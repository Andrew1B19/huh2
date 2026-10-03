-- Tests for smux/gertinet.lua (smux's own GERTi transport endpoint) with a fake GERTi object -
-- same approach as hmi/test/test_b9bbbb9net.lua: no real GERTi needed, plain lua5.3.
-- Run from repo root: lua5.3 smux/test/test_gertinet.lua

package.path = "./?.lua;./nodelib/?.lua;./hmi/?.lua;" .. package.path

local gertinet = require("smux.gertinet")
local proto    = require("proto")

local passed = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error("FAIL " .. name .. ": " .. tostring(err), 0) end
    passed = passed + 1
    print("PASS " .. name)
end

-- Fake GERTi: records openSocket calls; sockets record writes and can be fed incoming strings.
local function fake_gerti()
    local g = { opened = {}, refuse = false }
    function g.openSocket(addr, id)
        g.opened[#g.opened + 1] = { addr, id }
        if g.refuse then return false end
        local s = { written = {}, incoming = {}, closed = false }
        function s:write(str) self.written[#self.written + 1] = str; return true end
        function s:read() local r = self.incoming; self.incoming = {}; return r end
        function s:close() self.closed = true end
        g.last = s
        return s
    end
    return g
end

test("module constants: PORT=100, PORTS=4 (ids 100..103), RETRY present", function()
    assert(gertinet.PORT == 100)
    assert(gertinet.PORTS == 4)
    assert(type(gertinet.RETRY) == "number" and gertinet.RETRY > 0)
end)

test("trusted-only send: strangers are refused, no socket opened", function()
    local g = fake_gerti()
    local ep = gertinet.new(g, { trusted = { "peerA" } })
    assert(ep:send("eve", proto.heartbeat()) == false and #g.opened == 0)
    assert(ep:send("peerA", proto.heartbeat()) == true and #g.opened == 1)
end)

test("incoming connection from a trusted origin is opened back with the same id (within 100..103)", function()
    local g = fake_gerti()
    local ep = gertinet.new(g, { trusted = { "peerA" } })
    ep:signal("GERTConnectionID", "peerA", 102)
    assert(ep:poll() == nil)
    assert(#g.opened == 1 and g.opened[1][1] == "peerA" and g.opened[1][2] == 102)
end)

test("strangers and out-of-range ids are ignored", function()
    local g = fake_gerti()
    local ep = gertinet.new(g, { trusted = { "peerA" } })
    ep:signal("GERTConnectionID", "eve", 100)   -- stranger
    ep:signal("GERTConnectionID", "peerA", 96)  -- b9bbbb9's range, not smux's
    ep:signal("GERTConnectionID", "peerA", 80)  -- onpgp's range, not smux's
    ep:poll()
    assert(#g.opened == 0)
end)

test("id allocation stays within the 100..103 range and does not collide across peers", function()
    local g = fake_gerti()
    local ep = gertinet.new(g, { trusted = { "a", "b", "c", "d", "e" } })
    assert(ep:send("a", proto.heartbeat()) == true)
    assert(ep:send("b", proto.heartbeat()) == true)
    assert(ep:send("c", proto.heartbeat()) == true)
    assert(ep:send("d", proto.heartbeat()) == true)
    local ids = {}
    for _, o in ipairs(g.opened) do ids[o[2]] = (ids[o[2]] or 0) + 1 end
    -- Four distinct peers must get four DISTINCT ids, all within 100..103.
    assert(#g.opened == 4 and ids[100] == 1 and ids[101] == 1 and ids[102] == 1 and ids[103] == 1)
    -- A fifth peer has no free id left: send must fail, not open a socket outside the range.
    assert(ep:send("e", proto.heartbeat()) == false and #g.opened == 4)
end)

test("frames round-trip through the endpoint; garbage is dropped without raising", function()
    local g = fake_gerti()
    local ep = gertinet.new(g, { trusted = { "peerA" } })
    assert(ep:send("peerA", proto.heartbeat()) == true)
    -- Simulate an inbound frame from the peer (as GERTi would deliver a string).
    g.last.incoming = { proto.encode({ type = "SMUX", f = "frame1" }), "garbage{{", 42 }
    local from, msg = ep:poll()
    assert(from == "peerA" and msg.type == "SMUX" and msg.f == "frame1")
    assert(ep:poll() == nil) -- garbage entries dropped without raising
end)

test("retry backoff timing on send: failed open is retried only after RETRY", function()
    local g = fake_gerti(); g.refuse = true
    local now = 0
    local ep = gertinet.new(g, { trusted = { "peerA" }, clock = function() return now end })
    assert(ep:send("peerA", proto.heartbeat()) == false)
    assert(ep:send("peerA", proto.heartbeat()) == false and #g.opened == 1, "no hammering within RETRY")
    now = gertinet.RETRY + 1; g.refuse = false
    assert(ep:send("peerA", proto.heartbeat()) == true and #g.opened == 2)
end)

test("accept_pending: a failed incoming-open still honours RETRY on the next poll (drop must not wipe last_try)", function()
    local g = fake_gerti(); g.refuse = true
    local now = 0
    local ep = gertinet.new(g, { trusted = { "peerA" }, clock = function() return now end })
    ep:signal("GERTConnectionID", "peerA", 100)
    ep:poll() -- accept_pending tries openSocket (refused); last_try must be recorded
    assert(#g.opened == 1, "one attempt made")
    ep:poll(); ep:poll()
    assert(#g.opened == 1, "no immediate re-attempt while within RETRY")
    now = gertinet.RETRY + 1; g.refuse = false
    ep:poll()
    assert(#g.opened == 2, "retried after the back-off elapsed")
end)

test("connection close handling: GERTConnectionClose drops the socket and resets backoff", function()
    local g = fake_gerti()
    local now = 0
    local ep = gertinet.new(g, { trusted = { "peerA" }, clock = function() return now end })
    assert(ep:send("peerA", proto.heartbeat()) == true)          -- connection established at t=0
    local id = g.opened[1][2]
    local s = g.last
    ep:signal("GERTConnectionClose", "peerA", "node", id)        -- peer disconnects; socket dropped
    assert(ep.socks["peerA"] == nil, "socket should be gone after close")
    assert(s.closed, "the real GERTi socket must have been closed")
    -- The backoff timer must have been reset by the drop: no need to wait RETRY seconds before
    -- reconnecting a peer we were just talking to.
    assert(ep:send("peerA", proto.heartbeat()) == true and #g.opened == 2, "immediate reopen after a clean disconnect")
end)

test("GERTConnectionClose for the wrong id does not drop an established socket", function()
    local g = fake_gerti()
    local ep = gertinet.new(g, { trusted = { "peerA" } })
    assert(ep:send("peerA", proto.heartbeat()) == true)
    local real_id = g.opened[1][2]
    ep:signal("GERTConnectionClose", "peerA", "node", real_id + 37) -- some other connection's id
    assert(ep.socks["peerA"] ~= nil, "unrelated close must not drop our socket")
end)

test("reconnect while still connected: a failed re-open still honours RETRY (drop-before-last_try ordering)", function()
    local g = fake_gerti()
    local now = 0
    local ep = gertinet.new(g, { trusted = { "peerA" }, clock = function() return now end })
    assert(ep:send("peerA", proto.heartbeat()) == true)  -- connection established at t=0, last_try=0
    now = gertinet.RETRY + 1  -- old enough that accept_pending will act on a new pending entry
    g.refuse = true
    ep:signal("GERTConnectionID", "peerA", 101)  -- peer re-signals a new id while we still think we're connected
    ep:poll()  -- accept_pending: drop()s the old socket (resetting last_try), then must set last_try = now
    assert(#g.opened == 2, "re-open was attempted")
    assert(ep.socks["peerA"] == nil, "re-open failed, no socket")
    now = now + 1  -- well within RETRY of the attempt above
    ep:poll()
    assert(#g.opened == 2, "no immediate re-attempt: the failed re-open's own backoff must survive drop()'s reset, not be wiped back to nil")
end)

print(string.format("ALL %d GERTINET TESTS PASSED", passed))
