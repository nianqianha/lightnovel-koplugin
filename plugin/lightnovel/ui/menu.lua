--[[--
FileManager "+" menu for the lightnovel plugin.

Structured like weread.koplugin's weread/ui/menu.lua: the plugin registers a
single top-level submenu whose items are produced lazily by
sub_item_table_func, which touchmenu.lua evaluates each time the menu opens.

Every entry here maps to something that actually works. There is no settings
screen for options the code never reads, and no "coming soon" rows.
--]]--

local _ = require("gettext")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("lightnovel.lib.logger")

--- Plain KOReader Menu used for every sub-list in this file, matching the
-- pattern library_view.lua / toc_view.lua already established (Menu:extend).
-- The previous ButtonDialog approach stacked one button per row, so a dozen
-- cached books became a column of buttons running off the screen; Menu pages
-- and scrolls natively.
local ListMenu = Menu:extend{
    name = "lightnovel_list",
    is_doc_only = false,
    is_modal = true,
    covers_fullscreen = true,
    title_bar_fm_style = true,
    -- Back, not a menu. The hamburger used to be dead here: ListMenu never
    -- overrode onLeftButtonTap, and Menu's default implementation is an empty
    -- function, so the icon was drawn and did nothing. Menu:onClose() already
    -- has exactly the semantics the reader wants -- pop to the parent table
    -- when one is stacked, close when there is not -- so the left button now
    -- calls it directly.
    title_bar_left_icon = "chevron.left",
}

--- Back button for every ListMenu: one level up inside a submenu, out when at
--- the top. Matches Menu:onClose()'s own definition (menu.lua:1460).
function ListMenu:onLeftButtonTap()
    return self:onClose()
end

-- Long-press keeps the old "close everything" escape hatch: a reader three
-- levels deep should not have to tap back three times to get out.
function ListMenu:onLeftButtonHold()
    return self:onCloseAllMenus()
end

function ListMenu:onCloseWidget()
    Menu.onCloseWidget(self)
end

-- Declared here, before any M.* definition below. It used to sit further down,
-- next to showList(), which meant M was still an (undefined) global while the
-- functions above it ran -- "menu.lua:45: attempt to index global 'M' (a nil
-- value)" -- and the whole plugin failed to load, so its FileManager entry
-- silently disappeared. `local` only takes effect from the declaration onward.
local M = {}

-- Full-screen loading overlay.
--
-- ProgressOverlayWidget does not exist on this build and ProgressWidget is only
-- a bar with no text layer, so the cover is a Menu: the same widget the plugin
-- already uses everywhere, with covers_fullscreen so the file manager home
-- cannot show through. One non-selectable row carries the message.
--
-- `title_bar_left_icon = false` is deliberate and load-bearing. ListMenu now
-- carries a back arrow, and this overlay is built from ListMenu: without this
-- the reader could tap Back on a busy screen and dismiss the cover while the
-- job it is hiding still runs. Widget:new does `self:extend(o)`, so a field set
-- here overrides the class default -- but only a non-nil value does, which is
-- why this is `false` and not `nil`.
function M.showLoading(text)
    local overlay = ListMenu:new{
        title = text or _("请稍候…"),
        title_bar_left_icon = false,
        item_table = {
            {
                text = text or _("请稍候…"),
                select_enabled = false,
            },
        },
    }
    UIManager:show(overlay)
    return overlay
end

--- Show a titled list. Returns the menu so callers can close it before
--- reopening (settings does this on every save).
local function showList(title, items)
    local menu = ListMenu:new{
        title = title,
        item_table = items,
    }
    UIManager:show(menu)
    return menu
end

M.PAGE_SIZE_MIN = 20 -- the API rejects pageSize < 20 with code 3
M.PAGE_SIZE_MAX = 100

--- Run a menu callback with the error containment weread.koplugin uses for
-- every single item (`self:safeCallback(name, fn)`). Without this, one failing
-- item aborts the rest of the touch menu dispatch and the user just sees the
-- menu silently do nothing.
local function safeCallback(name, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            logger.err("menu item failed:", tostring(name), tostring(err))
            UIManager:show(InfoMessage:new{
                -- %1/%2 are Python-style positional specifiers; Lua's
                -- string.format rejects them ("invalid option '%1 '"), which
                -- turned this error handler into a second crash.
                text = string.format(_("%s 执行失败：%s"), tostring(name), tostring(err)),
            })
        end
    end
end
M.safeCallback = safeCallback

-- ------------------------------------------------------------------ helpers

--- List the per-book cache keys that actually hold something.
---
--- 「有目录」不算有缓存。
---
--- 这里原来只数 books/ 下有几个子目录，而 Settings:bookDir() 每次访问都会
--- mkdir，清理缓存又只删文件不删目录，于是「本地缓存（N）」永远清不下去——
--- 读者清完缓存、重新下载，看到的还是同一个数字。现在按是否真的存在章节文件
--- 判断，和 list_cached_books 的口径一致。
local function book_has_chapters(plugin, key)
    local dir = plugin.settings:data_dir() .. "/books/" .. key .. "/chapters"
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok or type(iter) ~= "function" then
        return false
    end
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." then
            return true
        end
    end
    return false
end

--- 章节文件数，只用于给缓存管理列表标"几章"。
local function count_chapter_files(plugin, key)
    local dir = plugin.settings:data_dir() .. "/books/" .. key .. "/chapters"
    local n = 0
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if ok and type(iter) == "function" then
        for name in iter, dir_obj do
            if name ~= "." and name ~= ".." then n = n + 1 end
        end
    end
    return n
end

local function cached_book_keys(plugin)
    local root = plugin.settings:data_dir() .. "/books"
    local keys = {}
    local ok, iter, dir_obj = pcall(lfs.dir, root)
    if not ok or type(iter) ~= "function" then
        return keys
    end
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." then
            local sub = root .. "/" .. name
            if lfs.attributes(sub, "mode") == "directory"
                and book_has_chapters(plugin, name) then
                keys[#keys + 1] = name
            end
        end
    end
    table.sort(keys)
    return keys
end

local function count_cached_volumes(plugin, key, catalog)
    local n = 0
    for _i, chapter in ipairs((catalog or {}).chapters or {}) do
        if plugin.cache:is_cached(key, chapter.aid) then
            n = n + 1
        end
    end
    return n
end

--- Remove a book's cached chapter files and its comment database.
---
--- 同时删 download_state.lua：它记着 revision + complete，章节却已经被清空。
--- 下载快路径本身会再核对每章是否真的在盘上（chapter_cache 的 all_cached），
--- 所以不会直接骗过下载；但"状态说完整、目录是空的"这种不一致留在设备上，会让
--- 下一次排查（检查更新/孤儿章节/日志）看到自相矛盾的记录。
local function purge_book(plugin, key)
    local book_dir = plugin.settings:bookDir(key)
    local chapters = book_dir .. "/chapters"
    local ok, iter, dir_obj = pcall(lfs.dir, chapters)
    if ok and type(iter) == "function" then
        for name in iter, dir_obj do
            if name ~= "." and name ~= ".." then
                pcall(os.remove, chapters .. "/" .. name)
            end
        end
    end
    pcall(os.remove, book_dir .. "/catalog.lua")
    pcall(os.remove, book_dir .. "/download_state.lua")
    local store = require("lightnovel.lib.comment_store")
    -- remove_db is a MODULE function taking a book_dir string. The old code did
    -- `store.open(book_dir):remove_db()`, i.e. looked the method up on the SQ3
    -- handle, where it does not exist -- so the error was swallowed by this
    -- pcall and comments.db (plus -wal/-shm) survived every purge, while the
    -- dialog still claimed the cache was cleared. Close the handle first: an
    -- open connection would keep the WAL alive and lock the unlink.
    -- A bid_* book has a separate new-content DB; close and remove only the
    -- namespace being purged, preserving legacy comments in any other namespace.
    local namespace = tostring(key or ""):match("^bid_%d+$")
        and "new-content" or nil
    local db = store.open(book_dir, namespace)
    if db then
        store.close(db)
    end
    local removed, remove_err = store.remove_db(book_dir, namespace)
    if not removed then
        logger.warn("purge:", tostring(key), "comment db not removed:",
            tostring(remove_err))
    end
    -- 最后收掉空目录本身：bookDir() 会按需重建，留着只会让"缓存还有没有"看起来
    -- 永远是"有"。
    pcall(os.remove, chapters)
    pcall(os.remove, book_dir)
end

-- ------------------------------------------------------------------- search

function M.showSearch(plugin)
    local dialog
    dialog = InputDialog:new{
        title = _("搜索轻小说"),
        input_hint = _("书名或作者"),
        -- Each button needs its OWN callback: buttontable.lua:82 calls
        -- `btn_entry.callback()` with no nil check, and InputDialog has no
        -- dialog-level `callback` field. weread 10/10, fanqie 16/16.
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("搜索"),
                    is_enter_default = true,
                    callback = function()
                        local query = (dialog:getInputValue() or "")
                            :gsub("^%s+", ""):gsub("%s+$", "")
                        if query == "" then
                            return
                        end
                        UIManager:close(dialog)
                        plugin:showLibrary{ mode = "search", query = query }
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

-- -------------------------------------------------------------- cached books

--- Items for the 本地缓存 submenu.
---
--- This replaces two sibling top-level rows (缓存书架 / 缓存管理) that both
--- described the same directory: one listed it, the other deleted from it, and
--- neither name said so. Browsing and deleting are still separate rows on
--- purpose -- a destructive action should not sit on the row a reader taps to
--- read something -- but they are now one entry point, and the count is
--- recomputed on every open rather than captured when the menu was built.
function M.getLocalCacheItems(plugin)
    local key_count = #cached_book_keys(plugin)
    local items = {
        {
            text_func = function()
                return string.format(_("已缓存书籍（%d）"),
                    #cached_book_keys(plugin))
            end,
            callback = safeCallback(_("已缓存书籍"), function()
                M.showCachedBooks(plugin)
            end),
        },
    }
    if key_count > 0 then
        items[#items + 1] = {
            text = _("清除缓存…"),
            callback = safeCallback(_("清除缓存"), function()
                M.showCacheManager(plugin)
            end),
        }
    end
    return items
end

function M.showCachedBooks(plugin)
    local keys = cached_book_keys(plugin)
    local rows = {}
    for _i, key in ipairs(keys) do
        -- load_catalog returns nil when the directory holds no catalog.lua --
        -- a normal state for a book that was opened while save_catalog was
        -- broken, so those leftovers left empty directories behind. Indexing
        -- the result unconditionally raised "attempt to index local 'catalog'
        -- (a nil value)" and took the whole cached-books list down with it.
        local catalog = plugin.cache:load_catalog(key)
        if type(catalog) == "table" then
            local total = #(catalog.chapters or {})
            local cached = count_cached_volumes(plugin, key, catalog)
            if cached > 0 then
                rows[#rows + 1] = {
                    key = key,
                    title = catalog.title or key,
                    text = string.format("%s  %s %d/%d", catalog.title or key,
                        _("已缓存"), cached, total),
                    catalog = catalog,
                }
            end
        end
    end
    if #rows == 0 then
        UIManager:show(InfoMessage:new{ text = _("还没有缓存任何书") })
        return
    end
    local items = {}
    for i, row in ipairs(rows) do
        items[i] = {
            text = row.text,
            -- Re-evaluated on every paint so a long title is not cached stale.
            text_func = function() return row.text end,
            callback = safeCallback(row.title, function()
                plugin:showCachedToc(row.key, plugin.cache:load_catalog(row.key))
            end),
        }
    end
    return showList(_("缓存书架"), items)
end

-- ------------------------------------------------------------- cache manager

function M.showCacheManager(plugin)
    local keys = cached_book_keys(plugin)
    if #keys == 0 then
        UIManager:show(InfoMessage:new{ text = _("还没有缓存任何书") })
        return
    end
    local menu
    local items = {}
    for i, key in ipairs(keys) do
        -- 书名 + 章数 + key。只显示 key(bid_1338) 时读者没法判断要留哪本，
        -- 只能靠记忆去对 book_id。
        local catalog = plugin.cache:load_catalog(key)
        local title = (catalog and catalog.title) or key
        local label = string.format("%s · %d 章（%s）", title,
            count_chapter_files(plugin, key), key)
        items[i] = {
            text = label,
            text_func = function() return label end,
            callback = safeCallback(title, function()
                UIManager:close(menu)
                M.confirmPurge(plugin, key)
            end),
        }
    end
    items[#items + 1] = {
        text = _("清除全部缓存"),
        callback = safeCallback(_("清除全部缓存"), function()
            UIManager:close(menu)
            UIManager:show(ConfirmBox:new{
                text = _("确定清除全部缓存？\n已下载的章节与评论都会删除。"),
                ok_text = _("清除"),
                cancel_text = _("取消"),
                ok_callback = safeCallback(_("清除全部缓存"), function()
                    local failed = 0
                    for _i, key in ipairs(cached_book_keys(plugin)) do
                        local ok = pcall(purge_book, plugin, key)
                        if not ok then
                            failed = failed + 1
                        end
                    end
                    if failed > 0 then
                        UIManager:show(InfoMessage:new{
                            text = string.format(
                                _("清除完成，但 %d 本书失败。"), failed),
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("缓存已清除"),
                        })
                    end
                end),
            })
        end),
    }
    menu = showList(_("缓存管理"), items)
    return menu
end

--- 单本缓存的操作面板：清除这本 / 只保留这本。
---
--- 用 ButtonDialog 是因为这里需要三个明确的动作；ConfirmBox 只有两个按钮。
--- （文件里其他地方用 ListMenu 是因为"一长串书"应该分页，不是同一个问题。）
--- "只保留这本"直接把其他缓存全部清掉——读者要的就是"别的都不要"，再让他一本
--- 一本去点反而更容易点错。
--- @treturn boolean 是否至少清掉了一本
function M.confirmPurge(plugin, key)
    local catalog = plugin.cache:load_catalog(key)
    local title = (catalog and catalog.title) or key
    local dialog
    dialog = ButtonDialog:new{
        title = string.format(_("《%s》"), title)
            .. "\n" .. string.format(_("%d 章（%s）"),
                count_chapter_files(plugin, key), key),
        buttons = {
            {
                {
                    text = _("只清除这本"),
                    callback = safeCallback(_("清除缓存"), function()
                        UIManager:close(dialog)
                        purge_book(plugin, key)
                        UIManager:show(InfoMessage:new{ text = _("缓存已清除") })
                    end),
                },
            },
            {
                {
                    text = _("只保留这本（清除其他全部）"),
                    callback = safeCallback(_("只保留这本"), function()
                        UIManager:close(dialog)
                        local removed, failed = 0, 0
                        for _i, other in ipairs(cached_book_keys(plugin)) do
                            if other ~= key then
                                if pcall(purge_book, plugin, other) then
                                    removed = removed + 1
                                else
                                    failed = failed + 1
                                end
                            end
                        end
                        logger.info("purge: kept", tostring(key),
                            "removed=", tostring(removed),
                            "failed=", tostring(failed))
                        local text = string.format(_("已保留《%s》，清除其他 %d 本"),
                            title, removed)
                        if failed > 0 then
                            text = text .. string.format(_("（%d 本失败）"),
                                failed)
                        end
                        UIManager:show(InfoMessage:new{ text = text })
                    end),
                },
            },
            {
                {
                    text = _("取消"),
                    callback = function() UIManager:close(dialog) end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

-- ----------------------------------------------------------------- settings

-- Unlock strategies, in cycling order. The stored value is the key; the label
-- and the cost preview come from here so the settings row and the unlock
-- prompt can never disagree about what a setting means.
M.UNLOCK_STRATEGIES = {
    {
        key = "chapter",
        label = _("逐章确认"),
        hint = _("遇到锁章时询问，只解锁这一章（最省）"),
    },
    {
        key = "volume",
        label = _("按卷解锁"),
        hint = _("解锁当前卷的全部锁章"),
    },
    {
        key = "book",
        label = _("全书解锁"),
        hint = _("解锁全书全部锁章，一次性扣款"),
    },
}

--- Resolve a stored strategy value to its table entry, defaulting to "chapter".
function M.getUnlockStrategy(settings)
    local key = tostring(settings:get("unlock.strategy") or "chapter")
    for _i, entry in ipairs(M.UNLOCK_STRATEGIES) do
        if entry.key == key then
            return entry
        end
    end
    return M.UNLOCK_STRATEGIES[1]
end

--- The strategy whose key follows `key`, wrapping at the end.
function M.nextUnlockStrategy(key)
    for i, entry in ipairs(M.UNLOCK_STRATEGIES) do
        if entry.key == key then
            return M.UNLOCK_STRATEGIES[(i % #M.UNLOCK_STRATEGIES) + 1]
        end
    end
    return M.UNLOCK_STRATEGIES[2]
end

function M.showSettings(plugin)
    local current = tonumber(plugin.settings:get("cache.comment_page_size"))
        or M.PAGE_SIZE_MIN
    local menu
    local items = {
        {
            -- Account state moved here from its own top-level row, which opened
            -- this very menu. Read-only when logged in; when logged out the row
            -- IS the login entry point, so a reader who cleared the session can
            -- get back in without first triggering a search.
            text_func = function()
                if plugin.client and plugin.client:hasSession() then
                    return _("账号：已登录")
                end
                return _("账号：未登录（点击登录）")
            end,
            callback = safeCallback(_("账号"), function()
                if plugin.client and plugin.client:hasSession() then
                    UIManager:show(InfoMessage:new{
                        text = _("当前已登录。\n如需更换账号，请先使用下方“清除登录状态”。"),
                    })
                else
                    UIManager:close(menu)
                    plugin:showLogin()
                end
            end),
        },
        {
            -- The row itself is the feedback. An earlier version showed an
            -- InfoMessage and then immediately closed and reopened this menu,
            -- so the message covered the new list and the tap looked like a
            -- no-op on e-ink. text_func is re-evaluated on every paint, so
            -- rebuilding the list is enough.
            text_func = function()
                local entry = M.getUnlockStrategy(plugin.settings)
                return string.format(_("解锁方式：%s\n%s"), entry.label,
                    entry.hint)
            end,
            callback = safeCallback(_("解锁方式"), function()
                local current = M.getUnlockStrategy(plugin.settings)
                local next_entry = M.nextUnlockStrategy(current.key)
                plugin.settings:set("unlock.strategy", next_entry.key)
                plugin.settings:flush()
                UIManager:close(menu)
                M.showSettings(plugin)
            end),
        },
        {
            text_func = function()
                return string.format(_("评论每页条数：%d"), current)
            end,
            callback = safeCallback(_("评论每页条数"), function()
                UIManager:close(menu)
                local dialog
                dialog = InputDialog:new{
                    title = _("评论每页条数"),
                    input_hint = string.format(_("最小 %d，最大 %d"),
                        M.PAGE_SIZE_MIN, M.PAGE_SIZE_MAX),
                    input = tostring(current),
                    -- Each button needs its OWN callback: buttontable.lua:82
                    -- calls `btn_entry.callback()` with no nil check, and
                    -- InputDialog has no dialog-level `callback` field.
                    buttons = {
                        {
                            {
                                text = _("取消"),
                                callback = function()
                                    UIManager:close(dialog)
                                end,
                            },
                            {
                                text = _("保存"),
                                is_enter_default = true,
                                callback = safeCallback(
                                    _("评论每页条数"), function()
                                    local n = tonumber(
                                        dialog:getInputValue() or "")
                                    if not n or n < M.PAGE_SIZE_MIN then
                                        n = M.PAGE_SIZE_MIN
                                    end
                                    if n > M.PAGE_SIZE_MAX then
                                        n = M.PAGE_SIZE_MAX
                                    end
                                    plugin.settings:set(
                                        "cache.comment_page_size", n)
                                    plugin.settings:flush()
                                    UIManager:close(dialog)
                                    UIManager:show(InfoMessage:new{
                                        text = string.format(
                                            _("已保存：每页 %d 条"), n),
                                    })
                                    -- The list was closed above, so no stacking.
                                    M.showSettings(plugin)
                                end),
                            },
                        },
                    },
                }
                UIManager:show(dialog)
            end),
        },
        {
            -- Only offered when there is a session to clear. Without this the
            -- row read "清除登录状态" while already logged out, and tapping it
            -- confirmed a logout that had nothing to log out of.
            text = plugin.client and plugin.client:hasSession()
                and _("清除登录状态") or nil,
            callback = safeCallback(_("清除登录状态"), function()
                UIManager:close(menu)
                UIManager:show(ConfirmBox:new{
                    text = _("确定退出登录？\n搜索需要登录账号。"),
                    ok_text = _("退出"),
                    cancel_text = _("取消"),
                    ok_callback = safeCallback(_("退出登录"), function()
                        plugin.client:logout()
                        plugin.settings:flush()
                        UIManager:show(InfoMessage:new{
                            text = _("已退出登录"),
                        })
                    end),
                })
            end),
        },
    }
    -- A nil `text` would be rendered as an empty row by touchmenu, so the
    -- logged-out case is filtered out rather than left in place.
    local visible = {}
    for _i, item in ipairs(items) do
        if item.text ~= nil or item.text_func ~= nil then
            visible[#visible + 1] = item
        end
    end
    menu = showList(_("设置"), visible)
    return menu
end

-- -------------------------------------------------------------------- about

function M.showAbout(plugin)
    UIManager:show(InfoMessage:new{
        -- %s, not %1. Lua's string.format has no positional specifiers and
        -- raises "invalid option '%1 ' to 'format'" -- which is what happened
        -- here. The format-lint missed it because the format string is wrapped
        -- in gettext: it only matched a bare literal right after "(".
        text = string.format(
            _("轻之国度插件 v%s\n\n评论与章节缓存在本机，可离线阅读。\n仅供个人学习与技术研究使用。"),
            tostring(plugin.version or "?")),
    })
end

-- --------------------------------------------------------------------- menu

function M:addToMainMenu(plugin, menu_items)
    menu_items.lightnovel = {
        text = _("轻之国度"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return M.getMainMenuItems(plugin)
        end,
    }
end

--- Search and the personal shelf both need a session (the API answers code 5
--- and code 8 respectively without one). Gate them so the user gets a login
--- prompt instead of a bare api_error_N.
--- `purpose` is the sentence shown in the prompt; each caller names its own so
--- the dialog never claims the wrong feature.
function M.ensureLogin(plugin, on_ok, purpose)
    local client = plugin.client
    if client and client:hasSession() then
        on_ok()
        return
    end
    local prompt = purpose or _("搜索需要先登录轻之国度账号。\n是否现在登录？")
    UIManager:show(ConfirmBox:new{
        text = prompt,
        ok_text = _("登录"),
        cancel_text = _("取消"),
        ok_callback = safeCallback(_("登录"), function()
            plugin:showLogin()
        end),
    })
end

function M.getMainMenuItems(plugin)
    local items = {}
    local client = plugin.client

    -- 任务进度 is the way back to a dialog the reader hid. Without it 隐藏 is a
    -- one-way door: the progress, and the 暂停/退出 buttons that go with it, would
    -- only be reachable by restarting the job. Hidden when nothing is running so
    -- the menu does not carry a permanently dead row.
    -- b22: 任务登记在模块级 STATE 里跨插件实例存活（阅读器 ⇄ 文件管理器切换
    -- 会重建实例），必须经 getTask() 读；直接读实例字段在切换后永远拿不到。
    if plugin:getTask() then
        items[#items + 1] = {
            text_func = function()
                local running = plugin:getTask()
                return running and running.paused
                    and _("任务进度（已暂停）") or _("任务进度")
            end,
            callback = safeCallback(_("任务进度"), function()
                plugin:showTaskStatus()
            end),
        }
    end

    -- 反馈通道（b27）：遇到报错一键导出诊断日志到 documents，USB 取走发送。
    items[#items + 1] = {
        text = _("导出诊断日志"),
        callback = safeCallback(_("导出诊断日志"), function()
            plugin:exportDiagnosticLog()
        end),
    }

    items[#items + 1] = {
        -- "书架" is the account's shelf on the server, per the request that
        -- started this work. It used to open the category browser, which is
        -- now reachable from the left-button menu inside the shelf screen.
        --
        -- keep_menu_open is what makes the back button in the shelf work. The
        -- FileManager "+" menu is a TouchMenu, and TouchMenu:onMenuSelect ends
        -- with `if not item.keep_menu_open then self:closeMenu() end`
        -- (touchmenu.lua:900-902) -- so without this flag the plugin menu is
        -- already gone by the time the shelf opens, and its left button can
        -- only close back to the file manager. Keep the menu open and the shelf
        -- sits on top of it, which is exactly the "up one level" the reader
        -- asked for. This is also what weread does for all its sub-screens.
        text = _("书架"),
        keep_menu_open = true,
        callback = safeCallback(_("书架"), function()
            M.ensureLogin(plugin, function()
                plugin:showLibrary{ mode = "bookshelf" }
            end, _("书架需要先登录轻之国度账号。\n是否现在登录？"))
        end),
    }
    items[#items + 1] = {
        text = _("搜索"),
        -- Same reason as 书架 above: search opens its own screen, and the
        -- reader must be able to come back here rather than to the file manager.
        keep_menu_open = true,
        callback = safeCallback(_("搜索"), function()
            M.ensureLogin(plugin, function()
                M.showSearch(plugin)
            end)
        end),
    }

    items[#items + 1] = {
        -- One entry point for the on-disk cache. It used to be two sibling rows
        -- (缓存书架 / 缓存管理) for the same directory, and a reader could not
        -- tell from the labels that one only listed and the other only deleted.
        --
        -- `sub_item_table`, NOT `sub_item_table_func`. This is a plain
        -- Menu:extend (ListMenu), and Menu:onMenuSelect only ever looks at
        -- `item.sub_item_table` (menu.lua:1365) -- sub_item_table_func is a
        -- TouchMenu mechanism. Using the func form here made
        -- switchItemTable(text, nil) run, which leaves the old table in place
        -- (menu.lua:1183) while still pushing onto item_table_stack: the row
        -- would appear to do nothing and then corrupt the back button's idea of
        -- where "up" is.
        text_func = function()
            return string.format(_("本地缓存（%d）"), #cached_book_keys(plugin))
        end,
        sub_item_table = M.getLocalCacheItems(plugin),
    }
    items[#items + 1] = {
        text = _("设置"),
        callback = safeCallback(_("设置"), function()
            M.showSettings(plugin)
        end),
    }

    -- There is deliberately no top-level account row any more. The old
    -- "已登录（点击管理）" row opened showSettings() -- the very row above it --
    -- so it was a duplicate whose label also promised account management it did
    -- not perform. Account state now lives inside 设置, where the logout action
    -- already was, so both halves are in one place.
    items[#items + 1] = {
        text = _("关于"),
        callback = safeCallback(_("关于"), function()
            M.showAbout(plugin)
        end),
    }
    return items
end

return M
