--[[--
Cover lookup for the bookshelf rows and the catalogue header.

Layout under the plugin data dir (written by chapter_cache:_cache_cover):

    covers/<key>.jpg          original bytes, exactly as the server sent them
    covers/<key>.thumb.png    240x360 UI-sized copy, see cover_thumbnail.lua

`<key>` is Cache.book_key(book) -- "bid_3177" for a server-shelf book, which is
why the cover is found by recomputing the key from the same book table rather
than by storing a path anywhere.

Resolution order is thumb first, original second. The original is a real fallback,
not a placeholder: covers can be dropped onto the device by hand (the shipped
bid_3177.jpg was), and a book must still show its cover before the thumbnail pass
has run. The thumbnail pass then makes every later repaint cheap.
--]]--

local lfs = require("libs/libkoreader-lfs")

local Cover = {}
local Thumbnail = require("lightnovel.lib.cover_thumbnail")
local logger = require("lightnovel.lib.logger")

-- The shelf row draws about 70x100 and the catalogue header about 145x210 on a
-- 600x800 screen, so 240x360 covers both with headroom on a wider panel while
-- staying roughly nine times cheaper to decode than the 577x812 original.
Cover.THUMB_WIDTH = 240
Cover.THUMB_HEIGHT = 360

-- Anything smaller than this is a truncated or placeholder file, not an image.
Cover.MIN_IMAGE_BYTES = 16

-- One info line per book per process, not per row per repaint: the point of the
-- line is to prove from crash.log which file the UI actually loaded, and a line
-- per paint would bury everything else.
local reported = {}

local function usable_file(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    local attributes = lfs.attributes(path)
    return attributes ~= nil and attributes.mode == "file"
        and (tonumber(attributes.size) or 0) >= Cover.MIN_IMAGE_BYTES
end

--- Magic-byte check for a downloaded cover.
---
--- Deliberately conservative: it rejects anything it does not positively
--- recognise instead of trying to be a general sniffer. In particular SVG and
--- XML are NOT accepted -- cover_thumbnail.lua hands the file to
--- ui/renderimage, whose fallback path loads credocument, and crengine's
--- engineInit() must never run inside a forked worker (it binds Screen and
--- FontList at module scope and registers every font).
local function looks_like_image(body)
    if type(body) ~= "string" or #body < 4 then
        return false
    end
    local b1, b2, b3, b4 = body:byte(1, 4)
    if b1 == 0xFF and b2 == 0xD8 then            -- JPEG
        return true
    end
    if b1 == 0x89 and b2 == 0x50 and b3 == 0x4E and b4 == 0x47 then  -- PNG
        return true
    end
    if body:sub(1, 3) == "GIF" then             -- GIF87a / GIF89a
        return true
    end
    if body:sub(1, 2) == "BM" then              -- BMP
        return true
    end
    if b1 == 0x52 and b2 == 0x49 and b3 == 0x46 and b4 == 0x46 then  -- RIFF
        return body:sub(9, 12) == "WEBP"
    end
    return false
end

--- The cover directory, or nil plus a reason. settings may be missing entirely
--- when the caller runs before init, so every step is guarded.
function Cover.dir(settings)
    if not settings then
        return nil, "no_settings"
    end
    local ok, dir = pcall(function() return settings:coverDir() end)
    if not ok or type(dir) ~= "string" or dir == "" then
        return nil, "coverDir_failed"
    end
    return dir
end

function Cover.source_path(settings, key)
    local dir, err = Cover.dir(settings)
    if not dir then
        return nil, err
    end
    if type(key) ~= "string" or key == "" then
        return nil, "no_key"
    end
    return dir .. "/" .. key .. ".jpg"
end

function Cover.thumb_path(settings, key)
    local dir, err = Cover.dir(settings)
    if not dir then
        return nil, err
    end
    if type(key) ~= "string" or key == "" then
        return nil, "no_key"
    end
    return dir .. "/" .. key .. ".thumb.png"
end

--- The best image to draw for this book right now.
--- @return string|nil path, string|nil which ("thumb" / "source"), string|nil why
function Cover.resolve(settings, key)
    local thumb = Cover.thumb_path(settings, key)
    if thumb and usable_file(thumb) then
        if not reported[key] then
            reported[key] = "thumb"
            logger.info("cover: using thumbnail", tostring(key), thumb)
        end
        return thumb, "thumb"
    end
    local source = Cover.source_path(settings, key)
    if source and usable_file(source) then
        if not reported[key] then
            reported[key] = "source"
            logger.info("cover: using original, no thumbnail yet", tostring(key),
                source)
        end
        return source, "source"
    end
    local why = "no_cover_file"
    if thumb and not usable_file(thumb) and lfs.attributes(thumb) then
        -- Present but truncated: worth saying out loud, because that is the
        -- failure mode that used to be invisible.
        why = "thumbnail_truncated"
    end
    if not reported[key] then
        reported[key] = why
        logger.dbg("cover: none for", tostring(key), why)
    end
    return nil, nil, why
end

--- True when this book has a cover that is not thumbnail-sized yet, i.e. when
--- Cover.resolve fell back to the original. Drives the background render pass.
function Cover.needs_thumbnail(settings, key)
    local thumb = Cover.thumb_path(settings, key)
    if not thumb or usable_file(thumb) then
        return false
    end
    local source = Cover.source_path(settings, key)
    return source ~= nil and usable_file(source) or false
end

--- Render the thumbnail once, atomically, if it is missing.
--- Safe to call from a worker subprocess: it touches nothing but the filesystem.
--- @return string|nil thumbnail path, string|nil reason on failure
function Cover.ensure_thumbnail(settings, key)
    local thumb = Cover.thumb_path(settings, key)
    if not thumb then
        return nil, "no_thumb_path"
    end
    if usable_file(thumb) then
        return thumb
    end
    local source = Cover.source_path(settings, key)
    if not source then
        return nil, "no_source_path"
    end
    if not usable_file(source) then
        return nil, "source_missing"
    end
    local dir = Cover.dir(settings)
    if not dir then
        return nil, "no_cover_dir"
    end
    -- Settings:new() creates the directory, but this also runs in a subprocess
    -- that never went through init, and a missing directory makes every open
    -- below fail with a far less obvious message.
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(dir)
    end
    if lfs.attributes(dir, "mode") ~= "directory" then
        logger.err("cover: cannot create cover dir:", dir)
        return nil, "cover_dir_unwritable"
    end

    -- Write beside the target and rename: a half-written PNG that ImageWidget
    -- picks up would paint as a blank box forever, because nothing retries.
    local temporary = thumb .. ".part.png"
    os.remove(temporary)
    local rendered, value, err = pcall(Thumbnail.render, source, temporary,
        Cover.THUMB_WIDTH, Cover.THUMB_HEIGHT)
    if not rendered or not value or not usable_file(temporary) then
        os.remove(temporary)
        local why = tostring(err or value or "thumbnail_render_failed")
        logger.err("cover: thumbnail render failed key=", tostring(key), why)
        return nil, why
    end
    local renamed, rename_err = os.rename(temporary, thumb)
    if not renamed then
        os.remove(temporary)
        logger.err("cover: thumbnail commit failed key=", tostring(key),
            tostring(rename_err))
        return nil, tostring(rename_err or "thumbnail_commit_failed")
    end
    reported[key] = "thumb"
    logger.info("cover: thumbnail ready key=", tostring(key), "at", thumb)
    return thumb
end

--- Download a cover and make its thumbnail, in one call.
---
--- The URL carries a signature (?m=<token>&t=<expiry>) and MUST be used verbatim;
--- rebuilding one from the path alone yields a 403, so the caller passes through
--- whatever the listing handed us.
---
--- Safe to call from a worker subprocess: it touches the network and the
--- filesystem only. Failures are non-fatal -- the caller falls back to whatever
--- is already on disk.
--- @return string|nil source path, string|nil reason on failure
function Cover.download(client, key, url)
    if not client or type(url) ~= "string" or url == "" then
        logger.err("cover: bad url for", tostring(key))
        return nil, "bad_url"
    end
    local settings = client.settings
    if not settings then
        logger.err("cover: client has no settings (in subprocess?)")
        return nil, "no_settings"
    end
    local source = Cover.source_path(settings, key)
    if not source then
        return nil, "no_source_path"
    end
    -- Already downloaded: still make sure the thumbnail exists, because the
    -- file being present says nothing about whether the UI-sized copy does.
    if usable_file(source) then
        Cover.ensure_thumbnail(settings, key)
        return source
    end
    local dir = Cover.dir(settings)
    if not dir then
        return nil, "no_cover_dir"
    end
    -- Settings:new() creates the directory, but this also runs in a subprocess
    -- that never went through init, and a missing directory makes every open
    -- below fail with a far less obvious message.
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(dir)
    end
    if lfs.attributes(dir, "mode") ~= "directory" then
        logger.err("cover: cannot create cover dir:", dir)
        return nil, "cover_dir_unwritable"
    end

    local body, err = client:get(url, { timeout = 45 })
    if type(body) ~= "string" or body == "" then
        logger.err("cover: download failed key=", tostring(key), "err=",
            tostring(err))
        return nil, tostring(err or "empty_body")
    end

    -- Refuse anything that is not an image BEFORE writing it. During the outage
    -- the CDN answered with its order-expired HTML page, and that page was
    -- happily saved as <key>.jpg: usable_file() only checks the size, so the
    -- shelf then tried to decode HTML as a JPEG on the UI thread.
    if not looks_like_image(body) then
        logger.warn("cover: rejecting non-image body key=", tostring(key),
            "bytes=", tostring(#body), "head=",
            string.sub(body:gsub("%s+", " "), 1, 60))
        return nil, "not_an_image"
    end

    local f = io.open(source, "wb")
    if not f then
        logger.err("cover: cannot open for write:", source)
        return nil, "open_failed"
    end
    f:write(body)
    f:close()
    logger.info("cover: saved", source, tostring(#body), "bytes")
    -- ensure_thumbnail can fail (that is what cover_thumbnail.lua is for), and
    -- its result used to be dropped: the caller counted the book as done, the
    -- shelf refreshed, and Cover.resolve fell back to the FULL-SIZE original,
    -- which ShelfRow then decoded on the UI thread -- seconds of frozen e-ink.
    local thumb, why = Cover.ensure_thumbnail(settings, key)
    if not thumb then
        logger.warn("cover: thumbnail failed key=", tostring(key), "why=",
            tostring(why))
        return source, "thumbnail_failed"
    end
    return source
end

--- True when this book has no cover file yet but the listing gave us a URL for
--- one. Drives the background fetch pass on the shelf.
function Cover.needs_download(settings, key, url)
    if type(url) ~= "string" or url == "" then
        return false
    end
    local source = Cover.source_path(settings, key)
    return source ~= nil and not usable_file(source)
end

--- Forget which books have already been logged. Used by tests and by the
--- settings screen when a purge may have removed covers.
function Cover.reset_reported()
    reported = {}
end

return Cover