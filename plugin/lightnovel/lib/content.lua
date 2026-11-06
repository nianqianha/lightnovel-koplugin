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
local Variant = require("lightnovel.lib.variant")

local Content = {}

--- 下载/重出时要转成哪种字形："raw"（原文，默认）/ "simp"（简体）/ "trad"（繁体）。
---
--- 由 main 在插件 init 时按设置写入，设置项切换后立即改这个字段。放在模块上而不是
--- 逐层传参：渲染入口有 text_to_html / paragraphs_to_html / chapter_body_html 三条，
--- 传参会把签名改得到处都是，而这是个全局语义。
Content.variant_mode = "raw"

--- 按当前设置转换字形。mode 为 raw 时**原样返回同一个字符串**（零开销）。
local function to_variant(text)
    local mode = Content.variant_mode
    if not mode or mode == "raw" then
        return text
    end
    return Variant.convert(text, mode)
end
Content.to_variant = to_variant

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

--- 站点正文里混着 BBCode：`[justify]…[/justify]`、`[b]`、`[color=#fff]`…
---
--- 2026-10-26 读者截图实测：整段正文前面挂着字面的 "[justify]"，正文里还夹着
--- `[justify] [/justify]` 这种空行标记。原因是**只有** comment_plain_text 会去标记，
--- 正文的两条路径（text_to_html / paragraphs_to_html）都没有，于是原样进了章节
--- XHTML 和 EPUB。
---
--- 这里只做"去标记、留内容"：调用方的输出随后要逐段 xml_escape，塞真 HTML 进去
--- 会被转义成可见文本。所以 [b]/[i] 这类只丢弃标记（丢失粗斜体是可接受的代价），
--- 只有真正的换行类标记（[br]/[p]/[hr]）换成换行符，避免把两段黏成一段。
--- 未知的方括号保持原样——正文里本来就有 `[注]` 这类合法方括号，不能一律删。
local BBCODE_DROP = {
    justify = true, center = true, left = true, right = true, align = true,
    b = true, i = true, u = true, s = true, del = true, strike = true,
    em = true, strong = true, color = true, backcolor = true, size = true,
    font = true, highlight = true, quote = true, code = true, spoiler = true,
    indent = true, sup = true, sub = true, url = true, email = true,
    list = true, li = true, table = true, tr = true, td = true, th = true,
}
local BBCODE_BREAK = { br = true, p = true, hr = true }

function Content.strip_bbcode(text)
    local out = tostring(text or "")
    -- 图片先摘出来：把 [img]URL[/img] 还原成裸 URL，交给调用方既有的图片识别。
    out = out:gsub("%[img[^%]]*%]%s*(.-)%s*%[/img%]", " %1 ")
    out = out:gsub("%[/?([A-Za-z][%w_]*)[^%]]*%]", function(name)
        local n = name:lower()
        if BBCODE_BREAK[n] then return "\n" end
        if BBCODE_DROP[n] then return "" end
        return nil -- 未知标记原样保留
    end)
    -- Markdown 链接的处理放在下面（它要用到 is_image_url，必须定义在后者之后），
    -- 所以这里通过模块表间接调用，避免 Lua 的前向引用被静默当成 nil 全局。
    if Content.strip_markdown_links then
        out = Content.strip_markdown_links(out)
    end
    return out
end

function Content.comment_plain_text(value)
    local text = Content.decode_entities(Content.decode_entities(
        tostring(value or "")))
    text = text:gsub("<br%s*/?>", "\n")
    text = text:gsub("<img[^>]*>", " [图片/表情] ")
    text = text:gsub("%[img[^%]]*%].-%[/img%]", " [图片/表情] ")
    text = text:gsub("<[A-Za-z/][^>]*>", "")
    -- 评论里也会出现 Markdown 链接。必须放在下面这条"删 [xxx] 标记"之前，
    -- 否则方括号先被吃掉，只剩一截赤裸的 "(https://…)"。
    if Content.strip_markdown_links then
        text = Content.strip_markdown_links(text)
    end
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

--- 站点正文里另有一类脏东西：**Markdown 链接**，而且常是**缺收尾括号**的残形。
---
--- 2026-10-31 实测（book 31165《游戏人生》第 3 卷 chapter 313886）服务端下发的
--- HTML 原文：
---   <p>[\_三校\_]NO GAME NO LIFE游戏人生3\_简繁\_.rar](https://api.lightnovel.fun/
---   …/214350gfjmvvccdx4c09u4.rar?m=…&t=…</p>
--- 注意 ")" **不存在**。站点自己的渲染器也因此没把它识别成链接，原样当正文下发；
--- 读者在 Kindle 上看到的就是一长条 URL 铺在页面上（2026-10-31 截图）。
---
--- 规则：
---   * `[文字](地址)` → 只留"文字"（地址在 Kindle 上既不可点也不可达）；
---   * 地址是压缩包/文档附件 → **整条删掉**：剩下的只有文件名，读者打不开，
---     而且紧挨着就是书名行，留着纯噪音；
---   * `![说明](图片地址)` 且确实是图片 → 还原成裸 URL，交给既有的图片识别；
---   * `\[` `\]` 这类 Markdown 转义还原成 `[` `]`；
---   * 收尾的 ")" 允许缺失（站点数据里本来就是缺的），地址在空白/换行/`<` 处截断，
---     绝不会把后面的 `</p>` 一起吃掉。
local MD_ATTACHMENT_EXT = {
    rar = true, zip = true, ["7z"] = true, tar = true, gz = true, bz2 = true,
    txt = true, doc = true, docx = true, pdf = true, epub = true,
    mobi = true, azw3 = true, torrent = true,
}

local function is_attachment_url(url)
    local path = url:gsub("[%?#].*$", "")
    local ext = path:match("%.([%w]+)$")
    return ext ~= nil and MD_ATTACHMENT_EXT[ext:lower()] == true
end

local function md_unescape(label)
    return (label:gsub("\\([%[%]%(%)%*_`#!~%-])", "%1"))
end

local function strip_markdown_links(text)
    local s = tostring(text or "")
    -- 绝大多数段落连一个 "](" 都没有，先便宜地短路掉。
    if not s:find("]%(", 1) and not s:find("!%[", 1) then
        return s
    end
    local out, i, n = {}, 1, #s
    while i <= n do
        local c = s:sub(i, i)
        local is_image = c == "!" and s:sub(i + 1, i + 1) == "["
        local open = is_image and (i + 1) or i
        if s:sub(open, open) == "[" then
            -- 找配对的 "]"：跳过 \[ \] 转义，不跨行。
            local j, close = open + 1, nil
            while j <= n do
                local d = s:sub(j, j)
                if d == "\\" then
                    j = j + 2
                elseif d == "\n" then
                    break
                elseif d == "]" then
                    close = j
                    break
                else
                    j = j + 1
                end
            end
            if close and s:sub(close + 1, close + 1) == "(" then
                -- 地址可能缺收尾 ")"，在空白/换行/引号/尖括号处截断。
                local k = close + 2
                while k <= n do
                    local d = s:sub(k, k)
                    if d == ")" or d == "\n" or d == "<" or d == ">"
                        or d == '"' or d == "'" or d == " " or d == "\t" then
                        break
                    end
                    k = k + 1
                end
                local url = s:sub(close + 2, k - 1)
                if url:match("^https?://") or url:match("^//") then
                    local emit
                    if is_attachment_url(url) then
                        emit = ""
                    elseif is_image then
                        emit = is_image_url(url) and (" " .. url .. " ") or ""
                    else
                        emit = md_unescape(s:sub(open + 1, close - 1))
                    end
                    out[#out + 1] = emit
                    i = (s:sub(k, k) == ")") and (k + 1) or k
                else
                    out[#out + 1] = c
                    i = i + 1
                end
            else
                out[#out + 1] = c
                i = i + 1
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

Content.strip_markdown_links = strip_markdown_links

--- 清理之后仍然"看起来像标记"的签名。
---
--- 为什么要有这个：2026-10-26、10-29、10-31 读者连着拍了三次屏——BBCode、
--- `<img>` 半截标签、Markdown 链接。每次都是在 `strip_bbcode` 里再补一条黑名单，
--- 黑名单天然会漏下一种写法，于是同一个位置反复出问题。
---
--- 这里做的是**反向检查**：清洗完的正文里只要还看得见这些签名，就说明又漏了，
--- 直接写日志报警（带章节号与样例），不必等读者把屏幕拍下来。
---
--- 只扫标签之外的文字。判定必须严格，否则日志会被误报淹掉——
--- 2026-10-31 全量跑 82 章时，最初的"方括号里是字母就算 BBCode"把《密室》[IV]、[VI]
--- 这类卷标全报了；所以这里只认 BBCODE_DROP/BBCODE_BREAK 里的真标签名。
local HTML_TAG_NAMES = {
    img = true, br = true, p = true, div = true, span = true, em = true,
    strong = true, a = true, ruby = true, rt = true, table = true, tr = true,
    td = true, b = true, i = true, u = true,
}

local RESIDUE_SIGNATURES = {
    { kind = "md-link", pattern = "%]%s*%(" },
    { kind = "md-escape", pattern = "\\[%[%]]" },
    { kind = "res-token", pattern = "%[res%]" },
    { kind = "img-attr", pattern = "img%-width%s*=" },
    -- b55 那次事故：图片抓取失败时只删掉 `<img src="…"`，剩下的
    -- `style="max-width:100%;height:auto;" />` 被当正文渲染。属性片段本身
    -- 没有 `img-` 前缀，所以单独认「标识符="…"」这种只在标签里才成立的写法。
    { kind = "attr-fragment", pattern = "[%a][%w%-]*%s*=%s*\"" },
    { kind = "upload-url", pattern = "upload%-files" },
}

--- 只在文字里出现「真标签名」的方括号标记才算 BBCode 残留。
local function scan_bbcode(text)
    local n, sample = 0, nil
    for name in text:gmatch("%[/?([A-Za-z][%w_]*)%s*[=%]]") do
        local lower = name:lower()
        if BBCODE_DROP[lower] or BBCODE_BREAK[lower] then
            n = n + 1
            sample = sample or ("[" .. name .. "]")
            if n >= 500 then break end
        end
    end
    return n, sample
end

--- 正文里出现 `&lt;img …&gt;` 这种"整条标签被当文字显示"的情况才算残留。
--- 必须带收尾的 `&gt;`：译名/算式里的 `a&lt;b` 是正常的 `<`，报出来就是噪音。
local function scan_escaped_tag(text)
    local n, sample = 0, nil
    for name in text:gmatch("&lt;%s*/?%s*([A-Za-z][%w]*)[^&<]-&gt;") do
        if HTML_TAG_NAMES[name:lower()] then
            n = n + 1
            sample = sample or ("<" .. name .. ">")
            if n >= 500 then break end
        end
    end
    return n, sample
end

--- 去掉站点混进"纯文本"里的 HTML 包装标签。
---
--- 只认 HTML_TAG_NAMES 里的名字，正文里 `a<b` 之类的算式不会被误删。
--- `<img src>` 换成裸 URL 再交给 text_to_html 走既有插图识别——直接删掉会丢图。
--- 块级标签留一个换行，避免两段黏成一段。
local WRAPPER_BLOCK = { br = true, p = true, hr = true, div = true }

function Content.strip_wrapper_tags(text)
    local out = tostring(text or "")
    out = out:gsub("<%s*[Bb][Rr]%s*/?%s*>", "\n")
    out = out:gsub("(<%s*[Ii][Mm][Gg]%s[^>]*>)", function(tag)
        local src = tag:match('[Ss][Rr][Cc]%s*=%s*"([^"]+)"')
            or tag:match("[Ss][Rr][Cc]%s*=%s*'([^']+)'")
        if src then return " " .. src .. " " end
        return ""
    end)
    out = out:gsub("<%s*/?%s*([A-Za-z][%w]*)[^>]*>", function(name)
        local lower = name:lower()
        if WRAPPER_BLOCK[lower] then return "\n" end
        if HTML_TAG_NAMES[lower] then return "" end
        return nil -- 不认识的不动，交给 scan_residue 报警
    end)
    return out
end

--- 统计渲染结果里残留的标记签名。
--- @treturn table { total = <次数>, hits = { {kind=…, count=…, sample=…}, … } }
function Content.scan_residue(html)
    local text = tostring(html or "")
    text = text:gsub("<[^>]->", " ")
    local hits, total = {}, 0
    local function add(kind, n, sample)
        if n and n > 0 then
            total = total + n
            hits[#hits + 1] = { kind = kind, count = n, sample = sample }
        end
    end
    for _, sig in ipairs(RESIDUE_SIGNATURES) do
        local n, sample = 0, nil
        for found in text:gmatch(sig.pattern) do
            n = n + 1
            sample = sample or found
            if n >= 500 then break end
        end
        add(sig.kind, n, sample)
    end
    add("bbcode", scan_bbcode(text))
    add("html-tag-as-text", scan_escaped_tag(text))
    return { total = total, hits = hits }
end

--- Sentinel used to carry a URL out of a gsub without re-escaping it.
local IMG_MARK = "\1img\1"

--- Convert plain text into paragraph HTML, turning bare image URLs into <img>.
function Content.text_to_html(text)
    -- 先解码实体再转字形：转换表里全是汉字，实体是 ASCII，先后无所谓，
    -- 但必须在 xml_escape 之前，否则实体化后的字符表对不上。
    local body = strip_leading_toc(Content.strip_bbcode(
        Content.decode_entities(to_variant(text or ""))))
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
        text = Content.strip_bbcode(Content.decode_entities(to_variant(text)))
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
    -- `body_text` 名义上是纯文本，实测会夹着站点的包装标签：book 5143 的
    -- 第 5&6 卷有 252 处 `<span style="color:#424242">…</span>`。这些标签
    -- 一路走到 xml_escape 就变成正文里可见的 `<span style="color:#424242">`，
    -- 和 BBCode / `<img>` 残片是同一类事故，所以在进 XML 之前先摘掉。
    text = Content.strip_wrapper_tags(text)
    -- 剩下解不出的 `[res]…[/res]` 是站点自己的占位符（实测形如 `[res]0,257517[/res]`，
    -- 该章 `legacy_resources.res_info` 为空，没有 URL 可还原）。留着就会原样显示，
    -- 按"未知标记不得上屏"一并清掉；少一张图好过正文里多一行乱码。
    local dropped = 0
    text = text:gsub("%[res%].-%[/res%]", function()
        dropped = dropped + 1
        return ""
    end)
    if dropped > 0 then
        logger.dbg("content: dropped unresolved res tokens ", dropped)
    end
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
            -- 服务端渲染的 HTML 里也见过 BBCode 混排，同一套去皮先跑一遍；
            -- 输出进的是 XML，不能把标记留给 crengine 当正文。
            html = Content.strip_bbcode(to_variant(html))
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

--- 从站点的阅读页 HTML 里取出正文段落（b60）。
---
--- 页面结构：`<section class="…reader-body">` → `<div class="reader-text">`，里面全是 `<p>`。
--- 不能直接搜 `"<p"`：SVG 图标里有 `<path>`，`<p[^>]*>` 会把整个图标吞掉。必须看
--- `<p` 后面紧跟的是空格还是 `>`，再按 `</p>` 收尾。
---
--- 返回 nil 的三种情况都会让调用方退回本地转换表：
---   no_reader_text —— 页面结构变了（站点改版）
---   truncated      —— `reader-text` 这块没有闭合，多半是长章节传到一半断了
---   no_paragraphs  —— 结构对但没有段落
---
--- @treturn string|nil 段落 HTML（`<p>…</p>` 换行连接）
--- @treturn string|nil 失败原因
function Content.reader_page_html(html)
    local s = tostring(html or "")
    -- 不要求 class 恰好以引号收尾：站点可能给它再加状态类
    -- （同一页的 section 就出现过 class="…reader-body"），只认前缀更稳。
    local open = s:find('<div class="reader-text', 1, true)
    if not open then
        return nil, "no_reader_text"
    end
    -- 配平 div：确认这一块收口了。长章节在慢网络上经常读到一半就断。
    local i, depth, close = open, 0, nil
    while true do
        local o = s:find("<div", i, true)
        local c = s:find("</div>", i, true)
        if not c then
            break
        end
        if o and o < c then
            depth = depth + 1
            i = o + 4
        else
            depth = depth - 1
            i = c + 6
            if depth == 0 then
                close = i - 1
                break
            end
        end
    end
    if not close then
        return nil, "truncated"
    end

    local seg = s:sub(open, close)
    local out, pos = {}, 1
    while true do
        local p = seg:find("<p", pos, true)
        if not p then
            break
        end
        local after = seg:sub(p + 2, p + 2)
        if after == ">" or after == " " or after == "\n"
            or after == "\t" or after == "\r" then
            local gt = seg:find(">", p + 2, true)
            local cl = gt and seg:find("</p>", gt + 1, true)
            if gt and cl then
                local inner = seg:sub(gt + 1, cl - 1)
                -- 站点给每个节点挂着 data-v-xxxx 作用域属性，进 EPUB 没有意义
                inner = inner:gsub('%s+data%-v%-[%w]+%s*=%s*"[^"]*"', "")
                inner = inner:gsub("^%s+", ""):gsub("%s+$", "")
                if inner ~= "" then
                    out[#out + 1] = "<p>" .. inner .. "</p>"
                end
                pos = cl + 4
            else
                pos = p + 2
            end
        else
            pos = p + 2
        end
    end
    if #out == 0 then
        return nil, "no_paragraphs"
    end
    return table.concat(out, "\n")
end

--- 记录这一章的字形是从哪来的，好在日志与完成弹窗里说清楚（b60）。
Content.variant_stats = { server = 0, local_table = 0 }

function Content.note_variant_source(kind)
    local stats = Content.variant_stats
    if kind == "server" then
        stats.server = stats.server + 1
    elseif kind == "local" then
        stats.local_table = stats.local_table + 1
    end
end

function Content.reset_variant_stats()
    Content.variant_stats = { server = 0, local_table = 0 }
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
    -- 标题也按同一字形走，否则设成繁体后正文是繁体、章名还是原文。
    if type(title) == "string" then
        title = to_variant(title)
    end
    -- 所有章节 XHTML 都从这里出去（单章、批量、下载、重出四条路径），
    -- 残留检查放这里才能保证"一次覆盖全部出口"。
    local scan = Content.scan_residue(body_html)
    if scan.total > 0 then
        for _, hit in ipairs(scan.hits) do
            logger.warn("content residue: kind=", hit.kind,
                "count=", hit.count, "chapter=", tostring(aid),
                "sample=", tostring(hit.sample):sub(1, 60))
        end
    end
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
