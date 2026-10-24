--[[--
Catalog resolution for the lightnovel plugin.

The site is organised as: category -> series (sid) -> volumes (aid).
Each volume is a single article whose `content` already contains every chapter
of that volume inline, so a "chapter" in this plugin is a volume, and the
chapter headings inside it are not separately addressable.

Verified endpoint behaviour (2026-09-30):
  * /api/series/get-article-list {sid}  -> ALL volumes of the series.
    /api/series/get-info {sid} returns only one entry in `articles`, so it
    must not be used as the catalog.
  * Every numeric id may arrive as a string ("1441774") in listing responses
    and as a number in detail responses, so ids are always coerced.
--]]--

local logger = require("lightnovel.lib.logger")

local Catalog = {}

--- Coerce an API id to a number, tolerating string ids.
local function num(value)
    local n = tonumber(value)
    if n then return n end
    return nil
end
Catalog.num = num

--- Normalise one entry of the volume list into a flat chapter record.
-- @return table|nil {index, aid, title, cover}
function Catalog.normalize_volume(entry, index)
    if type(entry) ~= "table" then
        return nil
    end
    local aid = num(entry.aid)
    if not aid then
        return nil
    end
    local title = tostring(entry.title or entry.name or ("第 " .. tostring(index) .. " 卷"))
    -- Strip a leading "第N卷" style marker from the display title only if the
    -- remainder still carries information; otherwise keep it verbatim.
    return {
        index = tonumber(index) or 1,
        aid = aid,
        sid = num(entry.sid),
        title = title,
        cover = tostring(entry.cover or ""),
        comments = tonumber(entry.comments) or 0,
    }
end

--- Build the flat chapter list for a series.
-- @param volumes raw data.list from /api/series/get-article-list
-- @return table array of normalized chapters, plus a skipped count
function Catalog.from_volumes(volumes)
    local chapters = {}
    local skipped = 0
    if type(volumes) ~= "table" then
        return chapters, skipped, "empty_response"
    end
    for _, entry in ipairs(volumes) do
        local volume = Catalog.normalize_volume(entry, #chapters + 1)
        if volume then
            chapters[#chapters + 1] = volume
        else
            skipped = skipped + 1
        end
    end
    if #chapters == 0 then
        return chapters, skipped, "no_valid_volumes"
    end
    return chapters, skipped
end

-- Exact live-verified cross-family mappings. Keyed by new-content book_id and
-- volume_id; the mapped value must also equal source_article_id from the API.
-- These entries were verified against legacy article title/body and comment
-- samples, not merely by coincidental numeric IDs or counts.
local VERIFIED_SHELF_COMMENT_AIDS = {
    [3177] = {
        [6802] = 1089155, [6817] = 1089288, [6804] = 1103799,
        [6805] = 1113183, [6807] = 1117208, [6808] = 1126580,
        [6812] = 1129793, [6815] = 1134549,
    },
    [1338] = {
        -- Volumes 1-4 added 2026-10-12 after the SAME live verification as the
        -- original five: /api/discuss/get-topic page_info.count matched the
        -- shelf's volume_comment_count exactly (779/729/402/453) AND every
        -- sampled comment discusses this book ("老八啊😭", "佳门伟大", vol-4
        -- romance complaints). Their absence from the original whitelist was a
        -- repair gap, not policy: the 10-07 fix verified only the back half of
        -- the book, silently dropping 2363 comments from volumes 1-4.
        [36754] = 1083748, [36747] = 1094751, [36749] = 1117792,
        [36748] = 1121562,
        [36750] = 1130115, [36752] = 1135203, [36753] = 1139876,
        [36756] = 1143056, [36757] = 1136433,
    },
    -- 《雨森润奈的湿度很高》: all three comment-bearing volumes verified live
    -- 2026-10-12. For each, /api/discuss/get-topic{aid} answered page_info.count
    -- exactly equal to the shelf's volume_comment_count (119/122/64) AND the
    -- comment bodies discuss this book (rain-soaked atmosphere, waiting for a
    -- third volume), which is the same content-level confirmation the other
    -- entries went through. Volumes with no comment thread are not listed:
    -- an absent row is the fail-closed default, not an oversight.
    [16484] = {
        [15469] = 1139061, [15462] = 1140926, [15466] = 1143992,
    },
    -- 《桌游咖（玩乐关系/玩玩的戀愛關係）》: 第 3 卷 verified live 2026-10-23.
    -- /api/article/get-detail{aid=1143317} answers code 0 with the title
    -- "第3卷【已完本含实体特典】", byte-identical to this volume's title in the
    -- shelf catalogue, and /api/discuss/get-topic reports 193 comments whose
    -- character names (月乃 302 / 小鸟游 247 occurrences) fill the cached body of
    -- that very volume.
    --
    -- 第2卷特典 (candidate 1142253) is deliberately NOT listed: its legacy
    -- article answers code 5001 (gone), so the title cannot be compared, and its
    -- 7 comments quote a sentence that does not occur anywhere in the cached
    -- 特典 text. Fail-closed: no entry, those 7 comments stay out rather than risk
    -- attaching another work's thread. Volumes with source_article_id = 0
    -- (1~2卷, 第4卷) have no candidate at all.
    [31607] = {
        [9919] = 1143317,
    },
    -- 《义妹生活》: verified live 2026-10-24 (bid_5143, 重置版合卷书). For
    -- volumes 3/4, /api/discuss/get-topic page_info.count matched the shelf's
    -- volume_comment_count exactly (273/273 and 166/166) and the comment bodies
    -- discuss this book. The other four candidate volumes (16347/1588/11075/
    -- 20096, legacy aids 1083785/1120401/1123784/1127284) are deliberately NOT
    -- listed: the new-content shelf declares 0 comments for them while their
    -- legacy articles carry 60/180/324/287 comments from the old forum threads
    -- -- a count mismatch means the site itself no longer attributes those
    -- threads to these repackaged volumes. Fail-closed: no entry.
    [5143] = {
        [10141] = 1099421, [10144] = 1100523,
    },
}

--- Resolve a new-content volume's legacy comment aid only for an exact mapping
--- verified against title/body/comment content. Unknown or changed records fail
--- closed; count mismatches do not invalidate a content-verified identity.
function Catalog.shelf_comment_aid(book_id, volume)
    if type(volume) ~= "table" then
        return 0
    end
    local book = tonumber(book_id or volume.book_id) or 0
    local volume_id = tonumber(volume.volume_id) or 0
    local expected = (VERIFIED_SHELF_COMMENT_AIDS[book] or {})[volume_id]
    local source = tonumber(volume.source_article_id or volume.comment_candidate_aid)
    if expected and source == expected then
        return expected
    end
    return 0
end

function Catalog.is_shelf_comment_mapping_verified(book_id, volume)
    return Catalog.shelf_comment_aid(book_id, volume) > 0
end

--- Full comment mapping: candidate aid, verified flag, resolved aid.
---
--- The whitelist is the human-verified fast path. Since b21 the plugin ALSO
--- verifies mappings live at download time: a volume thread whose
--- page_info.count exactly equals the shelf's volume_comment_count gets marked
--- comment_mapping_verified directly on its catalogue rows (the same standard
--- as every manual whitelist entry: 16484/1338/31607/5143). Those persisted
--- entries must survive every whitelist-only recompute, or each run would
--- un-verify them and hammer the API again. A runtime entry stays valid only
--- while its stored aid still equals the current candidate aid; if the site
--- changes source_article_id the entry drops back to unverified and the live
--- check runs again. Returns (candidate, verified, aid).
function Catalog.shelf_comment_mapping(book_id, volume)
    if type(volume) ~= "table" then
        return 0, false, 0
    end
    local candidate = Catalog.shelf_comment_candidate(volume) or 0
    local aid = Catalog.shelf_comment_aid(book_id, volume)
    if aid > 0 then
        return candidate, true, aid
    end
    aid = tonumber(volume.comment_aid) or 0
    if aid > 0 and volume.comment_mapping_verified == true
        and aid == candidate then
        return candidate, true, aid
    end
    return candidate, false, 0
end

--- Human-readable volume heading shared by the plugin TOC and EPUB navigation.
function Catalog.volume_heading(title)
    local value = tostring(title or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local number = value:match("^(%d+%.?%d*)")
    if number then
        local rest = value:sub(#number + 1):gsub("^%s*卷?%s*", "")
        local label = "第" .. number .. "卷"
        if rest ~= "" and not rest:match("^%[.*%]$") then
            return label .. " · " .. rest
        end
        return label
    end
    return value ~= "" and value or "未分类卷"
end

--- Preserve the explicit candidate for diagnostics without enabling it.
function Catalog.shelf_comment_candidate(volume)
    if type(volume) ~= "table" then
        return 0
    end
    local aid = tonumber(volume.source_article_id)
    if aid and aid > 0 then return aid end
    return 0
end

--- Group a flat chapter list by the series name embedded in volume titles.
-- The site repeats the series title inside each volume title
-- (e.g. "第四卷：追忆的彼方"), so a common prefix can be factored out and used
-- as a group heading. Falls back to a single unnamed group.
function Catalog.group_by_series(chapters)
    local groups = {}
    local index = {}
    for _, chapter in ipairs(chapters or {}) do
        local key = chapter.title
        local group = index[key]
        if not group then
            group = { title = key, chapters = {} }
            index[key] = group
            groups[#groups + 1] = group
        end
        group.chapters[#group.chapters + 1] = chapter
    end
    return groups
end

--- Fetch and build the catalog for a series. Must run inside a worker.
function Catalog.fetch(client, sid)
    local volumes, err = client:fetchVolumes(sid, { timeout = 30 })
    if not volumes then
        return nil, err or "volumes_unavailable"
    end
    local chapters, skipped, build_err = Catalog.from_volumes(volumes)
    if build_err then
        logger.warn("catalog build failed:", "sid=", tostring(sid),
            "error=", tostring(build_err))
    end
    return {
        sid = num(sid),
        chapters = chapters,
        groups = Catalog.group_by_series(chapters),
        skipped = skipped,
    }, nil
end

--- Find a chapter record by its article id.
function Catalog.find_by_aid(catalog, aid)
    local target = num(aid)
    if not catalog or not target then
        return nil
    end
    for _, chapter in ipairs(catalog.chapters or {}) do
        if chapter.aid == target then
            return chapter
        end
    end
    return nil
end

return Catalog
