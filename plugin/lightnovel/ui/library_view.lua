--[[--
Library screen: browse categories, search, and reopen cached books.

This is a plain KOReader Menu, the same widget fanqie.koplugin uses for its shelf
(fanqie/shelf_view.lua: ShelfMenu = Menu:extend). The previous version built its
own VerticalGroup + ScrollHtmlWidget + Button row, which looked nothing like
KOReader and re-laid out on every paint -- slow enough to stall the e-ink screen.
Menu handles item sizing, paging and repaints natively.

Rows are drawn by ShelfRow below instead of MenuItem, because MenuItem renders
text only and a bookshelf needs a cover next to the title. That is the same
trade fanqie made, and it is done the same way: replace the row widget and
rebuild the page in an updateItems override.

Search needs a session (the API answers code 5 otherwise), so the search entry
only appears once a session key exists. Category browsing works logged out.
--]]--

local _ = require("gettext")
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Menu = require("ui/widget/menu")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UnderlineContainer = require("ui/widget/container/underlinecontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

-- There is no global Screen; both reference plugins bind it from the device
-- module (weread/zenui.lua:53-64, fanqie/bookshelf.lua:6).
local Screen = Device.screen

local logger = require("lightnovel.lib.logger")
local Cache = require("lightnovel.lib.chapter_cache")
local Cover = require("lightnovel.lib.cover")
-- menu.lua exposes the same safeCallback wrapper every other entry point uses.
-- Required here (not duplicated) so a failing row cannot kill the reader: an
-- unwrapped callback raised straight through menu.lua's onMenuChoice and
-- stopped ./reader.lua's event loop, which is what turned a nil-call inside
-- book_key into a full crash instead of a dialog.
local PluginMenu = require("lightnovel.ui.menu")
local lfs = require("libs/libkoreader-lfs")
-- Same JSON codec client.lua prefers, used for the on-disk shelf cache.
local ok_json, Json = pcall(require, "json")
if not ok_json then Json = require("rapidjson") end

--- How many cover artifacts (downloads + renders) one background pass may do
--- before the UI stops asking. A shelf holds up to 50 books, so this is a safety
--- net rather than a working limit.
local MAX_ARTIFACTS_PER_PASS = 12

local LibraryMenu = Menu:extend{
    name = "lightnovel_library",
    is_doc_only = false,
    is_modal = true,
    covers_fullscreen = true,
    title_bar_fm_style = true,
    -- Back arrow, matching weread's screens. This used to be appbar.menu and
    -- opened a ButtonDialog whose rows (我的书架 / 刷新书架 / 最新 / 整卷 / 原创 /
    -- 搜索) duplicated what the list already shows: 分类浏览（最新/整卷/原创）and
    -- ⌕ 搜索轻小说 are rows on this very menu, and the shelf is reached from
    -- the plugin menu. So the dialog cost a tap to re-offer what was on screen.
    title_bar_left_icon = "chevron.left",
}

-- ----------------------------------------------------------------- shelf row

--- One bookshelf row: cover thumbnail on the left, title and author beside it.
---
--- Ported from fanqie.koplugin (fanqie/shelf_view.lua: ShelfItem), which hit the
--- identical wall -- KOReader's MenuItem draws text and nothing else -- and solved
--- it identically: an InputContainer per row, inserted into the menu's item group
--- by an updateItems override, with the tap forwarded to Menu:onMenuSelect.
---
--- Two details are taken from weread.koplugin rather than fanqie:
---   * ImageWidget construction is wrapped in pcall and the buffer is freed when
---     it fails, so one unreadable file costs a blank slot instead of the menu.
---   * file_do_cache = false. Every page turn rebuilds these rows, and keeping
---     them out of KOReader's shared image cache stops a shelf of covers from
---     evicting the images the reader itself is using.
local ShelfRow = InputContainer:extend{
    entry = nil,
    menu = nil,
    dimen = nil,
}

function ShelfRow:init()
    self.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = self.dimen } },
        -- 长按 = 打开目录（而不是打开书）。
        --
        -- 已经入库的书点一下会直接进阅读器（openWholeBook 的"一本书一个文件"规则），
        -- 于是"下载入库 / 库中书更新 / 补评论"这些目录页上的动作就没有入口了。
        -- 长按给回这个入口，同时不影响"点一下就读"。
        HoldSelect = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }

    local h = self.dimen.h
    local side = math.max(Size.padding.small, Screen:scaleBySize(4))
    local show_cover = self.entry.show_cover ~= false
    local cover_h = math.max(Screen:scaleBySize(58), h - side * 2)
    local cover_w = show_cover and math.max(1, math.floor(cover_h * 0.69)) or 0
    local cover

    if show_cover and self.entry.cover_path then
        local thumb_image
        local ok, err = pcall(function()
            thumb_image = ImageWidget:new{
                file = self.entry.cover_path,
                width = cover_w,
                height = cover_h,
                -- 0 means "best fit inside width x height"; the aspect ratio is
                -- preserved (imagewidget.lua:320-324), so the cover is never
                -- stretched to fill the slot.
                scale_factor = 0,
                file_do_cache = false,
            }
            -- Force the decode now: a failure here is still inside the pcall,
            -- whereas a failure on first paint happens during the paint loop.
            thumb_image:getSize()
        end)
        if ok and thumb_image then
            cover = thumb_image
        else
            logger.err("shelf: cover decode failed",
                tostring(self.entry.cover_path), tostring(err))
            if thumb_image and type(thumb_image.free) == "function" then
                pcall(thumb_image.free, thumb_image)
            end
        end
    end
    if show_cover then
        -- An empty bordered slot when there is no cover, rather than nothing:
        -- rows that gain or lose a cover must not shift the title column
        -- sideways, and a blank slot is the same signal fanqie shows.
        local content = cover
            or TextWidget:new{ text = "", face = Font:getFace("smallinfofont", 12) }
        cover = FrameContainer:new{
            width = cover_w,
            height = cover_h,
            bordersize = Size.border.thin,
            padding = 0,
            margin = 0,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = cover_w, h = cover_h },
                content,
            },
        }
    end

    local gap = show_cover and Size.padding.large or 0
    local text_w = math.max(Screen:scaleBySize(120),
        self.dimen.w - cover_w - gap - side * 2)
    -- Named title_box / info_box rather than title / info: the API contract gate
    -- maps variable names to classes across the whole plugin, and a bare `title`
    -- bound to a TextBoxWidget here would make it read catalog.title:gsub() in
    -- chapter_cache.lua as a TextBoxWidget call.
    local title_box = TextBoxWidget:new{
        text = tostring(self.entry.row_title or ""),
        face = Font:getFace("cfont", math.min(22, Screen:scaleBySize(18))),
        width = text_w,
        height = math.floor(h * 0.52),
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "left",
        bold = true,
    }
    local info_box = TextBoxWidget:new{
        text = tostring(self.entry.row_info or ""),
        face = Font:getFace("smallinfofont", math.min(17, Screen:scaleBySize(14))),
        width = text_w,
        height = math.floor(h * 0.30),
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "left",
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }

    local row = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = side },
    }
    if cover then
        table.insert(row, cover)
        table.insert(row, HorizontalSpan:new{ width = gap })
    end
    table.insert(row, LeftContainer:new{
        dimen = Geom:new{ w = text_w, h = h },
        VerticalGroup:new{
            align = "left",
            title_box,
            VerticalSpan:new{ height = math.max(1, Screen:scaleBySize(2)) },
            info_box,
        },
    })
    table.insert(row, HorizontalSpan:new{ width = side })

    self._underline = UnderlineContainer:new{
        dimen = self.dimen:copy(),
        linesize = Size.line.thin,
        color = Blitbuffer.COLOR_DARK_GRAY,
        padding = 0,
        vertical_align = "center",
        row,
    }
    self[1] = self._underline
    -- Do NOT assign self.dimen here. self.dimen is the table the TapSelect
    -- gesture range captured by reference, and InputContainer:paintTo
    -- (:80-82) keeps it aligned by writing x/y into whatever table self.dimen
    -- points at. UnderlineContainer:getSize() returns a NEWLY allocated Geom
    -- (underlinecontainer.lua:22-28) with no x/y, so rebinding would leave the
    -- gesture range pinned at (0,0) forever -- every row's tap zone collapsed
    -- onto the top-left corner and the shelf stopped responding to taps.
    -- fanqie's ShelfItem does not do this either; the row is already exactly
    -- item_dimen tall, which is what the item group lays out against.
end

function ShelfRow:onTapSelect()
    -- The menu owns selection semantics (select_enabled, callbacks), so the row
    -- only forwards the entry -- same as fanqie's ShelfItem.
    if self.menu and self.entry then
        self.menu:onMenuSelect(self.entry)
    end
    return true
end

--- 长按：交给菜单去开目录页。
function ShelfRow:onHoldSelect()
    if self.menu and self.entry then
        self.menu:onRowHold(self.entry)
    end
    return true
end

function ShelfRow:onFocus()
    self._underline.color = Blitbuffer.COLOR_BLACK
    return true
end

function ShelfRow:onUnfocus()
    self._underline.color = Blitbuffer.COLOR_DARK_GRAY
    return true
end

function LibraryMenu:_client()
    return self.deps.client
end

function LibraryMenu:_busy(text)
    self:_idle()
    -- Full-screen cover, not an InfoMessage: an InfoMessage is a small centred
    -- box and the file manager home stays visible behind it. Once the plugin is
    -- open nothing behind it may show through -- the reader asked for that
    -- explicitly.
    self.busy_overlay = PluginMenu.showLoading(text)
end

function LibraryMenu:_idle()
    if self.busy_overlay then
        pcall(function() UIManager:close(self.busy_overlay) end)
        self.busy_overlay = nil
    end
end

--- Run a client call inside the background worker so the UI never blocks.
--- Every exit path logs. A failure that only raises an InfoMessage leaves
--- nothing in crash.log, which is what made a failed shelf refresh impossible
--- to diagnose: the dialog said "获取书架失败：..." and the log stopped at the
--- line before the request.
function LibraryMenu:_fetch(label, task, on_done)
    local worker = self.deps.worker
    if not worker or not worker:available() then
        logger.err("fetch:", label, "worker unavailable")
        UIManager:show(InfoMessage:new{ text = _("后台进程不可用，无法联网") })
        return false
    end
    self:_busy(label)
    local started, err = worker:start{
        timeout = 120,
        -- queue = true: the worker runs one job at a time and the background
        -- cover-thumbnail pass may hold it. A refresh the reader asked for must
        -- wait its turn, not come back as "worker_busy".
        queue = true,
        on_done = function(result)
            self:_idle()
            if not result or not result.ok then
                local reason = result and result.error or "unknown"
                if reason ~= "cancelled" then
                    logger.err("fetch:", label, "failed. reason=", tostring(reason))
                    UIManager:show(InfoMessage:new{
                        text = label .. _("失败：") .. tostring(reason),
                    })
                else
                    logger.info("fetch:", label, "cancelled")
                end
                return
            end
            on_done(result.value)
        end,
        task = task,
    }
    if not started then
        self:_idle()
        logger.err("fetch:", label, "cannot start. reason=", tostring(err or "?"))
        UIManager:show(InfoMessage:new{
            text = _("无法启动后台任务：") .. tostring(err or "unknown"),
        })
        return false
    end
    logger.info("fetch:", label, "started")
    return true
end

-- ------------------------------------------------------------------- items

--- Locate the cover image for one book, or nil.
---
--- The path is recomputed from the same key chapter_cache wrote it under rather
--- than stored on the book: the shelf cache on disk is JSON and predates covers,
--- and a book reaches this screen from four different listings.
--- @return string|nil path, string|nil key
function LibraryMenu:_cover_for(book)
    local settings = self.deps.settings
    if not settings then
        return nil
    end
    local key = Cache.book_key(book)
    if not key or key == "" then
        logger.warn("shelf: book has no cache key, no cover. title=",
            tostring(book and book.title))
        return nil
    end
    local ok, path = pcall(Cover.resolve, settings, key)
    if not ok then
        logger.err("shelf: cover lookup raised. key=", tostring(key),
            tostring(path))
        return nil
    end
    return path, key
end

--- Second line of a shelf row: author, plus the word count when the API sent one.
local function row_info(book)
    local info = tostring(book.author or "")
    local words = tonumber(book.words) or 0
    if words > 0 then
        local count = string.format(_("%d 字"), words)
        info = info ~= "" and (info .. " · " .. count) or count
    end
    return info
end

--- One action row (refresh / search / browse / back), used instead of leaving
--- the entry inside the left-button dialog.
---
--- The functions below used to live only in the hamburger dialog, which is the
--- third time this plugin has hidden a feature there and the third time it read
--- as "the feature does not exist". They are real rows now, and the dialog is
--- kept as a duplicate so nothing becomes unreachable.
local function action_row(text, callback)
    return {
        text = text,
        row_title = text,
        row_info = "",
        show_cover = false,
        callback = PluginMenu.safeCallback(text, callback),
    }
end

--- The category browser as a Menu sub-table. Menu renders it as a normal page
--- with a back arrow (switchItemTable), which is one tap away and visible --
--- unlike the dialog it replaces.
local function browse_items(self)
    local Client = require("lightnovel.lib.client")
    local labels = {
        latest = _("最新"),
        full_vol = _("整卷"),
        original = _("原创"),
    }
    local items = {}
    for _index, key in ipairs({ "latest", "full_vol", "original" }) do
        -- Client.BROWSE[key] already carries parent_gid AND gid; hand the table
        -- over untouched. Rebuilding a partial copy here silently dropped
        -- parent_gid, and load_category copies exactly those two fields.
        local spec = Client.BROWSE[key]
        local label = labels[key]
        items[#items + 1] = action_row(label, function()
            self:load_category(spec, label)
        end)
    end
    return items
end

function LibraryMenu:_build_items()
    local items = {}
    local st = self.state

    -- Refresh, search and the category browser live as visible rows on the shelf,
    -- not only inside the left-button menu: the shelf paints from its on-disk
    -- cache and issues no request, so without an on-screen row there is no
    -- visible way to fetch changes made on the website, browse, or search.
    if st.mode == "bookshelf" then
        local suffix = ""
        if st.from_cache then
            suffix = _("（缓存，点此刷新）")
        else
            suffix = _("（已联网更新）")
        end
        items[#items + 1] = action_row(_("↻ 刷新书架") .. suffix, function()
            self:load_bookshelf(1, { force = true })
        end)
        if self:_client() and self:_client():hasSession() then
            items[#items + 1] = action_row(_("⌕ 搜索轻小说"), function()
                self:onPromptSearch()
            end)
        end
        local browse = browse_items(self)
        items[#items + 1] = {
            text = _("分类浏览（最新 / 整卷 / 原创）▸"),
            row_title = _("分类浏览（最新 / 整卷 / 原创）▸"),
            row_info = "",
            show_cover = false,
            sub_item_table = browse,
        }
        -- Bulk backfill, on the shelf itself rather than only inside one book's
        -- catalogue: it acts on EVERY cached book, so requiring the reader to
        -- open a book first was a pointless extra step. weread publishes one
        -- merged file per title and nothing else, so this is the action that
        -- makes an already-downloaded library look the same way.
        if self.deps.on_publish_all then
            items[#items + 1] = action_row(_("⤓ 把已缓存书籍合并入库"), function()
                self:onClose()
                self.deps.on_publish_all()
            end)
        end
    elseif st.mode ~= "menu" then
        -- Category and search results need a way back that does not involve the
        -- hamburger: this row is that way.
        items[#items + 1] = action_row(_("← 我的书架"), function()
            self:load_bookshelf(1)
        end)
    end

    if #(st.items or {}) == 0 then
        local hint
        if st.mode == "search" then
            hint = _("没有结果")
        elseif st.mode == "bookshelf" then
            hint = _("书架是空的，点上面「↻ 刷新书架」拉取")
        else
            hint = _("用下面的「分类浏览」或「⌕ 搜索轻小说」找书")
        end
        items[#items + 1] = {
            text = hint,
            row_title = hint,
            row_info = "",
            select_enabled = false,
        }
    end
    for _i, entry in ipairs(st.items or {}) do
        local book = entry
        local label = tostring(book.title or "")
        if book.author and book.author ~= "" then
            label = label .. "\n" .. tostring(book.author)
        end
        local title_text = book.title or ""
        items[#items + 1] = {
            -- `text` is what Menu itself would draw and what the search /
            -- goto-letter machinery reads, so it keeps the old two-line form.
            text = label,
            row_title = title_text,
            row_info = row_info(book),
            cover_path = self:_cover_for(book),
            show_cover = true,
            -- 长按要用"这本书"而不是这个菜单行：行里没有 book_id/title。
            -- 少了这个字段，长按会带着空 book_id 走 legacy 分支，开出一个
            -- "chapters=1 title=''" 的空目录页（23:11:42 日志实证）。
            book = book,
            -- safeCallback keeps a failure inside one row: it logs, shows the
            -- reason and returns, leaving the menu and the reader alive.
            callback = PluginMenu.safeCallback(title_text, function()
                self:_open(book)
            end),
        }
    end
    -- quiet 书架只是下载弹窗的背景：此时 worker 正被下载任务占着，再排一个封面
    -- 任务只会挤掉队列里的用户任务（Worker:start 会用新请求替换 pending），
    -- 而封面本来就要在下一次正常打开书架时补，不必在这里抢。
    if not self.quiet then
        self:_ensure_artifacts(st.items)
    end
    return items
end

--- Fetch missing covers and render missing thumbnails in the worker, once per
--- pass, silently.
---
--- Two jobs used to be needed and one is enough: the shelf listing already
--- carries a `cover_url` for every book, but until Cover.download was shared with
--- chapter_cache the only code path that ever fetched a cover was a whole-book
--- download -- so a shelf showed exactly one cover, the one whose body happened
--- to be cached.
---
--- Rendering and downloading happen in the subprocess for the reason the whole
--- download does -- decoding a 577x812 JPEG costs seconds of frozen screen on
--- e-ink -- and this deliberately raises no overlay: nothing is being waited on,
--- and the shelf is fully usable meanwhile (rows without a cover just show an
--- empty slot).
function LibraryMenu:_ensure_artifacts(books)
    local settings = self.deps.settings
    local worker = self.deps.worker
    local client = self.deps.client
    if not settings or not worker or not worker:available() then
        return
    end
    if self._artifact_job or self._closed then
        return
    end
    -- Entries whose fetch or render already failed are not retried on this
    -- session: without this, one unreachable cover URL spawns a fresh subprocess
    -- on every page turn.
    --
    -- "this session" is the operative word. Cover URLs are signed and expire
    -- (`?m=<signature>&t=<expiry>`), and normaliseShelf hands out a freshly
    -- signed one on every successful refresh -- so a key blacklisted for an
    -- http_403 during the outage stayed dead for the whole session even after
    -- the site came back and a perfectly good URL was sitting in the new shelf
    -- data. The memo is therefore cleared whenever a forced refresh succeeds,
    -- which is exactly when new URLs arrive.
    self._artifact_failed = self._artifact_failed or {}
    local download, render = {}, {}
    for _i, book in ipairs(books or {}) do
        if #download + #render >= MAX_ARTIFACTS_PER_PASS then
            break
        end
        local key = Cache.book_key(book)
        local url = tostring(book.cover_url or "")
        if key and not self._artifact_failed[key] then
            if Cover.needs_download(settings, key, url) then
                download[#download + 1] = { key = key, url = url }
            elseif Cover.needs_thumbnail(settings, key) then
                render[#render + 1] = key
            end
        end
    end
    if #download == 0 and #render == 0 then
        return
    end
    logger.info("shelf: fetching", tostring(#download), "covers, rendering",
        tostring(#render), "thumbnails")
    self._artifact_job = true
    -- queue = true: the worker runs one job at a time and a whole-book download
    -- must not be displaced by cosmetics.
    local started, err = worker:start{
        queue = true,
        timeout = 300,
        on_done = function(result)
            self._artifact_job = false
            if not result or not result.ok then
                logger.warn("shelf: cover pass failed:",
                    tostring(result and result.error or "no result"))
                return
            end
            local value = result.value or {}
            local made = value.made or {}
            local failed = value.failed or {}
            for _index, item in ipairs(failed) do
                self._artifact_failed[item.key] = true
            end
            -- Say so once, out loud. An empty cover slot with no explanation is
            -- indistinguishable from a plugin bug, and the first time this
            -- happened the site turned out to be serving 512 "订单到期暂停" on
            -- every path -- nothing to fix here, but the reader deserves to know
            -- the picture is coming back on its own rather than being broken.
            if #failed > 0 and not self._cover_notice_shown then
                self._cover_notice_shown = true
                local reason = failed[1].reason or "unknown"
                logger.warn("shelf: cover fetch failed:", tostring(#failed),
                    "books. first reason=", tostring(reason))
                UIManager:show(InfoMessage:new{
                    text = _("封面暂时取不到（服务器返回 %s）。这是网站那边的问题，"
                        .. "恢复后会自动补上。") .. tostring(reason),
                })
            end
            if #made == 0 then
                return
            end
            logger.info("shelf: cover artifacts ready:", tostring(#made))
            -- The rows were built without covers; rebuild so they pick them up.
            if not self._closed then
                self:_refresh()
            end
        end,
        -- Emit progress per cover. background_worker refreshes its `last_progress_at`
        -- only when a payload arrives and SIGKILLs the child once that goes stale
        -- for `timeout` seconds. The pass had no context at all, so a shelf with
        -- a dozen covers (12 x 45s of socket time) was killed at 300s, the
        -- results were thrown away, and the same covers were re-queued on the next
        -- page turn -- forever.
        task = function(context)
            local made, failed = {}, {}
            local total = #download + #render
            local step = 0
            for _index, item in ipairs(download) do
                context.checkCancelled()
                step = step + 1
                context.emit{ stage = "cover", done = step, total = total }
                local path, reason = Cover.download(client, item.key, item.url)
                if path then
                    made[#made + 1] = item.key
                else
                    failed[#failed + 1] = { key = item.key,
                        reason = tostring(reason or "unknown") }
                end
            end
            -- Downloads already render their own thumbnail.
            for _index, key in ipairs(render) do
                context.checkCancelled()
                step = step + 1
                context.emit{ stage = "cover", done = step, total = total }
                local path, reason = Cover.ensure_thumbnail(settings, key)
                if path then
                    made[#made + 1] = key
                else
                    failed[#failed + 1] = { key = key,
                        reason = tostring(reason or "unknown") }
                end
            end
            return { made = made, failed = failed }
        end,
    }
    if not started then
        self._artifact_job = false
        logger.warn("shelf: cannot start cover pass:",
            tostring(err or "unknown"))
    end
end

function LibraryMenu:_refresh()
    self.item_table = self:_build_items()
    self:updateItems()
end

--- Selection stays with the menu: Menu:onMenuSelect honours select_enabled and
--- then calls the entry's callback, which is already error-contained.
function LibraryMenu:onMenuSelect(entry)
    return Menu.onMenuSelect(self, entry)
end

--- Rebuild the visible page out of ShelfRow widgets.
---
--- A copy of Menu:updateItems (menu.lua:1058-1145) with MenuItem swapped for
--- ShelfRow -- the same substitution fanqie's ShelfMenu makes. Everything else is
--- left alone deliberately: item_dimen still decides row height, the focus
--- layout still gets one entry per row, and the page counter still comes from
--- Menu.getPageNumber.
function LibraryMenu:updateItems(select_number, no_recalculate_dimen)
    local old_dimen = self.dimen and self.dimen:copy()
    -- self.layout must be updated for focusmanager
    self.layout = {}
    self.item_group:clear()
    self.page_info:resetLayout()
    self.return_button:resetLayout()
    self.content_group:resetLayout()
    self:_recalculateDimen(no_recalculate_dimen)
    local offset = (self.page - 1) * self.perpage
    for index_on_page = 1, self.perpage do
        local index = offset + index_on_page
        local entry = self.item_table[index]
        if not entry then
            break
        end
        -- idx is valid only for displayed items; Menu reads it back in
        -- getFirstVisibleItemIndex and in the gesture position maths.
        entry.idx = index
        if index == self.itemnumber then
            select_number = index_on_page
        end
        local row = ShelfRow:new{
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

function LibraryMenu:_open(book, options)
    local handler = self.deps.on_open_book
    if not handler then return end
    -- Order matters. Covering the screen happens BEFORE this menu closes,
    -- otherwise closing first leaves a gap in which the file manager home is
    -- fully visible while the catalog loads. on_begin_load raises a full-screen
    -- overlay owned by the plugin; the handler reuses it and drops it when the
    -- work finishes.
    if self.deps.on_begin_load then
        pcall(function() self.deps.on_begin_load() end)
    end
    pcall(function() self:onClose() end)
    handler(book, options)
end

--- 长按一行：进入目录页，而不是打开书。
---
--- 已入库的书点一下直接进阅读器是刻意的（一个标题只占 FILE 历史一条），但那样
--- 目录页上的"下载入库 / 库中书更新"就没有入口，想补评论也无从点起。长按把目录
--- 页请回来，动作由调用方决定（main.openShelfBook 收到 toc_only）。
function LibraryMenu:onRowHold(entry)
    -- 只有书行才有 book 字段；「刷新书架」「分类浏览」这些行长按不做任何事。
    if not entry or not entry.book then return true end
    logger.info("shelf: hold on", tostring(entry.book.title),
        "-> open catalogue")
    self:_open(entry.book, { toc_only = true })
    return true
end

-- -------------------------------------------------------------- left button

--- Back button: close THIS screen, which uncovers the 轻之国度 menu underneath.
---
--- Why onClose() and not onCloseAllMenus(): LibraryMenu is shown with
--- UIManager:show on top of the plugin's TouchMenu, and 书架 / 搜索 are
--- registered with keep_menu_open = true (see menu.lua) so that menu is still
--- in the window stack. Menu:onClose() pops one item_table level if there is
--- one, and otherwise closes only this widget -- which is exactly "up one
--- level" here. onCloseAllMenus() would tear the whole stack down and drop the
--- reader on the file manager, which is what the reader reported.
---
--- There is no long-press action. It used to offer 刷新书架 / 关闭, but the
--- shelf now carries a visible "↻ 刷新书架" row of its own, so the long press
--- was a hidden duplicate. Removed on the reader's explicit request.
function LibraryMenu:onLeftButtonTap()
    return self:onClose()
end

-- ------------------------------------------------------------------ search

function LibraryMenu:onPromptSearch()
    local dialog
    dialog = InputDialog:new{
        title = _("搜索轻小说"),
        -- Each button needs its OWN callback: buttontable.lua:82 calls
        -- `btn_entry.callback()` with no nil check, and InputDialog has no
        -- dialog-level `callback` field. weread 10/10, fanqie 16/16.
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("搜索"),
                    is_enter_default = true,
                    callback = function()
                        local query = (dialog:getInputValue() or "")
                            :gsub("^%s+", ""):gsub("%s+$", "")
                        if query == "" then
                            return
                        end
                        UIManager:close(dialog)
                        self.state.query = query
                        self:run_search(1)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

-- ------------------------------------------------------------------ loading

local function normalise(list, skip_unreadable)
    local out = {}
    for _i, entry in ipairs(list or {}) do
        local gid = tonumber(entry.gid)
        if not (skip_unreadable and (gid == 108 or gid == 110)) then
            out[#out + 1] = {
                index = #out + 1,
                aid = tonumber(entry.aid),
                sid = tonumber(entry.sid),
                title = tostring(entry.title or entry.name or ""),
                author = tostring(entry.author or ""),
            }
        end
    end
    return out
end

--- Map a bff shelf entry onto the same shape the other listings produce, so
--- _build_items needs no special case.
--
--- `sid` and `aid` stay 0 on purpose: the shelf hands out a `book_id` from the
--- new id space, and neither `source_series_id` nor `book_id` resolves against
--- the legacy series/article endpoints (get-article-list and get-info both
--- answer code 0 with an empty array for it). Passing them on as if they were
--- legacy ids would open an empty catalog, so _open() checks book_id first.
--
--- `cover_url` is carried through for the same reason as the ids: every shelf
-- entry has one, and it is the only way a book that was never cached whole ever
-- gets a picture. Dropping it here is what left the shelf showing one cover for
-- two books.
local function normaliseShelf(list)
    local out = {}
    for _i, entry in ipairs(list or {}) do
        out[#out + 1] = {
            index = #out + 1,
            book_id = tonumber(entry.book_id) or 0,
            sid = 0,
            aid = 0,
            title = tostring(entry.title or ""),
            author = tostring(entry.author_name or entry.illustrator_name or ""),
            words = tonumber(entry.word_count) or 0,
cover_url = tostring(entry.cover_url or ""),
        }
    end
    return out
end

function LibraryMenu:load_category(spec, label)
    local st = self.state
    st.mode = "category"
    st.title = label
    st.page = 1
    st.spec = spec
    local client = self:_client()
    local spec_copy = { parent_gid = spec.parent_gid, gid = spec.gid }
    self:_fetch(_("获取列表"), function()
        local data, err = client:fetchCategory(spec_copy, 1, { timeout = 30 })
        if not data then
            return { error = err }
        end
        return { data = data }
    end, function(value)
        if not value or value.error then
            UIManager:show(InfoMessage:new{
                text = _("获取失败：") .. tostring(value and value.error or "unknown"),
            })
            return
        end
        st.items = normalise((value.data or {}).list, false)
        -- A full page implies there may be more; the API has no total count.
        st.has_more = #st.items >= 20
        self:_refresh()
    end)
end

function LibraryMenu:load_category_page(page)
    local st = self.state
    local client = self:_client()
    local spec_copy = { parent_gid = st.spec.parent_gid, gid = st.spec.gid }
    -- b27：一次取全（最多 3 个服务器页合并），列表翻页全部走菜单本地分页。
    -- 旧的单页服务器翻页从不同步 self.page，猫按了没反应（与书架同根因）。
    self:_fetch(_("获取列表"), function()
        local merged = {}
        for p = 1, 3 do
            local data, err = client:fetchCategory(spec_copy, p, { timeout = 30 })
            if not data then
                if p == 1 then return { error = err } end
                break
            end
            local list = (data or {}).list or {}
            for _i, item in ipairs(list) do merged[#merged + 1] = item end
            if #list < 20 then break end
        end
        return { data = { list = merged } }
    end, function(value)
        if not value or value.error then
            UIManager:show(InfoMessage:new{ text = _("获取失败") })
            return
        end
        st.page = 1
        st.items = normalise((value.data or {}).list, false)
        st.has_more = false
        self:_refresh()
    end)
end

function LibraryMenu:run_search(page)
    local st = self.state
    local client = self:_client()
    if not client or not client:hasSession() then
        UIManager:show(InfoMessage:new{
            text = _("搜索需要先登录，请先在菜单里登录账号"),
        })
        return
    end
    local query = st.query
    -- b27：同 load_category_page，取全（最多 3 页合并）+ 本地翻页。
    self:_fetch(_("搜索"), function()
        local merged = {}
        for p = 1, 3 do
            local data, err = client:search(query, 2, p, { timeout = 30 })
            if not data then
                if p == 1 then return { error = err } end
                break
            end
            local list = (data or {}).list or {}
            for _i, item in ipairs(list) do merged[#merged + 1] = item end
            if #list < 20 then break end
        end
        return { data = { list = merged } }
    end, function(value)
        if not value or value.error then
            UIManager:show(InfoMessage:new{
                text = _("搜索失败：") .. tostring(value and value.error or "unknown"),
            })
            return
        end
        st.mode = "search"
        st.page = 1
        local list = (value.data or {}).list or {}
        -- gid 108/110 are download and EPUB link posts, not readable text.
        st.items = normalise(list, true)
        st.has_more = false
        self:_refresh()
    end)
end

-- ------------------------------------------------------------ server shelf

-- The shelf page size matches Client.BOOKSHELF_PAGE_SIZE (50). The bff family
-- only rejects pageSize < 1, unlike the legacy list endpoints that need >= 20.
local SHELF_PAGE_SIZE = 50

--- Where the last successful shelf response is cached.
--
-- Re-entering the shelf used to refetch every time, which costs a round trip on
-- e-ink and shows a spinner for data that rarely changes. The cache lets the
-- list paint instantly and work offline; a refresh is always one tap away.
local function shelf_cache_path(client)
    if not client or not client.settings then
        return nil
    end
    return client.settings:data_dir() .. "/shelf.lua"
end

local function read_shelf_cache(client)
    local path = shelf_cache_path(client)
    if not path then
        logger.err("shelf cache: no data dir (client has no settings)")
        return nil
    end
    if lfs.attributes(path, "mode") ~= "file" then
        -- Normal on a first run; dbg so it does not drown the log.
        logger.dbg("shelf cache: none at", path)
        return nil
    end
    local f = io.open(path, "rb")
    if not f then
        logger.err("shelf cache: cannot open", path)
        return nil
    end
    local raw = f:read("*a")
    f:close()
    local ok, data = pcall(Json.decode, raw)
    if not ok or type(data) ~= "table" or type(data.items) ~= "table" then
        -- A truncated cache used to look exactly like "no cache", so the shelf
        -- silently refetched (or, offline, showed nothing).
        logger.err("shelf cache: unreadable", path, "bytes=",
            tostring(#raw))
        return nil
    end
    return data
end

local function write_shelf_cache(client, items)
    local path = shelf_cache_path(client)
    if not path then
        logger.err("shelf cache: no data dir, not writing")
        return
    end
    -- Same encoder client.lua uses, so no new dependency is introduced.
    local ok, raw = pcall(Json.encode, { items = items, saved_at = os.time() })
    if not ok or type(raw) ~= "string" then
        logger.err("shelf cache: encode failed. err=", tostring(raw))
        return
    end
    local f = io.open(path, "wb")
    if not f then
        logger.err("shelf cache: cannot open for write", path)
        return
    end
    f:write(raw)
    f:close()
    logger.info("shelf cache: wrote", tostring(#items), "items to", path)
end

--- Load the shelf.
--- @param page page number, default 1
--- @param opts {force=boolean, quiet=boolean}. Without force the on-disk cache
--- is painted first and NO request is made when it is present, so re-entering
--- the shelf is instant and works offline. With force (the refresh button) the
--- network is hit and the cache is rewritten on success. `quiet` means "this
--- shelf is only the backdrop of a running download": never start a fetch
--- (its full-screen overlay would sit under the task dialog for the whole job),
--- and show what the cache has.
function LibraryMenu:load_bookshelf(page, opts)
    local st = self.state
    local client = self:_client()
    opts = opts or {}
    if not client or not client:hasSession() then
        logger.err("bookshelf: no session, cannot load")
        local login = self.deps.on_request_login
        if login then login() end
        return
    end
    logger.info("bookshelf: load page=", tostring(page),
        "force=", tostring(opts.force == true),
        "quiet=", tostring(opts.quiet == true))
    st.mode = "bookshelf"
    st.title = _("我的书架")
    st.page = tonumber(page) or 1

    if opts.quiet then
        local cached = read_shelf_cache(client)
        if cached and #(cached.items or {}) > 0 then
            st.items = cached.items
            st.has_more = false
            st.from_cache = true
        end
        self:_refresh()
        return
    end

    if not opts.force then
        local cached = read_shelf_cache(client)
        if cached and #(cached.items or {}) > 0 then
            st.items = cached.items
            st.has_more = false
            st.from_cache = true
            self:_refresh()
            return
        end
    end

    self:_fetch(_("获取书架"), function()
        local data, err = client:fetchBookshelf(st.page, { timeout = 30 })
        if not data then
            return { error = err }
        end
        return { data = data }
    end, function(value)
        if not value or value.error then
            local reason = tostring(value and value.error or "unknown")
            logger.err("bookshelf refresh failed:", reason,
                "page=", tostring(st.page))
            -- Keep whatever is already on screen. Previously the branch above
            -- left the list exactly as it was but said nothing, and the branch
            -- here replaced a usable cached shelf with a bare dialog. A failed
            -- refresh must never cost the reader their list.
            UIManager:show(InfoMessage:new{
                text = _("获取书架失败：") .. reason,
            })
            return
        end
        -- bff returns `list`; the web parser accepts items ?? list ?? cards.
        local payload = value.data or {}
        local list = payload.list or payload.items or payload.cards or {}
        logger.info("bookshelf refresh ok. page=", tostring(st.page),
            "items=", tostring(#list))
        st.items = normaliseShelf(list)
        st.has_more = #list >= SHELF_PAGE_SIZE
        st.from_cache = false
        if st.page == 1 then
            write_shelf_cache(client, st.items)
            -- A forced refresh is where brand-new signed cover URLs arrive, so
            -- this is the moment to forgive the previous session's failures.
            -- Without it, every key that 403'd or 512'd during the outage stayed
            -- permanently blacklisted and its cover never came back.
            if opts.force == true and self._artifact_failed then
                local forgotten = 0
                for _key in pairs(self._artifact_failed) do
                    forgotten = forgotten + 1
                end
                if forgotten > 0 then
                    logger.info("shelf: clearing", tostring(forgotten),
                        "cover failures after a successful refresh")
                end
                self._artifact_failed = {}
                Cover.reset_reported()
            end
        end
        self:_refresh()
    end)
end

-- ---------------------------------------------------------------- lifecycle

--- 读者定下的页脚规则（2026-10-24）：**四只猫任何情况下都要在**，灰=该方向
--- 当前不可翻。b26/b27 之后三个模式（书架/搜索/分类）的条目都在发起时取全、
--- 由菜单本地分页，onNextPage/onPrevPage 的服务器翻页重载整体作废（旧分支
--- 从不同步 self.page，显示永远停在第 1 页、中间两只猫失灵），这里不再定义，
--- 直接继承 KOReader Menu 的原生实现：四猫常驻、边界灰态准确。

function LibraryMenu:onCloseWidget()
    self:_idle()
    -- Read by the background thumbnail pass: a worker callback that lands after
    -- the menu is gone must not rebuild rows on a closed widget. Same guard
    -- fanqie's ShelfMenu keeps as _miu_closed.
    self._closed = true
    Menu.onCloseWidget(self)
    return true
end

--- Entry point, mirroring fanqie's ShelfView.show(opts).
function LibraryMenu.show(opts)
    opts = opts or {}
    local menu = LibraryMenu:new{
        title = opts.title or _("轻之国度"),
        item_table = {},
        items_per_page = opts.items_per_page or 7,
        is_borderless = true,
        -- 只当背景用：不联网、不起加载遮罩、不排封面任务。
        quiet = opts.quiet == true,
        deps = {
            client = opts.client,
            -- Settings instance, used to locate covers under the plugin data dir.
            settings = opts.settings,
            worker = opts.worker,
            on_open_book = opts.on_open_book,
            on_request_login = opts.on_request_login,
            on_publish_all = opts.on_publish_all,
        },
        state = {
            mode = opts.mode or "menu",
            page = 1,
            items = {},
            has_more = false,
            query = opts.query or "",
        },
    }
    menu:_refresh()
    UIManager:show(menu)
    local mode = opts.mode or ""
    if mode == "search" and (opts.query or "") ~= "" then
        menu:run_search(1)
    elseif mode == "bookshelf" then
        menu:load_bookshelf(1, { quiet = opts.quiet == true })
    end
    return menu
end

return LibraryMenu
