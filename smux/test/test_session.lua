-- Tests for smux/session.lua (pure auth/lockout/duplicate/idle logic) and its interaction with
-- framing. Run from repo root: lua5.3 smux/test/test_session.lua
package.path = "./?.lua;./nodelib/?.lua;./hmi/?.lua;" .. package.path

local framing = require("smux/framing")
local session_mod = require("smux/session")

local passed = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error("FAIL " .. name .. ": " .. tostring(err), 0) end
    passed = passed + 1
    print("PASS " .. name)
end

-- Helper: build a session whose execute() records calls and returns an ACK.
local function make_session(secret, opts)
    local executed = {}
    opts = opts or {}
    local sess = session_mod.new({
        secret = secret,
        max_failures = opts.max_failures,
        lockout = opts.lockout,
        idle_timeout = opts.idle_timeout,
        execute = function(peer, frame)
            executed[#executed + 1] = { peer = peer, type = frame.type, seq = frame.seq }
            return { framing.encode("ACK", frame.seq, "", "") }
        end,
    })
    return sess, executed
end

local SECRET = "correct-horse-battery-staple"

test("a correct token authenticates and the request executes exactly once", function()
    local sess, executed = make_session(SECRET)
    local frame = framing.encode("AUTH", 1, SECRET, "")
    local replies = sess:handle("peerA", frame, 0)
    assert(#replies == 1, "expected one reply")
    local r = framing.decode(replies[1])
    assert(r.type == "ACK" and r.seq == 1)
    assert(#executed == 1, "execute should be called exactly once")
end)

test("a wrong token is denied and does NOT execute", function()
    local sess, executed = make_session(SECRET)
    local frame = framing.encode("AUTH", 1, "wrong-secret", "")
    local replies = sess:handle("peerA", frame, 0)
    assert(#replies == 1)
    assert(framing.decode(replies[1]).type == "DENY")
    assert(#executed == 0, "execute must not run for a bad token")
end)

test("empty vs non-empty secret: empty frame token is denied", function()
    local sess = make_session(SECRET)
    local frame = framing.encode("AUTH", 1, "", "")
    assert(framing.decode(sess:handle("p", frame, 0)[1]).type == "DENY")
end)

test("5 consecutive failures lock the peer out; frames during lockout are dropped with NO reply", function()
    local sess = make_session(SECRET, { max_failures = 3, lockout = 10 })
    -- First two failures: DENY each.
    for i = 1, 2 do
        assert(framing.decode(sess:handle("p", framing.encode("AUTH", i, "bad", ""), i)[1]).type == "DENY")
    end
    -- Third failure trips the lockout (still one final DENY).
    local r3 = sess:handle("p", framing.encode("AUTH", 3, "bad", ""), 3)
    assert(#r3 == 1 and framing.decode(r3[1]).type == "DENY")

    -- Now locked out until t=13. A CORRECT token must be dropped with no reply while locked.
    local r4 = sess:handle("p", framing.encode("AUTH", 4, SECRET, ""), 5)
    assert(#r4 == 0, "locked peer's frames are dropped silently (no reply)")

    -- After the lockout window elapses, a correct token works again.
    local r5 = sess:handle("p", framing.encode("AUTH", 5, SECRET, ""), 13)
    assert(#r5 == 1 and framing.decode(r5[1]).type == "ACK")
end)

test("a successful auth resets the failure streak (no spurious lockout)", function()
    local sess = make_session(SECRET, { max_failures = 2 })
    -- One failure...
    assert(framing.decode(sess:handle("p", framing.encode("AUTH", 1, "bad", ""), 0)[1]).type == "DENY")
    -- ...then a success resets the counter...
    assert(framing.decode(sess:handle("p", framing.encode("AUTH", 2, SECRET, ""), 1)[1]).type == "ACK")
    -- ...so one more failure is just another DENY, not a lockout.
    local r = sess:handle("p", framing.encode("AUTH", 3, "bad", ""), 2)
    assert(#r == 1 and framing.decode(r[1]).type == "DENY")
end)

test("duplicate seq replays the stored reply without re-executing; older seq is dropped", function()
    local sess, executed = make_session(SECRET)
    -- Handle seq=1 (executes).
    local first = sess:handle("p", framing.encode("ATTACH", 1, SECRET, "job1"), 0)
    assert(#first == 1 and #executed == 1)

    -- Re-send the SAME seq=1: must replay the identical reply and NOT execute again.
    local replay = sess:handle("p", framing.encode("ATTACH", 1, SECRET, "job1"), 1)
    assert(#replay == 1, "duplicate should still get a reply")
    assert(replay[1] == first[1], "replayed frame must be byte-identical to the original reply")
    assert(#executed == 1, "execute must NOT run again for a duplicate seq")

    -- A seq LOWER than the last handled one is dropped with no reply.
    local older = sess:handle("p", framing.encode("ATTACH", 0, SECRET, "job1"), 2)
    assert(#older == 0, "seq lower than last must be dropped silently")

    -- A seq MORE than 1 ahead (client restarted counting) executes normally.
    local ahead = sess:handle("p", framing.encode("ATTACH", 99, SECRET, "job2"), 3)
    assert(#ahead == 1 and #executed == 2)
end)

test("idle expiry forgets a silent peer; an active peer is kept", function()
    local sess = make_session(SECRET, { idle_timeout = 100 })
    -- Two peers authenticate at t=0.
    assert(framing.decode(sess:handle("active", framing.encode("AUTH", 1, SECRET, ""), 0)[1]).type == "ACK")
    assert(framing.decode(sess:handle("silent", framing.encode("AUTH", 1, SECRET, ""), 0)[1]).type == "ACK")

    -- 'active' keeps sending; 'silent' does not.
    sess:handle("active", framing.encode("AUTH", 2, SECRET, ""), 30)
    sess:handle("active", framing.encode("AUTH", 3, SECRET, ""), 59)

    -- At t=120 the silent peer (last active at t=0) is past idle_timeout; active (t=59) is not.
    local removed = sess:forget_idle(120)
    assert(removed == 1, "exactly one (the silent) peer should be forgotten")

    -- The forgotten peer must re-authenticate from scratch (its last_seq state is gone).
    local r = sess:handle("silent", framing.encode("AUTH", 1, SECRET, ""), 121)
    assert(#r == 1 and framing.decode(r[1]).type == "ACK")
end)

test("malformed frames are dropped silently (no crash, no reply)", function()
    local sess = make_session(SECRET)
    assert(#sess:handle("p", "garbage{{", 0) == 0)
    assert(#sess:handle("p", "", 0) == 0)
    assert(#sess:handle("p", "SMX1 AUTH 0 5 3\nab", 0) == 0, "truncated payload must be dropped")
end)

test("a handler that raises is contained (session does not crash), replies DENY", function()
    local sess = session_mod.new({
        secret = SECRET,
        execute = function() error("boom in handler") end,
    })
    local r = sess:handle("p", framing.encode("AUTH", 1, SECRET, ""), 0)
    assert(#r == 1 and framing.decode(r[1]).type == "DENY")
end)

test("peers() lists tracked peers in stable order", function()
    local sess = make_session(SECRET)
    sess:handle("b", framing.encode("AUTH", 1, SECRET, ""), 0)
    sess:handle("a", framing.encode("AUTH", 1, SECRET, ""), 0)
    local list = sess:peers()
    assert(#list == 2 and list[1] == "a" and list[2] == "b")
end)

print(string.format("ALL %d SESSION TESTS PASSED", passed))
