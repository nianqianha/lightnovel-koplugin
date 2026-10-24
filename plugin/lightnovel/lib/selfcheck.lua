--[[--
Load-time self-check.

Why this exists
===============
Two shipped crashes were both invisible to the static gates:

  * `main.lua:143 attempt to index global 'Screen' (a nil value)` -- the only
    `local Screen` sat inside a function, out of scope at the login dialog.
  * `menu.lua:65 invalid option '%1 ' to 'format'` -- the error handler itself
    was broken, so a handled failure became a hard crash.

Both would have been visible before you ever tapped anything, if the plugin
had exercised its own construction path once at startup and written the result
to crash.log. That is all this module does. It is read-only: it builds things,
reports what failed, and shows nothing.

What it covers, and what it does not
===================================
Covers: module loading, the Screen binding, the settings/cache/client probes,
and building the main menu item table (which is where the menu callbacks and
their closures are created).

Does NOT cover: anything that only runs when a menu row is tapped, chapter
opening, or the network. Those still need a real tap.
--]]--

local logger = require("lightnovel.lib.logger")

-- 诊断截图默认关闭。它会在 UI 线程上做 framebuffer 读取 + PNG 编码，
-- 实测每次 1-2 s；曾在生产路径上随每次插件实例重建各触发一张，设备累积
-- 300+ 张。需要排查菜单渲染时，创建 /mnt/us/koreader/_selfcheck_shot.on
-- 即可临时恢复。
local SHOT_FLAG = "/mnt/us/koreader/_selfcheck_shot.on"

local SelfCheck = {}
SelfCheck.__index = SelfCheck

-- Every module the plugin owns, so a load error names the culprit instead of
-- surfacing later as an unrelated nil call.
local OWN_MODULES = {
    "lightnovel.lib.digest",
    "lightnovel.lib.plugin_util",
    "lightnovel.lib.settings",
    "lightnovel.lib.client",
    "lightnovel.lib.content",
    "lightnovel.lib.chapter_cache",
    "lightnovel.lib.comment_store",
    "lightnovel.lib.comment_sync",
    "lightnovel.lib.book_catalog",
    "lightnovel.lib.background_worker",
    "lightnovel.ui.menu",
    "lightnovel.ui.library_view",
    "lightnovel.ui.toc_view",
    "lightnovel.ui.comment_panel",
    "lightnovel.ui.reader_hooks",
}

local function try(label, fn, failures)
    local ok, err = pcall(fn)
    if not ok then
        failures[#failures + 1] = label .. ": " .. tostring(err)
    end
    return ok
end

--- Run every probe once. Returns a one-line summary; logs the detail.
function SelfCheck.run(plugin)
    local failures = {}
    local checks = 0

    -- 1) every owned module must load
    for _, name in ipairs(OWN_MODULES) do
        checks = checks + 1
        try("require " .. name, function() require(name) end, failures)
    end

    -- 2) Screen must resolve and answer getWidth(). This is the exact
    --    regression that shipped: a bare global read as nil.
    checks = checks + 1
    try("device.screen.getWidth", function()
        local Screen = require("device").screen
        assert(type(Screen) == "table" or type(Screen) == "userdata",
            "device.screen is " .. type(Screen))
        assert(type(Screen.getWidth) == "function", "getWidth missing")
        local w = Screen:getWidth()
        assert(type(w) == "number" and w > 0, "getWidth returned " .. tostring(w))
    end, failures)

    -- 3) settings must be readable and its data dir must exist
    checks = checks + 1
    try("settings", function()
        local settings = plugin and plugin.settings
        assert(settings, "plugin.settings is nil")
        local dir = settings:data_dir()
        assert(type(dir) == "string" and #dir > 0, "data_dir empty")
        -- dig() lookup: a nested default must resolve, not fall through
        local n = settings:get("cache.comment_page_size")
        assert(tonumber(n) ~= nil, "comment_page_size not numeric: " .. tostring(n))
    end, failures)

    -- 4) cache dir walk (the cached bookshelf enumerates it on every menu open)
    checks = checks + 1
    try("cache dirs", function()
        local settings = plugin and plugin.settings
        assert(settings, "plugin.settings is nil")
        local lfs = require("libs/libkoreader-lfs")
        for _, sub in ipairs({ "books", "chapters", "covers", "workers" }) do
            local path = settings:data_dir() .. "/" .. sub
            assert(lfs.attributes(path, "mode") == "directory",
                "missing dir " .. sub)
        end
    end, failures)

    -- 5) client must answer hasSession without a network call
    checks = checks + 1
    try("client.hasSession", function()
        local client = plugin and plugin.client
        assert(client, "plugin.client is nil")
        assert(type(client.hasSession) == "function", "hasSession missing")
        assert(type(client:hasSession()) == "boolean", "hasSession not boolean")
    end, failures)

    -- 6) the main menu item table must build. This creates every row closure,
    --    so a bad upvalue or a typo in an item shows up here rather than on tap.
    checks = checks + 1
    local item_count = 0
    try("buildMenuItems", function()
        local Menu = require("lightnovel.ui.menu")
        assert(type(Menu.getMainMenuItems) == "function", "getMainMenuItems missing")
        local items = Menu.getMainMenuItems(plugin)
        assert(type(items) == "table", "item table is " .. type(items))
        assert(#items > 0, "main menu has no items")
        item_count = #items
        for i, item in ipairs(items) do
            -- A static label is a plain string (`text = "书架"`); only dynamic
            -- ones use `text_func = function`. Asserting `type(text) == "function"`
            -- reported a false SELFCHECK FAIL on item 1.
            local has_label = (type(item.text) == "string" and #item.text > 0)
                or type(item.text_func) == "function"
            assert(has_label,
                "menu item " .. i .. " has no label (text=" ..
                type(item.text) .. " text_func=" .. type(item.text_func) .. ")")
            -- A row is actionable EITHER by a callback (it does something) or by
            -- a submenu (it opens one). Asserting callback-only reported a false
            -- FAIL on item 3 after 本地缓存 became a sub_item_table row:
            -- "menu item 3 has no callback". That is exactly the shape a submenu
            -- has, so the check has to accept it -- otherwise a healthy menu
            -- keeps logging SELFCHECK FAIL and masks a real one.
            local has_action = type(item.callback) == "function"
                or item.sub_item_table ~= nil
                or item.sub_item_table_func ~= nil
            assert(has_action,
                "menu item " .. i .. " is neither actionable nor a submenu "
                .. "(callback=" .. type(item.callback)
                .. " sub_item_table=" .. type(item.sub_item_table)
                .. " sub_item_table_func=" .. type(item.sub_item_table_func) .. ")")
        end
    end, failures)

    if #failures == 0 then
        logger.info(string.format(
            "SELFCHECK PASS: %d checks, %d menu items, Screen bound",
            checks, item_count))
    else
        for _, f in ipairs(failures) do
            logger.err("SELFCHECK FAIL " .. f)
        end
        logger.err(string.format(
            "SELFCHECK DONE: %d checks, %d FAILED", checks, #failures))
    end

    -- The screenshot is an optional integration owned by the standalone
    -- Screenshot Tool plugin. Absence of that plugin skips only the diagnostic
    -- image; it must not turn an otherwise healthy selfcheck red.
    --
    -- Default OFF: capture + PNG encode run on the UI thread (1-2 s each) and
    -- this path used to fire once per plugin-instance rebuild. Opt in with
    -- the flag file when debugging menu rendering.
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(SHOT_FLAG, "mode") == "file" then
        local shot_ok, shot_err = pcall(function()
            return plugin:requestDiagnosticScreenshot("menu_built", 2)
        end)
        if not shot_ok then
            logger.warn("SELFCHECK optional screenshot unavailable: " .. tostring(shot_err))
        end
    end
    return #failures
end

return SelfCheck
