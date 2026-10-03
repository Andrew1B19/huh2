-- Tests for smux/serve.lua (the bridge: transport -> session -> job console routing).
-- Uses a fake endpoint that records sends and queues receives, so no GERTi or process.lua needed.
-- Run from repo root: lua5.3 smux/test/test_serve.lua
package.path = "./?.lua;./nodelib/?.lua;./hmi/?.lua;" .. package.path

local framing     = require("smux/framing")
local job_console = require("smux/job_console")
local serve_mod   = require("smux/serve")

local passed = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error("FAIL " .. name .. ": " .. tostring(err), 0) end
    passed = passed + 1
    print("PASS " .. name)
end

-- Fake endpoint: records all sends; test can queue receives.
local function make_fake_endpoint()
    local ep = { sent = {}, inbox = {} }
    function ep:send(addr, msg) self.sent[#self.sent + 1] = { addr = addr, msg = msg } end
    function ep:poll()
        local item = table.remove(self.inbox, 1)
        if not item then return nil end
        return item.from, item.msg
    end
    -- Helper for tests to queue an inbound frame.
    function ep.queue(from, frame_string)
        ep.inbox[#ep.inbox + 1] = { from = from, msg = { type = "SMUX", f = frame_string } }
    end
    return ep
end

local SECRET = "test-secret-42"

test("AUTH -> ACK; ATTACH to a known job -> ACK and console is attached", function()
    local c1 = job_console.new()
    local ep = make_fake_endpoint()
    local serve = serve_mod.new({ endpoint = ep, secret = SECRET, jobs = { j1 = c1 } })

    -- AUTH
    ep.queue("peerA", framing.encode("AUTH", 0, SECRET, ""))
    serve:step()
    assert(#ep.sent == 1)
    local r = framing.decode(ep.sent[1].msg.f)
    assert(r.type == "ACK" and r.seq == 0)

    -- ATTACH to j1
    ep.queue("peerA", framing.encode("ATTACH", 1, SECRET, "j1"))
    serve:step()
    local r2 = framing.decode(ep.sent[2].msg.f)
    assert(r2.type == "ACK" and r2.seq == 1)
    assert(c1.attached == "peerA", "console must record the attached peer")
end)

test("ATTACH to an unknown job -> DENY, console unchanged", function()
    local c1 = job_console.new()
    local ep = make_fake_endpoint()
    local serve = serve_mod.new({ endpoint = ep, secret = SECRET, jobs = { j1 = c1 } })

    ep.queue("peerA", framing.encode("AUTH", 0, SECRET, ""))
    serve:step()
    ep.queue("peerA", framing.encode("ATTACH", 1, SECRET, "nonexistent"))
    serve:step()
    local r = framing.decode(ep.sent[2].msg.f)
    assert(r.type == "DENY")
    assert(c1.attached == nil, "console must NOT be attached to an unknown job")
end)

test("INPUT from an attached peer lands in the job's input queue", function()
    local c1 = job_console.new()
    local ep = make_fake_endpoint()
    local serve = serve_mod.new({ endpoint = ep, secret = SECRET, jobs = { j1 = c1 } })

    -- AUTH + ATTACH first.
    ep.queue("peerA", framing.encode("AUTH", 0, SECRET, ""))
    ep.queue("peerA", framing.encode("ATTACH", 1, SECRET, "j1"))
    serve:step()

    -- Now send INPUT.
    ep.queue("peerA", framing.encode("INPUT", 2, SECRET, "echo hello\n"))
    serve:step()

    assert(c1:input_pending(), "job console must have pending input")
    assert(c1:read_input() == "echo hello", "the exact text sent by the peer must be in the queue")
end)

test("INPUT from a non-attached peer -> DENY, nothing lands in any job's queue", function()
    local c1 = job_console.new()
    local ep = make_fake_endpoint()
    local serve = serve_mod.new({ endpoint = ep, secret = SECRET, jobs = { j1 = c1 } })

    -- AUTH only (no ATTACH).
    ep.queue("peerA", framing.encode("AUTH", 0, SECRET, ""))
    serve:step()

    ep.queue("peerA", framing.encode("INPUT", 1, SECRET, "should not land\n"))
    serve:step()

    local r = framing.decode(ep.sent[2].msg.f)
    assert(r.type == "DENY")
    assert(not c1:input_pending(), "no input should reach the job without an attachment")
end)

test("job output is pushed to the attached peer as OUTPUT frames on step()", function()
    local c1 = job_console.new()
    local ep = make_fake_endpoint()
    local serve = serve_mod.new({ endpoint = ep, secret = SECRET, jobs = { j1 = c1 } })

    -- AUTH + ATTACH.
    ep.queue("peerA", framing.encode("AUTH", 0, SECRET, ""))
    ep.queue("peerA", framing.encode("ATTACH", 1, SECRET, "j1"))
    serve:step()

    -- Simulate the job writing output (as io_patch would do).
    c1:write_output("job says hi\n")

    -- Next step should push OUTPUT to peerA.
    local sent_before = #ep.sent
    serve:step()
    assert(#ep.sent > sent_before, "an OUTPUT frame must be sent")
    local out_frame = framing.decode(ep.sent[#ep.sent].msg.f)
    assert(out_frame.type == "OUTPUT", "frame type must be OUTPUT")
    assert(out_frame.body == "job says hi\n", "output text must match what the job wrote")
end)

test("DETACH removes the attachment; subsequent INPUT is DENYed", function()
    local c1 = job_console.new()
    local ep = make_fake_endpoint()
    local serve = serve_mod.new({ endpoint = ep, secret = SECRET, jobs = { j1 = c1 } })

    -- AUTH + ATTACH.
    ep.queue("peerA", framing.encode("AUTH", 0, SECRET, ""))
    ep.queue("peerA", framing.encode("ATTACH", 1, SECRET, "j1"))
    serve:step()
    assert(c1.attached == "peerA")

    -- DETACH.
    ep.queue("peerA", framing.encode("DETACH", 2, SECRET, ""))
    serve:step()
    assert(c1.attached == nil, "console must be detached after DETACH")

    -- INPUT now denied.
    ep.queue("peerA", framing.encode("INPUT", 3, SECRET, "too late\n"))
    serve:step()
    local r = framing.decode(ep.sent[#ep.sent].msg.f)
    assert(r.type == "DENY")
end)

test("BYE detaches and the session forgets peer state (re-auth needed)", function()
    local c1 = job_console.new()
    local ep = make_fake_endpoint()
    local serve = serve_mod.new({ endpoint = ep, secret = SECRET, jobs = { j1 = c1 } })

    -- AUTH + ATTACH.
    ep.queue("peerA", framing.encode("AUTH", 0, SECRET, ""))
    ep.queue("peerA", framing.encode("ATTACH", 1, SECRET, "j1"))
    serve:step()
    assert(c1.attached == "peerA")

    -- BYE.
    ep.queue("peerA", framing.encode("BYE", 2, SECRET, ""))
    serve:step()
    assert(c1.attached == nil, "console must be detached after BYE")

    -- Now INPUT without re-auth should still work at the session level (same secret) but
    -- there's no attachment so it gets DENYed by the routing layer.
    ep.queue("peerA", framing.encode("INPUT", 3, SECRET, "after bye\n"))
    serve:step()
    local r = framing.decode(ep.sent[#ep.sent].msg.f)
    assert(r.type == "DENY")
end)

test("wrong secret is DENYed at the session layer before routing sees it", function()
    local c1 = job_console.new()
    local ep = make_fake_endpoint()
    local serve = serve_mod.new({ endpoint = ep, secret = SECRET, jobs = { j1 = c1 } })

    ep.queue("peerA", framing.encode("AUTH", 0, "wrong-secret", ""))
    serve:step()
    assert(#ep.sent == 1)
    local r = framing.decode(ep.sent[1].msg.f)
    assert(r.type == "DENY")
    -- The job console must be untouched.
    assert(c1.attached == nil and not c1:input_pending())
end)

test("two peers can attach to the same job independently (last-attach wins)", function()
    local c1 = job_console.new()
    local ep = make_fake_endpoint()
    local serve = serve_mod.new({ endpoint = ep, secret = SECRET, jobs = { j1 = c1 } })

    -- peerA attaches.
    ep.queue("peerA", framing.encode("AUTH", 0, SECRET, ""))
    ep.queue("peerA", framing.encode("ATTACH", 1, SECRET, "j1"))
    serve:step()
    assert(c1.attached == "peerA")

    -- peerB attaches to the same job (replaces peerA).
    ep.queue("peerB", framing.encode("AUTH", 0, SECRET, ""))
    ep.queue("peerB", framing.encode("ATTACH", 1, SECRET, "j1"))
    serve:step()
    assert(c1.attached == "peerB", "last attach wins")

    -- peerA's INPUT is now DENYed (no longer attached).
    ep.queue("peerA", framing.encode("INPUT", 2, SECRET, "stale\n"))
    serve:step()
    local r = framing.decode(ep.sent[#ep.sent].msg.f)
    assert(r.type == "DENY")

    -- peerB's INPUT works.
    ep.queue("peerB", framing.encode("INPUT", 2, SECRET, "fresh\n"))
    serve:step()
    assert(c1:read_input() == "fresh", "read_input pops one line, newline stripped - matches its own documented contract")
end)

print(string.format("ALL %d SERVE TESTS PASSED", passed))
