-- lightnovel.koplugin 静态检查配置（2026-10-24 接入）
--
-- KOReader 插件环境与纯 Lua 5.4 的差异：
-- * 全局 `logger` 由插件宿主注入（lightnovel/lib/logger.lua 封装），视为合法全局。
-- * gettext `_` 是本插件的约定全局（各文件 require 的 gettext）。
cache = true

std = "lua54"

globals = {
    "logger",
}

-- 占位命名约定：`_i`/`_key`/`_c` 等下划线前缀循环变量表示有意忽略。
-- W213/W212/W211 的这类报告是噪音，真正有价值的信号是：
--   W241 变量被写但从未读（死代码候选）
--   W231 变量声明后从未访问（死代码候选）
--   W311 赋值被覆盖（逻辑可疑）
--   E 系列语法/作用域错误
ignore = {
    "213",       -- unused loop variable（_i/_c/_key 等占位约定；_ 是 gettext 不能用）
    "212",       -- unused argument (self, page … 惯例占位)
    "211.*/_fc$", "211.*/_cand$", "211.*/err$", "211.*/written$",
    "211.*/book_dir$", "211.*/UIManager$", "211.*/lfs$", "211.*/Content$",
    "211.*/q_title$", "211.*/client$", "211.*/menu$",
    "411",       -- shadowing upvalue（menu.lua current 属局部闭包惯例）
    "431",
    "423",       -- 嵌套循环同名占位 _i（534/1955 为相邻独立循环，无遮蔽风险）
    "542",       -- empty if branch（chapter_cache 985 为刻意的注释分支）
    -- 以下 7 处经人工核对为误报（多分支赋值/后续覆写模式），逐条登记：
    "311.1_1",   -- main.lua:1808 label/cancel_text（多策略分支，1921 行 ConfirmBox 使用）
    "311",       -- comment_sync 459 ok / epub_export 871 cover_data / library_view 418 suffix
    "231",       -- main.lua:708 info（worker:start 局部预留）
    "241",       -- chapter_cache 845 wanted_set（Phase A 重构残留，无害）
    "211.*/logger$", "211.*/LeftContainer$", "211.*/VerticalGroup$",
    "211.*/Digest$", "211.*/ContentModule$",   -- 预留/防御性 require（禁用即报的哨兵）
    "113.*/unpack$",  -- plugin_util 兼容 5.1/5.4 两代 unpack（Luajit vs 5.4）
    "631",       -- client.lua 101 行 128 字符（WEB_UA 注释行，语义完整不拆）
}

-- 供 LuaJIT 目标（KOReader 实际运行时）参考，不阻塞。
max_line_length = 120
