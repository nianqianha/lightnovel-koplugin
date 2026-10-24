--[[--
Screen snapshots for local and remote debugging.

Remote commands arrive as uniquely named marker files through the existing
FileBrowser+ API. This module consumes one marker at a time, waits for KOReader
to repaint, captures the framebuffer and atomically publishes a result file.
--]]--

local logger = require("lightnovel.lib.logger")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local Snapshot = {}
Snapshot.__index = Snapshot

Snapshot.DIR = "/mnt/us/koreader/screenshots"
Snapshot.BRIDGE_DIR = "/mnt/us/koreader/screenbridge"
Snapshot.REQUEST_DIR = Snapshot.BRIDGE_DIR .. "/requests"
Snapshot.INFLIGHT_DIR = Snapshot.BRIDGE_DIR .. "/inflight"
Snapshot.RESULT_DIR = Snapshot.BRIDGE_DIR .. "/results"
Snapshot.REMOTE_DIR = Snapshot.DIR .. "/remote"
Snapshot.AUTO_DIR = Snapshot.DIR .. "/auto"
Snapshot.POLL_INTERVAL = 1
Snapshot.REPAINT_DELAY = 0.25
Snapshot.RESULT_RETENTION_SECONDS = 7 * 24 * 60 * 60
Snapshot.REQUEST_TTL_SECONDS = 60 * 60
Snapshot.AUTO_RETENTION_SECONDS = 20 * 60
Snapshot._running = false
Snapshot._busy = false
Snapshot._poll_task = nil
Snapshot._auto_task = nil
Snapshot.AUTO_MIN_INTERVAL = 30
Snapshot.AUTO_MAX_INTERVAL = 3600
Snapshot.AUTO_MAX_FILES = 20
Snapshot.AUTO_INTERVAL_SETTING = "lightnovel_screenshot_auto_interval"
Snapshot.AUTO_INTERVALS = { 0, 30, 60, 300 }
Snapshot._local_sequence = 0

local function valid_id(id)
    return type(id) == "string" and #id > 0 and #id <= 64
        and id:match("^[%w_-]+$") ~= nil
end

local function write_result(id, ok, value)
    local result_path = Snapshot.RESULT_DIR .. "/" .. id .. ".result"
    local temporary_path = result_path .. ".tmp"
    local file, err = io.open(temporary_path, "w")
    if not file then
        logger.err("snapshot: cannot open result", id, tostring(err))
        return false
    end
    file:write(ok and "OK\n" or "ERROR\n")
    -- Extra parens truncate gsub to its first return: the bare call would also
    -- pass the substitution COUNT to write(), appending stray digits to the path.
    file:write((tostring(value or "unknown error"):gsub("[\r\n]", " ")))
    file:write("\n")
    file:close()
    local renamed, rename_err = os.rename(temporary_path, result_path)
    if not renamed then
        os.remove(temporary_path)
        logger.err("snapshot: cannot publish result", id, tostring(rename_err))
        return false
    end
    return true
end

local function read_request(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local id = file:read("*l")
    file:close()
    return id
end

local function png_is_valid(path)
    local file = io.open(path, "rb")
    if not file then return false end
    local signature = file:read(8)
    file:close()
    return signature == "\137PNG\r\n\026\n"
end

local function capture(id)
    if not valid_id(id) then
        return nil, "invalid request id"
    end
    -- util.makePath returns `true` on success and `nil, err` on failure, so
    -- pcall yields (true, true) on success and (true, nil, msg) otherwise:
    -- `made ~= true` catches both failure shapes.
    local ok, made = pcall(util.makePath, Snapshot.REMOTE_DIR)
    if not ok or made ~= true then
        return nil, "cannot create screenshot directory"
    end
    local path = Snapshot.REMOTE_DIR .. "/" .. id .. ".png"
    local shot_ok, shot_err = pcall(function()
        require("device").screen:shot(path)
    end)
    if not shot_ok then
        return nil, tostring(shot_err)
    end
    if not png_is_valid(path) then
        return nil, "screenshot file is missing or is not a PNG"
    end
    logger.info("snapshot: saved", path)
    return path
end

function Snapshot.take(tag, path)
    local label = tostring(tag or "shot"):gsub("[^%w_-]", "_"):sub(1, 32)
    if not path then
        Snapshot._local_sequence = Snapshot._local_sequence + 1
        path = os.date(Snapshot.DIR .. "/lightnovel_" .. label .. "_%Y%m%d_%H%M%S_")
            .. tostring(Snapshot._local_sequence) .. ".png"
    end
    local dir = path:match("^(.*)/[^/]+$")
    local ok, made = pcall(util.makePath, dir)
    if not ok or made ~= true then
        return nil, "cannot create screenshot directory"
    end
    local shot_ok, shot_err = pcall(function()
        require("device").screen:shot(path)
    end)
    if not shot_ok then
        logger.err("snapshot: capture failed", tostring(shot_err))
        return nil, tostring(shot_err)
    end
    if not png_is_valid(path) then
        return nil, "screenshot file is missing or is not a PNG"
    end
    logger.info("snapshot: saved", path)
    return path
end

function Snapshot.after(tag, delay, callback)
    -- Lazily require UIManager so offline tests can stub it in package.loaded
    -- before exercising this module (same pattern as the runtime seams used in
    -- content.lua tests). On device the require is cached and costs nothing.
    local UIManager = require("ui/uimanager")
    if type(UIManager.scheduleIn) ~= "function" then
        logger.dbg("snapshot: scheduleIn unavailable, skipping", tostring(tag))
        return false
    end
    local scheduled, schedule_err = pcall(function()
        UIManager:scheduleIn(delay or Snapshot.REPAINT_DELAY, function()
            local path, err = Snapshot.take(tag)
            if callback then
                local callback_ok, callback_err = pcall(callback, path, err)
                if not callback_ok then
                    logger.err("snapshot: callback failed", tostring(callback_err))
                end
            end
        end)
    end)
    if not scheduled then
        logger.err("snapshot: could not schedule capture", tostring(schedule_err))
    end
    return scheduled
end

local function finish_request(id, inflight_path)
    local png_path
    local ok, result, err = pcall(capture, id)
    if ok then
        png_path, err = result, err
    else
        err = tostring(result)
    end
    if Snapshot._running then
        if png_path then
            write_result(id, true, png_path)
        else
            logger.err("snapshot: remote capture failed", id, tostring(err))
            write_result(id, false, err)
        end
    end
    os.remove(inflight_path)
    Snapshot._busy = false
end

local function consume_request(id)
    if not valid_id(id) then return false end
    local request_path = Snapshot.REQUEST_DIR .. "/" .. id .. ".request"
    local ready_path = Snapshot.REQUEST_DIR .. "/" .. id .. ".ready"
    local inflight_path = Snapshot.INFLIGHT_DIR .. "/" .. id .. ".active"
    local result_path = Snapshot.RESULT_DIR .. "/" .. id .. ".result"
    local ready = read_request(ready_path)
    if ready ~= "ready" then return false end
    if lfs.attributes(result_path, "mode") then
        os.remove(request_path)
        os.remove(ready_path)
        return false
    end
    local payload = read_request(request_path)
    if payload ~= id then
        os.remove(request_path)
        os.remove(ready_path)
        logger.warn("snapshot: rejected malformed request", id)
        return false
    end
    if lfs.attributes(inflight_path, "mode") then
        os.remove(request_path)
        os.remove(ready_path)
        return false
    end
    local moved, move_err = os.rename(request_path, inflight_path)
    if not moved then
        logger.warn("snapshot: could not claim request", id, tostring(move_err))
        return false
    end
    os.remove(ready_path)
    Snapshot._busy = true
    require("ui/uimanager"):scheduleIn(Snapshot.REPAINT_DELAY, function()
        finish_request(id, inflight_path)
    end)
    return true
end

local function for_each_filename(dir, callback)
    local ok, iter, dir_object = pcall(lfs.dir, dir)
    if not ok or type(iter) ~= "function" then return false end
    for filename in iter, dir_object do
        if filename ~= "." and filename ~= ".." then
            callback(filename)
        end
    end
    return true
end

local function prune_old_files(dir, suffix, cutoff)
    for_each_filename(dir, function(filename)
        if filename:sub(-#suffix) == suffix then
            local path = dir .. "/" .. filename
            local attrs = lfs.attributes(path)
            if attrs and attrs.modification and attrs.modification < cutoff then
                os.remove(path)
            end
        end
    end)
end

function Snapshot.poll()
    if Snapshot._busy then return end
    for_each_filename(Snapshot.REQUEST_DIR, function(filename)
        if not Snapshot._busy then
            local ready_id = filename:match("^([%w_-]+)%.ready$")
            if ready_id then
                local request_path = Snapshot.REQUEST_DIR .. "/" .. ready_id .. ".request"
                local attrs = lfs.attributes(request_path)
                if attrs and attrs.modification
                    and os.time() - attrs.modification > Snapshot.REQUEST_TTL_SECONDS then
                    local ready_path = Snapshot.REQUEST_DIR .. "/" .. ready_id .. ".ready"
                    os.remove(request_path)
                    os.remove(ready_path)
                    logger.warn("snapshot: expired request removed", ready_id)
                else
                    local ok, consumed = pcall(consume_request, ready_id)
                    if not ok then
                        logger.err("snapshot: request processing failed", ready_id, tostring(consumed))
                    end
                end
            end
        end
    end)
end

function Snapshot.getAutoInterval()
    local settings = rawget(_G, "G_reader_settings")
    local interval = settings and tonumber(settings:readSetting(Snapshot.AUTO_INTERVAL_SETTING)) or 0
    for _, allowed in ipairs(Snapshot.AUTO_INTERVALS) do
        if interval == allowed then return interval end
    end
    return 0
end

local function prune_auto_files()
    local files = {}
    for_each_filename(Snapshot.AUTO_DIR, function(filename)
        if filename:match("%.png$") then
            local path = Snapshot.AUTO_DIR .. "/" .. filename
            local attrs = lfs.attributes(path)
            if attrs and attrs.modification then
                files[#files + 1] = { path = path, modification = attrs.modification }
            end
        end
    end)
    table.sort(files, function(a, b)
        return a.modification > b.modification
    end)
    local cutoff = os.time() - Snapshot.AUTO_RETENTION_SECONDS
    local retained = 0
    for _, file in ipairs(files) do
        if retained >= Snapshot.AUTO_MAX_FILES or file.modification < cutoff then
            os.remove(file.path)
        else
            retained = retained + 1
        end
    end
end

local function schedule_auto()
    if not Snapshot._running then return end
    local interval = Snapshot.getAutoInterval()
    if interval <= 0 then return end
    Snapshot._auto_task = function()
        Snapshot._auto_task = nil
        if not Snapshot._running then return end
        local current_interval = Snapshot.getAutoInterval()
        if current_interval <= 0 then return end
        Snapshot._auto_sequence = (Snapshot._auto_sequence or 0) + 1
        local filename = os.date(Snapshot.AUTO_DIR .. "/lightnovel_auto_%Y%m%d_%H%M%S_")
            .. tostring(Snapshot._auto_sequence) .. ".png"
        local path, err = Snapshot.take("auto", filename)
        if path then
            prune_auto_files()
        else
            logger.warn("snapshot: automatic capture failed", tostring(err))
        end
        schedule_auto()
    end
    require("ui/uimanager"):scheduleIn(interval, Snapshot._auto_task)
end

function Snapshot.setAutoInterval(interval)
    interval = tonumber(interval)
    local allowed = false
    for _, value in ipairs(Snapshot.AUTO_INTERVALS) do
        if interval == value then
            allowed = true
            break
        end
    end
    if not allowed then return false end
    local settings = rawget(_G, "G_reader_settings")
    if not settings then return false end
    settings:saveSetting(Snapshot.AUTO_INTERVAL_SETTING, interval)
    if Snapshot._auto_task then
        require("ui/uimanager"):unschedule(Snapshot._auto_task)
        Snapshot._auto_task = nil
    end
    schedule_auto()
    return true
end

local function schedule_poll()
    if not Snapshot._running then return end
    Snapshot._poll_task = function()
        Snapshot._poll_task = nil
        if not Snapshot._running then return end
        Snapshot.poll()
        local cutoff = os.time() - Snapshot.RESULT_RETENTION_SECONDS
        prune_old_files(Snapshot.RESULT_DIR, ".result", cutoff)
        prune_old_files(Snapshot.REMOTE_DIR, ".png", cutoff)
        schedule_poll()
    end
    require("ui/uimanager"):scheduleIn(Snapshot.POLL_INTERVAL, Snapshot._poll_task)
end

function Snapshot.start()
    if Snapshot._running then return true end
    for _, dir in ipairs({ Snapshot.DIR, Snapshot.BRIDGE_DIR, Snapshot.REQUEST_DIR,
        Snapshot.INFLIGHT_DIR, Snapshot.RESULT_DIR, Snapshot.REMOTE_DIR,
        Snapshot.AUTO_DIR }) do
        local ok, success = pcall(util.makePath, dir)
        if not ok or not success then
            logger.err("snapshot: cannot initialize directory", dir, tostring(success))
            return false
        end
    end
    Snapshot._running = true
    schedule_poll()
    schedule_auto()
    logger.info("snapshot: remote request listener started")
    return true
end

function Snapshot.stop()
    Snapshot._running = false
    local UIManager = require("ui/uimanager")
    for _, field in ipairs({ "_poll_task", "_auto_task" }) do
        local task = Snapshot[field]
        if task then
            pcall(function() UIManager:unschedule(task) end)
            Snapshot[field] = nil
        end
    end
end

return Snapshot
