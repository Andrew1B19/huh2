-- Hardware verification suite for muxos. Bare-metal, no OpenOS required
-- -- run this directly on REAL OpenComputers hardware to check a list
-- of low-level primitives this project's design depends on. Several of
-- these could only be verified by reading the mod's own Scala source
-- in the sandbox this project was built in -- there was no real OC Lua
-- environment available there to actually run against, and some of
-- these (eris's ability to persist a SUSPENDED coroutine specifically,
-- which the project's proposed "semi-live" job migration depends on
-- entirely) can only be answered by actually running them for real.
--
-- Each check is self-contained and pcall-wrapped, so one failing or
-- crashing check can't take down the rest of the suite -- important on
-- real hardware, where a hang might mean physically breaking the block
-- to recover.
--
-- Install: flash directly to an EEPROM (`eeprom test/hardware/verify.lua`
-- from an OpenOS shell, same as any other EEPROM image) and boot with
-- no OpenOS -- the checks that depend on coroutine.yield(timeout)
-- actually receiving real signals (computer.pushSignal round trip)
-- need to run as the computer's own true top-level/kernel coroutine to
-- mean anything; running this as an ordinary OpenOS program instead
-- would nest it under OpenOS's own thread/process scheduling and could
-- give a misleading result for those specific checks. The eris/
-- debug.sethook checks don't depend on this and would read the same
-- either way, but flashing it bare is the only way to trust ALL of the
-- results at once.
--
-- A gpu+screen is used to report results if present (plain
-- component.invoke, not muxos's console -- this doesn't depend on any
-- other file in this project). If neither is present, results are
-- only reported via a beep pattern (one pattern if everything passed,
-- another if anything failed) -- check the results table on the
-- in-game screen/log where possible instead.

local results = {}

local function check(name, fn)
  local ok, detail = pcall(fn)
  results[#results + 1] = {name = name, ok = ok, detail = detail}
end

-- --- 1. Native API surface sanity ---

check("component.list/invoke exist", function()
  assert(type(component) == "table", "no component global")
  assert(type(component.list) == "function", "no component.list")
  assert(type(component.invoke) == "function", "no component.invoke")
  return "ok"
end)

check("computer.address/uptime/beep/pushSignal exist", function()
  assert(type(computer) == "table", "no computer global")
  assert(type(computer.address) == "function", "no computer.address")
  assert(type(computer.uptime) == "function", "no computer.uptime")
  assert(type(computer.beep) == "function", "no computer.beep")
  assert(type(computer.pushSignal) == "function", "no computer.pushSignal")
  return computer.address()
end)

-- --- 2. coroutine.yield(timeout) as computer.pullSignal's real primitive.
-- Ordinary Lua-level semantics only (suspend/resume, timeout value) --
-- NOT a check that it receives real external signals; that needs to
-- run at this script's own true top level (see check 5, below), since
-- the mod only ever resumes ONE coroutine (the computer's own "kernel
-- thread") -- a separately coroutine.create()'d one, like this one,
-- never receives real signals through its own yields no matter how
-- it's nested, confirming why node/runtime.lua's job-preemption design
-- had to manually bridge a job's nested coroutine to the real signal
-- queue rather than letting it yield "directly" as if it were the top
-- level. ---

check("coroutine.yield(timeout) suspends and resumes correctly (Lua-level only)", function()
  local co = coroutine.create(function()
    local a = coroutine.yield(0.5)
    return a
  end)
  local ok, err = coroutine.resume(co)
  assert(ok, tostring(err))
  assert(coroutine.status(co) == "suspended", "expected the coroutine to be suspended after yielding")
  local ok2, result = coroutine.resume(co, "resumed-value")
  assert(ok2, tostring(result))
  assert(result == "resumed-value", "expected the resume argument to come back as the yield's return value")
  return "ok"
end)

-- --- 3. Lua library profile: utf8 (5.3) vs bit32 (5.2) ---

check("Lua library profile (utf8 vs bit32)", function()
  local hasUtf8 = type(utf8) == "table" and type(utf8.char) == "function"
  local hasBit32 = type(bit32) == "table"
  if hasUtf8 then
    return "Lua 5.3 profile (utf8 present) -- kernal/bitmap.lua's utf8.char will work as written"
  end
  if hasBit32 then
    return "Lua 5.2 profile (bit32 present, no utf8!) -- kernal/bitmap.lua's utf8.char call WILL FAIL on this build, needs a fallback encoder"
  end
  error("neither utf8 nor bit32 present -- unrecognized Lua profile, check against LuaStateFactory.scala again")
end)

-- --- 4a. debug.sethook: error() from a hook works (this project's real
-- circuit-breaker mechanism) ---

check("debug.sethook count hook: error() from a hook kills the coroutine cleanly", function()
  local co = coroutine.create(function()
    local x = 0
    for i = 1, 1000000 do x = x + 1 end
    return x
  end)
  debug.sethook(co, function() error("budget hit", 0) end, "", 100)
  local ok, err = coroutine.resume(co)
  assert(not ok, "expected the hook's error to abort the coroutine")
  assert(tostring(err):find("budget hit", 1, true), "wrong error message: " .. tostring(err))
  return "ok, error = " .. tostring(err)
end)

-- --- 4b. debug.sethook: yield() from a hook does NOT work. Confirms (or
-- refutes, on whatever Lua build this hardware actually runs) the
-- finding node/runtime.lua's whole job-preemption design depends on. ---

check("debug.sethook count hook: yield() from a hook fails (expected -- confirms/refutes a load-bearing finding)", function()
  local co = coroutine.create(function()
    local x = 0
    for i = 1, 1000000 do x = x + 1 end
    return x
  end)
  debug.sethook(co, function() coroutine.yield("preempt") end, "", 100)
  local ok, err = coroutine.resume(co)
  if not ok and tostring(err):find("yield", 1, true) then
    return "CONFIRMED: yielding from a hook fails here too (\"" .. tostring(err) ..
      "\") -- matches the dev-sandbox finding node/runtime.lua's design depends on"
  elseif ok then
    return "UNEXPECTED: yielding from a hook actually WORKED here -- the dev-sandbox " ..
      "finding does NOT hold on this build; node/runtime.lua's job-preemption design " ..
      "could be simplified (a real preempt-and-resume instead of the error-based circuit breaker)"
  else
    error("hook failed with an unexpected error, not a yield-boundary one: " .. tostring(err))
  end
end)

-- --- 4c. debug.sethook: re-arming before each resume gives a fresh
-- per-slice budget (node/runtime.lua's armBudgetHook pattern) ---

check("debug.sethook count hook: re-arming before each resume gives a fresh per-slice budget", function()
  local slices = 0
  local co = coroutine.create(function()
    for i = 1, 5 do
      for j = 1, 300 do end -- some work
      coroutine.yield()
    end
    return "done"
  end)
  local function arm()
    debug.sethook(co, function() error("budget hit", 0) end, "", 1000)
  end
  local ok, result = true, nil
  while ok and coroutine.status(co) ~= "dead" do
    arm()
    ok, result = coroutine.resume(co)
    slices = slices + 1
    if slices > 20 then error("did not converge within 20 slices") end
  end
  assert(ok and result == "done", "expected the cooperating coroutine to finish, got " .. tostring(result))
  return "ok, finished across " .. slices .. " resume slices"
end)

-- --- 5. computer.pushSignal round-trips through a REAL coroutine.yield
-- at this script's OWN top level (not a nested coroutine -- see the
-- comment on check 2 for why that distinction matters). Only
-- meaningful if this script is actually running bare, as the
-- computer's own kernel thread -- see this file's header. ---

check("computer.pushSignal delivers a real signal back via coroutine.yield at top level", function()
  computer.pushSignal("hw_test_signal", "payload123")
  local name, payload = coroutine.yield(2)
  assert(name == "hw_test_signal", "expected to receive the pushed signal, got name=" .. tostring(name) ..
    " -- if this script is running under OpenOS rather than bare, that would explain a mismatch here")
  assert(payload == "payload123", "signal arrived but payload didn't match: " .. tostring(payload))
  return "ok -- pushSignal correctly round-tripped through a real top-level yield"
end)

-- --- 6. eris availability ---

check("eris global exists with persist/unpersist", function()
  assert(type(eris) == "table", "no eris global -- ERIS library not opened on this build")
  assert(type(eris.persist) == "function", "no eris.persist")
  assert(type(eris.unpersist) == "function", "no eris.unpersist")
  return "ok"
end)

-- --- 7. eris basic round trip: a plain table ---

check("eris persists and unpersists a plain table correctly", function()
  local perms, uperms = {}, {}
  local original = {x = 42, y = "hello", nested = {1, 2, 3}}
  local bytes = eris.persist(perms, original)
  assert(type(bytes) == "string", "persist did not return a string, got " .. type(bytes))
  local restored = eris.unpersist(uperms, bytes)
  assert(restored.x == 42 and restored.y == "hello", "scalar fields did not round-trip")
  assert(restored.nested[1] == 1 and restored.nested[3] == 3, "nested table did not round-trip")
  assert(restored ~= original, "unpersist should produce a NEW table, not the same reference")
  return "ok, " .. #bytes .. " bytes"
end)

-- --- 8. THE KEY QUESTION this whole suite exists to answer: does eris
-- persist a SUSPENDED coroutine's call stack/locals, and does resuming
-- the revived one continue correctly? This is the entire mechanism
-- "semi-live" job migration (pause, serialize, ship, resume elsewhere)
-- would depend on. Strongly implied by OC's own use of eris to persist
-- a computer's live kernel thread across every world save
-- (PersistenceAPI.scala) -- but never run directly from Lua code in
-- this project before now. ---

check("eris persists a SUSPENDED coroutine and it resumes correctly after unpersist", function()
  local perms, uperms = {}, {}
  local co = coroutine.create(function()
    local total = 0
    for i = 1, 10 do
      total = total + i
      coroutine.yield(total) -- pauses here repeatedly, with real accumulated local state
    end
    return "finished with total=" .. total
  end)
  -- Run it partway: 3 steps in, so its suspended call stack holds real
  -- accumulated state (total=6, i=3) at the moment we persist it.
  local ok1, v1 = coroutine.resume(co)
  local ok2, v2 = coroutine.resume(co)
  local ok3, v3 = coroutine.resume(co)
  assert(ok1 and ok2 and ok3, "setup resumes failed")
  assert(v3 == 6, "expected total=6 (1+2+3) three steps in, got " .. tostring(v3))

  local bytes = eris.persist(perms, co)
  assert(type(bytes) == "string", "persisting the suspended coroutine did not return a string, got " .. type(bytes))

  local revived = eris.unpersist(uperms, bytes)
  assert(type(revived) == "thread", "unpersist did not produce a coroutine, got " .. type(revived))
  assert(revived ~= co, "unpersist should produce a NEW coroutine object, not the same reference")

  -- Resume the REVIVED coroutine, not the original. If this continues
  -- correctly (total=10, then total=15, matching what the ORIGINAL
  -- would have produced next), the suspended call stack -- including
  -- its local variables -- genuinely survived the persist/unpersist
  -- round trip.
  local ok4, v4 = coroutine.resume(revived)
  assert(ok4, tostring(v4))
  assert(v4 == 10, "expected total=10 on the revived coroutine's next step, got " .. tostring(v4))
  local ok5, v5 = coroutine.resume(revived)
  assert(v5 == 15, "expected total=15, got " .. tostring(v5))

  return "CONFIRMED: suspended coroutine state survived persist/unpersist -- v4=" ..
    tostring(v4) .. " v5=" .. tostring(v5)
end)

-- --- 9. eris + a reference to a native function, correctly marked
-- permanent. This is what lets a migrated job's component/computer
-- calls correctly re-bind to the TARGET node's own hardware instead of
-- either erroring or carrying a stale reference to the old node's. ---

check("eris treats a marked-permanent native function correctly on unpersist", function()
  local perms, uperms = {}, {}
  perms[computer.uptime] = "computer.uptime"
  uperms["computer.uptime"] = computer.uptime

  local holder = {getTime = computer.uptime}
  local bytes = eris.persist(perms, holder)
  local restored = eris.unpersist(uperms, bytes)
  assert(type(restored.getTime) == "function", "restored.getTime is not a function, got " .. type(restored.getTime))
  local t = restored.getTime()
  assert(type(t) == "number", "calling the restored native function reference did not return a number")
  return "ok, restored native function reference callable, returned " .. tostring(t)
end)

-- --- 10. GPU/screen smoke test (only if present -- see the reporter
-- below, which uses the same components) ---

check("gpu/screen basic smoke test (allocateBuffer/set/fill/bitblt)", function()
  local gpuAddr = component.list("gpu")()
  local screenAddr = component.list("screen")()
  if not gpuAddr then return "skipped -- no gpu component present" end
  if screenAddr then component.invoke(gpuAddr, "bind", screenAddr) end
  local w, h = component.invoke(gpuAddr, "getResolution")
  assert(type(w) == "number" and type(h) == "number", "getResolution did not return numbers")
  if component.invoke(gpuAddr, "allocateBuffer") then
    local buf = component.invoke(gpuAddr, "allocateBuffer", 5, 5)
    assert(buf, "allocateBuffer returned nothing")
    component.invoke(gpuAddr, "setActiveBuffer", buf)
    component.invoke(gpuAddr, "set", 1, 1, "hi")
    component.invoke(gpuAddr, "setActiveBuffer", 0)
    component.invoke(gpuAddr, "bitblt", 0, 1, 1, 5, 5, buf, 1, 1)
    component.invoke(gpuAddr, "freeBuffer", buf)
    return "ok, resolution " .. w .. "x" .. h .. ", Tier 3 buffer operations all succeeded"
  end
  return "ok, resolution " .. w .. "x" .. h .. " (no allocateBuffer -- not Tier 3, muxos requires Tier 3)"
end)

-- --- 11. Modem smoke test (open/broadcast don't error -- a real
-- loopback check needs a second node, out of scope for a single-file
-- suite; see test/emu's integration test for the full multi-node wire
-- protocol coverage instead) ---

check("modem open/broadcast don't error (single-node smoke test only)", function()
  local modemAddr = component.list("modem")()
  if not modemAddr then return "skipped -- no modem/network card present" end
  component.invoke(modemAddr, "open", 4477)
  component.invoke(modemAddr, "broadcast", 4477, "hw_test_broadcast")
  return "ok -- open/broadcast did not error (does NOT confirm a peer actually received it)"
end)

-- --- Reporter: write results to a gpu+screen if present, else just beep. ---

local function report()
  local gpuAddr = component.list("gpu")()
  local screenAddr = component.list("screen")()
  local failCount = 0
  for _, r in ipairs(results) do
    if not r.ok then failCount = failCount + 1 end
  end

  if gpuAddr then
    if screenAddr then pcall(component.invoke, gpuAddr, "bind", screenAddr) end
    local w, h = component.invoke(gpuAddr, "getResolution")
    local row = 1
    local function writeLine(text)
      if row > h then
        component.invoke(gpuAddr, "copy", 1, 2, w, h - 1, 0, -1)
        component.invoke(gpuAddr, "fill", 1, h, w, 1, " ")
        row = h
      end
      component.invoke(gpuAddr, "set", 1, row, text:sub(1, w))
      row = row + 1
    end
    writeLine("muxos hardware verification -- " .. #results .. " checks, " .. failCount .. " failed")
    for _, r in ipairs(results) do
      writeLine((r.ok and "PASS " or "FAIL ") .. r.name)
      writeLine("  " .. tostring(r.detail))
    end
  end

  if failCount == 0 then
    computer.beep(1500, 0.15)
    computer.beep(2000, 0.15)
  else
    computer.beep(400, 0.4)
    computer.beep(400, 0.4)
  end
end

report()
