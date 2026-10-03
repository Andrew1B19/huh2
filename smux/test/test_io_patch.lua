-- Tests for smux/io_patch.lua: proves the Gmux-60_io-style redirect mechanism routes a job's
-- print()/io.write into its console output buffer and io.read out of its input queue, using an
-- INJECTED fake io (so this runs under plain lua5.3 without touching PUC Lua's real io).
-- Run from repo root: lua5.3 smux/test/test_io_patch.lua
package.path = "./?.lua;./nodelib/?.lua;./hmi/?.lua;" .. package.path

local job_console = require("smux/job_console")
local io_patch = require("smux/io_patch")

local passed = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error("FAIL " .. name .. ": " .. tostring(err), 0) end
    passed = passed + 1
    print("PASS " .. name)
end

-- A minimal fake io table with the same call surface smux/io_patch uses (input/output/error/write,
-- each a getter/setter pair). Handles are opaque; we just record which one is current.
local function make_fake_io()
    local state = { _in = "REAL_IN", _out = "REAL_OUT", _err = "REAL_ERR" }
    local f = {}
    f.input  = function(h) if h == nil then return state._in end; state._in = h; return true end
    f.output = function(h) if h == nil then return state._out end; state._out = h; return true end
    f.error  = function(h) if h == nil then return state._err end; state._err = h; return true end
    -- io.write as a plain callable (Gmux swaps it out explicitly).
    f.write = function(...) return "REAL_WRITE" end
    return f
end

test("make_sink routes write() into the console output buffer and read() out of its input queue", function()
    local c = job_console.new()
    local sink = io_patch.make_sink(c)
    sink:write("hello from job\n")
    assert(c:drain_output(100) == "hello from job\n", "written text must land in the console output buffer")

    c:push_input("typed by remote peer\n")
    assert(sink.read() == "typed by remote peer", "read() must return queued input lines")
end)

test("make_sink read() returns nil when nothing is queued (io EOF-style, not a hang)", function()
    local c = job_console.new()
    local sink = io_patch.make_sink(c)
    assert(sink.read() == nil, "no queued input -> nil, matching io.read's no-data behaviour")
end)

test("make_streams exposes distinct stdin/stdout/stderr handles all backed by the same console", function()
    local c = job_console.new()
    local sink = io_patch.make_sink(c)
    local stdin, stdout, stderr = io_patch.make_streams(sink)
    assert(stdin ~= stdout and stdout ~= stderr and stdin ~= stderr, "handles must be distinct objects")
    assert(stdin.tty == true and stdout.tty == true and stderr.tty == true, "marked tty-like like Gmux's core streams")
    -- All three write to the same underlying console buffer.
    stdout:write("A"); stderr:write("B")
    assert(c:drain_output(10) == "AB", "stdout and stderr both land in the one console output buffer")
end)

test("patch() with instances.loads swaps io on load and restores it on unload", function()
    local c = job_console.new()
    local fake_io = make_fake_io()
    local instances = { loads = { load = {}, unload = {} } }

    io_patch.patch(instances, { console = c, io = fake_io })

    -- Before any load handler runs, the real handles are still in place.
    assert(fake_io.input() == "REAL_IN" and fake_io.output() == "REAL_OUT")

    -- Run all load handlers (as process.lua does when a job becomes current).
    for _, f in ipairs(instances.loads.load) do f() end
    local cur_in, cur_out = fake_io.input(), fake_io.output()
    assert(cur_in ~= "REAL_IN" and cur_out ~= "REAL_OUT", "handles must be swapped to the console streams")

    -- A print()-style write through io.write now lands in the job's output buffer.
    fake_io.write("job printed this\n")
    assert(c:drain_output(100) == "job printed this\n", "io.write after load must route into the console")

    -- Run all unload handlers (as process.lua does when a job stops being current).
    for _, f in ipairs(instances.loads.unload) do f() end
    assert(fake_io.input() == "REAL_IN" and fake_io.output() == "REAL_OUT",
        "handles must be restored to the originals after unload")
end)

test("two jobs with separate consoles don't cross-contaminate output", function()
    local cA, cB = job_console.new(), job_console.new()
    local ioA = make_fake_io()
    -- Job A's patch points at console A.
    local instA = { loads = { load = {}, unload = {} } }
    io_patch.patch(instA, { console = cA, io = ioA })
    for _, f in ipairs(instA.loads.load) do f() end
    ioA.write("from job A\n")

    -- Job B's patch points at console B (a different fake io, as each process gets its own).
    local cB_sink = io_patch.make_sink(cB)
    cB_sink:write("from job B\n")

    assert(cA:drain_output(100) == "from job A\n", "job A's output stays in console A")
    assert(cB:drain_output(100) == "from job B\n", "job B's output stays in console B")
end)

print(string.format("ALL %d IO_PATCH TESTS PASSED", passed))
