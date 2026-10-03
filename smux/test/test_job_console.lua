-- Tests for smux/job_console.lua (pure per-job input/output buffer + attach routing).
-- Run from repo root: lua5.3 smux/test/test_job_console.lua
package.path = "./?.lua;./nodelib/?.lua;./hmi/?.lua;" .. package.path

local job_console = require("smux/job_console")

local passed = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error("FAIL " .. name .. ": " .. tostring(err), 0) end
    passed = passed + 1
    print("PASS " .. name)
end

test("input queue: push/read round-trips lines in order", function()
    local c = job_console.new()
    assert(not c:input_pending())
    c:push_input("hello\nworld\n")
    assert(c:input_pending())
    assert(c:read_input() == "hello")
    assert(c:read_input() == "world")
    assert(c:read_input() == "", "empty once drained")
    assert(not c:input_pending())
end)

test("input queue: a chunk without a trailing newline is returned whole", function()
    local c = job_console.new()
    c:push_input("partial line no newline yet")
    assert(c:read_input() == "partial line no newline yet")
    assert(not c:input_pending())
end)

test("output buffer: write/drain round-trips and respects max_len", function()
    local c = job_console.new()
    assert(not c:output_pending())
    c:write_output("abcdef")
    assert(c:output_pending())
    assert(c:drain_output(3) == "abc")
    assert(c:drain_output(100) == "def", "remaining bytes returned even if max_len is larger")
    assert(not c:output_pending())
end)

test("attach routing: set_attached records and clears the peer", function()
    local c = job_console.new()
    assert(c.attached == nil)
    c:set_attached("1.2.3.4")
    assert(c.attached == "1.2.3.4")
    c:set_attached(nil)
    assert(c.attached == nil)
end)

test("reset clears all state", function()
    local c = job_console.new()
    c:push_input("x\n"); c:write_output("y"); c:set_attached("p")
    c:reset()
    assert(not c:input_pending())
    assert(not c:output_pending())
    assert(c.attached == nil)
end)

print(string.format("ALL %d JOB_CONSOLE TESTS PASSED", passed))
