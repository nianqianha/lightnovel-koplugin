--[[--
把阅读器底部进度条的填充改成纯黑（2026-10-26）。

问题：底部进度条 "时有时无、没有灰色填充"。
根因（源码 + 实测）：
  · 填充色来自 ProgressWidget 的默认 `fillcolor = Blitbuffer.COLOR_DARK_GRAY`
    （frontend/ui/widget/progresswidget.lua 的 extend 表），ReaderFooter 构造
    进度条时没有覆盖它。
  · 本机 Kindle 的 `waveform_fast` 是 MTK_WAVEFORM_MODE_DU（1-bit），我们的翻页
    补丁在文字页又显式 `dither = false`，于是灰色在 1-bit 波形下被抹成白色——
    读者看到的就是"边框在、灰填充不见了"。底栏是单独一条 region 刷新
    （crash.log: `fastpage MECH ... wf=257 region=1072x28`），也会被这条路径吃掉。
做法：只把 ReaderFooter 的进度条填充改成 COLOR_BLACK。黑色在任何波形下都稳定，
代价是失去那一档灰（本来也只有一档）。其它 ProgressWidget 不动——任务弹窗那个
自己就设了黑色。
]]--

local Blitbuffer = require("ffi/blitbuffer")
local logger = require("logger")

local ok, err = pcall(function()
    local ReaderFooter = require("apps/reader/modules/readerfooter")
    local orig_init = ReaderFooter.init
    if type(orig_init) ~= "function" then
        error("ReaderFooter.init is not a function")
    end

    local function blacken(footer)
        local bar = footer and footer.progress_bar
        if not bar then return end
        bar.fillcolor = Blitbuffer.COLOR_BLACK
        -- progress_style_thin 时 init 里会调 updateStyle()，它把 fillcolor 重置回
        -- DARK_GRAY；之后换样式也会再调。包一层，改完颜色再放回去。
        if not bar._zz_fill_black_patched then
            local orig_update = bar.updateStyle
            if type(orig_update) == "function" then
                bar.updateStyle = function(self, ...)
                    local result = orig_update(self, ...)
                    self.fillcolor = Blitbuffer.COLOR_BLACK
                    return result
                end
            end
            bar._zz_fill_black_patched = true
        end
    end

    function ReaderFooter:init()
        local result = orig_init(self)
        blacken(self)
        logger.info("footer: progress bar fill forced to black (DU-safe)")
        return result
    end
end)

if not ok then
    logger.warn("footer-progress-black patch failed:", tostring(err))
end
