--[[--
Comment sync controller.

Ties together the client (network), the store (SQLite) and the worker
(subprocess). The controller owns two responsibilities:

  * background sync: fetch every page for a set of aids inside one worker task
    and write the rows to SQLite from the parent process
  * on-demand refresh: fetch a single aid in the foreground because the user
    explicitly asked for fresh comments

The child process only performs HTTP. SQLite writes happen in the parent so a
reader popup reading the same database never races the writer.
--]]--

local _ = require("gettext")
local logger = require("lightnovel.lib.logger")
local CommentStore = require("lightnovel.lib.comment_store")
local Content = require("lightnovel.lib.content")

local Sync = {}
Sync.__index = Sync

-- Marker rewrites read, rewrite and rename a whole chapter file (50-200 KB).
-- The store loop used to call on_count_changed inline, so an 83-chapter book did
-- 83 transactions + 83 count() scans + 83 full-file rewrites inside ONE UIManager
-- timer callback: a multi-second freeze at exactly the moment the reader asked to
-- cache the comments. Three files per tick keeps the event loop turning.
local MARKERS_PER_TICK = 3
local MARKER_TICK_MS = 60

--- Rewrite the "[N 条评论]" links of the given chapters, a few per UI tick.
--- `pending` is a list of { aid = number, count = number }.
function Sync:_drain_markers(pending)
    if type(pending) ~= "table" or #pending == 0 then return end
    local notify_count = self.on_count_changed
    if not notify_count then return end
    -- Required lazily: this module is loaded standalone by the offline tests,
    -- which have no UIManager.
    local scheduler = self.scheduler or require("ui/uimanager")
    local queue, index, failed = pending, 0, 0
    local step
    step = function()
        local last = math.min(index + MARKERS_PER_TICK, #queue)
        while index < last do
            index = index + 1
            local item = queue[index]
            if not pcall(notify_count, item.aid, item.count) then
                failed = failed + 1
                logger.warn("comment sync: marker update failed for aid",
                    tostring(item.aid))
            end
        end
        if index < #queue then
            scheduler:scheduleIn(MARKER_TICK_MS, step)
        elseif failed > 0 then
            logger.warn("comment sync: marker updates failed for",
                tostring(failed), "chapters")
        end
    end
    scheduler:scheduleIn(0, step)
end

function Sync:new(options)
    local obj = setmetatable({
        client = assert(options.client, "client required"),
        worker = assert(options.worker, "worker required"),
        settings = options.settings,
        get_book_dir = assert(options.get_book_dir, "get_book_dir required"),
        -- Keep the two ID spaces in different SQLite files as defense in depth;
        -- old releases may already have polluted comments.db with chapter_id rows.
        store_namespace = options.store_namespace,
        -- Legacy /api/discuss/get-topic accepts legacy article ids only. New
        -- shelf chapters carry book_id/chapter_id from a different id space;
        -- callers must disable this controller until the new comment contract
        -- is wired, or it will cache another book's comments.
        comments_supported = options.comments_supported,
        -- Called with (aid, count) after the marker count changes so the cached
        -- chapter can be rewritten without reopening the reader.
        on_count_changed = options.on_count_changed,
        notify = options.notify,
    }, self)
    return obj
end

local function sync_namespace(self)
    if type(self.store_namespace) == "function" then
        return self.store_namespace()
    end
    return self.store_namespace
end

function Sync:db()
    return CommentStore.open(self:get_book_dir(), sync_namespace(self))
end

--- Comments per request. The API rejects pageSize below 20 with code 3, so the
--- configured value is clamped instead of trusted.
function Sync:page_size()
    local n = tonumber(self.settings:get("cache.comment_page_size")) or 20
    if n < 20 then n = 20 end
    -- The API rejects pageSize above 50 with
    -- {"code":3,"data":{"pageSize":["Page Size的值必须不大于50"]}}. The clamp
    -- said 100, so any configured value in (50,100] produced code 3 for EVERY
    -- chapter -- a whole-book sync that stored nothing and reported failures
    -- rather than "your setting is too large".
    if n > 50 then n = 50 end
    return n
end

--- Queue a background sync for the given aids (usually the cached chapters of
--- the book currently open). Returns false when the worker is unavailable.
---
--- Everything here used to be silent: the failure path only raised an InfoMessage,
--- so a sync that died halfway left nothing in crash.log and there was no way to
--- tell a timeout from a network error from an empty chapter. The whole history
--- of crash.log contains not one line from this module.
function Sync:queue_background(aids, options)
    options = options or {}
    if self.comments_supported and not self.comments_supported() then
        logger.warn("comment sync: disabled for new-content book; refusing legacy aid lookup")
        if self.notify then self.notify("新书评论接口尚未接入，已阻止旧接口串书") end
        return false, "unsupported_new_content_comments"
    end
    if type(aids) ~= "table" or #aids == 0 then
        logger.warn("comment sync: no aids given")
        return false, "no_aids"
    end
    if not self.worker:available() then
        logger.err("comment sync: worker unavailable")
        if self.notify then self.notify("评论同步不可用：设备不支持后台进程") end
        return false, "worker_unavailable"
    end

    local client = self.client
    local book_dir = self:get_book_dir()
    -- Snapshot namespace together with book_dir; the user may switch books while
    -- the worker runs, and reading `self.current_book` in its callback could then
    -- write to the captured path using the other book's namespace.
    local store_namespace = sync_namespace(self)
    -- Snapshot the list so the child does not iterate a live table.
    local targets = {}
    -- NOT `for _, aid`: this file requires gettext as `_`, and a loop variable
    -- of that name makes it a number inside the body. The SELF_FIELDS check in
    -- check_api_contract.py exists for exactly this and caught it here.
    for _index, aid in ipairs(aids) do
        targets[#targets + 1] = tonumber(aid)
    end
    local page_size = self:page_size()
    local timeout = tonumber(options.timeout) or 300
logger.info("comment sync: start chapters=", tostring(#targets),
        "page_size=", tostring(page_size), "timeout=", tostring(timeout))
    local started_at = os.time()

    -- Hoisted out of the worker:start table below because the caller's chain hook
    -- has to run on EVERY exit, not just the happy one. The handler returns early
    -- on worker failure, on "nothing collected" and on "store unavailable", and
    -- every one of those skips options.on_done -- so a caller waiting to build the
    -- EPUB after the comments landed would wait forever on a book whose comments
    -- failed. Returns the number of chapters stored, 0 on those early exits.
    local settle = function(result)
        if not result or not result.ok then
            local reason = result and result.error or "unknown"
            logger.err("comment sync: failed. reason=", tostring(reason),
                "chapters=", tostring(#targets),
                "elapsed=", tostring(os.time() - started_at), "s")
            if not (result and result.cancelled) and self.notify then
                self.notify("评论同步失败：" .. tostring(reason))
            end
            return 0
        end
            local value = result.value or {}
            local items = value.items or {}
            local stats = value.stats or {}
            logger.info("comment sync: done chapters=", tostring(#targets),
                "with_comments=", tostring(stats.with_comments or #items),
                "empty=", tostring(stats.empty or 0),
                "failed=", tostring(stats.failed or 0),
                "comments=", tostring(stats.comments or 0),
                "elapsed=", tostring(os.time() - started_at), "s")
            -- The first few failures are what tells "stopped halfway" apart from
            -- "this chapter genuinely has no comments".
            local sample = {}
            for index, reason in ipairs(stats.errors or {}) do
                if index > 3 then break end
                sample[#sample + 1] = tostring(reason)
            end
            if #sample > 0 then
                logger.warn("comment sync: sample failures:", table.concat(sample,
                    " | "))
            end
            if #items == 0 then
                logger.warn("comment sync: nothing collected for",
                    tostring(#targets), "chapters")
                if self.notify then
                    self.notify("未获取到评论（网络异常或该章节暂无评论）")
                end
                return 0
            end

            local db = CommentStore.open(book_dir, store_namespace)
            if not db then
                logger.warn("comment sync cannot open store")
                if self.notify then self.notify("评论存储不可用") end
                return 0
            end
            local written = 0
            local pending = {}
            -- `_` is gettext in this file; see the note above.
            for _index, group in ipairs(items) do
                local aid = tonumber(group.aid)
                if aid then
                    local stored = CommentStore.put_comments(db, aid,
                        group.comments or {}, {
                            total = group.total,
                            page = group.page,
                            complete = group.complete,
                        })
                    if stored then
                        written = written + 1
                        -- Record the count, do not touch the chapter file yet:
                        -- see _drain_markers.
                        pending[#pending + 1] = {
                            aid = aid,
                            count = CommentStore.count(db, aid),
                        }
                    end
                end
            end
            CommentStore.close(db)
            self:_drain_markers(pending)
            logger.info("comment sync: stored chapters=", tostring(written),
                "of", tostring(#targets))

            if self.notify then
                -- Say what actually happened, including the parts that did not.
                -- "评论已缓存：N 章" used to hide every failure.
                local text = string.format(_("评论已缓存：%d/%d 章"), written,
                    #targets)
                if (stats.failed or 0) > 0 then
                    text = text .. string.format(_("（%d 章取失败）"),
                        stats.failed)
                end
                self.notify(text)
            end
            if options.on_done then
                pcall(options.on_done, written)
            end
            return written
        end

    local ok, err = self.worker:start{
        queue = true,
        -- 评论同步是"下载入库"链里的一环：排队期间不能被背景封面任务挤掉，
        -- 否则 on_finished 里的导出一旦跟着失败，读者会看到一个莫名的"导出失败"。
        protect = true,
        timeout = timeout,
        on_progress = function(state)
            if options.on_progress then
                pcall(options.on_progress, state)
            end
        end,
        on_done = function(result)
            local written = settle(result)
            -- Fires on every exit, including the failure ones. This is what lets
            -- the EPUB be built after the comments are in the database instead of
            -- racing them: the worker runs one job at a time, so the next stage
            -- cannot be queued until this one is over.
            if type(options.on_finished) == "function" then
                pcall(options.on_finished, result, written)
            end
        end,
        task = function(context)
            local collected = {}
            local stats = { with_comments = 0, empty = 0, failed = 0,
                comments = 0, errors = {} }
            for index, aid in ipairs(targets) do
                context.checkCancelled()
                -- Emit BEFORE the request, not only after a successful page.
                -- The worker's timeout is a no-progress gap, and a chapter with
                -- fewer comments than one page breaks out of the loop without
                -- ever reaching the old emit -- so a book whose chapters mostly
                -- have few comments produced almost no progress and the whole
                -- batch was killed at the timeout, which is what "comments stop
                -- halfway" looked like. Now the worst gap is one request.
                context.emit{ stage = "chapter", index = index,
                    total = #targets, aid = aid, page = 0, fetched = 0 }
                local page = 1
                local all = {}
                local total = 0
                local complete = false
                local failure = nil
                local seen_first = {}
                while true do
                    context.checkCancelled()
                    local data = client:fetchComments(aid, page, {
                            timeout = 30,
                            page_size = page_size,
                        })
                    if not data then
                        -- A single failing chapter must not abort the batch, but
                        -- the reason is kept so the parent can report it.
                        failure = "request_failed"
                        break
                    end
                    local list = data.list or {}
                    -- The server's real comment count lives at
                    -- data.page_info.count, NOT data.total (see
                    -- tests/test_live_pipeline.py, which reads it off a live
                    -- response). Reading data.total yielded nil, so `total`
                    -- collapsed to 0 and every consumer then reported "#all",
                    -- which silently disabled the "this cache is incomplete"
                    -- disclosure in both comment_panel and epub_export.
                    local pinfo = data.page_info or {}
                    total = tonumber(pinfo.count) or tonumber(data.total) or 0
                    for position, entry in ipairs(list) do
                        local normalized = CommentStore.normalize(entry,
                            (page - 1) * page_size + position)
                        if normalized then
                            local replies = {}
                            for rindex, reply in ipairs(entry.reply_list or {}) do
                                local rn = CommentStore.normalize_reply(reply, rindex)
                                if rn then replies[#replies + 1] = rn end
                            end
                            normalized.replies_list = replies
                            all[#all + 1] = normalized
                        end
                    end
                    if #list == 0 then
                        complete = true
                        break
                    end
                    -- Follow the server's own has_next, do NOT infer the end from
                    -- a short page. Measured live: with page_size=50 the API
                    -- returns 49 rows for page 1 while page_info.count says 518
                    -- and has_next is still 1, and the following pages hold
                    -- entirely different rows (zero tid overlap). The old
                    -- "stop when a page comes back short" rule therefore
                    -- stopped at page 1, stored 49 of 518 comments, and still
                    -- reported the chapter complete.
                    local has_next = tonumber(pinfo.has_next) or 0
                    if has_next == 0 then
                        complete = true
                        break
                    end
                    -- Guard against a server that ignores `page`: if a page ever
                    -- starts where the previous one started, we are looping.
                    local first_tid = tostring(list[1].tid or "")
                    if first_tid ~= "" and seen_first[first_tid] then
                        logger.warn("comment sync: aid", tostring(aid),
                            "page", tostring(page), "repeated; stopping")
                        break
                    end
                    if first_tid ~= "" then
                        seen_first[first_tid] = true
                    end
                    page = page + 1
                    -- Hard bound so a misbehaving server cannot loop forever.
                    -- Deliberately NOT complete: we stopped because of our own
                    -- cap, not because the chapter ran out, so the cache must
                    -- keep saying so or the panel and the EPUB would present a
                    -- truncated comment list as the whole thing.
                    if page > 50 then
                        complete = false
                        logger.warn("comment sync: aid", tostring(aid),
                            "hit the 50-page cap; cache marked incomplete")
                        break
                    end
                    context.emit{ stage = "page", index = index,
                        total = #targets, aid = aid, page = page, fetched = #all }
                end
                if #all > 0 then
                    stats.with_comments = stats.with_comments + 1
                    stats.comments = stats.comments + #all
                    collected[#collected + 1] = {
                        aid = aid,
                        comments = all,
                        total = total > 0 and total or #all,
                        page = page,
                        complete = complete,
                    }
                else
                    if failure then
                        stats.failed = stats.failed + 1
                        if #stats.errors < 8 then
                            stats.errors[#stats.errors + 1] =
                                string.format("aid=%s page=%d", tostring(aid), page)
                        end
                    else
                        stats.empty = stats.empty + 1
                    end
                end
            end
            return { items = collected, stats = stats }
        end,
    }
    if not ok then
        logger.err("comment sync: cannot start. reason=", tostring(err or "?"))
        if self.notify then
            self.notify("无法启动后台缓存：" .. tostring(err or "unknown"))
        end
        return false, err
    end
    return true
end

--- Fetch one article's comments right now and persist them.
-- Used when the reader asks for a refresh; still routed through the worker so
-- the UI is never blocked.
function Sync:refresh_one(aid, options)
    options = options or {}
    if self.comments_supported and not self.comments_supported() then
        logger.warn("comment refresh: disabled for new-content book; refusing legacy aid lookup")
        if self.notify then self.notify("新书评论接口尚未接入，已阻止旧接口串书") end
        return false, "unsupported_new_content_comments"
    end
    if not self.worker:available() then
        return false, "worker_unavailable"
    end
    local target = tonumber(aid)
    if not target then
        return false, "invalid_aid"
    end
    local client = self.client
    local book_dir = self:get_book_dir()
    local store_namespace = sync_namespace(self)
    local notify = self.notify

    return self.worker:start{
        timeout = 90,
        -- Queue rather than fail. Without this the worker answers
        -- "worker_busy" whenever a whole-book comment sync is running, so tapping
        -- 刷新评论 during one -- which is exactly when a reader wants fresh
        -- comments for the chapter they are on -- was impossible.
        queue = true,
        protect = true,
        on_done = function(result)
            if not result or not result.ok then
                local reason = result and result.error or "unknown"
-- Cancellation is signalled by result.cancelled, and its `error` is one of
    -- "cancelled", "replaced" (a newer queued job evicted this one) or
    -- "superseded" (background_worker.lua:298-316). Testing the string against
    -- "cancelled" alone therefore reported a normal queue eviction to the reader
    -- as "评论刷新失败：replaced" for work that never even started.
    if notify and not (result and result.cancelled) then
        notify("评论刷新失败：" .. tostring(reason))
                end
                if options.on_done then pcall(options.on_done, false, reason) end
                return
            end
            local group = (result.value or {}).items
            local entry = group and group[1]
            local db = CommentStore.open(book_dir, store_namespace)
            if not db then
                if notify then notify("评论存储不可用") end
                if options.on_done then pcall(options.on_done, false, "store") end
                return
            end
            local ok = false
            -- Always write the meta row, even for a chapter with genuinely zero
            -- comments. It used to be skipped when the list was empty, so
            -- fetched_at stayed 0, needs_refresh() returned true forever, and the
            -- panel kept saying "评论未缓存，用左上角菜单刷新" for a chapter that
            -- was fully synced and genuinely empty. queue_background already
            -- writes unconditionally.
            ok = CommentStore.put_comments(db, target, entry and entry.comments or {}, {
                total = entry and entry.total, page = entry and entry.page,
                complete = entry and entry.complete,
            })
            local count = CommentStore.count(db, target)
            CommentStore.close(db)
            if ok and self.on_count_changed then
                pcall(self.on_count_changed, target, count)
            end
            if options.on_done then
                pcall(options.on_done, ok, nil, count)
            end
        end,
        task = function(context)
            local page = 1
            local all = {}
            local total = 0
            local complete = false
            -- Snapshot the page size ONCE. It used to be recomputed three times per
            -- page, independently: the request was sized with one value while
            -- item_index was computed with another, so a settings change
            -- mid-refresh (评论每页条数 in the menu) produced duplicate and gapped
            -- indices -- and `ORDER BY item_index` then interleaved the pages
            -- wrongly. queue_background already does this at :120.
            local ps = self:page_size()
            local seen_first = {}
            while true do
                context.checkCancelled()
                local data = client:fetchComments(target, page, {
                    timeout = 30,
                    page_size = ps,
                })
                -- Without an emit the worker's last_progress_at never moves and it
                -- SIGKILLs the child at the 90s timeout, discarding every comment
                -- already fetched. A chapter with more than ~3 pages always hit
                -- that. queue_background emits per page for the same reason.
                context.emit{ stage = "page", page = page, fetched = #all }
                if not data then break end
                local list = data.list or {}
                local pinfo = data.page_info or {}
                total = tonumber(pinfo.count) or tonumber(data.total) or 0
                for index, entry in ipairs(list) do
                    local normalized = CommentStore.normalize(entry,
                        (page - 1) * ps + index)
                    if normalized then
                        local replies = {}
                        for rindex, reply in ipairs(entry.reply_list or {}) do
                            local rn = CommentStore.normalize_reply(reply, rindex)
                            if rn then replies[#replies + 1] = rn end
                        end
                        normalized.replies_list = replies
                        all[#all + 1] = normalized
                    end
                end
                -- Same rule as queue_background: trust page_info.has_next rather
                -- than a short page, because the API really does answer 49 rows
                -- for page_size 50 and then keep going.
                if #list == 0 then
                    complete = true
                    break
                end
                if (tonumber(pinfo.has_next) or 0) == 0 then
                    complete = true
                    break
                end
                local first_tid = tostring(list[1].tid or "")
                if first_tid ~= "" and seen_first[first_tid] then
                    logger.warn("comment refresh: aid", tostring(target),
                        "repeated page; stopping")
                    break
                end
                if first_tid ~= "" then
                    seen_first[first_tid] = true
                end
                page = page + 1
                -- Our own cap, so NOT complete: say the cache is a truncation.
                if page > 50 then
                    complete = false
                    logger.warn("comment refresh: aid", tostring(target),
                        "hit the 50-page cap; cache marked incomplete")
                    break
                end
            end
            return {
                items = {
                    { aid = target, comments = all,
                      total = total > 0 and total or #all,
                      page = page, complete = complete },
                },
            }
        end,
    }
end

return Sync
