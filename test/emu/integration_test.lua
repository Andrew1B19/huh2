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

print("test 10: Ctrl+Alt+C is the console interrupt -- releases a stuck fullscreen grant and shows the console")
-- worker 1 grabs the grant and deliberately never releases it (fire-and-forget spawn).
typeLine('spawn 1 gmuxapi.request_fullscreen()')
emu:advance(2)
-- worker 2 trying to grab it now must be denied. The console is a
-- compositor window, and compositing is suspended while a node owns the
-- screen, so this denial only becomes visible after the interrupt.
typeLine('run local g, gerr = gmuxapi.request_fullscreen() return tostring(g) .. "|" .. tostring(gerr)')
emu:advance(2)

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
assertScreenContains("already held by", "second requester was denied while the grant was held")
assertScreenContains("force-releasing fullscreen grant", "Ctrl+Alt+C release message")
assertScreenContains("console only", "Ctrl+Alt+C put the console in solo mode")
print("  OK -- the console came up over the stuck fullscreen app, showing the denied request and the release")

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
typeLine('run local a=gmuxapi.create_headless_process({code="local t=0 for i=1,2000 do t=t+1 if i%50==0 then yield() end end return t", name="testapp", orphan_policy="orphan"}); local b=gmuxapi.create_headless_process({code="return 123", name="testapp", orphan_policy="promote"}); local c=gmuxapi.create_headless_process({code="local t=0 for i=1,2000 do t=t+1 if i%50==0 then yield() end end return t", name="testapp", orphan_policy="kill"}); return tostring(a.process.id) .. "," .. tostring(b.process.id) .. "," .. tostring(c.process.id)')
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
emu:injectSignal(kernal, "key_down", screenAddr, 0, KEY_LCONTROL, "tester"); emu:step()
emu:injectSignal(kernal, "key_down", screenAddr, 0, KEY_LMENU, "tester"); emu:step()
emu:injectSignal(kernal, "key_down", screenAddr, string.byte("c"), KEY_C, "tester"); emu:step()
emu:advance(1)
typeLine("spawn 1 gmuxapi.request_fullscreen()")
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
emu:injectSignal(kernal, "key_down", screenAddr, string.byte("c"), KEY_C, "tester"); emu:step()
emu:advance(1)
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
if not screenAfter("window spin 1 1 5 1"):find("exceeded its instruction budget", 1, true) then
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
-- Ctrl+Alt+C (test 10) left the console in solo mode. A window created
-- now is drawn into its buffer but not shown until `comp`.
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
assertScreenContains('"console"  50x15 at (1,16)', "the console starts as the bottom half of the screen")
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
assertScreenContains('"console"  30x8 at (1,23)', "console resized and docked bottom-left")
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
if not screenHas("muxos> " .. ("x"):rep(45) .. "_") or screenHas(("x"):rep(46)) then
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
emu:advance(2)
assertScreenContains("e27=nil/nil/false", "no debug, no raw component, read-only libraries")
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
assertScreenContains("k27=killed/killed by user", "the user can end a process")
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
  local firstRow = renderScreen():match("^[^\n]*")
  if firstRow:sub(1, 4) ~= "hi28" or screenHas("muxos> hi28") then
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

print("ALL OK")
