-- Network-boot stub for huh2 worker nodes: the ENTIRE worker EEPROM.
-- Everything else lives in node/runtime.lua, served by the kernal over
-- the modem, so this stays under the EEPROM's 4096-byte limit (checked
-- by test/emu/integration_test.lua -- comments count toward it too).
-- No local fallback: if the kernal isn't up yet, keep asking.

local PORT = 4477

-- The sandbox's computer.pullSignal yields to the machine; a bare
-- coroutine.yield(timeout) wouldn't (the sandbox wraps it as a user
-- yield and the timeout is lost).
local function pullSignal(timeout)
  return computer.pullSignal(timeout)
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
-- Re-announce only after 5 s with no chunk -- on a timer, never in
-- reaction to other traffic. (Reacting to any message made workers set
-- each other off: every BOOT broadcast woke the others into sending
-- theirs, a storm that flooded every computer on the network.)
local quietSince = computer.uptime()
while not code do
  local name, _, from, port, _, data = pullSignal(math.max(0, quietSince + 5 - computer.uptime()))
  if name == "modem_message" and port == PORT and type(data) == "string" then
    local i, n, chunk = data:match("^CODE (%d+)/(%d+) (.*)$")
    if i then
      quietSince = computer.uptime()
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
  if not code and computer.uptime() >= quietSince + 5 then
    requestBoot()
    quietSince = computer.uptime()
  end
end

local chunk, err = load(code, "=runtime")
if not chunk then
  computer.beep(1000, 0.3)
  error(err)
end
chunk(kernalAddr)
