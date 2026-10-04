-- smux session / auth core (pure): token auth, lockout, duplicate-seq replay, idle expiry.
--
-- Modelled directly on rshell/docs/spec.md section 4 (the proven shared-secret pattern in this
-- repo), adapted to smux's console frames from framing.lua. Every frame carries the server
-- secret as its `token`; the server compares it constant-time and tracks per-peer state for
-- lockout, duplicate replay and idle expiry.
--
-- Pure module: no os/io/computer/event/component/GERTi/process dependencies. The clock is
-- injected (caller passes `now`, seconds) so tests can drive time deterministically. Runs under
-- plain lua5.3 and OpenComputers Lua 5.3.

local framing = require("smux/framing")

local M = {}
M.VERSION = "1.0.0"

------------------------------------------------------------------- constants --
M.DEFAULT_MAX_FAILURES = 5   -- consecutive bad tokens before a peer is locked out
M.DEFAULT_LOCKOUT      = 30  -- seconds a failed peer stays locked (frames dropped, no reply)
M.DEFAULT_IDLE_TIMEOUT = 300 -- seconds of silence before a peer's session state is forgotten

------------------------------------------------------------------- helpers --

-- Constant-time string equality: does not short-circuit on first mismatching byte. Length still
-- has to match (a length oracle is unavoidable and acceptable here - the secret is a shared
-- server key, not per-user; rshell makes the same choice).
local function const_eq(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return false end
    if #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do
        -- Lua 5.3 native bitwise ops (no OpenComputers `bit` module needed).
        diff = diff | (a:byte(i) ~ b:byte(i))
    end
    return diff == 0
end

------------------------------------------------------------------- session --

--[[
new(opts):
  opts.secret       string   required - the shared secret every frame's token must equal
  opts.max_failures integer  default M.DEFAULT_MAX_FAILURES
  opts.lockout      number   seconds, default M.DEFAULT_LOCKOUT
  opts.idle_timeout number   seconds, default M.DEFAULT_IDLE_TIMEOUT
  opts.execute      function(peer, frame) -> list of encoded response-frame strings (may be {})
                    Called for each authenticated, non-duplicate request. `frame` is the decoded
                    table from framing.decode. Return zero or more frames to send back; they are
                    stored so a duplicate seq can replay them without re-executing.

sess:handle(peer, frame_string, now) -> list of encoded response-frame strings (may be {})
  The single entry point. `peer` is an opaque key identifying the remote address (a string).
  `frame_string` is one raw wire frame (the exact string a transport delivered). Returns zero or
  more frames to send back to that peer. Never raises on malformed/hostile input - bad frames are
  dropped silently, matching rshell's "never crash, never reply with detail" rule.

sess:forget_idle(now) -> count of peers whose session expired and was removed (idle_timeout).
  Call periodically from the serve loop; a forgotten peer must re-authenticate from scratch.

sess:peers() -> list of peer keys currently tracked (for tests/inspection).
]]
function M.new(opts)
    assert(type(opts) == "table", "session: opts table required")
    local secret = opts.secret
    if type(secret) ~= "string" or #secret == 0 then
        error("session: a non-empty string secret is required")
    end

    local max_failures = opts.max_failures or M.DEFAULT_MAX_FAILURES
    local lockout      = opts.lockout      or M.DEFAULT_LOCKOUT
    local idle_timeout = opts.idle_timeout or M.DEFAULT_IDLE_TIMEOUT
    local execute      = opts.execute or function() return {} end

    -- peer -> { last_seq, replies (list of encoded frames), fails, locked_until, last_active }
    local peers = {}

    local sess = {}

    local function get_peer(peer)
        local p = peers[peer]
        if not p then
            p = { last_seq = nil, replies = {}, fails = 0, locked_until = nil, last_active = nil }
            peers[peer] = p
        end
        return p
    end

    function sess:handle(peer, frame_string, now)
        -- Malformed frames are dropped silently (no reply), exactly like rshell.
        local frame, err = framing.decode(frame_string)
        if not frame then return {} end

        local p = get_peer(peer)

        -- Lockout: a locked peer's frames are dropped with NO reply while the window is open.
        if p.locked_until ~= nil and now < p.locked_until then
            return {}
        end
        -- A lockout that has since expired is cleared so normal handling resumes.
        if p.locked_until ~= nil and now >= p.locked_until then
            p.locked_until = nil
            p.fails = 0
        end

        -- Auth: constant-time compare of the frame's token against the shared secret.
        if not const_eq(frame.token, secret) then
            p.fails = p.fails + 1
            if p.fails >= max_failures then
                p.locked_until = now + lockout
                p.fails = 0
                -- rshell: on the failure that trips the lockout we still send one DENY, then drop.
                return { framing.encode("DENY", frame.seq, "", "") }
            end
            return { framing.encode("DENY", frame.seq, "", "") }
        end

        -- Authenticated: reset the failure streak and record activity.
        p.fails = 0
        p.last_active = now

        -- Duplicate / ordering detection (rshell section 4 "Duplicates"):
        local last_seq = p.last_seq
        if last_seq ~= nil then
            if frame.seq < last_seq then
                -- Older than the last handled seq: drop, no reply.
                return {}
            elseif frame.seq == last_seq then
                -- Re-send of an already-handled request: replay the stored reply frames and do NOT
                -- execute again (no acks/retransmit on the wire, so clients re-send on timeout).
                return p.replies
            end
        end
        -- seq is new (last_seq+1 or a client that restarted counting): execute normally.

        local ok, responses = pcall(execute, peer, frame)
        if not ok then
            -- A handler error must never crash the session; reply with a single DENY and store it.
            responses = { framing.encode("DENY", frame.seq, "", "") }
        end
        if type(responses) ~= "table" then responses = {} end

        p.last_seq = frame.seq
        p.replies = responses
        return responses
    end

    function sess:forget_idle(now)
        local removed = 0
        for peer, p in pairs(peers) do
            if p.last_active ~= nil and now - p.last_active >= idle_timeout then
                peers[peer] = nil
                removed = removed + 1
            end
        end
        return removed
    end

    function sess:peers()
        local list = {}
        for peer in pairs(peers) do table.insert(list, peer) end
        table.sort(list)
        return list
    end

    -- Expose internals for tests (read-only intent; not part of the wire contract).
    sess._peers = peers

    return sess
end

return M
