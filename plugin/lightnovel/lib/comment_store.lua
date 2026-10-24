--[[--
Comment storage for the lightnovel plugin.

One database per book directory: {book_dir}/comments.db

Design note: comments are cached in SQLite and never written into the chapter
XHTML body. A cached chapter only carries a count marker; the panel reads rows
from here. This keeps chapter files small, lets a comment refresh run without
touching the reader, and avoids the "0-byte cache is ambiguous" class of bug the
chapter cache already had.

Table:
  comments(aid, tid, item_index, author, level, content, likes, replies, time)
  replies(aid, tid, rid, item_index, author, content, time)
  meta(aid, total, fetched_at)

A tap performs two indexed lookups (comments then replies) with no JSON decode
and no HTML rendering.
--]]--

local logger = require("lightnovel.lib.logger")

local CommentStore = {}

-- Keep cached comments for this long before a background refresh is offered.
local FRESH_SECONDS = 24 * 60 * 60

local function getSQ3()
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if ok and SQ3 then
        return SQ3
    end
    return nil
end

local function db_filename(namespace)
    if namespace == "new-content" then
        return "comments-new-content.db"
    end
    return "comments.db"
end

--- Remove a database and its WAL sidecars. Missing files are ignored.
-- @param namespace nil for legacy / `new-content` for the separate ID space.
function CommentStore.remove_db(book_dir, namespace)
    if type(book_dir) ~= "string" or book_dir == "" then
        return false
    end
    local filename = db_filename(namespace)
    for _, path in ipairs({
        book_dir .. "/" .. filename,
        book_dir .. "/" .. filename .. "-wal",
        book_dir .. "/" .. filename .. "-shm",
    }) do
        os.remove(path)
    end
    return true
end

--- Open the legacy comments DB or an isolated new-content comments DB.
-- The separate file is a safety boundary: rows written by old code under a
-- chapter_id can never alias a source_article_id merely because the integers
-- happen to match.
function CommentStore.open(book_dir, namespace)
    if type(book_dir) ~= "string" or book_dir == "" then
        return nil, "book_dir required"
    end
    local SQ3 = getSQ3()
    if not SQ3 then
        return nil, "sqlite_unavailable"
    end

    -- Ensure the book directory exists. There is deliberately NO lfs require here:
    -- this module is loaded directly by the offline test harness, which would
    -- then need a KOReader lfs stub just to reach the SQL. Instead, ask SQLite to
    -- create the file. It makes intermediate directories itself, so this
    -- replaces the `os.execute("mkdir -p ...")` that used to fork /bin/sh on
    -- EVERY open -- and open() is called from the UI thread for the TOC count,
    -- the comment panel, the export and every sync callback.
    local db_path = book_dir .. "/" .. db_filename(namespace)

    local ok, db = pcall(SQ3.open, db_path)
    if not ok or not db then
        return nil, "open_failed: " .. tostring(db)
    end

    pcall(function() db:exec("PRAGMA journal_mode=WAL") end)
    pcall(function() db:exec("PRAGMA synchronous=NORMAL") end)
    -- A background comment sync may write while the reader shows a popup, so
    -- wait instead of surfacing SQLITE_BUSY.
    pcall(function() db:exec("PRAGMA busy_timeout=5000") end)

    local schema_ok, schema_err = pcall(function()
        db:exec([[
            CREATE TABLE IF NOT EXISTS comments (
                aid        INTEGER NOT NULL,
                tid        TEXT    NOT NULL,
                item_index INTEGER NOT NULL,
                author     TEXT    NOT NULL,
                level      TEXT,
                content    TEXT    NOT NULL,
                likes      INTEGER NOT NULL DEFAULT 0,
                replies    INTEGER NOT NULL DEFAULT 0,
                time       TEXT,
                PRIMARY KEY (aid, tid)
            ) WITHOUT ROWID
        ]])
        db:exec([[
            CREATE TABLE IF NOT EXISTS replies (
                aid        INTEGER NOT NULL,
                tid        TEXT    NOT NULL,
                item_index INTEGER NOT NULL,
                author     TEXT    NOT NULL,
                content    TEXT    NOT NULL,
                time       TEXT,
                PRIMARY KEY (aid, tid, item_index)
            ) WITHOUT ROWID
        ]])
        db:exec([[
            CREATE TABLE IF NOT EXISTS meta (
                aid        INTEGER PRIMARY KEY,
                total      INTEGER NOT NULL DEFAULT 0,
                page       INTEGER NOT NULL DEFAULT 0,
                complete   INTEGER NOT NULL DEFAULT 0,
                fetched_at INTEGER NOT NULL DEFAULT 0
            )
        ]])
        -- Migrate. CREATE TABLE IF NOT EXISTS silently keeps an EXISTING table's
        -- old column list, and `page`/`complete` were added after the first
        -- shipped version. Without this, every put_comments on a database created
        -- by that version raises "no column named page", the error is swallowed by
        -- put_comments' own pcall, the chapter is rolled back -- and the sync still
        -- reports success with written=0. A device that upgraded would have looked
        -- like it simply had no comments.
        --
        -- Done by attempting the ALTER and recognising SQLite's "duplicate column
        -- name" as the success case, rather than by reading PRAGMA table_info.
        -- That keeps this independent of what db:exec returns for a row-returning
        -- statement, and makes the migration idempotent by construction.
        for _column, ddl in ipairs({
            "ALTER TABLE meta ADD COLUMN page INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE meta ADD COLUMN complete INTEGER NOT NULL DEFAULT 0",
        }) do
            local added, add_err = pcall(function() db:exec(ddl) end)
            if added then
                logger.info("comment_store: meta." .. _column, "added")
            elseif not tostring(add_err):find("duplicate column", 1, true) then
                logger.err("comment_store: cannot add meta column", _column,
                    tostring(add_err))
            end
        end
    end)
    if not schema_ok then
        logger.warn("comment_store schema init failed:", tostring(schema_err))
        pcall(function() db:close() end)
        return nil, "schema_failed"
    end

    return db
end

function CommentStore.close(db)
    if db then
        pcall(function() db:close() end)
    end
end

--- Normalize one API comment record into the shape the store persists.
-- The API returns numbers as strings for likes/replies and nests the author.
function CommentStore.normalize(entry, index)
    if type(entry) ~= "table" then
        return nil
    end
    local tid = entry.tid
    if tid == nil or tostring(tid) == "" then
        return nil
    end
    local user = entry.user_info or {}
    return {
        tid = tostring(tid),
        item_index = tonumber(index) or 1,
        author = tostring(user.nickname or "匿名"),
        level = tostring((user.level or {}).name or ""),
        content = tostring(entry.content or ""),
        likes = tonumber(entry.likes) or 0,
        replies = tonumber(entry.replies) or 0,
        time = tostring(entry.time or ""),
    }
end

function CommentStore.normalize_reply(entry, index)
    if type(entry) ~= "table" then
        return nil
    end
    local user = entry.user_info or {}
    return {
        rid = tostring(entry.tid or ""),
        item_index = tonumber(index) or 1,
        author = tostring(user.nickname or "匿名"),
        content = tostring(entry.content or ""),
        time = tostring(entry.time or ""),
    }
end

--- Replace all cached pages for one article in a single transaction.
-- @param db handle
-- @param aid number article id
-- @param items array of normalized comments
-- @param meta {total, page, complete}
function CommentStore.put_comments(db, aid, items, meta)
    if not db or tonumber(aid) == nil then
        return false, "db and aid required"
    end
    meta = meta or {}
    local transaction_open = false
    -- Every prepared statement is registered here and closed in one place on
    -- BOTH paths. They used to be closed only on the happy path, so any bind or
    -- step error left the handle open; the pcall below caught the error and
    -- rolled back, and the handle leaked. Repeated failed syncs then accumulated
    -- statements inside SQ3 until it refused to prepare more -- which is exactly
    -- the kind of failure that looks like "the database is broken".
    local open_stmts = {}
    local function track(stmt)
        open_stmts[#open_stmts + 1] = stmt
        return stmt
    end
    local function close_all()
        for _i, stmt in ipairs(open_stmts) do
            pcall(function() stmt:close() end)
        end
        open_stmts = {}
    end
    local ok, err = pcall(function()
        db:exec("BEGIN IMMEDIATE")
        transaction_open = true

        local del_c = track(db:prepare("DELETE FROM comments WHERE aid=?"))
        del_c:reset():bind(aid):step()
        del_c:close()

        local del_r = track(db:prepare("DELETE FROM replies WHERE aid=?"))
        del_r:reset():bind(aid):step()
        del_r:close()

        if type(items) == "table" and #items > 0 then
            local ins_c = track(db:prepare([[
                INSERT OR REPLACE INTO comments
                    (aid, tid, item_index, author, level, content, likes, replies, time)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ]]))
            local ins_r = track(db:prepare([[
                INSERT OR REPLACE INTO replies
                    (aid, tid, item_index, author, content, time)
                VALUES (?, ?, ?, ?, ?, ?)
            ]]))
            for _, item in ipairs(items) do
                ins_c:reset():bind(
                    aid, item.tid, item.item_index, item.author, item.level,
                    item.content, item.likes, item.replies, item.time
                ):step()
                for _, reply in ipairs(item.replies_list or {}) do
                    ins_r:reset():bind(
                        aid, item.tid, reply.item_index,
                        reply.author, reply.content, reply.time
                    ):step()
                end
            end
            ins_c:close()
            ins_r:close()
        end

        local ins_m = track(db:prepare([[
            INSERT OR REPLACE INTO meta
                (aid, total, page, complete, fetched_at)
            VALUES (?, ?, ?, ?, ?)
        ]]))
        ins_m:reset():bind(
            aid,
            tonumber(meta.total) or 0,
            tonumber(meta.page) or 0,
            meta.complete and 1 or 0,
            os.time()
        ):step()
        ins_m:close()

        db:exec("COMMIT")
        transaction_open = false
    end)
    close_all()
    if not ok then
        if transaction_open then
            pcall(function() db:exec("ROLLBACK") end)
        end
        logger.warn("comment_store write failed:",
            "aid=", tostring(aid), "error=", tostring(err))
        return false, err
    end
    return true
end

--- Read cached comments for one article, oldest first, with replies attached.
function CommentStore.get_comments(db, aid)
    if not db or tonumber(aid) == nil then
        return nil, "db and aid required"
    end

    local reply_map = {}
    local ok_r, stmt_r = pcall(function()
        return db:prepare([[
            SELECT tid, item_index, author, content, time
            FROM replies WHERE aid=? ORDER BY tid, item_index
        ]])
    end)
    if ok_r and stmt_r then
        local step_ok, row = pcall(function()
            return stmt_r:reset():bind(aid):step()
        end)
        while step_ok and row do
            local tid = tostring(row[1])
            reply_map[tid] = reply_map[tid] or {}
            reply_map[tid][#reply_map[tid] + 1] = {
                author = row[3],
                content = row[4],
                time = row[5],
            }
            step_ok, row = pcall(function() return stmt_r:step() end)
        end
        pcall(function() stmt_r:close() end)
        -- Both of these used to be silent. A replies query that failed mid-scan
        -- (SQLITE_BUSY past busy_timeout, a corrupt page) exited the while loop
        -- with row still set and no trace, reply_map stayed empty, and EVERY
        -- nested reply in the book silently vanished from the panel and the
        -- exported EPUB -- which is precisely the bug that was mistaken for a
        -- field-name mismatch for a whole review pass.
        if not step_ok then
            logger.err("comment_store reply scan failed mid-iteration aid=",
                tostring(aid), "rows_so_far=",
                tostring(#reply_map))
        end
    else
        logger.err("comment_store reply prepare failed aid=", tostring(aid),
            "err=", tostring(stmt_r))
        return nil, "reply_query_failed"
    end

    local ok_c, stmt_c = pcall(function()
        return db:prepare([[
            SELECT tid, author, level, content, likes, replies, time
            FROM comments WHERE aid=? ORDER BY item_index
        ]])
    end)
    if not ok_c or not stmt_c then
        return nil, "query_failed"
    end

    local items = {}
    local step_ok, row = pcall(function()
        return stmt_c:reset():bind(aid):step()
    end)
    while step_ok and row do
        local tid = tostring(row[1])
        items[#items + 1] = {
            tid = tid,
            author = row[2],
            level = row[3],
            content = row[4],
            likes = tonumber(row[5]) or 0,
            replies = tonumber(row[6]) or 0,
            time = row[7],
            -- Named replies_list, matching CommentStore.normalize's output and
            -- therefore put_comments' input. This used to be spelled reply_list
            -- here only, so every READER of the cache (comment_panel.lua,
            -- epub_export.lua) silently saw no nested replies at all -- the
            -- replies were stored and fetched correctly, just under a key nobody
            -- looked at. One canonical name across normalize -> put -> get.
            replies_list = reply_map[tid] or {},
        }
        step_ok, row = pcall(function() return stmt_c:step() end)
    end
    pcall(function() stmt_c:close() end)

    local total = #items
    local fetched_at = 0
    local complete = false
    local ok_m, stmt_m = pcall(function()
        return db:prepare(
            "SELECT total, complete, fetched_at FROM meta WHERE aid=?")
    end)
    if ok_m and stmt_m then
        local m_ok, mrow = pcall(function()
            return stmt_m:reset():bind(aid):step()
        end)
        if m_ok and mrow then
            total = tonumber(mrow[1]) or total
            complete = (tonumber(mrow[2]) or 0) == 1
            fetched_at = tonumber(mrow[3]) or 0
        end
        pcall(function() stmt_m:close() end)
    end

    return {
        items = items,
        total = total,
        complete = complete,
        fetched_at = fetched_at,
        fresh = fetched_at > 0 and (os.time() - fetched_at) <= FRESH_SECONDS,
    }
end

--- Cached comment count for one article, or 0.
function CommentStore.count(db, aid)
    if not db or tonumber(aid) == nil then
        return 0
    end
    local ok, stmt = pcall(function()
        return db:prepare("SELECT COUNT(*) FROM comments WHERE aid=?")
    end)
    if not ok or not stmt then
        return 0
    end
    local step_ok, row = pcall(function()
        return stmt:reset():bind(aid):step()
    end)
    local count = 0
    if step_ok and row then
        count = tonumber(row[1]) or 0
    end
    pcall(function() stmt:close() end)
    return count
end

--- How many distinct articles have at least one cached comment.
--- Backs the catalogue's "cached comments" row so it can report a real number
--- instead of a hopeful label. One COUNT(DISTINCT) instead of 83 per-chapter
--- queries, because the row is rebuilt on every catalogue open.
function CommentStore.count_chapters(db)
    if not db then
        return 0
    end
    local ok, stmt = pcall(function()
        return db:prepare("SELECT COUNT(DISTINCT aid) FROM comments")
    end)
    if not ok or not stmt then
        return 0
    end
    local step_ok, row = pcall(function()
        return stmt:reset():step()
    end)
    local chapters = 0
    if step_ok and row then
        chapters = tonumber(row[1]) or 0
    end
    pcall(function() stmt:close() end)
    return chapters
end

--- True when the cache is missing or older than the freshness window.
function CommentStore.needs_refresh(db, aid)
    local state, err = CommentStore.get_comments(db, aid)
    if not state then
        return true
    end
    if #state.items == 0 then
        return true
    end
    if state.fetched_at <= 0 then
        return true
    end
    return (os.time() - state.fetched_at) > FRESH_SECONDS
end

return CommentStore
