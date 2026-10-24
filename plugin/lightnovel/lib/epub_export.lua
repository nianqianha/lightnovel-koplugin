--[[--
Package the cached chapters of one book into a single EPUB, comments included.

Structure and archive mechanics are ported from weread.koplugin
(weread/lib/content.lua: save_book_epub + write_epub), which is the only proven
EPUB writer on this device: KOReader ships libarchive, `ffi/archiver` wraps it,
and two details are not optional --
  * `mimetype` must be added FIRST and stored (not deflated), or readers reject
    the file;
  * `Writer:addPath()` returns false after a successful walk because its terminal
    status is EOF, while a real libarchive failure sets `err`. Accept only the
    error-free EOF case.

Division of labour, following the rule the rest of this plugin already obeys:
the parent process reads SQLite (comment bodies) and renders them to HTML
fragments; the worker subprocess reads the chapter files and writes the archive.
Passing 83 pre-rendered comment fragments is a few hundred KB, while the ~2.4 MB
of chapter bodies never crosses the process boundary twice.

Comments are appended to the end of their own chapter ("option A"), so the book
reads exactly like the website: text, then its comments, then the next chapter.
--]]--

local lfs = require("libs/libkoreader-lfs")

local Content = require("lightnovel.lib.content")
local Cover = require("lightnovel.lib.cover")
local BookCatalog = require("lightnovel.lib.book_catalog")
local logger = require("lightnovel.lib.logger")

local Export = {}
Export.__index = Export

local CSS = [[
body { line-height: 1.7; margin: 5%; }
h1.ln-title { font-size: 1.2em; margin: 0 0 1em 0; }
h1.ln-volume { page-break-before: always; border-bottom: 1px solid #888; padding-bottom: 0.5em; }
img { max-width: 100%; height: auto; }
.ln-image-placeholder { color: #666; font-style: italic; }
.ln-comments { margin-top: 2em; border-top: 2px solid #999; padding-top: 0.5em; }
.ln-comments h2 { font-size: 1.05em; margin: 0 0 0.6em 0; }
.ln-comment { margin: 0 0 0.9em 0; }
.ln-comment .ln-meta { font-size: 0.8em; color: #555; }
.ln-replies { margin: 0.4em 0 0 1.2em; font-size: 0.95em; }
.ln-replies .ln-meta { color: #666; }
]]

local function xml_escape(text)
    local s = tostring(text or "")
    s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    s = s:gsub('"', "&quot;"):gsub("'", "&apos;")
    return s
end

-- Sidecar values are Lua source, not XML. `%q` escapes quotes, backslashes,
-- newlines and control bytes so server-provided titles/authors remain one valid
-- Lua string literal instead of corrupting metadata.epub.lua.
local function lua_quote(value)
    return string.format("%q", tostring(value or ""))
end

local function utc_modified()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local rewrite_image_urls
local image_extension

local function safe_comment_html(value, image_urls)
    local source = Content.decode_entities(Content.decode_entities(
        tostring(value or "")))
    source = source:gsub("%[img[^%]]*%](.-)%[/img%]", '<img src="%1"/>')
    local out, pos = {}, 1
    while pos <= #source do
        local first, last = source:find("<[^>]*>", pos)
        if not first then
            local text = source:sub(pos):gsub("\r\n", "\n")
            out[#out + 1] = xml_escape(text):gsub("\n", "<br/>")
            break
        end
        if first > pos then
            local text = source:sub(pos, first - 1):gsub("\r\n", "\n")
            out[#out + 1] = xml_escape(text):gsub("\n", "<br/>")
        end
        local tag = source:sub(first, last)
        local lower = tag:lower()
        if lower:match("^<%s*br[%s/]*>$") then
            out[#out + 1] = "<br/>"
        elseif lower:match("^<%s*img[%s/>]") then
            local url = tag:match('[sS][rR][cC]%s*=%s*"([^"]+)"')
                or tag:match("[sS][rR][cC]%s*=%s*'([^']+)'")
            if url and url:match("^https?://") then
                local normalized = Content.decode_entities(url):gsub("%)$", "")
                local replacement = image_urls and image_urls[normalized]
                if replacement then
                    out[#out + 1] = '<img src="../images/'
                        .. xml_escape(replacement) .. '" alt="评论图片"/>'
                else
                    -- The fragment is rendered in the parent process; leave a
                    -- trusted URL for rewrite_image_urls() in the EPUB worker.
                    out[#out + 1] = '<img src="' .. xml_escape(normalized)
                        .. '" alt="评论图片"/>'
                end
            else
                out[#out + 1] = '<span class="ln-image-placeholder">[评论图片]</span>'
            end
        elseif lower:match("^<%s*/?%s*[biu]%s*>") then
            local name = lower:match("^<%s*/?%s*([biu])")
            local closing = lower:match("^<%s*/") ~= nil
            local open_tag = ({ b = "strong", i = "em", u = "span" })[name]
            if open_tag then
                if closing then out[#out + 1] = "</" .. open_tag .. ">"
                else out[#out + 1] = "<" .. open_tag .. ">" end
            end
        else
            -- Unknown pseudo-tags such as the emoticon `<3` are text, not HTML.
            out[#out + 1] = xml_escape(tag)
        end
        pos = last + 1
    end
    return table.concat(out)
end

-- `on_progress` is called around every network attempt, and it is not optional
-- decoration. This runs inside the worker child, and the worker's timeout is a
-- NO-PROGRESS gap: a chapter with illustrations used to spend up to
-- 2 candidates x 3 attempts x 30s = 180s per image here, silently, which on a
-- 58-chapter book with several images each blew straight through the 600s
-- budget. The parent killed the child mid-fetch, no result file was written, and
-- the reader got `worker_no_result` for an export that had not actually failed --
-- it had gone quiet. Emitting before and after each attempt keeps the longest
-- possible gap down to a single request.
-- 插图磁盘缓存键（b28）：URL 的 djb2 32 位哈希。百张量级碰撞概率 ~1e-6，
-- 足够；缓存文件按内容 magic 识别类型，文件名不带后缀。
local function url_cache_name(url)
    local h = 5381
    for i = 1, #url do
        h = (h * 33 + url:byte(i)) % 4294967296
    end
    return string.format("%08x", h)
end

--- 抓取一个插图 URL：磁盘缓存优先（b28），未命中走候选×2 次网络重试（b20 的
--- 重定向跟随在 client:get 内），成功原子落缓存。预取阶段（b29）与 build 期
--- gsub 回调共用本函数，保证两条路径行为一致。
--- @return string|nil bytes, string|nil err, string|nil ext
local function fetch_image_bytes(client, url, image_cache_dir, on_progress)
    local bytes, err, ext
    local cache_file = image_cache_dir
        and (image_cache_dir .. "/" .. url_cache_name(url)) or nil
    if cache_file then
        pcall(function() lfs.mkdir(image_cache_dir) end)
        local cached = io.open(cache_file, "rb")
        if cached then
            bytes = cached:read("*a")
            cached:close()
            ext = image_extension(bytes)
            if not ext or #bytes > 8 * 1024 * 1024 then
                bytes, ext = nil, nil
            end
        end
    end
    if bytes then return bytes, nil, ext end
    local candidates = { url }
    if url:find("i.noire.cc:332", 1, true) then
        candidates[#candidates + 1] = url:gsub("i%.noire%.cc:332", "i.noire.cc")
    end
    for _c, candidate in ipairs(candidates) do
        -- Two attempts, not three: the second candidate already
        -- doubles the worst case, and an image that has not arrived
        -- in 2x20s is not arriving. Dropping it leaves a visible
        -- placeholder in the book instead of a silent hang.
        for _attempt = 1, 2 do
            if on_progress then
                on_progress("image_fetch_start", url)
            end
            bytes, err = client:get(candidate, { timeout = 20 })
            if bytes then ext = image_extension(bytes) end
            if bytes and ext and #bytes <= 8 * 1024 * 1024 then break end
            bytes, ext = nil, nil
        end
        if bytes and ext then break end
    end
    -- 抓到才落缓存：临时文件 + 原子改名，失败不留脏文件。
    if bytes and ext and cache_file then
        pcall(function()
            local tmp = cache_file .. ".tmp"
            local w = io.open(tmp, "wb")
            if w then
                w:write(bytes)
                w:close()
                os.rename(tmp, cache_file)
            end
        end)
    end
    return bytes, err, ext
end

rewrite_image_urls = function(body, client, assets, image_urls, on_progress,
    image_cache_dir)
    if type(body) ~= "string" then return "" end
    local fetched = 0
    local failed = 0
    return (body:gsub('(<img[^>]-src%s*=%s*")([^"]+)(")',
        function(prefix, source, suffix)
            local url = Content.decode_entities(source):gsub("%)$", "")
            local parsed = url:match("^https?://([^/]+)")
            if not parsed then return prefix .. source .. suffix end
            local host = parsed:match("^[^:]+")
            -- The bare apex host is NOT an oversight. The site serves a subset of
            -- illustrations from `https://lightnovel.fun/upload-files/images/...`
            -- with the same signed query string as the api./res. subdomains
            -- (device: 9 of 46 images for bid_16484), so refusing it dropped
            -- those nine from the EPUB while every other image in the same book
            -- was embedded. The signed URL is used verbatim, exactly as the
            -- listing handed it over; nothing is rewritten or guessed.
            local allowed = host == "api.lightnovel.fun"
                or host == "static.lightnovel.fun" or host == "res.lightnovel.fun"
                or host == "www.lightnovel.fun" or host == "lightnovel.fun"
                or host == "i.noire.cc"
            if not allowed then
                logger.warn("export: refusing image host", tostring(host))
                return '<span class="ln-image-placeholder">[图片来源不受支持]</span>'
            end
            local existing = assets[url]
            if not existing and client and type(client.get) == "function" then
                local candidates = { url }
                if url:find("i.noire.cc:332", 1, true) then
                    candidates[#candidates + 1] = url:gsub("i%.noire%.cc:332", "i.noire.cc")
                end
                local bytes, err, ext
                -- b28：先查磁盘缓存，命中免网络（重出版不再整批重下百张图，
                -- 实测一次约 5 分钟）。损坏/不完整的缓存按未命中处理重抓。
                -- b29：抓取细节抽到 fetch_image_bytes，与预取阶段共用。
                bytes, err, ext = fetch_image_bytes(client, url,
                    image_cache_dir, on_progress)
                if bytes and ext and #bytes <= 8 * 1024 * 1024 then
                    local n = 0
                    for _asset_key in pairs(assets) do n = n + 1 end
                    local name = string.format("inline-%04d%s", n + 1, ext)
                    existing = { name = name, data = bytes, mime = select(2, image_extension(bytes)) }
                    assets[url] = existing
                    fetched = fetched + 1
                else
                    failed = failed + 1
                    logger.warn("export: image unavailable or invalid", tostring(err),
                        "url=", url)
                end
            end
            if existing then
                if image_urls then image_urls[url] = existing.name end
                return prefix .. "../images/" .. existing.name .. suffix
            end
            return '<span class="ln-image-placeholder">[图片暂不可用]</span>'
        end)), fetched, failed
end

--- Signature-detection for the embedded cover. Same rule as weread: an
--- unrecognised body is an error/login page served with 200, and embedding it
--- would produce a cover page that renders blank.
image_extension = function(data)
    if type(data) ~= "string" then
        return nil
    end
    if data:sub(1, 3) == "\255\216\255" then
        return ".jpg", "image/jpeg"
    end
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then
        return ".png", "image/png"
    end
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
        return ".webp", "image/webp"
    end
    if data:sub(1, 6) == "GIF87a" or data:sub(1, 6) == "GIF89a" then
        return ".gif", "image/gif"
    end
    return nil
end

--- Write the archive. Verbatim from weread, including the two quirks above.
local function write_epub(path, entries)
    local Archiver = require("ffi/archiver")
    local archive = Archiver.Writer:new{}
    local part_path = path .. ".part"
    pcall(os.remove, part_path)
    if not archive:open(part_path, "epub") then
        error("failed to open archive for writing: " .. tostring(archive.err), 0)
    end
    local mtime = os.time()
    local ok, err = xpcall(function()
        assert(archive:setZipCompression("store"), archive.err)
        assert(archive:addFileFromMemory("mimetype", "application/epub+zip",
            mtime), archive.err)
        assert(archive:setZipCompression("deflate"), archive.err)
        for _, entry in ipairs(entries) do
            local added = archive:addFileFromMemory(entry.name, entry.data or "",
                mtime)
            assert(added, archive.err or ("failed to add " .. tostring(entry.name)))
        end
    end, debug.traceback)
    pcall(function() archive:close() end)
    if not ok then
        pcall(os.remove, part_path)
        error(err, 0)
    end
    -- Atomic commit: a half-written EPUB in the library is worse than none,
    -- because the reader will try to parse it and report a corrupt book.
    local renamed, rename_err = os.rename(part_path, path)
    if not renamed then
        pcall(os.remove, part_path)
        error(tostring(rename_err or "failed to commit EPUB"), 0)
    end
end

--- Write <book>.sdr/metadata.epub.lua beside the EPUB.
---
--- Every book already in the reader's library has one (北派盗墓笔记 - full.sdr,
--- 贩罪 - full.sdr, ...). It is what KOReader reads for the title, the author and
--- the document properties, and it is created the first time a document is
--- opened -- so a freshly published book showed up as a bare filename until the
--- reader opened it once. Writing it here means the entry is correct on sight.
---
--- Only the identity keys are written. The reader's sidecars also carry reading
--- state (percent_finished, page count, crengine cache paths, per-document
--- render settings); those belong to crengine and inventing values for them
--- would be worse than their absence.
local function write_sidecar(epub_path, title, author, entries)
    local sdr = epub_path:gsub("%.epub$", "") .. ".sdr/metadata.epub.lua"
    local dir = sdr:match("^(.*)/[^/]+$")
    if dir and lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(dir)
    end
    if lfs.attributes(dir or "", "mode") ~= "directory" then
        logger.warn("export: cannot create sidecar dir", tostring(dir))
        return false, "sidecar_dir_unwritable"
    end
    -- Reuse xml_escape: it already turns & < > " ' into entities, which is
    -- exactly what a double-quoted Lua literal needs, and it is already tested.
    local q_title = xml_escape(title or "")
    local q_author = xml_escape(author or "")
    local authors = q_author ~= "" and (lua_quote(author) .. ",") or ""
    local body = table.concat({
        "-- KOReader document metadata sidecar",
        "return {",
        '    ["doc_path"] = ', lua_quote(epub_path), ',',
        '    ["doc_props"] = {',
        '        ["title"] = ', lua_quote(title), ',',
        '        ["authors"] = {', authors, "},",
        '        ["language"] = "zh-CN",',
        "    },",
        '    ["title"] = ', lua_quote(title), ',',
        '    ["authors"] = {', authors, "},",
        '    ["language"] = "zh-CN",',
        '    ["doc_props_open"] = true,',
        '    ["partial_md5_checksum"] = "",',
        '    ["stats"] = {},',
        '    ["annotations"] = {},',
        '    ["highlights"] = {},',
        '    ["notes"] = {},',
        '    ["page_overlap_style"] = 0,',
        '    ["percent_finished"] = 0,',
        '    ["series"] = {},',
        '    ["status"] = "reading",',
        "}",
    }, "\n")
    -- Same atomic discipline as the chapter writes: a half-written sidecar is a
    -- Lua syntax error in a file KOReader loads on every open of that book.
    local ok, err = Content.write_atomic(sdr, body)
    if not ok then
        logger.warn("export: sidecar not written:", sdr, tostring(err))
        return false, err
    end
    logger.info("export: sidecar written:", sdr)
    return true
end

--- Extract the body of a cached chapter.
---
--- The comment marker is KEPT. It used to be stripped here on the reasoning that
--- "in an EPUB there is no plugin to intercept it" -- but once the merged book is
--- what the reader opens (so that one title is one entry in 正在阅读, the way
--- weread does it), that is no longer true: the plugin's reader hook is installed
--- in the same reader and matches on the href, not on the file's identity.
--- Stripping it therefore threw away the interactive comment panel for exactly the
--- files people now read.
---
--- Keeping the anchor as well means that IF interception ever fails, KOReader's
--- fallback is a jump to an element that exists in the same file, rather than a
--- dead "#lncomment-<aid>" link that silently does nothing.
local function chapter_body(xhtml)
    local body = tostring(xhtml or ""):match("<body[^>]*>(.*)</body>")
    if not body then
        return nil
    end
    return (body:gsub("^%s+", ""):gsub("%s+$", ""))
end

function Export:new(options)
    options = options or {}
    return setmetatable({
        settings = assert(options.settings, "settings required"),
        cache = assert(options.cache, "cache required"),
        store = options.store,
        book = assert(options.book, "book required"),
        catalog = assert(options.catalog, "catalog required"),
        key = assert(options.key, "key required"),
        worker = options.worker,
        client = options.client,
        include_comments = options.include_comments ~= false,
        -- "volume" for new-content books (one shared source-article thread per
        -- volume) and "chapter" for legacy serials. It MUST be carried through
        -- here: callers pass it, and an earlier omission left this nil so a
        -- book_id>0 fixture silently fell into volume scope and read no aid at
        -- all. `nil` keeps the conservative book_id-based fallback.
        comment_scope = options.comment_scope,
        store_namespace = options.store_namespace,
        -- Only true when the caller has verified that the chapters this book will
        -- be missing are LOCKED content it deliberately refused to unlock/purchase.
        -- Any other shortfall must fail the build rather than ship a short EPUB.
        allow_partial = options.allow_partial == true,
        -- 供调用方拿到真正的 worker 请求句柄（暂停/退出要用它）。
        on_request = options.on_request,
    }, self)
end

--- Where the EPUB goes. Into KOReader's library, NOT the plugin data dir.
---
--- weread publishes its merged book into a user-visible library folder
--- (weread/lib/content.lua:325 `book_epub_path` -> `settings.cache_dir`), and
--- keeps every per-chapter artifact in a private dir precisely so that only one
--- file per title exists to be seen. This file used to write to
--- `data_dir/exports` with a comment saying it wanted nothing to land in the
--- library "uninvited" -- which is exactly what left "正在阅读" filling up with
--- one entry per chapter instead of one per book.
function Export:output_dir()
    local dir, ok = self.settings:libraryDir()
    if not ok then
        logger.err("export: library dir unusable:", tostring(dir))
        return nil, "library_dir_unwritable"
    end
    return dir
end

function Export:output_path()
    local title = tostring(self.book.title or "book")
    -- Strip anything a FAT/VFAT mount would choke on, so the file stays usable
    -- if the reader copies it to /mnt/us.
    local safe = title:gsub('[/\\:%*%?"<>|]', "_"):gsub("%.+$", "")
    if safe == "" then
        safe = "book"
    end
    -- Title alone is not unique: two volumes of the same series, or a rerun after
    -- the title was fixed, resolve to one path and the second export silently
    -- overwrites the first -- and the user loses the earlier file with no warning.
    -- The book id (or the cache key, which always carries it) keeps them apart.
    local unique = tostring(self.book.book_id or self.key or "book")
    local dir = self:output_dir()
    if not dir then
        return nil
    end
    return dir .. "/" .. safe .. "_" .. unique .. ".epub"
end

--- Render the comments of one chapter as an XHTML fragment. Option A: appended
--- to the end of its own chapter.
---
--- `complete` decides what the heading claims. The server-reported total is what
--- the website shows, but a cache that stopped after three pages would then be
--- captioned "191 条" above twenty comments -- so an incomplete cache is labelled
--- with what is actually printed plus what is missing.
local function comments_fragment(items, total, complete, image_urls)
    local list = items or {}
    if #list == 0 then
        return ""
    end
    local stored = tonumber(total) or #list
    local heading
    if complete == false and stored > #list then
        heading = string.format("本卷评论（已缓存 %d 条，共 %d 条）", #list, stored)
    else
        heading = string.format("本卷评论（%d 条）", #list)
    end
    local out = {
        '<section class="ln-comments">',
        "<h2>" .. xml_escape(heading) .. "</h2>",
    }
    for _, item in ipairs(list) do
        local meta = {}
        if item.author and item.author ~= "" then
            meta[#meta + 1] = xml_escape(item.author)
        end
        if item.level and item.level ~= "" then
            meta[#meta + 1] = xml_escape(item.level)
        end
        if tonumber(item.likes) and tonumber(item.likes) > 0 then
            meta[#meta + 1] = string.format("赞 %d", tonumber(item.likes))
        end
        if item.time and item.time ~= "" then
            meta[#meta + 1] = xml_escape(item.time)
        end
        out[#out + 1] = '<div class="ln-comment">'
        if #meta > 0 then
            out[#out + 1] = '<div class="ln-meta">' ..
                table.concat(meta, " · ") .. "</div>"
        end
        out[#out + 1] = "<p>" .. safe_comment_html(item.content,
            image_urls) .. "</p>"
        local replies = item.replies_list or {}
        if #replies > 0 then
            out[#out + 1] = '<div class="ln-replies">'
            for _, reply in ipairs(replies) do
                out[#out + 1] = '<div class="ln-comment">'
                out[#out + 1] = '<div class="ln-meta">' ..
                    xml_escape(reply.author or "") .. "</div>"
                out[#out + 1] = "<p>" .. safe_comment_html(reply.content,
                    image_urls) .. "</p>"
                out[#out + 1] = "</div>"
            end
            out[#out + 1] = "</div>"
        end
        out[#out + 1] = "</div>"
    end
    out[#out + 1] = "</section>"
    return table.concat(out, "\n")
end

--- Read the comments of every cached chapter. Runs in the parent because SQLite
--- is only ever touched there (see comment_sync.lua for the reasoning).
function Export:collect_fragments()
    local fragments = {}
    if not self.include_comments then
        return fragments
    end
    -- store is optional: the batch publisher may run without a comment store
    -- (a book cached by an older build has no db yet), and a text-only EPUB is
    -- better than no book at all.
    if not self.store then
        logger.warn("export: no comment store; exporting text only for",
            tostring(self.key))
        return fragments
    end
    local db = self.store.open(self.settings:bookDir(self.key),
        self.store_namespace)
    if not db then
        logger.warn("export: comment store unavailable, exporting text only")
        return fragments
    end
    local is_new_content_book = self.comment_scope == "volume"
        or ((tonumber(self.book.book_id) or 0) > 0 and self.comment_scope ~= "chapter")
    -- Only volume-scoped comments are de-duplicated and placed once; a legacy
    -- chapter thread is emitted after its own chapter.
    local volume_scoped = self.comment_scope == "volume" or (is_new_content_book
        and self.comment_scope ~= "chapter")
    local counted, seen = 0, {}
    local chapters = self.export_chapters or self.catalog.chapters or {}
    -- `run()` has already selected cached and newly fetched public chapters.
    -- Attach each volume thread to the final chapter actually emitted.
    local last_exported_by_volume = {}
    if volume_scoped then
        for index, chapter in ipairs(chapters) do
            local chapter_aid = tonumber(chapter.aid)
            local volume_id = tonumber(chapter.volume_id)
            if chapter_aid and chapter_aid > 0 and volume_id and volume_id > 0 then
                last_exported_by_volume[volume_id] = index
            end
        end
    end
    for index, chapter in ipairs(chapters) do
        local aid
        if is_new_content_book then
            if chapter.comment_mapping_verified == true then
                aid = tonumber(chapter.comment_aid)
            end
        else
            aid = tonumber(chapter.aid)
        end
        -- New-content comments are volume-scoped, legacy comments chapter-scoped.
        -- For a volume, attach the one source-article thread after its last cached
        -- chapter; do not duplicate it after every chapter in the volume.
        local chapter_volume_id = tonumber(chapter.volume_id)
        local volume_last = not volume_scoped
            or (chapter_volume_id and chapter_volume_id > 0
                and last_exported_by_volume[chapter_volume_id] == index)
        -- `aid > 0` matters: a new-content chapter without a mapping may carry
        -- comment_aid = 0 (explicit "no thread"), and 0 is truthy in Lua. Never
        -- let that fall through to a query keyed by the chapter id.
        if aid and aid > 0 and not seen[aid] and volume_last then
            seen[aid] = true
            local state = self.store.get_comments(db, aid)
            if state and #(state.items or {}) > 0 then
                -- Image bytes are intentionally not fetched in this parent-side
                -- SQLite phase. URLs remain in safe XHTML until the EPUB worker
                -- downloads/packages them, keeping the e-ink UI responsive.
                -- EPUBs are opened without the plugin hook on some readers; do
                -- not embed a marker that links to the plugin-only panel. The
                -- section itself contains the comments for offline reading.
                fragments[tonumber(chapter.aid)] = comments_fragment(state.items,
                    state.total, state.complete, self.image_urls)
                counted = counted + 1
            end
        end
    end
    self.store.close(db)
    logger.info("export: comment fragments for", tostring(counted), "chapters")
    return fragments
end

--- Build the EPUB.
--- The archive is written in a worker, so the result arrives asynchronously:
--- `on_done(path, chapters, comment_chapters, reason, worker_result)` on success
--- and `on_done(nil, 0, 0, reason, worker_result)` on failure. When no worker is
--- available the build runs inline and `on_done` fires before this function
--- returns.
---
--- The arity is fixed and `reason` has its own slot rather than doubling as the
--- second argument. Overloading it meant a failure delivered three values while the
--- caller read four, so the worker result landed in the comment-count position and
--- arrived as nil -- which is why a pause could never be told apart from a failure.
--- `worker_result` is the ONLY way to do that: a paused child and a broken one are
--- both `ok = false`, and the reason for a pause is just the string "paused".
local function build_volume_nav(groups)
    local nav, ncx = {}, {}
    local order = 0
    for gi, group in ipairs(groups) do
        if #group.chapters > 0 then
            local title = xml_escape(group.title)
            nav[#nav + 1] = string.format(
                '<li class="ln-volume-entry"><a href="%s">%s</a><ol>%s</ol></li>',
                group.chapters[1].filename, title,
                table.concat(group.nav_children, "\n"))
            order = order + 1
            local volume_order = order
            local children = {}
            for _, child in ipairs(group.chapters) do
                order = order + 1
                children[#children + 1] = string.format(
                    '<navPoint id="np%d" playOrder="%d"><navLabel><text>%s</text>'
                        .. '</navLabel><content src="%s"/></navPoint>',
                    order, order, xml_escape(child.title), child.filename)
            end
            ncx[#ncx + 1] = string.format(
                '<navPoint id="vol%d" playOrder="%d"><navLabel><text>%s</text>'
                    .. '</navLabel><content src="%s"/>%s</navPoint>',
                gi, volume_order, title, group.chapters[1].filename,
                table.concat(children, "\n"))
        end
    end
    return table.concat(nav, "\n"), table.concat(ncx, "\n")
end

function Export:run(on_done)
    self.asset_map = {}
    self.image_urls = {}
    local chapters = {}
    local missing = 0
    -- Split the shortfall. A LOCKED chapter that is not cached is genuinely
    -- unavailable (we refuse to unlock or buy), so a book containing them is
    -- expected to be short and must still publish -- refusing on those would make
    -- every partially-locked book permanently unexportable. A chapter that is NOT
    -- locked yet is missing is different: it is free to obtain, so its absence is a
    -- defect, and shipping it silently is exactly the "this book is missing
    -- chapters" report. Only that second number gates the export.
    local missing_locked, missing_obtainable = 0, 0
    local is_new_content_book = self.comment_scope == "volume"
        or ((tonumber(self.book.book_id) or 0) > 0
            and self.comment_scope ~= "chapter")
    for _index, chapter in ipairs(self.catalog.chapters or {}) do
        if self.cache:is_cached(self.key, chapter.aid) then
            chapters[#chapters + 1] = chapter
        elseif is_new_content_book and self.client
            and (tonumber(chapter.book_id) or tonumber(self.book.book_id) or 0) > 0
            and not chapter.locked
            and (chapter.unlocked == true or (tonumber(chapter.unlocked) or 0) == 1)
            and ((chapter.access_type == "public")
                or chapter.unlocked == true
                or (tonumber(chapter.unlocked) or 0) == 1) then
            -- A refreshed catalogue may contain newly public chapters that have
            -- not yet been cached. Fetch their read-only detail in the build
            -- worker so the exported copy is complete without unlocking coins.
            local copy = {}
            for k, v in pairs(chapter) do copy[k] = v end
            copy._export_fetch = true
            chapters[#chapters + 1] = copy
            missing = missing + 1
        else
            missing = missing + 1
            if chapter.locked then
                missing_locked = missing_locked + 1
            else
                missing_obtainable = missing_obtainable + 1
            end
        end
    end
    if #chapters == 0 then
        local reason = "no_cached_chapters"
        logger.err("export:", reason)
        if on_done then on_done(nil, reason) end
        return false, reason
    end
    -- Defence in depth against a silently short book. The loop above drops every
    -- catalogue chapter that is neither cached nor fetchable-on-demand, and this
    -- function used to only object when NOTHING survived -- so a book that kept 55
    -- of 87 chapters was written into the library and the reader found the gap by
    -- opening it. `missing` was reported, never acted on.
    if missing_obtainable > 0 and not self.allow_partial then
        local reason = string.format("incomplete_book:%d_of_%d", #chapters,
            #(self.catalog.chapters or {}))
        logger.err("export: refusing to publish", reason,
            "-- chapters are missing and the caller did not authorise a partial book")
        if on_done then on_done(nil, reason) end
        return false, reason
    end
    logger.info("export: building EPUB. chapters=", tostring(#chapters),
        "skipped_uncached=", tostring(missing),
        "locked=", tostring(missing_locked),
        "obtainable_but_absent=", tostring(missing_obtainable))

    self.asset_map = {}
    self.image_urls = {}
    self.export_chapters = chapters
    local fragments = self:collect_fragments()
    local fragment_count = 0
    for _key, fragment in pairs(fragments) do
        if fragment and fragment ~= "" then
            fragment_count = fragment_count + 1
        end
    end
    self.asset_map = self.asset_map or {}
    self.image_urls = self.image_urls or {}
    -- Deliberately NOT Cover.resolve(): resolve() returns the 240x360 shelf
    -- thumbnail first because that is what a 90px shelf row wants. An EPUB cover
    -- is opened at full page width on a phone, so the original wins here and the
    -- thumbnail is only the fallback. No usable_file() check either -- the bytes
    -- are validated by image_extension below, which is a stronger test than a
    -- size threshold, and a truncated original is dropped rather than embedded.
    local cover_path = Cover.source_path(self.settings, self.key)
        or Cover.thumb_path(self.settings, self.key)
    local key = self.key
    local cache = self.cache
    local title = tostring(self.book.title or key)
    local author = tostring(self.book.author or "")
    -- Set by the worker task so build() can report progress and honour
    -- cancellation. Nil when the build runs inline (no worker available).
    local build_context = nil

    -- b29：插图预取阶段——全书 URL 先收集、2 个协程并发抓取。
    --
    -- 串行抓一张 ~3s，百张 5 分钟；预取并发后约减半，且 build 期 gsub 回调
    -- 全部命中内存 assets，正文阶段零网络。LuaSocket 的 http.request 是阻塞
    -- 调用，双协程只能交替而非真并行；收益来自两张图的下载时间重叠（一次
    -- ~3s 传输里大部分是网络等待）。每请求前后都有 emit 心跳，worker 的
    -- 120s stale-kill 不会误判（最坏单图 2 候选×2 次×20s=80s < 120s）。
    -- 失败的 URL 不进 assets，交给 build 期回调按原逻辑重试与记数。
    local image_cache_dir = self.settings:bookDir(self.key) .. "/images"
    if self.client and type(self.client.get) == "function" then
        local urls, seen_urls = {}, {}
        for _i, chapter in ipairs(chapters) do
            local body_file = io.open(cache:chapter_path(self.key,
                tonumber(chapter.aid)), "rb")
            local body = body_file and body_file:read("*a") or nil
            if body_file then body_file:close() end
            if type(body) == "string" then
                for source in body:gmatch('<img[^>]-src%s*=%s*"([^"]+)"') do
                    local url = Content.decode_entities(source):gsub("%)$", "")
                    local host = url:match("^https?://([^/:]+)")
                    if host == "api.lightnovel.fun" or host == "static.lightnovel.fun"
                        or host == "res.lightnovel.fun" or host == "www.lightnovel.fun"
                        or host == "lightnovel.fun" or host == "i.noire.cc" then
                        if not seen_urls[url] then
                            seen_urls[url] = true
                            urls[#urls + 1] = url
                        end
                    end
                end
            end
        end
        if #urls > 0 then
            logger.info("export: prefetching images. urls=", tostring(#urls))
            local cursor = 0
            local function prefetch_worker()
                while true do
                    cursor = cursor + 1
                    local url = urls[cursor]
                    if not url then return end
                    local bytes = fetch_image_bytes(self.client, url,
                        image_cache_dir, nil)
                    if bytes and #bytes <= 8 * 1024 * 1024 then
                        local ext = image_extension(bytes)
                        if ext then
                            local n = 0
                            for _k in pairs(self.asset_map) do n = n + 1 end
                            self.asset_map[url] = {
                                name = string.format("inline-%04d%s", n + 1, ext),
                                data = bytes,
                                mime = select(2, image_extension(bytes)),
                            }
                        end
                    end
                    -- 让出执行权给另一个抓取协程；HTTP 阻塞期间另一协程无法
                    -- 运行，但对端下载与本地处理可以重叠，仍快于纯串行。
                    coroutine.yield()
                end
            end
            local threads = { coroutine.create(prefetch_worker),
                coroutine.create(prefetch_worker) }
            local alive = #threads
            while alive > 0 do
                alive = 0
                for _t, co in ipairs(threads) do
                    if coroutine.status(co) == "suspended" then
                        local ok, err = coroutine.resume(co)
                        if not ok then
                            logger.err("export: prefetch worker error",
                                tostring(err))
                        elseif coroutine.status(co) == "suspended" then
                            alive = alive + 1
                        end
                    end
                end
            end
            local n_ok = 0
            for _k in pairs(self.asset_map) do n_ok = n_ok + 1 end
            logger.info("export: prefetch done. assets=", tostring(n_ok),
                "urls=", tostring(#urls))
        end
    end

    local build = function()
        -- No "mimetype" entry here on purpose. write_epub adds it itself, FIRST
        -- and uncompressed, because that is an OCF requirement. The old code had
        -- it in BOTH places, so every exported EPUB carried two mimetype entries
        -- and readers that validate the container reject the duplicate.
        local entries = {
            { name = "META-INF/container.xml", data =
                '<?xml version="1.0" encoding="utf-8"?>'
                .. '<container version="1.0" '
                .. 'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
                .. '<rootfiles><rootfile full-path="OEBPS/content.opf" '
                .. 'media-type="application/oebps-package+xml"/></rootfiles>'
                .. "</container>" },
        }
        local manifest = {
            '<item id="nav" href="nav.xhtml" '
                .. 'media-type="application/xhtml+xml" properties="nav"/>',
            '<item id="toc" href="toc.ncx" '
                .. 'media-type="application/x-dtbncx+xml"/>',
            '<item id="style" href="style.css" media-type="text/css"/>',
        }
        local spine = {}
        local nav_points = {}
        local ncx_points = {}
        local volume_groups = {}
        local current_volume_id = nil
        local cover_embedded = 0

        -- Cover: prefer the small UI thumbnail, fall back to the original.
        local cover_data = nil
        if cover_path then
            local file = io.open(cover_path, "rb")
            if file then
                cover_data = file:read("*a")
                file:close()
            end
        end
        local cover_meta = ""
        if cover_data and #cover_data > 0 then
            local ext, mime = image_extension(cover_data)
            if not ext then
                logger.warn("export: unrecognised cover image, shipping without",
                    "it. bytes=", tostring(#cover_data))
                cover_data = nil
            else
                local href = "images/cover" .. ext
                entries[#entries + 1] = { name = "OEBPS/" .. href,
                    data = cover_data }
                manifest[#manifest + 1] = string.format(
                    '<item id="cover-image" href="%s" media-type="%s" '
                    .. 'properties="cover-image"/>', href, mime)
                manifest[#manifest + 1] =
                    '<item id="cover" href="text/cover.xhtml" '
                    .. 'media-type="application/xhtml+xml"/>'
                spine[#spine + 1] = '<itemref idref="cover"/>'
                entries[#entries + 1] = { name = "OEBPS/text/cover.xhtml",
                    data = '<?xml version="1.0" encoding="utf-8"?>'
                    .. '<!DOCTYPE html><html '
                    .. 'xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN">'
                    .. '<head><title>Cover</title><style>'
                    .. 'html,body{margin:0;padding:0;height:100%;}'
                    .. 'img{display:block;width:100%;height:100%;'
                    .. 'object-fit:contain;}</style></head>'
                    .. '<body><img src="../' .. href .. '" alt="Cover"/></body>'
                    .. "</html>" }
                cover_meta = '\n<meta name="cover" content="cover-image"/>'
                cover_embedded = cover_embedded + 1
            end
        end

        for index, chapter in ipairs(chapters) do
            local volume_id = tonumber(chapter.volume_id) or 0
            local volume_group
            if volume_id > 0 then
                if volume_id ~= current_volume_id then
                    current_volume_id = volume_id
                    volume_group = {
                        volume_id = volume_id,
                        title = BookCatalog.volume_heading(chapter.volume_title),
                        chapters = {},
                        nav_children = {},
                        ncx_children = {},
                        _heading_pending = true,
                    }
                    volume_groups[#volume_groups + 1] = volume_group
                else
                    volume_group = volume_groups[#volume_groups]
                end
            end
            if build_context then
                build_context.checkCancelled()
                build_context.emit{ stage = "chapter", done = index,
                    total = #chapters }
            end
            local aid = tonumber(chapter.aid)
            local chapter_title = tostring(chapter.title or
                ("第 " .. tostring(index) .. " 章"))
            local file = io.open(cache:chapter_path(key, aid), "rb")
            local raw
            if file then
                raw = file:read("*a")
                file:close()
            elseif not chapter._export_fetch then
                logger.warn("export: chapter file vanished mid-build. aid=",
                    tostring(aid))
            end
            if raw or chapter._export_fetch then
                local body = chapter_body(raw)
                if (chapter._export_fetch or (body and body:find("%[res%]ext:")))
                    and self.client and (tonumber(chapter.book_id) or 0) > 0 then
                    local detail_book_id = tonumber(chapter.book_id)
                        or tonumber(self.book.book_id)
                    local detail, detail_err = self.client:fetchChapterDetail(
                        detail_book_id, chapter.aid, { timeout = 60 })
                    local snapshot = detail and detail.body_snapshot
                    if snapshot and type(snapshot.body_html) == "string"
                        and snapshot.body_html:match("<%s*[PpHhIi]") then
                        -- Use refreshed HTML only in this EPUB build. The API
                        -- returns a body fragment, not the full chapter XHTML;
                        -- never overwrite the original chapter cache with it.
                        body = snapshot.body_html
                    else
                        logger.warn("export: detail HTML unavailable; keeping cached body",
                            tostring(chapter.aid), tostring(detail_err))
                    end
                end
                if body then
                    if volume_group and volume_group._heading_pending then
                        body = '<h1 class="ln-volume">'
                            .. xml_escape(volume_group.title) .. "</h1>\n" .. body
                        volume_group._heading_pending = false
                    end
                    local fragment = fragments[aid]
                    if fragment and fragment ~= "" then
                        body = body .. "\n" .. fragment
                    elseif is_new_content_book
                        and chapter.comment_mapping_verified ~= true then
                        -- Do not publish a plugin marker for an unverified new-
                        -- content mapping. It could send readers to an unrelated
                        -- legacy thread or imply comments that cannot be attributed.
                        body = body:gsub(
                            '<p class="ln%-comment%-line">.-</p>', "")
                    end
                    body = body:gsub("%[res%]ext:[%w_%-]+%[/res%]",
                        '<span class="ln-image-placeholder">[插图资源不可用]</span>')
                    -- Single target on purpose: rewrite_image_urls also returns fetch counts, and
                    -- binding those instead left `body` holding the ORIGINAL markup
                    -- with its remote <img src> intact, so every illustration fell
                    -- back to a remote URL that cannot be read offline. The two
                    -- export tests caught exactly that.
                    -- b28: 传入本书插图缓存目录（bookDir/images），重出版免重下。
                    body = rewrite_image_urls(body, self.client,
                        self.asset_map, self.image_urls,
                        function(stage, url)
                            -- Heartbeat around every image request. Without it the
                            -- child can go silent for minutes and the parent reads
                            -- that as a dead worker.
                            if build_context then
                                build_context.emit{ stage = stage, done = index,
                                    total = #chapters, image = url }
                            end
                        end,
                        self.settings:bookDir(self.key) .. "/images")
                    local filename = string.format("text/chapter-%03d.xhtml",
                        index)
                    local id = "chapter_" .. tostring(index)
                    manifest[#manifest + 1] = string.format(
                        '<item id="%s" href="%s" '
                        .. 'media-type="application/xhtml+xml"/>', id, filename)
                    spine[#spine + 1] = '<itemref idref="' .. id .. '"/>'
                    local nav_entry = string.format(
                        '<li><a href="%s">%s</a></li>', filename,
                        xml_escape(chapter_title))
                    local ncx_entry = string.format(
                        '<navPoint id="np%d" playOrder="%d"><navLabel>'
                        .. '<text>%s</text></navLabel><content src="%s"/>'
                        .. "</navPoint>", index, index,
                        xml_escape(chapter_title), filename)
                    if volume_group then
                        volume_group.chapters[#volume_group.chapters + 1] = {
                            filename = filename,
                            title = chapter_title,
                            play_order = index,
                        }
                        volume_group.nav_children[#volume_group.nav_children + 1] = nav_entry
                        volume_group.ncx_children[#volume_group.ncx_children + 1] = ncx_entry
                    else
                        nav_points[#nav_points + 1] = nav_entry
                        ncx_points[#ncx_points + 1] = ncx_entry
                    end
                    entries[#entries + 1] = { name = "OEBPS/" .. filename,
                        data = '<?xml version="1.0" encoding="utf-8"?>'
                        .. '<!DOCTYPE html><html '
                        .. 'xmlns="http://www.w3.org/1999/xhtml" '
                        .. 'xmlns:epub="http://www.idpf.org/2007/ops" '
                        .. 'lang="zh-CN"><head><title>'
                        .. xml_escape(chapter_title)
                        .. "</title><link rel=\"stylesheet\" "
                        .. "type=\"text/css\" href=\"../style.css\"/></head>"
                        .. "<body>\n" .. body .. "\n</body></html>" }
                end
            end
        end
        for url, asset in pairs(self.asset_map) do
            local ext, mime = image_extension(asset.data)
            if ext and mime then
                entries[#entries + 1] = {
                    name = "OEBPS/images/" .. asset.name,
                    data = asset.data,
                }
                manifest[#manifest + 1] = string.format(
                    '<item id="%s" href="images/%s" media-type="%s"/>',
                    asset.name:gsub("[^%w_-]", ""), asset.name, mime)
            end
        end
        local volume_nav, volume_ncx = build_volume_nav(volume_groups)
        local opf = '<?xml version="1.0" encoding="utf-8"?>'
            .. '<package xmlns="http://www.idpf.org/2007/opf" '
            .. 'unique-identifier="bookid" version="3.0" '
            .. 'prefix="dcterms: http://purl.org/dc/terms/">'
            .. '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
            .. '<dc:identifier id="bookid">lightnovel-' .. xml_escape(key)
            .. "</dc:identifier>"
            .. "<dc:title>" .. xml_escape(title) .. "</dc:title>"
            .. "<dc:creator>" .. xml_escape(author) .. "</dc:creator>"
            .. "<dc:publisher>lightnovel.koplugin</dc:publisher>"
            .. "<dc:source>https://www.lightnovel.fun/</dc:source>"
            .. "<dc:language>zh-CN</dc:language>"
            .. '<meta property="dcterms:modified">' .. utc_modified()
            .. "</meta>" .. cover_meta .. "</metadata><manifest>"
            .. table.concat(manifest, "\n") .. "</manifest>"
            .. '<spine toc="toc">' .. table.concat(spine, "\n") .. "</spine>"
            .. "</package>"
        local ncx = '<?xml version="1.0" encoding="utf-8"?>'
            .. '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" '
            .. 'version="2005-1"><head>'
            .. '<meta name="dtb:uid" content="lightnovel-' .. xml_escape(key)
            .. '"/><meta name="dtb:depth" content="'
            .. (#volume_groups > 0 and "2" or "1") .. '"/>'
            .. '<meta name="dtb:totalPageCount" content="0"/>'
            .. '<meta name="dtb:maxPageNumber" content="0"/></head>'
            .. "<docTitle><text>" .. xml_escape(title) .. "</text></docTitle>"
            .. "<navMap>" .. table.concat(ncx_points, "\n")
            .. (#volume_groups > 0 and volume_ncx or "")
            .. "</navMap></ncx>"
        local nav = '<?xml version="1.0" encoding="utf-8"?>'
            .. '<html xmlns="http://www.w3.org/1999/xhtml">'
            .. "<head><title>Navigation</title></head><body>"
            .. '<nav epub:type="toc" xmlns:epub="http://www.idpf.org/2007/ops">'
            .. "<ol>" .. table.concat(nav_points, "\n")
            .. (#volume_groups > 0 and volume_nav or "")
            .. "</ol></nav></body>"
            .. "</html>"

        entries[#entries + 1] = { name = "OEBPS/content.opf", data = opf }
        entries[#entries + 1] = { name = "OEBPS/nav.xhtml", data = nav }
        entries[#entries + 1] = { name = "OEBPS/toc.ncx", data = ncx }
        entries[#entries + 1] = { name = "OEBPS/style.css", data = CSS }

        local path = self:output_path()
        if not path then
            -- Library directory is not writable. Raise with a reason the caller
            -- can show, rather than letting write_epub try to open a nil path.
            error("library_dir_unwritable", 0)
        end
        write_epub(path, entries)
        -- Write the <name>.sdr/metadata.epub.lua sidecar too. Every book in the
        -- reader's library has one; without it KOReader has no title, no author
        -- and no document properties for a file it has never opened, and lists it
        -- by filename alone. Written from the same values that went into the
        -- OPF, so the entry reads correctly before the book is ever opened.
        write_sidecar(path, title, author, entries)
        logger.info("export: wrote", path, "chapters=", tostring(#chapters),
            "comment_chapters=", tostring(cover_embedded))
        return path
    end

    local function finish(path, reason, raw)
        if path then
            if on_done then
                on_done(path, #chapters, fragment_count, nil, raw)
            end
            return true
        end
        logger.err("export failed:", tostring(reason))
        if on_done then
            on_done(nil, 0, 0, tostring(reason or "unknown"), raw)
        end
        return false, reason
    end

    local worker = self.worker
    if not worker or not worker:available() then
        -- No subprocess: build on this thread. Slower on e-ink but correct.
        logger.warn("export: worker unavailable, building on the UI thread")
        local ok, path = pcall(build)
        if not ok then
            return finish(nil, path)
        end
        return finish(path)
    end

    -- Remembered so a failure can say WHERE it got to.
    --
    -- `worker_no_result` on its own is undiagnosable: it means "the child died
    -- without writing a result", which on this device happened for ten minutes
    -- straight while the real cause was a single image request hanging in the
    -- child. The last stage the child reported is the only thing that points at
    -- it, so it is kept and logged instead of thrown away.
    local last_stage = { stage = "start", done = 0, total = #chapters }

    local started, failure = worker:start{
        queue = true,
        -- 读者发起的任务：排队期间不允许被封面/书架刷新这类背景请求挤掉。
        protect = true,
        timeout = 900,
        on_progress = function(state)
            if type(state) == "table" then
                last_stage = {
                    stage = tostring(state.stage or last_stage.stage),
                    done = tonumber(state.done) or last_stage.done,
                    total = tonumber(state.total) or last_stage.total,
                    image = tostring(state.image or last_stage.image or ""),
                    updated_at = os.time(),
                }
            end
        end,
        on_done = function(result)
            if not result or not result.ok then
                logger.err("export failed:", tostring(result and result.error),
                    "last stage=", last_stage.stage, "chapter=",
                    tostring(last_stage.done), "/", tostring(last_stage.total),
                    "image=", tostring(last_stage.image or "none"))
                return finish(nil, (result and result.error) or "worker_failed",
                    result)
            end
            return finish((result.value or {}).path, nil, result)
        end,
        task = function(context)
            context.checkCancelled()
            -- Report progress per chapter. background_worker only refreshes its
            -- `last_progress_at` when a payload arrives, and SIGKILLs the child
            -- when that goes stale for `timeout` seconds. An 83-chapter deflate
            -- build runs well past any fixed budget on a Kindle, so without this
            -- the export was killed and reported "导出失败：worker_timeout" no
            -- matter how healthy it was. Image fetches inside build() emit too --
            -- those are the ones that can sit silent for minutes.
            build_context = context
            return { path = build() }
        end,
    }
    if not started then
        return finish(nil, failure or "cannot_start")
    end
    -- worker:start 的第二个返回值在成功时就是请求句柄。把它交给调用方，否则
    -- 导出期间的"暂停"只能拿上一次（已完成）的缓存请求去暂停，worker 会以
    -- "不是活动任务"静默拒绝。
    if type(self.on_request) == "function" then
        pcall(self.on_request, failure)
    end
    logger.info("export: queued in worker")
    return true
end

--- Publish every already-cached book to the library as one merged EPUB.
---
--- This is the backfill for books downloaded before the merged book existed: they
--- were only ever a pile of chapter HTML under the plugin data dir, invisible to
--- the library. Called with no worker on purpose -- the per-book work is small
--- once chapters are cached, and a batch that needs 80 worker round trips (one at
--- a time, 600s each) would never finish. Sequential, reporting each book as it
--- lands so a failure names the book that failed instead of just "batch failed".
---
--- @param on_book fun(done_index, total, path|nil, reason|nil)
--- @return table summary {ok = n, failed = n, paths = {...}, reasons = {...}}
--- Publish every cached book into the reader's library, one book per pass.
---
--- Runs in the parent, on the UI thread: the library directory and the SQLite
--- comment database are both parent-side, and a child must not write either.
--- That makes it a blocking loop, so pausing means stopping BETWEEN books:
--- `deps.should_continue` is consulted before each one and `deps.start_index`
--- lets the caller come back for the rest later. `summary.stopped_at` is the
--- resume point -- without it a paused batch would redo every book it had
--- already merged, which on a shelf of eighty EPUBs is the difference between a
--- pause being useful and being a trap.
---
--- @treturn table {ok, failed, paths, reasons, stopped_at, processed, total}
function Export:publish_all(deps, on_book)
    deps = deps or {}
    local settings = assert(deps.settings, "settings required")
    local cache = assert(deps.cache, "cache required")
    local store = deps.store
    local client = deps.client
    local should_continue = deps.should_continue
    local start_index = math.max(1, tonumber(deps.start_index) or 1)

    local books = cache:list_cached_books()
    if #books == 0 then
        logger.warn("publish: nothing cached to publish")
        return { ok = 0, failed = 0, paths = {}, reasons = {},
            processed = 0, total = 0, stopped_at = nil }
    end
    logger.info("publish: merging", tostring(#books), "cached books into",
        tostring(settings:libraryDir()), start_index > 1
            and ("resuming at " .. tostring(start_index)) or "")

    local summary = { ok = 0, failed = 0, paths = {}, reasons = {},
        processed = 0, total = #books, stopped_at = nil }
    for index = start_index, #books do
        if type(should_continue) == "function" and not should_continue(index) then
            summary.stopped_at = index
            logger.info("publish: paused before book", tostring(index))
            break
        end
        local entry = books[index]
        local catalog = cache:load_catalog(entry.key)
        if not catalog or type(catalog.chapters) ~= "table"
            or #catalog.chapters == 0 then
            summary.failed = summary.failed + 1
            summary.reasons[#summary.reasons + 1] = entry.key .. ": no catalog"
            logger.warn("publish:", tostring(entry.key),
                "skipped, no usable catalog")
            if on_book then on_book(index, #books, nil, "no_catalog") end
        else
            local exporter = Export:new{
                settings = settings,
                cache = cache,
                store = store,
                client = client,
                store_namespace = tostring(entry.key or ""):match("^bid_%d+$")
                    and "new-content" or nil,
                comment_scope = deps.comment_scope == "auto"
                    and (tostring(entry.key or ""):match("^bid_%d+$")
                        and "volume" or "chapter")
                    or deps.comment_scope,
                key = entry.key,
                book = {
                    title = entry.title or catalog.title or entry.key,
                    author = catalog.author or "",
                    book_id = tonumber(entry.key:match("^bid_(%d+)$")) or 0,
                },
                catalog = catalog,
                -- No worker: inline, one book per pass.
                worker = nil,
            }
            -- run()'s callback is on_done(path, chapters, count) on success and
            -- on_done(nil, reason) on failure, and it fires synchronously when
            -- there is no worker -- so this returns the outcome directly rather
            -- than leaving it pending.
            local result, reason = nil, nil
            local ok = exporter:run(function(path, chapters)
                if path then
                    result = path
                else
                    -- Second argument carries the reason in the failure case.
                    reason = chapters
                end
            end) and true or false
            if ok and result then
                summary.ok = summary.ok + 1
                summary.paths[#summary.paths + 1] = result
                logger.info("publish:", tostring(entry.key), "->", result)
                if on_book then on_book(index, #books, result, nil) end
            else
                summary.failed = summary.failed + 1
                summary.reasons[#summary.reasons + 1] = entry.key .. ": "
                    .. tostring(reason or "unknown")
                logger.err("publish:", tostring(entry.key), "failed:",
                    tostring(reason or "unknown"))
                if on_book then on_book(index, #books, nil, reason or "failed") end
            end
        end
        summary.processed = summary.processed + 1
    end
    logger.info("publish: done ok=", tostring(summary.ok),
        "failed=", tostring(summary.failed))
    return summary
end

return Export