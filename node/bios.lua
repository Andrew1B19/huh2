-- Minimal network-boot stub for huh2 worker nodes. This is the ENTIRE
-- thing flashed onto a worker's EEPROM -- everything else (job
-- execution, the remote-component bridge, the gpu face, ...) lives in
-- node/runtime.lua, served by the kernal over the modem, so the EEPROM
-- stays tiny regardless of how large the real runtime grows (EEPROMs
-- have a real, confirmed 4096-byte code limit -- see docs/PROTOCOL.md).
--
-- There is deliberately no local fallback: the kernal is the
-- authoritative source for what a worker runs, so if it isn't up yet,
-- this just keeps waiting for it rather than doing anything on its own.

local PORT = 4477

local function findModem()
  for addr in component.list("modem") do
    return component.proxy(addr)
  end
end

local modem = findModem()
if not modem then
  -- No network/wireless card present -- there is no way to reach the
  -- kernal at all. Beep and halt rather than spin silently.
  computer.beep(200, 0.5)
  while true do computer.pullSignal() end
end

modem.open(PORT)

local nodeId = computer.address()

-- The real wire protocol (docs/PROTOCOL.md) uses a serialized Lua table
-- per message, but that serializer is itself part of the runtime we
-- haven't fetched yet, so boot uses its own tiny, separate convention:
-- a type word, a space, then a payload that runs to the end of the
-- message -- "BOOT <node address>" from us, "CODE <i>/<n> <chunk>" back
-- (chunked because the runtime can exceed one modem message's
-- maxNetworkPacketSize -- see docs/PROTOCOL.md). Lua's `.` matches
-- newlines too, so this is safe even though a chunk spans many lines.
local function requestBoot()
  modem.broadcast(PORT, "BOOT " .. nodeId)
end

requestBoot()

local chunks = {}
local code
while not code do
  local name, _, _, port, _, data = computer.pullSignal(5)
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
      end
    end
  end
  if not code and not gotChunk then
    -- Nothing relevant arrived within the timeout -- the kernal may not
    -- be up yet, or this is a fresh wait with no transfer in progress.
    -- Re-announce rather than waiting silently. (Deliberately NOT
    -- re-announced on every single received chunk -- that would restart
    -- the kernal's whole chunked send on every reply.)
    requestBoot()
  end
end

local chunk, err = load(code, "=runtime")
if not chunk then
  computer.beep(1000, 0.3)
  error(err)
end
chunk()
