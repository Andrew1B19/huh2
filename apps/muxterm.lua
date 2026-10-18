-- muxterm: a network terminal for munix, for any OpenOS computer with a
-- screen, a keyboard and a network card on the munix cluster's network.
-- You get a munix session of your own on this screen -- login, console,
-- desktop, taskbar, windows -- composited here, on this computer's GPU;
-- programs you run draw their windows straight to it.
--
--   muxterm [kernal address] [port]
--
-- Without an address it finds the kernal by broadcasting. The port is
-- munix's terminal port (its terminal_port flag; 4478 by default).
-- Ctrl+Alt+D disconnects (logging out). Every other key, Ctrl+Alt+C
-- included, goes to munix.
--
-- This is only the bootstrap: it fetches the terminal's code from the
-- kernal (kernal/terminal.lua, with the session, compositor and encoder
-- it runs), so a terminal always runs its kernal's own version.
local component = require("component")
local computer = require("computer")
local term = require("term")

local args = {...}
local kernal = args[1]
local PORT = tonumber(args[2]) or 4478

if not component.isAvailable("modem") then io.stderr:write("muxterm: this computer has no network card\n") return 1 end
if not component.isAvailable("gpu") then io.stderr:write("muxterm: this computer has no graphics card\n") return 1 end
local modem, gpu = component.modem, component.gpu
local keyboards = {}
local screen = gpu.getScreen()
for _, k in ipairs(screen and component.invoke(screen, "getKeyboards") or {}) do keyboards[k] = true end

local wasOpen = modem.isOpen(PORT)
if not wasOpen and not modem.open(PORT) then io.stderr:write("muxterm: can't open port " .. PORT .. "\n") return 1 end

-- Ctrl+Alt+C is munix's: OpenOS mustn't end this program over it (its
-- event library signals the running process).
local processData = require("process").info().data
local signal = processData.signal
processData.signal = function() end

local fg, bg = gpu.getForeground(), gpu.getBackground()
local function restore(message)
  processData.signal = signal
  if not wasOpen then modem.close(PORT) end
  gpu.setForeground(fg)
  gpu.setBackground(bg)
  term.clear()
  if message then print(message) end
end

-- The kernal's messages are framed "MSG <id> <i>/<n> <part>", their
-- payload a Lua table constructor.
local function frame(msg) return "MSG 1 1/1 " .. msg end
local function hello()
  local msg = '{["type"]="TERMHELLO",["from"]=' .. string.format("%q", modem.address)
    .. (kernal and (',["to"]=' .. string.format("%q", kernal)) or "") .. "}"
  if kernal then modem.send(kernal, PORT, frame(msg)) else modem.broadcast(PORT, frame(msg)) end
end

print("muxterm: connecting to " .. (kernal or "the munix kernal on this network") .. " on port " .. PORT .. "...")
local parts, code = {}, nil
local giveUp, nextHello = computer.uptime() + 15, 0
while not code and computer.uptime() < giveUp do
  if computer.uptime() >= nextHello then
    hello()
    nextHello = computer.uptime() + 3
  end
  local name, _, from, port, _, data = computer.pullSignal(0.5)
  if name == "modem_message" and port == PORT and type(data) == "string" and (not kernal or from == kernal) then
    local id, i, n, part = data:match("^MSG (%d+) (%d+)/(%d+) (.*)$")
    if id then
      local set = parts[from .. ":" .. id] or {}
      parts[from .. ":" .. id] = set
      set[tonumber(i)] = part
      local all = true
      for j = 1, tonumber(n) do if not set[j] then all = false break end end
      if all then
        local ok, msg = pcall(load("return " .. table.concat(set, "", 1, tonumber(n)), "=kernal", "t", {}))
        if ok and type(msg) == "table" and msg.type == "TCODE" then
          code, kernal = msg, from
        elseif ok and type(msg) == "table" and msg.type == "TBYE" then
          restore("muxterm: " .. tostring(msg.why))
          return 1
        end
      end
    end
  elseif name == "key_down" and keyboards[_] then
    -- (nothing to do before connecting)
  end
end
if not code then
  restore("muxterm: no munix kernal answered (is it on this network, with flag remote_terminals on?)")
  return 1
end

-- OpenOS takes component, computer and unicode out of the globals; the
-- terminal's code (written for bare metal, like the kernal) expects them.
local env = setmetatable({component = component, computer = computer, unicode = require("unicode")},
  {__index = _G})
local chunk, err = load(code.files["terminal.lua"] or "", "=terminal.lua", "t", env)
if not chunk then
  restore("muxterm: the kernal's terminal code doesn't load: " .. tostring(err))
  return 1
end
local ok, why = pcall(chunk, {kernal = kernal, port = PORT, files = code.files, version = code.version,
  modem = modem.address, gpu = gpu.address, keyboards = keyboards})
restore("muxterm: " .. (ok and tostring(why or "disconnected") or ("crashed: " .. tostring(why))))
return ok and 0 or 1
