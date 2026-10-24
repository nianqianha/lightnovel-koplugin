--[[--
Reader hooks for the lightnovel plugin.

Wraps KOReader's ReaderLink so a tap on the "[N 条评论]" link opens the comment
panel instead of scrolling to the in-document anchor.

Why interception is required: crengine ignores CSS `pointer-events` when
hit-testing links, so a styled <a> still swallows the tap. The sibling weread
plugin already relies on this behaviour and works around it the same way, by
wrapping `getLinkFromGes` / `onTap`. Only links whose href starts with
Content.ANCHOR_PREFIX are affected, so normal links and page turns are
untouched.

Every wrapper is idempotent and restores the original function on close, so
repeated book opens cannot stack wrappers.
--]]--

local Content = require("lightnovel.lib.content")
local logger = require("lightnovel.lib.logger")

local Hooks = {}
Hooks.__index = Hooks

-- Stored on the reader link module so a second install can find and remove the
-- first one instead of stacking wrappers.
local INSTALL_KEY = "__lightnovel_reader_hooks"

-- Minimum seconds between two comment-panel openings. os.clock is wall time on
-- KOReader builds (it is only CPU time on some desktop Lua builds, which makes
-- the guard merely tighter there, never looser).
local COMMENT_TAP_GUARD = 1.0

function Hooks:new(options)
    return setmetatable({
        -- Supplied by main.lua; opens the comment panel for an aid.
        show_comments = assert(options.show_comments, "show_comments required"),
        -- Returns true when a tap is inside a page-turn edge zone.
        is_edge_tap = options.is_edge_tap,
        settings = options.settings,
        _installed = false,
        _saved = nil,
    }, self)
end

--- Extract our comment anchor from a link object as returned by ReaderLink.
-- Ported from weread/ui/annotations_controller.lua:_linkHref (L357-388): the
-- link table's shape depends on which path produced it. The segment /
-- larger-tap-area path carries `section` / `uri` / a nested `link` table (see
-- the sample at readerlink.lua:1132-1152), while getLinkFromGes returns only
-- xpointer-family fields. A flat two-field check therefore finds nothing on
-- the common path. Traverse, and let Content decide which string is ours.
function Hooks:_link_href(link)
    if type(link) ~= "table" then
        return nil
    end
    local seen = {}
    local function extract(value, depth)
        if depth > 4 or value == nil then
            return nil
        end
        if type(value) == "string" then
            -- Only strings that are actually one of our anchors count.
            return Content.aid_from_href(value) and value or nil
        end
        if type(value) ~= "table" or seen[value] then
            return nil
        end
        seen[value] = true
        for _, key in ipairs({
            "section", "href", "url", "target", "link", "uri",
            "dest", "destination", "xpointer", "a_xpointer",
        }) do
            local found = extract(value[key], depth + 1)
            if found then
                return found
            end
        end
        for _, child in pairs(value) do
            local found = extract(child, depth + 1)
            if found then
                return found
            end
        end
        return nil
    end
    return extract(link, 0)
end

function Hooks:_comment_aid(link)
    return Content.aid_from_href(self:_link_href(link))
end

function Hooks:install(reader_ui)
    if self._installed then
        return false
    end
    local link = reader_ui and reader_ui.link
    if not link or type(link.getLinkFromGes) ~= "function" then
        logger.warn("reader_hooks: reader link module unavailable")
        return false
    end

    -- Unwrap a previous instance first. Stacking two wrappers makes the inner
    -- one consume the edge-tap decision, so a comment link in the page-turn
    -- zone would no longer turn the page. main.lua keeps one Hooks instance, but
    -- ReaderReady can fire again after a re-open, so the guard is cheap
    -- insurance against double installation.
    local previous = rawget(link, INSTALL_KEY)
    if previous then
        -- `pcall(f, ...)` calls `f(...)` with no implicit self, so the instance
        -- must be passed explicitly. A dot call here would leave self unset and
        -- the stored originals would never be restored, silently stacking a
        -- second wrapper whose edge-tap handling is dead.
        pcall(previous.uninstall, previous, reader_ui)
    end

    local plugin = self
    self._saved = {
        getLinkFromGes = link.getLinkFromGes,
        onTap = link.onTap,
    }

    -- Ask KOReader for the link under the gesture, defensively.
    -- getLinkFromGes -> getLinkFromPosition indexes `pos` inside credocument and
    -- raises "attempt to index local 'pos' (a nil value)" whenever the document
    -- is not laid out yet -- during teardown, or on a tap that arrives while the
    -- page is still being prepared. Because this hook stays installed for the
    -- lifetime of the reader, such a tap reached KOReader's own code and froze
    -- the UI. A failure here must never be fatal: treat it as "no link".
    local function probe(link_self, ges)
        local ok, found = pcall(plugin._saved.getLinkFromGes, link_self, ges)
        if not ok then
            logger.dbg("reader_hooks: getLinkFromGes failed, ignoring tap")
            return nil
        end
        -- One-shot shape probe. getLinkFromGes (readerlink.lua:662-677) returns
        -- only {xpointer, marker_xpointer, from_xpointer, a_xpointer, link_y} --
        -- no href/uri/section -- so _link_href cannot match our anchor on this
        -- path. Rather than guess which field carries it, log the real keys once
        -- per session; the next device run settles it with evidence.
        if found and not plugin._shape_logged then
            plugin._shape_logged = true
            local keys = {}
            for k, v in pairs(found) do
                keys[#keys + 1] = k .. "=" .. type(v)
            end
            table.sort(keys)
            logger.info("reader_hooks: link table shape: " .. table.concat(keys, " "))
        end
        return found
    end

    -- 1) Hide our link from hit-testing when the tap belongs to a page turn, so
    --    the turn still happens. This mirrors the weread plugin's edge-zone
    --    behaviour and is what stops the comment link from feeling "sticky".
    link.getLinkFromGes = function(link_self, ges)
        local found = probe(link_self, ges)
        if not found then
            return nil
        end
        if not plugin:_comment_aid(found) then
            return found
        end
        if plugin.is_edge_tap and plugin.is_edge_tap(ges) then
            return nil
        end
        return found
    end

    -- 2) Intercept the tap itself. Returning true consumes the event so
    --    ReaderLink never follows the anchor and the page never jumps.
    --
    --    Arity matters, and the previous version got it wrong. Device
    --    readerlink.lua:703 declares `function ReaderLink:onTap(_, ges)` and
    --    L1598 calls `self:onTap(arg, ges)` — so at runtime the wrapper
    --    receives (self, arg, ges) and the gesture is the THIRD value. The
    --    old two-parameter `(link_self, ges)` bound the gesture to `arg`,
    --    which (a) fed a non-gesture to getLinkFromGes and is the real cause
    --    of the `credocument.lua:953 pos=nil` freeze, and (b) called the
    --    original with the gesture shifted into `arg` and `ges` nil, so any
    --    non-comment tap hit KOReader with ges=nil. weread uses the same
    --    three-parameter shape.
    -- Tapping the comment link is the ONE thing this plugin does in the reader, so
    -- an install that only half-succeeded must not report success. When onTap is
    -- not a function the tap wrapper below is skipped, yet _installed used to be
    -- set anyway, so install() returned true, main logged nothing, and the marker
    -- link silently did nothing for the rest of the session.
    if type(link.onTap) ~= "function" then
        logger.err("reader_hooks: link.onTap is", type(link.onTap),
            "-- tap interception NOT installed")
        link.getLinkFromGes = self._saved.getLinkFromGes
        self._saved = nil
        return false, "no_onTap"
    end
    link.onTap = function(link_self, arg, ges)
        local found = probe(link_self, ges)
        local aid = plugin:_comment_aid(found)
        if not aid then
            return plugin._saved.onTap(link_self, arg, ges)
        end
        if plugin.is_edge_tap and plugin.is_edge_tap(ges) then
            return plugin._saved.onTap(link_self, arg, ges)
        end
        plugin:open_comments(aid)
        return true
    end

    self._installed = true
    rawset(link, INSTALL_KEY, self)
    logger.info("reader_hooks installed")
    return true
end

function Hooks:uninstall(reader_ui)
    if not self._installed then
        return false
    end
    local link = reader_ui and reader_ui.link
    if link and self._saved then
        link.getLinkFromGes = self._saved.getLinkFromGes
        if self._saved.onTap then
            link.onTap = self._saved.onTap
        end
        if rawget(link, INSTALL_KEY) == self then
            rawset(link, INSTALL_KEY, nil)
        end
    end
    self._saved = nil
    self._installed = false
    logger.dbg("reader_hooks removed")
    return true
end

function Hooks:open_comments(aid)
    -- One panel at a time. Two taps in quick succession (a double tap on the
    -- marker, or a tap while the panel is still opening) used to push a SECOND
    -- CommentMenu onto the stack and run a second refresh_one for the same aid,
    -- because each CommentMenu guards `loading` on itself. The reader then had to
    -- close two identical panels, and the worker queue got two jobs for one
    -- chapter.
    local now = os.clock()
    if self._opened_at and (now - self._opened_at) < COMMENT_TAP_GUARD then
        logger.dbg("reader_hooks: ignoring repeat comment tap for aid",
            tostring(aid))
        return false
    end
    self._opened_at = now
    local ok, err = pcall(self.show_comments, aid)
    if not ok then
        logger.warn("reader_hooks: open comments failed:", tostring(err))
    end
    return ok
end

return Hooks
