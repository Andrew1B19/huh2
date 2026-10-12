-- muxterm: a network terminal for muxos, for any OpenOS computer with a
-- screen, a keyboard and a network card on the muxos cluster's network.
-- It shows a muxos session -- its own login, console, desktop and
-- windows -- and sends the keyboard and touches back.
--
--   muxterm [kernal address] [port]
--
-- Without an address it finds the kernal by broadcasting. The port is
-- muxos's terminal port (its terminal_port flag; 4478 by default).
-- Ctrl+Alt+D disconnects (logging out). Every other key, Ctrl+Alt+C
-- included, goes to muxos.
--
-- The protocol is in muxos's kernal/terminals.lua.
local component = require("component")
local computer = require("computer")
local event = require("event")
local term = require("term")

local args = {...}
local kernal = args[1]
local PORT = tonumber(args[2]) or 4478

if not component.isAvailable("modem") then io.stderr:write("muxterm: this computer has no network card\n") return 1 end
if not component.isAvailable("gpu") then io.stderr:write("muxterm: this computer has no graphics card\n") return 1 end
local modem, gpu = component.modem, component.gpu
local screenAddress = gpu.getScreen()
local keyboards = {}
for _, k in ipairs(screenAddress and component.invoke(screenAddress, "getKeyboards") or {}) do keyboards[k] = true end
local function ours(address) return address == screenAddress or keyboards[address] end

-- Messages are plain Lua tables, written the kernal's way.
local function serialize(v)
  local t = type(v)
  if t == "number" then
    return math.type(v) == "integer" and tostring(v) or string.format("%.17g", v)
  elseif t == "string" then
    return (string.format("%q", v):gsub("\\\n", "\\n"))
  elseif t == "boolean" then
    return tostring(v)
  elseif t == "table" then
    local parts = {}
    for k, x in pairs(v) do
      if type(k) == "string" or type(k) == "number" then
        parts[#parts + 1] = "[" .. serialize(k) .. "]=" .. serialize(x)
      end
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "nil"
end
local function deserialize(s)
  local chunk = load("return " .. s, "=muxos", "t", {})
  if not chunk then return nil end
  local ok, v = pcall(chunk)
  return ok and v or nil
end

local function send(msg)
  if kernal then modem.send(kernal, PORT, serialize(msg)) else modem.broadcast(PORT, serialize(msg)) end
end

local wasOpen = modem.isOpen(PORT)
if not wasOpen and not modem.open(PORT) then io.stderr:write("muxterm: can't open port " .. PORT .. "\n") return 1 end

-- Ctrl+Alt+C is muxos's: OpenOS mustn't end this program over it (its
-- event library signals the running process).
local processData = require("process").info().data
local signal = processData.signal
processData.signal = function() end

local oldW, oldH = gpu.getResolution()
local w, h = oldW, oldH
local fg, bg = gpu.getForeground(), gpu.getBackground()

local function restore(message)
  processData.signal = signal
  if not wasOpen then modem.close(PORT) end
  gpu.setForeground(fg)
  gpu.setBackground(bg)
  term.clear()
  if message then print(message) end
end

-- Connecting: hello until a kernal welcomes us.
print("muxterm: connecting to " .. (kernal or "the muxos kernal on this network") .. " on port " .. PORT .. "...")
local welcome
local giveUp = computer.uptime() + 10
local nextHello = 0
while not welcome and computer.uptime() < giveUp do
  if computer.uptime() >= nextHello then
    send({t = "hello", w = w, h = h, depth = gpu.getDepth()})
    nextHello = computer.uptime() + 2
  end
  local e = {event.pull(0.5)}
  if e[1] == "modem_message" and e[4] == PORT and (not kernal or e[3] == kernal) then
    local msg = deserialize(tostring(e[6]))
    if type(msg) == "table" and msg.t == "welcome" then
      welcome, kernal = msg, e[3]
    elseif type(msg) == "table" and msg.t == "bye" then
      restore("muxterm: " .. tostring(msg.why))
      return 1
    end
  elseif e[1] == "key_down" and ours(e[2]) and e[4] == 0x20 and require("keyboard").isControlDown()
      and require("keyboard").isAltDown() then
    restore("muxterm: cancelled")
    return 1
  end
end
if not welcome then
  restore("muxterm: no muxos kernal answered (is it on this network, with flag remote_terminals on?)")
  return 1
end

gpu.setBackground(0x000000)
gpu.fill(1, 1, w, h, " ")

local lastHeard, lastSent = computer.uptime(), computer.uptime()
local held = {}
local function draw(runs)
  local cf, cb
  for _, run in ipairs(runs) do
    local x, y, text, f, b = run[1], run[2], run[3], run[4], run[5]
    if type(x) == "number" and type(y) == "number" and type(text) == "string" then
      if f ~= cf then gpu.setForeground(f) cf = f end
      if b ~= cb then gpu.setBackground(b) cb = b end
      gpu.set(x, y, text)
    end
  end
end

local INPUT = {key_down = true, key_up = true, scroll = true, clipboard = true, touch = true, drag = true, drop = true}
local reason
while true do
  local e = {event.pull(0.5)}
  local now = computer.uptime()
  if e[1] == "modem_message" and e[3] == kernal and e[4] == PORT then
    lastHeard = now
    local msg = deserialize(tostring(e[6]))
    if type(msg) == "table" then
      if msg.t == "draw" and type(msg.r) == "table" then
        draw(msg.r)
      elseif msg.t == "bye" then
        reason = "muxterm: disconnected -- " .. tostring(msg.why)
        break
      end
    end
  elseif INPUT[e[1]] and ours(e[2]) then
    if e[1] == "key_down" then held[e[4]] = true elseif e[1] == "key_up" then held[e[4]] = nil end
    -- Ctrl+Alt+D: hang up.
    if e[1] == "key_down" and e[4] == 0x20 and (held[0x1D] or held[0x9D]) and (held[0x38] or held[0xB8]) then
      send({t = "bye"})
      reason = "muxterm: disconnected"
      break
    end
    send({t = "in", e = {e[1], e[3], e[4], e[5]}})
    lastSent = now
  end
  if now - lastSent > 2 then
    send({t = "ping"})
    lastSent = now
  end
  if now - lastHeard > 10 then
    reason = "muxterm: lost the kernal (nothing heard for 10 s)"
    break
  end
end
restore(reason)
