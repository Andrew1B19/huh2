-- smux over GERTi: a transport endpoint (transport.lua interface: send(addr, msg), poll()) for the
-- smux remote-console host. This is smux's OWN copy of the b9bbbb9net pattern - it belongs to this
-- protocol and node, not a shared library, so it is deliberately NOT reused from hmi/b9bbbb9net.lua
-- (different port range, different trust list; they never share a node). GERTi itself is injected,
-- so this runs under plain lua5.3 with a fake network for unit tests; on a real computer pass
-- require("GERTiClient").
--
-- GERTi facts used (same as hmi/b9bbbb9net.lua and vendor/gerti/GERTiClient.lua):
-- openSocket(address, id) -> socket | false (blocks up to 3 s); socket:write(string);
-- socket:read() -> list of strings (drains); socket:close(); signals GERTConnectionID(origin, id),
-- GERTConnectionClose(origin, dest, id). GERTi drops tables, so every frame is one proto.encode string.
--
-- The node only talks to `trusted` addresses (set or list). Connections from anyone else are never
-- answered. Whoever opens a connection, the other side must open back with the same id; this adapter
-- does that for incoming connections when the owner calls ep:poll() (the signal handler only queues).

-- hmi/proto.lua is the shared wire codec (encode/decode of one message table per frame) - a pure,
-- dependency-free module safe to reuse across projects in this monorepo. Resolve it under both its
-- own directory's package name and the repo-root-relative path so this works from plain lua5.3 test
-- runs as well as on a real node disk where the whole project tree is copied verbatim.
local proto = (function()
    local ok, m = pcall(require, "proto")
    if ok then return m end
    return require("hmi.proto")
end)()

local M = {}
M.VERSION = "0.1.0"
M.PORT = 100     -- first connection id, LOCAL numbering convention for this one node only - not a
                 -- network-wide reservation; do not add any check against b9bbbb9 (96..99) or onpgp
                 -- (80..95) ports: they never share a node with smux.
M.PORTS = 4      -- ids 100..103
M.RETRY = 5      -- seconds between attempts to (re)open a socket to the same peer

function M.new(gerti, opts)
    opts = opts or {}
    local trusted = {}
    for k, v in pairs(opts.trusted or {}) do
        if type(k) == "number" then trusted[tostring(v)] = true else trusted[tostring(k)] = v and true or nil end
    end
    local port, ports = opts.port or M.PORT, opts.ports or M.PORTS
    local clock = opts.clock or function() return 0 end

    local ep = { socks = {}, ids = {}, pending = {}, inbox = {}, last_try = {} }

    local function drop(addr)
        local s = ep.socks[addr]
        ep.socks[addr], ep.ids[addr] = nil, nil
        if s then
            pcall(s.close, s)
            -- A real connection just ended: reset the retry backoff for this peer. Without this a
            -- peer that was reachable moments ago and then disconnects (GERTConnectionClose or a
            -- failed write) would have its very next reconnection attempt needlessly delayed by up
            -- to RETRY seconds - stale backoff state leaking across the disconnect. Only when there
            -- WAS a socket: drop() is also used as pre-open cleanup in accept_pending(), where it
            -- must not erase the last_try set one line earlier (that would bypass the retry guard).
            ep.last_try[addr] = nil
        end
    end

    local function free_id()
        local taken = {}
        for _, id in pairs(ep.ids) do taken[id] = true end
        for i = port, port + ports - 1 do if not taken[i] then return i end end
    end

    -- signal handler: GERTConnectionID(origin, id) / GERTConnectionClose(origin, dest, id)
    function ep:signal(name, a, b, c)
        if name == "GERTConnectionID" then
            local origin = tostring(a)
            if trusted[origin] and type(b) == "number" and b >= port and b < port + ports then
                self.pending[origin] = b
            end
        elseif name == "GERTConnectionClose" then
            local origin = tostring(a)
            if self.socks[origin] and self.ids[origin] == c then drop(origin) end
        end
    end

    local function accept_pending()
        for origin, id in pairs(ep.pending) do
            local now = clock()
            -- No `or not ep.socks[origin]` here: an origin is only in pending while no socket is up
            -- for it (a successful open clears pending in the same branch), so that clause would be
            -- always true and silently bypass the RETRY backoff on every poll.
            if not ep.last_try[origin] or now - ep.last_try[origin] >= M.RETRY then
                -- drop() BEFORE last_try is set: drop() resets last_try when a real socket was
                -- dropped (the reconnect-while-still-connected case), and setting last_try first
                -- would just get wiped by that reset, re-arming an immediate retry on the next poll
                -- if this open attempt then fails. Running drop() first means its reset (if any)
                -- happens before we set the real backoff value, so the value we set here survives.
                drop(origin)
                ep.last_try[origin] = now
                local ok, sock = pcall(gerti.openSocket, origin, id)
                if ok and sock then
                    ep.socks[origin], ep.ids[origin] = sock, id
                    -- Clear the pending request only once the connection is actually established. A
                    -- failed open must stay queued so it can be retried after RETRY without needing a
                    -- fresh GERTConnectionID signal (the last_try guard above prevents hammering).
                    ep.pending[origin] = nil
                end
            end
        end
    end

    function ep:send(addr, msg)
        addr = tostring(addr)
        if not trusted[addr] then return false end
        local sock = self.socks[addr]
        if not sock then
            local now = clock()
            if self.last_try[addr] and now - self.last_try[addr] < M.RETRY then return false end
            self.last_try[addr] = now
            local id = free_id()
            if not id then return false end
            local ok, s = pcall(gerti.openSocket, addr, id)
            if not (ok and s) then return false end
            self.socks[addr], self.ids[addr] = s, id
            sock = s
        end
        local ok = pcall(sock.write, sock, proto.encode(msg))
        if not ok then drop(addr); return false end
        return true
    end

    local function drain()
        for addr, sock in pairs(ep.socks) do
            local ok, items = pcall(sock.read, sock)
            if not ok then drop(addr)
            elseif type(items) == "table" then
                for _, item in ipairs(items) do
                    if type(item) == "string" then
                        local msg = proto.decode(item)
                        if type(msg) == "table" then ep.inbox[#ep.inbox + 1] = { from = addr, msg = msg } end
                    end
                end
            end
        end
    end

    function ep:poll()
        -- Always try to open any pending (incoming) connections first, regardless of whether there
        -- is already data queued in the inbox. Gating this on `#self.inbox == 0` (as hmi/b9bbbb9net.lua
        -- does) means a frame that arrives before the connection was accepted - or any stray item left
        -- over from a previous drain - permanently blocks accept_pending() from ever running, and since
        -- GERTiClient drops data for connections it doesn't know about yet, that first write is lost.
        accept_pending()
        drain()
        local item = table.remove(self.inbox, 1)
        if not item then return nil end
        return item.from, item.msg
    end

    return ep
end

return M
