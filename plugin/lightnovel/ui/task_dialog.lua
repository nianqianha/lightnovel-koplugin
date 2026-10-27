--[[--
Progress dialog for the long jobs, modelled on the weread plugin's DownloadDialog.

Replaces the full-screen `Menu.showLoading` overlay for the three operations that
run for minutes rather than seconds (whole-book cache, EPUB export, merge into the
library). The overlay had no way out: on the device a 58-chapter cache ran from
20:36:40 with the reader unable to do anything until it finished or the device was
rebooted.

Three distinct actions, because they are not the same thing:

  隐藏 Hide     Dismiss the dialog. The job keeps running. The reader gets their
                screen back and can reopen this from the plugin menu.
  暂停 Pause    Stop the worker but keep everything already written to disk. Every
                job here persists per-item progress (chapters as separate files,
                the catalogue before the first body request), so a pause is
                resumable by running the same job again -- which is what 继续 does.
                Reported as a pause, never as a failure.
  退出 Exit     Abandon the job. Reported as a cancellation.

Pause and exit are deliberately not the same button. A pause that reported itself
as a failure would train the reader to distrust a resumable stop, and a cancel that
claimed to be resumable would promise progress that was thrown away.

This widget owns the button set and the running/paused state machine; the caller
supplies four callbacks and a title. It never owns the job itself -- hiding the
dialog must not be able to stop the work by accident.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local logger = require("lightnovel.lib.logger")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local time = require("ui/time")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local _ = require("gettext")

local Screen = Device.screen

local TaskDialog = InputContainer:extend{
    title = "",
    description = nil,
    is_doc_only = false,
    -- Repaint at most this often. On e-ink a repaint per progress event is both
    -- slow and visible as flickering, so progress is coalesced.
    refresh_time_seconds = 1,
}

function TaskDialog:init()
    self.dimen = Screen:getSize()
    self.state = "running"
    self.percentage = 0
    self.progress_total = tonumber(self.progress_total) or 0
    self.last_redraw_at = 0
    self.shown_at = nil
    self.width = Screen:getWidth() - Screen:scaleBySize(80)

    self.title_widget = TextWidget:new{
        text = tostring(self.title or ""),
        face = Font:getFace("ffont"),
        bold = true,
        max_width = self.width,
    }
    self.description_widget = TextWidget:new{
        text = tostring(self.description or ""),
        face = Font:getFace("xx_smallinfofont"),
        max_width = self.width,
    }
    -- Always present, even with no known total: an indeterminate bar still tells
    -- the reader the job is alive, which is the whole reason this dialog exists.
    self.progress_bar = ProgressWidget:new{
        fillcolor = Blitbuffer.COLOR_BLACK,
        width = self.width,
        height = Screen:scaleBySize(18),
        padding = Size.padding.large,
        margin = Size.margin.tiny,
        percentage = 0,
    }
    self.status_widget = TextWidget:new{
        text = "",
        face = Font:getFace("xx_smallinfofont"),
        max_width = self.width,
    }
    self:_rebuild()
end

function TaskDialog:_center_row(widget)
    return CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = widget:getSize().h },
        widget,
    }
end

--- (Re)build the widget tree. Called on init and whenever the button set has to
--- change, because ButtonTable fixes its buttons at construction and there is no
--- supported way to re-label one in place.
function TaskDialog:_rebuild()
    self.button_table = ButtonTable:new{
        width = self.width,
        buttons = self:buttonSpec(),
        zero_sep = true,
        show_parent = self,
    }
    local group = VerticalGroup:new{}
    table.insert(group, self:_center_row(self.title_widget))
    table.insert(group, VerticalSpan:new{ width = Size.padding.small })
    table.insert(group, self:_center_row(self.description_widget))
    table.insert(group, VerticalSpan:new{ width = Size.padding.small })
    table.insert(group, self.progress_bar)
    table.insert(group, VerticalSpan:new{ width = Size.padding.small })
    table.insert(group, self:_center_row(self.status_widget))
    table.insert(group, VerticalSpan:new{ width = Size.padding.large })
    table.insert(group, self.button_table)
    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        FrameContainer:new{
            radius = Size.radius.window,
            bordersize = Size.border.window,
            padding = Size.padding.large,
            padding_bottom = 0,
            background = Blitbuffer.COLOR_WHITE,
            group,
        },
    }
end

--- The button row for the current state.
---
--- 隐藏 is absent while paused: there is no running job to hide, and 退出 already
--- covers leaving. Offering it anyway would imply work continues in the background,
--- which after a pause it does not.
function TaskDialog:buttonSpec()
    if self.state == "paused" then
        return { {
            { text = _("继续"), callback = function() self:onResume() end },
            { text = _("退出"), callback = function() self:onExit() end },
        } }
    end
    return { {
        { text = _("隐藏"), callback = function() self:onHide() end },
        { text = _("暂停"), callback = function() self:onPause() end },
        { text = _("退出"), callback = function() self:onExit() end },
    } }
end

--- @treturn boolean whether the repaint was actually scheduled
---
--- `force` is used for structural changes (title, description, button row) and
--- asks for a FULL refresh. Progress ticks keep "fast": they are frequent and
--- only a bar moves. This distinction is not cosmetic -- on this Kindle a
--- "fast" repaint of a rebuilt button row left the previous labels on screen
--- and erased the new one, which is exactly the "点了暂停还是三个按钮/标题没变"
--- report. A full refresh of the dialog area has no ghosts to misread.
function TaskDialog:_redraw(force)
    local now = time.now()
    if not force then
        -- b38：time.now() 是 `time.monotonic_coarse`，单位**秒**（frontend/ui/time.lua
        -- 里 `time.now = time.monotonic_coarse`）。这里原来拿它去比较
        -- `refresh_time_seconds * 1000 * 1000`（微秒），阈值变成 1e6 秒——于是
        -- 非 force 的刷新永远被拦掉：进度条、状态行、标题全都不重绘，读者看到的
        -- 就是"弹窗卡住/进度不动"。改成直接比秒。
        if now - self.last_redraw_at < self.refresh_time_seconds then
            return false
        end
    end
    self.last_redraw_at = now
    if force then
        UIManager:setDirty(self, function() return "full", self.dimen end)
    else
        -- b37：进度 tick 用 "ui" 而不是 "fast"。这台机器上装了自己的翻页补丁
        -- （2-zz-pageturn-fast.lua 的 DU 强制段），fast 局部刷新会把弹窗擦成
        -- 空白/残影，读者看到的就是"弹窗一闪就没了"，而下一帧只在 force 时
        -- 回来。ui 是 KOReader 里对话框的标准刷新类型：局部、不抖动、不擦字。
        UIManager:setDirty(self, function() return "ui", self.dimen end)
    end
    return true
end

--- 文本变化用普通刷新。
---
--- 只有按钮行被重建（暂停/继续）才值得整屏刷新：批量合并入库按每一本更新标题，
--- 那里用 full 会变成每本闪一下黑屏。整屏刷新由 setState 负责。
function TaskDialog:setTitle(title)
    title = tostring(title or "")
    if self.title == title then return end
    self.title = title
    self.title_widget:setText(title)
    self:_redraw()
end

function TaskDialog:setDescription(text)
    text = tostring(text or "")
    if self.description == text then return end
    self.description = text
    self.description_widget:setText(text)
    self:_redraw()
end

--- Merge a worker progress payload into the bar and the status line.
---
--- `total` is remembered once seen, so a job that restarts its own count (a
--- resumed cache starts from the first missing chapter) cannot make the bar run
--- backwards -- which reads as the job losing work it had already done.
function TaskDialog:reportProgress(state)
    if type(state) ~= "table" then return end
    if state.title then self:setTitle(state.title) end
    if state.description then self:setDescription(state.description) end
    local done = tonumber(state.done)
    local total = tonumber(state.total) or self.progress_total
    local written = tonumber(state.written)
    local failed = tonumber(state.failed)
    if total and total > 0 then
        self.progress_total = total
        self.percentage = math.min(1, math.max(0, (done or 0) / total))
    end
    if self.progress_bar and self.progress_bar.setPercentage then
        self.progress_bar:setPercentage(self.percentage)
    end
    -- 阶段名：读者要的是"现在在干什么"，只给 300/392 还是看不出阶段。
    local STAGE_LABEL = {
        catalog = _("获取目录"),
        export_route = _("取回正文"),
        image_fetch_start = _("下载插图"),
        image = _("下载插图"),
        prefetch = _("预取插图"),
        chapter = _("整理章节"),   -- 渲染/清洗正文，不是打 zip
        pack = _("打包 EPUB"),
        page = _("抓取评论"),
    }
    local parts = {}
    if done and total then
        parts[#parts + 1] = tostring(done) .. "/" .. tostring(total)
    end
    if state.stage and STAGE_LABEL[state.stage] then
        parts[#parts + 1] = STAGE_LABEL[state.stage]
    end
    if written then parts[#parts + 1] = _("已缓存 %s 个"):format(tostring(written)) end
    if failed and failed > 0 then
        parts[#parts + 1] = _("失败 %s 个"):format(tostring(failed))
    end
    -- 没有任何数字可显示时也要说明当前阶段。
    --
    -- 缓存任务先取目录、再取下载清单，之后才逐章下载；整本已缓存的书这两步
    -- 都不产生 done/total，于是很长一段时间弹窗只有一条空进度条和一行空白，
    -- 看上去就是"卡住了、进度条没有"。阶段文案让每一步都有可见反馈。
    if #parts == 0 then
        if state.message then
            parts[#parts + 1] = tostring(state.message)
        elseif state.stage == "catalog" then
            parts[#parts + 1] = string.format(_("正在获取目录（第 %s 页）"),
                tostring(state.page or 1))
        elseif state.stage == "export_route" then
            parts[#parts + 1] = _("正在获取下载清单…")
        elseif state.stage then
            parts[#parts + 1] = _("正在处理…")
        end
    end
    self.status_widget:setText(table.concat(parts, "  "))
    self:_redraw()
end

--- @treturn boolean whether the state actually changed
function TaskDialog:setState(state)
    if state ~= "running" and state ~= "paused" then return false end
    if self.state == state then return false end
    self.state = state
    if state == "paused" then
        self:setTitle(_("已暂停：进度已保留"))
        self:setDescription(_("已下载的内容保留在设备上，可以稍后继续。"))
    else
        self:setDescription("")
    end
    self:_rebuild()
    self:_redraw(true)
    return true
end

function TaskDialog:show()
    -- b38：记下显示时刻。实测有弹窗刚出来就自己消失的情况（crash.log
    -- 18:30:02 打开 → 18:30:03 就 onHide），那是打开它的那次点击被重复派发、
    -- 落到了同一位置的「隐藏」按钮上。1 秒内忽略隐藏请求。
    self.shown_at = time.now()
    UIManager:show(self, "ui")
end

function TaskDialog:close()
    -- 同 hideTaskDialog：关闭要带 "full" + 自身区域，否则墨水屏停在最后一帧。
    UIManager:close(self, "full", self.dimen)
end

-- Each action delegates and logs. These are the three ways a reader can lose a
-- running job, so a silent no-op here would be indistinguishable from a broken
-- button.
function TaskDialog:onHide()
    local since = self.shown_at and (time.now() - self.shown_at) or 99
    if since < 1.0 then
        logger.info("task dialog: ignoring hide right after show, dt=",
            string.format("%.2f", since))
        return
    end
    logger.info("task dialog: hidden, job keeps running")
    local _t0 = os.clock()
    local ok, err = pcall(function()
        if type(self.on_hide) == "function" then self:on_hide() end
    end)
    logger.info("task dialog: onHide handler returned ok=", tostring(ok),
        "ms=", tostring(math.floor((os.clock() - _t0) * 1000)),
        "err=", tostring(err))
end

function TaskDialog:onPause()
    logger.info("task dialog: pause requested")
    local _t0 = os.clock()
    -- 回调的返回值决定界面状态。
    --
    -- 这里原来无条件调用 setState("paused")：worker:pause() 用错任务句柄时会
    -- 直接返回 false（任务照跑），弹窗却已经改成"已暂停/继续"，于是读者点
    -- 继续只是从头再跑一遍，而点暂停看起来"没反应"。只有真的停下来了才切换。
    local ok, paused = pcall(function()
        if type(self.on_pause) == "function" then return self.on_pause() end
        return nil
    end)
    logger.info("task dialog: onPause handler returned ok=", tostring(ok),
        "paused=", tostring(paused),
        "ms=", tostring(math.floor((os.clock() - _t0) * 1000)),
        "err=", tostring(paused))
    if ok and paused == true then
        self:setState("paused")
        return
    end
    -- Do not claim a pause that did not happen. The job keeps running, so the
    -- button row must keep 隐藏/暂停/退出 as well.
    self:setDescription(_("暂停未生效：任务可能已经结束或正在收尾。"))
    self:_redraw(true)
end

function TaskDialog:onResume()
    logger.info("task dialog: resume requested")
    self:setState("running")
    local _t0 = os.clock()
    local ok, err = pcall(function()
        if type(self.on_resume) == "function" then self:on_resume() end
    end)
    logger.info("task dialog: onResume handler returned ok=", tostring(ok),
        "ms=", tostring(math.floor((os.clock() - _t0) * 1000)),
        "err=", tostring(err))
end

function TaskDialog:onExit()
    logger.info("task dialog: exit requested")
    local _t0 = os.clock()
    local ok, err = pcall(function()
        if type(self.on_exit) == "function" then self:on_exit() end
    end)
    logger.info("task dialog: onExit handler returned ok=", tostring(ok),
        "ms=", tostring(math.floor((os.clock() - _t0) * 1000)),
        "err=", tostring(err))
end

return TaskDialog