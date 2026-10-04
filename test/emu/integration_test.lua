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

-- --- Build the kernal ---
local kernal = emu:newNode("kernal")
local kernalEnv = emu:buildEnv(kernal)
emu:addModem(kernal)
emu:addEeprom(kernal)
local gpuAddr, screenAddr, screenBuffers = emu:addGpuScreen(kernal, 50, 30)
emu:addFilesystem(kernal, {
  ["/muxos.lua"] = muxosSrc,
  ["/compositor.lua"] = compositorSrc,
  ["/bitmap.lua"] = bitmapSrc,
  ["/runtime.lua"] = runtimeSrc,
})

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

local function dumpScreenOnFailure(label)
  io.stderr:write("\n=== screen at failure (" .. label .. ") ===\n" .. renderScreen() .. "\n=== end ===\n")
  io.stderr:write("\n=== emulator log (last 40) ===\n")
  local n = #emu.log
  for i = math.max(1, n - 40), n do
    local e = emu.log[i]
    io.stderr:write(string.format("[%.2f] %s: %s\n", e.t, e.node, e.msg))
  end
end

local biosChunk = assert(kernalEnv.load(kernalBiosSrc, "=bios", "t", kernalEnv))
emu:boot(kernal, biosChunk)
assert(kernal.status == "running", "kernal failed to boot: see log")

-- --- Build 3 workers ---
local workers = {}
for i = 1, 3 do
  local w = emu:newNode("worker")
  local wenv = emu:buildEnv(w)
  emu:addModem(w)
  local chunk = assert(wenv.load(workerBiosSrc, "=bios", "t", wenv))
  emu:boot(w, chunk)
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
assertScreenContains("muxos>", "prompt visible")
-- The startup banner itself may have already scrolled off a short
-- console by now -- that's correct behavior (confirmed: this is a real
-- fixed-height scrolling console, see kernal/muxos.lua's termWrite),
-- not something to assert on. All 3 workers should still be visible in
-- the post-boot discover(1) + listNodes() output, though.
do
  local screen = renderScreen()
  local count = 0
  for _ in screen:gmatch("worker%-%x+") do count = count + 1 end
  if count < 3 then
    dumpScreenOnFailure("worker discovery")
    error("expected all 3 workers listed after boot, found " .. count)
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

print("test 6: a NON-cooperating long JOB gets killed by the instruction-budget circuit breaker, not the worker")
typeLine("run local x = 0 for i = 1, 100000000 do x = x + 1 end return x")
emu:advance(4)
assertScreenContains("error", "non-cooperating job error")
assertScreenContains("instruction budget", "circuit breaker message")
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

print("test 10: Ctrl+Alt+C force-releases a stuck fullscreen grant at the kernal console")
-- worker 1 grabs the grant and deliberately never releases it (fire-and-forget spawn).
typeLine('spawn 1 gmuxapi.request_fullscreen()')
emu:advance(2)
-- worker 2 trying to grab it now must be denied -- confirms the grant is actually held.
typeLine('run local g, gerr = gmuxapi.request_fullscreen() return tostring(g) .. "|" .. tostring(gerr)')
emu:advance(2)
assertScreenContains("already held by", "grant correctly held by worker 1")
print("  OK -- grant confirmed held (second requester denied)")

-- Inject the real Ctrl+Alt+C combo as three separate key_down signals,
-- exactly as a human holding all three keys would generate -- matching
-- the exact keycodes OpenOS's own lib/keyboard.lua uses (verified
-- against its source, see docs/PROTOCOL.md).
local KEY_LCONTROL, KEY_LMENU, KEY_C = 0x1D, 0x38, 0x2E
emu:injectSignal(kernal, "key_down", screenAddr, 0, KEY_LCONTROL, "tester")
emu:step()
emu:injectSignal(kernal, "key_down", screenAddr, 0, KEY_LMENU, "tester")
emu:step()
emu:injectSignal(kernal, "key_down", screenAddr, string.byte("c"), KEY_C, "tester")
emu:step()
emu:advance(1)
assertScreenContains("force-releasing fullscreen grant", "Ctrl+Alt+C release message")
print("  OK -- Ctrl+Alt+C printed the force-release message")

-- Confirm the grant is ACTUALLY free now, not just that the message
-- printed: a fresh request should succeed immediately.
typeLine('run local g, gerr = gmuxapi.request_fullscreen() return tostring(g) .. "|" .. tostring(gerr)')
emu:advance(2)
assertScreenContains("true|nil", "grant actually available again after Ctrl+Alt+C")
print("  OK -- fullscreen grant was genuinely free after the escape hatch, not just the message")

print("ALL OK")
