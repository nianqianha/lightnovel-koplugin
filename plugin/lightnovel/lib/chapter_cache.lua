--[[--
Chapter cache: fetch one volume's text and write it as a renderable XHTML file.

Layout under the plugin data dir:

  data/lightnovel/
    books/<key>/catalog.lua        resolved chapter list for the book
    books/<key>/chapters/<aid>.html
    books/<key>/comments.db        comment rows (see comment_store.lua)
    covers/<key>.jpg               cover bytes as the server sent them
    covers/<key>.thumb.png         UI-sized copy, see cover_thumbnail.lua
    settings.lua

`<key>` is derived from the series id so a book keeps one directory even when
it is reached from different listings.

Every write goes through Content.write_atomic (`.part.<time>.<seq>` + rename),
which is the same invariant the sibling plugins use: a half-written chapter must
never be visible, because crengine would cache the broken layout.
--]]--

local lfs = require("libs/libkoreader-lfs")
local Digest = require("lightnovel.lib.digest")

local Content = require("lightnovel.lib.content")
local Cover = require("lightnovel.lib.cover")
local logger = require("lightnovel.lib.logger")

-- How hard to try a chapter whose body did not arrive. On 2026-10-10 a download of
-- 《义妹生活》 died on chapter 218070 with `sink timeout` -- LuaSocket's read
-- timeout, i.e. the socket went quiet for the whole 60s window -- and the old code
-- treated that as a final verdict, so one slow response permanently lost a
-- chapter that the very next request would have returned. Retries are bounded
-- and only fire for failures that look like transport trouble.
local MAX_CHAPTER_ATTEMPTS = 3
local RETRY_BASE_DELAY_SECONDS = 1

-- Substrings of a client error string that mark it worth another attempt.
-- Deliberately narrow: a lock refusal, a 4xx, or an HTML/WAF page is a stable
-- answer and retrying it just burns the reader's battery and data plan.
local RETRYABLE_REASONS = {
    ["sink timeout"] = true,
    ["timeout"] = true,
    ["request_failed"] = true,
    ["transport_failed"] = true,
    ["empty_response"] = true,
    ["empty_body"] = true,
    ["connection"] = true,
    ["closed"] = true,
    ["http_429"] = true,
    ["http_500"] = true,
    ["http_502"] = true,
    ["http_503"] = true,
    ["http_504"] = true,
}

local function is_retryable_reason(reason)
    local text = tostring(reason or ""):lower()
    if text == "" then return false end
    for token in pairs(RETRYABLE_REASONS) do
        if text:find(token, 1, true) then return true end
    end
    return false
end

--- Persist the outcome of a download as a loadable Lua table.
---
--- Written through `.tmp` + rename for the same reason chapter bodies are: a power
--- cut in the middle of a plain write leaves a truncated file that is itself a
--- syntax error, and `dofile` on it fails -- so the one record meant to explain an
--- interrupted download is the record that gets destroyed by the interruption.
--- Losing that file is what made the 20:36 run undiagnosable: it left chapters on
--- disk and no `download_state.lua` explaining which of 58 were done.
local function write_download_state(path, state)
    local lines = { "return {\n" }
    for key, value in pairs(state or {}) do
        local kind = type(value)
        if kind == "number" then
            lines[#lines + 1] = string.format("  %s = %d,\n", key, value)
        elseif kind == "boolean" then
            lines[#lines + 1] = string.format("  %s = %s,\n", key,
                value and "true" or "false")
        elseif kind == "string" then
            lines[#lines + 1] = string.format("  %s = %q,\n", key, value)
        elseif kind == "table" then
            local ids = {}
            for _i, id in ipairs(value) do
                ids[#ids + 1] = tostring(tonumber(id) or 0)
            end
            lines[#lines + 1] = string.format("  %s = { %s },\n", key,
                table.concat(ids, ", "))
        end
    end
    lines[#lines + 1] = "}\n"

    local temporary = path .. ".tmp"
    local file = io.open(temporary, "wb")
    if not file then
        logger.err("download state not written, path unwritable:", path)
        return false, "state_unwritable"
    end
    local ok = file:write(table.concat(lines))
    file:close()
    if not ok then
        os.remove(temporary)
        return false, "state_write_failed"
    end
    if not os.rename(temporary, path) then
        os.remove(temporary)
        logger.err("download state not published:", path)
        return false, "state_rename_failed"
    end
    return true
end

local Cache = {}
-- Required for instance method lookup. `Cache:new` sets the module table as the
-- instance metatable, and Lua only follows __index when it is present; with it
-- nil EVERY instance method (save_catalog, load_catalog, chapter_path,
-- is_cached, fetch_chapter, _book_dir) resolved to nil and failed with
-- "attempt to call method 'save_catalog' (a nil value)". Cache.book_key kept
-- working because it is a static, called as Cache.book_key.
Cache.__index = Cache

function Cache:new(settings)
    return setmetatable({ settings = settings }, self)
end

function Cache:_root()
    local dir = self.settings:data_dir() .. "/books"
    lfs.mkdir(dir)
    return dir
end

function Cache:_book_dir(key, create)
    local dir = self:_root() .. "/" .. key
    if create then
        lfs.mkdir(dir)
        lfs.mkdir(dir .. "/chapters")
    end
    return dir
end

--- Every book that has a cache directory, newest name order irrelevant.
--- Used by the "publish everything already downloaded as whole books" action, so
--- it must report only directories that actually hold chapters -- an empty shell
--- left by an interrupted download would otherwise produce a 0-chapter "book".
--- @return table list of {key = string, chapters = number, title = string|nil}
function Cache:list_cached_books()
    local out = {}
    local ok, iter, dir_obj = pcall(lfs.dir, self:_root())
    if not ok or type(iter) ~= "function" then
        logger.warn("cache: cannot list", self:_root())
        return out
    end
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." then
            local chapters = 0
            local cok, citer, cobj = pcall(lfs.dir, self:_book_dir(name) .. "/chapters")
            if cok and type(citer) == "function" then
                for _f in citer, cobj do
                    -- 与菜单同口径：只数 .html，别把 .format 标记算成章节。
                    if _f ~= "." and _f ~= ".." and _f:sub(-5) == ".html" then
                        chapters = chapters + 1
                    end
                end
            end
            if chapters > 0 then
                local catalog = self:load_catalog(name)
                out[#out + 1] = {
                    key = name,
                    chapters = chapters,
                    title = catalog and catalog.title or nil,
                }
            end
        end
    end
    table.sort(out, function(a, b) return tostring(a.key) < tostring(b.key) end)
    return out
end

--- Stable per-book directory name. Prefers the series id so all volumes of one
--- series share a directory.
---
--- A shelf book carries no sid and no aid -- only a book_id from the new id
--- space -- so without this branch it would fall through to the md5-of-title
--- fallback and collide with any other book of the same name. Checked first:
--- book_id is the most reliable identifier when it is present at all.
function Cache.book_key(book)
    local book_id = tonumber(book and book.book_id) or nil
    if book_id and book_id > 0 then
        return "bid_" .. tostring(book_id)
    end
    local sid = tonumber(book and book.sid) or nil
    if sid and sid > 0 then
        return "sid_" .. tostring(sid)
    end
    local aid = tonumber(book and book.aid) or nil
    if aid then
        return "aid_" .. tostring(aid)
    end
    local title = tostring(book and book.title or "unknown")
    return "t_" .. Digest.md5(title)
end

--- Inverse of book_key. The catalog on disk deliberately stores no book_id (it
--- is not needed to render a TOC), but the TOC screen gates its comment,
--- whole-book-cache and export rows on `book_id > 0`. Without this, a book opened
--- from the cached bookshelf silently lost all three entry points. Deriving it
--- from the key also covers books cached before this existed, so no migration.
function Cache.book_id_from_key(key)
    local id = tonumber(tostring(key or ""):match("^bid_(%d+)$"))
    if id and id > 0 then
        return id
    end
    return nil
end

function Cache:chapter_path(key, aid)
    return self:_book_dir(key) .. "/chapters/" .. tostring(tonumber(aid) or 0) .. ".html"
end

-- 章节 XHTML 的格式版本（b40）。
--
-- 正文抽取一改（这次是去 BBCode），磁盘上已经烘好的章节不会自己更新：
-- is_cached 只看文件在不在，于是"下载入库"认为都齐了、一个都不重下，读者
-- 屏幕上还是旧的 `[justify]`。加一个 per-book 标记文件，版本不符就按未缓存
-- 处理，下次下载自动重取。改抽取逻辑时记得把这个数字加一。
local CHAPTER_HTML_VERSION = 2

function Cache:_format_marker(key)
    return self:_book_dir(key) .. "/chapters/.format"
end

function Cache:format_ok(key)
    self._format_cache = self._format_cache or {}
    -- 只缓存"确认有效"的结果。原来连 false 也缓存，而父进程往往在下载*之前*
    -- 就查过一次（那时还没有 .format 标记）——下载写完后仍是同一个 Cache 实例，
    -- 于是 is_cached 永远返回 false，导出阶段把 15 章全判成"未缓存"并逐章重新
    -- 联网抓取（实测日志 `skipped_uncached= 15`），又慢又白做一遍网络。
    -- 现在 false 不落缓存：多一次 io.open，换来的是不会因为一次早查而永久误判。
    if self._format_cache[key] == true then return true end
    local f = io.open(self:_format_marker(key), "r")
    local ok = false
    if f then
        local version = tonumber(f:read("*n"))
        f:close()
        ok = version == CHAPTER_HTML_VERSION
    end
    if ok then self._format_cache[key] = true end
    return ok
end

function Cache:mark_format(key)
    self:_book_dir(key, true)
    local path = self:_format_marker(key)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if f then
        f:write(tostring(CHAPTER_HTML_VERSION) .. "\n")
        f:close()
        os.remove(path)
        os.rename(tmp, path)
        self._format_cache = self._format_cache or {}
        self._format_cache[key] = true
    end
end

function Cache:is_cached(key, aid)
    if not self:format_ok(key) then return false end
    return lfs.attributes(self:chapter_path(key, aid), "mode") == "file"
end

function Cache:cached_count(key, aids)
    local n = 0
    for _, aid in ipairs(aids or {}) do
        if self:is_cached(key, aid) then
            n = n + 1
        end
    end
    return n
end

--- Persist the resolved catalog so the TOC opens offline.
---
--- Written to `catalog.lua.tmp` and renamed into place. The catalog is now saved
--- immediately after it is fetched -- before any chapter body is downloaded -- so
--- that an interrupted download still leaves a complete catalog behind and the
--- next run can tell "these chapters exist but have no body yet" from "this book
--- was never catalogued". A plain write would defeat that: a power cut mid-write
--- leaves a truncated `catalog.lua` that `load_catalog` swallows, and the book
--- disappears from the cached shelf with nothing to rebuild it from.
function Cache:save_catalog(key, catalog)
    local dir = self:_book_dir(key, true)
    local final_path = dir .. "/catalog.lua"
    local file = io.open(final_path .. ".tmp", "wb")
    if not file then
        -- Every caller used to drop this return value, so a full filesystem --
        -- the normal state after downloading a whole book -- meant the TOC was
        -- simply not saved for offline use, with nothing in the log and nothing
        -- on screen. Say it out loud.
        logger.err("cache: catalog not saved for", tostring(key),
            "path unwritable:", tostring(dir))
        return false, "catalog_unwritable"
    end
    catalog = catalog or {}
    -- Written as Lua source so it can be loaded without a JSON parser.
    --
    -- %q, not a hand-rolled gsub of `\` and `"`. A title containing a newline, a
    -- carriage return or any control byte came from the server unescaped and put a
    -- literal newline inside a `"..."` literal, so catalog.lua became a SYNTAX
    -- ERROR -- and load_catalog then swallowed it, so the book silently vanished
    -- from the cache shelf. %q also escapes ]] and embedded quotes correctly.
    local parts = { "return {\n  sid = " .. tostring(tonumber(catalog.sid) or 0)
        .. ",\n  title = " .. string.format("%q", tostring(catalog.title or key or ""))
        .. ",\n  chapters = {\n" }
    for _i, chapter in ipairs(catalog.chapters or {}) do
        -- Keep volume_id / volume_title / lock state / book_id: they are dropped
        -- otherwise, and a reloaded shelf book then has no book_id, fails the
        -- `book_id > 0` routing in main.lua and falls through to the legacy
        -- endpoint -- which answers code 0 with an empty list for a new-id book.
        parts[#parts + 1] = string.format(
            "    { index = %d, aid = %d, book_id = %d, volume_id = %d, "
                .. "source_article_id = %d, comment_aid = %d, "
                .. "comment_candidate_aid = %d, "
                .. "volume_comment_count = %d, comment_mapping_verified = %s, "
                .. "volume_title = %q, locked = %s, unlocked = %s, "
                .. "access_type = %q, coin_price = %d, title = %q },\n",
            tonumber(chapter.index) or _i, tonumber(chapter.aid) or 0,
            tonumber(chapter.book_id) or 0, tonumber(chapter.volume_id) or 0,
            tonumber(chapter.source_article_id) or 0,
            tonumber(chapter.comment_aid) or 0,
            tonumber(chapter.comment_candidate_aid) or 0,
            tonumber(chapter.volume_comment_count) or 0,
            chapter.comment_mapping_verified and "true" or "false",
            tostring(chapter.volume_title or ""),
            chapter.locked and "true" or "false",
            chapter.unlocked and "true" or "false",
            tostring(chapter.access_type or ""),
            tonumber(chapter.coin_price) or 0,
            tostring(chapter.title or ""))
    end
    parts[#parts + 1] = "  },\n}\n"
    local payload = table.concat(parts)
    local wrote = file:write(payload)
    file:close()
    if not wrote then
        os.remove(final_path .. ".tmp")
        logger.err("cache: catalog write failed for", tostring(key))
        return false, "catalog_write_failed"
    end
    if not os.rename(final_path .. ".tmp", final_path) then
        os.remove(final_path .. ".tmp")
        logger.err("cache: catalog not published for", tostring(key))
        return false, "catalog_rename_failed"
    end
    return true
end

function Cache:load_catalog(key)
    local path = self:_book_dir(key) .. "/catalog.lua"
    if lfs.attributes(path, "mode") ~= "file" then
        return nil
    end
    local ok, data = pcall(dofile, path)
    if not ok or type(data) ~= "table" then
        -- Was a bare `return nil`, so a corrupt or truncated catalog made the book
        -- disappear from 缓存书架 and 缓存管理 with nothing in crash.log.
        logger.err("cache: catalog unreadable for", tostring(key),
            "path=", path, "err=", tostring(data))
        return nil
    end
    return data
end

--- Fetch one volume and write its XHTML. Returns the path.
-- @param client Client instance
-- @param key book directory key
-- @param chapter {aid, title}
-- @param comment_count comments already cached, for the marker
function Cache:fetch_chapter(client, key, chapter, comment_count)
    local data, err = client:fetchArticle(chapter.aid, { timeout = 45 })
    if not data then
        return nil, err or "article_unavailable"
    end
    local content = tostring(data.content or "")
    if content:gsub("%s", "") == "" then
        return nil, "empty_content"
    end

    -- Inline images: the site stores illustration URLs in content as bare links
    -- (verified: no [res]/[img] markup), so text_to_html turns them into <img>.
    local body = Content.text_to_html(content)
    local title = tostring(chapter.title or data.title or "")
    local xhtml = Content.build_chapter_xhtml(title, body, comment_count,
        chapter.aid)

    local path = self:chapter_path(key, chapter.aid)
    local ok, write_err = Content.write_atomic(path, xhtml)
    if not ok then
        return nil, write_err or "write_failed"
    end
    return path
end

--- Fetch a shelf chapter (new-content-read family) and write its XHTML.
---
--- Returns a result table instead of a bare path so the caller can tell three
--- outcomes apart: {path=...}, {need_unlock=true,...}, or nil plus an error.
--- The unlock prompt needs a UI, which a worker process cannot show, so the
--- locked case is handed back to main.lua instead of being resolved here.
---
--- @param chapter {aid=chapter_id, title, book_id, volume_id}
function Cache:fetch_shelf_chapter(client, key, chapter, comment_count)
    local book_id = tonumber(chapter.book_id)
    local chapter_id = tonumber(chapter.aid)
    if not book_id or book_id <= 0 or not chapter_id or chapter_id <= 0 then
        return nil, "bad_shelf_ids"
    end

    local data, err = client:fetchChapterParagraphs(book_id, chapter_id,
        { timeout = 45 })
    if not data then
        -- A locked chapter answers code 1000 with data.message "本章需要 N 轻币
        -- 解锁". The coin_price field in the chapter list is always 0 and cannot
        -- be used to predict N.
        --
        -- The match must NOT be a bare substring test for "1000". That code is
        -- overloaded on this API (see client.lua:508-509): it also means "请求过于
        -- 频繁，请稍后再试" and "签名失效", and other codes such as 21000 contain
        -- the same digits. Matching the digits alone therefore classified ordinary
        -- rate-limiting and signature errors as "locked", which opened the unlock
        -- confirmation for a chapter the reader already owns -- and confirming it
        -- spends real 轻币. Require the currency wording as well, and log the two
        -- cases apart so a mismatch is visible instead of expensive.
        local text = tostring(err or "")
        local code_1000 = text:find("1000", 1, true) ~= nil
        local asks_money = text:find("轻币", 1, true) ~= nil
        if code_1000 and asks_money then
            return { need_unlock = true, chapter_id = chapter_id,
                     book_id = book_id }
        end
        if code_1000 then
            logger.warn("chapter: code 1000 without an unlock message",
                "aid=", tostring(chapter_id), "err=", text)
        end
        return nil, err or "paragraphs_unavailable"
    end

    local paragraphs = data.paragraphs or {}
    local details, detail_err = client:fetchChapterDetail(book_id, chapter_id,
        { timeout = 60 })
    if not details then
        logger.warn("chapter: detail html unavailable chapter=",
            tostring(chapter_id), "err=", tostring(detail_err))
    end
    local body = Content.chapter_body_html(details, paragraphs)
    if body:gsub("%s", "") == "" then
        return nil, "empty_content"
    end

    local title = tostring(chapter.title or "")
    local xhtml = Content.build_chapter_xhtml(title, body, comment_count,
        chapter_id)

    local path = self:chapter_path(key, chapter_id)
    local ok, write_err = Content.write_atomic(path, xhtml)
    if not ok then
        return nil, write_err or "write_failed"
    end
    return { path = path }
end

--- Download an entire book into the local cache, covers included.
---
--- Follows the site's own export sequence (check -> prepare -> fetch ->
--- complete; see the reference at the top of client.lua). Verified 2026-10-02:
--- one fetch returns all 83 chapters in ~2.4 MB and spends no coins, including
--- the seven trailing chapters that per-chapter unlocking refused.
---
--- Text handling differs by route on purpose. This path receives
--- `body_snapshot.body_text`, which is flat plain text separated by newlines
-- -- exactly what Content.text_to_html() expects. The online per-chapter route
--- returns structured paragraphs with <ruby> markup and uses
--- Content.paragraphs_to_html() instead.
---
--- @param book {book_id, key, title}
--- 网络层瞬时错误的有限重试。
---
--- `Cannot assign requested address`（EADDRNOTAVAIL）是设备建不出 socket 时的典型
--- 瞬时错误：WiFi 刚断/刚重连，或短时间内打开了太多连接。2026-10-27《游戏人生》
--- 重出时正好撞上，直接判 `catalog_failed` 让整轮作废——而这只是一次 2 秒的抖动。
--- 只重试连接层错误；业务错误（接口返回 code != 0）立即返回，不掩盖真问题。
local function is_transient_net_error(err)
    local t = tostring(err or ""):lower()
    return t:find("cannot assign requested address", 1, true) ~= nil
        or t:find("request_failed", 1, true) ~= nil
        or t:find("connection reset", 1, true) ~= nil
        or t:find("connection refused", 1, true) ~= nil
        or t:find("timeout", 1, true) ~= nil
end

local function with_net_retry(fn, tries)
    tries = tries or 3
    local last
    for attempt = 1, tries do
        local data, err = fn()
        if data then return data end
        last = err
        if not is_transient_net_error(err) then return nil, err end
        if attempt < tries then
            logger.warn("catalog: transient net error, retrying attempt=",
                tostring(attempt), tostring(err))
            local ok, ffiutil = pcall(require, "ffi/util")
            if ok and ffiutil.sleep then ffiutil.sleep(2) end
        end
    end
    return nil, last
end

--- Read the canonical web volume/chapter catalog with all pages.
--- Returns flat rows plus declared totals; no unlock endpoint is used.
function Cache:fetch_web_catalog(client, book_id, context)
    context = context or {}
    local volumes, volume_ids, total_volumes = {}, {}, nil
    local page = 1
    while page <= 50 do
        -- Heartbeat before every page request. The catalogue pass is the longest
        -- silent stretch of a whole-book download (dozens of paginated round
        -- trips, 40s timeouts each), and the parent's progress dialog only
        -- repaints on an emit -- without this the reader stared at a motionless
        -- bar for minutes and concluded the download was broken.
        if context.emit then
            context.emit{ stage = "catalog", page = page }
        end
        local data, err = with_net_retry(function()
            return client:fetchWebBookVolumes(book_id, page, { timeout = 40 })
        end)
        if not data then return nil, "volumes_failed:" .. tostring(err) end
        local rows = data.list or {}
        for _, volume in ipairs(rows) do
            local vid = tonumber(volume.volume_id or volume.id)
            if not vid or vid <= 0 then return nil, "bad_volume_id" end
            if volume_ids[vid] then return nil, "duplicate_volume_id" end
            volume_ids[vid] = true
            volumes[#volumes + 1] = volume
        end
        local page_info = data.page_info or {}
        total_volumes = tonumber(page_info.count) or total_volumes
        if #rows == 0 or (tonumber(page_info.has_next) or 0) == 0 then break end
        page = page + 1
    end
    if total_volumes and #volumes ~= total_volumes then
        return nil, string.format("incomplete_volume_catalog:%d/%d",
            #volumes, total_volumes)
    end
    if #volumes == 0 then return nil, "empty_volume_catalog" end

    local chapters, chapter_ids, declared_total = {}, {}, 0
    for volume_index, volume in ipairs(volumes) do
        local vid = tonumber(volume.volume_id or volume.id)
        local page_no, volume_rows = 1, 0
        local expected = tonumber(volume.chapter_count) or 0
        while page_no <= 100 do
            -- Same heartbeat inside the per-volume chapter listing: one volume
            -- page can also stall for its full 45s timeout with no other signal.
            if context.emit then
                context.emit{ stage = "catalog", volume = volume_index,
                    total_volumes = #volumes, page = page_no }
            end
            local data, err = with_net_retry(function()
                return client:fetchWebVolumeChapters(book_id, vid, page_no,
                    { timeout = 45 })
            end)
            if not data then
                return nil, string.format("volume_chapters_failed:%d:%s",
                    vid, tostring(err))
            end
            local rows = data.list or {}
            for _, row in ipairs(rows) do
                local cid = tonumber(row.chapter_id)
                if not cid or cid <= 0 then return nil, "bad_chapter_id" end
                if chapter_ids[cid] then return nil, "duplicate_chapter_id" end
                chapter_ids[cid] = true
                chapters[#chapters + 1] = {
                    index = #chapters + 1,
                    aid = cid,
                    book_id = tonumber(book_id),
                    volume_id = vid,
                    volume_title = tostring(volume.title or volume.volume_title or ""),
                    source_article_id = tonumber(volume.source_article_id
                        or volume.volume_legacy_aid) or 0,
                    comment_candidate_aid = tonumber(volume.source_article_id
                        or volume.volume_legacy_aid) or 0,
                    volume_comment_count = tonumber(volume.volume_comment_count) or 0,
                    title = tostring(row.title or ""),
                    words = tonumber(row.word_count) or 0,
                    locked = (tonumber(row.locked) or 0) == 1
                        and (tonumber(row.unlocked) or 0) == 0,
                    unlocked = (tonumber(row.unlocked) or 0) == 1,
                    access_type = tostring(row.access_type or ""),
                    coin_price = tonumber(row.coin_price) or 0,
                    _readable = not ((tonumber(row.locked) or 0) == 1
                        and (tonumber(row.unlocked) or 0) == 0)
                        and (tostring(row.access_type or "") == "public"
                            or (tonumber(row.unlocked) or 0) == 1),
                }
                volume_rows = volume_rows + 1
            end
            local page_info = data.page_info or {}
            if #rows == 0 or (tonumber(page_info.has_next) or 0) == 0 then break end
            page_no = page_no + 1
        end
        if expected > 0 and volume_rows ~= expected then
            return nil, string.format("incomplete_volume:%d:%d/%d",
                vid, volume_rows, expected)
        end
        declared_total = declared_total + (expected > 0 and expected or volume_rows)
    end
    if declared_total ~= #chapters then
        return nil, string.format("incomplete_chapter_catalog:%d/%d",
            #chapters, declared_total)
    end
    return { volumes = volumes, chapters = chapters, total_volumes = #volumes,
        total_chapters = #chapters }
end

--- @param context worker context, for cancellation and progress
--- @return table {revision, total, written, skipped, cover}
local function web_catalog_revision(chapters)
    local parts = {}
    for _, chapter in ipairs(chapters or {}) do
        parts[#parts + 1] = tostring(chapter.aid)
            .. ":" .. tostring(chapter.title)
            .. ":" .. tostring(chapter.unlocked)
    end
    return Digest.md5(table.concat(parts, "|"))
end

--- How does the cached copy of a serialised book compare to the server?
---
--- Returns nil plus a reason when the question cannot be answered (no session,
--- access refused, network down) so the caller can tell "no new chapters" apart
--- from "could not check" -- they look identical otherwise, and the reader is
--- left believing a serial is finished.
---
--- @treturn table {revision, total, cached, missing = {ids}, added = n,
---                  orphans = {ids}, changed = bool}
function Cache:check_for_updates(client, book)
    local book_id = tonumber(book and book.book_id)
    local key = book and book.key
    if not book_id or book_id <= 0 or not key then
        return nil, "bad_book"
    end
    if client.uses_web_catalog_download then
        -- check_for_updates runs outside the worker, so there is no emit
        -- context; fetch_web_catalog guards on context.emit anyway.
        local remote, catalog_err = self:fetch_web_catalog(client, book_id, {})
        if not remote then return nil, "catalog_failed:" .. tostring(catalog_err) end
        local export_manifest = {}
        local export_allowed = false
        if client.checkBookDownloadAccess and client.prepareBookDownload then
            local access, access_err = client:checkBookDownloadAccess(book_id,
                { timeout = 30 })
            if access and tonumber(access.allow) == 1 then
                local prepared, prepare_err = client:prepareBookDownload(book_id,
                    { timeout = 60 })
                if prepared and type(prepared.chapter_ids) == "table" then
                    export_allowed = true
                    for _, id in ipairs(prepared.chapter_ids) do
                        local n = tonumber(id)
                        if n and n > 0 then export_manifest[n] = true end
                    end
                else
                    logger.warn("check updates: free export prepare failed:",
                        tostring(prepare_err))
                end
            elseif not access then
                logger.warn("check updates: free export access check failed:",
                    tostring(access_err))
            end
        end
        local cached, missing, remote_set, readable_total, downloadable_total =
            0, {}, {}, 0, 0
        for _, chapter in ipairs(remote.chapters) do
            local id = tonumber(chapter.aid)
            remote_set[id] = true
            if chapter._readable then
                readable_total = readable_total + 1
            end
            local downloadable = chapter._readable
                or (export_allowed and export_manifest[id] == true)
            if downloadable then
                downloadable_total = downloadable_total + 1
                if self:is_cached(key, id) then cached = cached + 1
                else missing[#missing + 1] = id end
            end
        end
        local orphans = {}
        for _, entry in ipairs((self:load_catalog(key) or {}).chapters or {}) do
            local id = tonumber(entry.aid)
            if id and id > 0 and not remote_set[id] then orphans[#orphans + 1] = id end
        end
        local revision = web_catalog_revision(remote.chapters)
        local state_path = self:_book_dir(key) .. "/download_state.lua"
        local previous
        if lfs.attributes(state_path, "mode") == "file" then
            local ok, data = pcall(dofile, state_path)
            if ok and type(data) == "table" then previous = data end
        end
        return { revision = revision,
            previous_revision = previous and previous.revision or nil,
            total = remote.total_chapters, downloadable_total = downloadable_total,
            readable_total = readable_total,
            cached = cached, missing = missing, added = #missing, orphans = orphans,
            changed = previous ~= nil and previous.revision ~= revision,
            first_time = previous == nil,
        }
    end
    -- access answers code 8 without a session; reporting that as "no updates"
    -- would be a lie, so it is surfaced as a failure instead.
    local access, aerr = client:checkBookDownloadAccess(book_id, { timeout = 30 })
    if not access then
        return nil, "access_failed:" .. tostring(aerr)
    end
    if tonumber(access.allow) ~= 1 then
        return nil, "not_allowed:" .. tostring(access.reason_code
            or access.policy or "unknown")
    end

    local prep, perr = client:prepareBookDownload(book_id, { timeout = 60 })
    if not prep then
        return nil, "prepare_failed:" .. tostring(perr)
    end
    local revision = tostring(prep.revision or "")
    local remote_ids = prep.chapter_ids or {}
    if #remote_ids == 0 then
        return nil, "empty_chapter_list"
    end

    local cached, missing, remote_set = 0, {}, {}
    for _i, id in ipairs(remote_ids) do
        local n = tonumber(id)
        if n and n > 0 then
            remote_set[n] = true
            if self:is_cached(key, n) then
                cached = cached + 1
            else
                missing[#missing + 1] = n
            end
        end
    end

    -- Chapters on disk that the server no longer lists: a rename, a volume merge
    -- or a takedown. They stay on disk (deleting a reader's copy unasked is not
    -- this function's call) but they are reported.
    local orphans = {}
    for _i, entry in ipairs((self:load_catalog(key) or {}).chapters or {}) do
        local n = tonumber(entry.aid)
        if n and n > 0 and not remote_set[n] then
            orphans[#orphans + 1] = n
        end
    end

    local state_path = self:_book_dir(key) .. "/download_state.lua"
    local previous = nil
    if lfs.attributes(state_path, "mode") == "file" then
        local ok, data = pcall(dofile, state_path)
        if ok and type(data) == "table" then previous = data end
    end

    return {
        revision = revision,
        previous_revision = previous and previous.revision or nil,
        total = #remote_ids,
        downloadable_total = #remote_ids,
        cached = cached,
        missing = missing,
        added = #missing,
        orphans = orphans,
        -- A changed revision means a body may have been EDITED, not merely
        -- appended, so the update has to re-fetch everything rather than only the
        -- missing ids. Reported so the caller can say so honestly.
        changed = previous ~= nil and previous.revision ~= revision,
        first_time = previous == nil,
    }
end

--- Download the whole book, or only what is missing.
---
--- `context.force` re-downloads every chapter even when the files are present;
--- used when the server's revision changed, because that means a body may have
--- been edited rather than merely appended.
function Cache:download_web_catalog_book(client, book, context)
    context = context or {}
    local book_id = tonumber(book and book.book_id)
    local key = book and book.key
    if not book_id or book_id <= 0 or not key then return { error = "bad_book" } end
    if context.checkCancelled then context.checkCancelled() end
    local catalog, catalog_err = self:fetch_web_catalog(client, book_id, context)
    if not catalog then return { error = "catalog_failed:" .. tostring(catalog_err) } end

    local chapters = catalog.chapters
    local readable_ids, by_id = {}, {}
    for _, chapter in ipairs(chapters) do
        by_id[chapter.aid] = chapter
        if chapter._readable then readable_ids[#readable_ids + 1] = chapter.aid end
    end

    -- Resolve the site's explicit whole-book export entitlement BEFORE deciding
    -- that a local cache hit is complete. The web catalogue says nine chapters
    -- are `coin`; the free export manifest has been verified to include all 67
    -- chapter IDs for book 5143. Returning early based only on the 58 public IDs
    -- made an already-cached public subset impossible to complete, because the
    -- code never discovered that those nine IDs were downloadable without spend.
    -- This preflight is read-only: check + prepare only; no unlock/purchase call.
    local export_allowed, export_manifest, export_revision = false, {}, ""
    if client.checkBookDownloadAccess and client.prepareBookDownload then
        local access, access_err = client:checkBookDownloadAccess(book_id,
            { timeout = 30 })
        if access and tonumber(access.allow) == 1 then
            local prepared, prepare_err = client:prepareBookDownload(book_id,
                { timeout = 60 })
            if prepared and type(prepared.chapter_ids) == "table" then
                export_allowed = true
                export_revision = tostring(prepared.revision or "")
                for _, id in ipairs(prepared.chapter_ids) do
                    local n = tonumber(id)
                    if n and n > 0 then export_manifest[n] = true end
                end
                logger.info("download: free export manifest has",
                    tostring(#prepared.chapter_ids), "chapter IDs")
            else
                logger.warn("download: free export prepare failed; public chapters",
                    "will use per-chapter reads:", tostring(prepare_err))
            end
        else
            logger.info("download: free export route not allowed; public chapters",
                "only:", tostring(access_err or (access and access.reason_code)))
        end
    end

    local wanted, downloadable_ids, locked_skipped_ids = {}, {}, {}
    for _, chapter in ipairs(chapters) do
        local id = tonumber(chapter.aid)
        -- Public/already-unlocked chapters remain readable through their normal
        -- detail endpoint. Coin-gated chapters are eligible ONLY when present in
        -- the server's explicit, allowed export manifest. Never guess IDs, never
        -- send an unmanifested coin chapter to the detail or unlock endpoint.
        local free_exported = export_allowed and export_manifest[id] == true
        local downloadable = chapter._readable or free_exported
        if downloadable then
            downloadable_ids[#downloadable_ids + 1] = id
            if context.force or not self:is_cached(key, id) then
                wanted[#wanted + 1] = id
            end
        elseif not self:is_cached(key, id) then
            locked_skipped_ids[#locked_skipped_ids + 1] = id
        end
    end
    local revision = web_catalog_revision(chapters)

    -- `load_catalog` is read BEFORE anything is written below, so this compares
    -- the server's catalog against the previous run's.
    local previous_chapters = (self:load_catalog(key) or {}).chapters or {}
    local catalog_changed = #previous_chapters ~= catalog.total_chapters
    if not catalog_changed then
        for index, row in ipairs(chapters) do
            local old = previous_chapters[index]
            if not old or tonumber(old.aid) ~= row.aid
                or tonumber(old.volume_id) ~= row.volume_id
                or tostring(old.title or "") ~= row.title then
                catalog_changed = true
                break
            end
        end
    end

    local state_path = self:_book_dir(key) .. "/download_state.lua"
    -- Written on every exit path, including a cancelled one. A previous version
    -- only wrote it after the loop, so an interrupted download left no record at
    -- all and the next run started from nothing.
    local function publish_state(complete, written, failed_ids, locked_skipped_ids)
        write_download_state(state_path, {
            revision = revision,
            total = #chapters,
            downloadable_total = #downloadable_ids,
            catalog_total = catalog.total_chapters,
            written = written,
            failed = #failed_ids,
            locked_skipped = #locked_skipped_ids,
            complete = complete and #failed_ids == 0
                and #locked_skipped_ids == 0,
            failed_ids = failed_ids,
            locked_skipped_ids = locked_skipped_ids,
            saved_at = os.time(),
        })
    end

    -- Persist the catalog BEFORE the first body request. Everything needed to
    -- resume -- which ids exist, which are readable, which volumes they belong
    -- to -- is in here, so a download killed at chapter 30 of 58 leaves a book
    -- the next run can finish instead of one it has to rediscover.
    local catalog_saved, catalog_save_err = self:save_catalog(key, {
        sid = 0, title = tostring(book.title or key), chapters = chapters,
    })
    if not catalog_saved then
        return { error = "catalog_write_failed:" .. tostring(catalog_save_err) }
    end

    if #wanted == 0 then
        -- Clears stale state when every currently downloadable body is already on
        -- disk. Coin chapters outside the explicit free manifest remain visible
        -- as locked/skipped and do not turn into a failed download.
        publish_state(true, 0, {}, locked_skipped_ids)
        return { revision = revision, total = catalog.total_chapters,
            readable_total = #readable_ids,
            downloadable_total = #downloadable_ids, written = 0,
            skipped = #downloadable_ids, failed = 0, cached = true,
            locked_skipped = #locked_skipped_ids,
            locked_skipped_ids = locked_skipped_ids,
            complete = #locked_skipped_ids == 0,
            catalog_changed = catalog_changed, chapters = chapters,
            volumes = catalog.volumes }
    end
    logger.info("download: fetching", tostring(#wanted), "of",
        tostring(#chapters), "chapters (", tostring(#readable_ids),
        " public); catalog_changed=", tostring(catalog_changed))

    local failed_ids, written_ids, reused = {}, {}, 0
    local wanted_set = {}
    for _, id in ipairs(wanted) do wanted_set[id] = true end

    --- Write one chapter body to the cache and record it.
    local function store_body(id, body)
        local meta = by_id[id]
        local xhtml = Content.build_chapter_xhtml(
            (meta and meta.title) or "", body, 0, id)
        local ok, werr = Content.write_atomic(self:chapter_path(key, id), xhtml)
        if ok then
            written_ids[#written_ids + 1] = id
            if not self:format_ok(key) then self:mark_format(key) end
            return true
        end
        logger.err("download write failed", tostring(id), tostring(werr))
        return false
    end

    --- Phase A: the site's own whole-book export route.
    ---
    --- This is what makes coin-gated chapters reachable without paying. It is
    --- gated on the server's own access decision rather than assumed: only an
    --- explicit `allow == 1` is acted on, so a book the account may not export
    --- falls through to the per-chapter path instead of being attempted.
    ---
    --- Nothing here purchases anything. unlock-chapter is never called.
    local batched, batch_requested, batch_written = {}, {}, {}
    local function fetch_via_export_route()
        if not export_allowed or not client.fetchBookDownloadChapters then
            return false, "route_unavailable"
        end
        local requested_ids = {}
        for _, id in ipairs(wanted) do
            if export_manifest[id] then
                requested_ids[#requested_ids + 1] = id
                batch_requested[id] = true
            end
        end
        if #requested_ids == 0 then
            return false, "no_requested_ids_in_export_manifest"
        end
        logger.info("download: free export route allowed; revision=",
            export_revision, "requested=", tostring(#requested_ids))
        if context.checkCancelled then context.checkCancelled() end
        -- 这一步是**一次性取回全部章节正文**（服务端整本导出路由，超时 300 秒），
        -- 期间没有任何 done/total 可报。原来一句话都不说，弹窗从"正在获取目录"
        -- 直接静默到好几分钟，读者只会理解成"卡死了/失败了"。
        if context.emit then
            context.emit{ stage = "export_route",
                message = string.format("正在一次性取回 %d 章正文（最长 5 分钟）",
                    #requested_ids) }
        end
        local data, derr = client:fetchBookDownloadChapters(book_id, requested_ids,
            { timeout = 300 })
        if not data or type(data.list) ~= "table" then
            return false, "fetch_failed:" .. tostring(derr)
        end
        local rows = data.list
        -- Captured before the loop empties `rows` (which IS data.list), because
        -- a table with holes has an undefined `#`.
        local total_rows = #rows
        local got = 0
        for index = 1, total_rows do
            if context.checkCancelled then context.checkCancelled() end
            local row = rows[index]
            rows[index] = nil
            local cid = tonumber(row and row.chapter_id)
            if cid and batch_requested[cid] and batched[cid] == nil then
                local snapshot = row.body_snapshot or {}
                local body = Content.chapter_body_html(
                    { body_snapshot = snapshot,
                      legacy_resources = row.legacy_resources }, nil)
                if body and body:gsub("%s", "") ~= "" then
                    -- Commit each row immediately, not after the whole response
                    -- has been decoded. A pause/power cut halfway through a large
                    -- batch then leaves atomic chapter files on disk, and the next
                    -- run only asks for ids still missing.
                    if store_body(cid, body) then
                        batched[cid] = true
                        batch_written[cid] = true
                        got = got + 1
                    else
                        logger.err("download: export route body could not be stored",
                            tostring(cid))
                    end
                end
            end
            if context.emit then
                context.emit{ done = index, total = total_rows, written = got,
                    failed = 0, stage = "export_route" }
            end
        end
        logger.info("download: export route returned", tostring(got),
            "of", tostring(#wanted), "requested")
        return got > 0, got > 0 and nil or "empty_bodies"
    end

    -- Fetch one chapter, retrying only transport-looking failures.
    local function fetch_body(id)
        local last_reason = "no_detail"
        for attempt = 1, MAX_CHAPTER_ATTEMPTS do
            local detail, detail_err = client:fetchWebChapterDetail(book_id, id,
                { timeout = 60 })
            if detail then
                local body = Content.chapter_body_html(detail, nil)
                if body:gsub("%s", "") ~= "" then
                    return body, nil, attempt
                end
                last_reason = "empty_body"
            else
                last_reason = detail_err or "no_detail"
            end
            if attempt >= MAX_CHAPTER_ATTEMPTS
                or not is_retryable_reason(last_reason) then
                return nil, last_reason, attempt
            end
            local delay = RETRY_BASE_DELAY_SECONDS * (2 ^ (attempt - 1))
            logger.warn("download: chapter", tostring(id), "attempt",
                tostring(attempt), "failed, retrying in", tostring(delay),
                "seconds; reason:", tostring(last_reason))
            -- context.sleep is the worker's cancellable sleep; absent in tests
            -- and in a direct call, where the backoff is not worth blocking for.
            if type(context.sleep) == "function" then context.sleep(delay) end
            if context.checkCancelled then context.checkCancelled() end
        end
        return nil, last_reason, MAX_CHAPTER_ATTEMPTS
    end

    -- checkCancelled raises. Wrapped so the state file is still published when
    -- it does -- otherwise a cancelled or power-cut run reports nothing and the
    -- chapters it did write look like they were never attempted.
    -- `completed` is pcall's success flag: false means we were interrupted.
    local completed, interrupt_err = pcall(function()
        -- Phase A runs inside the same protected block so a cancellation during a
        -- multi-hundred-kilobyte response still publishes state.
        local batch_reason
        if #wanted > 0 then
            local ok_batch, why = fetch_via_export_route()
            if not ok_batch then batch_reason = why end
        end
        logger.info("download: export route outcome=",
            tostring(batch_reason or "used"))

        for index, id in ipairs(wanted) do
            if context.checkCancelled then context.checkCancelled() end
            local meta = by_id[id]
            if not meta then
                failed_ids[#failed_ids + 1] = id
                logger.err("download: chapter missing from catalog", tostring(id))
            elseif batch_written[id] then
                -- Already atomically stored and counted in written_ids by Phase A.
            elseif not context.force and self:is_cached(key, id) then
                -- An earlier attempt wrote this file and died before reporting.
                -- Counted as already-have-it, never re-fetched: overwriting a good
                -- body is pure loss.
                reused = reused + 1
            elseif not meta._readable and not export_manifest[id] then
                -- Never fall back to the per-chapter detail endpoint for a
                -- coin-gated chapter. That endpoint may return a lock refusal,
                -- and this path is explicitly not allowed to unlock or purchase.
                -- No explicit free export entitlement was confirmed for this ID.
                locked_skipped_ids[#locked_skipped_ids + 1] = id
                logger.warn("download: coin chapter not returned by free export route;",
                    "safely skipped", tostring(id))
            elseif not meta._readable then
                -- The free manifest explicitly authorized this coin chapter, but
                -- the batch response omitted it or failed. Never probe the paid
                -- single-chapter endpoint; record a failure so the next tap retries
                -- the free route rather than falsely marking the download complete.
                failed_ids[#failed_ids + 1] = id
                logger.warn("download: free export route omitted authorized coin chapter",
                    tostring(id))
            else
                -- Not covered by the export route (it declined, failed, or simply
                -- omitted this chapter). Fall back to the per-chapter read, which
                -- still has the bounded retry.
                local body, reason, attempts = fetch_body(id)
                if body then
                    if not store_body(id, body) then
                        failed_ids[#failed_ids + 1] = id
                    end
                else
                    failed_ids[#failed_ids + 1] = id
                    logger.warn("download: web chapter body unavailable",
                        tostring(id), tostring(reason), "attempts=",
                        tostring(attempts))
                end
            end
            if context.emit then
                context.emit{ done = index, total = #wanted,
                    written = #written_ids, failed = #failed_ids }
            end
        end
    end)

    publish_state(completed, #written_ids, failed_ids, locked_skipped_ids)

    if not completed then
        -- Re-raise so the worker still reports the cancellation to its caller.
        error(interrupt_err, 0)
    end

    return { revision = revision, total = catalog.total_chapters,
        readable_total = #readable_ids, downloadable_total = #chapters,
        written = #written_ids,
        -- Everything in the catalogue that this run did not have to fetch, plus
        -- the files an earlier interrupted run had already written. Measured
        -- against the whole catalogue, not the readable subset: `wanted` can now
        -- be LARGER than `readable_ids` (coin chapters are fetched too), and the
        -- old subtraction went negative and reported a nonsense skip count.
        skipped = (#chapters - #wanted) + reused,
        failed = #failed_ids, failed_ids = failed_ids,
        locked_skipped = #locked_skipped_ids,
        locked_skipped_ids = locked_skipped_ids,
        complete = completed and #failed_ids == 0 and #locked_skipped_ids == 0,
        cached = false,
        catalog_changed = catalog_changed, chapters = chapters,
        volumes = catalog.volumes }
end

function Cache:download_whole_book(client, book, context)
    context = context or {}
    local force = context.force == true
    local book_id = tonumber(book and book.book_id)
    local key = book and book.key
    if not book_id or book_id <= 0 or not key then
        return { error = "bad_book" }
    end

    local function checkCancelled()
        if context.checkCancelled then
            context.checkCancelled()
        end
    end

    if client.uses_web_catalog_download then
        return self:download_web_catalog_book(client, book, context)
    end

    -- Step 1 -------------------------------------------------------------
    local access, aerr = client:checkBookDownloadAccess(book_id, { timeout = 30 })
    if not access then
        return { error = "access_failed:" .. tostring(aerr) }
    end
    -- The web client uses the same truthiness test on `allow`.
    if tonumber(access.allow) ~= 1 then
        return { error = "not_allowed:" .. tostring(access.reason_code
            or access.policy or "unknown") }
    end

    -- Step 2 -------------------------------------------------------------
    local prep, perr = client:prepareBookDownload(book_id, { timeout = 60 })
    if not prep then
        return { error = "prepare_failed:" .. tostring(perr) }
    end
    local revision = tostring(prep.revision or "")
    local chapter_ids = prep.chapter_ids or {}
    if #chapter_ids == 0 then
        return { error = "empty_chapter_list" }
    end

    -- revision is a content hash: unchanged means the cached copy is current.
    local state_path = self:_book_dir(key) .. "/download_state.lua"
    local previous = nil
    if lfs.attributes(state_path, "mode") == "file" then
        local ok, data = pcall(dofile, state_path)
        if ok and type(data) == "table" then previous = data end
    end
    if previous and previous.revision == revision and previous.complete
        and tonumber(previous.total) == #chapter_ids then
        local all_cached = true
        for _, id in ipairs(chapter_ids) do
            if not self:is_cached(key, id) then
                all_cached = false
                break
            end
        end
        if all_cached then
            return { revision = revision, total = #chapter_ids, written = 0,
                     skipped = #chapter_ids, cached = true }
        end
    end

    -- Step 3 -------------------------------------------------------------
    -- Only the chapters that are actually missing are requested.
    --
    -- This used to pass the whole chapter_ids list every time, so pressing
    -- "cache whole book" on a serial that already had 52 of 53 chapters
    -- re-downloaded and rewrote all 52 -- on e-ink, over a metered connection.
    -- `fetchBookDownloadChapters` takes an explicit id list precisely so this
    -- can be incremental. When `force` is set (a revision change means bodies
    -- may have been edited) everything is fetched again.
    local wanted = chapter_ids
    if not force then
        wanted = {}
        for _i, id in ipairs(chapter_ids) do
            if not self:is_cached(key, id) then
                wanted[#wanted + 1] = id
            end
        end
    end
    if #wanted == 0 then
        return { revision = revision, total = #chapter_ids, written = 0,
                 skipped = #chapter_ids, failed = 0, cached = true,
                 chapters = {} }
    end
    logger.info("download: fetching", tostring(#wanted), "of",
        tostring(#chapter_ids), "chapters", force and "(forced)" or "(incremental)")

    -- One request carries the batch. The decoded table is large, so the rows are
    -- consumed and released one at a time below instead of being copied into a
    -- second structure.
    local data, derr = client:fetchBookDownloadChapters(book_id, wanted,
        { timeout = 300 })
    if not data then
        return { error = "fetch_failed:" .. tostring(derr) }
    end
    local rows = data.list or {}
    if #rows == 0 then
        return { error = "empty_content" }
    end
    -- Captured before the loop empties `rows` (which is `data.list` itself) to
    -- release each row early; see the emit at the bottom of the loop.
    local total_rows = #rows

    local chapters, written, failed = {}, 0, 0
    local wanted_set, returned_set = {}, {}
    for _i, id in ipairs(wanted) do
        local n = tonumber(id)
        if n and n > 0 then wanted_set[n] = true end
    end
    for i = 1, #rows do
        checkCancelled()
        local row = rows[i]
        local cid = tonumber(row.chapter_id)
        if cid and cid > 0 and wanted_set[cid] and not returned_set[cid] then
            returned_set[cid] = true
            local snapshot = row.body_snapshot or {}
            -- Batch downloads may return rendered body_html / legacy resource
            -- maps as well as body_text. Prefer the same safe body converter as
            -- the single-chapter path so image URLs and [res]ext tokens survive.
            local detail = {
                body_snapshot = snapshot,
                legacy_resources = row.legacy_resources
                    or row.legacyResources,
            }
            local has_resource_tokens = tostring(snapshot.body_text or "")
                    :find("%[res%]ext:") ~= nil
                or tostring(snapshot.body_html or ""):find("%[res%]ext:") ~= nil
            if has_resource_tokens and client.fetchChapterDetail then
                local fetched, detail_err = client:fetchChapterDetail(
                    book_id, cid, { timeout = 60 })
                if fetched then
                    -- Keep the authorized batch body as the content source; the
                    -- per-chapter call supplements only resource mappings and
                    -- must not replace a full batch body with a preview.
                    detail = fetched
                    detail.body_snapshot = snapshot
                else
                    logger.warn("download: image resource detail unavailable",
                        "chapter=", tostring(cid), "err=", tostring(detail_err))
                end
            end
            local body = Content.chapter_body_html(detail, nil)
            if body:gsub("%s", "") == "" then
                body = Content.text_to_html(snapshot.body_text or "")
            end
            if body:gsub("%s", "") == "" then
                failed = failed + 1
            else
                local xhtml = Content.build_chapter_xhtml(
                    tostring(row.title or ""), body, 0, cid)
                local ok, werr = Content.write_atomic(
                    self:chapter_path(key, cid), xhtml)
                if ok then
                    written = written + 1
                else
                    failed = failed + 1
                    logger.err("download write failed chapter=",
                        tostring(cid), tostring(werr))
                end
            end
            chapters[#chapters + 1] = {
                index = #chapters + 1,
                aid = cid,
                book_id = book_id,
                volume_id = tonumber(row.volume_id) or 0,
                volume_title = tostring(row.volume_title or ""),
                volume_chapter_no = tonumber(row.volume_chapter_no) or 0,
                title = tostring(row.title or ""),
                words = tonumber(row.word_count) or 0,
                locked = (tonumber(row.locked) or 0) == 1
                    and (tonumber(row.unlocked) or 0) == 0,
                unlocked = (tonumber(row.unlocked) or 0) == 1,
                access_type = tostring(row.access_type or ""),
                coin_price = tonumber(row.coin_price) or 0,
            }
        end
        -- Drop the reference so the row can be collected while the rest decode.
        -- `rows` IS `data.list` (same table), so after a few iterations that table
        -- has holes and its `#` is undefined -- Lua may answer 0 or any partial
        -- length. The progress emit used that value, so the parent's progress bar
        -- showed a total that drifted downwards as the download ran. `total_rows`
        -- was captured before the loop for exactly this reason.
        rows[i] = nil
        if context.emit then
            context.emit{ done = i, total = total_rows, written = written,
                          failed = failed }
        end
    end

    -- A successful HTTP response can still be partial. Do not mark the server
    -- download state complete unless every requested chapter was returned.
    for cid in pairs(wanted_set) do
        if not returned_set[cid] then
            failed = failed + 1
            logger.err("download response omitted requested chapter", tostring(cid))
        end
    end

    -- Step 4 -------------------------------------------------------------
    local summary = {
        revision = revision,
        total = #chapter_ids,
        written = written,
        failed = failed,
        cover = nil,
        saved_at = os.time(),
    }

    local cover = self:_cache_cover(client, prep.cover_url, key)
    if cover then
        summary.cover = cover
    end

    write_download_state(state_path, {
        revision = revision,
        total = #chapter_ids,
        written = written,
        failed = failed,
        complete = failed == 0,
        saved_at = os.time(),
    })

    return { revision = revision, total = #chapter_ids, written = written,
             skipped = #chapter_ids - written, failed = failed,
             cover = summary.cover, chapters = chapters }
end

--- Fetch one cover into the plugin's cover directory.
--- The URL carries a signature (?m=<token>&t=<expiry>) and MUST be used
--- verbatim; rebuilding it from the path alone yields a 403.
---
--- The logic lives in Cover.download because the bookshelf needs the same thing
--- from a different direction: every shelf entry carries a `cover_url`, and until
--- this was shared only a whole-book download ever fetched one -- so a shelf of
--- ten books showed exactly one cover, the one whose body happened to be cached.
---
--- This code only ever runs inside a subprocess, and the thumbnail is rendered
--- here too, in the same run: decoding + scaling a cover on the UI thread is what
--- makes a shelf of covers unusable on e-ink. Failures are non-fatal -- the
--- original is what the UI falls back to.
function Cache:_cache_cover(client, url, key)
    return Cover.download(client, key, url)
end

return Cache
