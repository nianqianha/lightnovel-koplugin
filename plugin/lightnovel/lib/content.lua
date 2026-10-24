--[[--
Chapter content pipeline for the lightnovel plugin.

Responsibilities:
  * turn the API's plain-text `content` into a crengine-renderable XHTML file
  * append a tappable comment marker whose count matches the cached comments
  * write every artifact atomically (.part.<time>.<seq> then rename)

Chapter text verified on the live API is plain text with bare image URLs and no
BBCode markup, so cleaning is limited to entity handling and paragraphing. The
marker is an <a> with an internal anchor so KOReader's onGotoLink can raise the
popup without any JavaScript.
--]]--

local logger = require("lightnovel.lib.logger")

local Content = {}

local write_seq = 0

local function write_atomic(path, data)
    write_seq = write_seq + 1
    local tmp = string.format("%s.part.%d.%d", path, os.time(), write_seq)
    local file, err = io.open(tmp, "wb")
    if not file then
        return nil, err
    end
    local ok, write_err = file:write(data)
    file:close()
    if not ok then
        os.remove(tmp)
        return nil, write_err
    end
    -- POSIX rename() replaces the destination atomically, which is what we want
    -- on the device. Some platforms (Windows, used by the desktop test run)
    -- refuse to overwrite, so fall back to unlink-then-rename there.
    local renamed, rename_err = os.rename(tmp, path)
    if not renamed then
        os.remove(path)
        renamed, rename_err = os.rename(tmp, path)
    end
    if not renamed then
        os.remove(tmp)
        return nil, rename_err or "rename failed"
    end
    return true
end
Content.write_atomic = write_atomic

local function xml_escape(value)
    local text = tostring(value or "")
    text = text:gsub("&", "&amp;")
    text = text:gsub("<", "&lt;")
    text = text:gsub(">", "&gt;")
    text = text:gsub('"', "&quot;")
    return text
end
Content.xml_escape = xml_escape

--- Decode the small set of HTML entities the site emits.
local ENTITIES = {
    lt = "<", gt = ">", amp = "&", quot = '"', apos = "'",
    nbsp = " ", ldquo = "\226\128\156", rdquo = "\226\128\157",
    lsquo = "\226\128\152", rsquo = "\226\128\153",
    hellip = "\226\128\166", mdash = "\226\128\148", ndash = "\226\128\147",
}

--- Encode a Unicode code point as UTF-8 across the full range, so a stray
--- numeric entity is never silently dropped.
local function utf8_char(code)
    if code < 0 or code > 0x10FFFF then
        return ""
    end
    if code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(
            0xC0 + math.floor(code / 0x40),
            0x80 + code % 0x40)
    elseif code < 0x10000 then
        return string.char(
            0xE0 + math.floor(code / 0x1000),
            0x80 + math.floor(code / 0x40) % 0x40,
            0x80 + code % 0x40)
    end
    return string.char(
        0xF0 + math.floor(code / 0x40000),
        0x80 + math.floor(code / 0x1000) % 0x40,
        0x80 + math.floor(code / 0x40) % 0x40,
        0x80 + code % 0x40)
end
Content.utf8_char = utf8_char

function Content.decode_entities(text)
    if type(text) ~= "string" then return "" end
    return (text:gsub("&(#?%w+);", function(name)
        if name:sub(1, 1) == "#" then
            local digits = name:sub(2)
            local code
            if digits:match("^[xX]") then
                code = tonumber(digits:sub(2), 16)
            else
                code = tonumber(digits)
            end
            if not code then
                return "&" .. name .. ";"
            end
            return utf8_char(code)
        end
        return ENTITIES[name:lower()] or ("&" .. name .. ";")
    end))
end

--- Convert comment markup to readable plain text for the compact menu panel.
--- Keep line breaks and make image/sticker loss explicit instead of silently
--- stripping the entire tag (the EPUB path embeds the actual image bytes).
function Content.comment_image_urls(value)
    local source = Content.decode_entities(Content.decode_entities(
        tostring(value or "")))
    local urls, seen = {}, {}
    local function add(url)
        url = Content.decode_entities(url or ""):gsub("%)$", "")
        local host = url:match("^https?://([^/]+)") or ""
        host = host:match("^[^:]+") or host
        local trusted = host == "static.lightnovel.fun"
            or host == "api.lightnovel.fun" or host == "res.lightnovel.fun"
            or host == "www.lightnovel.fun" or host == "i.noire.cc"
        local opaque_image_suffix = host == "i.noire.cc"
            and url:gsub("[%?#].*$", ""):match("%.i$") ~= nil
        if trusted and (Content.is_image_url(url) or opaque_image_suffix)
            and not seen[url] then
            seen[url] = true
            urls[#urls + 1] = url
        end
    end
    for tag in source:gmatch("<img[^>]*>") do
        add(tag:match('[sS][rR][cC]%s*=%s*"([^"]+)"')
            or tag:match("[sS][rR][cC]%s*=%s*'([^']+)'") )
    end
    for url in source:gmatch("%[img[^%]]*%](.-)%[/img%]") do
        add(url)
    end
    return urls
end

function Content.comment_plain_text(value)
    local text = Content.decode_entities(Content.decode_entities(
        tostring(value or "")))
    text = text:gsub("<br%s*/?>", "\n")
    text = text:gsub("<img[^>]*>", " [图片/表情] ")
    text = text:gsub("%[img[^%]]*%].-%[/img%]", " [图片/表情] ")
    text = text:gsub("<[A-Za-z/][^>]*>", "")
    text = text:gsub("%[/?[a-zA-Z][^%]]*%]", "")
    return text
end

--- The site prefixes most bodies with its own table of contents. It duplicates
--- the reader TOC, so it is dropped.
-- 目 = U+76EE = E7 9B AE
local TOC_HEAD = "^\231\158\190"

local function strip_leading_toc(text)
    local body = text:gsub("^\239\187\191", "")
    body = body:gsub("^\r\n", "")
    if not body:match(TOC_HEAD) then
        return body
    end
    -- Strip the "目录" block up to the first blank line, but only when the block
    -- carries no sentence punctuation; otherwise it is prose that happens to
    -- start with the word.
    local toc_end = body:find("\n%s*\n")
    if not toc_end then
        return body
    end
    local head = body:sub(1, toc_end)
    for _, stop in ipairs({ "。", "！", "？", "；" }) do
        if head:find(stop, 1, true) then
            return body
        end
    end
    return (body:sub(toc_end + 1):gsub("^\n+", ""))
end

local IMAGE_EXT = {
    jpg = true, jpeg = true, png = true, gif = true,
    webp = true, bmp = true,
}

--- True when a URL path ends in a known image extension. Query strings are
--- ignored so "?m=..&t=.." style cache busting does not defeat the test.
local function is_image_url(url)
    local path = url:gsub("[%?#].*$", "")
    local ext = path:match("%.([%a]+)$")
    if not ext then return false end
    return IMAGE_EXT[ext:lower()] == true
end
Content.is_image_url = is_image_url

--- Sentinel used to carry a URL out of a gsub without re-escaping it.
local IMG_MARK = "\1img\1"

--- Convert plain text into paragraph HTML, turning bare image URLs into <img>.
function Content.text_to_html(text)
    local body = strip_leading_toc(Content.decode_entities(text or ""))
    body = body:gsub("\r\n", "\n"):gsub("\r", "\n")

    local out = {}
    for block in body:gmatch("([^\n]+)") do
        block = block:gsub("^%s+", ""):gsub("%s+$", "")
        if block ~= "" then
            local marked = block:gsub("(https?://[^%s<>]+)", function(url)
                if is_image_url(url) then
                    return IMG_MARK .. url .. IMG_MARK
                end
                return url
            end)
            local segments = {}
            local pos = 1
            while true do
                local s, e, cap = marked:find(IMG_MARK .. "(.-)" .. IMG_MARK, pos)
                if not s then
                    segments[#segments + 1] = { text = marked:sub(pos) }
                    break
                end
                if s > pos then
                    segments[#segments + 1] = { text = marked:sub(pos, s - 1) }
                end
                segments[#segments + 1] = { image = cap }
                pos = e + 1
            end
            local rendered = {}
            for _, seg in ipairs(segments) do
                if seg.image then
                    rendered[#rendered + 1] = string.format(
                        '<img src="%s" alt=""/>', xml_escape(seg.image))
                elseif seg.text:match("%S") then
                    rendered[#rendered + 1] = xml_escape(seg.text)
                end
            end
            if #rendered > 0 then
                out[#out + 1] = "<p>" .. table.concat(rendered, " ") .. "</p>"
            end
        end
    end
    return table.concat(out, "\n")
end

--- Render the paragraph array returned by
--- /api/new-content-read/get-chapter-paragraphs.
---
--- Deliberately NOT xml_escape()d, unlike text_to_html(): these rows already
--- carry inline markup. Verified live 2026-10-02, chapter 191395 paragraph 2 is
---   paragraph_text = '白河<ruby>月愛<rt>Luna</rt></ruby>是全年級首屈一指的美少女。'
--- so escaping would print the tags instead of rendering the furigana. Only
--- bare image URLs and hard newlines are transformed here; everything else is
--- passed through untouched.
---
--- @treturn string HTML, one <p> per paragraph
function Content.paragraphs_to_html(paragraphs, resources)
    resources = resources or {}
    local out = {}
    for _, row in ipairs(paragraphs or {}) do
        local text = row.paragraph_text
        if type(text) ~= "string" then
            text = tostring(text or "")
        end
        text = Content.decode_entities(text)
        text = text:gsub("%[res%]ext:([%w_%-]+)%[/res%]", function(key)
            local item = resources[key]
            local url = type(item) == "table"
                and (item.url or item.src or item.res_url) or item
            if type(url) == "string" and url:match("^https?://") then
                return IMG_MARK .. url .. IMG_MARK
            end
            logger.warn("content: unresolved resource placeholder", key)
            return ""
        end)
        text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
        text = text:gsub("^%s+", ""):gsub("%s+$", "")
        if text ~= "" then
            -- A bare URL becomes an <img>; an already-marked one is left alone
            -- because IMG_MARK would itself be raw markup we cannot escape.
            local marked = text:gsub("(https?://[^%s<>]+)", function(url)
                if is_image_url(url) then
                    return IMG_MARK .. url .. IMG_MARK
                end
                return url
            end)
            local segments = {}
            local pos = 1
            while true do
                local s, e, cap = marked:find(IMG_MARK .. "(.-)" .. IMG_MARK, pos)
                if not s then
                    segments[#segments + 1] = { text = marked:sub(pos) }
                    break
                end
                if s > pos then
                    segments[#segments + 1] = { text = marked:sub(pos, s - 1) }
                end
                segments[#segments + 1] = { image = cap }
                pos = e + 1
            end
            local rendered = {}
            for _, seg in ipairs(segments) do
                if seg.image then
                    rendered[#rendered + 1] = string.format(
                        '<img src="%s" alt=""/>', xml_escape(seg.image))
                elseif seg.text:match("%S") then
                    -- Hard newlines inside one logical paragraph become <br/>.
                    rendered[#rendered + 1] = seg.text:gsub("\n", "<br/>")
                end
            end
            if #rendered > 0 then
                -- first_line_indent 0 marks headings such as "序章"; the
                -- stylesheet indents every other paragraph by 2em already.
                local cls = ""
                if tonumber(row.first_line_indent) == 0 then
                    cls = ' class="ln-no-indent"'
                end
                out[#out + 1] = "<p" .. cls .. ">"
                    .. table.concat(rendered, " ") .. "</p>"
            end
        end
    end
    return table.concat(out, "\n")
end

--- Normalize the resource URL map from the server's chapter-detail response.
--- The public web client reads legacy_resources.res_info and supports snake/camel
--- case fields; mirror that wire contract here rather than assuming a pre-normalized
--- `legacy_resource` object that this Lua client does not create.
function Content.resource_map(detail)
    if type(detail) ~= "table" then return {} end
    local legacy = detail.legacy_resources or detail.legacyResources
        or detail.legacy_resource or detail.legacyResource
    if type(legacy) ~= "table" then return {} end
    local info = legacy.res_info or legacy.resInfo
    if type(info) ~= "table" then return {} end
    local out = {}
    for key, value in pairs(info) do
        if type(value) == "table" then
            local resource_key = tostring(value.res_key or value.resKey or key)
            local url = value.url or value.src or value.res_url or value.resUrl
            if type(url) == "string" and url:match("^https?://") then
                out[resource_key] = { url = url }
            end
        elseif type(value) == "string" and value:match("^https?://") then
            out[tostring(key)] = { url = value }
        end
    end
    return out
end

--- Resolve `[res]ext:<key>[/res]` tokens using the normalized URL map.
--- Unknown tokens are removed rather than exposed as literal markup.
function Content.resolve_resources(text, resources)
    if type(text) ~= "string" then return "" end
    resources = resources or {}
    return (text:gsub("%[res%]ext:([%w_%-]+)%[/res%]", function(key)
        local item = resources[key]
        local url = type(item) == "table"
            and (item.url or item.src or item.res_url) or item
        if type(url) == "string" and url:match("^https?://") then
            return url
        end
        return ""
    end))
end

--- Convert a batch body_text snapshot to XHTML, resolving any legacy image
--- tokens from its detail/resource map. Unknown tokens remain readable notices.
function Content.body_text_html(body_text, detail)
    local resources = Content.resource_map(detail)
    local text = tostring(body_text or "")
    text = text:gsub("%[res%]ext:([%w_%-]+)%[/res%]", function(key)
        local item = resources[key]
        local url = type(item) == "table"
            and (item.url or item.src or item.res_url) or item
        if type(url) == "string" and url:match("^https?://") then
            return url
        end
        logger.warn("content: unresolved body resource", key)
        return "[插图暂不可用]"
    end)
    return Content.text_to_html(text)
end

--- Prefer the server's rendered XHTML when available: it has already resolved
--- opaque [res]ext tokens to concrete image URLs. The paragraphs endpoint is a
--- selection/text representation and may contain those tokens verbatim.
function Content.chapter_body_html(detail, paragraphs)
    local snapshot = type(detail) == "table" and detail.body_snapshot or nil
    if type(snapshot) == "table" then
        local html = snapshot.body_html
        if type(html) == "string" and html:match("<%s*[PpHhIi]") then
            local resources = Content.resource_map(detail)
            return (html:gsub("%[res%]ext:([%w_%-]+)%[/res%]", function(key)
                local item = resources[key]
                local url = type(item) == "table"
                    and (item.url or item.src or item.res_url) or item
                if type(url) == "string" and url:match("^https?://") then
                    return '<img src="' .. xml_escape(url) .. '" alt=""/>'
                end
                logger.warn("content: unresolved rendered resource", key)
                return '<span class="ln-image-placeholder">[插图暂不可用]</span>'
            end))
        end
        local body_text = snapshot.body_text
        if type(body_text) == "string" and body_text:gsub("%s", "") ~= "" then
            return Content.body_text_html(body_text, detail)
        end
    end
    local resources = Content.resource_map(detail)
    return Content.paragraphs_to_html(paragraphs, resources)
end

-- NOTE: crengine ignores CSS `pointer-events` for link hit-testing, so the
-- comment link must stay a real <a href> and be intercepted in Lua. Styling
-- here is purely visual.
local CHAPTER_CSS = [[
body { margin: 0; padding: 0; }
p { text-indent: 2em; margin: 0 0 0.35em 0; line-height: 1.5; }
p.ln-no-indent { text-indent: 0; }
img { display: block; margin: 0.6em auto; max-width: 100%; height: auto; }
a.ln-comment {
  font-size: 0.68em;
  vertical-align: super;
  text-decoration: underline;
  margin-left: 2px;
  color: inherit;
}
p.ln-comment-line { text-indent: 0; margin-top: 1.2em; }
]]

--- Anchor href prefix. The reader hook recognises links starting with this and
--- resolves the numeric aid that follows.
Content.ANCHOR_PREFIX = "#lncomment-"

--- Id of the in-document anchor for one article.
function Content.comment_anchor_id(aid)
    return "lncomment-anchor-" .. tostring(aid)
end

--- Build the full XHTML document for one cached chapter.
-- @string title chapter/volume title
-- @string body_html already-rendered paragraphs
-- @integer comment_count comments currently cached for this chapter
-- @number aid article id, used to build the comment link target
function Content.build_chapter_xhtml(title, body_html, comment_count, aid)
    aid = tonumber(aid) or 0
    local marker = ""
    if tonumber(comment_count) and comment_count > 0 and aid > 0 then
        -- href points at a real in-document anchor so crengine keeps the link
        -- alive; reader_hooks intercepts the tap and opens the panel rather than
        -- letting KOReader scroll down to the anchor.
        marker = string.format(
            '\n<p class="ln-comment-line">' ..
            '<a class="ln-comment" id="ln-comment-marker" href="%s">[%d 条评论]</a></p>',
            Content.ANCHOR_PREFIX .. tostring(aid), tonumber(comment_count))
    end
    return table.concat({
        '<?xml version="1.0" encoding="utf-8"?>',
        '<!DOCTYPE html>',
        '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh-CN">',
        "<head>",
        '<meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>',
        "<title>" .. xml_escape(title) .. "</title>",
        "<style>" .. CHAPTER_CSS .. "</style>",
        "</head>",
        "<body>",
        '<h1 class="ln-title">' .. xml_escape(title) .. "</h1>",
        body_html or "",
        marker,
        -- Anchor target, intentionally empty. The panel is rendered by the
        -- plugin rather than baked into the document, so a cached chapter stays
        -- small and refreshing comments never invalidates the crengine layout.
        string.format('<p id="%s"></p>', Content.comment_anchor_id(aid)),
        "</body>",
        "</html>",
    }, "\n")
end

--- Marker id used to detect a cached chapter that shows a comment link.
function Content.has_comment_marker(path)
    local file = io.open(path, "rb")
    if not file then return false end
    local data = file:read("*a") or ""
    file:close()
    return data:find('id="ln-comment-marker"', 1, true) ~= nil
end

--- Extract the article id encoded in a comment link href.
-- Returns nil when the href is not one of ours.
function Content.aid_from_href(href)
    if type(href) ~= "string" then return nil end
    if href:sub(1, #Content.ANCHOR_PREFIX) ~= Content.ANCHOR_PREFIX then
        return nil
    end
    return tonumber(href:sub(#Content.ANCHOR_PREFIX + 1))
end

--- Rewrite a cached chapter so the marker matches the store.
-- Handles both directions: a chapter cached with no comments gains a marker
-- after the first sync, and a marker is removed when the store empties.
-- @string path chapter file
-- @integer comment_count current cached count
-- @number aid article id, required when adding a marker
function Content.rewrite_marker(path, comment_count, aid)
    local file = io.open(path, "rb")
    if not file then return false, "unreadable" end
    local data = file:read("*a") or ""
    file:close()

    local count = tonumber(comment_count) or 0
    local target = tonumber(aid) or 0
    local anchor = string.format('<p id="%s"></p>',
        Content.comment_anchor_id(target))

    local function marker_html()
        return string.format(
            '<p class="ln-comment-line">' ..
            '<a class="ln-comment" id="ln-comment-marker" href="%s">[%d 条评论]</a></p>',
            Content.ANCHOR_PREFIX .. tostring(target), count)
    end

    local has_marker = data:find('id="ln-comment-marker"', 1, true) ~= nil
    local replaced, n

    if count > 0 and target > 0 then
        if has_marker then
            replaced, n = data:gsub(
                '<p class="ln%-comment%-line">.-</p>', marker_html(), 1)
        else
            -- Insert immediately before the anchor target so the link sits at the
            -- very end of the prose.
            if data:find(anchor, 1, true) then
                replaced, n = data:gsub(anchor:gsub("([^%w])", "%%%1"),
                    marker_html() .. anchor, 1)
            else
                replaced, n = data:gsub("</body>",
                    marker_html() .. "\n" .. anchor .. "</body>", 1)
            end
        end
    else
        if not has_marker then
            return false, "unchanged"
        end
        replaced, n = data:gsub('<p class="ln%-comment%-line">.-</p>', "", 1)
    end

    if n == 0 then
        return false, "marker_not_found"
    end
    if replaced == data then
        return false, "unchanged"
    end
    return write_atomic(path, replaced)
end

return Content
