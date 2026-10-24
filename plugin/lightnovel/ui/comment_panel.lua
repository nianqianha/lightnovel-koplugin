--[[--
Comment panel for the lightnovel plugin.

Opened by tapping the "[N 条评论]" link in a chapter; reader_hooks intercepts
that tap and calls `CommentPanel.show(aid, title, deps)`.

Reads cached rows from SQLite, so it opens instantly and works with no network.
"刷新" re-fetches through the background worker.

Plain KOReader Menu (same widget fanqie's ShelfMenu and weread's
chapter_list_view use) instead of a hand-built ScrollHtmlWidget page: the
hand-built version re-laid out on every paint and stalled the e-ink screen.
--]]--

local _ = require("gettext")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local logger = require("lightnovel.lib.logger")
local Content = require("lightnovel.lib.content")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local lfs = require("libs/libkoreader-lfs")
local Digest = require("lightnovel.lib.digest")
local Screen = Device.screen

local CommentMenu = Menu:extend{
    name = "lightnovel_comment_panel",
    is_doc_only = false,
    is_modal = true,
    covers_fullscreen = true,
    title_bar_fm_style = true,
    -- Back arrow, matching the other screens. 刷新评论 / 缓存全书评论 used to
    -- live behind this icon in a ButtonDialog; they are rows at the top of the
    -- list now, so the icon is free to do what the reader expects of it.
    title_bar_left_icon = "chevron.left",
}

--- A tappable action row at the top of the comment list.
---
--- The comment rows themselves are deliberately select_enabled = false (they
--- are text to read, not choices), so they are drawn by CommentTextRow /
--- CommentImageRow. These rows ARE choices and must therefore go through
--- Menu:onMenuSelect -- which is what CommentTextRow:onTapSelect already
--- forwards to -- so they are built as plain item_table entries with a `kind`
--- this menu recognises.
local CommentActionRow = InputContainer:extend{
    entry = nil,
    menu = nil,
    dimen = nil,
}

function CommentActionRow:init()
    self.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
    -- CenterContainer, not a bare TextWidget: TextWidget's height is its own
    -- content height, so inside a full-row FrameContainer it would sit flush
    -- against the top border. The comment rows can use TextBoxWidget with an
    -- explicit height (it fills the box), but a one-line action label needs the
    -- centering container to look like a row.
    self[1] = FrameContainer:new{
        dimen = self.dimen:copy(),
        padding = Size.padding.small,
        margin = 0,
        bordersize = Size.border.thin,
        background = Blitbuffer.COLOR_GRAY_3,
        CenterContainer:new{
            dimen = Geom:new{
                w = self.dimen.w - 2 * Size.padding.small,
                h = self.dimen.h - 2 * Size.padding.small,
            },
            TextWidget:new{
                text = tostring(self.entry.text or ""),
                face = Font:getFace("cfont", 16),
                bold = true,
                max_width = self.dimen.w - 2 * Size.padding.small,
            },
        },
    }
end

function CommentActionRow:onTapSelect()
    if self.menu and self.entry and self.entry.callback then
        self.entry.callback()
    end
    return true
end

local CommentTextRow = InputContainer:extend{
    entry = nil,
    menu = nil,
    dimen = nil,
}

function CommentTextRow:init()
    self.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
    self[1] = FrameContainer:new{
        dimen = self.dimen:copy(),
        padding = Size.padding.small,
        margin = 0,
        bordersize = Size.border.thin,
        background = Blitbuffer.COLOR_WHITE,
        TextBoxWidget:new{
            text = tostring(self.entry.text or ""),
            face = Font:getFace("cfont", 16),
            width = self.dimen.w - 2 * Size.padding.small,
            height = self.dimen.h - 2 * Size.padding.small,
            height_adjust = true,
        },
    }
end

function CommentTextRow:onTapSelect()
    if self.menu and self.entry then
        self.menu:onMenuSelect(self.entry)
    end
    return true
end

local CommentImageRow = InputContainer:extend{
    entry = nil,
    menu = nil,
    dimen = nil,
}

function CommentImageRow:init()
    self.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
    local max_side = Screen:scaleBySize(48)
    local row = HorizontalGroup:new{ align = "center" }
    for image_index, path in ipairs(self.entry.image_paths or {}) do
        local image
        local ok, err = pcall(function()
            image = ImageWidget:new{
                file = path, width = max_side, height = max_side,
                scale_factor = 0, file_do_cache = false,
            }
            image:getSize()
        end)
        if ok and image then
            table.insert(row, image)
            if image_index < #(self.entry.image_paths or {}) then
                table.insert(row, HorizontalSpan:new{ width = Size.padding.small })
            end
        elseif image and type(image.free) == "function" then
            pcall(image.free, image)
            logger.warn("comment image row decode failed", tostring(path), tostring(err))
        end
    end
    if (tonumber(self.entry.missing_count) or 0) > 0 then
        table.insert(row, TextWidget:new{
            text = _("还有图片/表情不可用；轻触重试"),
            face = Font:getFace("smallinfofont", 14),
        })
    end
    if #row == 0 then
        table.insert(row, TextWidget:new{
            text = _("[图片/表情暂不可用]"),
            face = Font:getFace("smallinfofont", 14),
        })
    end
    self[1] = FrameContainer:new{
        dimen = self.dimen:copy(),
        padding = Size.padding.small,
        margin = 0,
        bordersize = Size.border.thin,
        background = Blitbuffer.COLOR_WHITE,
        row,
    }
end

function CommentImageRow:onTapSelect()
    -- Missing image slots are explicit and tappable: retry just the safe,
    -- whitelisted image fetches without touching comment/thread data.
    if (tonumber(self.entry.missing_count) or 0) > 0
        and self.menu and self.menu.retryImages then
        self.menu:retryImages()
    end
    return true
end

--- Comments may carry BBCode-ish tags and <br>. Strip markup, keep line breaks,
--- never emit raw markup into a Menu item.
local function clean(text)
    return Content.comment_plain_text(text)
end

function CommentMenu:_store()
    local store = self.deps.store
    if not store then return nil end
    local db, err = store.open(self.deps.book_dir, self.deps.store_namespace)
    if not db then
        -- Keep the reason for the log line in reload(); nil is not informative.
        self.deps.db_error = err
    end
    return db
end

function CommentMenu:reload()
    local store = self.deps.store
    if not store then return end
    local db = self:_store()
    if not db then
        -- This used to set fresh=false and fall through to the same rendering as
        -- "nothing cached", so a broken database told the reader their comments
        -- were not downloaded yet -- and offered a refresh that could not work.
        self.items, self.total, self.fresh = {}, 0, false
        self.error = self.deps.db_error or "open_failed"
        logger.err("comment panel: cannot open comment db:",
            tostring(self.error))
        return
    end
    local state = store.get_comments(db, self.store_aid or self.aid)
    store.close(db)
    if not state then
        self.items, self.total, self.fresh = {}, 0, false
        self.error = nil
        self.complete = false
        return
    end
    self.error = nil
    self.items = state.items or {}
    self.total = state.total or #self.items
    self.complete = state.complete
    self.fresh = state.fresh or false
end

function CommentMenu:_title()
    -- Say what is actually listed. `total` is the server's count while the list
    -- holds only the cached pages, so a partial cache would otherwise be
    -- captioned with a number the reader cannot see.
    local shown = #(self.items or {})
    local total = tonumber(self.total) or shown
    if self.complete == false and total > shown then
        return string.format(_("看评论（已缓存 %d 条，共 %d 条）"), shown, total)
    end
    return string.format(_("看评论（共 %d 条）"), shown)
end

function CommentMenu:_build_items()
    local items = {}
    -- Action rows first, always: 刷新评论 and 缓存全书评论 used to be behind the
    -- title-bar menu, which is now the back button. They lead the list so they
    -- are reachable without scrolling past hundreds of comments.
    items[#items + 1] = {
        kind = "action",
        text = self.fresh and _("↻ 刷新评论") or _("↻ 刷新评论（未缓存）"),
        callback = function() self:onRefresh() end,
    }
    items[#items + 1] = {
        kind = "action",
        text = _("↓ 缓存全书评论"),
        callback = function() self:onCacheAll() end,
    }
    if #(self.items or {}) == 0 then
        items[#items + 1] = {
            text = self.error and _("评论数据库打不开") or
                (self.fresh and _("还没有评论") or _("评论未缓存，点上方“刷新评论”")),
            select_enabled = false,
        }
        return items
    end
    local function add_comment(comment, prefix)
        local body = clean(comment.content)
        local urls = Content.comment_image_urls(comment.content)
        if #urls > 0 then
            body = body:gsub("%s*%[图片/表情%]%s*", " ")
        end
        local who = tostring(comment.author or "?")
        if comment.likes and tonumber(comment.likes) and tonumber(comment.likes) > 0 then
            who = who .. "  ♥" .. tostring(tonumber(comment.likes))
        end
        items[#items + 1] = {
            kind = "text", text = (prefix or "") .. who .. "\n" .. body,
            select_enabled = false,
        }
        if #urls > 0 then
            local paths = {}
            for url_index, url in ipairs(urls) do
                        local path = self.image_cache and self.image_cache[url]
                if path then paths[#paths + 1] = path end
            end
            items[#items + 1] = { kind = "images", image_urls = urls,
                image_paths = paths, missing_count = #urls - #paths,
                select_enabled = false }
        end
    end
    for _i, entry in ipairs(self.items) do
        add_comment(entry, "")
        for reply_index, reply in ipairs(entry.replies_list or {}) do
            add_comment(reply, "  └ ")
        end
    end
    return items
end

function CommentMenu:_imageUrls()
    local urls, seen = {}, {}
    local function collect(text)
        for image_index, url in ipairs(Content.comment_image_urls(text)) do
            if not seen[url] and #urls < 64 then
                seen[url] = true
                urls[#urls + 1] = url
            end
        end
    end
    for entry_index, entry in ipairs(self.items or {}) do
        collect(entry.content)
        for reply_index, reply in ipairs(entry.replies_list or {}) do collect(reply.content) end
    end
    return urls
end

function CommentMenu:_loadImages()
    if self.images_loading or self.images_ready then return end
    local worker = self.deps.worker
    local client = self.deps.client
    local book_dir = self.deps.book_dir
    if not worker or not client or not book_dir then
        self.images_ready = true
        return
    end
    local urls = self:_imageUrls()
    if #urls == 0 then self.images_ready = true; return end
    self.images_loading = true
    local ContentModule = Content
    local started = worker:start{
        queue = true,
        timeout = 300,
        on_done = function(result)
            self.images_loading = false
            if self._closed then return end
            if result and result.ok and type(result.value) == "table" then
                self.image_cache = result.value
            else
                logger.warn("comment panel: image cache job failed",
                    tostring(result and result.error or "unknown"))
            end
            self.images_ready = true
            self:_refresh()
        end,
        task = function()
            local lfs = require("libs/libkoreader-lfs")
            local ContentWorker = require("lightnovel.lib.content")
            local DigestWorker = require("lightnovel.lib.digest")
            local paths = book_dir .. "/comment-images"
            lfs.mkdir(paths)
            local result, total_bytes = {}, 0
            local function extension(data)
                if data:sub(1,3) == "\\255\\216\\255" then return ".jpg" end
                if data:sub(1,8) == "\\137PNG\\r\\n\\26\\n" then return ".png" end
                if data:sub(1,6) == "GIF87a" or data:sub(1,6) == "GIF89a" then return ".gif" end
                if data:sub(1,4) == "RIFF" and data:sub(9,12) == "WEBP" then return ".webp" end
                return nil
            end
            for url_index, url in ipairs(urls) do
                local normalized = url
                if normalized:find("i.noire.cc:332", 1, true) then
                    normalized = normalized:gsub("i%.noire%.cc:332", "i.noire.cc")
                end
                local candidates = { url }
                if normalized ~= url then candidates[#candidates + 1] = normalized end
                local key = DigestWorker.md5(url)
                local existing
                for extension_index, ext in ipairs({ ".jpg", ".png", ".gif", ".webp" }) do
                    local candidate = paths .. "/" .. key .. ext
                    if lfs.attributes(candidate, "mode") == "file" then
                        existing = candidate; break
                    end
                end
                if existing then
                    local attr = lfs.attributes(existing, "size")
                    total_bytes = total_bytes + (tonumber(attr) or 0)
                    result[url] = existing
                elseif total_bytes < 24 * 1024 * 1024 then
                    local bytes, ext
                    for candidate_index, candidate_url in ipairs(candidates) do
                        for attempt = 1, 3 do
                            bytes = client:get(candidate_url, { timeout = 30 })
                            ext = bytes and extension(bytes)
                            if bytes and ext and #bytes <= 8 * 1024 * 1024 then break end
                            bytes, ext = nil, nil
                        end
                        if bytes and ext then break end
                    end
                    if bytes and ext and total_bytes + #bytes <= 24 * 1024 * 1024 then
                        local path = paths .. "/" .. key .. ext
                        local ok = ContentWorker.write_atomic(path, bytes)
                        if ok then
                            result[url] = path
                            total_bytes = total_bytes + #bytes
                        end
                    end
                end
            end
            return result
        end,
    }
    if not started then
        self.images_loading = false
        self.images_ready = true
        logger.warn("comment panel: unable to queue image cache")
    end
end

function CommentMenu:updateItems(select_number, no_recalculate_dimen)
    local old_dimen = self.dimen and self.dimen:copy()
    self.layout = {}
    self.item_group:clear()
    self.page_info:resetLayout()
    self.return_button:resetLayout()
    self.content_group:resetLayout()
    self:_recalculateDimen(no_recalculate_dimen)
    local offset = (self.page - 1) * self.perpage
    for idx_on_page = 1, self.perpage do
        local index = offset + idx_on_page
        local entry = self.item_table[index]
        if not entry then break end
        entry.idx = index
        if index == self.itemnumber then select_number = idx_on_page end
        local klass
        if entry.kind == "images" then
            klass = CommentImageRow
        elseif entry.kind == "action" then
            klass = CommentActionRow
        else
            klass = CommentTextRow
        end
        local row = klass:new{
            entry = entry,
            menu = self,
            dimen = self.item_dimen:copy(),
        }
        table.insert(self.item_group, row)
        table.insert(self.layout, { row })
    end
    self:updatePageInfo(select_number)
    self:mergeTitleBarIntoLayout()
    UIManager:setDirty(self.show_parent, function()
        return "ui", old_dimen and old_dimen:combine(self.dimen) or self.dimen
    end)
end

function CommentMenu:retryImages()
    if self.images_loading then return end
    self.images_ready = false
    self:_loadImages()
end

function CommentMenu:_refresh()
    self.item_table = self:_build_items()
    self:updateItems()
    self.title_bar:setTitle(self:_title())
    self:_loadImages()
end

--- Back button. The two actions that used to live here are rows at the top of
--- the list now (see _build_items), so this matches every other screen.
function CommentMenu:onLeftButtonTap()
    return self:onClose()
end

--- Long-press still offers the same two actions plus a way straight out, so a
--- reader who has scrolled far down the list does not have to come back up.
function CommentMenu:onLeftButtonHold()
    local actions = {
        {
            {
                text = self.fresh and _("刷新评论") or _("刷新评论（未缓存）"),
                callback = function() self:onRefresh() end,
            },
            {
                text = _("缓存全书评论"),
                callback = function() self:onCacheAll() end,
            },
            {
                text = _("关闭"),
                callback = function() self:onCloseAllMenus() end,
            },
        },
    }
    UIManager:show(ButtonDialog:new{
        title = _("评论"),
        buttons = actions,
    })
    return true
end

function CommentMenu:onRefresh()
    if self.loading then
        return
    end
    local sync = self.deps.sync
    if not sync then
        UIManager:show(InfoMessage:new{ text = _("评论同步不可用") })
        return
    end
    self.loading = true
    local started, err = sync:refresh_one(self.store_aid or self.aid, {
        on_done = function()
            self.loading = false
            -- The worker answers from a UIManager timer, so the panel can be
            -- closed in the meantime. Repainting a dead widget is how this file
            -- used to risk touching title_bar after onCloseWidget.
            if self._closed then
                return
            end
            self:reload()
            self.image_cache = {}
            self.images_ready = false
            self:_refresh()
        end,
    })
    if not started then
        self.loading = false
        UIManager:show(InfoMessage:new{
            text = _("无法启动后台刷新：") .. tostring(err or "unknown"),
        })
    end
end

function CommentMenu:onCacheAll()
    local sync = self.deps.sync
    if not sync then return end
    local aids = self.deps.all_aids
    if type(aids) ~= "table" or #aids == 0 then
        UIManager:show(InfoMessage:new{ text = _("没有可缓存的章节") })
        return
    end
    local started, err = sync:queue_background(aids)
    if not started then
        UIManager:show(InfoMessage:new{
            text = _("无法启动后台缓存：") .. tostring(err or "unknown"),
        })
    end
end

function CommentMenu:onCloseWidget()
    self._closed = true
    Menu.onCloseWidget(self)
    return true
end

--- Entry point used by the reader hook; mirrors fanqie's ShelfView.show(opts).
function CommentMenu.show(opts)
    opts = opts or {}
    local menu = CommentMenu:new{
        title = string.format(_("看评论（共 %d 条）"), 0),
        item_table = {},
        -- Image rows share Menu's fixed row height; five entries per page
        -- leaves enough vertical room for a 48px thumbnail plus frame padding.
        items_per_page = opts.items_per_page or 5,
        is_borderless = true,
        aid = tonumber(opts.aid),
        store_aid = tonumber(opts.store_aid) or tonumber(opts.aid),
        deps = opts.deps or {},
    }
    menu.image_cache = {}
    menu:reload()
    UIManager:show(menu)
    menu:_refresh()
    return menu
end

return CommentMenu