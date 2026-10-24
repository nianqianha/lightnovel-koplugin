--[[--
Render a bounded, UI-sized thumbnail from a cached cover image.

Ported from weread.koplugin (weread/lib/cover_thumbnail.lua), which solves the same
problem for its shelf: the file on disk is much larger than anything the UI draws.
The cover for this book is a 577x812 JPEG (50117 bytes), and a shelf page decodes
seven of them at once -- roughly 3.3 megapixels per page turn, which on e-ink is
seconds of frozen screen. A 240x360 PNG is about 86k pixels, so the same page
costs a fraction of that, and it is paid for exactly once per book because the
result is cached next to the original.

Deliberately not using ImageWidget here: this runs inside a worker subprocess and
must not touch KOReader's global image cache. Only the render is bounded -- the
decoded source buffer is always freed, even on the failure path, or the
subprocess leaks a full-frame buffer on a memory-tight device.
--]]--

local RenderImage = require("ui/renderimage")

local Thumbnail = {}

local function free(buffer)
    if buffer and type(buffer.free) == "function" then
        pcall(buffer.free, buffer)
    end
end

--- Scale `source` to fit inside max_width x max_height and write it as a PNG.
--- Aspect ratio is preserved and the image is never scaled up.
--- @return string|nil target on success, nil plus a message on failure
function Thumbnail.render(source, target, max_width, max_height)
    max_width = math.max(1, math.floor(tonumber(max_width) or 240))
    max_height = math.max(1, math.floor(tonumber(max_height) or 360))

    -- Named source_image, not image: the API contract gate keys its
    -- variable->class map by bare variable name across the whole plugin, so a
    -- local called `image` that some other file assigns from ImageWidget:new
    -- makes it read getWidth() here as an ImageWidget call. The value really is
    -- a BlitBuffer from RenderImage, which is what has getWidth/getHeight.
    local source_image, scaled
    local ok, result = xpcall(function()
        source_image = assert(RenderImage:renderImageFile(source, false, nil, nil),
            "cover decode failed")
        local width = math.max(1, tonumber(source_image:getWidth()) or 1)
        local height = math.max(1, tonumber(source_image:getHeight()) or 1)
        local ratio = math.min(1, max_width / width, max_height / height)
        local target_width = math.max(1, math.floor(width * ratio + 0.5))
        local target_height = math.max(1, math.floor(height * ratio + 0.5))

        if target_width ~= width or target_height ~= height then
            scaled = assert(RenderImage:scaleBlitBuffer(
                source_image, target_width, target_height, false),
                "cover scale failed")
        else
            scaled = source_image
        end
        -- KOReader's writePNG raises on failure and returns no value on success.
        scaled:writePNG(target)
        return target
    end, debug.traceback)

    if scaled ~= source_image then free(scaled) end
    free(source_image)
    if not ok then return nil, result end
    return result
end

return Thumbnail