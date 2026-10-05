-- Network-boot stub for huh2 worker nodes: the ENTIRE worker EEPROM.
-- Everything else lives in node/runtime.lua, served by the kernal over
-- the modem, so this stays under the EEPROM's 4096-byte limit (checked
-- by test/emu/integration_test.lua -- comments count toward it too).
-- No local fallback: if the kernal isn't up yet, keep asking.

local PORT = 4477

-- There is no computer.pullSignal in the EEPROM sandbox (that's OpenOS);
-- the real primitive is yielding the kernel coroutine with a timeout.
local function pullSignal(timeout)
  return coroutine.yield(timeout)
end

local function findModem()
  for addr in component.list("modem") do
    return addr
  end
end

local modemAddr = findModem()
if not modemAddr then
  -- No network card: no way to reach the kernal. Beep and halt.
  computer.beep(200, 0.5)
  while true do pullSignal() end
end

component.invoke(modemAddr, "open", PORT)

-- Boot uses its own tiny convention (the table serializer is part of
-- the runtime we haven't fetched yet): "BOOT <card address>" from us,
-- "CODE <i>/<n> <chunk>" back, chunked to fit the modem's packet size.
-- Lua's `.` matches newlines, so a chunk spanning lines is fine.
local function requestBoot()
  component.invoke(modemAddr, "broadcast", PORT, "BOOT " .. modemAddr)
end

requestBoot()

local chunks = {}
local code
-- The card whose chunks complete the runtime is the kernal. This is
-- the only place a worker learns that; runtime.lua treats it as
-- authoritative from then on (see its header).
local kernalAddr
while not code do
  local name, _, from, port, _, data = pullSignal(5)
  local gotChunk = false
  if name == "modem_message" and port == PORT and type(data) == "string" then
    local i, n, chunk = data:match("^CODE (%d+)/(%d+) (.*)$")
    if i then
      gotChunk = true
      i, n = tonumber(i), tonumber(n)
      chunks[i] = chunk
      local haveAll = true
      for j = 1, n do
        if not chunks[j] then haveAll = false break end
      end
      if haveAll then
        code = table.concat(chunks, "", 1, n)
        kernalAddr = from
      end
    end
  end
  if not code and not gotChunk then
    -- Nothing arrived: re-announce. Not on every chunk, which would
    -- restart the kernal's whole chunked send each time.
    requestBoot()
  end
end

local chunk, err = load(code, "=runtime")
if not chunk then
  computer.beep(1000, 0.3)
  error(err)
end
chunk(kernalAddr)
