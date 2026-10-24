--[[--
Table of contents for one book.

A "chapter" here is a volume: the site stores each volume as a single article
whose text already contains every chapter inside it, so the list is one row per
volume. Cached volumes are marked so the reader can open them offline.

Plain KOReader Menu, matching fanqie's ShelfMenu and weread's chapter_list_view.
The rows are still MenuItems -- only a cover header is added above them, which is
done by reserving height and inserting a widget into the menu's content group
rather than by replacing the row widget the way library_view.lua does.
--]]--

local _ = require("gettext")
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local BookCatalog = require("lightnovel.lib.book_catalog")

-- No global Screen; weread and fanqie both bind it from the device module.
local Screen = Device.screen

local TocMenu = Menu:extend{
    name = "lightnovel_toc",
    is_doc_only = false,
    is_modal = true,
    covers_fullscreen = true,
    title_bar_fm_style = true,
    -- Back arrow. See TocMenu:onLeftButtonTap.
    title_bar_left_icon = "chevron.left",
}

--- How much of the screen the cover header may take, and its proportions.
--- A light novel cover is roughly 2:3 portrait, so width follows from height.
--- 0.26 leaves room for seven chapter rows on a 600x800 panel: 208px of cover,
--- then 72px rows, which is 712 of the 716px the menu actually has.
local COVER_HEIGHT_RATIO = 0.26
local COVER_ASPECT = 0.70
local COVER_BORDER = 2
local COVER_PADDING = 6

-- Opening a row leads to Cache.book_key and a worker fetch, so the row callback
-- must contain failures: an unwrapped one unwinds through menu.lua's
-- onMenuChoice and stops the reader, which reads to the user as a crash.
local PluginMenu = require("lightnovel.ui.menu")
local logger = require("lightnovel.lib.logger")

--- Build the cover banner that sits above the chapter rows.
--- @return table|nil widget, number height it reserves
function TocMenu.build_cover(path)
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local total_h = math.max(1, math.floor(screen_h * COVER_HEIGHT_RATIO))
    if type(path) ~= "string" or path == "" then
        logger.info("toc: no cover file, header omitted")
        return nil, 0
    end
    -- FrameContainer:getSize() is content + 2*(border) + 2*(padding), and the
    -- layout uses getSize() while paintTo honours width/height, so the reserved
    -- height is derived by subtracting exactly what the frame will add.
    local inner_h = math.max(1, total_h - 2 * COVER_BORDER - 2 * COVER_PADDING)
    local inner_w = math.max(1, math.floor(inner_h * COVER_ASPECT))
    local thumb_image
    local ok, err = pcall(function()
        thumb_image = ImageWidget:new{
            file = path,
            width = inner_w,
            height = inner_h,
            -- 0 means "best fit inside width x height" with the aspect ratio
            -- preserved (imagewidget.lua:320-324).
            scale_factor = 0,
            -- Unlike the shelf rows, this single image lives as long as the
            -- whole catalogue and is repainted on every page turn, so it is
            -- worth holding in KOReader's shared cache.
            file_do_cache = true,
        }
        -- Decode inside the pcall: a failure on first paint would happen during
        -- the paint loop instead, with no way to report it.
        thumb_image:getSize()
    end)
    if not ok or not thumb_image then
        logger.err("toc: cover decode failed", tostring(path), tostring(err))
        if thumb_image and type(thumb_image.free) == "function" then
            pcall(thumb_image.free, thumb_image)
        end
        return nil, 0
    end
    local framed = FrameContainer:new{
        bordersize = COVER_BORDER,
        padding = COVER_PADDING,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            thumb_image,
        },
    }
    local widget = CenterContainer:new{
        dimen = Geom:new{ w = screen_w, h = total_h },
        framed,
    }
    local reserved = widget:getSize().h
    logger.info("toc: cover header built from", path, "height=",
        tostring(reserved))
    return widget, reserved
end

--- Reserve the header's height before the rows are sized.
---
--- Menu divides the whole item area evenly (menu.lua:668-672), so the rows have
--- to be re-divided over what is left. Called from Menu:updateItems, which runs
--- inside init before anything is painted, which is why the widget is passed in
--- through the constructor rather than built afterwards.
function TocMenu:_recalculateDimen(no_recalculate_dimen)
    Menu._recalculateDimen(self, no_recalculate_dimen)
    local cover = self.cover_widget
    if not cover or not self.available_height or not self.perpage then
        return
    end
    local reserved = tonumber(self.cover_reserved) or 0
    if reserved <= 0 then
        return
    end
    -- available_height is only recomputed by the base call and is never mutated
    -- here, so redoing this division on every update is idempotent.
    local room = self.available_height - reserved
    local height = math.max(1, math.floor(room / self.perpage))
    if self.item_dimen and height == self.item_dimen.h then
        return
    end
    self.item_dimen = Geom:new{
        x = 0,
        y = 0,
        w = self.inner_dimen.w,
        h = height,
    }
end

--- Put the cover between the title bar and the chapter rows.
---
--- content_group is VerticalGroup{ title_bar, item_group } (menu.lua:901-905);
--- index 2 is exactly the gap that has to be filled. Done once, because
--- updateItems only resets the group's cached size -- it does not empty it, so
--- a second insert would stack a second cover.
function TocMenu:_mount_cover()
    local cover = self.cover_widget
    if not cover or self._cover_mounted then
        return
    end
    local group = self.content_group
    if not group then
        logger.err("toc: content_group missing, cover header not shown")
        return
    end
    table.insert(group, 2, cover)
    self._cover_mounted = true
    group:resetLayout()
end

function TocMenu:updateItems(select_number, no_recalculate_dimen)
    Menu.updateItems(self, select_number, no_recalculate_dimen)
    self:_mount_cover()
end

function TocMenu:_is_cached(chapter)
    local cache = self.deps.cache
    if not cache or not cache.is_cached then
        return false
    end
    -- The key must come from deps, not from the book. A book opened from the
    -- cached bookshelf has neither `aid` nor `sid` on current_book (it only has
    -- `key`), so this used to build the path ".../books/nil/chapters/<aid>.html",
    -- find nothing, and label EVERY row 未缓存 even though the chapters were
    -- sitting on disk.
    local key = self.deps.key or self.book.key
        or self.book.aid or self.book.sid
    if not key then
        return false
    end
    return cache.is_cached(key, chapter.aid) and true or false
end

function TocMenu.volume_heading_row(title)
    return {
        text = "━━ " .. BookCatalog.volume_heading(title) .. " ━━",
        select_enabled = false,
        -- 卷分隔行加粗，在灰度屏上把卷边界撑清楚。
        bold = true,
    }
end

function TocMenu:_build_items()
    local items = {}
    local chapters = (self.catalog.chapters or {})
    -- How much of the body text is already on disk. Only used to decorate the one
    -- action's label; it used to drive two separate rows here ("缓存整本书" and
    -- "缓存全书评论"), which is the duplication this screen was simplified to
    -- remove. Guarded per chapter because a catalogue that will not stat must not
    -- take the whole list down.
    local total_chapters, cached_chapters = 0, 0
    for row_index, chapter in pairs(self.catalog.chapters or {}) do
        total_chapters = total_chapters + 1
        if self:_is_cached(chapter) then
            cached_chapters = cached_chapters + 1
        end
    end

    -- The one action. Everything the reader used to have to sequence by hand
        -- -- cache the chapters, fetch the comments, build the EPUB, put it in the
        -- library -- is what this row does, and it ends with the book in the
        -- library. Two labels for one button, because the work genuinely differs:
        -- a book already in the library only needs the delta.
        local in_library = false
        if self.deps.in_library then
            local ok, value = pcall(self.deps.in_library)
            in_library = ok and value == true
        end
        -- b30：评论状态常驻行。此前"评论 (x/y 卷)"只在库中书更新的弹窗里
        -- 一闪而过，读者想知道"评论齐了没、还差几卷"只能猜。只对有已验证
        -- 评论卷的新书显示；0 卷可显示或旧书不显示（没有可汇报的状态）。
        local comment_total, comment_stored = 0, 0
        if (tonumber(self.book and self.book.book_id) or 0) > 0 then
            local seen_volumes = {}
            for _i, chapter in ipairs(chapters) do
                local vid = tonumber(chapter.volume_id) or 0
                if chapter.comment_mapping_verified == true
                    and (tonumber(chapter.comment_aid) or 0) > 0
                    and vid > 0 and not seen_volumes[vid] then
                    seen_volumes[vid] = true
                    comment_total = comment_total + 1
                    if self.deps.comment_stored_count then
                        local ok_n, n = pcall(self.deps.comment_stored_count,
                            tonumber(chapter.comment_aid))
                        if ok_n and (tonumber(n) or 0) > 0 then
                            comment_stored = comment_stored + 1
                        end
                    end
                end
            end
        end
        if comment_total > 0 then
            items[#items + 1] = {
                text = comment_stored >= comment_total
                    and string.format(_("评论：全部 %d 卷已入库"), comment_total)
                    or string.format(_("评论：已入库 %d/%d 卷（点「下载入库」补齐）"),
                        comment_stored, comment_total),
                select_enabled = false,
            }
        end
        if self.deps.on_download or self.deps.on_update then
            local download_label = in_library and _("库中书更新") or _("下载入库")
            items[#items + 1] = {
                -- 墨水屏灰度抗锯齿下细笔画观感偏虚，主操作行加粗一档。
                bold = true,
                text_func = function()
                    -- Progress rides along on the label instead of on a row of its
                    -- own, so "how far along is it" is answerable without adding
                    -- anything the reader has to tap.
                    if in_library then return download_label end
                    if cached_chapters > 0 and total_chapters > 0 then
                        return string.format(_("下载入库（已缓存 %d/%d 章）"),
                            cached_chapters, total_chapters)
                    end
                    return download_label
                end,
                callback = PluginMenu.safeCallback(download_label, function()
                    if in_library then
                        if self.deps.on_update then
                            self:onClose()
                            self.deps.on_update()
                        else
                            logger.err("toc: no on_update dep")
                        end
                    elseif self.deps.on_download then
                        self:onClose()
                        self.deps.on_download()
                    else
                        logger.err("toc: no on_download dep")
                    end
                end),
            }
        end
        -- Read the merged whole book. This is the weread rule: the reader's
        -- history records one row per opened FILE (apps/reader/readerui.lua:511),
        -- so the way to get one row per title is to only ever open one file per
        -- title. Chapter rows below still open their own file for per-chapter
        -- navigation, and those are kept out of the history by
        -- main.lua's ReadHistory wrapper. Only offered once there is a file: before
        -- the first 下载入库 there is nothing to open, and offering it sent people
        -- to an error.
        if self.deps.on_open_whole_book and in_library then
            items[#items + 1] = {
                text = _("阅读整本书"),
                callback = PluginMenu.safeCallback(_("阅读整本书"), function()
                    self:onClose()
                    self.deps.on_open_whole_book()
                end),
            }
        end
        if #chapters == 0 then
        items[#items + 1] = { text = _("目录为空"), select_enabled = false }
    end
    -- The loop variable must NOT be named `_`: that is the gettext function
    -- required at the top of this file, and naming the loop variable `_` makes
    -- it a number inside the body, so `_("✓已缓存")` below raised "attempt to
    -- call local '_' (a number value)" and killed the whole catalogue list.
    local is_shelf_book = (tonumber(self.book and self.book.book_id) or 0) > 0
    local previous_volume_id = nil
    for chapter_index, chapter in ipairs(chapters) do
        local target = chapter
        local volume_id = tonumber(target.volume_id) or 0
        if is_shelf_book and volume_id > 0
            and volume_id ~= previous_volume_id then
            local volume_title = target.volume_title
                or (target.volume_id and tostring(target.volume_id))
            items[#items + 1] = TocMenu.volume_heading_row(volume_title)
            previous_volume_id = volume_id
        end
        local label = string.format("%d. %s", target.index or 0,
            tostring(target.title or ""))
        if self:_is_cached(target) then
            label = label .. "  " .. _("✓已缓存")
        end
        items[#items + 1] = {
            text = label,
            callback = PluginMenu.safeCallback(target.title or "", function()
                self:_open(target)
            end),
        }
    end
    return items
end

function TocMenu:_open(chapter)
    if not self.deps.on_open_chapter then
        -- Was a bare `return`, so tapping a chapter row did nothing at all with
        -- nothing in the log: indistinguishable from a dead screen.
        logger.err("toc: no on_open_chapter dep; cannot open",
            tostring((chapter or {}).aid))
        return
    end
    pcall(function() self:onClose() end)
    self.deps.on_open_chapter(chapter)
end

function TocMenu:onLeftButtonTap()
    -- Back, not a menu. This screen's hamburger only ever offered 关闭 -- the
    -- same thing Menu:onClose() does -- so the reader paid a tap for a
    -- one-row dialog. The chapters, the cache rows and the export all live in
    -- the catalogue now, and the two remaining actions (刷新目录 / 缓存整本书)
    -- are rows on this menu itself. Nothing was dropped by making this a
    -- plain back button.
    return self:onClose()
end

--- Long-press still escapes all the way out, for a reader several menus deep.
function TocMenu:onLeftButtonHold()
    return self:onCloseAllMenus()
end

--- Cache every chapter's comment thread for this book.
---
--- NO LONGER REACHABLE FROM THE UI, deliberately. It used to be a row in this
--- screen's title-bar menu; that menu is the back button now, and the work this
--- function does is already inside 下载入库 / 库中书更新 (main.lua:1090-1105
--- queues the same comment sync, then exports the EPUB with those comments in
--- it). Offering it as its own row again would restore exactly the multi-step
--- sequencing this screen was simplified to remove.
---
--- Kept rather than deleted because it is still the only path that caches
--- comments WITHOUT rebuilding the EPUB, which is what a future "refresh
--- comments only" action would want. If you wire it back up, give it a visible
--- row -- do not put it behind the back button.
function TocMenu:onCacheAll()
    local sync = self.deps.sync
    if not sync then
        logger.err("toc: comment sync unavailable; cannot cache comments")
        UIManager:show(InfoMessage:new{ text = _("评论同步不可用") })
        return
    end
    local is_new_content_book =
        (tonumber(self.book and self.book.book_id) or 0) > 0
    local aids, seen = {}, {}
    for _i, chapter in ipairs(self.catalog.chapters or {}) do
        -- Keep the two ID spaces apart: a new-content book is keyed by the
        -- volume source article, a legacy serial by the chapter aid. Never let a
        -- missing mapping fall back to the other space.
        local aid
        if is_new_content_book then
            aid = chapter.comment_mapping_verified == true
                and tonumber(chapter.comment_aid) or nil
        else
            aid = tonumber(chapter.aid)
        end
        if aid and aid > 0 and not seen[aid] then
            seen[aid] = true
            aids[#aids + 1] = aid
        end
    end
    if #aids == 0 then
        logger.warn("toc: catalog has no chapters; nothing to cache")
        UIManager:show(InfoMessage:new{ text = _("没有可缓存的章节") })
        return
    end
    local started, err = sync:queue_background(aids)
    if not started then
        UIManager:show(InfoMessage:new{
            text = _("无法启动后台缓存：") .. tostring(err or "unknown"),
        })
    else
        UIManager:show(InfoMessage:new{
            text = string.format(_("已开始缓存 %d 章（后台）"), #aids),
        })
    end
end

--- Entry point mirroring fanqie's ShelfView.show(opts).
function TocMenu.show(opts)
    opts = opts or {}
    logger.info("TocMenu.show: catalog type=",
        type(opts.catalog), "chapters=",
        tostring(type(opts.catalog) == "table"
            and #(opts.catalog.chapters or {}) or -1),
        "title=", tostring(opts.title))
    -- Built before the menu exists: _recalculateDimen runs inside Menu:init and
    -- has to know how much height the header takes before it divides the rest
    -- over the chapter rows.
    local cover, reserved = TocMenu.build_cover(opts.cover_path)
    local menu = TocMenu:new{
        title = opts.title or _("目录"),
        item_table = {},
        -- The header eats vertical space, so a page holds fewer chapters while
        -- it is there. 83 chapters over 12 pages instead of 9 is the trade for
        -- seeing which book is open.
        items_per_page = opts.items_per_page or (cover and 7 or 10),
        is_borderless = true,
        catalog = opts.catalog or {},
        book = opts.book or {},
        cover_widget = cover,
        cover_reserved = reserved,
        deps = opts.deps or {},
    }
    local items = menu:_build_items()
    logger.info("TocMenu.show: built rows=", tostring(#(items or {})))
    menu.item_table = items
    -- Required. KOReader recalculates page dimensions and repaints from
    -- updateItems(); assigning item_table alone leaves the menu painted empty,
    -- which is exactly the "no items" screen that was reported even though the
    -- log showed 83 rows built. LibraryMenu:_refresh() already worked this
    -- way, and fanqie's ShelfView goes further and passes item_table straight
    -- into the constructor.
    menu:updateItems()
    UIManager:show(menu)
    -- Screenshot is supplied by the optional standalone Screenshot Tool adapter;
    -- TOC rendering itself never depends on that plugin being installed.
    if menu.deps and type(menu.deps.snapshot) == "function" then
        pcall(menu.deps.snapshot, "toc_shown", 3)
    end
    return menu
end

return TocMenu