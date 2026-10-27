--[[--
HTTP client for the 轻之国度 (lightnovel.fun) JSON API.

The site speaks TWO different API families, and they disagree on both the base
URL and the body shape. Mixing them is the single easiest way to get a silent
`code 3` that never resolves, so both are documented here.

Legacy family (Client:envelope, base https://api.lightnovel.fun) --
verified live 2026-09-30:

  POST /api/category/get-article-by-cate  {parent_gid, gid, page, pageSize>=20}
  POST /api/search/search-result          {q, type, page, page_size}   (needs login)
  POST /api/series/get-article-list       {sid}            -> all volumes of a series
  POST /api/series/get-info               {sid}            -> volume metadata
  POST /api/article/get-detail            {aid, simple:0}  -> chapter text
  POST /api/discuss/get-topic             {aid, page, page_size}       -> comments
  POST /api/user/login                    {username, password}
  POST /api/new-content-read/*            {book_id, ...}  -> volumes/chapters/paragraphs

  Body: {platform,client,sign,ver_name,ver_code,gz,d:{...}} -- params live in `d`.

bff family (Client:postFlat, base https://www.lightnovel.fun/api/pc-proxy) --
verified live 2026-10-02:

  POST /api/bff/bookshelf-v1  {security_key, page, pageSize>=1} -> data.list
  POST /api/bff/auth-session-v1, /api/bff/my-home-v1, /api/bff/get-bookmarks-v1, ...

  Body: {...} FLAT -- no envelope, and no request signature.
  Response uses `data.list`, not `items`.

Observed codes (both families):
  0   ok
  3   parameter rejected (pageSize too small; the message is in data.pageSize)
  5   authentication required (legacy search without a session key)
  8   not logged in (bff family without a valid security_key)
  5001 the aid is not a readable article (forum announcement, or locked)

ID spaces do NOT overlap: a bff `book_id` is not a legacy `aid`, and a
`source_series_id` from the shelf answers code 0 with an empty array when
passed to /api/series/*. Shelf rows therefore cannot be opened through the
legacy article flow -- see LibraryMenu:_open.
--]]--

local logger = require("lightnovel.lib.logger")

local ok_json, Json = pcall(require, "json")
if not ok_json then Json = require("rapidjson") end

local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local lfs = require("libs/libkoreader-lfs")

-- HTTP transport mirrors weread.koplugin/weread/lib/client.lua.
--
-- Why this rewrite: the previous code called `NetworkMgr:request{...}`, which
-- does not exist on this build -- 0 occurrences across all 457 frontend .lua
-- files, and `ui/network/manager.lua` defines its methods directly on
-- NetworkMgr with no `request`. Every call therefore raised
-- "attempt to call method 'request' (a nil value)", which is why login never
-- completed no matter what the dialogs did. The working reference plugins
-- (weread, fanqie) both use LuaSocket + socketutil instead.
local socketutil = require("socketutil")
local http = require("socket.http")
local ltn12 = require("ltn12")

local Client = {}
Client.__index = Client

local BASE_URL = "https://api.lightnovel.fun"

-- Two distinct API families live on this site, and they disagree on BOTH the
-- base URL and the request body shape. Verified live 2026-10-02:
--
--   legacy family  POST https://api.lightnovel.fun/api/<x>
--                  body = {platform,client,sign,ver_name,ver_code,gz,d:{...}}
--                  (Client:envelope). Login, category, search, volumes,
--                  article text and comments all use this one.
--
--   bff family     POST https://www.lightnovel.fun/api/pc-proxy/api/bff/<x>-v1
--                  body = {...} FLAT, no envelope, and NO request signature.
--                  The web client picks the base from runtime config; when it is
--                  unset it defaults to the literal "/api/pc-proxy", which makes
--                  its own guard `baseUrl !== "/api/pc-proxy"` false and turns
--                  signing OFF. pcApiSignSecret is not present in the public
--                  config at all, so signing cannot be reproduced -- but it is
--                  also not required.
--
-- Posting the bff body to api.lightnovel.fun directly answers
-- code 3 "Page Size must be >= 1" no matter which spelling of the page size is
-- used (pageSize / page_size / query string), because that host expects the
-- legacy envelope. Going through the /api/pc-proxy prefix returns code 0.
local BFF_BASE_URL = "https://www.lightnovel.fun/api/pc-proxy"

-- The Android app identifies itself with a Dart UA. The site also serves a
-- desktop UI to unknown agents, so we keep the app UA to stay on the API shape.
local APP_UA = "Dart/3.8 (dart:io)"

-- Used for the website's own forwarder (/api/pc-proxy), which fronts the legacy
-- endpoints that the Dart app signs. Requests through it must look like the
-- site's, not like the app.
local WEB_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

local VER_NAME = "0.11.53"
local VER_CODE = 193

-- Content categories used by the official app.
local CATEGORY = {
    NOVEL = 2,
    COMIC = 5,
    ANIME = 4,
    NEWS = 3,
    ALL = 0,
}

-- Browse category ids (parent_gid=3 is 轻小说).
local BROWSE = {
    latest   = { parent_gid = 3, gid = 106 },
    full_vol = { parent_gid = 3, gid = 107 },
    original = { parent_gid = 3, gid = 111 },
    epub     = { parent_gid = 3, gid = 110 },
    download = { parent_gid = 3, gid = 108 },
}

-- The server rejects pageSize below 20; keep every list request at 20.
local LIST_PAGE_SIZE = 20
-- page_size=100 was rejected outright, so legacy comment paging stays at 20.
-- 新内容评论接口（get-book-comments）接受 50，实测可用，页数因此少一半。
local COMMENT_PAGE_SIZE_MAX = 50
local COMMENT_PAGE_SIZE = 20
-- The bff shelf validates pageSize >= 1 (not >= 20 like the legacy list
-- endpoints). The web client defaults to 50, so match it.
local BOOKSHELF_PAGE_SIZE = 50

Client.CATEGORY = CATEGORY
Client.BROWSE = BROWSE

function Client:new(settings)
    local obj = setmetatable({
        settings = settings,
        base_url = BASE_URL,
        session_key = "",
        uses_web_catalog_download = true,
    }, self)
    if settings then
        local auth = settings:get("auth", {}) or {}
        obj.session_key = tostring(auth.security_key or "")
    end
    return obj
end

function Client:setSessionKey(key)
    self.session_key = tostring(key or "")
    if self.settings then
        local auth = self.settings:get("auth", {}) or {}
        auth.security_key = self.session_key
        self.settings:set("auth", auth)
    end
end

function Client:hasSession()
    return self.session_key ~= ""
end

function Client:envelope(d)
    local payload = d or {}
    payload.security_key = self.session_key
    return {
        platform = "android",
        client = "app",
        sign = "",
        ver_name = VER_NAME,
        ver_code = VER_CODE,
        gz = 0,
        d = payload,
    }
end

--- Low-level POST: send an already-encoded body to an absolute URL.
-- Shared by the legacy (enveloped) and bff (flat) request shapes so the
-- transport, timeout handling and error strings stay in one place.
function Client:_send(url, body, options)
    options = options or {}
    -- Recorded, not enforced. Background tasks run in a forked subprocess
    -- (FFIUtil.runInSubProcess) and NetworkMgr:isConnected() has already
    -- answered false there on this build, which turned every catalog request
    -- into a bare "offline" before a socket was ever opened -- while the exact
    -- same request succeeded from outside the device. LuaSocket reports a real
    -- transport error when the network is genuinely down, so short-circuiting
    -- here only ever replaced a true error with a misleading one.
    if type(NetworkMgr.isConnected) == "function" then
        local connected = false
        local ok_conn = pcall(function() connected = NetworkMgr:isConnected() end)
        -- 高频诊断（任务期间每个网络操作都跑一次），按日志规范降级：
        -- INFO 落盘让 crash.log 在一次整本下载里膨胀数百行。
        -- 注意方法名：本插件 logger 封装是 **dbg**（LEVELS = dbg/info/warn/err），
        -- 没有 debug——2026-10-24 22:03 书架全挂事故：误写 logger.debug 抛
        -- "attempt to call field 'debug' (a nil value)"（client.lua:194），
        -- worker xpcall 捕获后 reason 只剩文件名头部，联网功能全部失败。
        logger.dbg("net state (subprocess aware):", tostring(ok_conn),
            tostring(connected))
    end

    local timeout = tonumber(options.timeout) or 30

    local headers = {
        ["User-Agent"] = APP_UA,
        ["Accept"] = "application/json, text/plain, */*",
        ["Content-Type"] = "application/json",
        ["Content-Length"] = tostring(#body),
    }
    -- Caller-supplied headers win: the /api/pc-proxy forwarder is the website's
    -- own endpoint and needs the website's User-Agent/Origin/Referer, while the
    -- direct API host wants the app UA.
    if type(options.headers) == "table" then
        for name, value in pairs(options.headers) do
            if value ~= nil then
                headers[name] = tostring(value)
            end
        end
        headers["Content-Length"] = tostring(#body)
    end

    socketutil:set_timeout(timeout, timeout)
    local chunks = {}
    local req_opts = {
        url = url,
        method = "POST",
        source = ltn12.source.string(body),
        sink = socketutil.table_sink(chunks),
        headers = headers,
    }
    -- weread sets redirect=false: LuaSocket re-sends redirects as GET, which
    -- would silently drop our JSON body. 3xx is reported as an error instead.
    req_opts.redirect = false

    -- LuaSocket's request-table form returns (1, code, headers, status).
    -- pcall prepends its own boolean, so keep the transport success value
    -- separate: (pcall_ok, request_ok, code, headers, status). Without this
    -- offset, `code` becomes 1 and the numeric HTTP status is mistaken for the
    -- headers table (seen on-device during bookshelf refresh).
    local call_ok, request_ok, code, resp_headers, status = pcall(http.request, req_opts)
    socketutil:reset_timeout()
    if not call_ok then
        -- Logged, not just returned. Every failure below used to be a bare
        -- `return nil, reason`, which meant a broken request produced an
        -- InfoMessage and NOTHING in crash.log -- a refresh that failed on the
        -- device was undiagnosable. The request body carries security_key, so
        -- only the URL and the failure text are logged, never the payload.
        logger.err("net request failed:", url, "err=",
            tostring(request_ok))
        return nil, "request_failed: " .. tostring(request_ok)
    end
    if request_ok ~= 1 then
        local reason = code or request_ok or "transport_failed"
        logger.err("net request failed:", url, "err=", tostring(reason))
        return nil, "request_failed: " .. tostring(reason)
    end

    local raw = table.concat(chunks)
    if raw == "" then
        logger.err("net empty response:", url, "http=",
            tostring(code), "status=", tostring(status))
        return nil, string.format("empty_response: http_%s", tostring(code))
    end

    -- Status first. The 512 "订单到期暂停" outage served an HTML page, and the
    -- only thing that reached the screen was `decode_failed: <!DOCTYPE html>` --
    -- which reads like a parser bug and sent me hunting in the wrong place. The
    -- status code and content-type are what actually identify it.
    local http_code = tonumber(code)
    if http_code and http_code ~= 200 then
        logger.err("net http status:", url, "http=", tostring(code),
            "ctype=", tostring(resp_headers and resp_headers["content-type"]),
            "status=", tostring(status))
        return nil, string.format("http_%s", tostring(code))
    end

    local decode_ok, decoded = pcall(Json.decode, raw)
    if not decode_ok or type(decoded) ~= "table" then
        -- Name the likely cause instead of just "not JSON". During the outage
        -- this body was the CDN's order-expired page.
        local ctype = tostring(resp_headers and resp_headers["content-type"] or "")
        local looks_html = raw:sub(1, 40):lower():find("<!doctype html", 1, true) ~= nil
            or raw:sub(1, 40):lower():find("<html", 1, true) ~= nil
        local reason = looks_html and "html_not_api" or "decode_failed"
        if looks_html and ctype ~= "" then
            reason = "html_not_api:" .. ctype
        end
        -- The body is logged (truncated) because the usual cause is a WAF or
        -- captcha page rather than a malformed API response.
        logger.err("net decode failed:", url, "http=", tostring(code),
            "reason=", reason, "ctype=", ctype,
            "body=", string.sub(raw, 1, 200))
        return nil, reason .. ": " .. string.sub(tostring(raw), 1, 120)
    end
    return decoded
end

--- Low-level POST returning a decoded JSON table (the raw envelope).
-- Transport: LuaSocket via socketutil, same shape as weread's Client:request.
function Client:post(path, d, options)
    local body = Json.encode(self:envelope(d))
    return self:_send(self.base_url .. path, body, options)
end

--- Plain HTTP GET returning the raw body as a string, for binary payloads
--- (cover images). Unlike _send() this deliberately does NOT run the response
--- through JSON: an image would fail to decode. The caller supplies the URL
--- verbatim -- cover URLs carry an ?m=<signature>&t=<expiry> pair and rebuilding
--- one by hand is rejected.
---
--- 3xx is followed, up to 2 hops, but only inside *.lightnovel.fun: the site now
--- 302s bare-domain image URLs (https://lightnovel.fun/upload-files/...) to
--- https://www.lightnovel.fun/... with the same path and a still-valid
--- signature (2026-10-24 实测：义妹生活全书插图 302，跟随重定向即 200 JPEG)。
--- redirect=false stays on the wire hop itself -- LuaSocket would re-send a
--- redirected POST as GET and drop the body -- so the hop is re-issued here
--- where the method is known to be GET.
local function redirect_target(original_url, location)
    if type(location) ~= "string" or location == "" then return nil end
    local target
    if location:find("^https?://") then
        target = location
    elseif location:sub(1, 1) == "/" then
        local scheme, host = original_url:match("^(https?)://([^/]+)")
        if not host then return nil end
        target = scheme .. "://" .. host .. location
    else
        return nil
    end
    -- 只允许站内重定向：图片 URL 带站点签名，但盲目跟随会把请求打到任意主机。
    local target_host = target:match("^https?://([^/]+)") or ""
    local original_host = original_url:match("^https?://([^/]+)") or ""
    -- 同主机重定向（几乎都是 http→https 升级）放行：目标域名没变，安全边界不动。
    -- 2026-10-27《游戏人生》实测：photobucket 全库插图都是 301 到自己 https，
    -- 被旧策略判成 "redirect unusable"，整批图取不回来。
    if target_host ~= "" and target_host == original_host then
        return target
    end
    if target_host == "lightnovel.fun" or target_host:find("%.lightnovel%.fun$") then
        return target
    end
    return nil
end

function Client:get(url, options)
    options = options or {}
    local timeout = tonumber(options.timeout) or 45
    local redirects_left = 2
    while true do
        socketutil:set_timeout(timeout, timeout)
        local chunks = {}
        local req_opts = {
            url = url,
            method = "GET",
            sink = socketutil.table_sink(chunks),
            headers = {
                ["User-Agent"] = WEB_UA,
                ["Accept"] = "image/*,*/*",
                ["Referer"] = "https://www.lightnovel.fun/",
            },
        }
        req_opts.redirect = false
        -- Match _send's pcall/LuaSocket return handling; request-table form is
        -- (1, HTTP status, response headers, status line), not just a status code.
        local call_ok, request_ok, code, resp_headers = pcall(http.request, req_opts)
        socketutil:reset_timeout()
        if not call_ok then
            logger.err("net GET failed:", url, "err=", tostring(request_ok))
            return nil, "request_failed: " .. tostring(request_ok)
        end
        if request_ok ~= 1 then
            local reason = code or request_ok or "transport_failed"
            logger.err("net GET failed:", url, "err=", tostring(reason))
            return nil, "request_failed: " .. tostring(reason)
        end
        local numeric = tonumber(code)
        if (numeric == 301 or numeric == 302 or numeric == 303
                or numeric == 307 or numeric == 308) and redirects_left > 0 then
            local headers = resp_headers or {}
            local location = headers["location"] or headers["Location"]
                or headers["LOCATION"]
            local target = redirect_target(url, location)
            if target then
                redirects_left = redirects_left - 1
                logger.info("net GET redirect:", tostring(code), url, "->", target)
                url = target
            else
                logger.err("net GET redirect unusable:", url, "http=",
                    tostring(code), "location=", tostring(location))
                return nil, "http_" .. tostring(code)
            end
        elseif numeric ~= 200 then
            -- Signed cover URLs expire; a 403 here is expected behaviour, not a bug,
            -- but it must still leave a trace.
            logger.err("net GET status:", tostring(code), url)
            return nil, "http_" .. tostring(code)
        else
            local raw = table.concat(chunks)
            if raw == "" then
                logger.err("net GET empty response:", url)
                return nil, "empty_response"
            end
            return raw
        end
    end
end

--- Low-level POST for the bff family: flat body, no envelope, different base.
-- See the BFF_BASE_URL comment for why these two shapes cannot be merged.
function Client:postFlat(path, d, options)
    options = options or {}
    local payload = d or {}
    -- security_key travels at the top level for this family, exactly as the web
    -- client sends it. Passing it through post() would bury it inside `d`, which
    -- this family never reads (it answers code 8 = not logged in).
    payload.security_key = self.session_key
    local body = Json.encode(payload)
    local base = options.base_url or BFF_BASE_URL
    return self:_send(base .. path, body, options)
end

--- POST and unwrap `data`, mapping non-zero `code` to a readable error.
-- Returns data on success, or nil plus a reason string.
function Client:call(path, d, options)
    local envelope, err = self:post(path, d, options)
    if not envelope then
        return nil, err
    end
    local code = tonumber(envelope.code)
    if code == nil then
        logger.err("api malformed envelope:", path)
        return nil, "malformed_envelope"
    end
    if code == 0 then
        return envelope.data
    end
    -- The server puts a human-readable reason in data as a string or a table
    -- with one key; surface it instead of a bare numeric code.
    local detail = ""
    local data = envelope.data
    if type(data) == "string" then
        detail = data
    elseif type(data) == "table" then
        for _, value in pairs(data) do
            if type(value) == "string" then
                detail = value
                break
            end
        end
    end
    logger.err("api error:", path, "code=", tostring(code), "detail=",
        detail ~= "" and detail or "(none)")
    return nil, string.format("api_error_%d%s", code,
        detail ~= "" and (": " .. detail) or "")
end

--- Unwrap a bff response. Same code semantics as call(), but the payload can
--- arrive under `data` or `d` (the web parser accepts either), so check both.
function Client:callFlat(path, d, options)
    local response, err = self:postFlat(path, d, options)
    if not response then
        return nil, err
    end
    local code = tonumber(response.code)
    if code == nil then
        logger.err("api malformed envelope:", path)
        return nil, "malformed_envelope"
    end
    if code == 0 then
        local payload = response.data
        if payload == nil then payload = response.d end
        return payload
    end
    local detail = ""
    local data = response.data or response.d
    if type(data) == "string" then
        detail = data
    elseif type(data) == "table" then
        for _, value in pairs(data) do
            if type(value) == "string" then
                detail = value
                break
            end
        end
    end
    logger.err("api error:", path, "code=", tostring(code), "detail=",
        detail ~= "" and detail or "(none)")
    return nil, string.format("api_error_%d%s", code,
        detail ~= "" and (": " .. detail) or "")
end

--- Browse a category page. Verified: pageSize must be >= 20.
function Client:fetchCategory(spec, page, options)
    page = tonumber(page) or 1
    return self:call("/api/category/get-article-by-cate", {
        parent_gid = spec.parent_gid,
        gid = spec.gid,
        page = page,
        pageSize = LIST_PAGE_SIZE,
    }, options)
end

--- Search. Requires a session key; without one the server answers code 5.
function Client:search(keyword, category, page, options)
    if not self:hasSession() then
        return nil, "login_required"
    end
    return self:call("/api/search/search-result", {
        q = keyword,
        type = tonumber(category) or CATEGORY.NOVEL,
        page = tonumber(page) or 1,
        page_size = LIST_PAGE_SIZE,
    }, options)
end

--- All volumes of a series. This is the catalog entry point: the detail
--- endpoint only exposes the volume it was called with.
function Client:fetchVolumes(sid, options)
    return self:call("/api/series/get-article-list",
        { sid = tonumber(sid) or sid }, options)
end

--- Volume metadata (name, cover, author, intro).
function Client:fetchSeries(sid, options)
    return self:call("/api/series/get-info",
        { sid = tonumber(sid) or sid }, options)
end

--- Chapter/volume text. `simple=0` is required or content comes back empty.
function Client:fetchArticle(aid, options)
    return self:call("/api/article/get-detail", {
        aid = tonumber(aid) or aid,
        simple = 0,
    }, options)
end

--- One page of comments for an article, including nested replies.
function Client:fetchComments(aid, page, options)
    options = options or {}
    return self:call("/api/discuss/get-topic", {
        aid = tonumber(aid) or aid,
        page = tonumber(page) or 1,
        -- The caller owns the page size so the sync loop and the request always
        -- agree; COMMENT_PAGE_SIZE is only the fallback.
        page_size = tonumber(options.page_size) or COMMENT_PAGE_SIZE,
    }, options)
end

--- The account's personal shelf on the server (bff family).
---
--- Verified live 2026-10-02: returns code 0 and a `data.list` array (not
--- `items` -- the web parser accepts items ?? list ?? cards, so `list` is the
--- field to read). Entries carry `book_id`, which belongs to the NEW id space:
--- `source_series_id` does NOT resolve against the legacy series endpoints
--- (get-article-list/get-info answer code 0 with an empty array for it), so a
--- shelf row cannot be opened through the legacy article flow.
function Client:fetchBookshelf(page, options)
    if not self:hasSession() then
        return nil, "login_required"
    end
    return self:callFlat("/api/bff/bookshelf-v1", {
        page = tonumber(page) or 1,
        pageSize = BOOKSHELF_PAGE_SIZE,
    }, options)
end

--- Volumes of a bff book. Direct api.lightnovel.fun can return a partial catalog
--- for older/imported books; the website's read-only PC proxy is the canonical
--- source used by its book-detail page and returns the full volume list.
function Client:fetchWebBookVolumes(book_id, page, options)
    options = options or {}
    return self:callFlat("/api/new-content-read/get-book-volumes", {
        book_id = tonumber(book_id) or book_id,
        page = tonumber(page) or 1,
        pageSize = LIST_PAGE_SIZE,
        page_size = LIST_PAGE_SIZE,
    }, {
        timeout = options.timeout or 40,
        base_url = BFF_BASE_URL,
        headers = {
            ["User-Agent"] = WEB_UA,
            ["Origin"] = "https://www.lightnovel.fun",
            ["Referer"] = "https://www.lightnovel.fun/",
        },
    })
end

--- 新内容书籍的按卷评论（公开接口，无需登录）。
---
--- 2026-10-27 实测：`POST /api/new-content-read/get-book-comments`
--- `{book_id, volume_id, page, page_size}`，page_size 可到 50，page_info.count 与站点
--- 书架上的 volume_comment_count 逐卷相等（499/499、273/273、779/779）。不传
--- volume_id 时返回"全书评论"（通常只有寥寥几条）。这条路径让没有 legacy 文章 id
--- 的书也能拿到评论，不必再依赖白名单或运行时核验。
function Client:fetchBookComments(book_id, volume_id, page, options)
    options = options or {}
    local body = {
        book_id = tonumber(book_id) or book_id,
        page = tonumber(page) or 1,
        page_size = COMMENT_PAGE_SIZE_MAX,
        pageSize = COMMENT_PAGE_SIZE_MAX,
    }
    local vid = tonumber(volume_id)
    if vid and vid > 0 then body.volume_id = vid end
    return self:callFlat("/api/new-content-read/get-book-comments", body, {
        timeout = options.timeout or 40,
        base_url = BFF_BASE_URL,
        headers = {
            ["User-Agent"] = WEB_UA,
            ["Origin"] = "https://www.lightnovel.fun",
            ["Referer"] = "https://www.lightnovel.fun/",
        },
    })
end

--- One web-catalog volume page through the same read-only route as the site.
function Client:fetchWebVolumeChapters(book_id, volume_id, page, options)
    options = options or {}
    return self:callFlat("/api/new-content-read/get-volume-chapters", {
        book_id = tonumber(book_id) or book_id,
        volume_id = tonumber(volume_id) or volume_id,
        page = tonumber(page) or 1,
        pageSize = LIST_PAGE_SIZE,
        page_size = LIST_PAGE_SIZE,
    }, {
        timeout = options.timeout or 40,
        base_url = BFF_BASE_URL,
        headers = {
            ["User-Agent"] = WEB_UA,
            ["Origin"] = "https://www.lightnovel.fun",
            ["Referer"] = "https://www.lightnovel.fun/",
        },
    })
end

--- Read-only chapter detail via the web proxy; no unlock endpoint is called.
function Client:fetchWebChapterDetail(book_id, chapter_id, options)
    options = options or {}
    return self:callFlat("/api/new-content-read/get-chapter-detail", {
        book_id = tonumber(book_id) or book_id,
        chapter_id = tonumber(chapter_id) or chapter_id,
    }, {
        timeout = options.timeout or 60,
        base_url = BFF_BASE_URL,
        headers = {
            ["User-Agent"] = WEB_UA,
            ["Origin"] = "https://www.lightnovel.fun",
            ["Referer"] = "https://www.lightnovel.fun/",
        },
    })
end

--- Legacy direct catalog methods remain for existing callers/tests; new-content
--- shelf opening should use the complete web-catalog variants above.
function Client:fetchBookVolumes(book_id, page, options)
    return self:call("/api/new-content-read/get-book-volumes", {
        book_id = tonumber(book_id) or book_id,
        page = tonumber(page) or 1,
        pageSize = LIST_PAGE_SIZE,
        page_size = LIST_PAGE_SIZE,
    }, options)
end

--- Chapters of one volume. `data.list` rows carry chapter_id / chapter_no /
--- title / word_count plus the access triple that decides whether the text can
--- be read: access_type ("public" | "coin"), coin_price, locked, unlocked.
function Client:fetchVolumeChapters(book_id, volume_id, page, options)
    return self:call("/api/new-content-read/get-volume-chapters", {
        book_id = tonumber(book_id) or book_id,
        volume_id = tonumber(volume_id) or volume_id,
        page = tonumber(page) or 1,
        pageSize = LIST_PAGE_SIZE,
        page_size = LIST_PAGE_SIZE,
    }, options)
end

--- Chapter text as a paragraph array.
---
--- A locked chapter does not come back as an error payload we can render: the
--- server answers code 1000 with data.message "本章需要 N 轻币解锁". That is
--- surfaced verbatim by call(), so the caller can read the price out of it and
--- decide whether to spend.
function Client:fetchChapterParagraphs(book_id, chapter_id, options)
    return self:call("/api/new-content-read/get-chapter-paragraphs", {
        book_id = tonumber(book_id) or book_id,
        chapter_id = tonumber(chapter_id) or chapter_id,
    }, options)
end

--- Chapter detail carries the legacy resource map for [res]ext:<key> tokens
--- present in the paragraph API's text. Images cannot be resolved from the
--- paragraph endpoint alone.
function Client:fetchChapterDetail(book_id, chapter_id, options)
    return self:call("/api/new-content-read/get-chapter-detail", {
        book_id = tonumber(book_id) or book_id,
        chapter_id = tonumber(chapter_id) or chapter_id,
    }, options)
end

--- Chapter detail supplements paragraphs with URLs in `legacy_resources.res_info`.
--- An unresolved server token is omitted rather than shown to the reader.
function Client:fetchChapterDetail(book_id, chapter_id, options)
    return self:call("/api/new-content-read/get-chapter-detail", {
        book_id = tonumber(book_id) or book_id,
        chapter_id = tonumber(chapter_id) or chapter_id,
    }, options)
end

---
--- The obvious call -- POST https://api.lightnovel.fun/api/new-content-read/
--- unlock-chapter inside the legacy envelope -- cannot work: that host checks
--- an HMAC signature whose secret lives in the closed-source Dart app. Verified
--- 2026-10-02, and the failures are distinguishable and informative:
---   without ts -> code 1000 "请求已过期，请刷新后重试"
---   with ts    -> code 1000 "签名无效"
---
--- Routing the SAME legacy path through the website's own forwarder works and
--- needs no signature at all, because that layer applies the bff rules
--- (flat body, ts + nonce):
---   POST https://www.lightnovel.fun/api/pc-proxy/api/new-content-read/unlock-chapter
---   {security_key, chapter_id, ts, nonce}
---   -> {"code":0,"data":{"chapter_id":…,"unlocked":1,"coin_price":1}}
---
--- NOTE: this call spends real currency. Every attempt costs a coin when it
--- succeeds, so callers must confirm with the reader first.
function Client:unlockChapter(chapter_id, options)
    options = options or {}
    local response, err = self:_send(BFF_BASE_URL
        .. "/api/new-content-read/unlock-chapter",
        Json.encode({
            security_key = self.session_key,
            chapter_id = tonumber(chapter_id) or chapter_id,
            ts = math.floor(os.time()),
            nonce = string.format("%x", math.random(0, 0x7fffffff)),
        }), {
            timeout = options.timeout,
            -- The forwarder is the website's own endpoint, so it expects the
            -- website's headers; the Dart app UA is rejected or misrouted.
            headers = {
                ["User-Agent"] = WEB_UA,
                ["Origin"] = "https://www.lightnovel.fun",
                ["Referer"] = "https://www.lightnovel.fun/",
            },
        })
    if not response then
        return false, err or "request_failed"
    end
    local code = tonumber(response.code)
    if code == 0 then
        return true, ""
    end
    local detail = ""
    local data = response.data
    if type(data) == "string" then
        detail = data
    elseif type(data) == "table" then
        for _, value in pairs(data) do
            if type(value) == "string" then
                detail = value
                break
            end
        end
    end
    return false, string.format("api_error_%d%s", tostring(code),
        detail ~= "" and (": " .. detail) or "")
end

--- ============================================================================
-- Whole-book download family (EPUB export backend).
--
-- Parameter order and field usage taken from the web client's own
-- implementation (CuYSs1Ih.js, function `Ts`, @50667-51400), so the plugin
-- speaks the same protocol the site does rather than a guessed shape:
--
--   1. check-book-download-access {security_key, book_id}
--   2. prepare-book-download      {security_key, book_id}
--        -> revision, chapter_ids, total_chapters, chapters[], cover_url
--   3. get-book-download-chapters {security_key, book_id, chapter_ids}
--        -> data.list[] each with body_snapshot.body_text
--   4. complete-book-download     {security_key, book_id, revision, completed:1,
--                                  downloaded_chapter_ids, total_chapters}
--
-- Verified live 2026-10-02 on book_id 3177: step 3 answered code 0 with all 83
-- chapters in a single 2.4 MB response, and it did NOT consume coins. It also
-- returned the seven trailing chapters that per-chapter unlocking refused, so
-- this route replaces unlocking entirely.
--
-- Step 3 REQUIRES book_id *and* chapter_ids; omitting chapter_ids answers
-- code 3 with data containing only the failing `chapter_ids` key.
-- ============================================================================

--- Step 1. Returns the access decision for a whole-book export.
function Client:checkBookDownloadAccess(book_id, options)
    return self:call("/api/new-content-read/check-book-download-access", {
        book_id = tonumber(book_id) or book_id,
    }, options)
end

--- Step 2. Opens the export and returns {revision, chapter_ids, chapters, ...}.
--- `revision` is a content hash: store it, and if a later prepare returns the
--- same value the cached copy is still current and the download can be skipped.
function Client:prepareBookDownload(book_id, options)
    return self:call("/api/new-content-read/prepare-book-download", {
        book_id = tonumber(book_id) or book_id,
    }, options)
end

--- Step 3. Returns the text of every requested chapter in one response.
--- @treturn table data.list -- rows carrying body_snapshot.body_text
function Client:fetchBookDownloadChapters(book_id, chapter_ids, options)
    options = options or {}
    if type(chapter_ids) ~= "table" or #chapter_ids == 0 then
        return nil, "chapter_ids_required"
    end
    local ids = {}
    for _, id in ipairs(chapter_ids) do
        local n = tonumber(id)
        if n and n > 0 then
            ids[#ids + 1] = n
        end
    end
    if #ids == 0 then
        return nil, "chapter_ids_required"
    end
    return self:call("/api/new-content-read/get-book-download-chapters", {
        book_id = tonumber(book_id) or book_id,
        chapter_ids = ids,
    }, options)
end

--- Step 4. Reports the export as finished. Fire and forget: a failure here
--- only leaves the server's `download_state` stale, the downloaded text is
--- already on the device.
function Client:completeBookDownload(book_id, revision, chapter_ids,
                                     total_chapters, options)
    local ids = {}
    for _, id in ipairs(chapter_ids or {}) do
        local n = tonumber(id)
        if n and n > 0 then
            ids[#ids + 1] = n
        end
    end
    return self:call("/api/new-content-read/complete-book-download", {
        book_id = tonumber(book_id) or book_id,
        revision = tostring(revision or ""),
        completed = 1,
        downloaded_chapter_ids = ids,
        total_chapters = tonumber(total_chapters) or #ids,
    }, options)
end

--- Log in and store the session key. The key is a colon separated string whose
--- second field is the numeric uid.
function Client:login(username, password, options)
    local data, err = self:call("/api/user/login", {
        username = username,
        password = password,
    }, options)
    if not data then
        return nil, err
    end
    local key = data and data.security_key
    if type(key) ~= "string" or key == "" then
        return nil, "login_failed"
    end
    self:setSessionKey(key)
    return { uid = data.uid, security_key = key }
end

function Client:logout()
    self:setSessionKey("")
end

return Client
