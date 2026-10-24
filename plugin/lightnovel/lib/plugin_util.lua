-- Small shared helpers for the lightnovel plugin.
--
-- Error text is normalized before it reaches the UI: a stack trace on an
-- e-ink screen is unreadable, and an unbounded message can overflow the
-- InfoMessage box.
local logger = require("lightnovel.lib.logger")

local PluginUtil = {
    unpack_args = unpack or table.unpack,
}

function PluginUtil.tr(text)
    return text
end

function PluginUtil.log_error(err)
    local text = tostring(err):gsub("[%c]+", " ")
    if #text > 500 then
        return text:sub(1, 500) .. "..."
    end
    return text
end

function PluginUtil.display_error(err)
    local text = tostring(err)
    text = text:match("^[^\r\n]+") or text
    if #text > 300 then
        return text:sub(1, 300) .. "..."
    end
    return text
end

function PluginUtil.file_exists(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    file:close()
    return true
end

function PluginUtil.now_ms()
    local ok, Time = pcall(require, "ui/time")
    if ok and Time then
        return Time.to_s(Time.monotonic())
    end
    return os.time() * 1000
end

return PluginUtil
