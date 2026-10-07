-- Hardware verification suite for muxos: run it on REAL OpenComputers
-- hardware to confirm the sandbox behavior muxos depends on. Every
-- check here also runs in test/emu's emulator, which boots the mod's own
-- machine.lua -- so a difference between the two is exactly what this
-- is for.
--
-- It's larger than an EEPROM, so it runs from a disk: flash
-- test/hardware/bios.lua to an EEPROM, put this file on a filesystem as
-- /verify.lua, and boot with no OpenOS.
--
-- Each check is self-contained and pcall-wrapped, so one failing check
-- can't take down the rest. Results go to a gpu+screen if present, and
-- a beep pattern (high = all passed, low = something failed).

local results = {}

local function check(name, fn)
  local ok, detail = pcall(fn)
  results[#results + 1] = {name = name, ok = ok, detail = detail}
end

-- --- 1. The API surface muxos uses ---

check("component and computer APIs muxos uses exist", function()
  for _, name in ipairs({"list", "invoke", "type"}) do
    assert(type(component[name]) == "function", "no component." .. name)
  end
  for _, name in ipairs({"address", "uptime", "beep", "pushSignal", "pullSignal", "shutdown"}) do
    assert(type(computer[name]) == "function", "no computer." .. name)
  end
  return computer.address()
end)

check("Lua 5.3 library profile (utf8, math.type)", function()
  assert(type(utf8) == "table" and type(utf8.char) == "function", "no utf8 -- kernal/bitmap.lua needs it")
  assert(type(math.type) == "function", "no math.type -- the wire serializer needs it")
  return _VERSION
end)

-- --- 2. Waiting: computer.pullSignal is the real primitive ---

check("computer.pullSignal(timeout) returns after the timeout with no signal", function()
  while computer.pullSignal(0) do end -- drain
  local start = computer.uptime()
  local name = computer.pullSignal(1)
  local waited = computer.uptime() - start
  assert(name == nil, "got a signal: " .. tostring(name))
  assert(waited >= 0.9, "returned after only " .. waited .. "s")
  return string.format("waited %.2fs", waited)
end)

check("computer.pushSignal round-trips through computer.pullSignal", function()
  computer.pushSignal("muxos_verify", 42)
  local name, value = computer.pullSignal(1)
  assert(name == "muxos_verify" and value == 42, "got " .. tostring(name) .. ", " .. tostring(value))
  return "ok"
end)

-- --- 3. Coroutines: the job model ---

check("a nested coroutine's yield comes back to its resumer (the job model)", function()
  local co = coroutine.create(function() local v = coroutine.yield(0.5) return v end)
  local ok, yielded = coroutine.resume(co)
  assert(ok and yielded == 0.5, "first resume: " .. tostring(ok) .. ", " .. tostring(yielded))
  local ok2, result = coroutine.resume(co, "back")
  assert(ok2 and result == "back", "second resume: " .. tostring(ok2) .. ", " .. tostring(result))
  return "ok"
end)

check("a coroutine that never yields is ended by the deadline, not the machine", function()
  local co = coroutine.create(function() while true do end end)
  local ok, err = coroutine.resume(co)
  computer.pullSignal(0) -- yield to the machine promptly afterwards, as muxos does
  assert(not ok, "the runaway coroutine was not stopped")
  assert(tostring(err):find("too long without yielding", 1, true), "unexpected error: " .. tostring(err))
  return "ok -- " .. tostring(err)
end)

-- --- 4. What muxos does NOT depend on (informational) ---

check("debug.sethook / eris availability (informational)", function()
  return "debug.sethook: " .. (debug and debug.sethook and "present" or "absent") ..
    ", eris: " .. (eris and "present" or "absent") ..
    " -- muxos uses neither; semi-live migration can't be built on eris unless it's present"
end)

-- --- 5. GPU/screen smoke test (only if present -- see the reporter
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

-- --- 6. Modem smoke test (open/broadcast don't error -- a real
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

-- Keep the results on screen.
while true do computer.pullSignal() end
