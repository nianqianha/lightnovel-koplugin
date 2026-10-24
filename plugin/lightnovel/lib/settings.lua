-- Plugin settings, stored below the plugin data directory rather than in
-- KOReader's global settings tree.
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local LuaSettings = require("luasettings")

local Settings = {}
Settings.__index = Settings

function Settings:new()
    local root = DataStorage:getDataDir() .. "/lightnovel"
    lfs.mkdir(root)
    for _, name in ipairs({ "books", "chapters", "covers", "workers" }) do
        lfs.mkdir(root .. "/" .. name)
    end

    local o = setmetatable({
        root_dir = root,
        defaults = {
            auth = { security_key = "" },
            cache = { download_images = true, comment_page_size = 20 },
            reader = { font_size_scale = 1.0 },
            -- How aggressively a locked chapter may be unlocked with the
            -- account's 轻币. "chapter" asks per chapter, "volume" buys the
            -- whole volume the chapter belongs to, "book" buys the whole book.
            -- The most conservative value is the default so a fresh install can
            -- never spend currency without an explicit choice.
            unlock = { strategy = "chapter" },
            -- Destination for merged whole-book EPUBs. Empty means the default
            -- library folder; see libraryDir() for why this is not the plugin
            -- data directory.
            library = { dir = "" },
        },
    }, self)

    o.settings = LuaSettings:open(root .. "/settings.lua")
    return o
end

--- Walk a dotted key through a nested table: dig(defaults, "cache.page_size").
local function dig(tbl, key)
    local cur = tbl
    for part in key:gmatch("[^%.]+") do
        if type(cur) ~= "table" then
            return nil
        end
        cur = cur[part]
    end
    return cur
end

function Settings:get(key, default)
    -- Storage stays FLAT on purpose: LuaSettings:readSetting is
    -- `self.data[key]` (luasettings.lua:89-99), so "cache.page_size" is one
    -- key, not a nested table.
    local value = self.settings:readSetting(key)
    if value ~= nil then
        return value
    end
    if default ~= nil then
        return default
    end
    -- Defaults are nested, so a flat self.defaults[key] lookup would always
    -- miss "cache.comment_page_size" and silently fall through to the
    -- caller's hardcoded fallback. Walk the table instead.
    return dig(self.defaults, key)
end

function Settings:set(key, value)
    self.settings:saveSetting(key, value)
end

function Settings:flush()
    self.settings:flush()
end

--- Root of the plugin's own data directory.
function Settings:data_dir()
    return self.root_dir
end

--- Per-book directory. Created on demand because the caller may be a worker
--- child that must not depend on UI state.
function Settings:bookDir(key)
    local dir = self.root_dir .. "/books/" .. tostring(key or "default")
    lfs.mkdir(dir)
    return dir
end

function Settings:coverDir()
    return self.root_dir .. "/covers"
end

function Settings:workerDir()
    return self.root_dir .. "/workers"
end

--- Where merged whole books are published so they appear in KOReader's library.
---
--- This is deliberately NOT inside the plugin data directory. Chapter HTML lives
--- under data_dir (see bookDir) and must stay there: weread makes the same
--- separation explicitly, keeping per-chapter files in a private
--- `chapter-cache/<book>` directory because "chapter files must never end up in a
--- user-selected library folder" (weread/lib/content.lua:51-54). Only the merged
--- single-file book is published, which is what keeps one title to one entry.
---
--- Default is a subfolder of the stock library root, so the files show up in the
--- file browser and can be deleted wholesale without touching anything else.
--- Overridable via the `library.dir` setting for a reader who keeps books
--- elsewhere. Returns the directory and whether it is usable; an unwritable
--- library must not be fatal, since reading and caching still work without it.
function Settings:libraryDir()
    local configured = self:get("library.dir")
    local dir
    if type(configured) == "string" and configured ~= "" then
        dir = configured
    else
        -- Downloads/Items01, NOT /mnt/us/books (not a directory on this device)
        -- and NOT /mnt/us/documents (the folder root).
        --
        -- Verified on the device: every book the reader already has lives in
        -- documents/Downloads/Items01 -- 北派盗墓笔记 - full.epub, 贩罪 - full.epub,
        -- 惊悚乐园 ..., plus two .kfx -- each with its own <name>.sdr sidecar.
        -- Publishing into the documents root put the lightnovel books in a
        -- different folder from the rest of the library, so they showed up apart
        -- from everything else and read as "not in the library".
        dir = "/mnt/us/documents/Downloads/Items01"
    end
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(dir)
    end
    local ok = lfs.attributes(dir, "mode") == "directory"
    return dir, ok
end

return Settings
