-- muxos terminal server: network terminals (muxterm, an OpenOS program)
-- log in to muxos over the network, each in a session of its own -- the
-- same kind of session as the kernal's own screen, drawn with a
-- kernal/vgpu.lua GPU instead of the real one.
--
-- Loaded by kernal/muxos.lua:
--   loadSibling("terminals.lua")(K, {modem, serialize, deserialize, vgpu})
--
-- The protocol: raw modem messages on the terminal port (flag
-- terminal_port, 4478 by default; not the cluster's 4477), each one
-- serialized table with a type `t`:
--   terminal -> kernal
--     {t = "hello", w, h, depth}   start a session (broadcast, or sent to
--                                  a kernal's address); again restarts it
--     {t = "in", e = {name, ...}}  input: an OpenComputers signal name and
--                                  its arguments after the address
--                                  (key_down/key_up char code, touch/drag/
--                                  drop x y button, scroll x y direction,
--                                  clipboard text)
--     {t = "ping"}                 I'm still here (every 2 s)
--     {t = "bye"}                  hanging up
--   kernal -> terminal
--     {t = "welcome", kernal, session, w, h}
--     {t = "draw", r = {{x, y, text, fg, bg}, ...}}  screen changes
--     {t = "ping"}                 when there's been nothing else for 2 s
--     {t = "bye", why}             the session is over
-- A terminal that says nothing for 10 s is hung up on: its session ends
-- as a logout does.
local K, deps = ...
local system, modem, serialize, deserialize, vgpu = K.system, deps.modem, deps.serialize, deps.deserialize, deps.vgpu

local T = {byAddress = {}}
local PORT = system.flag("terminal_port")
local QUIET, SILENT = 2, 10
local INPUT = {key_down = true, key_up = true, scroll = true, clipboard = true, touch = true, drag = true, drop = true}
local MAX_MESSAGE = math.min(6000, ((modem.maxPacketSize and modem.maxPacketSize()) or 8192) - 512)

T.PORT = PORT
if system.flag("remote_terminals") then modem.open(PORT) end

local function send(address, msg)
  modem.send(address, PORT, serialize(msg))
end

-- A terminal's screen changes, after its session drew: as few messages
-- as fit them.
local function flushed(S)
  local term = S.terminal
  if not term then return end
  local now = computer.uptime()
  local runs = term.gpu.takeDamage(term.full)
  term.full = false
  local batch, size = {}, 0
  local function ship()
    if #batch == 0 then return end
    send(term.address, {t = "draw", r = batch})
    batch, size, term.lastSent = {}, 0, now
  end
  for _, run in ipairs(runs) do
    local cost = #run[3] + 40
    if size + cost > MAX_MESSAGE then ship() end
    batch[#batch + 1] = run
    size = size + cost
  end
  ship()
  if now - term.lastSent > QUIET then
    send(term.address, {t = "ping"})
    term.lastSent = now
  end
end

local function hangUp(term, why)
  T.byAddress[term.address] = nil
  K.endSession(term.session)
  send(term.address, {t = "bye", why = why})
end

local function clamp(n, lo, hi, default)
  n = math.tointeger(tonumber(n))
  if not n then return default end
  return math.max(lo, math.min(hi, n))
end

local function hello(address, msg)
  if not system.flag("remote_terminals") then
    send(address, {t = "bye", why = "this muxos doesn't take terminals (flag remote_terminals)"})
    return
  end
  local old = T.byAddress[address]
  if old then hangUp(old, "restarted") end
  local w, h = clamp(msg.w, 20, 160, 80), clamp(msg.h, 8, 50, 25)
  local depth = ({[1] = 1, [4] = 4, [8] = 8})[tonumber(msg.depth)] or 8
  local gpu = vgpu.new(w, h, depth)
  local S = K.newSession({gpu = gpu, kind = "terminal", address = address, flushed = flushed})
  local now = computer.uptime()
  local term = {address = address, session = S, gpu = gpu, lastSeen = now, lastSent = now, full = true}
  S.terminal = term
  T.byAddress[address] = term
  send(address, {t = "welcome", kernal = K.selfAddr, session = S.id, w = w, h = h})
  K.inSession(S, S.showLogin)
end

-- A message on the terminal port.
function T.message(from, port, data)
  if port ~= PORT or type(data) ~= "string" then return end
  local msg = deserialize(data)
  if type(msg) ~= "table" then return end
  local term = T.byAddress[from]
  if msg.t == "hello" then
    hello(from, msg)
  elseif not term then
    if msg.t ~= "bye" then send(from, {t = "bye", why = "no session here -- start one with hello"}) end
  elseif msg.t == "bye" then
    T.byAddress[from] = nil
    K.endSession(term.session)
  else
    term.lastSeen = computer.uptime()
    local e = msg.e
    if msg.t == "in" and type(e) == "table" and INPUT[e[1]] then
      for i = 2, 4 do
        if e[i] ~= nil and type(e[i]) ~= "number" and type(e[i]) ~= "string" then return end
      end
      K.inSession(term.session, term.session.input, e[1], e[2], e[3], e[4])
    end
  end
end

-- Hangs up on terminals that have gone quiet.
function T.sweep()
  local now = computer.uptime()
  for _, term in pairs(T.byAddress) do
    if now - term.lastSeen > SILENT then hangUp(term, "the terminal stopped answering") end
  end
end

function T.list()
  local list = {}
  for _, term in pairs(T.byAddress) do list[#list + 1] = term end
  return list
end

return T
