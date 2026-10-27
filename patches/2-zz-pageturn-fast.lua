--[[
  2-zz-pageturn-fast.lua（翻页极速刷新 / DU 纯黑白，默认关闭）

  开关：菜单 → 设置 →「翻页优化」子菜单（阅读器菜单和文件管理器菜单都注入了）
    · 翻页极速刷新（DU）               总开关，也可用 /mnt/us/koreader/_fastpage.on 标记文件
    · 图片页也走 DU（更快，插图 1-bit）  默认关；关时含图页面自动走 GL16
    · 整屏全刷间隔（页）                0 = 从不全刷；越大越少闪，但残影更久

  为什么只有纯黑白：本机 Kindle Basic 4 (MTK) 的 DU 路径只有挂
  FORCE_MONOCHROME（阈值化）是正路。dither=true 时驱动 flags=0，
  8bit 灰图裸丢给 2bit 波形，边缘糊；强挂 Y4 抖动则边缘成麻点且刷新
  会被挂起（页面不动）。实测 2026-10-24，两档实验路径均已删除。
]]--

local UIManager = require("ui/uimanager")
local logger = require("logger")

-- b35：强制波形档位 Level 2（fast=真 DU）。
--
-- wf_level 默认 0 档下 fast 映射 GC16（灰阶慢波），DU 开关形同虚设
-- （读者实测"两种没区别、都有点慢"）。且直写 settings.reader.lua 会被
-- KOReader 退出时的整文件回写冲掉（20:47 实测丢失）。
-- 时机坑（20:53 实测）：patch 加载在启动早期，Screen.wf_level_max 尚未由
-- framebuffer init 设为 3，立即判定会静默跳过。改为惰性：第一次
-- _refresh（framebuffer 必已就绪）时检查并强制一次。
-- b38（撤销 wf_level 逻辑）：追读 framebuffer_mxcfb.lua 893-900 行定案——
-- Kindle MTK 分支**硬编码** waveform_fast = MTK_WAVEFORM_MODE_DU，wf_level
-- 档位机制是 PocketBook/remarkable 专用的（Kindle 上 wf_level_max 恒 0，
-- 条件永不满足），b35-b37 三轮"强制 wf_level"全部扑空且不必要——
-- "fast" 在本机一直是真 DU（1-bit）。读者感知的"两种没区别/都有点慢"
-- 是 DU 与 GL16 在此屏上的实际体感差距本就有限，不是配置问题。
-- 函数保留为空实现，调用点不动，留档防回归。
local function force_wf_level_once()
    -- no-op since b38
end

-- b49 观测 + 队列后置修正 ------------------------------------------------
--
-- 事实（b48 日志）：同一轮翻页里图页先拿 wf=4（GLR16 灰阶），随后又被一次
-- 全屏 wf=1（DU + FORCE_MONOCHROME）覆盖。b49 做两件事：
--   ① 把"第二次 DU 是谁发的"钉死：每次全屏 _refresh 记序号 + 调用栈，
--      驱动层 MECH 带同一序号 + 调用栈（只对 wf≠257 打，量很小）。
--   ② 不再相信队列时刻的 img_count/img_coverage —— paintTo 之前它还是
--      上一页的值 —— 改为在 paintTo **之后**、_repaint 真正下发**之前**
--      用刚画完这页的 img_count 复查刷新队列，按需把 fast↔partial 互相修正。
--      这一步与"谁是元凶"无关：哪怕没抓到源头，画质也能先修好。
local FASTPAGE_LOG_ENTRY = 60
local FASTPAGE_LOG_MECH = 60
local FASTPAGE_LOG_FIX = 60
local refresh_seq = 0
local log_entry_left = FASTPAGE_LOG_ENTRY
local log_mech_left = FASTPAGE_LOG_MECH
local log_fix_left = FASTPAGE_LOG_FIX

local function compact_stack(levels)
    local ok, tb = pcall(debug.traceback, "", 3)
    if not ok or type(tb) ~= "string" then return "?" end
    tb = tb:gsub("^stack traceback:\n?", "")
    local out = {}
    for line in tb:gmatch("[^\n]+") do
        line = line:gsub("^%s+", "")
        if line ~= "" then
            out[#out + 1] = line
            if #out >= (levels or 6) then break end
        end
    end
    return table.concat(out, " <- ")
end

local function reader_view()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok or not ReaderUI or not ReaderUI.instance then return nil end
    return ReaderUI.instance.view
end

local function reader_page_has_images()
    local view = reader_view()
    if not view then return false end
    -- KOpt（PDF/图片书）走 paging 分支，img_count 恒为 0，不能当"无图"用。
    if view.ui and view.ui.paging then return false end
    -- b50：优先用按页缓存的统计（img_count 同页重绘时会归 0，不可信）。
    local st = view._fastpage_stats
    if st then return (tonumber(st.count) or 0) > 0 end
    return (tonumber(view.img_count) or 0) > 0
end

-- b50：按页缓存图片统计。
--
-- 实测（b49 日志）：同一页连续重绘时 crengine 的 drawCurrentPage() 会交替
-- 返回 (1, 0.568) / (0, 0)。因为只有真正重新排版的那次才统计图片，同页原地
-- 重绘只做 blit。拿 0 当"这页没图"就会把图页反复打回 DU（黑白）——读者看到的
-- "先黑白再变灰"正是这个来回。
-- 因此按页码缓存：页码变了才采信新值（换页时 crengine 必定重排），同页重绘
-- 只在读到更大值时更新，绝不把已知的"有图"覆盖成 0。
local function page_stats(view)
    local page = -1
    local ok, p = pcall(function() return view.document:getCurrentPage() end)
    if ok and type(p) == "number" then page = p end
    local cnt = tonumber(view.img_count) or 0
    local cov = tonumber(view.img_coverage) or 0
    local st = view._fastpage_stats
    if not st or st.page ~= page then
        st = { page = page, count = cnt, coverage = cov }
        view._fastpage_stats = st
    elseif cnt > (tonumber(st.count) or 0) then
        st.count, st.coverage = cnt, cov
    end
    return st
end

local function region_is_fullscreen(region)
    if not region then return true end
    local Device = require("device")
    local Screen = Device.screen
    return region.w >= Screen:getWidth() - 2 and region.h >= Screen:getHeight() - 2
end

local function reader_on_top()
    local view = reader_view()
    if not view or not view.dialog then return false end
    local UIManager = require("ui/uimanager")
    return UIManager:getTopmostVisibleWidget() == view.dialog
end

-- b47 观测（只读，不改行为）：dump 驱动层波形常量的真实数值。
--
-- 前六轮全在猜 mode 名的语义，这次直接读实际映射：Screen.waveform_* 的
-- 数值 + MTK 常量表。一次翻页即可确认 partial 究竟映射到什么波形、
-- 以及我们的 mode 字符串最终是否真的送到那个波形。
local wf_dumped = false
local function dump_waveforms_once()
    if wf_dumped then return end
    wf_dumped = true
    pcall(function()
        local Device = require("device")
        local Screen = Device.screen
        logger.info("fastpage WAVEFORMS: fast=", tostring(Screen.waveform_fast),
            " partial=", tostring(Screen.waveform_partial),
            " full=", tostring(Screen.waveform_full),
            " ui=", tostring(Screen.waveform_ui),
            " flashui=", tostring(Screen.waveform_flashui),
            " a2=", tostring(Screen.waveform_a2))
        pcall(function()
            local C = require("ffi/mxcfb_mtk_h")
            logger.info("fastpage MTK consts: MTK_DU=",
                tostring(C.MTK_WAVEFORM_MODE_DU),
                " MTK_GLR16=", tostring(C.MTK_WAVEFORM_MODE_GLR16),
                " GL16=", tostring(C.WAVEFORM_MODE_GL16),
                " GC16=", tostring(C.WAVEFORM_MODE_GC16),
                " AUTO=", tostring(C.WAVEFORM_MODE_AUTO))
        end)
        logger.info("fastpage hw_dither=", tostring(Screen:canHWDither()),
            " scrolling=", tostring(require("ui/uimanager").currently_scrolling))
    end)
    -- b48 终极观测：hook 驱动层 mech_refresh，打印实际送进驱动的波形数值。
    -- 这一步能直接看出"透传"到底送了什么波形给硬件，不再依赖上层推测。
    -- b49：加刷新序号 + 调用栈（只对非 AUTO 的 wf 打栈，避免刷屏），
    -- 这样每条 wf=1（DU）都能对回"是哪个 _refresh 调用点发的"。
    pcall(function()
        local Device = require("device")
        local Screen = Device.screen
        local orig_mech = Screen.mech_refresh
        if type(orig_mech) ~= "function" then return end
        Screen.mech_refresh = function(fb, is_flashing, waveform_mode, x, y, w, h, dither)
            local head = string.format("fastpage MECH R#%d wf=%s flashing=%s dither=%s region=%sx%s",
                refresh_seq, tostring(waveform_mode), tostring(is_flashing),
                tostring(dither), tostring(w), tostring(h))
            if waveform_mode ~= 257 and log_mech_left > 0 then
                log_mech_left = log_mech_left - 1
                logger.info(head, " STACK: ", compact_stack(6))
            else
                logger.info(head)
            end
            return orig_mech(fb, is_flashing, waveform_mode, x, y, w, h, dither)
        end
    end)
end

local FAST_FLAG = "/mnt/us/koreader/_fastpage.on"
local IMAGE_COVERAGE_GL16 = 0.05

local last_check_s = -1
local enabled = false

local function flag_present()
    local f = io.open(FAST_FLAG, "r")
    if f then
        f:close()
        return true
    end
    return false
end

local function set_flag(on)
    if on then
        local f = io.open(FAST_FLAG, "w")
        if f then
            f:write("1\n")
            f:close()
        end
    else
        os.remove(FAST_FLAG)
    end
    last_check_s = -1
end

local function refresh_flag(force)
    local now_s = os.time()
    if force or now_s ~= last_check_s then
        last_check_s = now_s
        enabled = flag_present()
    end
end

local function du_on_images()
    return G_reader_settings:isTrue("pageturn_du_images")
end

-- 图片页判定（2026-10-24 修正）。
--
-- 旧实现读 view.img_coverage 并在 pcall 失败时按"有图"放行——实测两个坑：
-- ① CRe 翻页时 _refresh 触发早于新页 paintTo 写入 img_coverage，读到的是
--   上一页的旧值（纯文字页=0）→ 插图页被判成无图误走 DU，图变 1-bit，
--   直到任意整刷（如开菜单）才恢复灰阶（读者实拍 125/207 插图页三连照）；
-- ② pcall 失败兜底为 true 的方向也错：宁误走 GL16 不该误走 DU。
-- 改用 KOReader 自己的图页信号：ReaderView:paintTo 发现插图覆盖后置
-- dialog.dithered（readerview.lua:281-283），CRe 翻页在请求刷新时已经带上
-- dither=true。所以：dither 参数为真 or dialog.dithered 为真 = 图片页，
-- 一律放行 GL16；二者皆无才是纯文字页，可走 DU。pcall 失败按"有图"处理
-- （保守方向：牺牲速度保画质）。
local function page_is_image_page(dither)
    if dither then return true end
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok or not ReaderUI or not ReaderUI.instance then return true end
    local view = ReaderUI.instance.view
    if not view then return true end
    local coverage = tonumber(view.img_coverage) or 0
    local img_count = tonumber(view.img_count) or 0
    local dialog_dithered = view.dialog and view.dialog.dithered or false
    -- b40 诊断打点（临时 INFO）：读者报"文字+大图（>5%）仍走 DU"，
    -- 需要看 img_count/coverage 在混合页的真实值。
    local logger_ok, logger = pcall(require, "logger")
    if logger_ok and logger then
        logger.info("fastpage judge: img_count=", tostring(img_count),
            " coverage=", string.format("%.3f", coverage),
            " dithered=", tostring(dialog_dithered),
            " dither_param=", tostring(dither),
            " drawn=", tostring(view.state and view.state.drawn))
    end
    -- b40（读者报"文字和图片共存的情况还是 DU"）：旧判定只看覆盖率
    -- ≥5%，文字+小图的页（图占屏 <5%）被判成纯文字页走 DU，小图被
    -- 1-bit 化。改为 img_count > 0 即图页——哪怕一张装饰图也不吃 DU。
    -- img_count 与 img_coverage 同在 paintTo 里由 getDrawnImagesStatistics
    -- 更新（readerview.lua:274-278），时序一致。
    if img_count > 0 then return true end
    if dialog_dithered then
        return coverage >= IMAGE_COVERAGE_GL16 * 0.5
    end
    return coverage >= IMAGE_COVERAGE_GL16
end

-- b49：paintTo 结束后按"刚画完这一页"的真值修正刷新队列。
--
-- 时序（uimanager.lua:1220-1321）：setDirty 先把 mode 写进 _refresh_stack →
-- _repaint 先 paintTo（此时 readerview.lua:274 才把新页的 img_count /
-- img_coverage 写进 view）→ 最后才按下发队列执行。也就是说队列里的 mode
-- 是在**旧页数据**上做的决定。这里在 paintTo 返回的瞬间把队列重判一次：
--   有图 → partial（MTK=GLR16 灰阶）；无图 → fast（MTK=DU 极速）。
-- 只在阅读器是顶层窗口、且不在滚动中时生效，避免影响菜单/翻页动画。
local function adjust_queued_refreshes(view, st)
    if not enabled or du_on_images() then return end
    -- 只对 CRe（EPUB）生效：KOpt 的 img_count 恒 0，降级会把 PDF 页面打成 1-bit。
    if view.ui and view.ui.paging then return end
    local UIManager = require("ui/uimanager")
    if UIManager.currently_scrolling then return end
    if not (view.dialog and UIManager:getTopmostVisibleWidget() == view.dialog) then
        return
    end
    local stack = UIManager._refresh_stack
    if type(stack) ~= "table" then return end
    local img_count = st and tonumber(st.count) or 0
    local coverage = st and tonumber(st.coverage) or 0
    local want = img_count > 0 and "partial" or "fast"
    for _, entry in ipairs(stack) do
        local m = entry.mode
        if (m == "partial" or m == "fast") and region_is_fullscreen(entry.region)
            and m ~= want then
            entry.mode = want
            if want == "fast" then
                -- DU + dither 在 MTK 上是 Y4 抖动（b41 实测发糊），必须清掉。
                entry.dither = nil
            end
            if log_fix_left > 0 then
                log_fix_left = log_fix_left - 1
                logger.info(string.format(
                    "fastpage FIX R#%d %s->%s page=%s img_count=%d coverage=%.3f STACK: %s",
                    refresh_seq, m, want, tostring(st and st.page), img_count, coverage,
                    compact_stack(6)))
            end
        end
    end
end

pcall(function()
    local ReaderView = require("apps/reader/modules/readerview")
    local orig_paint_to = ReaderView.paintTo
    if type(orig_paint_to) ~= "function" then return end
    function ReaderView:paintTo(bb, x, y)
        local r = orig_paint_to(self, bb, x, y)
        pcall(function()
            local st = page_stats(self)
            adjust_queued_refreshes(self, st)
        end)
        return r
    end
end)

local orig_refresh = UIManager._refresh
-- b32：全刷计数只认翻页（读者要求"菜单/按键不整刷"）。
--
-- KOReader 原生把每次全屏 partial 都计入 FULL_REFRESH_COUNT（uimanager.lua
-- 1163-1174），开/关菜单也是全屏 partial——设 10 页时每 5 次操作就被升级成
-- 一次 full 黑闪，读者感知为"其他按键每次都刷新"。改为：补丁接管计数，
-- 只有**阅读器翻页**（onPageUpdate 事件）递增；菜单/按键的 partial 一律
-- 降为 "ui"（灰阶、无闪、不计数）。翻页满阈值时由补丁主动请求一次 full，
-- 语义回到"每 N 页整刷一次"的本意。
local page_refresh_count = 0
local page_turn_count = 0

local function on_page_turn()
    page_turn_count = page_turn_count + 1
    local rate = tonumber(G_reader_settings:readSetting("full_refresh_count")) or 10
    if rate > 0 and page_turn_count >= rate then
        page_turn_count = 0
        return true -- 本页翻页用 full 整刷
    end
    return false
end

-- 只在阅读器里监听翻页事件；文件管理器没有 onPageUpdate，天然不计数。
-- 注意：onPageUpdate 是 ReaderView 的方法（readerview.lua:1011），不是
-- ReaderUI 的——b32 首版挂错了类，type 校验直接 return，钩子从未生效，
-- 所有翻页刷新掉进非翻页分支被降成 ui（读者实测"翻页不是 DU 了"）。
local page_turn_hooked = false
pcall(function()
    local ReaderView = require("apps/reader/modules/readerview")
    local orig_on_page_update = ReaderView.onPageUpdate
    if type(orig_on_page_update) ~= "function" then return end
    function ReaderView:onPageUpdate(new_page_no)
        -- 翻页事件先于本轮刷新到达：标记"这是翻页"。
        self._fastpage_is_page_turn = true
        return orig_on_page_update(self, new_page_no)
    end
    page_turn_hooked = true
end)
UIManager._refresh = function(self, mode, region, dither)
    refresh_flag(false)
    force_wf_level_once()
    dump_waveforms_once()
    -- b45 全链路打点：入口 mode / 是否带 region / currently_scrolling，
    -- 以及图页命中的最终 mode。一次翻页即可定案（前几轮靠猜浪费太多轮次）。
    -- b49：加序号 + 调用栈（仅全屏刷新），把"第二次 DU 是谁发的"钉死。
    refresh_seq = refresh_seq + 1
    local seq = refresh_seq
    local mode_in, region_in, scroll_in = mode, region and "yes" or "no",
        tostring(self.currently_scrolling)
    local mode_out = "--"
    if not region and log_entry_left > 0 then
        log_entry_left = log_entry_left - 1
        local entry_view = reader_view()
        logger.info(string.format(
            "fastpage R#%d in=%s dither=%s enabled=%s scroll=%s pageturn=%s",
            seq, tostring(mode), tostring(dither), tostring(enabled),
            tostring(self.currently_scrolling),
            tostring(entry_view and entry_view._fastpage_is_page_turn)))
        logger.info(string.format("fastpage R#%d STACK: %s", seq, compact_stack(7)))
    end
    if enabled and mode == "partial" and not region then
        -- b43（读者改选画质）：图页走 full 整刷（GC16 灰阶，闪一下），
        -- 文字页走 DU 极速。
        --
        -- b42 曾全走 DU（不闪），读者后改主意："有图的弄成闪吧"。原因：
        -- MTK fast mode 下 partial 永远 1-bit，唯一灰阶路径是 full。
        -- KOReader 原生对 >7.5% 覆盖的图页本来就会自动 full（闪+清晰），
        -- 我们的补丁之前把它拦下来转 DU 导致图糊。现在恢复正确行为：
        -- 有图 → full（画质）；无图 → DU（速度）。
        local is_image = false
        do
            local ok, result = pcall(page_is_image_page, dither)
            is_image = (not ok) or result
        end
        if is_image then
            -- b46（源码定案·终版）：图页**原样透传 partial**。
            --
            -- framebuffer_mxcfb.lua:893-901（Kindle MTK 分支）：
            --   waveform_fast    = MTK_WAVEFORM_MODE_DU    → 1-bit 黑白
            --   waveform_partial = MTK_WAVEFORM_MODE_GLR16 → **REAGL 灰阶**
            --   waveform_full    = WAVEFORM_MODE_GC16      → 灰阶
            -- 即：原生的 partial 本来就是灰阶！b32 起把图页 partial 改成
            -- fast(DU) 才是"图变黑白"的唯一原因；b39-b45 的 ui/flashui/full
            -- 全是在绕这个自造的问题。
            -- 唯一需要防的：uimanager.lua:1130 在 currently_scrolling 为真时
            -- 把一切降 fast —— 清掉它，让真正的 partial(GLR16) 走到驱动。
            UIManager.currently_scrolling = false
            -- b49：翻页标记在两个分支都要消费掉。旧版只在文字分支清，
            -- 图页之后这个标记会一直挂着，把下一次全屏刷新误当成翻页。
            local inst = reader_view()
            if inst then inst._fastpage_is_page_turn = nil end
            return orig_refresh(self, mode, region, dither)
        elseif page_turn_hooked
            and (function()
                local ReaderUI = require("apps/reader/readerui")
                local inst = ReaderUI and ReaderUI.instance
                local view = inst and inst.view
                if view and view._fastpage_is_page_turn then
                    view._fastpage_is_page_turn = nil
                    page_turn_count = page_turn_count + 1
                    return true
                end
                return false
            end)() then
            -- 翻页（含图页）：DU 极速；满阈值时本页升级 full 整刷。
            local rate = tonumber(G_reader_settings:readSetting("full_refresh_count")) or 10
            if rate > 0 and page_turn_count >= rate then
                page_turn_count = 0
                mode = "full"
                dither = true
            else
                dither = false
                mode = "fast"
            end
        else
            -- 菜单/按键等非翻页全屏刷新：降为 "ui"——灰阶、无黑闪、
            -- 且不再被 KOReader 原生计数器升级成 full（ui 不进计数）。
            mode = "ui"
        end
    end
    -- b49 队列期修正：只做 fast→partial（单方向）。
    --
    -- 这里 img_count 可能仍是上一页的值，所以只允许"往保守方向修"：
    -- 一旦读到有图就升成 partial(灰阶)，绝不在这里把 partial 降成 fast
    -- （降级只放在 paintTo 之后按新页真值做，见 adjust_queued_refreshes）。
    if enabled and not du_on_images() and not region and not self.currently_scrolling
        and mode == "fast" and reader_on_top() and reader_page_has_images() then
        local fix_view = reader_view()
        mode = "partial"
        if log_fix_left > 0 then
            log_fix_left = log_fix_left - 1
            logger.info(string.format(
                "fastpage FIXQ R#%d fast->partial img_count=%d STACK: %s",
                seq, tonumber(fix_view and fix_view.img_count) or 0, compact_stack(6)))
        end
    end
    if mode ~= mode_in then
        logger.info("fastpage refresh R#" .. seq .. ": ", mode_in, "(region=", region_in,
            ", scroll=", scroll_in, ") -> ", mode,
            " is_image_path=", tostring(mode == "flashui"))
    end
    return orig_refresh(self, mode, region, dither)
end

-- 菜单入口 ---------------------------------------------------------------
-- 同时注入阅读器菜单和文件管理器菜单的「设置」标签：
-- 两边长得一模一样，只注一边用户根本分不清，索性都放。
pcall(function()
    local ReaderMenu = require("apps/reader/modules/readermenu")
    local FileManagerMenu = require("apps/filemanager/filemanagermenu")
    local InfoMessage = require("ui/widget/infomessage")
    local SpinWidget = require("ui/widget/spinwidget")
    local _ = require("gettext")

    -- 每次注入都新建条目表，避免两个菜单共享同一组闭包表对象
    local function make_items()
        local function master_on()
            refresh_flag(true)
            return enabled
        end
        return {
            {
                text = "翻页优化",
                sub_item_table = {
                    {
                        text = "翻页极速刷新（DU）",
                        checked_func = master_on,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            local now_on = not master_on()
                            set_flag(now_on)
                            if touchmenu_instance and touchmenu_instance.updateItems then
                                touchmenu_instance:updateItems()
                            end
                            UIManager:show(InfoMessage:new{
                                text = now_on and "翻页极速刷新：开" or "翻页极速刷新：关（GL16）",
                                timeout = 2,
                            })
                        end,
                    },
                    {
                        text = "图片页也走 DU（更快，插图 1-bit）",
                        checked_func = function() return du_on_images() end,
                        enabled_func = master_on,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            G_reader_settings:saveSetting("pageturn_du_images", not du_on_images())
                            if touchmenu_instance and touchmenu_instance.updateItems then
                                touchmenu_instance:updateItems()
                            end
                            UIManager:show(InfoMessage:new{
                                text = du_on_images() and "图片页：DU（最快，插图 1-bit）" or "图片页：GL16",
                                timeout = 2,
                            })
                        end,
                    },
                    {
                        text_func = function()
                            local n = UIManager.FULL_REFRESH_COUNT or 0
                            return n > 0 and string.format("整屏全刷间隔（%d 页）", n) or "整屏全刷间隔（从不）"
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            local spin = SpinWidget:new{
                                title_text = "整屏全刷间隔（页）",
                                info_text = "0 = 从不整屏全刷；越大越少闪，残影保留更久",
                                value = UIManager.FULL_REFRESH_COUNT or 0,
                                value_min = 0,
                                value_max = 200,
                                value_step = 1,
                                default_value = 22,
                                callback = function(spin_widget)
                                    UIManager:setRefreshRate(spin_widget.value)
                                    touchmenu_instance:updateItems()
                                end,
                            }
                            UIManager:show(spin)
                        end,
                    },
                },
            },
        }
    end

    -- MenuSorter 最后会把顶层 tab 替换成它的 sub_item_table，
    -- 即 tab 本身就是条目数组（touchmenu 直接 item_table = tab_item_table[i]），
    -- 必须往 tab 里插，tab.sub_item_table 并不存在
    local function inject(tabs, tag)
        if type(tabs) ~= "table" then return end
        for _, tab in ipairs(tabs) do
            if tab.id == "setting" and type(tab) == "table" and #tab > 0 then
                local items = make_items()
                for i = #items, 1, -1 do
                    table.insert(tab, 2, items[i])
                end
                logger.info("pageturn-fast: DU items injected into " .. tag .. " settings tab (" .. #tab .. " items)")
                return
            end
        end
        logger.warn("pageturn-fast: no settings tab found for " .. tag)
    end

    local function wrap(menu_cls, tag)
        if type(menu_cls) ~= "table" then return end
        local orig = menu_cls.setUpdateItemTable
        if type(orig) ~= "function" then return end
        menu_cls.setUpdateItemTable = function(self, ...)
            local r = orig(self, ...)
            inject(self.tab_item_table, tag)
            return r
        end
    end

    wrap(ReaderMenu, "reader")
    wrap(FileManagerMenu, "filemanager")
    logger.info("pageturn-fast: b50 loaded (page-keyed image stats + traceback)")
    logger.info("pageturn-fast: menu entries installed (reader + filemanager, mono-only)")
end)
