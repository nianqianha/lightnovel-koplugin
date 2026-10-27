--[[--
LightNovel — read 轻之国度 light novels in KOReader with cached comments.

Entry point. Wires the client, cache, comment store, background worker and the
UI screens together, then routes:

    library -> catalog -> chapter file -> reader (+ comment panel)

All network work runs in a forked worker; the UI process only ever writes
LuaSettings and SQLite, so a slow request cannot freeze the reader.
--]]

local _ = require("gettext")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
-- Needed by confirmUnlock(): spending 轻币 always goes through a ConfirmBox so
-- the cost is stated before any currency moves.
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ReaderUI = require("apps/reader/readerui")
-- There is NO global Screen: both reference plugins bind it locally from the
-- device module (weread/zenui.lua:53-64, fanqie/bookshelf.lua:6). The previous
-- code used a bare `Screen` at line 143 while the only `local Screen` sat at
-- line 437 inside a function, so login died with
-- "attempt to index global 'Screen' (a nil value)".
local Screen = require("device").screen
local lfs = require("libs/libkoreader-lfs")

local logger = require("lightnovel.lib.logger")

local BookCatalog = require("lightnovel.lib.book_catalog")
local Cache = require("lightnovel.lib.chapter_cache")
local Client = require("lightnovel.lib.client")
local CommentStore = require("lightnovel.lib.comment_store")
local CommentSync = require("lightnovel.lib.comment_sync")
local Content = require("lightnovel.lib.content")
local Cover = require("lightnovel.lib.cover")
local Export = require("lightnovel.lib.epub_export")
local Settings = require("lightnovel.lib.settings")
local SelfCheck = require("lightnovel.lib.selfcheck")
local Worker = require("lightnovel.lib.background_worker")

local CommentPanel = require("lightnovel.ui.comment_panel")
local LibraryView = require("lightnovel.ui.library_view")
local Menu = require("lightnovel.ui.menu")
local ReaderHooks = require("lightnovel.ui.reader_hooks")
local TaskDialog = require("lightnovel.ui.task_dialog")

-- 模块级自检状态：插件实例在阅读器⇄文件管理器切换时会被重建（见
-- KOReader 平台坑），实例字段 selfcheck_done 会随之丢失，导致每次切换后
-- 第一次开菜单都重跑自检（并触发一张阻塞式诊断截图，实测每次 1-2 s）。
-- 放在模块级表里，require 缓存让它在整个进程内只跑一次。
local SELFCHECK_STATE = { done = false }

-- 进度诊断日志的配额（b39）。读者报"下载弹窗不显示进度"，但只有两条可能：
-- (a) 弹窗根本没收到进度载荷；(b) 收到了但没重绘。代码看着都通，只能取证。
-- 每个进程只打前 8 条，正常使用时日志里就这几行，用完即止。
-- b43：改成"每个阶段各 3 条"。原来总共只有 8 条，一次下载里 catalog + export_route
-- 就用光了，prefetch/pack 阶段一条都不剩——排查时看到的正是"导出阶段无日志"。
local PROGRESS_LOG_SEEN = {}
local PROGRESS_LOG_PER_STAGE = 3

-- 跨实例存活的任务登记（b22）。
--
-- KOReader 在阅读器 ⇄ 文件管理器切换时会重建插件实例（init 每次重跑，
-- crash.log 里连续的 BUILD 行就是它）。_task/_task_dialog/_shelf_widget 挂在
-- 实例上时，一切换就丢：菜单里「任务进度」消失、暂停中的任务无人认领、
-- 弹窗变成不响应触摸的僵尸（2026-10-24 02:00-02:04 实测：评论同步被
-- plugin_closed 取消、菜单无任务行、按暂停无反应）。挪到模块级后任务跨
-- 切换存活，弹窗在新上下文里随时可重建。
local STATE = { task = nil, dialog = nil, shelf = nil }
local TocView = require("lightnovel.ui.toc_view")

-- Defined near the reader section, but called from init(), so it needs a forward
-- declaration: Lua locals must exist before the closure that captures them.
local suppress_chapter_history

local LightNovelPlugin = WidgetContainer:extend{
    name = "lightnovel",
    is_doc_only = false,
    version = "0.2.0",
}

-- Stable entry points for SimpleUI / ZenUI launchers.
function LightNovelPlugin:openBookshelf()
    return self:showLibrary()
end

function LightNovelPlugin:launch()
    return self:openBookshelf()
end

function LightNovelPlugin:requestDiagnosticScreenshot(tag, delay)
    local tool = self.ui and self.ui.screenshottool
    if not tool or type(tool.requestDiagnosticScreenshot) ~= "function" then
        logger.dbg("diagnostic screenshot skipped: Screenshot Tool is not loaded")
        return false
    end
    local ok, scheduled = pcall(tool.requestDiagnosticScreenshot, tool, tag, delay)
    if not ok then
        logger.warn("diagnostic screenshot unavailable:", tostring(scheduled))
        return false
    end
    return scheduled and true or false
end

function LightNovelPlugin:init()
    math.randomseed(os.time())
    self.settings = Settings:new()
    self.client = Client:new(self.settings)
    self.cache = Cache:new(self.settings)
    -- worker 必须跨插件实例共享（b41）。
    --
    -- KOReader 在阅读器 ⇄ 文件管理器之间切换时会重建插件实例，init 每次重跑。
    -- 原来这里每次 new 一个 Worker：重建之后 self.worker 是**新的空壳**，而正在跑的
    -- 那个 job 还挂在旧实例的 Worker 上——于是新实例看不到进度、暂停/退出作用在
    -- 一个没有 job 的对象上返回 false（读者看到的就是"点了没反应/任务像是丢了"）。
    -- crash.log 里 23:53–23:56 三分钟内 BUILD 出现 5 次，正是一次下载被重建打断。
    -- 和 b22 的 STATE.task 同一个道理：任务归属必须放在模块级。
    STATE.worker = STATE.worker or Worker:new{
        temp_dir = self.settings:workerDir(),
        min_available_kb = 64 * 1024,
    }
    self.worker = STATE.worker
    -- Do this once, at load, before anything can be opened: from here on the
    -- per-chapter cache files never become "正在阅读" rows, and only a published
    -- whole book does. Wraps ReadHistory.addItem, is idempotent, and also sweeps
    -- the rows that are already in the list.
    local history_ok, history_err = pcall(suppress_chapter_history, self)
    if not history_ok then
        logger.err("history: suppression setup raised:", tostring(history_err))
    end

    -- Current book context, used by the comment panel and the marker rewrite.
    self.current_key = nil
    self.current_book = nil
    self.current_catalog = nil

    self.comment_sync = CommentSync:new{
        client = self.client,
        worker = self.worker,
        settings = self.settings,
        get_book_dir = function()
            return self.settings:bookDir(self.current_key or "default")
        end,
        store_namespace = function()
            return (tonumber(self.current_book and self.current_book.book_id) or 0) > 0
                and "new-content" or nil
        end,
        comments_supported = function()
            -- Legacy books use aid directly. New-content books are supported
            -- only after their catalog carries an explicit source article ID;
            -- explicit zero means this volume has no comment thread.
            if (tonumber(self.current_book and self.current_book.book_id) or 0) <= 0 then
                return true
            end
            local chapters = (self.current_catalog or {}).chapters or {}
            if #chapters == 0 then return false end
            local verified_thread = false
            for _chapter_index, chapter in ipairs(chapters) do
                -- false is an explicit reviewed exclusion for special or
                -- mismatched volumes; nil means a stale/incomplete catalog.
                if chapter.comment_aid == nil
                    or chapter.comment_mapping_verified == nil then
                    return false
                end
                if chapter.comment_mapping_verified == true
                    and (tonumber(chapter.comment_aid) or 0) > 0 then
                    verified_thread = true
                end
            end
            return verified_thread
        end,
        on_count_changed = function(aid, count)
            self:onCommentCountChanged(aid, count)
        end,
        notify = function(text)
            UIManager:show(InfoMessage:new{ text = tostring(text) })
        end,
    }

    self.hooks = ReaderHooks:new{
        show_comments = function(aid)
            return self:showComments(aid)
        end,
        is_edge_tap = function(ges)
            return self:isPageTurnZone(ges)
        end,
    }

self:registerMenu()
-- Log a build stamp on every init. KOReader only loads plugins at startup, so a
-- deploy does NOT take effect until the app is restarted; without this line
-- there is no way to tell which build the device is actually running, and a
-- stale build looks exactly like a new bug.
logger.info("BUILD b54-task-gap-diag (任务进度入口常驻; 点开无任务时记日志, 定位两阶段之间的空档; 含 b19-b53)",
    "at", tostring(os.date("%Y-%m-%d %H:%M:%S")))
logger.info("initialized version=", self.version)
end

-- ---------------------------------------------------------------- library --

function LightNovelPlugin:showLibrary(opts)
    opts = opts or {}
    return LibraryView.show{
        mode = opts.mode,
        query = opts.query,
        -- quiet: 只当背景用（下载任务的底层书架），不联网、不起加载遮罩。
        quiet = opts.quiet == true,
        client = self.client,
        -- The shelf draws a cover per row and locates it under the plugin data
        -- dir, so the Settings instance travels with the view.
        settings = self.settings,
        worker = self.worker,
        on_open_book = function(item, options)
            self:openBook(item, options)
        end,
        on_request_login = function()
            self:showLogin()
        end,
        -- Bulk backfill reachable from the shelf itself, so publishing what is
        -- already downloaded does not require opening a book first.
        on_publish_all = function()
            self:publishAllToLibrary()
        end,
        -- Raised by LibraryMenu:_open before it closes itself, so the screen is
        -- already covered when the menu goes away. Without it the file manager
        -- home is fully visible for the whole catalog fetch.
        on_begin_load = function()
            self:showSpinner(_("正在加载…"))
        end,
    }
end

--- Open the table of contents of an already cached book, without any network
--- access. Used by the cache bookshelf in the FileManager menu.
function LightNovelPlugin:showCachedToc(key, catalog)
    self.current_key = key
    self.current_catalog = catalog
    -- book_id used to be missing here, and TocMenu gates the comment,
    -- cache-whole-book and EPUB-export rows on it, so a book opened from the
    -- cached bookshelf showed a TOC with none of those actions and no error.
    self.current_book = {
        title = catalog.title or key,
        key = key,
        book_id = self.cache.book_id_from_key(key),
    }
    return self:showToc()
end

--- Login is two native InputDialogs (username, then password) instead of a
--- hand-built fullscreen view: no custom layout to get wrong, and the dialogs
--- look exactly like the rest of KOReader.
---
--- `fullscreen` is deliberately NOT set. InputDialog only sizes itself above the
--- virtual keyboard in its default mode ("adjust to full screen minus keyboard",
--- inputdialog.lua:139). With fullscreen = true it sets covers_fullscreen but
--- reserves no room for the keyboard, so the keyboard covers the buttons while
--- deny_keyboard_hiding keeps it locked open -- the form becomes unusable.
--- A modal dialog floating over the page is how every other KOReader dialog
--- looks, so that is the lesser evil.
---
--- The keyboard's enter key works because of `is_enter_default`: InputDialog's
--- default enter_callback scans the buttons for that flag and calls its callback
--- (inputdialog.lua:352-361). No custom enter_callback is needed, which also
--- avoids having to reach the dialog instance (UIManager has no getTopWidget).
function LightNovelPlugin:showLogin()
    -- Each button carries its OWN callback. buttontable.lua:82 calls
    -- `btn_entry.callback()` with no nil check, and InputDialog has no
    -- dialog-level `callback` field at all (only edited_callback), so a
    -- button defined with just `id` crashes the event loop when tapped.
    -- weread 10/10 and fanqie 16/16 dialog buttons define a callback.
    local dialog
    dialog = InputDialog:new{
        title = _("登录轻之国度"),
        description = _("第 1 步 / 共 2 步 · 输入用户名或邮箱"),
        -- No width override on purpose. inputdialog.lua:213 defaults to
        -- 0.8 * min(screen_w, screen_h) and L139 notes that non-fullscreen
        -- "adjust to full screen minus keyboard", which is what a software
        -- keyboard needs. Overriding to Screen:getWidth() - 20 made the panel
        -- nearly as wide as the screen while staying short, so the bookshelf
        -- showed above and below it. weread and fanqie set no width at all.
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("下一步"),
                    is_enter_default = true,
                    callback = function()
                        local username = (dialog:getInputValue() or "")
                            :gsub("^%s+", ""):gsub("%s+$", "")
                        if username == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("请输入用户名"),
                            })
                            return
                        end
                        UIManager:close(dialog)
                        self:_promptPassword(username)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    self:requestDiagnosticScreenshot("login1_username", 1)
end

function LightNovelPlugin:_promptPassword(username)
    local dialog
    dialog = InputDialog:new{
        title = _("登录轻之国度"),
        description = _("第 2 步 / 共 2 步 · 输入密码"),
        -- Same as step 1: no width override, so the panel sizes around the
        -- on-screen keyboard.
        -- InputDialog forwards both input_type and text_type to InputText, and
        -- InputText masks when text_type == "password" (with a reveal toggle).
        text_type = "password",
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("登录"),
                    is_enter_default = true,
                    callback = function()
                        local password = dialog:getInputValue() or ""
                        if password == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("请输入密码"),
                            })
                            return
                        end
                        UIManager:close(dialog)
                        self:_doLogin(username, password)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    self:requestDiagnosticScreenshot("login2_password", 1)
end

function LightNovelPlugin:_doLogin(username, password)
    local worker = self.worker
    if not worker or not worker:available() then
        UIManager:show(InfoMessage:new{ text = _("后台进程不可用，无法登录") })
        return
    end
    local spinner = InfoMessage:new{ text = _("正在登录…"), dismissable = false }
    UIManager:show(spinner)
    self:requestDiagnosticScreenshot("login3_sending", 1)
    -- Bind the client out here rather than reading self.client from inside the
    -- subprocess: a worker task must not reach back into the plugin table (the
    -- same rule cacheWholeBook follows).
    local client = self.client
    local started, err = worker:start{
        timeout = 60,
        -- Queue, do not fail. The worker runs one job at a time and the shelf
        -- cover pass holds it for as long as it takes; without this, tapping
        -- 登录 while covers were being fetched answered "worker_busy" and login
        -- simply looked broken.
        queue = true,
        on_done = function(result)
            pcall(function() UIManager:close(spinner) end)
            if not result or not result.ok then
                UIManager:show(InfoMessage:new{
                    text = _("登录失败：") .. tostring(result and result.error or "unknown"),
                })
                return
            end
            local value = result.value or {}
            if not value.ok then
                UIManager:show(InfoMessage:new{
                    text = _("登录失败：") .. tostring(value.error or "unknown"),
                })
                return
            end
            -- The login ran in a worker child, so the session key it stored never
            -- reaches this process. Re-apply it here or search keeps saying
            -- "no session".
            self.client:setSessionKey(value.security_key or "")
            self.settings:flush()
            UIManager:show(InfoMessage:new{ text = _("登录成功，现在可以使用搜索了") })
            -- Go straight to the shelf so the login has an obvious result.
            self:showLibrary()
        end,
        task = function()
            local ok, login_err = client:login(username, password, { timeout = 30 })
            if ok then
                return { ok = true, uid = ok.uid, security_key = ok.security_key }
            end
            return { ok = false, error = login_err }
        end,
    }
    if not started then
        pcall(function() UIManager:close(spinner) end)
        UIManager:show(InfoMessage:new{
            text = _("无法启动后台任务：") .. tostring(err or "unknown"),
        })
    end
end

-- ------------------------------------------------------------------- book --

--- Build the catalog for a shelf book from the new-content-read family and
--- show its table of contents.
---
--- A shelf row carries a `book_id` from the new id space. The legacy series
--- endpoints answer code 0 with an empty array for the same book, so the whole
--- volume/chapter tree has to come from the new family:
---   get-book-volumes {book_id} -> get-volume-chapters {book_id, volume_id}
--- Every chapter is stored with its volume and lock state so that the unlock
--- prompt can price a chapter, a volume or the whole book without refetching.
--- @param options {refresh} when refresh is true the stored catalogue is
--- ignored and the tree is rebuilt from the server.
function LightNovelPlugin:openShelfBook(item, options)
    local client = self.client
    local book_id = tonumber(item.book_id) or 0
    if book_id <= 0 then
        UIManager:show(InfoMessage:new{ text = _("这本书缺少 book_id，无法打开") })
        return
    end

    self.current_book = {
        book_id = book_id,
        sid = 0,
        title = tostring(item.title or ""),
        author = tostring(item.author or ""),
    }
    self.current_key = Cache.book_key(self.current_book)
    self.settings:bookDir(self.current_key)

    -- Serve the catalogue from disk when one is already stored.
    --
    -- Opening a book used to ALWAYS rebuild the tree over the network: one
    -- request per volume plus one per chapter page, i.e. ~76 sequential
    -- round-trips for a 67-chapter book, all behind a spinner. That is the
    -- "点进书获取目录非常慢" the reader reported -- on every tap, for a book whose
    -- catalogue the previous download had already saved.
    --
    -- save_catalog persists everything the TOC, the unlock prompt and the
    -- comment attribution need (book_id, volume_id, locked/unlocked,
    -- access_type, comment_mapping_verified), so the stored rows are equivalent
    -- to what the worker would rebuild. Nothing is pinned to a stale list:
    -- 刷新目录 passes refresh=true, and 下载入库 always refetches from the server.
    local cached = self.cache:load_catalog(self.current_key)
    if not (options and options.refresh) and cached
        and #(cached.chapters or {}) > 0 then
        logger.info("openShelfBook: cached catalogue, chapters=",
            tostring(#cached.chapters), "key=", tostring(self.current_key),
            "toc_only=", tostring(options and options.toc_only == true))
        self.current_catalog = cached
        -- 长按书行走的是 toc_only：读者要的是目录页上的动作（下载入库/更新/补评论），
        -- 而不是"继续读上次那本"。否则已入库的书永远进不了目录页。
        if not (options and options.toc_only) and self:openWholeBook() then
            return
        end
        self:showToc()
        return
    end

    self:showSpinner(_("正在获取目录…"))
    -- Captured here, outside the worker task. That task runs in a separate
    -- process, so reaching back into `self` from inside it is not reliable --
    -- the legacy openBook() deliberately binds every value it needs before
    -- calling worker:start, and this must match.
    local shelf_title = tostring(item.title or "")
    local started, err = self.worker:start{
        timeout = 300,
        -- Opening a book is a deliberate user action, so it waits its turn
        -- rather than failing: the cover pass that starts automatically with the
        -- shelf used to hold the worker and make the very next tap answer
        -- "无法启动后台任务：worker_busy".
        queue = true,
        on_done = function(result)
            self:hideSpinner()
            if not result or not result.ok then
                local reason = tostring(result and result.error or "unknown")
                -- This path used to only raise a dialog, which left the
                -- catalog failure completely invisible in crash.log.
                logger.err("openShelfBook worker failed:", reason)
                UIManager:show(InfoMessage:new{
                    text = _("获取目录失败：") .. reason,
                })
                return
            end
            local value = result.value or {}
            if not value.catalog then
                local reason = tostring(value.error or "unknown")
                logger.err("openShelfBook no catalog. book_id=", tostring(book_id),
                    "reason=", reason)
                UIManager:show(InfoMessage:new{
                    text = _("获取目录失败：") .. reason,
                })
                return
            end
            self.current_catalog = value.catalog
            self.cache:save_catalog(self.current_key, value.catalog)
            logger.info("openShelfBook: catalog stored, chapters=",
                tostring(#(value.catalog.chapters or {})),
                "key=", tostring(self.current_key),
                "showToc=", type(self.showToc))
            -- weread's rule: if this title is already published as one merged
            -- book, open THAT rather than dropping the reader into a chapter
            -- list. It is the only file that should represent the title in
            -- "正在阅读". Falls through to the catalogue when there is none yet,
            -- where the "阅读整本书" and "把已缓存书籍合并入库" rows live.
            -- toc_only（书架长按）始终停在目录页。
            if not (options and options.toc_only) and self:openWholeBook() then
                return
            end
            self:showToc()
        end,
        task = function()
            local vlist, volume_page = {}, 1
            while volume_page <= 50 do
                local volumes, verr = client:fetchWebBookVolumes(book_id,
                    volume_page, { timeout = 40 })
                if not volumes then
                    logger.err("shelf fetchWebBookVolumes failed. book_id=",
                        tostring(book_id), "page=", tostring(volume_page),
                        "reason=", tostring(verr))
                    return { error = verr }
                end
                local page_rows = volumes.list or {}
                for _i, vol in ipairs(page_rows) do
                    vlist[#vlist + 1] = vol
                end
                local page_info = volumes.page_info or {}
                if #page_rows == 0 or (tonumber(page_info.has_next) or 0) == 0 then
                    break
                end
                volume_page = volume_page + 1
            end
            logger.info("shelf web volumes:", tostring(#vlist))
            local chapters = {}
            for _i, vol in ipairs(vlist) do
                local vid = tonumber(vol.volume_id or vol.id)
                if vid and vid > 0 then
                    local chapter_page = 1
                    while chapter_page <= 100 do
                        local vdata, verr2 = client:fetchWebVolumeChapters(
                            book_id, vid, chapter_page, { timeout = 40 })
                        if not vdata then
                            return { error = verr2 }
                        end
                        local page_rows = vdata.list or {}
                        for _i, ch in ipairs(page_rows) do
                            local cid = tonumber(ch.chapter_id)
                            if cid and cid > 0 then
                                chapters[#chapters + 1] = {
                                    index = #chapters + 1,
                                    aid = cid,
                                    title = tostring(ch.title or ""),
                                    book_id = book_id,
                                    volume_id = vid,
                                    volume_title = tostring(vol.title or vol.volume_title or ""),
                                    -- Keep a candidate for diagnostics, but do not
                                    -- activate the legacy endpoint until comment
                                    -- bodies confirm this exact volume mapping.
                                    source_article_id = tonumber(vol.source_article_id)
                                        or tonumber(vol.volume_legacy_aid) or 0,
                                    comment_candidate_aid =
                                        BookCatalog.shelf_comment_candidate(vol),
                                    volume_comment_count =
                                        tonumber(vol.volume_comment_count) or 0,
                                    comment_mapping_verified =
                                        BookCatalog.is_shelf_comment_mapping_verified(
                                            book_id, vol),
                                    comment_aid = BookCatalog.shelf_comment_aid(
                                        book_id, vol),
                                    locked = (tonumber(ch.locked) or 0) == 1
                                        and (tonumber(ch.unlocked) or 0) == 0,
                                    unlocked = (tonumber(ch.unlocked) or 0) == 1,
                                    access_type = tostring(ch.access_type or ""),
                                    coin_price = tonumber(ch.coin_price) or 0,
                                    words = tonumber(ch.word_count) or 0,
                                }
                            end
                        end
                        local page_info = vdata.page_info or {}
                        if #page_rows == 0
                            or (tonumber(page_info.has_next) or 0) == 0 then
                            break
                        end
                        chapter_page = chapter_page + 1
                    end
                end
            end
            if #chapters == 0 then
                logger.err("shelf empty_catalog. book_id=", tostring(book_id),
                    "volumes=", tostring(#vlist))
                return { error = "empty_catalog" }
            end
            logger.info("shelf chapters:", tostring(#chapters))
            return {
                catalog = {
                    book_id = book_id,
                    sid = 0,
                    title = shelf_title,
                    chapters = chapters,
                },
            }
        end,
    }
    if not started then
        self:hideSpinner()
        UIManager:show(InfoMessage:new{
            text = _("无法启动后台任务：") .. tostring(err or "unknown"),
        })
    end
end

--- Resolve the catalog for a picked item, then show the table of contents.
--- @param options {refresh} forwarded to openShelfBook; see its doc comment.
function LightNovelPlugin:openBook(item, options)
    -- A shelf row is not a legacy listing entry: its ids live in the new id
    -- space, so it needs its own catalog builder.
    if (tonumber(item.book_id) or 0) > 0 then
        return self:openShelfBook(item, options)
    end
    local client = self.client
    -- A listing entry with a non-zero sid is a series; otherwise the aid is
    -- itself the readable article.
    local sid = tonumber(item.sid) or 0
    local aid = tonumber(item.aid) or 0
    self.current_book = {
        aid = aid,
        sid = sid,
        title = tostring(item.title or ""),
        author = tostring(item.author or ""),
    }
    self.current_key = Cache.book_key(self.current_book)
    self.settings:bookDir(self.current_key)

    if sid <= 0 then
        -- Standalone post: no series, treat it as a one-chapter book.
        self.current_catalog = {
            sid = 0,
            title = self.current_book.title,
            chapters = { { index = 1, aid = aid, title = self.current_book.title } },
        }
        self.cache:save_catalog(self.current_key, self.current_catalog)
        self:showToc()
        return
    end

    local key = self.current_key
    local book = self.current_book

    self:showSpinner(_("正在获取目录…"))
    local started, err = self.worker:start{
        timeout = 90,
        on_done = function(result)
            self:hideSpinner()
            if not result or not result.ok then
                UIManager:show(InfoMessage:new{
                    text = _("获取目录失败：")
                        .. tostring(result and result.error or "unknown"),
                })
                return
            end
            local value = result.value or {}
            if not value.catalog then
                UIManager:show(InfoMessage:new{
                    text = _("获取目录失败：") .. tostring(value.error or "unknown"),
                })
                return
            end
            self.current_catalog = value.catalog
            self.cache:save_catalog(key, {
                sid = value.catalog.sid,
                title = book.title,
                chapters = value.catalog.chapters,
            })
            self:showToc()
        end,
        task = function()
            local catalog, fetch_err = BookCatalog.fetch(client, sid)
            if not catalog then
                return { error = fetch_err }
            end
            return { catalog = catalog }
        end,
    }
    if not started then
        self:hideSpinner()
        UIManager:show(InfoMessage:new{
            text = _("无法启动后台任务：") .. tostring(err or "unknown"),
        })
    end
end

--- Download the whole book -- every chapter plus the cover -- into the local
--- cache. Uses the site's own export sequence (see the reference block at the
--- top of client.lua); it costs no coins and, unlike per-chapter unlocking,
--- returns the trailing chapters that unlocking refused.
---
--- Runs in the worker: one response carries the whole book (~2.4 MB for 83
--- chapters), which is far too much to do on the UI thread.
--- Check a serialised book for new chapters and offer to fetch them.
---
--- Serialised books grow, so "cache whole book" is a one-shot action that goes
--- stale silently: the reader has no way to learn that chapter 84 exists without
--- opening the catalogue and noticing. This asks the server what the book now
--- contains, compares it with the cache, and says which of the three answers is
--- true -- new chapters, nothing new, or "could not check" -- because the first
--- two look identical if you only report a count.
function LightNovelPlugin:checkForUpdates()
    local book = self.current_book
    local book_id = tonumber(book and book.book_id) or 0
    local key = self.current_key
    if book_id <= 0 or not key then
        UIManager:show(InfoMessage:new{
            text = _("只有服务器书架上的书才能检查更新"),
        })
        return false
    end
    self:showSpinner(_("正在检查更新…"))
    local cache = self.cache
    local client = self.client
    local info, err
    local started, start_err = self.worker:start{
        timeout = 120,
        queue = true,
        task = function()
            local result, reason = cache:check_for_updates(client, {
                book_id = book_id, key = key,
            })
            if not result then
                return { error = tostring(reason or "unknown") }
            end
            -- Sent as a flat string because the parent decodes this through the
            -- worker's JSON channel.
            return {
                revision = result.revision,
                previous_revision = result.previous_revision or "",
                total = result.total,
                downloadable_total = result.downloadable_total or result.total,
                cached = result.cached,
                added = result.added,
                changed = result.changed and true or false,
                first_time = result.first_time and true or false,
                missing = table.concat(result.missing, ","),
                orphans = table.concat(result.orphans, ","),
            }
        end,
        on_done = function(result)
            self:hideSpinner()
            if not result or not result.ok then
                local reason = tostring(result and result.error or "unknown")
                logger.err("checkForUpdates worker failed:", reason)
                UIManager:show(InfoMessage:new{
                    text = _("检查更新失败：") .. reason,
                })
                return
            end
            local value = result.value or {}
            if value.error then
                logger.err("checkForUpdates:", tostring(value.error))
                UIManager:show(InfoMessage:new{
                    text = _("检查更新失败：") .. tostring(value.error),
                })
                return
            end
            info = value
            self:_reportUpdate(value)
        end,
    }
    if not started then
        self:hideSpinner()
        UIManager:show(InfoMessage:new{
            text = _("无法启动后台任务：") .. tostring(start_err or "unknown"),
        })
        return false
    end
    return true
end

--- 上次导出的插图健康度（b33，读 bookDir/export_status.lua）。
---
--- 以前"导出缺图"只写日志：书已经在库里，读者点「库中书更新」永远只得到
--- 一句"已是最新"，想补图只能手动删掉 EPUB 再点「下载入库」。这里把导出
--- 结果落盘，让更新动作自己发现缺图并重出。
---
--- 没有状态文件 = 旧版本导出（他当时还不知道要记录），无法判断是否缺图，
--- 重建一次以取得状态；之后按失败占比决定。
function LightNovelPlugin:lastExportStatus()
    local key = self.current_key
    if not key then return nil end
    local path = self.settings:bookDir(key) .. "/export_status.lua"
    local chunk = loadfile(path)
    if not chunk then
        return { repair = true, failed = 0, unsupported = 0, total = 0 }
    end
    local ok, st = pcall(chunk)
    if not ok or type(st) ~= "table" then
        return { repair = true, failed = 0, unsupported = 0, total = 0 }
    end
    local total = tonumber(st.total) or 0
    local failed = tonumber(st.failed) or 0
    local unsupported = tonumber(st.unsupported) or 0
    -- 白名单版本变了 = 上次被拒的图现在可能取得到，必须重出一次。
    -- 少了这条，改完白名单点「库中书更新」只会回"已是最新"，那批图永远补不进来
    -- （2026-10-27 实测：《游戏人生》14:30 点更新无任何动作，就是这个原因）。
    local stored_wl = tonumber(st.whitelist) or 0
    local current_wl = tonumber(Export.IMAGE_WHITELIST_VERSION) or 0
    -- 其余情况只按"抓取失败"占比 ≥25% 触发：零星上游死链重导也不会好，
    -- 不能让它把每次点更新都变成一次全量导出。
    local repair = (failed >= 3 and failed * 4 >= total)
        or (unsupported > 0 and stored_wl ~= current_wl)
    return { repair = repair, failed = failed, unsupported = unsupported,
        total = total, missing = st.missing, whitelist = stored_wl }
end

--- Turn a check result into words, and offer the download when there is one.
function LightNovelPlugin:_reportUpdate(info)
    local total = tonumber(info.total) or 0
    local downloadable = tonumber(info.downloadable_total) or total
    local cached = tonumber(info.cached) or 0
    local added = tonumber(info.added) or 0
    local orphans = 0
    for _c in tostring(info.orphans or ""):gmatch("[^,]+") do
        orphans = orphans + 1
    end

    if added == 0 and not info.changed then
        local text = string.format(_("目录 %d 章；可缓存 %d 章，已缓存 %d 章"),
            total, downloadable, cached)
        if orphans > 0 then
            text = text .. string.format(_("\n（%d 章已不在服务器列表中，仍保留在本地）"),
                orphans)
        end
        logger.info("checkForUpdates: up to date. total=", tostring(total),
            "orphans=", tostring(orphans))
        -- 已是最新，但评论还没抓全 → 仍然跑一遍"评论 → 重出 EPUB"。
        --
        -- 否则一本早就入库、只是当时没抓到评论的书，点"库中书更新"永远只会回
        -- "已是最新"，评论没有任何入口可以补上（读者报的"想要补全评论"就卡在这）。
        if self:needsCommentBackfill() then
            logger.info("checkForUpdates: up to date but comments are missing;",
                "running the comment -> republish chain")
            self:cacheWholeBook({})
            return
        end
        -- b33：上次导出缺图（图床白名单拒收/大量超时）也重出。读者要的是
        -- "点一下更新就把插图补齐"，不必先删库中书。阈值在 lastExportStatus
        -- 里，零星上游死链不会触发，避免每次更新都全量重导。
        local st = self:lastExportStatus()
        if st and st.repair then
            logger.info("checkForUpdates: up to date but last export was",
                "incomplete; republishing. failed=", tostring(st.failed),
                "unsupported=", tostring(st.unsupported),
                "total=", tostring(st.total))
            self:cacheWholeBook({})
            return
        end
        UIManager:show(InfoMessage:new{ text = text })
        return
    end

    local parts = {}
    if added > 0 then
        parts[#parts + 1] = string.format(_("新增 %d 章"), added)
    end
    if info.changed then
        -- Not just appended: something already downloaded may have been edited.
        parts[#parts + 1] = _("内容有改动，将重新下载全书")
    end
    if orphans > 0 then
        parts[#parts + 1] = string.format(
            _("%d 章已不在服务器列表中，仍保留在本地"), orphans)
    end
    logger.info("checkForUpdates: new chapters=", tostring(added),
        "changed=", tostring(info.changed), "total=", tostring(total))
    UIManager:show(InfoMessage:new{
        text = table.concat(parts, "\n") .. "\n\n"
            .. string.format(_("目录 %d 章；可缓存 %d 章；缓存进度 %d/%d"),
                total, downloadable, cached, downloadable),
    })
    -- Downloading is the obvious next step, so it is offered rather than assumed.
    self:cacheWholeBook({ force = info.changed })
end

-- 新内容书籍的按卷评论（2026-10-27）。
--
-- 抓取在 worker 子进程里做（`CommentSync:queue_volumes`），这里只负责两件父进程的事：
-- 从目录里挑出"声明了评论数的卷"，以及抓完后把目录里的卷映射指到评论库的键上
-- （`NEW_COMMENT_KEY_BASE + volume_id`）。导出侧不动——它本来就是 volume_scoped，
-- 会在该卷最后一章之后挂一次「本卷评论（N 条）」。
local function collect_comment_volumes(catalog)
    local chapters = (catalog or {}).chapters or {}
    local counts, order = {}, {}
    for _i, chapter in ipairs(chapters) do
        local vid = tonumber(chapter.volume_id) or 0
        local count = tonumber(chapter.volume_comment_count) or 0
        if vid > 0 then
            if not counts[vid] then
                counts[vid] = count
                order[#order + 1] = vid
            elseif count > counts[vid] then
                counts[vid] = count
            end
        end
    end
    local volumes = {}
    for _i, vid in ipairs(order) do
        if counts[vid] > 0 then
            volumes[#volumes + 1] = { volume_id = vid, count = counts[vid] }
        end
    end
    return volumes
end

--- 把抓到的卷评论映射写回目录：该卷各章的 comment_aid 指向评论库键并标已验证。
function LightNovelPlugin:_applyVolumeCommentMapping(catalog, volumes, key)
    if type(catalog) ~= "table" then return end
    local wanted = {}
    for _i, entry in ipairs(volumes or {}) do
        local vid = tonumber(entry.volume_id)
        if vid then wanted[vid] = true end
    end
    local base = tonumber(CommentSync.NEW_COMMENT_KEY_BASE) or 0
    for _i, chapter in ipairs(catalog.chapters or {}) do
        local vid = tonumber(chapter.volume_id) or 0
        if vid > 0 and wanted[vid] then
            chapter.comment_aid = base + vid
            chapter.comment_mapping_verified = true
        end
    end
    self.cache:save_catalog(key, catalog)
end

function LightNovelPlugin:cacheWholeBook(options)
    options = options or {}
    local book_id = tonumber((self.current_book or {}).book_id) or 0
    if book_id <= 0 then
        UIManager:show(InfoMessage:new{ text = _("这本书不是服务器书架，不能整本缓存") })
        return
    end
    local key = self.current_key
    local catalog = self.current_catalog
    -- 任务上下文在发起时捕获（2026-10-24 02:01 实测串书：任务跑动中读者点开
    -- 另一本书，收尾导出读到被覆盖的 current_*，把 A 书的评论链导成了 B 书）。
    -- 结算与导出一律用这份捕获值，不接受运行中的替换。
    local task_book = self.current_book
    if not key or not catalog then
        UIManager:show(InfoMessage:new{ text = _("请先打开一本书") })
        return
    end
    local new_content_book = (tonumber(self.current_book and self.current_book.book_id) or 0) > 0

    -- 下载期间把插件书架铺在弹窗下面。
    --
    -- 目录页的"下载入库"会先关闭目录，于是弹窗下面直接露出文件管理器/插件菜单，
    -- 读者看到的就是"一开始下载就回到桌面"。书架本身有磁盘缓存（shelf.lua），
    -- 非强制刷新不联网、也不占用 worker，所以可以先铺好再让任务弹窗盖上去。
    self:showShelfUnderTask()

    -- 读者按过"退出"就记在这里。
    --
    -- 不能只依赖 STATE.task.exiting：on_exit 紧接着就调 endTask() 把 _task 置空，
    -- worker 的取消结果晚几秒才回来，那时 STATE.task 已经是 nil，读到的
    -- user_exited 是 nil → 取消被当成失败 → 读者自己点的退出却弹出"缓存/导出失败"。
    local exited_by_reader = false
    self:beginTask{
        kind = "cache",
        title = _("正在缓存整本书…"),
        description = _("可以隐藏到后台，或暂停并稍后继续。"),
        on_pause = function()
            -- 用当前任务自己的句柄。self._task_request 可能还指着上一次（已完成
            -- 的）请求，worker 会把它判成"不是活动任务"而静默失败。
            local request = (STATE.task and STATE.task.request) or self._task_request
            return self.worker:pause(request, "user_paused") == true
        end,
        -- Resuming is just running the same job again: the chapter cache and the
        -- download_state file are what make that cheap, so there is no separate
        -- resume path that could disagree with the original one.
        on_resume = function()
            local resume = function() self:cacheWholeBook(options) end
            -- Deferred: this runs inside the dialog's own button handler, and
            -- resume replaces that dialog. Closing a widget from within its own
            -- event dispatch is not safe here.
            UIManager:scheduleIn(0, resume)
        end,
        on_exit = function()
            exited_by_reader = true
            if STATE.task then STATE.task.exiting = true end
            local request = (STATE.task and STATE.task.request) or self._task_request
            self.worker:cancel(request, "user_cancelled")
            self:endTask()
        end,
    }
    -- Bind everything the task needs before handing the closure over. This module's
    -- own rule (see the comment above openBook) is that a worker task must not
    -- reach back into `self`: the closure runs in a subprocess where the plugin
    -- table, its widgets and its UIManager state do not exist, and it used to read
    -- self.cache / self.client / self.current_book from there.
    local cache = self.cache
    local client = self.client
    local book_title = tostring((self.current_book or {}).title or "")
    -- force = true re-downloads every chapter; used after the server reports a
    -- changed revision, which means a body may have been edited rather than
    -- merely appended.
    local force = options.force == true
    -- The second return is the request handle on success and an error string on
    -- failure, so it is kept under a name that says both. The handle is what
    -- 暂停 and 退出 address; dropping it (as this used to) left the dialog with no
    -- way to name the job it was supposed to control.
    local started, handle = self.worker:start{
        -- One request carries everything; give it room but keep a ceiling.
        timeout = 900,
        queue = true,
        -- 读者发起的任务：排队期间不允许被封面/书架刷新这类背景请求挤掉。
        protect = true,
        on_done = function(result)
            -- A pause is not a failure. The worker stops the child the same way a
            -- cancel does, so this is the only place that can tell them apart --
            -- and reporting a resumable stop as "缓存失败" is exactly what made the
            -- earlier interrupted download look like data loss.
            if result and result.paused then
                logger.info("cacheWholeBook: paused, progress kept on disk")
                if STATE.task then STATE.task.paused = true end
                return
            end
            local user_exited = exited_by_reader
                or (STATE.task and STATE.task.exiting)
            self:endTask()
            if user_exited then
                logger.info("cacheWholeBook: cancelled by the reader")
                return
            end
            -- 被取消（队列被替换、插件关闭）不是失败：任务没有跑出任何结果，
            -- 弹"缓存失败"只会让读者以为数据出了问题。
            if result and result.cancelled then
                logger.info("cacheWholeBook: stopped before it ran:",
                    tostring(result.error))
                return
            end
            if not result or not result.ok then
                UIManager:show(InfoMessage:new{
                    text = _("缓存失败：")
                        .. tostring(result and result.error or "unknown"),
                })
                return
            end
            local value = result.value or {}
            if value.error then
                logger.err("cacheWholeBook failed:", tostring(value.error))
                UIManager:show(InfoMessage:new{
                    text = _("缓存失败：") .. tostring(value.error),
                })
                return
            end
            logger.info("cacheWholeBook done: written=", tostring(value.written),
                "skipped=", tostring(value.skipped),
                "failed=", tostring(value.failed),
                "revision=", tostring(value.revision))
            if value.cached then
                -- "Every readable chapter is already on disk" is NOT a finished
                -- job, and treating it as one is what broke 下载入库 outright.
                -- This used to show "已全部缓存" and `return` here -- before the
                -- export step -- so the second tap on any already-downloaded
                -- book did nothing at all and never put it in the library. The
                -- chapters were on disk and the book was still absent from the
                -- shelf, which is the exact state the reader sees on the device.
                --
                -- There is nothing to download, but the catalogue may have moved
                -- on (new chapters on a serial) and the EPUB may never have been
                -- built. Both are handled further down, so fall through.
                logger.info("cacheWholeBook: every readable chapter is already",
                    "cached; continuing to refresh and publish")
            end
            -- The catalogue is refreshed from the SERVER, not kept as it was.
            -- On a serial this is the whole point of the action: the local
            -- catalog was written when the book had 52 chapters, and keeping it
            -- meant a newly published chapter 53 never appeared in the TOC even
            -- after its body had been downloaded. The download returns the
            -- chapter rows the server just served, so save those.
            local fresh = (value.chapters and #value.chapters > 0)
                and value.chapters or nil
            if fresh then
                logger.info("cacheWholeBook: refreshing catalogue with",
                    tostring(#fresh), "server chapters")
                if new_content_book then
                    local volume_metadata = {}
                    for _i, old_chapter in ipairs((catalog or {}).chapters or {}) do
                        local vid = tonumber(old_chapter.volume_id) or 0
                        if vid > 0 then
                            volume_metadata[vid] = {
                                comment_aid = tonumber(old_chapter.comment_aid) or 0,
                                comment_candidate_aid =
                                    tonumber(old_chapter.comment_candidate_aid) or 0,
                                volume_comment_count =
                                    tonumber(old_chapter.volume_comment_count) or 0,
                                comment_mapping_verified =
                                    old_chapter.comment_mapping_verified == true,
                                source_article_id =
                                    tonumber(old_chapter.source_article_id) or 0,
                                volume_title = old_chapter.volume_title,
                            }
                        end
                    end
                    -- The whole-book response omits the volume comment metadata.
                    -- Carry only the existing explicit mapping state forward;
                    -- never infer it from chapter_id or a numeric collision.
                    for _i, fresh_chapter in ipairs(fresh) do
                        local vid = tonumber(fresh_chapter.volume_id) or 0
                        local metadata = volume_metadata[vid]
                        fresh_chapter.source_article_id =
                            tonumber(fresh_chapter.source_article_id)
                            or (metadata and metadata.source_article_id) or 0
                        fresh_chapter.comment_candidate_aid =
                            BookCatalog.shelf_comment_candidate(fresh_chapter)
                        fresh_chapter.volume_comment_count =
                            tonumber(fresh_chapter.volume_comment_count)
                            or (metadata and metadata.volume_comment_count) or 0
                        -- 白名单优先，行上已带的运行时核验结果（b21）保持。
                        local _fc, f_verified, f_aid =
                            BookCatalog.shelf_comment_mapping(book_id, fresh_chapter)
                        fresh_chapter.comment_mapping_verified = f_verified == true
                        fresh_chapter.comment_aid = tonumber(f_aid) or 0
                        fresh_chapter.volume_title = fresh_chapter.volume_title
                            or (metadata and metadata.volume_title) or ""
                    end
                end
                self.cache:save_catalog(key, {
                    sid = (catalog or {}).sid or 0,
                    title = (catalog or {}).title,
                    chapters = fresh,
                })
                self.current_catalog = {
                    sid = (catalog or {}).sid or 0,
                    title = (catalog or {}).title,
                    chapters = fresh,
                }
                -- NO export here. This call used to sit in this branch and was
                -- left behind when the comments -> EPUB chain was introduced
                -- below, so one download built the archive TWICE: the second job
                -- displaced the first in the worker's pending slot, and the reader
                -- paid for a full deflate pass that was thrown away. The export
                -- now happens exactly once, at the end of the chain, where the
                -- comments are already stored.
            else
                self.cache:save_catalog(key, catalog)
            end
            -- The catalogue is NOT reopened here. TocMenu.show builds a brand new
            -- menu every call, so doing it while the task dialog is up stacked a
            -- second catalogue on top of the first AND over the dialog; and doing
            -- it before the export meant the reader sat on a catalogue that was
            -- about to be replaced. It is reopened by exportBook when the whole
            -- chain finishes, by which time the dialog is closed and there is
            -- exactly one catalogue on screen.
            --
            -- Comments ride along with the bodies, and they have to be IN the
            -- exported book, not fetched next to it. This used to export first and
            -- queue the comments after, so the EPUB the reader ended up with on a
            -- first download had no comments in it and was never rebuilt -- the
            -- library copy stayed permanently incomplete. The order is now
            -- chapters -> comments -> EPUB, and the export (which reads the
            -- comment database in the parent) is last for exactly that reason.
            local aids, seen_aids = {}, {}
            -- 用刚刷新过的目录，而不是开始下载时捕获的旧目录。
            --
            -- 旧目录里没有 comment_mapping_verified / comment_aid（这两项是这次
            -- 刷新才写进去的），于是评论 aid 收集结果永远是空，日志里表现为
            -- "comment attribution unverified for this book"，读者看到的就是
            -- "这本书获取评论又失败"。旧目录只在服务端没返回章节行时兜底。
            local chapters_for_comments = (fresh and #fresh > 0)
                and fresh or ((catalog or {}).chapters or {})
            -- 评论映射不能只靠"下载时刷新目录"来更新。
            --
            -- 整本已缓存的书会走 download_state 快路径（written=0，响应里没有
            -- chapters），fresh 为 nil，目录一行都不改；于是刚加进白名单的书
            -- 仍然读不到映射，评论永远补不上（桌游咖 bid_31607 就是这种状态：
            -- 目录里第 3 卷的 mapping 还停在 false）。映射本身是
            -- (book_id, volume_id, source_article_id) 的纯函数，在父进程直接重算
            -- 一遍并写回目录，以后打开也不再是旧值。
            if new_content_book then
                for _i, chapter in ipairs(chapters_for_comments) do
                    if chapter.volume_id then
                        -- 白名单优先；行上已带运行时核验结果（b21）且候选未变
                        -- 时保持已验证。
                        local _cand, verified, aid =
                            BookCatalog.shelf_comment_mapping(book_id, chapter)
                        chapter.comment_candidate_aid =
                            BookCatalog.shelf_comment_candidate(chapter)
                        chapter.comment_mapping_verified = verified == true
                        chapter.comment_aid = tonumber(aid) or 0
                    end
                end
                -- 白名单之外的卷现场核验（b21）：评论数与书架声明逐卷相等的
                -- 卷自动标记已验证，随本轮回目录、进评论同步。这一步把"每本
                -- 新书都要人工核验白名单"变成下载链路自带的动作。
                if self:verifyCommentMappingsAtRuntime(book_id, chapters_for_comments)
                    and self.current_catalog then
                    pcall(function()
                        self.cache:save_catalog(key, {
                            sid = self.current_catalog.sid or 0,
                            title = self.current_catalog.title,
                            chapters = chapters_for_comments,
                        })
                    end)
                end
                if not fresh and self.current_catalog then
                    pcall(function()
                        self.cache:save_catalog(key, {
                            sid = self.current_catalog.sid or 0,
                            title = self.current_catalog.title,
                            chapters = chapters_for_comments,
                        })
                    end)
                end
            end
            if not new_content_book then
                -- Legacy serial: one legacy aid per chapter is the supported API.
                for _i, chapter in ipairs(chapters_for_comments) do
                    local aid = tonumber(chapter.aid)
                    if aid and aid > 0 and not seen_aids[aid] then
                        seen_aids[aid] = true
                        aids[#aids + 1] = aid
                    end
                end
            else
                -- New-content book: comments belong to each source volume aid;
                -- de-duplicate so the same volume thread is downloaded once.
                for _i, chapter in ipairs(chapters_for_comments) do
                    local aid = chapter.comment_mapping_verified == true
                        and tonumber(chapter.comment_aid) or nil
                    if aid and aid > 0 and not seen_aids[aid] then
                        seen_aids[aid] = true
                        aids[#aids + 1] = aid
                    end
                end
            end
            -- Why there are no comments to fetch, logged rather than shown. The reader-facing
            -- version of this sentence ended up inside a stats box on top of the
            -- export dialog, where it read as a failure of the download; the log is
            -- where a fact about attribution belongs.
            if new_content_book and #aids == 0 then
                -- 把 book_id 和每个卷的候选 aid 一起写进日志。
                --
                -- 没有这三样，"评论没抓"就只能靠猜；带上它们之后，核对白名单
                -- （VERIFIED_SHELF_COMMENT_AIDS）只需要看一行日志，不必再去翻
                -- 设备上的 catalog.lua。
                local candidates, seen_pairs = {}, {}
                for _i, chapter in ipairs(chapters_for_comments) do
                    local vid = tonumber(chapter.volume_id) or 0
                    local src = tonumber(chapter.source_article_id) or 0
                    local pair = tostring(vid) .. ":" .. tostring(src)
                    if vid > 0 and src > 0 and not seen_pairs[pair] then
                        seen_pairs[pair] = true
                        candidates[#candidates + 1] = pair
                    end
                end
                logger.info("cacheWholeBook: comment attribution unverified for this",
                    "book, skipped safely (no legacy endpoint call)",
                    "book_id=", tostring(book_id),
                    "volumes=", table.concat(candidates, ","))
            elseif #aids == 0 then
                logger.info("cacheWholeBook: no comment ids resolved")
            end
            -- The one button the reader presses has to leave a COMPLETE book in
            -- the library, so the export is deferred until the comments are
            -- stored. Every early exit below still reaches the export: a book
            -- whose comments fail must still get its EPUB, just without them.
            local function publish_now()
                -- allow_partial is safe here ONLY because the `failed > 0` branch
                -- below returns before this is ever reached. By this point no
                -- readable chapter is missing, so any shortfall left in the
                -- catalogue is locked content we deliberately did not unlock --
                -- which is exactly the case the export gate is allowed to permit.
                -- context 用发起时捕获的书目：任务跑动中读者点开别的书时，
                -- self.current_* 已被覆盖，不传 context 会导错书（02:01 实测）。
                self:exportBook({
                    silent = options.silent,
                    allow_partial = true,
                    context = { key = key, catalog = catalog, book = task_book },
                })
            end
            -- Only report when something went wrong.
            --
            -- A summary box used to be shown here on the success path, on top of
            -- the export dialog that publish_now had just opened. On the device it
            -- rendered as a stats table sitting inside a box titled "正在导出 EPUB…",
            -- which reads like the export failed: the two messages described
            -- different stages and the reader could not tell which one was current.
            -- The export dialog and its own completion message are the feedback for
            -- a successful run; a box here can only be noise, or a contradiction.
            local function report_problem(text)
                UIManager:show(InfoMessage:new{ text = text })
            end
            local written = tonumber(value.written) or 0
            local failed = tonumber(value.failed) or 0
            local readable = tonumber(value.readable_total) or tonumber(value.total) or 0
            if failed > 0 then
                -- Say it plainly and only now that the download is over. `written`
                -- counts chapters stored this run, so "67/58" is possible and
                -- meaningless to the reader; the honest pair is what is on disk
                -- versus what the server offers.
                --
                -- Do NOT publish. These chapters were readable and this run simply
                -- failed to fetch them, so the EPUB would go into the library quietly
                -- short and the gap would only surface when the book is opened. That
                -- silent partial publish is the long-running "这本书又少了几章" report:
                -- the catalogue knew about every chapter, nothing acted on the count.
                -- `weread_desktop.py` already refuses to publish an incomplete EPUB;
                -- this is the same rule on the device. Re-running 下载入库 resumes
                -- from the atomic chapter files, so retrying is cheap.
                report_problem(string.format(
                    _("有 %d 章没取到（共 %d 章可读），本次不出版。请再点一次下载入库补齐。"),
                    failed, readable))
                return
            elseif (tonumber(value.locked_skipped) or 0) > 0 then
                -- These are NOT fetchable on this path: coin chapters the free export
                -- manifest does not cover, which we refuse to unlock or buy. Blocking
                -- on them would make such a book permanently unpublishable, so it is
                -- published -- but the count has to reach the reader, because the EPUB
                -- is short by exactly this many and silence here is what made the loss
                -- look like a bug. This used to be a logger.info the reader never saw.
                local locked = tonumber(value.locked_skipped) or 0
                local obtained = readable - locked
                logger.info("cacheWholeBook: skipped locked chapters=",
                    tostring(locked), "of",
                    tostring(value.total), "catalogue chapters")
                report_problem(string.format(
                    _("有 %d 章是付费内容、未解锁，已跳过；已入库 %d 章。"),
                    locked, obtained))
            end
            -- 新内容书籍：走公开的按卷评论接口，全程在 worker 里跑（父进程不阻塞）。
            -- 失败不影响出版：on_finished 无论如何都会 publish_now。
            if new_content_book and not (options and options.skip_comments) then
                local volumes = collect_comment_volumes(catalog)
                if #volumes > 0 then
                    local queued, why = self.comment_sync:queue_volumes(
                        tonumber(book_id) or 0, volumes, {
                            on_finished = function(_result, written)
                                if (tonumber(written) or 0) > 0 then
                                    pcall(function()
                                        self:_applyVolumeCommentMapping(
                                            catalog, volumes, key)
                                    end)
                                end
                                publish_now()
                            end,
                        })
                    if queued then return end
                    logger.warn("comments(new-content): not queued:", tostring(why))
                end
            end
            if #aids > 0 and self.comment_sync then
                local queued = self.comment_sync:queue_background(aids, {
                    on_finished = function()
                        publish_now()
                    end,
                })
                if not queued then
                    -- Refused (worker unavailable, or comments are not wired for
                    -- new-content books). The chain hook will not run, so the
                    -- export has to happen here or the book never reaches the
                    -- library.
                    logger.err("cacheWholeBook: comment queue refused")
                    publish_now()
                end
            else
                publish_now()
            end
        end,
        on_progress = function(state)
            self:reportTaskProgress(state)
        end,
        task = function(context)
            -- `force` was read from options above and then never used, so it never
            -- reached the cache: the worker built its own context table and the
            -- download only ever looked at context.force. A revision change
            -- therefore re-fetched only missing chapters, and a body the server
            -- had EDITED stayed stale on disk forever. Assigned here because the
            -- worker owns `context` and nothing else can populate it.
            context.force = force
            return cache:download_whole_book(client,
                { book_id = book_id, key = key, title = book_title }, context)
        end,
    }
    if not started then
        self:endTask()
        UIManager:show(InfoMessage:new{
            text = _("无法启动后台任务：") .. tostring(handle or "unknown"),
        })
        return
    end
    self._task_request = handle
    -- 句柄同时挂在任务对象上：暂停/退出都按"当前任务"取，避免导出阶段还指着
    -- 上一次缓存请求。
    if STATE.task then STATE.task.request = handle end
    -- 首条进度文案。取目录和取下载清单都不带 done/total，没有这一句时弹窗会
    -- 长时间只有一条空进度条。
    self:reportTaskProgress{ stage = "catalog", page = 1 }
end

--- Package the cached book into one EPUB with its comments (option A: the
--- comments of a chapter are printed at the end of that chapter).
---
--- The archive is written in a worker -- 83 chapters plus a cover is a lot of
--- deflate for an e-ink CPU -- while the comment bodies are read from SQLite here
--- in the parent, because this plugin never writes that database from a child.
--- Publish the current book as one EPUB.
---
--- `options.silent` suppresses the "已导出" dialog: used after an automatic
--- update, where the reader did not ask for an export and a dialog would be
--- noise on top of the update report.
function LightNovelPlugin:exportBook(options)
    options = options or {}
    -- context 由任务发起方（cacheWholeBook 的评论→重出版链）传入：发起时
    -- 捕获的书目。不传时才读 self.current_*（手动导出的当前书）。
    local ctx = options.context or {}
    local key = ctx.key or self.current_key
    local catalog = ctx.catalog or self.current_catalog
    local task_book = ctx.book or self.current_book
    if not key or not catalog then
        UIManager:show(InfoMessage:new{ text = _("请先打开一本书") })
        return
    end
    local export = Export:new{
        settings = self.settings,
        cache = self.cache,
        client = self.client,
        store = CommentStore,
        store_namespace = (tonumber(task_book and task_book.book_id) or 0) > 0
            and "new-content" or nil,
        comment_scope = (tonumber(task_book and task_book.book_id) or 0) > 0
            and "volume" or "chapter",
        book = task_book or {},
        catalog = catalog,
        key = key,
        worker = self.worker,
        -- Forwarded verbatim. Defaults to false, so any caller that does not think
        -- about completeness gets a refusing export rather than a short book.
        allow_partial = options.allow_partial == true,
        -- Export 自己在内部调用 worker:start，句柄拿不到就会让"暂停"按上一次
        -- 缓存请求去暂停，worker 直接拒绝（日志 ms=0、没有任何 paused 记录）。
        -- 这里把真正的请求句柄交回任务对象。
        on_request = function(request)
            if STATE.task then STATE.task.request = request end
            self._task_request = request
        end,
    }
    -- 同 cacheWholeBook：endTask() 会清掉 _task，取消结果晚到时读不到 exiting，
    -- 于是读者按的"退出"被回报成"导出失败：user_cancelled"。
    local exited_by_reader = false
    self:beginTask{
        kind = "export",
        title = _("正在导出 EPUB…"),
        description = _("可以隐藏到后台，或暂停并稍后继续。"),
        on_pause = function()
            local request = (STATE.task and STATE.task.request) or self._task_request
            return self.worker:pause(request, "user_paused") == true
        end,
        -- Safe to resume: Export writes to `<path>.part` and renames it into place,
        -- so a killed export leaves no half-written EPUB in the library, and a
        -- second run simply starts the archive again.
        on_resume = function()
            local resume = function() self:exportBook(options) end
            UIManager:scheduleIn(0, resume)
        end,
        on_exit = function()
            exited_by_reader = true
            if STATE.task then STATE.task.exiting = true end
            local request = (STATE.task and STATE.task.request) or self._task_request
            self.worker:cancel(request, "user_cancelled")
            self:endTask()
        end,
    }
    local finished = false
    -- 打包前的准备（逐章 stat、读评论库）在父进程里做，没有进度事件；先给一句
    -- 状态，避免弹窗刚出来又是一条空进度条。
    self:reportTaskProgress{ message = _("正在准备打包…") }
    -- One call, not two. This used to run `export:run(callback)` and then wrap the
    -- *same* call again in pcall -- so every export queued TWO worker jobs for one
    -- request. The second `queued in worker` replaced the first as the pending job
    -- (see Worker:start), the first job was then killed by the progress timeout
    -- mid-deflate, and the reader got `worker_no_result` from a request that had
    -- merely been asked for twice. That double is exactly what the 20:21:24 log
    -- shows: `building EPUB` twice, `queued in worker` twice.
    --
    -- export:run also does real work in the parent before the worker starts: it
    -- stats every chapter and reads the whole comment database to build the
    -- fragments. Any raise there (a corrupt catalogue entry, an unreadable db)
    -- must be contained here, because hideSpinner() is only reachable from inside
    -- the callback -- an escaping error left the full-screen loading overlay up
    -- with nothing behind it and no way to dismiss it. Hence the pcall, wrapping
    -- the single call.
    local function settle(path, chapters, comment_chapters, reason, raw)
        -- The worker calls back from a timer, so this may land after the user
        -- walked away; the dialog close is guarded rather than assumed.
        if finished then
            return
        end
        finished = true
        local function reopen_catalogue()
            -- 任务开始时已经把书架铺在弹窗下面，这里只需保证读者不是落在空屏上。
            --
            -- 原来无条件重开目录：弹窗关掉后目录盖在书架上面，读者要回书架还得多
            -- 按一次返回；而如果书架已经被关掉（读者中途自己退出过），就又回到
            -- "停在文件管理器"。所以只在书架不在时才补一个，补的也是书架。
            if not self.current_key or not self.current_catalog then return end
            if self:isShelfShown() then return end
            pcall(function() self:showLibrary{ mode = "bookshelf" } end)
        end

        -- A pause arrives here as a failure-shaped result (path == nil), because
        -- the worker stops the child the same way for both. `raw.paused` is the
        -- only thing that separates them, and without this branch a resumable stop
        -- was announced to the reader as "导出失败：paused".
        if not path and raw and raw.paused then
            logger.info("exportBook: paused, nothing published")
            if STATE.task then STATE.task.paused = true end
            return
        end
        local user_exited = exited_by_reader
            or (STATE.task and STATE.task.exiting)
        self:endTask()
        if user_exited then
            logger.info("exportBook: cancelled by the reader")
            return
        end
        -- 同样：被取消（队列被替换、插件关闭、superseded）不是"导出失败"。
        -- 这条分支此前会把 `replaced` 直接糊到读者脸上，而他根本没点过取消。
        if raw and raw.cancelled then
            logger.info("exportBook: stopped before it ran:",
                tostring(raw.error))
            return
        end
        if not path then
            -- b44：子进程静默死亡（worker_no_result —— 多半是被系统 OOM 杀掉）时
            -- 自动重跑一次。已经抓到的插图都在磁盘缓存里，第二次明显更快，成功率高
            -- 得多；不重试的话读者只能自己再点一遍，还得先看到一条"导出失败"。
            -- 只重试一次（options._retried），避免在真·坏数据上反复烧电。
            if reason == "worker_no_result" and not options._retried then
                logger.info("exportBook: worker died without result; retrying once")
                local retry_options = {}
                for k, v in pairs(options) do retry_options[k] = v end
                retry_options._retried = true
                UIManager:scheduleIn(2, function()
                    self:exportBook(retry_options)
                end)
                return
            end
            logger.err("exportBook failed:", tostring(reason))
            UIManager:show(InfoMessage:new{
                text = _("导出失败：") .. tostring(reason or "unknown"),
            })
            -- A failed export still leaves the reader on the file manager home
            -- otherwise, with the error box and nothing behind it.
            reopen_catalogue()
            return
        end
        logger.info("exportBook done:", path, "chapters=", tostring(chapters),
            "comment_chapters=", tostring(comment_chapters))
        if not options.silent then
            -- b37：把插图成败写进完成弹窗。读者在书里已经看不到占位符，
            -- 缺了几张必须在这里说清楚，否则"没有任何提示"等于"全都好了"。
            local images = ""
            local st = self:lastExportStatus()
            if st and (tonumber(st.total) or 0) > 0 then
                local images_ok = (st.total or 0) - (st.failed or 0)
                    - (st.unsupported or 0)
                if images_ok < 0 then images_ok = 0 end
                local lost = (st.failed or 0) + (st.unsupported or 0)
                if lost > 0 then
                    images = string.format(
                        _("\n插图 %d/%d，%d 张仍缺（下次点「库中书更新」会重试）"),
                        images_ok, st.total, lost)
                else
                    images = string.format(_("\n插图 %d/%d，全部正常"),
                        images_ok, st.total)
                end
            end
            UIManager:show(InfoMessage:new{
                text = string.format(_("已导出 %d 章（含 %d 章评论）%s\n%s"),
                    chapters, comment_chapters, images, path),
            })
        end
        reopen_catalogue()
        self:requestDiagnosticScreenshot("export_done", 2)
    end

    local ok, raised = pcall(export.run, export, settle)
    if not ok then
        logger.err("exportBook raised:", tostring(raised))
        -- settle() never ran, so the request is still outstanding: report it
        -- through the same path so the task is torn down exactly once.
        settle(nil, 0, 0, tostring(raised))
    end
end

function LightNovelPlugin:showToc()
    -- Resolved here rather than inside TocMenu so the view never has to know
    -- about Settings or the cache key. A missing cover is normal (the book was
    -- never cached whole), and Cover.resolve logs which case it was.
    --
    -- 目录页封面优先用原图：这里只有一张图、按显示尺寸缩放并进共享缓存，
    -- 用原图（如 bid_5143 的 700x980）直缩实测比过 240x336 缩略图锐利约
    -- 34%（2026-10-24 定量对比）。缩略图是给书架一页 7 张的低开销设计的，
    -- 目录页不该跟着用；原图缺失时仍回退 Cover.resolve（缩略图→原图）。
    local cover_path
    local ok_src, src = pcall(Cover.source_path, self.settings, self.current_key)
    if ok_src and src and lfs.attributes(src, "mode") == "file" then
        cover_path = src
    else
        local ok, path = pcall(Cover.resolve, self.settings, self.current_key)
        if ok then
            cover_path = path
        else
            logger.err("showToc: cover lookup raised:", tostring(path))
        end
    end
    local comment_sync = self.comment_sync
    if (tonumber(self.current_book and self.current_book.book_id) or 0) > 0 then
        comment_sync = nil
        for _chapter_index, chapter in ipairs((self.current_catalog or {}).chapters or {}) do
            if chapter.comment_aid == nil then
                logger.warn("comments: missing source article mapping; disabling sync",
                    tostring(chapter.aid))
                comment_sync = nil
                break
            end
            if chapter.comment_mapping_verified == nil then
                logger.warn("comments: source article mapping absent; disabling sync",
                    tostring(chapter.aid))
                comment_sync = nil
                break
            end
            if chapter.comment_mapping_verified == true
                and (tonumber(chapter.comment_aid) or 0) > 0 then
                comment_sync = self.comment_sync
            end
        end
    end
    return TocView.show{
        title = self.current_book and self.current_book.title or _("目录"),
        catalog = self.current_catalog,
        book = self.current_book,
        cover_path = cover_path,
        deps = {
            -- Optional UI diagnostics are owned by the standalone Screenshot Tool.
            snapshot = function(tag, delay)
                return self:requestDiagnosticScreenshot(tag, delay)
            end,
            -- Passed explicitly so the view never has to reconstruct the key from
            -- book fields: a book opened from the cached bookshelf has no aid and
            -- no sid, and TocMenu._is_cached used to fall back to those.
            key = self.current_key,
            cache = {
                is_cached = function(_, aid)
                    return self.cache:is_cached(self.current_key, aid)
                end,
            },
            sync = comment_sync,
            -- Powers the "缓存全书评论" row: how many chapters already have
            -- comments on disk. One COUNT(DISTINCT) rather than a query per
            -- chapter, because the row is rebuilt on every catalogue open.
            comment_chapters = function()
                if (tonumber(self.current_book and self.current_book.book_id) or 0) > 0 then
                    return 0
                end
                local db = CommentStore.open(
                    self.settings:bookDir(self.current_key or "default"),
                    (tonumber(self.current_book and self.current_book.book_id) or 0) > 0
                        and "new-content" or nil)
                if not db then
                    return 0
                end
                local count = CommentStore.count_chapters(db)
                CommentStore.close(db)
                return count
            end,
            -- b30: 目录页评论状态行用——某评论卷（aid）在磁盘上有没有正文。
            comment_stored_count = function(aid)
                local db = CommentStore.open(
                    self.settings:bookDir(self.current_key or "default"),
                    "new-content")
                if not db then return 0 end
                local n = CommentStore.count(db, tonumber(aid) or 0)
                CommentStore.close(db)
                return n
            end,
            on_open_chapter = function(chapter)
                self:openChapter(chapter)
            end,
            on_refresh_catalog = function()
                -- refresh=true, or this row would re-serve the very catalogue
                -- the reader is asking to refresh -- openShelfBook now answers
                -- from disk and would make the button do nothing at all.
                self:openBook(self.current_book, { refresh = true })
            end,
            -- One row, not four. 缓存整本书 / 导出整本书 / 合并入库 were three
            -- reader-facing steps for a single filesystem result, and the fourth
            -- (缓存全书评论) is a step inside the first. The label flips on whether
            -- the merged book is already in the library.
            in_library = function()
                return self:isInLibrary()
            end,
            on_download = function()
                self:downloadToLibrary()
            end,
            on_update = function()
                self:updateInLibrary()
            end,
            on_open_whole_book = function()
                self:openWholeBook()
            end,
        },
    }
end

-- ------------------------------------------------------- the two actions ---

--- Where the merged EPUB for the open book would live, or nil when there is no
--- book open / no usable library directory. Same computation Export:output_path
--- does, kept here so the UI can ask "is this already in my library?" without
--- building an exporter.
function LightNovelPlugin:libraryBookPath()
    local key = self.current_key
    if not key then return nil end
    local export = Export:new{
        settings = self.settings,
        cache = self.cache,
        client = self.client,
        store = CommentStore,
        book = self.current_book or {},
        catalog = self.current_catalog or { chapters = {} },
        key = key,
    }
    local ok, path = pcall(function() return export:output_path() end)
    if not ok then
        logger.err("libraryBookPath raised:", tostring(path))
        return nil
    end
    return path
end

--- Is the merged book already sitting in the reader's library?
---
--- This is what decides whether the one visible row reads 下载入库 or 库中书更新.
--- Guessing from the chapter cache instead would be wrong: chapters on disk and a
--- published book are different things, and a book whose chapters are all cached
--- but whose EPUB was never built is exactly the case that needs 入库.
function LightNovelPlugin:isInLibrary()
    local path = self:libraryBookPath()
    if not path then return false end
    return lfs.attributes(path, "mode") == "file"
end

--- 按当前白名单重算当前目录的评论映射，有变化就写回磁盘。
---
--- 映射是 (book_id, volume_id, source_article_id) 与白名单的纯函数；白名单
--- 扩充后，早前下载时写下的目录里 comment_mapping_verified 仍是 false。
--- 整本已缓存的书点「库中书更新」走的是"已是最新"分支，不经过
--- cacheWholeBook 里的重算，于是缺口判断读到的永远是旧值、评论永远没有
--- 入口补上（桌游咖 bid_31607 实测卡在这）。返回是否至少有一章拿到了已
--- 验证映射。
function LightNovelPlugin:refreshCommentMapping()
    local book_id = tonumber(self.current_book and self.current_book.book_id) or 0
    local catalog = self.current_catalog
    if book_id <= 0 or type(catalog) ~= "table" then
        return false
    end
    local changed = false
    local verified = 0
    for _i, chapter in ipairs(catalog.chapters or {}) do
        if chapter.volume_id then
            -- 白名单优先；行上已带运行时核验结果（b21）且候选未变时保持已
            -- 验证，否则每次重算都会把运行时标记抹掉、每轮重新打接口。
            local candidate, is_verified, aid =
                BookCatalog.shelf_comment_mapping(book_id, chapter)
            candidate = tonumber(candidate) or 0
            is_verified = is_verified == true
            aid = tonumber(aid) or 0
            -- nil 和 false 都按"无"比较，避免旧目录缺字段时每次都误判成有变化。
            if (tonumber(chapter.comment_candidate_aid) or 0) ~= candidate
                or (chapter.comment_mapping_verified == true) ~= is_verified
                or (tonumber(chapter.comment_aid) or 0) ~= aid then
                chapter.comment_candidate_aid = candidate
                chapter.comment_mapping_verified = is_verified
                chapter.comment_aid = aid
                changed = true
            end
            if is_verified then
                verified = verified + 1
            end
        end
    end
    if changed then
        logger.info("refreshCommentMapping: updated mapping for book ",
            tostring(book_id), " verified chapters= ", tostring(verified))
        pcall(function()
            self.cache:save_catalog(self.current_key or "default", {
                sid = catalog.sid or 0,
                title = catalog.title,
                chapters = catalog.chapters,
            })
        end)
    end
    return verified > 0
end

--- 运行时评论映射核验（b21）。
---
--- 白名单是人工核验的固化结果，但"每本新书都要人工核验一遍"正是评论获取
--- 层出不穷问题的根源（读者看到的就是"这本书获取评论又失败"）。这套核验
--- 本身是纯机器可判的：候选 aid 帖子的 page_info.count 与书架卷声明的
--- volume_comment_count 逐卷精确相等——本月 20 余卷人工入库（16484/1338/
--- 31607/5143）用的就是同一条标准。这里在下载链路上现场执行同一标准：
--- 相等的卷直接标记已验证并写回目录，白名单仍优先（人工核过的卷不再联网）。
--- 数不等（重置版合卷、站方未把旧帖归属到新卷）或接口失败保持未验证，
--- fail-closed 语义不变。返回是否有章节被新标记。
function LightNovelPlugin:verifyCommentMappingsAtRuntime(book_id, chapters)
    local client = self.client
    if not client or type(chapters) ~= "table" then return false end
    -- 卷 → {candidate, declared, verified, chapters}
    local volumes = {}
    for _i, chapter in ipairs(chapters) do
        local vid = tonumber(chapter.volume_id) or 0
        if vid > 0 then
            local v = volumes[vid]
            if not v then
                v = {
                    candidate = tonumber(chapter.comment_candidate_aid)
                        or tonumber(chapter.source_article_id) or 0,
                    declared = tonumber(chapter.volume_comment_count) or 0,
                    verified = false,
                    chapters = {},
                }
                volumes[vid] = v
            end
            v.chapters[#v.chapters + 1] = chapter
            if chapter.comment_mapping_verified == true then
                v.verified = true
            end
        end
    end
    local changed = false
    for vid, v in pairs(volumes) do
        -- 已验证（白名单或此前运行时核验过）不动；声明 0 评论或没有源帖
        -- 线索的卷没有可核验的东西，也不发请求。
        if not v.verified and v.candidate > 0 and v.declared > 0 then
            local ok, payload = pcall(function()
                return client:fetchComments(v.candidate, 1, { timeout = 30 })
            end)
            local count = -1
            if ok and type(payload) == "table" then
                count = tonumber((payload.page_info or {}).count) or -1
            end
            -- 帖子数与书架声明精确相等即通过；对声明的轻微漂移放行。
            --
            -- 站点两套计数不同步是常态：败犬 bid_1338 三个真身卷 12 天内帖子
            -- 数落后声明 1/2/7 条（评论被删、计数缓存不同步，2026-10-24 实测），
            -- 精确相等会把这些真身卷错杀，评论又退回"人工逐本核验"的老路。
            -- 放行窗口收紧在 max(5, 声明的 5%)：实测的错配（重置版合卷声明 0
            -- 而旧帖 60+ 条、串书）差距都在 60 条以上，不会落进窗口。
            local accepted = count > 0
                and (count == v.declared
                    or math.abs(count - v.declared)
                        <= math.max(5, math.floor(v.declared * 0.05)))
            if accepted then
                for _, chapter in ipairs(v.chapters) do
                    chapter.comment_aid = v.candidate
                    chapter.comment_mapping_verified = true
                end
                changed = true
                logger.info("comment mapping runtime-verified: book ",
                    tostring(book_id), " volume ", tostring(vid),
                    " aid ", tostring(v.candidate), " count ", tostring(count))
            else
                -- 数不等也留痕：重置版合卷（站方声明 0 而旧帖有评论）与网络
                -- 失败在这里可分辨，事后排查不必再猜。
                logger.info("comment mapping runtime check failed: book ",
                    tostring(book_id), " volume ", tostring(vid),
                    " aid ", tostring(v.candidate),
                    " thread_count=", tostring(count),
                    " shelf_declared=", tostring(v.declared))
            end
        end
    end
    return changed
end

--- 这本书有已验证的评论映射，但库里的评论还是空的？
---
--- 只对有映射的新书有意义（旧连载按章 aid 走，不算）。用来决定"库中书更新"在
--- "已是最新"时要不要继续跑评论 → 重出版：没有缺口就维持原来的"已是最新"，
--- 有缺口才多花一次导出。
function LightNovelPlugin:needsCommentBackfill()
    if (tonumber(self.current_book and self.current_book.book_id) or 0) <= 0 then
        return false
    end
    -- 磁盘目录可能写于白名单扩充之前：先按当前白名单重算映射再判断缺口，
    -- 否则下面的 aid 收集永远为空、"已是最新"直接返回，评论没有入口。
    if not self:refreshCommentMapping() then
        return false
    end
    local aids, seen = {}, {}
    for _i, chapter in ipairs((self.current_catalog or {}).chapters or {}) do
        local aid = chapter.comment_mapping_verified == true
            and tonumber(chapter.comment_aid) or nil
        if aid and aid > 0 and not seen[aid] then
            seen[aid] = true
            aids[#aids + 1] = aid
        end
    end
    if #aids == 0 then
        -- 没有一条已验证映射：评论本来就抓不了，别拿这个理由去重出版。
        return false
    end
    local db = CommentStore.open(
        self.settings:bookDir(self.current_key or "default"), "new-content")
    if not db then
        logger.warn("needsCommentBackfill: comment store unavailable")
        return false
    end
    local missing = 0
    for _i, aid in ipairs(aids) do
        if (tonumber(CommentStore.count(db, aid)) or 0) == 0 then
            missing = missing + 1
        end
    end
    CommentStore.close(db)
    if missing > 0 then
        logger.info("needsCommentBackfill: ", tostring(missing), "of",
            tostring(#aids), "mapped volumes have no stored comments")
    end
    return missing > 0
end

--- 下载入库: one tap, and the book ends up complete in the library.
---
--- This is deliberately a thin name over cacheWholeBook rather than a new
--- pipeline. cacheWholeBook already fetches the catalogue, downloads every missing
--- readable chapter with retry and resume, refreshes the catalogue from the server
--- and then runs the comments -> EPUB chain; Export:output_path writes that EPUB
--- straight into settings:libraryDir(), which is the reader's actual library. So
--- "cache, then export, then merge into the library" were three reader-facing
--- steps for one filesystem result, and only the first two names survive here.
function LightNovelPlugin:downloadToLibrary()
    self:cacheWholeBook()
end

--- 库中书更新: this book only.
---
--- Checks the server's revision and chapter list, downloads just what is missing,
--- and republishes over the existing library copy. A changed revision re-fetches
--- every chapter, because that means a body may have been edited rather than
--- merely appended.
function LightNovelPlugin:updateInLibrary()
    self:checkForUpdates()
end

-- ---------------------------------------------------------------- chapter ---

--- Open one volume, downloading it first unless it is already cached.
--- Collect the chapters an unlock strategy would buy for `chapter`.
--- Returns the list of chapter ids plus a human label, so the confirmation
--- dialog can state the exact cost before any currency is spent.
local function unlockScope(self, chapter)
    local strategy = Menu.getUnlockStrategy(self.settings)
    local chapters = (self.current_catalog or {}).chapters or {}
    -- `ids` MUST start as a table. It used to be nil here, and both the
    -- "volume" and "book" branches below do `ids[#ids + 1]`, so tapping
    -- "unlock volume" or "unlock whole book" raised "attempt to index a nil
    -- value" inside the menu callback -- BEFORE the ConfirmBox was built, so the
    -- user saw literally nothing happen. Only the single-chapter branch worked.
    local ids, label, cancel_text = {}, nil, nil

    if strategy.key == "volume" then
        local vid = tonumber(chapter.volume_id)
        local count = 0
        for _i, ch in ipairs(chapters) do
            if (tonumber(ch.volume_id) or 0) == vid and ch.locked then
                count = count + 1
            end
        end
        local name = tostring(chapter.volume_title or "")
        for _i, ch in ipairs(chapters) do
            if (tonumber(ch.aid) or 0) == (tonumber(chapter.aid) or -1) then
                name = tostring(ch.volume_title or name)
                break
            end
        end
        label = string.format(
            _("《%s》第 %s 卷有 %d 章未解锁。\n\n解锁整卷需要 %d 轻币。"),
            tostring(self.current_book.title or ""), name, count, count)
        cancel_text = _("解锁整卷（%d 轻币）")
        cancel_text = string.format(cancel_text, count)
        for _i, ch in ipairs(chapters) do
            if (tonumber(ch.volume_id) or 0) == vid and ch.locked then
                ids[#ids + 1] = tonumber(ch.aid)
            end
        end
    elseif strategy.key == "book" then
        local count = 0
        for _i, ch in ipairs(chapters) do
            if ch.locked then
                count = count + 1
                ids[#ids + 1] = tonumber(ch.aid)
            end
        end
        label = string.format(
            _("《%s》全书有 %d 章未解锁。\n\n解锁全书需要 %d 轻币。"),
            tostring(self.current_book.title or ""), count, count)
        cancel_text = _("解锁全书（%d 轻币）")
        cancel_text = string.format(cancel_text, count)
    else
        ids = { tonumber(chapter.aid) }
        label = _("本章需要 1 轻币解锁。")
        cancel_text = _("解锁本章（1 轻币）")
    end

    return ids, label, cancel_text
end

--- Open a chapter that came from the server shelf.
function LightNovelPlugin:openShelfChapter(chapter, comment_count)
    local cache = self.cache
    local client = self.client
    local book_key = self.current_key

    self:showSpinner(string.format(_("正在下载：%s"),
        tostring(chapter.title or "")))

    local function run()
        local started, err = self.worker:start{
            timeout = 180,
            queue = true,
            on_done = function(result)
                self:hideSpinner()
                if not result or not result.ok then
                    UIManager:show(InfoMessage:new{
                        text = _("下载失败：")
                            .. tostring(result and result.error or "unknown"),
                    })
                    return
                end
                local value = result.value or {}
                if value.path then
                    self:showChapter(chapter)
                    return
                end
                if value.need_unlock then
                    -- A locked chapter: price the configured scope, then only
                    -- spend once the reader confirms.
                    self:confirmUnlock(chapter, function()
                        self:openShelfChapter(chapter, comment_count)
                    end)
                    return
                end
                UIManager:show(InfoMessage:new{
                    text = _("无法获取正文：") .. tostring(value.error or "unknown"),
                })
            end,
            task = function()
                return cache:fetch_shelf_chapter(client, book_key, chapter,
                    comment_count)
            end,
        }
        if not started then
            self:hideSpinner()
            UIManager:show(InfoMessage:new{
                text = _("无法启动后台任务：") .. tostring(err or "unknown"),
            })
        end
    end

    run()
end

--- Ask before spending 轻币, then unlock every chapter in the chosen scope and
--- continue. The dialog states the cost; cancelling spends nothing.
function LightNovelPlugin:confirmUnlock(chapter, on_done)
    local ids, label, ok_text = unlockScope(self, chapter)
    if #ids == 0 then
        UIManager:show(InfoMessage:new{ text = _("没有需要解锁的章节") })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = label,
        ok_text = ok_text,
        cancel_text = _("取消"),
        ok_callback = function()
            local client = self.client
            local book_dir = nil
            -- Each success spends 1 轻币, so this runs only after the reader
            -- confirmed the quoted cost. It runs in the worker because a volume
            -- or book scope is up to 55 sequential requests; on the UI thread
            -- that freezes the e-ink screen and reads as a hang.
            self:showSpinner(_("正在解锁…"))
            local started, err = self.worker:start{
                timeout = math.max(120, 30 * #ids),
                -- Spending currency is the one action that must never be lost to
                -- a busy worker, so it queues.
                queue = true,
                on_done = function(result)
                    self:hideSpinner()
                    if not result or not result.ok then
                        UIManager:show(InfoMessage:new{
                            text = _("解锁失败：")
                                .. tostring(result and result.error or "unknown"),
                        })
                        return
                    end
                    local value = result.value or {}
                    local done = tonumber(value.done) or 0
                    local failed = tonumber(value.failed) or 0
                    logger.info("unlock done:", tostring(done), "failed:",
                        tostring(failed))
                    -- Mark what was actually bought so a later open does not
                    -- ask again for the same chapters.
                    local chapters = (self.current_catalog or {}).chapters or {}
                    for _i, cid in ipairs(value.bought or {}) do
                        for _i, ch in ipairs(chapters) do
                            if (tonumber(ch.aid) or 0) == (tonumber(cid) or -1) then
                                ch.locked = false
                            end
                        end
                    end
                    self.cache:save_catalog(self.current_key, self.current_catalog)
                    UIManager:show(InfoMessage:new{
                        text = string.format(_("已解锁 %d 章，失败 %d 章"),
                            done, failed),
                    })
                    if done > 0 then
                        on_done()
                    end
                end,
                task = function(context)
                    local bought, done, failed = {}, 0, 0
                    for _i, cid in ipairs(ids) do
                        context.checkCancelled()
                        local ok, uerr = client:unlockChapter(cid,
                            { timeout = 30 })
                        if ok then
                            done = done + 1
                            bought[#bought + 1] = cid
                        else
                            failed = failed + 1
                            logger.err("unlock failed chapter=", tostring(cid),
                                "err=", tostring(uerr))
                        end
                        context.emit{ done = done, failed = failed }
                    end
                    return { done = done, failed = failed, bought = bought }
                end,
            }
            if not started then
                self:hideSpinner()
                UIManager:show(InfoMessage:new{
                    text = _("无法启动后台任务：") .. tostring(err or "unknown"),
                })
            end
        end,
    })
end

function LightNovelPlugin:openChapter(chapter)
    local key = self.current_key

    -- Shelf chapters live in the new id space and are read as paragraph arrays,
    -- so they bypass the legacy article fetch entirely.
    if (tonumber(chapter.book_id) or 0) > 0 then
        -- The new endpoint exposes comments at the source-volume article level.
        -- Never query with chapter_id; use the verified volume source aid.
        local comment_aid = chapter.comment_mapping_verified == true
            and (tonumber(chapter.comment_aid) or 0) or 0
        local db = comment_aid > 0
            and CommentStore.open(self.settings:bookDir(key), "new-content") or nil
        local comment_count = db and CommentStore.count(db, comment_aid) or 0
        if db then CommentStore.close(db) end
        return self:openShelfChapter(chapter, comment_count)
    end

    if self.cache:is_cached(key, chapter.aid) then
        self:showChapter(chapter)
        return
    end

    local client = self.client
    local cache = self.cache
    local book_key = key
    local target = chapter

    -- Comment count is read up front so a chapter that already has cached
    -- comments shows the marker on first open.
    local db = CommentStore.open(self.settings:bookDir(book_key))
    local comment_count = db and CommentStore.count(db, target.aid) or 0
    if db then
        CommentStore.close(db)
    end

    self:showSpinner(string.format(_("正在下载：%s"),
        tostring(chapter.title or "")))

    local started, err = self.worker:start{
        timeout = 180,
        queue = true,
        on_done = function(result)
            self:hideSpinner()
            if not result or not result.ok then
                UIManager:show(InfoMessage:new{
                    text = _("下载失败：")
                        .. tostring(result and result.error or "unknown"),
                })
                return
            end
            local value = result.value or {}
            if not value.path then
                UIManager:show(InfoMessage:new{
                    text = _("无法获取正文：") .. tostring(value.error or "unknown"),
                })
                return
            end
            self:showChapter(target)
        end,
        task = function(context)
            local path, fetch_err = cache:fetch_chapter(client, book_key,
                target, comment_count)
            if not path then
                return { error = fetch_err }
            end
            return { path = path }
        end,
    }
    if not started then
        self:hideSpinner()
        UIManager:show(InfoMessage:new{
            text = _("无法启动后台任务：") .. tostring(err or "unknown"),
        })
    end
end

--- Open the merged whole book if one has been published, else the chapter file.
---
--- This is the weread rule, and it is the whole point of the change:
--- ReaderUI:showReader records EVERY opened path in KOReader's read history
--- (apps/reader/readerui.lua:511 -> readhistory.lua, persisted to
--- <data_dir>/history.lua), unconditionally and with no library scoping. So
--- opening each chapter as its own .html put one "正在阅读" row per chapter.
--- weread avoids that structurally by only ever handing the reader one merged
--- file per title (weread/ui/library.lua:1601 -> the full-book EPUB), and it
--- never touches readhistory at all.
---
--- Opening from the plugin's shelf therefore opens the book. Chapter taps inside
--- the catalogue still open the chapter file -- that is what gives per-chapter
--- navigation and the interactive comment panel -- and those are kept out of the
--- history separately (see suppress_chapter_history).
function LightNovelPlugin:openWholeBook()
    local key = self.current_key
    local catalog = self.current_catalog
    if not key or not catalog then
        UIManager:show(InfoMessage:new{ text = _("请先打开一本书") })
        return false
    end
    local exporter = Export:new{
        settings = self.settings,
        cache = self.cache,
        client = self.client,
        store = CommentStore,
        store_namespace = (tonumber(self.current_book and self.current_book.book_id) or 0) > 0
            and "new-content" or nil,
        comment_scope = (tonumber(self.current_book and self.current_book.book_id) or 0) > 0
            and "volume" or "chapter",
        key = key,
        book = self.current_book or { title = catalog.title or key },
        catalog = catalog,
        worker = nil,
    }
    local path = exporter:output_path()
    if not path or lfs.attributes(path, "mode") ~= "file" then
        return false, "not_published"
    end
    logger.info("openWholeBook:", path)
    return self:openDocument(path)
end

--- Open an arbitrary document with the plugin's hooks installed.
function LightNovelPlugin:openDocument(path)
    -- ReaderUI:showReader is the only supported way to open a document --
    -- readerui.lua:613 calls it "the *only* safe way to instantiate a new
    -- ReaderUI instance". FileManager has no showReader on this build (it only
    -- defines 55 methods and showReader is not one of them), so the previous
    -- FileManager:showReader(path) was an attempt to call a nil value.
    --
    -- The call returns nothing useful: the new instance is published as
    -- ReaderUI.instance (readerui.lua:546) and after_open_callback is invoked
    -- with NO arguments (readerui.lua:526), so the hooks have to be installed
    -- from inside the callback. fanqie.koplugin does exactly this.
    local ok, err = pcall(function()
        if not ReaderUI.instance then
            UIManager:broadcastEvent(Event:new("SetupShowReader"))
        end
        ReaderUI:showReader(path, nil, true, nil, function()
            self:installHooks(ReaderUI.instance)
        end)
    end)
    if not ok then
        logger.info("showReader failed:", tostring(err))
        UIManager:show(InfoMessage:new{
            text = _("无法打开文件：") .. tostring(err),
        })
        return false
    end
    return true
end

function LightNovelPlugin:showChapter(chapter)
    local path = self.cache:chapter_path(self.current_key, chapter.aid)
    return self:openDocument(path)
end

--- Keep the per-chapter cache files out of KOReader's "正在阅读".
---
--- readerui.lua:511 calls `readhistory:addItem(file)` on every open, and
--- readhistory.lua:12 persists one row per path into <data_dir>/history.lua. The
--- plugin's chapter HTML lives under the plugin data dir, so every chapter opened
--- from the catalogue became its own history entry -- which is the pollution the
--- user reported.
---
--- weread does not need this because it never opens a chapter file. We do, because
--- the catalogue is how per-chapter navigation and the comment panel work. So wrap
--- ReadHistory.addItem once and drop only paths inside our own cache. The same
--- technique is already proven on this device: the bundled fanqie.koplugin ships
--- patches/core.lua doing exactly this for its own cache prefix.
---
--- Guarded so a second call cannot stack wrappers, and it always delegates for
--- every other path -- this suppresses our rows, nothing else.
--- @param plugin the plugin instance: this is a plain function, not a method,
--- and it needs plugin.settings. It is invoked as pcall(suppress_chapter_history,
--- self) -- calling it without the instance gave `self` == nil, the body raised on
--- `self.settings`, and pcall swallowed that, so the whole thing silently did
--- nothing: no log line, no suppression, and the chapter rows stayed in 正在阅读.
suppress_chapter_history = function(plugin)
    local ReadHistory = require("readhistory")
    if ReadHistory.__lightnovel_patched then
        return false
    end
    local original = ReadHistory.addItem
    if type(original) ~= "function" then
        logger.warn("history: ReadHistory.addItem missing; 正在阅读 will list"
            .. " every chapter again")
        return false
    end
    -- settings:data_dir() is <DataStorage:getDataDir()>/lightnovel, so this is
    -- exactly the chapter cache root without needing a second DataStorage handle.
    local marker = plugin.settings:data_dir() .. "/books/"
    ReadHistory.addItem = function(self, file, ts, no_flush)
        if type(file) == "string" and file:sub(1, #marker) == marker then
            logger.dbg("history: skipped chapter cache entry", file)
            return
        end
        return original(self, file, ts, no_flush)
    end
    ReadHistory.__lightnovel_patched = true

    -- Sweep the rows that are ALREADY there. Wrapping addItem only stops new
    -- ones, and an earlier attempt to remove them by editing history.lua did not
    -- stick: the running KOReader holds the list in memory and rewrites the file
    -- from that copy, so the two chapter rows came straight back. Doing it here
    -- fixes the in-memory list too, which is what makes it survive.
    local hist = ReadHistory.hist
    if type(hist) ~= "table" then
        logger.warn("history: ReadHistory.hist is", type(hist),
            "-- cannot sweep existing chapter rows")
    else
        local kept, dropped = {}, 0
        for _i, entry in ipairs(hist) do
            local file = type(entry) == "table" and entry.file or nil
            if type(file) == "string" and file:sub(1, #marker) == marker then
                dropped = dropped + 1
            else
                kept[#kept + 1] = entry
            end
        end
        if dropped > 0 then
            for i = #hist, 1, -1 do
                hist[i] = nil
            end
            for i = 1, #kept do
                hist[i] = kept[i]
            end
            -- Persist now rather than waiting for an unrelated flush.
            pcall(function() ReadHistory:_flush() end)
            logger.info("history: removed", tostring(dropped),
                "chapter rows already in 正在阅读")
        end
        logger.info("history: chapter cache suppressed from 正在阅读")
    end
    return true
end

--- Merge every already-cached book into one EPUB in the library.
---
--- The backfill for books downloaded before this existed: they were only ever a
--- directory of chapter HTML under the plugin data dir, invisible to the library
--- and one history row per chapter. Sequential and inline -- a worker round trip
--- per book, one at a time, would make a batch of 80 books impractical.
function LightNovelPlugin:publishAllToLibrary()
    local books = self.cache:list_cached_books()
    if #books == 0 then
        UIManager:show(InfoMessage:new{ text = _("没有已缓存的书籍") })
        return false
    end
    -- Unlike the other two jobs this one runs on the UI thread: the library
    -- directory and the comment database are both parent-side and a child must
    -- not write either. So 暂停 cannot stop it mid-book -- it stops it BEFORE the
    -- next book, via should_continue, and 继续 picks up at summary.stopped_at.
    -- A pause therefore lands between books, never inside one, and that is stated
    -- in the dialog rather than pretended away.
    local state = { index = 1, total = #books, paused = false, exiting = false }
    local function run_slice(from)
        state.index = from
        local slice
        local ok, err = pcall(function()
            slice = Export:publish_all({
                settings = self.settings,
                cache = self.cache,
                client = self.client,
                -- publish_all uses each new catalog's verified comment_aid values;
                -- contaminated rows keyed by chapter_id are never selected.
                store = CommentStore,
                comment_scope = "auto",
                start_index = from,
                should_continue = function()
                    return not state.paused and not state.exiting
                end,
            }, function(index, total, path)
                self:reportTaskProgress{
                    done = index, total = total,
                    title = string.format(_("合并入库 %d/%d…"), index, total),
                }
            end)
        end)
        return ok, err, slice
    end

    self:beginTask{
        kind = "publish",
        title = _("正在把已缓存书籍合并入库…"),
        description = _("可以隐藏到后台；暂停会在处理完当前这本后生效。"),
        on_pause = function()
            -- 返回 true：这是"处理完当前这本就停"的延迟暂停，确实已经生效。
            state.paused = true
            return true
        end,
        on_resume = function()
            if state.exiting then return end
            state.paused = false
            local resume = function()
                local ok, err, slice = run_slice(state.index)
                self:_finishPublish(ok, err, slice, state)
            end
            UIManager:scheduleIn(0, resume)
        end,
        on_exit = function()
            state.exiting = true
            self:endTask()
        end,
    }

    local ok, err, slice = run_slice(1)
    self:_finishPublish(ok, err, slice, state)
    return ok
end

--- Report the outcome of one merge slice. A slice that stopped early is a pause,
--- not a completion, and must not claim to have merged the whole shelf.
function LightNovelPlugin:_finishPublish(ok, err, slice, state)
    if not ok then
        logger.err("publishAll raised:", tostring(err))
        self:endTask()
        UIManager:show(InfoMessage:new{
            text = _("合并入库失败：") .. tostring(err),
        })
        return
    end
    slice = slice or {}
    if state.exiting then
        logger.info("publishAll: stopped by the reader at book",
            tostring(slice.processed or 0))
        return
    end
    if slice.stopped_at then
        logger.info("publishAll: paused,", tostring(slice.processed or 0),
            "of", tostring(slice.total or 0), "merged; resume at",
            tostring(slice.stopped_at))
        -- Resume from the first book that was NOT merged. Leaving state.index at
        -- the start of this slice would redo every book the pause just finished,
        -- which on a long shelf is exactly the cost pausing was meant to avoid.
        state.index = tonumber(slice.stopped_at) or state.index
        if STATE.task then STATE.task.paused = true end
        return
    end
    self:endTask()
    local dir = self.settings:libraryDir()
    logger.info("publishAll: ok=", tostring(slice.ok), "failed=",
        tostring(slice.failed), "dir=", tostring(dir))
    local text = string.format(_("已合并 %d 本到书库（失败 %d 本）\n%s"),
        tonumber(slice.ok) or 0, tonumber(slice.failed) or 0, tostring(dir))
    if slice.failed and slice.failed > 0 and slice.reasons and slice.reasons[1] then
        text = text .. "\n" .. tostring(slice.reasons[1])
    end
    UIManager:show(InfoMessage:new{ text = text })
end

-- ----------------------------------------------------------------- reader --

function LightNovelPlugin:installHooks(reader_ui)
    if not reader_ui then
        return false
    end
    self.reader_ui = reader_ui
    -- The link module exists only after the document is open, so retry once via
    -- the onReaderReady hook when it is not there yet.
    local installed, why = self.hooks:install(reader_ui)
    if not installed then
        -- "not ready" and "KOReader's link module has no onTap" need different
        -- reactions, and the retry only makes sense for the first.
        logger.warn("reader hooks not installed:", tostring(why),
            "(retry happens on the next ReaderReady)")
    end
    return true
end

--- KOReader dispatches this to the plugin when the reader finishes opening.
--- ReaderFooter/ReaderHighlight/ReaderPaging implement the same hook, and
--- weread.koplugin hooks it from its plugin object too.
function LightNovelPlugin:onReaderReady()
    local reader_ui = self.reader_ui or self.ui
    if reader_ui then
        self.hooks:install(reader_ui)
    end
end

--- True when a tap fell in the left/right page-turn zone, so the comment link
--- must yield to the page turn instead of opening the panel.
function LightNovelPlugin:isPageTurnZone(ges)
    -- Screen is bound once at file scope; the old function-local copy here
    -- shadowed it and was what left line 143 reading a nil global.
    if not ges or not ges.pos then
        return false
    end
    local x = ges.pos.x
    if not x then
        return false
    end
    local width = Screen:getWidth()
    if not width then
        return false
    end
    -- Match KOReader's own edge width so the behaviour feels native.
    local edge = math.max(40, math.floor(width * 0.2))
    return x <= edge or x >= (width - edge)
end

-- --------------------------------------------------------------- comments --

function LightNovelPlugin:showComments(aid)
    local chapter = BookCatalog.find_by_aid(self.current_catalog, aid)
    local comment_aid = tonumber(aid)
    if (tonumber(self.current_book and self.current_book.book_id) or 0) > 0 then
        comment_aid = chapter and chapter.comment_mapping_verified == true
            and (tonumber(chapter.comment_aid) or 0) or 0
    end
    if not comment_aid or comment_aid <= 0 then
        UIManager:show(InfoMessage:new{
            text = _("该章节没有可用的评论来源映射，未查询评论以避免串书。"),
        })
        return false
    end
    local title = chapter and chapter.title or ""
    local comment_title = title
    if chapter and (tonumber(self.current_book and self.current_book.book_id) or 0) > 0 then
        -- Legacy source comments are volume-scoped, not split-chapter-scoped.
        comment_title = tostring(chapter.volume_title or "本卷") .. "（卷评论，共享于本卷章节）"
    end
    local all_aids, seen_aids = {}, {}
    for _i, c in ipairs((self.current_catalog or {}).chapters or {}) do
        local target_aid
        if (tonumber(self.current_book and self.current_book.book_id) or 0) > 0 then
            target_aid = c.comment_mapping_verified == true
                and tonumber(c.comment_aid) or nil
        else
            target_aid = tonumber(c.aid)
        end
        if target_aid and target_aid > 0 and not seen_aids[target_aid] then
            seen_aids[target_aid] = true
            all_aids[#all_aids + 1] = target_aid
        end
    end
    return CommentPanel.show{
        aid = comment_aid,
        title = comment_title,
        deps = {
            store = CommentStore,
            book_dir = self.settings:bookDir(self.current_key or "default"),
            store_namespace = (tonumber(self.current_book and self.current_book.book_id) or 0) > 0
                and "new-content" or nil,
            sync = self.comment_sync,
            client = self.client,
            worker = self.worker,
            all_aids = all_aids,
        },
    }
end

--- A background sync changed a comment count; update the cached chapter so the
--- marker is not stale on the next open.
function LightNovelPlugin:onCommentCountChanged(aid, count)
    local key = self.current_key
    if not key then
        return
    end
    local is_new_content_book =
        (tonumber(self.current_book and self.current_book.book_id) or 0) > 0
    local chapters = (self.current_catalog or {}).chapters or {}
    local mapped = false
    for _chapter_index, chapter in ipairs(chapters) do
        -- New-content books are keyed by the volume source article; legacy books
        -- by the chapter aid. Falling back from one to the other crosses the two
        -- ID spaces and is exactly how a wrong comment count reaches a chapter.
        local comment_aid
        if is_new_content_book then
            comment_aid = chapter.comment_mapping_verified == true
                and tonumber(chapter.comment_aid) or nil
        else
            comment_aid = tonumber(chapter.aid)
        end
        if comment_aid and comment_aid > 0 and comment_aid == tonumber(aid) then
            mapped = true
            local path = self.cache:chapter_path(key, chapter.aid)
            if Content.has_comment_marker(path) then
                local changed, err = Content.rewrite_marker(path, count,
                    chapter.aid)
                if not changed and err then
                    logger.dbg("marker rewrite skipped:", tostring(err))
                end
            end
        end
    end
    if not mapped and not is_new_content_book then
        -- Legacy only: its cache path is keyed by the chapter aid directly.
        -- For a new-content book there is no chapter whose aid equals the volume
        -- source article, so this branch must not run.
        local path = self.cache:chapter_path(key, aid)
        if Content.has_comment_marker(path) then
            Content.rewrite_marker(path, count, aid)
        end
    end
end

-- ------------------------------------------------------------------- misc --

function LightNovelPlugin:showSpinner(text)
    -- Full-screen cover, not InfoMessage. InfoMessage is a small centred box
    -- that leaves the file manager home visible behind it, and the reader asked
    -- that nothing behind the plugin show through while it works. Idempotent:
    -- LibraryMenu:_open raises this before closing itself, then openShelfBook
    -- raises it again, and both must end up as one overlay.
    self:hideSpinner()
    self._spinner = Menu.showLoading(text)
end

function LightNovelPlugin:hideSpinner()
    if self._spinner then
        pcall(function() UIManager:close(self._spinner) end)
        self._spinner = nil
    end
end

-- ------------------------------------------------------------- long tasks ---

--- The one long job allowed at a time, and the dialog that shows it.
---
--- The job lives here, the dialog is only a view of it. That split is the whole
--- reason 隐藏 works: closing the dialog must not be able to stop the work, so
--- nothing about the job's lifetime is owned by a widget the reader can dismiss.
--- Short operations (fetching a catalogue, checking for updates) deliberately keep
--- using showSpinner -- a dialog the reader has to dismiss would be worse than a
--- two-second flash.
--- 当前运行中的任务（模块级，跨插件实例存活）。菜单与 UI 一律经此读取。
function LightNovelPlugin:getTask()
    return STATE.task
end

--- 一键导出诊断日志（反馈通道，b27）。
---
--- 遇到报错的读者只需：菜单 → 导出诊断日志 → USB 连电脑，从 documents 根
--- 目录取走 txt 发回。内容 = 版本印记 + 当前书目/任务状态 + crash.log 里
--- 最近 1000 行插件日志。**绝不读取 settings.lua**（那里有登录凭据），
--- crash.log 按日志规范本就不落凭据，导出侧再double-check 一道。
function LightNovelPlugin:exportDiagnosticLog()
    local function emit(line)
        return line
    end
    local header = {
        emit("lightnovel.koplugin 诊断日志"),
        emit("导出时间: " .. os.date("%Y-%m-%d %H:%M:%S")),
        emit("当前书: " .. tostring(self.current_book and self.current_book.title or "无")
            .. "  key=" .. tostring(self.current_key)),
        emit("任务: " .. tostring(STATE.task and STATE.task.kind or "无")),
        emit(string.rep("=", 48)),
    }
    local tail, total = {}, 0
    local ok, file = pcall(function()
        return io.open("/mnt/us/koreader/crash.log", "r")
    end)
    if ok and file then
        for line in file:lines() do
            total = total + 1
            if line:find("%[LightNovel%]") or line:find("BUILD b") then
                tail[#tail + 1] = line
                if #tail > 1000 then table.remove(tail, 1) end
            end
        end
        file:close()
    else
        tail[#tail + 1] = "(crash.log 读取失败: " .. tostring(file) .. ")"
    end
    local path = "/mnt/us/documents/lightnovel-诊断-"
        .. os.date("%Y%m%d_%H%M") .. ".txt"
    local out = io.open(path, "w")
    if not out then
        logger.err("diagnostic log: write failed", path)
        UIManager:show(InfoMessage:new{ text = _("日志写入失败：") .. path })
        return
    end
    out:write(table.concat(header, "\n"), "\n")
    out:write(table.concat(tail, "\n"), "\n")
    out:close()
    logger.info("diagnostic log exported:", path, "lines=", tostring(#tail),
        "scanned=", tostring(total))
    UIManager:show(InfoMessage:new{
        text = string.format(_("诊断日志已导出（%d 行）\n%s\n\nUSB 连电脑后，在 documents 文件夹里取出发送即可"), #tail, path),
        timeout = 8,
    })
end

function LightNovelPlugin:beginTask(spec)
    self:hideSpinner()
    self:hideTaskDialog()
    STATE.task = spec
    self:showTaskDialog()
    return spec
end

--- Clear the task and its dialog. Safe to call twice: every one of the three jobs
--- finishes on a path where the dialog may already have been torn down.
function LightNovelPlugin:endTask()
    self:hideTaskDialog()
    STATE.task = nil
end

--- 把插件书架铺在任务弹窗下面。
---
--- 目录页的"下载入库"先关闭目录，弹窗下面于是直接是最上层的文件管理器/插件
--- 菜单（读者口中的"回到桌面"）。书架有磁盘缓存，非强制刷新不联网，所以可以
--- 先铺好，再由 beginTask 把进度弹窗盖上去；任务结束后书架仍在，弹窗关掉就是
--- 读者要的"回到书架"。
function LightNovelPlugin:showShelfUnderTask()
    if self:isShelfShown() then return true end
    local ok, menu = pcall(function()
        -- quiet：只画磁盘里已有的书架，不联网、不起加载遮罩（遮罩会盖在下载
        -- 弹窗下面，同时 worker 正忙，书架请求会一直排队到下载结束）。
        return self:showLibrary{ mode = "bookshelf", quiet = true }
    end)
    if not ok or not menu then
        -- 没有登录态、或书架视图构造失败时不要挡住下载本身。
        logger.warn("shelf underlay unavailable:", tostring(menu))
        return false
    end
    STATE.shelf = menu
    -- 和任务弹窗同样的做法：关闭时清掉指针，避免下次误以为书架还在。
    local inherited = menu.onCloseWidget
    menu.onCloseWidget = function(...)
        if type(inherited) == "function" then pcall(inherited, ...) end
        if STATE.shelf == menu then STATE.shelf = nil end
    end
    return true
end

function LightNovelPlugin:isShelfShown()
    return STATE.shelf ~= nil
end

function LightNovelPlugin:showTaskDialog()
    local task = STATE.task
    if not task then return STATE.dialog end
    -- A dialog pointer is not proof of a live dialog. Walking out of the reader
    -- tears the whole widget stack down, and this pointer kept pointing at the
    -- corpse -- so 任务进度 hit the early return below and silently did nothing,
    -- for good: the reader had no way back to the progress, or to 暂停/退出,
    -- without restarting the job. The dialog clears the pointer itself when
    -- UIManager removes it, so a stale one can never be mistaken for a live one.
    if STATE.dialog and STATE.dialog.shown then
        return STATE.dialog
    end
    local dialog = TaskDialog:new{
        title = task.title,
        description = task.description or "",
        on_hide = function() self:hideTaskDialog() end,
        -- 返回值必须透传：TaskDialog 只在 on_pause 返回 true 时才真的切到
        -- "已暂停"，否则会谎报一个没有发生的暂停。
        on_pause = function()
            if type(task.on_pause) == "function" then
                return task.on_pause() == true
            end
            return false
        end,
        on_resume = function()
            if type(task.on_resume) == "function" then task.on_resume() end
        end,
        on_exit = function()
            if type(task.on_exit) == "function" then task.on_exit() end
        end,
    }
    -- Cleared on close so the next 任务进度 builds a fresh dialog instead of
    -- reusing a widget UIManager has already thrown away.
    -- Chained rather than replaced: onCloseWidget is a KOReader hook other
    -- widgets rely on, and silently discarding the inherited one is the kind of
    -- leak that only shows up much later.
    local inherited_close = dialog.onCloseWidget
    dialog.onCloseWidget = function()
        if type(inherited_close) == "function" then pcall(inherited_close) end
        dialog.shown = false
        if STATE.dialog == dialog then
            STATE.dialog = nil
        end
    end
    if task.paused then dialog:setState("paused") end
    dialog.shown = true
    STATE.dialog = dialog
    dialog:show()
    return dialog
end

function LightNovelPlugin:hideTaskDialog()
    local dialog = STATE.dialog
    if not dialog then return end
    STATE.dialog = nil
    dialog.shown = false
    pcall(function()
        -- 关闭必须带刷新提示。裸 UIManager:close 只把组件从窗口栈里摘掉，不把
        -- 弹窗区域标脏（这版 KOReader 只有 refreshtype 存在时才补一次 setDirty），
        -- 墨水屏于是停在弹窗的最后一帧：框体清晰留存、刚点过的按钮文字被
        -- fast 消隐——正是"点了隐藏，按键消失、弹窗没消失"的实测画面
        -- （crash.log 00:16:16 与 00:16:27 两次隐藏都返回 ok，屏幕却纹丝不动）。
        -- full + 弹窗区域：局部整刷一次，把框体连同残影一起擦掉，露出书架。
        UIManager:close(dialog, "full", dialog.dimen)
    end)
end

--- Push a worker progress payload into the dialog, if one is open. Guarded because
--- the worker keeps emitting after the reader has hidden or exited the dialog.
function LightNovelPlugin:reportTaskProgress(state)
    local dialog = STATE.dialog
    do
        local stage = tostring(state and state.stage or "?")
        local seen = PROGRESS_LOG_SEEN[stage] or 0
        if seen < PROGRESS_LOG_PER_STAGE then
            PROGRESS_LOG_SEEN[stage] = seen + 1
            logger.info("task progress:", stage,
                "done=", tostring(state and state.done),
                "total=", tostring(state and state.total),
                "dialog=", tostring(dialog ~= nil))
        end
    end
    if not dialog then return end
    pcall(function() dialog:reportProgress(state) end)
end

--- Menu entry: bring back a dialog the reader hid, or say there is nothing running.
---
--- Without this, 隐藏 would be a one-way door -- the reader could not get the
--- progress, or a way to reach 暂停/退出, back without restarting the job.
function LightNovelPlugin:showTaskStatus()
    local task = STATE.task
    if not task then
        -- 留一行日志：读者报"隐藏弹窗后菜单里没有任务进度"时，需要区分
        -- "入口没渲染"和"任务确实被判空了"（2026-10-27 两阶段之间存在空档）。
        logger.info("task status: no running task (entry tapped)")
        UIManager:show(InfoMessage:new{ text = _("当前没有正在进行的任务") })
        return
    end
    logger.info("task status: reopening dialog for", tostring(task.kind))
    self:showTaskDialog()
end

--- FileManager "+" menu entry. filemanagermenu.lua calls this on every widget
--- handed to registerToMainMenu, so registering without it makes KOReader log
--- "failed to register widget ... attempt to call a nil value" and show nothing.
function LightNovelPlugin:addToMainMenu(menu_items)
    Menu:addToMainMenu(self, menu_items)
    -- Exercise the construction path once, here, and write the result to
    -- crash.log. Both shipped crashes (unbound Screen, broken string.format
    -- in the error handler) were invisible until the menu was tapped; this
    -- runs at menu-build time instead. Guarded so it can never break loading,
    -- and it only reports -- it never shows anything.
    if not SELFCHECK_STATE.done then
        SELFCHECK_STATE.done = true
        pcall(function() SelfCheck.run(self) end)
    end
end

function LightNovelPlugin:registerMenu()
    self.ui.menu:registerToMainMenu(self)
end

function LightNovelPlugin:onDispatcherRegisterActions()
    return true
end

-- ---------------------------------------------------------------- lifecycle

--- Leaving the plugin must stop the background work.
---
--- Nothing here existed before. A whole-book cache (900s), an EPUB export
--- (600s), a comment sync (300s) or a login (60s) can all still be running when
--- the reader walks away, and the worker's poll timer goes on firing: the
--- callbacks still call UIManager:show, still rewrite chapter files through
--- comment_sync's marker update, and -- because hideSpinner() is only reachable
--- from inside those callbacks -- the full-screen overlay could never be closed
--- once its callback had already gone past.
---
--- Worker:cancel writes the cancel sentinel, so the child dies at its next
--- checkCancelled rather than being orphaned.
function LightNovelPlugin:onCloseWidget()
    self._unloaded = true
    -- b22：任务登记在模块级 STATE 里跨实例存活，插件重建（阅读器 ⇄ 文件
    -- 管理器切换）不再取消任何任务。原来 cache/comment 走 plugin_closed
    -- 取消、export 保留——那是任务登记随实例死亡时的折衷（取消后无人能
    -- 重建入口）。02:00 实测后果：评论同步 16 秒被杀、菜单无「任务进度」、
    -- 弹窗成僵尸。现在 settle 回调经 STATE/pcall 对新实例同样有效，worker
    -- 子进程本来就在 KOReader 进程外运行，跨切换继续跑完即可。
    if self.worker and STATE.task then
        logger.info("onCloseWidget: plugin rebuilt;", tostring(STATE.task.kind),
            "job keeps running in background")
    end
    -- 弹窗部件随宿主一起关闭（指针由 onCloseWidget 钩子清空），任务本体保留，
    -- 新上下文里从菜单「任务进度」随时重开。
    pcall(function() self:hideSpinner() end)
    pcall(function() self:hideTaskDialog() end)
    -- No super call here, deliberately. This used to be `Menu.onCloseWidget(self)`
    -- where `Menu` is lightnovel.ui.menu -- this plugin's OWN module -- not
    -- KOReader's ui/widget/menu. That module exports addToMainMenu (line 48 vs
    -- 2207) but no onCloseWidget, so the call was
    -- `attempt to call field 'onCloseWidget' (a nil value)` on EVERY book close.
    --
    -- Checked against the KOReader build on the device rather than assumed:
    -- onCloseWidget is defined exactly once, as Menu:onCloseWidget in
    -- ui/widget/menu.lua:1440. This plugin's own chain --
    -- WidgetContainer -> Widget -> EventListener -- defines it nowhere, so there
    -- is no inherited hook to forward to and nothing is being skipped. KOReader
    -- calls this method directly on the plugin.
    --
    -- Calling Menu's version would also be wrong: it is menu teardown, being
    -- handed a container that is not a Menu. All real teardown already happens
    -- above, and each step is individually guarded.
    --
    -- CRITICAL: return false (not true) to tell KOReader "don't tear down the UI
    -- when just closing a book". Returning true was causing the flash-to-desktop
    -- on every book close because it signaled "unload the plugin and teardown UI".
    -- This is the "same teardown behind the flash-to-desktop report" mentioned above.
    return false
end

--- Called by KOReader when settings should be written. Without it the plugin's
--- LuaSettings handle is never flushed on exit, so a changed unlock strategy or
--- library dir could be lost.
function LightNovelPlugin:onFlushSettings()
    if self.settings then
        pcall(function() self.settings:flush() end)
    end
end

function LightNovelPlugin:isNetworkConnected()
    -- The module is ui/network/manager (it exports the NetworkMgr table) and
    -- isConnected is a method, so it has to be called with self.
    local NetworkMgr = require("ui/network/manager")
    if type(NetworkMgr.isConnected) == "function" then
        return NetworkMgr:isConnected() and true or false
    end
    return true
end

return LightNovelPlugin
