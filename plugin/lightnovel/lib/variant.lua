--[[--
简体 ⇄ 繁体字形转换（b59）。

**为什么需要**：轻之国度的书是楼主自己排的，有的卷是台湾版繁体原文，有的卷是
大陆简体录入——同一本书里两种混着（实测《游戏人生》第 3 卷某章繁=8607/简=17，
其它章反过来）。站点阅读器有简/繁开关，插件此前没有，读者只能看原文。

**数据来源**：OpenCC（Apache-2.0）的 STCharacters / TSCharacters / STPhrases /
TSPhrases，生成脚本见 `05_补丁与其他/部署脚本/gen_variant_data.py`。生成时做了两件事：
  1. 去掉"字级转换结果和词组结果一样"的词条——它们不提供额外信息；
  2. 只保留长度 ≤3 的词条（更长的在散文里极少见，字级已经够用）。
结果从 4.9 万条压到 4 千条，整个数据模块 127 KB。

**能到什么水平**：繁→简基本无损（TSCharacters 是一对多之外的确定映射，词组再补 158 条）；
简→繁做不到 100%，`发/髮`、`面/麵`、`后/後` 这类要靠 4113 条词组兜住常见写法，
生僻组合仍可能错字——所以默认关闭，由读者自己开。

**性能**：只在 `text.variant` 不是"原文"时才跑，且只在章节生成（下载/重出）时跑一次；
140 KB 的章节约 10 万字符，逐字一次表查询。
--]]--

local logger = require("lightnovel.lib.logger")

local Variant = {}

--- 设置值 → 转换方向。raw 表示不改。
Variant.MODES = { raw = true, s2t = true, t2s = true }

local DIRECTION = {
    simp = "t2s",
    trad = "s2t",
}

local loaded   -- 数据模块（只 require 一次）
local prepared = {}  -- 方向 → { chars, phrases, initials, maxlen }

local function parse_pairs(text)
    local map = {}
    if type(text) ~= "string" then
        return map
    end
    for line in text:gmatch("[^\r\n]+") do
        local key, value = line:match("^([^\t]+)\t(.+)$")
        if key then
            map[key] = value
        end
    end
    return map
end

--- 数一个 UTF-8 串有多少个字（只用来算词条长度上限，调用频率很低）。
local function char_count(s)
    local n = 0
    for _ in s:gmatch("[\1-\127\194-\244][\128-\191]*") do
        n = n + 1
    end
    return n
end

local function load_data()
    if loaded ~= nil then
        return loaded
    end
    local ok, mod = pcall(require, "lightnovel.data.variant_data")
    if not ok or type(mod) ~= "table" then
        logger.err("variant: data module unavailable:", tostring(mod))
        loaded = false
        return false
    end
    loaded = mod
    return loaded
end

--- 取某个方向的查表结构，第一次使用时解析。解析失败返回 nil（调用方原样返回文本）。
local function tables_for(mode)
    if prepared[mode] then
        return prepared[mode]
    end
    local data = load_data()
    if not data then
        return nil
    end
    local chars_key, phrases_key
    if mode == "s2t" then
        chars_key, phrases_key = "s2c", "s2p"
    else
        chars_key, phrases_key = "t2c", "t2p"
    end
    local phrases = parse_pairs(data[phrases_key])
    -- 只有首字出现在词条里时才值得去试着匹配词组，省掉绝大多数无用查找。
    local initials, maxlen = {}, 1
    for key in pairs(phrases) do
        local first = key:match("^[\1-\127\194-\244][\128-\191]*")
        if first then
            initials[first] = true
        end
        local n = char_count(key)
        if n > maxlen then
            maxlen = n
        end
    end
    local t = {
        chars = parse_pairs(data[chars_key]),
        phrases = phrases,
        initials = initials,
        maxlen = maxlen,
    }
    prepared[mode] = t
    return t
end

--- 每个 UTF-8 字符的起始字节位置，末尾补一个 #s+1 方便切片。
local function char_starts(s)
    local starts, i, n = {}, 1, #s
    while i <= n do
        starts[#starts + 1] = i
        local b = s:byte(i)
        if b >= 0xF0 then
            i = i + 4
        elseif b >= 0xE0 then
            i = i + 3
        elseif b >= 0xC0 then
            i = i + 2
        else
            i = i + 1
        end
    end
    starts[#starts + 1] = n + 1
    return starts
end

--- 按设置项的值转换。
---
--- @param text 字符串（纯文本或已经渲染好的 HTML 都行：标签名和属性值都是 ASCII，
---             转换表里没有，原样通过）
--- @param mode "s2t" | "t2s" | "raw" | nil
--- @treturn string 转换后的文本；mode 不是转换方向时**原样返回同一个字符串**
function Variant.convert(text, mode)
    mode = DIRECTION[mode] or mode
    if not Variant.MODES[mode] or mode == "raw" then
        return text
    end
    if type(text) ~= "string" or text == "" then
        return text
    end
    local t = tables_for(mode)
    if not t then
        return text
    end

    local starts = char_starts(text)
    local total = #starts - 1
    local out = {}
    local k = 1
    while k <= total do
        local head = text:sub(starts[k], starts[k + 1] - 1)
        local phrase
        if t.initials[head] then
            local longest = math.min(t.maxlen, total - k + 1)
            for len = longest, 2, -1 do
                local value = t.phrases[text:sub(starts[k], starts[k + len] - 1)]
                if value then
                    phrase = value
                    k = k + len
                    break
                end
            end
        end
        if phrase then
            out[#out + 1] = phrase
        else
            out[#out + 1] = t.chars[head] or head
            k = k + 1
        end
    end
    return table.concat(out)
end

--- 设置值是否合法（菜单里循环时用）。
function Variant.is_mode(mode)
    return Variant.MODES[mode] == true
end

return Variant
