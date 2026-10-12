-- End-to-end integration test: boots the REAL, unmodified repo files
-- (kernal/bios.lua, kernal/muxos.lua, kernal/compositor.lua,
-- kernal/bitmap.lua, node/bios.lua, node/runtime.lua) under
-- test/emu/emulator.lua's faithful simulation of the native OC
-- primitives, as 1 kernal + 3 worker nodes, and drives the kernal's
-- REPL the same way a human would: injecting key_down signals and
-- reading back what actually landed on the simulated screen. This is
-- deliberately NOT another unit-mock test (the /tmp/test_*.lua suite
-- already covers unit-level logic against hand-copied mirrors of this
-- project's own functions) -- this is the first time the real files,
-- unmodified, run against each other end to end.
--
-- Run with: lua5.3 test/emu/integration_test.lua   (from the repo root)

local REPO_ROOT = (arg and arg[0] and arg[0]:match("^(.*)/test/emu/integration_test%.lua$")) or "."

local function readFile(path)
  local f = assert(io.open(path, "r"), "could not open " .. path)
  local s = f:read("a")
  f:close()
  return s
end

local Emulator = dofile(REPO_ROOT .. "/test/emu/emulator.lua")

local kernalBiosSrc = readFile(REPO_ROOT .. "/kernal/bios.lua")
local muxosSrc = readFile(REPO_ROOT .. "/kernal/muxos.lua")
local compositorSrc = readFile(REPO_ROOT .. "/kernal/compositor.lua")
local bitmapSrc = readFile(REPO_ROOT .. "/kernal/bitmap.lua")
local runtimeSrc = readFile(REPO_ROOT .. "/node/runtime.lua")
local workerBiosSrc = readFile(REPO_ROOT .. "/node/bios.lua")

local emu = Emulator.new()
-- system.timeout() for every node: 1s of host CPU per slice keeps the
-- "too long without yielding" scenarios fast.
emu.timeout = 1

-- --- Build the kernal ---
local kernal = emu:newNode("kernal")
emu:addModem(kernal)
emu:addEeprom(kernal, kernalBiosSrc)
local gpuAddr, screenAddr, screenBuffers = emu:addGpuScreen(kernal, 50, 30)
local kernalFiles = {
  ["/muxos.lua"] = muxosSrc,
  ["/compositor.lua"] = compositorSrc,
  ["/shell.lua"] = readFile(REPO_ROOT .. "/kernal/shell.lua"),
  ["/bitmap.lua"] = bitmapSrc,
  ["/lineedit.lua"] = readFile(REPO_ROOT .. "/kernal/lineedit.lua"),
  ["/system.lua"] = readFile(REPO_ROOT .. "/kernal/system.lua"),
  ["/session.lua"] = readFile(REPO_ROOT .. "/kernal/session.lua"),
  ["/vgpu.lua"] = readFile(REPO_ROOT .. "/kernal/vgpu.lua"),
  ["/terminals.lua"] = readFile(REPO_ROOT .. "/kernal/terminals.lua"),
  ["/etc/kernal.cfg"] = "login_required = false\n",
  ["/runtime.lua"] = runtimeSrc,
  -- Sample programs for the launcher (test 29).
  ["/bin/hello.mxe"] = [==[--[[mxe
muxos = "0.1.2"
libraries = {"greeting", "nosuchlib"}
]]
local greeting = require("greeting")
print(greeting.say("mxe") .. " v=" .. tostring(launch.versionMatch) .. " g=" .. tostring(launch.libraries.greeting)
  .. " n=" .. tostring(launch.libraries.nosuchlib) .. " a=" .. tostring((...)))
]==],
  ["/lib/mxe/greeting.lua"] = [==[return {say = function(name) return "hello " .. name end}]==],
  ["/bin/old.mxe"] = [==[--[[mxe
muxos = "9.9"
]]
print("old-runs v=" .. tostring(launch.versionMatch) .. " want=" .. tostring(launch.requested) .. " have=" .. launch.muxos)
]==],
  ["/bin/counter.mxe"] = [==[--[[mxe
muxos = "0.1.0"
libraries = {"mux"}
]]
local mux = require("mux")
local state = mux.restored() or {n = 0, starts = 0, target = tonumber((...)) or 20}
state.starts = state.starts + 1
mux.migratable(function() return state end)
while state.n < state.target do
  state.n = state.n + 1
  sleep(0.25)
end
print("counter done n=" .. state.n .. " starts=" .. state.starts)
]==],
  ["/bin/ask.lua"] = [==[io.write("name? ")
local name = io.read()
print("hi " .. name .. " gmuxapi=" .. tostring(gmuxapi) .. " os.time=" .. type(os.time))
]==],
  -- Legacy libraries (test 33): the vendored OpenOS ones are added below.
  ["/usr/lib/extralib.lua"] = [==[return {v = "ok"}]==],
  -- A legacy program using files (test 35).
  ["/bin/files.lua"] = [==[local fs = require("filesystem")
local f = io.open("/home/notes.txt", "w")
f:write("line one\n", "line two\n", string.rep("x", 5000), "\n")
f:close()
local r = io.open("/home/notes.txt")
local l1, l2, rest = r:read("l"), r:read("L"), r:read("a")
r:close()
fs.makeDirectory("/home/sub")
fs.copy("/home/notes.txt", "/home/sub/copy.txt")
local names = {} for n in fs.list("/home") do names[#names + 1] = n end
os.setenv("PWD", "/home")
local count = 0 for _ in io.lines("sub/copy.txt") do count = count + 1 end
local ok = pcall(dofile, "/lib/sides.lua") print("fs " .. l1 .. "|" .. l2:gsub("\n", "N") .. "|" .. #rest .. "|" .. table.concat(names, ",") .. "|" .. count .. "|" .. fs.size("/home/sub/copy.txt") .. "|" .. tostring(fs.exists("/home/nope")) .. "|" .. tostring(ok) .. "|" .. tostring(fs.isDirectory("/home/sub"))) error("boom")
]==],
  -- A legacy program using an internet card elsewhere in the cluster (test 36).
  ["/bin/fetch.lua"] = [==[local internet = require("internet")
local body = ""
for chunk in internet.request("http://example/x") do body = body .. chunk end
print("fetched " .. body .. " via " .. require("component").internet.address:sub(1, 8))
]==],
  -- The .mxe spec (test 37): libraries in both search dirs, one needing another.
  ["/usr/lib/mxe/toplib.lua"] = [==[--[[mxe
libraries = {"baselib"}
]]
return {value = require("baselib").v .. "+top"}]==],
  ["/lib/mxe/baselib.lua"] = [==[return {v = "base"}]==],
  ["/bin/spec.mxe"] = [==[--[[mxe
muxos = "0.1.0"
name = "spec"
version = "2.0"
libraries = {"mux", "http", "toplib"}
requires = {"internet", "tape_drive"}
]]
local mux = require("mux")
local args, opts = mux.parseArgs(...)
fs.write("/home/spec/a.txt", "one\ntwo\n")
local f = fs.open("/home/spec/a.txt", "a") f:write("three\n") f:close()
local lines = 0 for _ in fs.read("/home/spec/a.txt"):gmatch("\n") do lines = lines + 1 end
fs.copy("/home/spec/a.txt", "/home/spec/b.txt")
fs.rename("/home/spec/b.txt", "/home/spec/c.txt")
local names = table.concat(fs.list("/home/spec"), ",")
fs.remove("/home/spec/a.txt")
local body, status = require("http").get("http://gitea/repo/hello.txt")
print("spec " .. args[1] .. "|" .. tostring(opts.v) .. tostring(opts.x) .. "|" .. opts.name .. "|" .. require("toplib").value
  .. "|" .. lines .. "|" .. names .. "|" .. tostring(fs.exists("/home/spec/a.txt")) .. "|" .. body .. status
  .. "|" .. tostring(launch.compatible) .. launch.name .. launch.version
  .. "|" .. tostring(launch.components.internet) .. tostring(launch.components.tape_drive))
print("hello " .. tostring(readLine("who? ")))
]==],
  -- OPM, as the installer ships it (test 38).
  ["/bin/opm.mxe"] = readFile(REPO_ROOT .. "/opm/opm.mxe"),
  ["/lib/mxe/opm_core.lua"] = readFile(REPO_ROOT .. "/opm/opm_core.lua"),
  -- A legacy graphics program (test 34).
  ["/bin/paint.lua"] = [==[local component = require("component")
local event = require("event")
local gpu = component.gpu
local w0, h0 = gpu.getResolution()
gpu.setResolution(20, 4)
gpu.setBackground(0x0000FF)
gpu.fill(1, 1, 20, 4, " ")
gpu.set(2, 2, "legacy gfx")
gpu.copy(2, 2, 10, 1, 0, 1)
local buf = gpu.allocateBuffer(5, 1)
gpu.setActiveBuffer(buf)
gpu.set(1, 1, "BUF!!")
gpu.setActiveBuffer(0)
gpu.bitblt(0, 2, 4, 5, 1, buf, 1, 1)
gpu.set(2, 1, "d=" .. w0 .. "x" .. h0 .. " s=" .. tostring(component.isAvailable("screen")))
local _, addr, x, y = event.pull("touch")
gpu.set(2, 1, "touch " .. x .. "," .. y .. " " .. tostring(addr == gpu.getScreen()))
local _, _, nw, nh = event.pull("screen_resized")
gpu.set(2, 1, "size " .. nw .. "x" .. nh .. " res=" .. table.concat({gpu.getResolution()}, "x"))
os.sleep(0.5)
]==],
  ["/bin/libs.lua"] = [==[local serialization = require("serialization")
local text = require("text")
local sides = require("sides")
local colors = require("colors")
local keyboard = require("keyboard")
local event = require("event")
local component = require("component")
local t = serialization.unserialize(serialization.serialize({a = 1, b = "x"}))
local extra = require("extra" .. "lib")
local gpuOk = pcall(function() return component.gpu end)
print("libs t=" .. t.a .. t.b .. " pad=" .. text.padRight("ab", 4) .. "| top=" .. sides.top .. " red=" .. colors.red
  .. " f1=" .. keyboard.keys.f1 .. " extra=" .. extra.v .. " gpu=" .. tostring(gpuOk)
  .. " avail=" .. tostring(component.isAvailable("gpu")) .. " same=" .. tostring(require("text") == text))
io.write("press: ")
local name, _, char = event.pull("key_down")
print("got " .. name .. " " .. string.char(char) .. " held=" .. tostring(keyboard.isKeyDown(string.char(char))))
local ok, err = pcall(require, "nosuchmodule")
print("missing=" .. tostring(ok) .. " " .. (tostring(err):match("module 'nosuchmodule' not found") and "nf" or tostring(err)))
]==],
}
-- The vendored OpenOS libraries, installed as /lib on the kernal's disk.
for _, rel in ipairs({"serialization", "text", "sides", "colors", "keyboard", "transforms", "internet",
    "buffer", "uuid", "bit32", "note",
    "core/full_keyboard", "core/full_text", "core/full_transforms", "core/full_buffer"}) do
  kernalFiles["/lib/" .. rel .. ".lua"] = readFile(REPO_ROOT .. "/kernal/lib/" .. rel .. ".lua")
end
emu:addFilesystem(kernal, kernalFiles)

local function renderScreen()
  local buf = screenBuffers[0]
  local lines = {}
  for y = 1, buf.h do
    local row = buf.cells[y] or {}
    local chars = {}
    for x = 1, buf.w do
      chars[x] = (row[x] and row[x].char) or " "
    end
    lines[#lines + 1] = table.concat(chars)
  end
  return table.concat(lines, "\n")
end

-- The text in screen cells [x, x+n-1] of row y.
local function cellText(x, y, n)
  local row = screenBuffers[0].cells[y] or {}
  local out = {}
  for i = 0, n - 1 do out[#out + 1] = (row[x + i] and row[x + i].char) or " " end
  return table.concat(out)
end
local function touch(name, x, y)
  emu:injectSignal(kernal, name, screenAddr, x, y, 0, "tester")
  emu:advance(0.5)
end
-- Closes the window whose title bar starts at (x, 1) and is `w` wide.
local function closeWindowAt(x, w)
  touch("touch", x + w - 2, 1)
  emu:advance(0.5)
end

local function dumpScreenOnFailure(label)
  io.stderr:write("\n=== screen at failure (" .. label .. ") ===\n" .. renderScreen() .. "\n=== end ===\n")
  io.stderr:write("\n=== emulator log (last 40) ===\n")
  local n = #emu.log
  for i = math.max(1, n - 40), n do
    local e = emu.log[i]
    io.stderr:write(string.format("[%.2f] %s: %s\n", e.t, e.node, e.msg))
  end
end

emu:boot(kernal)
assert(kernal.status == "running", "kernal failed to boot: see log")

-- Hardware for the cluster component bus (test 36): an internet card on
-- the kernal, a redstone card on worker 1.
-- A tiny web for it (tests 37-38): a Gitea-style package catalog.
local GITEA = "http://gitea/repo/"
local webFiles = {
  [GITEA .. "hello.txt"] = "page",
  [GITEA .. "programs.cfg"] = [[{
  ["demo"] = { files = { ["master/demo/demo.lua"] = "/bin", ["master/demo/demolib.lua"] = "/lib" },
               dependencies = { ["demodep"] = "/" }, name = "Demo", description = "a demo program" },
  ["demodep"] = { files = { ["master/demodep/extra.lua"] = "/lib" }, name = "demodep", description = "its dependency" },
}]],
  [GITEA .. "demo/demo.lua"] = 'local VERSION = "1.2"\nprint("demo says " .. require("demolib").msg .. " " .. require("extra").v)\n',
  [GITEA .. "demo/demolib.lua"] = 'return {msg = "hi"}',
  [GITEA .. "demodep/extra.lua"] = 'return {v = "dep"}',
}
local function fakeInternet()
  return {
    request = function(url)
      local chunks = webFiles[url] and {webFiles[url]} or {"hello ", "", "bus"}
      return {
        finishConnect = function() return true end,
        response = function() return 200, "OK", {} end,
        read = function() return table.remove(chunks, 1) end,
        close = function() chunks = {} return true end,
      }
    end,
    isHttpEnabled = function() return true end,
  }
end
local internetAddr = emu:addComponent(kernal, "internet", fakeInternet())
-- Added after the kernal booted: it hears about it, as on real hardware.
emu:injectSignal(kernal, "component_added", internetAddr, "internet")

-- --- Build 3 workers ---
local workers, workerModems, redstoneAddr = {}, {}, nil
for i = 1, 3 do
  local w = emu:newNode("worker")
  workerModems[i] = emu:addModem(w)
  if i == 1 then
    local outputs = {}
    redstoneAddr = emu:addComponent(w, "redstone", {
      getInput = function(side) return side * 10 end,
      setOutput = function(side, v) local old = outputs[side] or 0 outputs[side] = v return old end,
      getOutput = function(side) return outputs[side] or 0 end,
    })
  end
  emu:addEeprom(w, workerBiosSrc)
  emu:boot(w)
  assert(w.status == "running", "worker " .. i .. " failed to boot: see log")
  workers[i] = w
end

-- --- Let discovery settle: kernal's own startup discover(1) plus
-- workers' HELLO broadcasts need a few seconds of simulated time. ---
emu:advance(3)

-- Matches against the screen with row breaks removed, not the raw
-- per-row rendering: the console has no word-wrap (a flat fixed-width
-- character wrap only -- see kernal/muxos.lua's termWrite), so a long
-- word can legitimately split across two rows (confirmed for real: an
-- early version of this test's own "force-releasing fullscreen grant"
-- check failed this exact way, wrapping to "...gran" / "t held...").
-- That's correct console behavior, not something a substring check
-- should be tripped up by.
local function assertScreenContains(substr, label)
  local screen = renderScreen()
  local flat = screen:gsub("\n", "")
  if not flat:find(substr, 1, true) then
    dumpScreenOnFailure(label or substr)
    error("expected screen to contain " .. string.format("%q", substr) .. " (" .. tostring(label) .. ")")
  end
end

-- Keycodes, matching OpenOS's own lib/keyboard.lua constants (verified
-- against its source -- see docs/PROTOCOL.md).
local KEY_ENTER, KEY_BACK = 0x1C, 0x0E

local function typeLine(text)
  for i = 1, #text do
    emu:injectSignal(kernal, "key_down", screenAddr, text:byte(i), 0, "tester")
    emu:step()
  end
  emu:injectSignal(kernal, "key_down", screenAddr, 13, KEY_ENTER, "tester")
  emu:step()
end

print("test 1: kernal booted and discovered all 3 workers")
assertScreenContains("root@muxos:~>", "prompt visible")
-- The startup banner itself may have already scrolled off a short
-- console by now -- that's correct behavior (confirmed: this is a real
-- fixed-height scrolling console, see kernal/muxos.lua's termWrite),
-- not something to assert on. All 3 workers should still be visible in
-- the post-boot discover(1) + listNodes() output, though.
-- Nodes are identified by their network card's address (see
-- kernal/muxos.lua's selfAddr), so check for each worker's own card.
do
  local screen = renderScreen()
  for i, w in ipairs(workers) do
    if not screen:find(w.modemAddr, 1, true) then
      dumpScreenOnFailure("worker discovery")
      error("worker " .. i .. " (card " .. w.modemAddr .. ") not listed after boot")
    end
  end
end
print("  OK -- 3 workers visible on screen after boot")

print("test 2: 'nodes' command lists the same 3 workers")
typeLine("nodes")
emu:advance(2)
assertScreenContains("[1]", "nodes listing index 1")
assertScreenContains("[2]", "nodes listing index 2")
assertScreenContains("[3]", "nodes listing index 3")
print("  OK")

print("test 3: 'run' dispatches a real job to a real worker and gets the real result")
typeLine("run return 21 + 21")
emu:advance(3)
assertScreenContains("42", "run result")
print("  OK -- worker computed 21+21 and returned 42 over the real wire protocol")

print("test 4: 'ping' round-trips a real PING/PONG with a real worker")
typeLine("ping 1 2")
emu:advance(3)
assertScreenContains("replies", "ping report")
print("  OK")

print("test 5: a cooperating long JOB (calls yield()) completes AND the worker stays responsive")
typeLine("run local total = 0 for i = 1, 20000 do total = total + i if i % 500 == 0 then yield() end end return total")
emu:advance(5)
assertScreenContains(string.format("%d", 20000 * 20001 // 2), "cooperating long job result")
print("  OK -- long cooperating job finished with the correct sum")

-- The worker that just ran that long job should still answer a ping --
-- proof the yield()/circuit-breaker design (docs/PROTOCOL.md's "JOB
-- code and the non-yielding timeout") actually keeps it responsive,
-- not just that the job eventually returns.
typeLine("ping 1 1")
emu:advance(3)
assertScreenContains("reply from", "ping after long job")
print("  OK -- worker still answers PING immediately after a long cooperating job")

print("test 6: a NON-cooperating long JOB is ended by the machine's deadline, not the worker")
typeLine("run local x = 0 while true do x = x + 1 end")
emu:advance(4)
assertScreenContains("error", "non-cooperating job error")
assertScreenContains("too long without yielding", "the machine's own deadline ended the job")
print("  OK -- non-cooperating job was killed with the expected error, worker itself survived")

-- Confirm the worker that ran it is STILL alive and answering, not
-- silently dead.
typeLine("ping 1 1")
emu:advance(3)
assertScreenContains("reply from", "ping after killed job")
print("  OK -- worker still answers PING after its runaway job was killed")

print("test 7: creating a character-mode window actually draws on the real compositor/gpu")
typeLine("window hi 2 2 10 1 gpu.set(1,1,\"HELLO\")")
emu:advance(2)
do
  local screen = renderScreen()
  if not screen:find("HELLO", 1, true) then
    dumpScreenOnFailure("window draw")
    error("expected the window's drawn text to appear on the composited screen")
  end
end
print("  OK -- window content actually composited onto the real screen buffer")

print("test 8: bitdemo draws a bit window (half-block) without crashing the compositor")
typeLine("bitdemo halfblock 20 2")
emu:advance(2)
assertScreenContains("created bit window", "bitdemo confirmation")
print("  OK")

print("test 9: fullscreen grant round trip -- a worker's gpu face is gated correctly, for real")
typeLine('run local s, serr = gpu.set(1,1,"blocked?") return tostring(s) .. "|" .. tostring(serr)')
emu:advance(2)
assertScreenContains("direct gpu/screen access is blocked", "gpu blocked before any grant")
print("  OK -- worker's gpu.set is blocked by default, as expected")

typeLine('run local a = gmuxapi.request_fullscreen() local s = gpu.set(45,1,"X") local r = gmuxapi.release_fullscreen() local b, berr = gpu.set(45,1,"Y") return tostring(s) .. "|" .. tostring(b) .. "|" .. tostring(berr)')
emu:advance(3)
assertScreenContains("true|nil|", "fullscreen round trip result")
assertScreenContains("blocked", "blocked again after release")
print("  OK -- gpu.set succeeded while the grant was held, and was blocked again after releasing it")

print("test 10: Ctrl+Alt+C -- a press exits fullscreen (releasing a stuck grant), holding it enters console mode")
-- worker 1 grabs the grant and deliberately never releases it, hanging
-- on to it like a stuck program (the grant goes when its process ends).
typeLine('spawn 1 gmuxapi.request_fullscreen() sleep(12)')
emu:advance(2)
-- worker 2 trying to grab it now must be denied. The console is a
-- compositor window, and compositing is suspended while a node owns the
-- screen, so this denial only becomes visible once fullscreen is exited.
typeLine('run local g, gerr = gmuxapi.request_fullscreen() return tostring(g) .. "|" .. tostring(gerr)')
emu:advance(2)

-- Ctrl+Alt+C as real key_down/key_up signals (OpenOS's keycodes),
-- held for `holdFor` seconds before the keys are released.
local KEY_LCONTROL, KEY_LMENU, KEY_C = 0x1D, 0x38, 0x2E
local function pressCombo(holdFor)
  emu:injectSignal(kernal, "key_down", screenAddr, 0, KEY_LCONTROL, "tester"); emu:step()
  emu:injectSignal(kernal, "key_down", screenAddr, 0, KEY_LMENU, "tester"); emu:step()
  emu:injectSignal(kernal, "key_down", screenAddr, string.byte("c"), KEY_C, "tester"); emu:step()
  emu:advance(holdFor or 0.2)
  emu:injectSignal(kernal, "key_up", screenAddr, string.byte("c"), KEY_C, "tester"); emu:step()
  emu:injectSignal(kernal, "key_up", screenAddr, 0, KEY_LMENU, "tester"); emu:step()
  emu:injectSignal(kernal, "key_up", screenAddr, 0, KEY_LCONTROL, "tester"); emu:step()
  emu:advance(0.5)
end

pressCombo()
assertScreenContains("already held by", "second requester was denied while the grant was held")
assertScreenContains("force-releasing fullscreen grant", "a press force-released the stuck grant")
if renderScreen():gsub("\n", ""):find("console only", 1, true) then
  dumpScreenOnFailure("press vs hold")
  error("a short press entered console mode; only holding should")
end
print("  OK -- a press exited fullscreen, releasing the stuck grant, without entering console mode")
pressCombo(1.5)
assertScreenContains("console only", "holding Ctrl+Alt+C entered console mode")
print("  OK -- holding Ctrl+Alt+C dropped into the full-screen kernal console")

-- Confirm the grant is ACTUALLY free now: a fresh request succeeds (and
-- is released again in the same job, so the console stays visible).
typeLine('run local g = gmuxapi.request_fullscreen() local r = gmuxapi.release_fullscreen() return tostring(g ~= nil) .. "|" .. tostring(r ~= nil)')
emu:advance(2)
assertScreenContains("true|true", "grant actually available again after Ctrl+Alt+C")
print("  OK -- fullscreen grant was genuinely free after the interrupt, not just the message")

print("test 11: node/runtime.lua never reassigns kernalAddr after boot (structural regression check)")
-- An end-to-end "spoof a peer message and see if kernalAddr breaks"
-- scenario was tried here first and REMOVED after proving itself
-- misleading: verified by deliberately reintroducing the old bug
-- (`kernalAddr = msg.from` on any message) and re-running that
-- scenario -- it still passed, because in the CURRENT protocol every
-- job dispatch is itself a legitimate kernal-origin message that heals
-- the corruption immediately before the vulnerable gpu-face call ever
-- runs. The bug is real and the fix is still correct -- it matters
-- the moment direct peer (parent/child) messaging exists, since a
-- long-running cooperating job could receive a peer message between
-- gmuxapi calls with no intervening kernal message to heal it -- but
-- the CURRENT protocol has no path that actually exploits it yet, so
-- an end-to-end test for it would either need peer messaging to exist
-- first or would silently test nothing, as happened here.
--
-- What's actually checked instead, honestly: the real source has
-- exactly ONE assignment to kernalAddr (the boot-handoff capture),
-- and no reassignment anywhere in the message-dispatch loop. Cheap,
-- precise, and catches exactly the regression that matters -- if
-- `kernalAddr = msg.from` (or equivalent) ever reappears in the
-- dispatch loop, this fails immediately.
do
  local runtimeSource = readFile(REPO_ROOT .. "/node/runtime.lua")
  local assignments = {}
  for line in runtimeSource:gmatch("[^\n]+") do
    -- Skip comment lines -- the fix's own explanatory comment
    -- mentions the OLD buggy assignment by name as a `-- Real bug,
    -- fixed: ... kernalAddr = msg.from ...` note, which would
    -- otherwise false-positive this check.
    local codePart = line:match("^([^%-]*)%-%-") or line
    local stmt = codePart:match("kernalAddr%s*=%s*[^=].*")
    if stmt then assignments[#assignments + 1] = line end
  end
  if #assignments ~= 1 then
    io.stderr:write("kernalAddr assignments found:\n")
    for _, a in ipairs(assignments) do io.stderr:write("  " .. a .. "\n") end
    error("expected exactly ONE assignment to kernalAddr (the boot-handoff capture), found " .. #assignments)
  end
  assert(assignments[1]:match("kernalAddr%s*=%s*%.%.%."),
    "the one kernalAddr assignment must be the boot-handoff capture (`kernalAddr = ...`), got: " .. assignments[1])
end
print("  OK -- exactly one kernalAddr assignment in the real source, and it's the boot-handoff capture")

print("test 12: parent/child jobs -- orphan/promote/kill policies, applied for real when the parent finishes")
-- A single job (dispatched via `run`, so it's a plain top-level job
-- with no parent of its own) spawns THREE children with the three
-- different orphan policies, then returns their ids. Once this `run`
-- job itself completes, kernal/muxos.lua's
-- applyOrphanPolicyForChildrenOf fires for real -- this is the actual
-- mechanism from docs/PROTOCOL.md's ".mxe process model", not a mock
-- of it.
typeLine('run local a=gmuxapi.create_headless_process({code="local t=0 for i=1,2000 do t=t+1 if i%50==0 then yield() end end return t", name="testapp", orphan_policy="orphan"}); local b=gmuxapi.create_headless_process({code="return 123", name="testapp", orphan_policy="promote"}); local c=gmuxapi.create_headless_process({code="for i=1,400 do sleep(0.05) end return 1", name="testapp", orphan_policy="kill"}); return tostring(a.process.id) .. "," .. tostring(b.process.id) .. "," .. tostring(c.process.id)')
emu:advance(3)

local childIds
do
  local screen = renderScreen():gsub("\n", "")
  local a, b, c = screen:match("(%d+),(%d+),(%d+)")
  if not a then
    dumpScreenOnFailure("parent job's spawned child ids")
    error("could not find the three spawned child ids on screen")
  end
  childIds = {orphan = tonumber(a), promote = tonumber(b), kill = tonumber(c)}
end
print("  OK -- parent job spawned 3 children: orphan=" .. childIds.orphan ..
  " promote=" .. childIds.promote .. " kill=" .. childIds.kill)

-- Give the "kill" child's own cooperative loop a chance to actually
-- receive the KILL broadcast (it only checks at its own yield points --
-- see node/runtime.lua's runJobCode/isKillSignalFor). This also
-- exercised a real, separate bug the first time this scenario ran:
-- the "kill" child happened to land (round-robin) on the SAME node
-- already running its own parent, and remoteRequest()'s nested wait
-- was silently discarding the child's own incoming JOB dispatch while
-- waiting for its unrelated SPAWN reply -- fixed in remoteRequest
-- itself (see its own comment) by pushing back anything that isn't
-- the awaited reply instead of dropping it.
emu:advance(2)

typeLine("processes")
emu:advance(2)
assertScreenContains("[" .. childIds.kill .. "] killed", "kill-policy child shows as killed")
assertScreenContains("killed (orphan policy", "kill-policy child's error names the real reason")
print("  OK -- the kill-policy child was actually killed once its parent finished, not just bookkept")

typeLine('run local list = gmuxapi.get_orphans("testapp") local n = 0 for _ in pairs(list) do n = n + 1 end local firstId = n > 0 and list[1].id or -1 return "count=" .. n .. " id=" .. firstId')
emu:advance(3)
assertScreenContains("count=1 id=" .. childIds.orphan, "get_orphans returns exactly the orphan-policy child, not the promoted or killed ones")
print("  OK -- gmuxapi.get_orphans(\"testapp\") returned exactly the orphan-policy child (" .. childIds.orphan .. "), excluding promote and kill")

typeLine('run local list = gmuxapi.get_orphans("testapp") local n = 0 for _ in pairs(list) do n = n + 1 end return "count=" .. n')
emu:advance(3)
assertScreenContains("count=0", "orphans are claimed once -- a second get_orphans call for the same name returns nothing")
print("  OK -- orphan was claimed once; a second get_orphans call returns none")

print("test 13: fan-out cap -- a job tree can't have more running jobs than there are worker nodes (3)")
-- The parent job itself counts as "running" in its own tree while it's
-- spawning children (it hasn't returned yet), so with 3 worker nodes
-- the cap (#nodeOrder == 3) allows the parent plus only 2 children
-- before a 3rd spawn attempt is rejected. Each child needs to still be
-- "running" (not finished) through all three back-to-back spawn round
-- trips below for that cap to actually bind.
--
-- The child sleeps with sleep(): a CPU-bound loop (even with yield())
-- finishes in zero simulated time, because the emulator only advances
-- its clock for a real timed wait, so a busy-loop child would already
-- be done -- and out of the tree's count -- before the 3rd spawn.
typeLine('run local childCode="sleep(5) return 1" local ok1,e1=gmuxapi.create_headless_process({code=childCode,name="fanout"}) local ok2,e2=gmuxapi.create_headless_process({code=childCode,name="fanout"}) local ok3,e3=gmuxapi.create_headless_process({code=childCode,name="fanout"}) return "r1="..tostring(ok1~=nil).." r2="..tostring(ok2~=nil).." r3="..tostring(ok3~=nil).." e3="..tostring(e3)')
emu:advance(3)
assertScreenContains("r1=true r2=true r3=false", "first two children succeed, third is rejected")
assertScreenContains("fan-out cap reached", "rejection names the real reason")
print("  OK -- 1st and 2nd child spawns succeeded, 3rd was rejected once the tree hit the 3-node cap")

-- Test 13's own two surviving children are still mid-sleep (5
-- simulated seconds from when each started, and only 3 of those have
-- passed) -- drain that before
-- test 14 starts anything new, so every worker node is actually free
-- rather than queued up behind a sleeper that has nothing to do with
-- this next test.
emu:advance(3)

print("test 14: window focus -- ownership + default/explicit focus")
-- create_graphics_process spawns a job AND a window FOR it, in one
-- call -- the window's ownerJobId should be that job's own id, not
-- whichever node happened to make the CREATEWINDOW request (this
-- `run` job's own node, not the spawned child's). The child just
-- sleeps so there's no race with the checks below.
typeLine('run local r=gmuxapi.create_graphics_process({code="sleep(5) return 1", name="focustest", width=10, height=5}) return tostring(r.process.id) .. "," .. tostring(r.window.id) .. "," .. tostring(r.window.ownerJobId)')
emu:advance(2)

local focusProcId, focusWinId
do
  local screen = renderScreen():gsub("\n", "")
  local p, w, owner = screen:match("(%d+),(%d+),(%d+)")
  if not p then
    dumpScreenOnFailure("create_graphics_process ids")
    error("could not find process/window/owner ids on screen")
  end
  assert(p == owner, "the new window's ownerJobId must be the SPAWNED child's own id -- got process=" .. p .. " owner=" .. owner)
  focusProcId, focusWinId = p, w
end
print("  OK -- create_graphics_process's window is owned by the job it was created for (job " .. focusProcId .. ", window " .. focusWinId .. ")")

-- While that window is focused and its process is alive, keystrokes go
-- to the process (test 28), so let it finish (it sleeps 5s) before
-- typing more commands -- with its owner gone, input falls back to the
-- console even though the window keeps focus.
emu:advance(5)

typeLine("windows")
emu:advance(2)
assertScreenContains("[" .. focusWinId .. "]", "graphics-process window listed")
assertScreenContains("(focused)", "the newest window takes focus by default")
assertScreenContains("(owner job " .. focusProcId .. ")", "the listing shows the real owning job, not just that one exists")
print("  OK -- the new window took focus by default and shows its real owning job")

-- A second, plain window (REPL `window` command, no owning job at
-- all) should steal focus the same way -- "new window = new focus" is
-- unconditional, not special-cased to only graphics-process windows.
typeLine("window plain 1 1 5 3 gpu.set(1,1,\"x\")")
emu:advance(2)
local plainWinId = renderScreen():gsub("\n", ""):match("created window %[(%d+)%]")
assert(plainWinId, "expected the plain window's own id to be echoed")
typeLine("windows")
emu:advance(2)
assertScreenContains("[" .. plainWinId .. "]", "plain window listed")
assertScreenContains("[" .. plainWinId .. "] \"plain\"  5x3 at (1,1) (focused)", "the plain window has no owner tag and now holds focus, having been created more recently")
print("  OK -- a plain, ownerless window still takes focus on creation, same as an owned one")

-- Explicit `focus <id>` (the manual stand-in for a gesture that
-- doesn't exist yet -- no mouse/click anywhere in this project) moves
-- focus back, and is reflected the same way in `windows`.
typeLine("focus " .. focusWinId)
emu:advance(2)
assertScreenContains("window [" .. focusWinId .. "] focused", "focus command confirms the change")
typeLine("windows")
emu:advance(2)
assertScreenContains("[" .. focusWinId .. "]", "graphics-process window still listed")
assertScreenContains("(owner job " .. focusProcId .. ")", "owner tag still present after refocusing")
print("  OK -- `focus <id>` moves focus back explicitly, observable via `windows`")

typeLine("focus 99999")
emu:advance(2)
assertScreenContains("error: no such window", "focusing a nonexistent window id is rejected, not silently accepted")
print("  OK -- focusing a nonexistent window id fails with a clear error, leaving focus unchanged")

-- Returns everything after the LAST occurrence of `marker` on the
-- (row-joined) screen, so an assertion can't be satisfied by output
-- left over from an earlier test.
local function screenAfter(marker)
  local flat = renderScreen():gsub("\n", "")
  local last
  local from = 1
  while true do
    local s = flat:find(marker, from, true)
    if not s then break end
    last, from = s, s + 1
  end
  if not last then
    dumpScreenOnFailure("marker " .. marker)
    error("marker " .. marker .. " not on screen")
  end
  return flat:sub(last)
end

print("test 15: a job returning an unserializable value gets an ERROR back, and the worker survives")
-- send() used to raise straight out of the worker's main loop when the
-- RESULT couldn't be serialized, killing that worker's runtime outright.
emu:advance(5)
typeLine("runall return function() end")
emu:advance(4)
typeLine('runall return "alive" .. 15')
emu:advance(4)
do
  local after = screenAfter("runall return function")
  local errors = 0
  for _ in after:gmatch("could not send job result") do errors = errors + 1 end
  local alive = 0
  for _ in after:gmatch("alive15") do alive = alive + 1 end
  if errors ~= 3 or alive ~= 3 then
    dumpScreenOnFailure("unserializable result")
    error("expected 3 result-send errors and 3 live workers, got " .. errors .. " and " .. alive)
  end
end
print("  OK -- each worker reported the bad result as an error and still answered the next job")

print("test 16: a forged `from` can't release someone else's fullscreen grant")
pressCombo() -- leave console mode
typeLine("spawn 1 gmuxapi.request_fullscreen() sleep(10)") -- held while it runs
emu:advance(2)
local holder = screenAfter("spawn 1 gmuxapi"):match("spawned job %[%d+%] on (modem%-%x+)")
assert(holder, "could not find the fullscreen holder's address")
local forger
for _, w in ipairs(workers) do
  if w.modemAddr ~= holder then forger = w.modemAddr break end
end
-- Sent by `forger`'s card, but claiming to be the holder.
local forged = string.format('MSG 990001 1/1 {["type"]="RELEASEFULLSCREEN",["from"]=%q,["to"]=%q,["id"]=990001}',
  holder, kernal.modemAddr)
emu:injectSignal(kernal, "modem_message", kernal.modemAddr, forger, 4477, 0, forged)
emu:advance(1)
typeLine('run return "MARK16"')
emu:advance(2)
pressCombo()
if not screenAfter("MARK16"):find("force-releasing fullscreen grant held by " .. holder, 1, true) then
  dumpScreenOnFailure("forged release")
  error("the forged RELEASEFULLSCREEN released the real holder's grant")
end
print("  OK -- the grant was still held by " .. holder .. " after a forged release from " .. forger)

print("test 17: a kill-policy child still QUEUED behind another job is killed, not run")
-- nodeOrder[2] gets a 5-second sleeper; the parent on nodeOrder[1] then
-- pins a kill-policy child onto that busy node and returns at once. The
-- KILL arrives while the sleeper is running -- before the child has
-- started -- and used to be swallowed by the sleeper's own wait.
emu:advance(5)
typeLine('spawn 2 sleep(5) return 1')
emu:advance(1)
local busyNode = screenAfter("spawn 2 sleep(5)"):match("spawned job %[%d+%] on (modem%-%x+)")
assert(busyNode, "could not find the busy node's address")
typeLine('spawn 1 gmuxapi.create_headless_process({code="return 17", orphan_policy="kill", node="' .. busyNode .. '"})')
emu:advance(8)
-- The full `processes` listing is longer than the screen by now, so
-- ask for the newest kill-policy job's status directly.
typeLine('run local last for _, p in ipairs(gmuxapi.get_processes()) do if p.orphanPolicy == "kill" then last = p end end return "K17=" .. tostring(last.status) .. "/" .. tostring(last.error)')
emu:advance(3)
if not screenAfter("K17="):find("K17=killed/killed (orphan policy", 1, true) then
  dumpScreenOnFailure("queued kill-policy child")
  error("the queued kill-policy child was not killed")
end
print("  OK -- the queued child was killed when it reached the front of the queue")

print("test 18: window draw code runs sandboxed on the kernal")
-- CREATEWINDOW code comes from any worker and runs ON the kernal, so it
-- must not see the kernal's globals or the raw gpu, and must not be able
-- to hang the kernal.
typeLine("window sb 1 1 5 1 component.list()")
emu:advance(1)
if not screenAfter("window sb 1 1 5 1"):find("window draw code failed", 1, true) then
  dumpScreenOnFailure("window sandbox")
  error("window draw code could reach the kernal's `component` global")
end
typeLine("window gs 1 1 5 1 gpu.setActiveBuffer(0)")
emu:advance(1)
if not screenAfter("window gs 1 1 5 1"):find("isn't available to window draw code", 1, true) then
  dumpScreenOnFailure("window gpu whitelist")
  error("window draw code could switch the gpu off its own buffer")
end
print("  OK -- no kernal globals, and only drawing calls on its own buffer")
typeLine("window spin 1 1 5 1 while true do end")
emu:advance(1)
if not screenAfter("window spin 1 1 5 1"):find("too long without yielding", 1, true) then
  dumpScreenOnFailure("window budget")
  error("a non-terminating window draw was not stopped")
end
typeLine('run return "kernal" .. "-ok"')
emu:advance(2)
assertScreenContains("kernal-ok", "kernal still dispatching after a runaway window draw")
print("  OK -- a non-terminating window draw is cut off and the kernal keeps running")

print("test 19: both EEPROM images fit the 4096-byte EEPROM")
-- Comments count toward the limit; node/bios.lua once grew to 4404
-- bytes through comments alone without anything noticing.
for _, path in ipairs({"/node/bios.lua", "/kernal/bios.lua"}) do
  local size = #readFile(REPO_ROOT .. path)
  assert(size <= 4096, path .. " is " .. size .. " bytes, over the 4096-byte EEPROM limit")
  print("  OK -- " .. path:sub(2) .. " is " .. size .. " bytes")
end

print("test 20: Ctrl+Alt+C shows the console alone; `comp` restores the windows")
-- Hold Ctrl+Alt+C for console mode: a window created now is drawn into
-- its buffer but not shown until `comp`.
pressCombo(1.5)
typeLine('window solo 30 2 6 1 gpu.set(1,1,"SO".."LOX")')
emu:advance(1)
if renderScreen():gsub("\n", ""):find("SOLOX", 1, true) then
  dumpScreenOnFailure("solo mode")
  error("a window was shown while the console was in solo mode")
end
typeLine("comp")
emu:advance(1)
assertScreenContains("SOLOX", "window shown again after comp")
print("  OK -- windows hidden in solo mode and shown again after `comp`")

-- Video memory: the console has no buffer at all -- its text is in
-- regular memory, painted into the frame buffer (or straight onto the
-- screen in console mode). The frame buffer is the only full-screen
-- buffer.
do
  local full = 0
  for idx, b in pairs(screenBuffers) do
    if idx ~= 0 and b.w == 50 and b.h == 30 then full = full + 1 end
  end
  assert(full == 1, "expected exactly one full-screen buffer (the frame), found " .. full)
  for idx, b in pairs(screenBuffers) do
    assert(not (b.w == 50 and b.h == 15), "the console has a video buffer (buffer " .. idx .. ")")
  end
end
typeLine("windows")
emu:advance(1)
assertScreenContains('"console"  50x15 at (1,14)', "the console starts as the bottom half of the screen, above the taskbar (title bar on row 14)")
print("  OK -- only the frame buffer is full-screen; the 50x15 console has no video buffer at all")

print("test 21: console scrollback with PgUp/PgDn and the mouse wheel")
local KEY_PAGEUP, KEY_PAGEDOWN = 0xC9, 0xD1
typeLine('run local t = {} for i = 1, 40 do t[#t + 1] = string.format("L%02d", i) end return table.concat(t, "\\n")')
emu:advance(2)
local function screenHas(text) return renderScreen():gsub("\n", ""):find(text, 1, true) ~= nil end
assert(screenHas("L40") and not screenHas("L01"), "expected only the tail of the 40-line output on screen")
-- The console is a 15-row window again after `comp`, so a page is 14
-- rows; line 1 of 40 sits 41 rows up (under the prompt row), so two
-- pages (offset 28, rows 29-43 in view) bring it into view.
for _ = 1, 2 do
  emu:injectSignal(kernal, "key_down", screenAddr, 0, KEY_PAGEUP, "tester"); emu:step()
end
emu:advance(0.2)
if not (screenHas("L01") and screenHas("[scrolled")) then
  dumpScreenOnFailure("PgUp")
  error("PgUp did not scroll the console back")
end
for _ = 1, 2 do
  emu:injectSignal(kernal, "key_down", screenAddr, 0, KEY_PAGEDOWN, "tester"); emu:step()
end
emu:advance(0.2)
assert(screenHas("L40") and not screenHas("L01") and not screenHas("[scrolled"), "PgDn did not return to the bottom")
emu:injectSignal(kernal, "scroll", screenAddr, 10, 10, 1, "tester"); emu:step()
emu:advance(0.2)
assert(screenHas("[scrolled 3"), "mouse wheel up did not scroll the console")
emu:injectSignal(kernal, "scroll", screenAddr, 10, 10, -1, "tester"); emu:step()
emu:advance(0.2)
assert(not screenHas("[scrolled"), "mouse wheel down did not scroll back")
print("  OK -- PgUp/PgDn and the wheel scroll through earlier output and back")

-- The console's size isn't fixed: `console` resizes it, and output
-- re-wraps to the new width.
typeLine("console 30 8")
emu:advance(0.5)
typeLine('run return string.rep("w", 35)')
emu:advance(2)
if not screenHas(("w"):rep(30)) or screenHas(("w"):rep(31)) then
  dumpScreenOnFailure("console rewrap")
  error("output did not re-wrap to the 30-column console")
end
typeLine("windows")
emu:advance(1)
assertScreenContains('"console"  30x8 at (1,21)', "console resized and docked bottom-left, above the taskbar (title bar on row 21)")
typeLine("console 5 2")
emu:advance(0.5)
assertScreenContains("console size must be between", "too-small size refused")
typeLine("console 50 15")
emu:advance(0.5)
print("  OK -- `console` resizes the console window, output re-wraps, bad sizes are refused")

print("test 22: backspace works across a wrapped input line")
local KEY_BACK_CODE = 0x0E
for _ = 1, 60 do
  emu:injectSignal(kernal, "key_down", screenAddr, string.byte("x"), 0, "tester"); emu:step()
end
for _ = 1, 15 do
  emu:injectSignal(kernal, "key_down", screenAddr, 8, KEY_BACK_CODE, "tester"); emu:step()
end
emu:advance(0.2)
if not screenHas("root@muxos:~> " .. ("x"):rep(45) .. "_") or screenHas(("x"):rep(46)) then
  dumpScreenOnFailure("wrapped backspace")
  error("the wrapped input line did not shrink to 45 characters")
end
emu:injectSignal(kernal, "key_down", screenAddr, 13, 0x1C, "tester"); emu:step()
emu:advance(0.5)
print("  OK -- 60 typed, 15 erased across the wrap, 45 left on screen")

print("test 23: keys typed while a command runs are queued, not run nested")
typeLine('run sleep(2) return "slow" .. 23')
typeLine('run return "queued" .. 23')
emu:advance(5)
do
  local flat = renderScreen():gsub("\n", "")
  local slow, queued = flat:find("slow23", 1, true), flat:find("queued23", 1, true)
  if not slow or not queued or queued < slow then
    dumpScreenOnFailure("input buffering")
    error("the second command did not wait for the first")
  end
end
print("  OK -- the second command ran after the first finished")

print("test 24: only real orphans can be claimed, finished ones with their result")
-- P sleeps 6s with its child A registered under "orph24"; while P is
-- alive, A isn't claimable. After P finishes, A is -- including after
-- A itself has finished.
typeLine('spawn 1 gmuxapi.create_headless_process({code=[[sleep(4) return "A24"]], name="orph24"}) sleep(6)')
emu:advance(1)
typeLine('run return "n24=" .. #gmuxapi.get_orphans("orph24")')
emu:advance(2)
assertScreenContains("n24=0", "a child of a still-running parent is not claimable")
emu:advance(12)
typeLine('run local l = gmuxapi.get_orphans("orph24") return "c24=" .. #l .. "/" .. tostring(l[1] and l[1].status) .. "/" .. tostring(l[1] and l[1].result)')
emu:advance(2)
assertScreenContains("c24=1/done/A24", "the finished orphan is claimable with its status and result")
print("  OK -- unclaimable while its parent ran; claimed afterward with status and result")

print("test 25: finished jobs are kept only up to the history cap, without their source")
for i = 1, 105 do
  typeLine("run return " .. i)
  emu:advance(0.3)
end
typeLine('run local ok, err = gmuxapi.get_process(1) return "r25=" .. tostring(ok) .. "/" .. tostring(err)')
emu:advance(2)
assertScreenContains("r25=nil/no such job", "the oldest job was dropped from history")
typeLine('run local p = gmuxapi.get_processes() local last = p[#p - 1] local full = gmuxapi.get_process(last.id) return "k25=" .. tostring(last.code) .. "/" .. tostring(last.codePreview) .. "/" .. tostring(full.code)')
emu:advance(2)
-- p[#p] is this probe itself; p[#p - 1] is the finished r25 probe above.
assertScreenContains("k25=nil/local ok, err = gmuxapi.get_process(1) r.../nil",
  "summaries carry a 40-char preview, not source, and a finished job's full record has dropped its source")
print("  OK -- oldest finished job dropped; summaries and finished records carry only a preview")

print("test 26: liveness -- a busy node stays up, a dead one is marked down and its job lost")
typeLine("spawn 2 sleep(13) return 26")
emu:advance(1)
local sleeperId = screenAfter("spawn 2 sleep(13)"):match("spawned job %[(%d+)%]")
emu:advance(15)
typeLine('run return "s26=" .. gmuxapi.get_process(' .. sleeperId .. ').status')
emu:advance(2)
assertScreenContains("s26=done", "a node busy sleeping 13s answered probes and was not marked down")
-- Now actually kill a worker and give it a job.
local victim = workers[3]
victim.status = "dead"
typeLine("spawn " .. victim.modemAddr .. " return 1")
emu:advance(1)
local lostId = screenAfter("spawn " .. victim.modemAddr):match("spawned job %[(%d+)%]")
emu:advance(14)
assertScreenContains("stopped responding", "the dead node was marked down")
typeLine('run return "l26=" .. gmuxapi.get_process(' .. lostId .. ').status')
emu:advance(2)
assertScreenContains("l26=lost", "the dead node's job is marked lost")
typeLine('runall return "up" .. 26')
emu:advance(4)
do
  local after, n = screenAfter("runall return"), 0
  for _ in after:gmatch("up26") do n = n + 1 end
  if n ~= 2 then
    dumpScreenOnFailure("runall after node down")
    error("expected runall to reach only the 2 live workers, got " .. n)
  end
end
print("  OK -- a long sleeper stayed up; the dead node was marked down, its job lost, and skipped")

print("test 27: process isolation, pause/resume/kill, and the balancer")
-- (Worker 3 is down after test 26, so 2 live nodes from here.)
typeLine('runall leak27 = "leaked" return "set"')
emu:advance(3)
typeLine('runall return "g27=" .. tostring(leak27)')
emu:advance(3)
do
  local after, n = screenAfter("runall return \"g27="), 0
  for _ in after:gmatch("g27=nil") do n = n + 1 end
  assert(n == 2 and not after:find("g27=leaked", 1, true), "a process's globals leaked into a later process")
end
typeLine('run local ok = pcall(function() string.x27 = 1 end) return "e27=" .. tostring(debug) .. "/" .. tostring(component) .. "/" .. tostring(ok)')
-- (component is now the cluster bus face; test 36 covers it)
emu:advance(2)
assertScreenContains("e27=nil/table: ", "no debug; `component` is the cluster bus, not the raw one")
assertScreenContains("/false", "read-only libraries")
print("  OK -- per-process globals; no debug or raw component; libraries are read-only")

typeLine("spawn 1 for i = 1, 6 do sleep(0.5) end return \"slept27\"")
emu:advance(0.5)
local pid = screenAfter("spawn 1 for i = 1, 6"):match("spawned job %[(%d+)%]")
typeLine("pause " .. pid)
emu:advance(5)
typeLine('run return "p27=" .. tostring(gmuxapi.get_process(' .. pid .. ').status) .. "/" .. tostring(gmuxapi.get_process(' .. pid .. ').paused)')
emu:advance(2)
assertScreenContains("p27=running/true", "the job is held while paused, well past when it would have finished")
typeLine("resume " .. pid)
emu:advance(5)
typeLine('run return "r27=" .. gmuxapi.get_process(' .. pid .. ').status')
emu:advance(2)
assertScreenContains("r27=done", "the job finished after being resumed")
print("  OK -- pause holds a process, resume lets it finish")

typeLine("spawn 1 sleep(30) return 1")
emu:advance(0.5)
local kid = screenAfter("spawn 1 sleep(30)"):match("spawned job %[(%d+)%]")
typeLine("kill " .. kid)
emu:advance(2)
typeLine('run local p = gmuxapi.get_process(' .. kid .. ') return "k27=" .. p.status .. "/" .. p.error')
emu:advance(2)
assertScreenContains("k27=killed/killed by root", "the user can end a process")
print("  OK -- kill ends a process, recorded as killed by user")

typeLine('run local c = gmuxapi.create_headless_process({code = "sleep(30) return 1"}) local ok, err = gmuxapi.kill_process(c.process.id) local ok2, err2 = gmuxapi.kill_process(' .. pid .. ') return "c27=" .. tostring(ok) .. "/" .. tostring(err2)')
emu:advance(3)
assertScreenContains("c27=true/job " .. pid .. " is not a descendant", "a process can end its own child but not an unrelated job")
print("  OK -- a process can control its own descendants only")

typeLine("spawn 1 sleep(6) return 0")
emu:advance(0.5)
local busyAddr = screenAfter("spawn 1 sleep(6)"):match("spawned job %[%d+%] on (modem%-%x+)")
typeLine('run return "b27=" .. gmuxapi.get_process(jobId).node')
emu:advance(2)
local landed = screenAfter('b27="'):match("b27=(modem%-%x+)")
assert(landed and landed ~= busyAddr, "the balancer sent new work to the busy node")
print("  OK -- new work goes to the least-busy node")

print("test 28: keyboard input goes to the focused window's process, which redraws its window")
typeLine('run local r = gmuxapi.create_graphics_process({name = "kbd28", width = 12, height = 1, code = [[' ..
  'local win while not win do for _, w in ipairs(gmuxapi.get_windows()) do if w.ownerJobId == jobId then win = w.id end end if not win then sleep(0.2) end end ' ..
  'local s = "" while true do local e = gmuxapi.pull_event(20) if not e then break end ' ..
  'if e[1] == "key_down" then if e[3] == 28 then break end s = s .. utf8.char(e[2]) ' ..
  'gmuxapi.draw_window(win, {code = "gpu.set(1, 1, args.t)", args = {t = s}}) end end return s]]}) return "w28=" .. r.process.id')
emu:advance(2)
local kbdId = screenAfter("w28="):match("w28=(%d+)")
assert(kbdId, "graphics process id not shown")
typeLine("hi28")
emu:advance(2)
do
  -- Row 1 is its title bar (gmux decorations: Enter ended the process,
  -- so it's marked ended, and the title is cut short of the buttons),
  -- row 2 its body.
  local titleRow, bodyRow = renderScreen():match("^([^\n]*)\n([^\n]*)")
  if titleRow:sub(1, #"\u{23F9} - kb") ~= "\u{23F9} - kb" or not titleRow:find("\u{2716}", 1, true) or bodyRow:sub(1, 4) ~= "hi28" or screenHas("root@muxos:~> hi28") then
    dumpScreenOnFailure("keyboard delivery")
    error("typed keys didn't reach the focused process and its window")
  end
end
typeLine('run return "R28=" .. tostring(gmuxapi.get_process(' .. kbdId .. ').result)')
emu:advance(2)
assertScreenContains("R28=hi28", "the process received the keys and returned them")
print("  OK -- keys went to the focused window's process (not the console), which redrew its window")

typeLine([[run local ok, err = gmuxapi.draw_window(1, {code = "gpu.set(1,1,'x')"}) return "d28=" .. tostring(err)]])
emu:advance(2)
assertScreenContains("d28=window 1 belongs to another process", "a process can't draw into a window it doesn't own")
print("  OK -- drawing into another process's window is refused")

print("test 29: the program launcher -- .mxe headers and libraries, legacy .lua programs, foreground/background")
typeLine("hello world")
emu:advance(3)
assertScreenContains("hello mxe v=true g=true n=false a=world", ".mxe got its header response, its library, and its args")
typeLine("old")
emu:advance(3)
assertScreenContains("old-runs v=false want=9.9 have=0.1.2", "a version mismatch is reported but the program still runs")
print("  OK -- .mxe launched by name: version response, granted/missing libraries, require, args")

typeLine("ask")
emu:advance(2)
assertScreenContains("/bin/ask.lua started on", "a legacy program has its own window, so the console doesn't wait")
assert(cellText(1, 1, 7) == "ask.lua" and cellText(1, 2, 7) == "name? _", "its prompt is in its own window, got " .. cellText(1, 2, 7))
typeLine("bob")
emu:advance(3)
assert(cellText(1, 2, 9) == "name? bob", "typed input was echoed in its window")
assert(cellText(1, 3, 35) == "hi bob gmuxapi=nil os.time=function",
  "it read the input, and sees the OpenOS environment, not gmuxapi; got " .. cellText(1, 3, 35))
closeWindowAt(1, 50)
print("  OK -- a legacy .lua program writes and reads in its own window (its terminal), like gmux")

typeLine("hello bg &")
emu:advance(3)
assertScreenContains("/bin/hello.mxe started on", "a trailing & runs it in the background")
assertScreenContains("a=bg", "the background program's output still reaches the console")
typeLine('run local h = gmuxapi.launch("hello", {"kid"}) sleep(1) return "L29=" .. tostring(gmuxapi.get_process(h.id).parent == jobId)')
emu:advance(4)
assertScreenContains("a=kid", "a program launched by a process ran")
assertScreenContains("L29=true", "the launching process is its parent")
typeLine("nosuchprogram")
emu:advance(1)
assertScreenContains("command not found", "an unknown name is still an unknown command")
print("  OK -- background launch, gmuxapi.launch (as parent), unknown names")

print("test 30: the hardware verification suite passes inside the emulated sandbox")
-- test/hardware/verify.lua is what you run on real hardware; it runs
-- here through the same machine.lua sandbox, booted by its own loader.
do
  local hw = Emulator.new()
  hw.timeout = 1
  local node = hw:newNode("hw")
  hw:addEeprom(node, readFile(REPO_ROOT .. "/test/hardware/bios.lua"))
  hw:addFilesystem(node, {["/verify.lua"] = readFile(REPO_ROOT .. "/test/hardware/verify.lua")})
  local _, _, bufs = hw:addGpuScreen(node, 100, 30)
  hw:boot(node)
  hw:advance(30)
  local rows = {}
  for y = 1, bufs[0].h do
    local row, chars = bufs[0].cells[y] or {}, {}
    for x = 1, bufs[0].w do chars[x] = (row[x] and row[x].char) or " " end
    rows[#rows + 1] = table.concat(chars)
  end
  local screen = table.concat(rows, "\n")
  if not screen:find("checks, 0 failed", 1, true) then
    io.stderr:write(screen .. "\n")
    error("the hardware verification suite failed in the emulated sandbox")
  end
end
print("  OK -- every check in test/hardware/verify.lua passes")

print("test 31: .mxe migration through the mux library, and draining a node")
typeLine("counter 20 &")
emu:advance(1)
local cid = screenAfter("counter 20 &"):match("%[(%d+)%] /bin/counter.mxe started on")
assert(cid, "counter didn't start")
emu:advance(1)
typeLine("migrate " .. cid)
emu:advance(1)
assertScreenContains("job [" .. cid .. "] migrated from", "the kernal moved the process")
emu:advance(8)
assertScreenContains("counter done n=20 starts=2", "it finished on the new node, continuing from its saved state")
print("  OK -- a migratable .mxe moved mid-run and carried on from its saved state")

typeLine("spawn 1 sleep(5) return 1")
emu:advance(0.5)
local plain = screenAfter("spawn 1 sleep(5)"):match("spawned job %[(%d+)%]")
typeLine("migrate " .. plain)
emu:advance(1)
assertScreenContains("isn't migratable", "a process that never opted in isn't moved")
print("  OK -- a process that never opted in is refused")

emu:advance(5)
typeLine("counter 40 &")
emu:advance(1)
local did, dnode = screenAfter("counter 40 &"):match("%[(%d+)%] /bin/counter.mxe started on (modem%-%x+)")
assert(did, "second counter didn't start")
emu:advance(1)
typeLine("drain " .. dnode)
emu:advance(2)
assertScreenContains("draining " .. dnode .. ": moving 1 migratable job(s)", "drain moved the migratable process")
assertScreenContains("job [" .. did .. "] migrated from " .. dnode, "it actually moved")
-- Only one other node is up at this point (an earlier test took one
-- down) and it's busy with the moved counter, so spawn rather than
-- `run`: the job queues there instead of the REPL blocking on it.
typeLine("spawn 1 return 1")
emu:advance(0.5)
local landed31 = screenAfter("spawn 1 return 1"):match("spawned job %[%d+%] on (modem%-%x+)")
assert(landed31 and landed31 ~= dnode, "new work went to the draining node")
typeLine("undrain " .. dnode)
emu:advance(12)
assertScreenContains("counter done n=40 starts=2", "the drained process finished elsewhere")
print("  OK -- drain moved the migratable process off and kept new work away")

print("test 32: gmux window decorations -- touch, move, minimize, maximize, resize, close")
typeLine('run local r = gmuxapi.create_graphics_process({name = "deco32", x = 20, y = 3, width = 14, height = 3, resizable = true, code = [[' ..
  'local win while not win do for _, w in ipairs(gmuxapi.get_windows()) do if w.ownerJobId == jobId then win = w.id end end if not win then sleep(0.2) end end ' ..
  'while true do local e = gmuxapi.pull_event(60) if not e then break end local t ' ..
  'if e[1] == "touch" then t = "T" .. e[2] .. "," .. e[3] elseif e[1] == "window_resized" then t = "R" .. e[3] .. "x" .. e[4] end ' ..
  'if t then gmuxapi.draw_window(win, {code = "gpu.set(1, 1, args.t)", args = {t = t}}) end end]]}) return "w32=" .. r.process.id')
emu:advance(2)
local decoId = screenAfter("w32="):match("w32=(%d+)")
assert(decoId, "graphics process didn't start")
assert(cellText(20, 3, 6) == "deco32" and cellText(32, 3, 1) == "\u{2716}", "title bar with the close button at w-1")

touch("touch", 22, 5)
emu:advance(1)
assert(cellText(20, 4, 4) == "T3,2", "a body touch reaches the process in the body's own coordinates, got " .. cellText(20, 4, 4))
print("  OK -- title bar drawn; a body touch reaches the owner in window coordinates")

touch("touch", 25, 3)
touch("drag", 35, 6)
touch("drop", 35, 6)
assert(cellText(30, 6, 6) == "deco32" and cellText(30, 7, 4) == "T3,2", "dragging the title bar moved the window")
assert(cellText(20, 4, 4) ~= "T3,2", "what was behind the old position shows again")
print("  OK -- dragging the title bar moves the window")

touch("touch", 38, 6)
assert(cellText(30, 6, 6) ~= "deco32" and cellText(30, 7, 4) ~= "T3,2", "minimize hides the whole window")
-- This 50-column screen has more windows than taskbar room: titles
-- shrink, and the "+N" button lists every window.
local bar = cellText(1, 30, 50)
local moreX = bar:find(" +", 1, true)
assert(moreX and bar:find("con ", 1, true), "shrunken buttons and a +N button: " .. bar)
touch("touch", moreX + 1, 30)
local menuY
for y = 1, 29 do if cellText(1, y, 50):find("deco32 (minimized)", 1, true) then menuY = y end end
assert(menuY, "the window menu lists it as minimized:\n" .. renderScreen())
touch("touch", cellText(1, menuY, 50):find("deco32", 1, true), menuY)
assert(cellText(30, 6, 6) == "deco32" and cellText(30, 7, 4) == "T3,2", "the menu brings it back:\n" .. renderScreen())
print("  OK -- minimize hides the window to the taskbar; its menu entry restores it")

touch("touch", 40, 6)
emu:advance(1)
assert(cellText(1, 1, 6) == "deco32" and cellText(1, 2, 6) == "R50x29", "maximize fills the screen and tells the owner, got " .. cellText(1, 2, 6))
touch("touch", 47, 1)
emu:advance(1)
assert(cellText(30, 6, 6) == "deco32" and cellText(30, 7, 5) == "R14x3", "maximize again restores the old geometry, got " .. cellText(30, 7, 5))
print("  OK -- maximize fills the screen and restores, the owner is told each time")

touch("touch", 43, 9)
touch("drag", 47, 10)
touch("drop", 47, 10)
emu:advance(1)
assert(cellText(30, 7, 5) == "R18x4" and cellText(46, 6, 1) == "\u{2716}", "dragging the corner resizes, got " .. cellText(30, 7, 5))
print("  OK -- dragging the bottom-right corner resizes the window")

touch("touch", 46, 6)
emu:advance(1)
assert(cellText(30, 6, 6) ~= "deco32", "close removes the window")
touch("touch", 5, 25) -- the console: keys go back to the REPL
typeLine('run return "s32=" .. gmuxapi.get_process(' .. decoId .. ').status')
emu:advance(2)
assertScreenContains("s32=killed", "closing the window killed its process, as in gmux")
print("  OK -- close removes the window and kills its process; touching the console refocuses it")

print("test 33: legacy require -- vendored OpenOS libraries, lazy halves, dynamic names, faces")
typeLine("libs")
emu:advance(3)
assert(cellText(1, 1, 8) == "libs.lua", "its output is in its own window")
assertScreenContains('libs t=1x pad=ab  | top=1 red=14 f1=59 extra=ok gpu=true avail=true same=true',
  "shipped, lazily loaded, and fetched-on-demand modules all work; component has the virtual gpu")
typeLine("q")
emu:advance(2)

assertScreenContains("got key_down q held=true", "event.pull filters by name; keyboard tracks held keys")
assertScreenContains("missing=false nf", "a module that doesn't exist fails like OpenOS's require")
closeWindowAt(1, 50)
print("  OK -- OpenOS libraries load through require, package.delay, and GETMODULE")

print("test 34: legacy graphics -- a gmux-style virtual gpu drawn into the program's own window")
typeLine("paint")
emu:advance(2)
assert(cellText(2, 2, 14) == "d=50x25 s=true", "a legacy program gets a virtual gpu and screen, sized to fit, got " .. cellText(2, 2, 14))
assert(cellText(1, 1, 8) == "paint.lu", "its window was created on the first draw, titled after it, got " .. cellText(1, 1, 8))
assert(cellText(2, 3, 10) == "legacy gfx" and cellText(2, 4, 10) == "legacy gfx", "set and copy reached the window")
assert(cellText(2, 5, 5) == "BUF!!", "bitblt from a virtual buffer reached the window")
assert(cellText(1, 1, 20):find("\u{2BC5}", 1, true), "its window is resizable (maximize button shown)")
print("  OK -- set/fill/copy/buffers/bitblt draw into a window sized by setResolution")
emu:injectSignal(kernal, "touch", screenAddr, 5, 3, 0, "tester")
emu:advance(1)
assert(cellText(2, 2, 14) == "touch 5,2 true", "touch arrives in OpenOS's shape, window coordinates, got " .. cellText(2, 2, 14))
emu:injectSignal(kernal, "touch", screenAddr, 17, 1, 0, "tester")
emu:advance(1)
assert(cellText(2, 2, 20) == "size 50x29 res=50x29", "maximizing is a resolution change for the program, got " .. cellText(2, 2, 20))
print("  OK -- touch and window resizes reach it as OpenOS signals (screen_resized), as in gmux")
emu:advance(2)
closeWindowAt(1, 50)

print("test 35: legacy filesystem -- the kernal's disk, like the OS filesystem for a gmux app")
typeLine("files")
emu:advance(4)
assertScreenContains("fs line one|line twoN|5001|notes.txt,sub/|3|5019|false|true|true",
  "io.open/read/write, filesystem.list/copy/size/exists/isDirectory/makeDirectory, PWD, io.lines, dofile")
assertScreenContains("/bin/files.lua:13: boom", "an error is written into the program's own window")
assert(cellText(1, 1, 1) == "\u{274C}", "and its title is marked as failed")
closeWindowAt(1, 50)
print("  OK -- files on the kernal's disk; a legacy error shows in its window")

print("test 36: the cluster component bus -- every node's components, from any process")
local w1, w2 = workerModems[1], workerModems[2]
typeLine("bus")
emu:advance(1)
assertScreenContains(string.format("%-14s %s  on kernal", "internet", internetAddr), "the kernal's internet card is on the bus")
assertScreenContains(string.format("%-14s %s  on %s", "redstone", redstoneAddr, w1), "worker 1's redstone card is on the bus")
do
  local after = screenAfter("root@muxos:~> bus")
  assert(not after:find("gpu ", 1, true) and not after:find("modem ", 1, true) and not after:find("eeprom ", 1, true),
    "the display, network cards and firmware stay off the bus")
end
print("  OK -- the kernal keeps a registry of every node's components")

typeLine("spawn " .. w2 .. " print('rs2=' .. component.redstone.getInput(2) .. '/' .. tostring(component.isAvailable('gpu')) .. '/' .. tostring(component.redstone.setOutput(3, 9)))")
emu:advance(2)
assertScreenContains("rs2=20/false/0", "worker 2 calls worker 1's redstone card through the kernal")
typeLine("spawn " .. w1 .. " print('rs1=' .. component.redstone.getOutput(3) .. '/' .. component.type('" .. redstoneAddr .. "'))")
emu:advance(2)
assertScreenContains("rs1=9/redstone", "on worker 1 the same card is called directly, and sees worker 2's write")
print("  OK -- a component on another worker is relayed; one on the caller's own node is called directly")

typeLine("spawn " .. w2 .. " local h = component.internet.request('http://x') h.finishConnect() local b = '' for i = 1, 5 do local d = h.read() if not d then break end b = b .. d end h.close() print('net=' .. b .. '/' .. tostring(select(2, pcall(h.read))))")
emu:advance(3)
assertScreenContains("net=hello bus/that value is gone", "a request handle stays on the kernal and is used through VALUECALL; closing frees it")
print("  OK -- values a call returns (an internet request handle) are used remotely, and freed on close")

typeLine("fetch")
emu:advance(4)
assertScreenContains("fetched hello bus via " .. internetAddr:sub(1, 8), "OpenOS's internet library works over the bus")
closeWindowAt(1, 50)
print("  OK -- a legacy program uses OpenOS's internet library with the kernal's internet card")

print("test 37: the .mxe spec -- fs, readLine, parseArgs, versions, library search, http, header fields")
typeLine("spec pos -vx --name=bob")
emu:advance(4)
assertScreenContains("spec pos|truetrue|bob|base+top|3|a.txt,c.txt|false|page200|truespec2.0|truefalse",
  "fs, parseArgs, /usr/lib/mxe and library dependencies, http.get, compatible, name/version, requires")
assertScreenContains("who? _", "readLine shows its prompt in the foreground")
typeLine("ann")
emu:advance(2)
assertScreenContains("who? ann", "what's typed is echoed")
assertScreenContains("hello ann", "readLine returns the line")
assert(kernalFiles["/home/spec/c.txt"] == "one\ntwo\nthree\n", "fs.write/open(a)/copy/rename reached the kernal's disk")
typeLine('run return "bg37=" .. tostring(select(2, readLine()))')
emu:advance(2)
assertScreenContains("bg37=not in the foreground at the console", "readLine outside the console's foreground fails")
typeLine('run for _, p in pairs(gmuxapi.get_processes()) do if p.programName == "spec" then return "v37=" .. p.programName .. "@" .. p.programVersion end end return "v37=none"')
emu:advance(2)
assertScreenContains("v37=spec@2.0", "the header's name and version show in process listings")
print("  OK -- every section-7 API works as docs/MXE.md specifies")

print("test 38: opm, ported to .mxe -- list, pull, run, update, bundle, offline install")
local base = "--base=" .. GITEA
typeLine("opm " .. base .. " list")
emu:advance(3)
assertScreenContains("demo               a demo program", "opm lists the catalog")
typeLine("opm " .. base .. " pull demo")
emu:advance(4)
assertScreenContains("demo/demo.lua -> /usr/bin/demo.lua  ", "files go under /usr")
assertScreenContains("version 1.2", "versions are reported")
assertScreenContains("done", "the pull finished")
assert(kernalFiles["/usr/bin/demo.lua"] and kernalFiles["/usr/lib/demolib.lua"] and kernalFiles["/usr/lib/extra.lua"],
  "the package and its dependency were installed")
assert(kernalFiles["/etc/opm.installed"]:find('["demo"]="/usr"', 1, true), "the install is recorded")
typeLine("demo")
emu:advance(3)
assertScreenContains("demo says hi dep", "the installed OpenOS package runs, finding its libraries under /usr/lib")
closeWindowAt(1, 50)
typeLine("opm " .. base .. " update demo")
emu:advance(4)
assertScreenContains("updating demo -> /usr", "update re-pulls at the recorded target")
typeLine("opm " .. base .. " bundle demo /home/b")
emu:advance(4)
assertScreenContains("bundle ready", "bundle wrote the package for offline use")
assert(kernalFiles["/home/b/files/programs.cfg"] and kernalFiles["/home/b/files/demo/demo.lua"], "bundle contents")
typeLine("opm --from=/home/b pull demo /home/x")
emu:advance(4)
assert(kernalFiles["/home/x/bin/demo.lua"] == webFiles[GITEA .. "demo/demo.lua"], "an offline install from the bundle")
typeLine("opm " .. base .. " update")
emu:advance(3)
assertScreenContains("no opm-mxe package", "self-update needs the opm-mxe package in the catalog")
print("  OK -- opm installs, updates and bundles packages on muxos")

print("test 39: a worker runs its processes side by side")
for i = 1, 3 do
  typeLine("spawn " .. workerModems[1] .. " sleep(2) print('mt39-" .. i .. "') return " .. i)
end
emu:advance(3)
for i = 1, 3 do
  assertScreenContains("mt39-" .. i, "three 2s sleepers on one node all finish within 3s (they'd take 6s queued)")
end
print("  OK -- processes on one node wait concurrently instead of queueing")

print("test 40: the desktop -- gmux's background and app icons; touching one starts it")
do
  -- A fresh cluster, so no earlier test's windows cover the icons.
  local demu = Emulator.new()
  local k = demu:newNode("kernal")
  demu:addModem(k)
  local _, dscreen, dbufs = demu:addGpuScreen(k, 80, 25)
  local files = {}
  for name, data in pairs(kernalFiles) do files[name] = data end
  files["/usr/bin/greeter.lua"] = 'print("hello from the desktop") io.read()'
  demu:addEeprom(k, readFile(REPO_ROOT .. "/kernal/bios.lua"), demu:addFilesystem(k, files))
  local w = demu:newNode("worker")
  demu:addModem(w)
  demu:addEeprom(w, readFile(REPO_ROOT .. "/node/bios.lua"))
  demu:boot(k)
  demu:boot(w)
  demu:advance(4)
  local function cells(x, y, n)
    local row, out = dbufs[0].cells[y] or {}, {}
    for i = 0, n - 1 do out[#out + 1] = (row[x + i] and row[x + i].char) or " " end
    return table.concat(out)
  end
  local function text()
    local rows = {}
    for y = 1, dbufs[0].h do rows[y] = cells(1, y, dbufs[0].w) end
    return table.concat(rows, "\n")
  end
  local function dtouch(x, y)
    demu:injectSignal(k, "touch", dscreen, x, y, 0, "tester")
    demu:advance(1)
  end
  -- The icon whose name row reads `name`: returns its art's middle cell.
  local function iconOf(name)
    for y = 6, dbufs[0].h do
      for x = 2, dbufs[0].w - 8, 10 do
        if cells(x, y - 4, 9) == "/-------\\" and cells(x, y, 9):match("^%s*(.-)%s*$") == name then return x + 4, y - 2 end
      end
    end
  end
  assert(iconOf("console"), "the console is a desktop icon:\n" .. text())
  -- The console is a window with a title bar: minimize it, then the
  -- icons it covered show.
  dtouch(80 - 5, 12)
  local hx, hy = iconOf("greeter")
  assert(iconOf("opm") and hx, "/bin's opm and /usr/bin's greeter are icons once the console is out of the way:\n" .. text())
  dtouch(hx, hy)
  for _ = 1, 20 do
    if text():find("hello from the desktop", 1, true) then break end
    demu:advance(0.5)
  end
  assert(text():find("hello from the desktop", 1, true), "touching its icon started it in its own window:\n" .. text())
  dtouch(80 - 1, 1) -- close the program's window
  local cx, cy = iconOf("console")
  dtouch(cx, cy)
  assert(text():find("root@muxos:~> _", 1, true), "the console icon brings the console back:\n" .. text())
  -- Its close button minimizes it rather than losing it.
  dtouch(80 - 1, 12)
  assert(not text():find("root@muxos:~> _", 1, true) and text():find("console", 1, true), "closing the console minimizes it:\n" .. text())
end
print("  OK -- icons for the console and every program; touching one starts it; the console minimizes")

print("test 41: the POSIX-style shell -- utilities, pipes, redirection, variables, globs, /mnt")
do
  -- A floppy, as the installer's would be: under /mnt by its address.
  local floppyFiles = {["/readme.txt"] = "alpha\nbeta\ngamma\n"}
  emu:addFilesystem(kernal, floppyFiles, "flop", 512 * 1024)
  local function sh(line)
    typeLine(line)
    emu:advance(0.5)
  end
  local function file(path) return kernalFiles[path] end
  sh("cd /home && mkdir -p t41/sub && cd t41")
  sh("pwd > where.txt")
  assert(file("/home/t41/where.txt") == "/home/t41\n", "cd, mkdir -p, && and pwd: " .. tostring(file("/home/t41/where.txt")))
  assertScreenContains("root@muxos:/home/t41> ", "the prompt shows the working directory")
  sh("echo one > a.txt; echo two >> a.txt; echo 'three  spaced' >> a.txt")
  assert(file("/home/t41/a.txt") == "one\ntwo\nthree  spaced\n", "> and >> and quoting: " .. tostring(file("/home/t41/a.txt")))
  sh("cat a.txt | grep t | sort -r | tee sorted.txt | wc -l > count.txt")
  assert(file("/home/t41/sorted.txt") == "two\nthree  spaced\n" and file("/home/t41/count.txt") == "2\n",
    "a pipeline through grep, sort, tee and wc")
  sh('X=world; export GREETING="hello $X"; echo "$GREETING" ${X} \\$X > v.txt')
  assert(file("/home/t41/v.txt") == "hello world world $X\n", "variables, export, escapes: " .. tostring(file("/home/t41/v.txt")))
  sh("false || echo recovered > or.txt; true && echo ran >> or.txt; false && echo never >> or.txt")
  assert(file("/home/t41/or.txt") == "recovered\nran\n", "&& and ||: " .. tostring(file("/home/t41/or.txt")))
  sh("grep nothing a.txt; echo $? > status.txt; nosuchcommand 2>/dev/null; echo $? >> status.txt")
  assert(file("/home/t41/status.txt") == "1\n127\n", "$? after grep with no match, and command not found: " .. tostring(file("/home/t41/status.txt")))
  sh("cp /mnt/flo/readme.txt . && head -n 2 readme.txt > h.txt && tail -n 1 readme.txt > t.txt")
  assert(file("/home/t41/h.txt") == "alpha\nbeta\n" and file("/home/t41/t.txt") == "gamma\n", "the floppy under /mnt, head and tail")
  sh("echo copied > /mnt/flo/out.txt")
  assert(floppyFiles["/out.txt"] == "copied\n", "writing to the floppy")
  sh("echo a b c | tr a-c x-z | cut -d ' ' -f 2,3 > tr.txt; seq 3 | sort -rn | uniq > seq.txt")
  assert(file("/home/t41/tr.txt") == "y z\n" and file("/home/t41/seq.txt") == "3\n2\n1\n", "tr, cut, seq, sort -n, uniq")
  sh("cp -r sub copy && mv a.txt sub/ && rm -r copy && touch sub/b.txt")
  assert(file("/home/t41/sub/a.txt") and not file("/home/t41/a.txt") and file("/home/t41/sub/b.txt") == "", "cp -r, mv into a directory, rm -r, touch")
  sh("echo *.txt > glob.txt")
  assert(file("/home/t41/glob.txt") == "count.txt h.txt or.txt readme.txt seq.txt sorted.txt status.txt t.txt tr.txt v.txt where.txt\n",
    "globbing: " .. tostring(file("/home/t41/glob.txt")))
  sh('[ -d sub ] && test -f sub/a.txt && [ "$X" = world ] && echo yes > test.txt')
  assert(file("/home/t41/test.txt") == "yes\n", "test and [")
  sh("which ls cat > which.txt; type opm >> which.txt")
  assert(file("/home/t41/which.txt") == "ls: built in\ncat: built in\nopm is /bin/opm.mxe\n", "which and type: " .. tostring(file("/home/t41/which.txt")))
  sh("clear")
  sh("ls /mnt/flo")
  assertScreenContains("out.txt     readme.txt", "ls in aligned columns")
  sh("nodes; echo after-nodes")
  assertScreenContains("after-nodes", "a muxos command inside a shell line")
  sh("cd /home && rm -r t41 && cd ~")
  assert(not file("/home/t41/where.txt"), "rm -r cleaned up")
end
print("  OK -- the core utilities, pipes, redirection, variables, globs, &&/||, /mnt, and muxos commands mixed in")

print("test 42: threads in an .mxe -- concurrent, joinable, killable; errors reported")
kernalFiles["/bin/threads.mxe"] = [==[--[[mxe
libraries = {"thread"}
]]
local thread = require("thread")
local t0 = computer.uptime()
local a = thread.create(function(x) sleep(1) return x * 2 end, 21)
local b = thread.create(function() sleep(1) return "b" end)
local okA, ra = a:join()
local okB, rb = b:join()
print(string.format("T42 a=%s %s b=%s %s took=%.1f", tostring(okA), tostring(ra), tostring(okB), tostring(rb),
  computer.uptime() - t0))
local slow = thread.create(function() sleep(30) end)
print("T42 timeout=" .. tostring(select(2, slow:join(0.5))) .. " status=" .. slow:status())
slow:kill()
slow:join(2)
print("T42 killed=" .. slow:status())
thread.create(function() error("boom") end)
sleep(0.5)
return "threads done"
]==]
typeLine("threads")
emu:advance(5)
assertScreenContains("T42 a=true 42 b=true b took=1.", "two threads sleeping 1s each finish together, joined with their results")
assertScreenContains("T42 timeout=timeout status=running", "join with a timeout")
assertScreenContains("T42 killed=dead", "kill ends a thread")
assertScreenContains("thread error: ", "an unjoined thread's error reaches the console")
assertScreenContains("boom", "...with its message")
print("  OK -- threads run concurrently, join/kill/timeout work, errors are reported")

-- A fresh cluster: a kernal (with the given extra files on its disk) and
-- `workers` workers, booted; returns helpers to drive and read it.
local function newCluster(width, height, extra, workers)
  local c = {emu = Emulator.new()}
  c.kernal = c.emu:newNode("kernal")
  c.emu:addModem(c.kernal)
  local _, scr, bufs = c.emu:addGpuScreen(c.kernal, width, height)
  c.files = {}
  for name, data in pairs(kernalFiles) do c.files[name] = data end
  for name, data in pairs(extra or {}) do c.files[name] = data end
  c.emu:addEeprom(c.kernal, readFile(REPO_ROOT .. "/kernal/bios.lua"), c.emu:addFilesystem(c.kernal, c.files))
  local ws = {}
  for i = 1, workers or 1 do
    ws[i] = c.emu:newNode("worker")
    c.emu:addModem(ws[i])
    c.emu:addEeprom(ws[i], readFile(REPO_ROOT .. "/node/bios.lua"))
  end
  c.emu:boot(c.kernal)
  for _, w in ipairs(ws) do c.emu:boot(w) end
  c.emu:advance(4)
  function c.cell(x, y) return (bufs[0].cells[y] or {})[x] end
  function c.cells(x, y, n)
    local out = {}
    for i = 0, n - 1 do local cell = c.cell(x + i, y) out[#out + 1] = cell and cell.char or " " end
    return table.concat(out)
  end
  function c.text()
    local rows = {}
    for y = 1, height do rows[y] = c.cells(1, y, width) end
    return table.concat(rows, "\n")
  end
  function c.touch(x, y)
    c.emu:injectSignal(c.kernal, "touch", scr, x, y, 0, "tester")
    c.emu:advance(1)
  end
  function c.key(char, code)
    c.emu:injectSignal(c.kernal, "key_down", scr, char, code or 0, "tester")
    c.emu:step()
  end
  function c.typeLine(line)
    for i = 1, #line do c.key(line:byte(i)) end
    c.key(13, 0x1C)
    c.emu:advance(0.5)
  end
  -- Where a string starts on screen (first match), or nil.
  function c.find(str)
    for y = 1, height do
      local x = c.cells(1, y, width):find(str, 1, true)
      if x then return utf8.len(c.cells(1, y, width):sub(1, x - 1)) + 1, y end
    end
  end
  return c
end

print("test 43: custom desktop icons, the taskbar, and the start menu")
do
  local c = newCluster(80, 25, {
    ["/usr/bin/fancy.mxe"] = '--[[mxe\nicon = {" .---. ", "( o.o )", " > ^ < ", ""}\nicon_color = 0xFFFF44\n]]\nreturn 1',
    ["/usr/bin/sidecar.lua"] = 'print("sidecar")',
    ["/usr/bin/sidecar.icon"] = "#44FF44\n[=====]\n[ sc  ]\n[=====]\n",
  }, 1)
  -- The taskbar: the bottom row, a start button, the console's button.
  local bar = c.cells(1, 25, 80)
  assert(bar:find("muxos", 1, true) and bar:find("console", 1, true), "the taskbar:\n" .. bar)
  local bx = bar:find(" console ", 1, true)
  -- Minimize the console from its taskbar button (it's focused and on
  -- top), uncovering the icons; then bring it back the same way.
  c.touch(bx + 2, 25)
  assert(not c.text():find("root@muxos:~> _", 1, true), "the console's button minimized it:\n" .. c.text())
  local fx, fy = c.find("( o.o )")
  assert(fx, "an .mxe header's icon is drawn:\n" .. c.text())
  assert(c.cell(fx, fy).fg == 0xFFFF44, "...in its icon_color")
  local sx, sy = c.find("[ sc  ]")
  assert(sx and c.cell(sx, sy).fg == 0x44FF44, "a .icon file's art and color:\n" .. c.text())
  local dx, dy = c.find("/-------\\")
  assert(dx and c.cell(dx, dy).fg == 0xFF8844, "programs without one get gmux's icon, in gmux's colors")
  c.touch(bx + 2, 25)
  assert(c.text():find("root@muxos:~> _", 1, true), "...and the button restored it:\n" .. c.text())
  -- The start menu lists the apps; touching one starts it.
  c.touch(3, 25)
  local mx, my = c.find("sidecar")
  assert(mx and my > 15, "the start menu lists the apps:\n" .. c.text())
  c.touch(mx, my)
  for _ = 1, 10 do
    if c.text():find("sidecar.lua", 1, true) then break end
    c.emu:advance(0.5)
  end
  assert(c.text():find("sidecar.lua", 1, true), "an app started from the start menu, with a taskbar button:\n" .. c.text())
  assert(c.cells(1, 25, 80):find("sidecar.lua", 1, true), "its window has a taskbar button")
end
print("  OK -- custom icons from .mxe headers and .icon files, taskbar buttons, start menu")

print("test 44: the demo -- threads, child processes on the workers, color and braille windows")
do
  local c = newCluster(100, 32, {["/bin/demo.mxe"] = readFile(REPO_ROOT .. "/apps/demo.mxe")}, 3)
  c.typeLine("demo")
  for _ = 1, 30 do
    if c.text():find("cycling colors", 1, true) then break end
    c.emu:advance(0.5)
  end
  local text = c.text()
  assert(text:find("image computed by 4 child processes on", 1, true), "the strips were computed by child processes:\n" .. text)
  assert(text:find("cycling colors", 1, true), "the status thread reports the image thread's phase:\n" .. text)
  -- The half-block window: many colors, half-block characters.
  local colors, halves = {}, 0
  for y = 3, 14 do
    for x = 2, 49 do
      local cell = c.cell(x, y)
      if cell then
        colors[(cell.fg or 0) .. "/" .. (cell.bg or 0)] = true
        if cell.char == "\u{2580}" or cell.char == "\u{2584}" then halves = halves + 1 end
      end
    end
  end
  local n = 0
  for _ in pairs(colors) do n = n + 1 end
  assert(n > 20 and halves > 50, "the color window shows a half-block image (" .. n .. " colors, " .. halves .. " half blocks)")
  local braille = 0
  for y = 3, 8 do
    for x = 52, 72 do
      local cell = c.cell(x, y)
      local code = cell and utf8.codepoint(cell.char)
      if code and code > 0x2800 and code <= 0x28FF then braille = braille + 1 end
    end
  end
  assert(braille > 20, "the braille window shows graphics (" .. braille .. " braille cells)")
  -- q in a demo window ends it, its threads joined.
  local tx, ty = c.find("demo: threads")
  c.touch(tx + 3, ty + 2)
  c.key(string.byte("q"), 0x10)
  for _ = 1, 20 do
    if c.text():find("demo: done", 1, true) then break end
    c.emu:advance(0.5)
  end
  assert(c.text():find("demo: done", 1, true), "q ended the demo:\n" .. c.text())
end
print("  OK -- four threads, strips on the workers, a half-block image and braille graphics, q to quit")

print("test 45: networking -- a raw modem API for .mxe programs and a modem for legacy ones")
do
  -- An ordinary OpenComputers machine elsewhere on the network: it
  -- answers anything on ports 123 and 124 with "pong:<what it got>".
  local outside = emu:newNode("outside")
  local outsideModem = emu:addModem(outside)
  emu:addEeprom(outside, [==[
local m = component.list("modem")()
component.invoke(m, "open", 123)
component.invoke(m, "open", 124)
while true do
  local name, _, from, port, _, a, b = computer.pullSignal()
  if name == "modem_message" then component.invoke(m, "send", from, port, "pong:" .. tostring(a), b) end
end
]==])
  emu:boot(outside)
  kernalFiles["/bin/net45.mxe"] = [==[--[[mxe
libraries = {"modem"}
]]
local modem = require("modem")
print("NET45 open=" .. tostring(modem.open(123)))
print("NET45 reserved=" .. tostring(pcall(modem.open, 4477)))
modem.broadcast(123, "hello", 7)
local e = gmuxapi.pull_event(3)
print("NET45 got " .. tostring(e and e[1]) .. " " .. tostring(e and e[6]) .. " " .. tostring(e and e[7]))
print("NET45 me=" .. tostring(modem.address))
modem.send(e[3], 123, "direct", 8)
e = gmuxapi.pull_event(3)
print("NET45 direct " .. tostring(e and e[6]) .. " " .. tostring(e and e[7]))
]==]
  kernalFiles["/usr/bin/net45legacy.lua"] = [==[
local component = require("component")
local event = require("event")
local m = component.modem
m.open(124)
m.broadcast(124, "legacy", 9)
local _, _, from, port, _, a, b = event.pull(3, "modem_message")
print("LNET45 " .. tostring(port) .. " " .. tostring(a) .. " " .. tostring(b) .. " " .. tostring(m.address == component.modem.address))
]==]
  typeLine("net45")
  emu:advance(4)
  assertScreenContains("NET45 open=true", "an .mxe opens a port")
  assertScreenContains("NET45 reserved=false", "the cluster's own port is refused")
  assertScreenContains("NET45 got modem_message pong:hello 7", "a broadcast's answer arrives as an event")
  assertScreenContains("NET45 me=" .. kernal.modemAddr, "a program's address is the kernal's card")
  assertScreenContains("NET45 direct pong:direct 8", "send to one address")
  emu:advance(1)
  assert(not kernal.modemOpenPorts[123], "the program's port was closed when it ended")
  typeLine("net45legacy")
  emu:advance(4)
  assertScreenContains("LNET45 124 pong:legacy 9 true", "a legacy program's modem, with OpenOS's event.pull")
  closeWindowAt(1, 50)
end
print("  OK -- programs open ports, send, broadcast and receive through the kernal's card; ports close at exit")

print("test 46: signals from any node's components reach programs anywhere in the cluster")
do
  kernalFiles["/bin/sig46.mxe"] = [==[
local got = 0
local deadline = computer.uptime() + 6
while got < 2 and computer.uptime() < deadline do
  local e = gmuxapi.pull_event(0.5)
  if e and e[1] == "redstone_changed" then
    got = got + 1
    print("SIG46 " .. e[2] .. " side=" .. tostring(e[3]) .. " new=" .. tostring(e[5]))
  end
end
]==]
  kernalFiles["/usr/bin/sig46legacy.lua"] = [==[
local event = require("event")
local _, addr, side, old, new = event.pull(6, "redstone_changed")
print("LSIG46 " .. tostring(addr) .. " " .. tostring(side) .. " " .. tostring(new))
]==]
  -- A redstone component on the kernal itself too, plugged in now.
  local kernalRedstone = emu:addComponent(kernal, "redstone", {getInput = function() return 0 end})
  emu:injectSignal(kernal, "component_added", kernalRedstone, "redstone")
  emu:advance(0.5)
  typeLine("sig46legacy")
  typeLine("sig46 &")
  emu:advance(2)
  local worker1
  for _, w in ipairs(workers) do
    if w.components[redstoneAddr] then worker1 = w end
  end
  emu:injectSignal(worker1, "redstone_changed", redstoneAddr, 2, 0, 15)
  emu:advance(1)
  emu:injectSignal(kernal, "redstone_changed", kernalRedstone, 4, 3, 7)
  emu:advance(2)
  assertScreenContains("SIG46 " .. redstoneAddr .. " side=2 new=15", "a worker's redstone card's signal reached an .mxe")
  assertScreenContains("SIG46 " .. kernalRedstone .. " side=4 new=7", "...and one on the kernal's own")
  assertScreenContains("LSIG46 " .. redstoneAddr .. " 2 15", "a legacy program got it through event.pull")
  closeWindowAt(1, 50)
end
print("  OK -- redstone_changed from a worker's card and the kernal's own reach .mxe and legacy programs")

print("test 47: OpenOS libraries for legacy programs -- shell, process, thread, tty, buffer, uuid, note")
do
  kernalFiles["/usr/bin/helper47.lua"] = 'print("helper ran") return 7'
  kernalFiles["/usr/bin/libs47.lua"] = [==[
local shell = require("shell")
local args, opts = shell.parse("a", "-xy", "--name=v", "--", "-z")
print("L47 parse " .. table.concat(args, ",") .. " " .. tostring(opts.x) .. tostring(opts.y) .. opts.name)
print("L47 resolve " .. tostring(shell.resolve("helper47", "lua")))
shell.setWorkingDirectory("/usr")
print("L47 cwd " .. shell.getWorkingDirectory() .. " " .. shell.resolve("bin/x"))
local ok, result = shell.execute("helper47")
print("L47 execute " .. tostring(ok) .. " " .. tostring(result))
local id = require("uuid").next()
print("L47 uuid " .. tostring(#id == 36 and id:match("^%x+%-%x+%-4%x+%-[89ab]%x+%-%x+$") ~= nil))
local chunks = {"line one\n", "line two\n"}
local stream = {read = function() return table.remove(chunks, 1) end, close = function() end}
local b = require("buffer").new("r", stream)
print("L47 buffer " .. tostring(b:read("l")) .. "|" .. tostring(b:read("l")))
local thread = require("thread")
local t0 = require("computer").uptime()
local a = thread.create(function() os.sleep(1) end)
local c = thread.create(function() os.sleep(1) end)
thread.waitForAll({a, c})
print(string.format("L47 threads %s %s %.1f", a:status(), c:status(), require("computer").uptime() - t0))
local co = require("process").load(function(x) return x * 3 end)
print("L47 process " .. tostring(select(2, coroutine.resume(co, 5))) .. " " .. tostring(require("process").info().path))
local w, h = require("tty").getViewport()
print("L47 tty " .. tostring(w > 0 and h > 0))
require("note").play(60, 0.05)
print("L47 done")
]==]
  typeLine("libs47")
  emu:advance(6)
  assertScreenContains("helper ran", "shell.execute started the helper in its own window")
  closeWindowAt(1, 50) -- the helper's, on top
  assertScreenContains("L47 parse a,-z truetruev", "shell.parse")
  assertScreenContains("L47 resolve /usr/bin/helper47.lua", "shell.resolve on the PATH")
  assertScreenContains("L47 cwd /usr /usr/bin/x", "the working directory, and resolving against it")
  assertScreenContains("L47 execute true 7", "shell.execute runs a program and waits for its result")
  assertScreenContains("L47 uuid true", "uuid.next")
  assertScreenContains("L47 buffer line one|line two", "buffer over a stream")
  assertScreenContains("L47 threads dead dead 1.", "OpenOS threads run concurrently; waitForAll")
  assertScreenContains("L47 process 15 /usr/bin/libs47.lua", "process.load and process.info")
  assertScreenContains("L47 tty true", "tty.getViewport")
  assertScreenContains("L47 done", "note.play")
  closeWindowAt(1, 50)
end
print("  OK -- shell, process, thread, tty, buffer, uuid and note work for legacy programs")

print("test 48: create_graphics_process -- the child's gpu draws into its own window, and gets its keys")
do
  kernalFiles["/bin/gfx48.mxe"] = [==[
local child = [[
gpu.setBackground(0x0000FF)
gpu.setForeground(0xFFFFFF)
local w, h = gpu.getResolution()
gpu.fill(1, 1, w, h, " ")
gpu.set(2, 1, "GFX48 " .. w .. "x" .. h)
local e
repeat e = gmuxapi.pull_event(20) until not e or e[1] == "key_down"
gpu.set(2, 2, "key=" .. (e and string.char(e[2]) or "none"))
sleep(5)
]]
local r = assert(gmuxapi.create_graphics_process({code = child, title = "gfx48", x = 5, y = 4, width = 20, height = 3}))
print("G48 window=" .. tostring(r.window and r.window.id) .. " owner=" .. tostring(r.window and r.window.ownerJobId == r.process.id))
]==]
  typeLine("gfx48")
  emu:advance(3)
  assertScreenContains("G48 window=", "create_graphics_process returns the window")
  assertScreenContains("owner=true", "...owned by the child")
  assertScreenContains("GFX48 20x3", "the child's gpu drew into its window, at the window's size")
  local gx = renderScreen():gsub("\n", ""):find("GFX48", 1, true)
  local row = screenBuffers[0].cells[5] or {}
  local blue = 0
  for x = 5, 24 do if row[x] and row[x].bg == 0x0000FF then blue = blue + 1 end end
  assert(blue >= 18, "the child's background color is in its window (" .. blue .. " cells)")
  touch("touch", 10, 6)
  emu:injectSignal(kernal, "key_down", screenAddr, string.byte("k"), 0x25, "tester")
  emu:advance(2)
  assertScreenContains("key=k", "keys typed into the window reach the child")
  touch("touch", 5, 25)
end
print("  OK -- a graphics process draws into its own window with its gpu, and receives its keys")

print("test 49: a wallpaper -- a PPM image behind the desktop's icons")
do
  local c = newCluster(80, 25, {
    ["/home/two.ppm"] = "P6\n# two pixels\n2 1\n255\n" .. string.char(255, 0, 0, 0, 0, 255),
    ["/home/green.ppm"] = "P3 1 1 255\n0 255 0\n",
    ["/home/bad.ppm"] = "P6 4 4 255\nxx",
  }, 1)
  local function bg(x, y) local cell = c.cell(x, y) return cell and cell.bg end
  c.typeLine("wallpaper /home/two.ppm")
  c.emu:advance(1)
  assert(bg(10, 1) == 0xFF0000 and bg(70, 1) == 0x0000FF,
    string.format("a P6 image stretched over the screen (got %06x, %06x)", bg(10, 1) or 0, bg(70, 1) or 0))
  assert(c.files["/etc/wallpaper"] == "/home/two.ppm\n", "remembered in /etc/wallpaper")
  local ix, iy = c.find("/-------\\")
  assert(ix and bg(ix, iy) == 0x444444, "icons sit on tiles of the desktop's color")
  c.typeLine("wallpaper /home/green.ppm")
  c.emu:advance(1)
  assert(bg(10, 1) == 0x00FF00 and bg(70, 1) == 0x00FF00, "a P3 image")
  c.typeLine("wallpaper /home/bad.ppm")
  c.emu:advance(1)
  assert(c.text():find("wallpaper: /home/bad.ppm: the image is cut short", 1, true), "a bad image is refused:\n" .. c.text())
  assert(bg(10, 1) == 0x00FF00, "...and the wallpaper stays")
  -- Kept across a reboot.
  c.typeLine("reboot")
  c.emu:boot(c.kernal)
  c.emu:advance(4)
  assert(bg(10, 1) == 0x00FF00, "the wallpaper comes back after a reboot")
  c.typeLine("wallpaper none")
  c.emu:advance(1)
  assert(bg(10, 1) == 0x444444 and not c.files["/etc/wallpaper"], "wallpaper none: the plain desktop again")
end
print("  OK -- P6 and P3 wallpapers, stretched behind the icons, remembered across reboots, cleared")

print("test 50: the console's line editor -- history, cursor movement, editing keys, paste")
do
  local c = newCluster(80, 25, {}, 1)
  local LEFT, RIGHT, UP, DOWN, HOME, END_, DEL = 0xCB, 0xCD, 0xC8, 0xD0, 0xC7, 0xCF, 0xD3
  local function prompt() -- the last prompt on screen: the live line
    for y = 25, 1, -1 do
      local row = c.cells(1, y, 80)
      local at = row:find("root@muxos:~> ", 1, true)
      if at then
        local x = utf8.len(row:sub(1, at - 1)) + 1
        return (c.cells(x + 14, y, 40):gsub("%s+$", "")), x, y
      end
    end
    error("no prompt:\n" .. c.text())
  end
  c.typeLine("echo one")
  c.typeLine("echo two")
  -- Up recalls the newest first; Down goes back toward the line being typed.
  for _, ch in ipairs({"d", "r", "a", "f", "t"}) do c.key(ch:byte()) end
  c.key(0, UP)
  assert(prompt() == "echo two_", "Up: the last command (got " .. prompt() .. ")")
  c.key(0, UP)
  assert(prompt() == "echo one_", "Up again: the one before")
  c.key(0, UP)
  assert(prompt() == "echo one_", "...and no further")
  c.key(0, DOWN)
  c.key(0, DOWN)
  assert(prompt() == "draft_", "Down past the newest: the line being typed comes back (got " .. prompt() .. ")")
  -- Cursor movement: the cursor's character is drawn inverted.
  c.key(0, HOME)
  c.key(("X"):byte())
  local text, x, y = prompt()
  assert(text == "Xdraft", "Home, then typing inserts at the start (got " .. text .. ")")
  local under = c.cell(x + 15, y)
  assert(under.char == "d" and under.bg == 0xFFFFFF and under.fg == 0x000000, "the cursor is the inverted 'd'")
  c.key(0, RIGHT) c.key(0, RIGHT)
  c.key(0, DEL)
  assert(prompt() == "Xdrft", "Delete removes the character under the cursor (got " .. prompt() .. ")")
  c.key(0, LEFT)
  c.key(8, 0x0E)
  assert(prompt() == "Xrft", "Backspace removes the one before it (got " .. prompt() .. ")")
  c.key(11) -- ^K
  assert(prompt() == "X_", "^K cuts to the end (got " .. prompt() .. ")")
  c.key(0, END_)
  c.key(21) -- ^U
  assert(prompt() == "_", "^U cuts to the start")
  for ch in ("echo alpha beta"):gmatch(".") do c.key(ch:byte()) end
  c.key(23) -- ^W
  assert(prompt() == "echo alpha _", "^W cuts the last word (got " .. prompt() .. ")")
  c.key(21)
  -- Paste: each newline is an Enter, so a pasted script runs line by line.
  c.emu:injectSignal(c.kernal, "clipboard", "kbd", "echo pasted1\necho pasted2\necho half", "tester")
  c.emu:advance(1)
  local screen = c.text()
  assert(screen:find("\npasted1", 1, true) and screen:find("\npasted2", 1, true), "both pasted lines ran:\n" .. screen)
  assert(prompt() == "echo half_", "the unfinished last line waits at the prompt (got " .. prompt() .. ")")
  c.key(13, 0x1C)
  c.emu:advance(0.5)
  c.key(0, UP)
  assert(prompt() == "echo half_", "pasted lines go into the history too")
end
print("  OK -- history, Home/End/arrows, Delete/Backspace, ^U ^K ^W, an inverted cursor, multi-line paste")

print("test 51: the fullscreen grant is released when the program holding it ends")
do
  local c = newCluster(80, 25, {}, 1)
  -- It draws over the whole screen, then ends without releasing.
  c.typeLine('spawn 1 gmuxapi.request_fullscreen() gpu.fill(1, 1, 80, 25, " ") gpu.set(1, 1, "GRABBED") sleep(2)')
  c.emu:advance(1)
  assert(c.text():find("GRABBED", 1, true) and not c.text():find("root@muxos:~>", 1, true),
    "while it holds the grant, the screen is its:\n" .. c.text())
  c.emu:advance(3)
  assert(c.text():find("root@muxos:~>", 1, true), "it ended without releasing: the desktop and console are back:\n" .. c.text())
  c.typeLine('run local g, e = gmuxapi.request_fullscreen() local r = gmuxapi.release_fullscreen() return tostring(g ~= nil) .. "/" .. tostring(r ~= nil)')
  c.emu:advance(2)
  assert(c.text():find("true/true", 1, true), "and the grant is free for the next program:\n" .. c.text())
end
print("  OK -- a program that ends holding fullscreen gives the screen back")

print("test 52: users and login, root-only actions, and kernal flags")
do
  local c = newCluster(80, 25, {
    ["/etc/kernal.cfg"] = "# test flags\nlogin_required = true\nbogus = 1\nreboot_requires_root = maybe\n",
    ["/bin/whereami.lua"] = 'print("env " .. os.getenv("USER") .. " " .. os.getenv("HOME") .. " " .. os.getenv("PWD"))',
  }, 1)
  local function has(str) return c.text():find(str, 1, true) end
  local function run(line, wait) c.typeLine(line) c.emu:advance(wait or 0.5) end
  assert(has("login: _"), "login_required: the console asks who you are:\n" .. c.text())
  assert(has("no flag called bogus") and has("reboot_requires_root is true or false"),
    "bad lines in /etc/kernal.cfg are reported:\n" .. c.text())
  run("alice")
  assert(has("no such user: alice") and has("login: _"), "an unknown name doesn't log in, or create a user")
  run("root")
  assert(has("root@muxos:~> _"), "root logs in, at home:\n" .. c.text())
  run("useradd Bad!")
  assert(has("useradd: a user name is lowercase"), "a bad user name is refused")
  run("useradd alice")
  assert(has("added alice (home /home/alice)") and c.files["/etc/users"] == "alice\n", "useradd adds a user")
  run("flags")
  assert(has("useradd_requires_root  = true") and has("reboot_requires_root   = false"), "flags lists them:\n" .. c.text())
  run("flags nosuch 1")
  assert(has("flags: no flag called nosuch"), "an unknown flag is refused")
  run("flags login_required maybe")
  assert(has("flags: login_required is true or false"), "a bad value is refused")
  run("flags reboot_requires_root true")
  assert(has("reboot_requires_root = true"), "root sets a flag")
  assert(c.files["/etc/kernal.cfg"]:find("reboot_requires_root = true\n", 1, true)
    and c.files["/etc/kernal.cfg"]:find("# test flags", 1, true), "...saved, keeping the file's other lines")
  run("spawn 1 sleep(60)")
  local rootJob = c.text():match("spawned job %[(%d+)%]")
  run("logout")
  assert(has("login: _") and not has("useradd"), "logout: back to login, the console cleared:\n" .. c.text())
  run("alice")
  assert(has("alice@muxos:~> _"), "alice logs in:\n" .. c.text())
  run("pwd; whoami")
  assert(has("/home/alice") and has("\nalice"), "her home and name:\n" .. c.text())
  run("whereami", 2)
  assert(has("env alice /home/alice /home/alice"), "legacy programs see USER, HOME and PWD:\n" .. c.text())
  local bx = c.cells(1, 25, 80):find(" console ", 1, true)
  c.touch(bx + 2, 25) -- the console's taskbar button: it's back on top
  run("update")
  assert(has("update: only root can do that (flag update_requires_root)"), "update is root's:\n" .. c.text())
  run("reboot")
  assert(has("reboot: only root can do that") and c.emu.nodes, "reboot too, now that the flag says so")
  run("flags reboot_requires_root false")
  assert(has("flags: only root can change flags"), "flags are root's")
  run("spawn 1 sleep(60)")
  local aliceJob = c.text():match("spawned job %[(%d+)%]")
  run("processes")
  assert(has("[" .. rootJob .. "] killed on") and has("as root -- killed (logged out)")
    and has("[" .. aliceJob .. "] running on") and has("as alice"),
    "processes shows whose each one is; root's logout ended root's:\n" .. c.text())
  run("logout", 1)
  run("root")
  run("processes")
  assert(has("[" .. aliceJob .. "] killed") and has("killed (logged out)"), "logging out ended alice's process:\n" .. c.text())
  run("userdel alice")
  assert(has("removed alice (their home /home/alice is kept)") and c.files["/etc/users"] == "", "userdel removes her")
  run("logout")
  run("alice")
  assert(has("no such user: alice"), "and she can't log in any more")
  -- The other two flags: processes outlive a logout; only their owner kills them.
  run("root")
  run("flags logout_ends_jobs false; flags kill_requires_owner true; useradd bob")
  run("spawn 1 sleep(60)")
  local kept = c.text():match("spawned job %[(%d+)%]")
  run("logout", 1)
  run("bob")
  run("kill " .. kept)
  assert(has("error: job [" .. kept .. "] is root's (flag kill_requires_owner)"), "bob can't kill root's:\n" .. c.text())
  run("processes")
  assert(has("[" .. kept .. "] running on"), "root's process outlived the logout:\n" .. c.text())
end
print("  OK -- login by name only, useradd/userdel, root-only update/reboot/flags, logout ends that login's processes")

print("test 53: render targets -- children draw their parts of one window; split, alternate and tearing frames")
do
  local child = [==[
local e
repeat e = gmuxapi.pull_event(10) until not e or e[1] == "window_shared"
if not e then return "no share" end
for f = 1, args.frames do
  local ok, err = gmuxapi.draw_region(args.win, f, {text = {args.text, args.text, args.text, args.text}})
  if not ok then return "err " .. tostring(err) end
  repeat e = gmuxapi.pull_event(10) until not e or (e[1] == "frame_presented" and e[3] == f)
end
local outside, why = gmuxapi.draw_region(args.win, args.frames + 1, {pixels = {{1}}, width = 1, height = 2, x = args.outside, y = 1})
if args.linger then sleep(args.linger) end
return "done " .. tostring(why)
]==]
  local program = [==[--[[mxe
name = "render53"
]]
local CHILD = CHILD_SOURCE
local win = gmuxapi.create_window({title = "render53", x = 2, y = 2, width = 20, height = 4, code = "gpu.fill(1, 1, 20, 4, '.')"}).id
local config = gmuxapi.render_config(win, {mode = "split", deadline = 1})
local _, bad = gmuxapi.render_config(win, {mode = "fast"})
local _, bad2 = gmuxapi.render_config(win, {speed = 1})
print("config " .. config.mode .. " " .. config.deadline .. " " .. config.stale .. " | " .. tostring(bad) .. " | " .. tostring(bad2))
local a = gmuxapi.create_headless_process({code = CHILD, args = {win = win, frames = 2, text = "AAAAAAAAAA", outside = 15}})
local b = gmuxapi.create_headless_process({code = CHILD, args = {win = win, frames = 1, text = "BBBBBBBBBB", linger = 4, outside = 1}})
local _, notMine = gmuxapi.share_window(win, 999999, {1, 1, 5, 1})
print("share " .. tostring(gmuxapi.share_window(win, a.process.id, {1, 1, 10, 4})) .. " "
  .. tostring(gmuxapi.share_window(win, b.process.id, {x = 11, y = 1, w = 10, h = 4})) .. " | " .. tostring(notMine))
local seen = {}
local stop = computer.uptime() + 10
while #seen < 2 and computer.uptime() < stop do
  local e = gmuxapi.pull_event(1)
  if e and e[1] == "frame_presented" then seen[#seen + 1] = e[3] .. ":" .. tostring(e[4]) end
end
print("presented " .. table.concat(seen, " "))
-- Alternate: frame 2 shows at once; frame 1, late, never does.
local w2 = gmuxapi.create_window({title = "alt53", x = 2, y = 9, width = 10, height = 1, code = "gpu.fill(1, 1, 10, 1, ' ')"}).id
gmuxapi.render_config(w2, {mode = "alternate", queue = 3})
gmuxapi.draw_region(w2, 2, {text = {"TWO"}})
local _, late = gmuxapi.draw_region(w2, 1, {text = {"ONE"}})
-- Tearing: frame 1 shows as soon as frame 2 starts.
local w3 = gmuxapi.create_window({title = "tear53", x = 2, y = 7, width = 10, height = 1, code = "gpu.fill(1, 1, 10, 1, ' ')"}).id
gmuxapi.render_config(w3, {mode = "tearing", deadline = 5})
gmuxapi.draw_region(w3, 1, {text = {"first"}})
gmuxapi.draw_region(w3, 2, {text = {"X"}})
local e
repeat e = gmuxapi.pull_event(3) until not e or (e[1] == "frame_presented" and e[2] == w3)
print("late " .. tostring(late) .. " | tear " .. (e and (e[3] .. ":" .. tostring(e[4])) or "none"))
-- A big region goes in bands of `chunk` bytes, all one frame.
local w4 = gmuxapi.create_window({title = "big53", x = 30, y = 9, width = 20, height = 4, code = "gpu.fill(1, 1, 20, 4, ' ')"}).id
gmuxapi.render_config(w4, {chunk = 512})
local pixels = {}
for y = 1, 8 do
  pixels[y] = {}
  for x = 1, 20 do pixels[y][x] = y <= 4 and 0xFF0000 or 0x00FF00 end
end
local okBig, bigErr = gmuxapi.draw_region(w4, 1, {pixels = pixels, width = 20, height = 8, mode = "halfblock"})
print("big " .. tostring(okBig) .. " " .. tostring(bigErr))
sleep(1)
print("results " .. tostring(gmuxapi.get_process(a.process.id).result))
]==]
  program = program:gsub("CHILD_SOURCE", function() return string.format("%q", child) end)
  local c = newCluster(80, 25, {["/bin/render53.mxe"] = program}, 3)
  c.typeLine("render53")
  for _ = 1, 30 do
    if c.text():find("results", 1, true) then break end
    c.emu:advance(0.5)
  end
  local text = c.text():gsub("\n", "")
  assert(text:find("config split 1 keep | mode is one of alternate, split, tearing, not fast | no render setting called speed", 1, true),
    "render_config sets and refuses:\n" .. text)
  assert(text:find("share true true | process 999999 isn't a running descendant of yours", 1, true), "share_window:\n" .. text)
  assert(text:find("presented 1:true 2:false", 1, true),
    "frame 1 complete (both parts), frame 2 at its deadline without the second part:\n" .. text)
  assert(text:find("late frame 1 is already past | tear 1:false", 1, true), "alternate and tearing:\n" .. text)
  assert(text:find("results done the region is outside the share", 1, true), "drawing outside a share is refused:\n" .. text)
  assert(text:find("AAAAAAAAAABBBBBBBBBB", 1, true), "both parts in the window, the second kept from frame 1:\n" .. text)
  assert(text:find("TWO", 1, true) and not text:find("ONE", 1, true) and text:find("first", 1, true),
    "what each mode put on screen:\n" .. text)
  assert(text:find("big true nil", 1, true), "a big region in bands:\n" .. text)
  local function color(cell) return cell and (cell.char == " " and cell.bg or cell.fg) end
  assert(color(c.cell(30, 10)) == 0xFF0000 and color(c.cell(49, 13)) == 0x00FF00,
    "every band landed: top red, bottom green (got " .. tostring(color(c.cell(30, 10))) .. ", "
    .. tostring(color(c.cell(49, 13))) .. ")")
end
print("  OK -- shares, split frames (complete and at the deadline), alternate order, tearing, refusals")

print("ALL OK")
