-- Worker runtime for huh2. NOT flashed anywhere -- this lives on the
-- KERNAL's filesystem (as a sibling file of kernal/muxos.lua) and gets
-- served, as plain source text, to each worker over the modem at boot
-- (node/bios.lua, the actual EEPROM image, is just the tiny stub that
-- fetches this and `load()`s it into RAM). There is still no disk and no
-- `require` on the worker -- this file runs in the exact same bare
-- environment bios.lua used to run in directly, just arriving over the
-- network instead of baked into the EEPROM, so it isn't bound by the
-- EEPROM's 4096-byte eepromSize limit.
--
-- Wire format: see docs/PROTOCOL.md. The serializer below is duplicated in
-- kernal/muxos.lua on purpose -- this file can't `require` anything any
-- more than bios.lua could, so both sides keep their own copy in sync by
-- hand.

local PORT = 4477

local function serialize(v, seen)
  seen = seen or {}
  local t = type(v)
  if t == "nil" or t == "boolean" or t == "number" then
    return tostring(v)
  elseif t == "string" then
    return string.format("%q", v)
  elseif t == "table" then
    if seen[v] then error("cannot serialize a cyclic table") end
    seen[v] = true
    local parts = {}
    for k, val in pairs(v) do
      parts[#parts + 1] = "[" .. serialize(k, seen) .. "]=" .. serialize(val, seen)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  else
    error("cannot serialize a value of type " .. t)
  end
end

local function deserialize(s)
  local chunk = load("return " .. s, "=msg", "t", {})
  if not chunk then return nil end
  local ok, v = pcall(chunk)
  if not ok then return nil end
  return v
end

local function findModem()
  for addr in component.list("modem") do
    return component.proxy(addr)
  end
end

local modem = findModem()
if not modem then
  -- No network/wireless card present -- there is no way to receive jobs.
  -- Beep and halt rather than spin silently.
  computer.beep(200, 0.5)
  while true do computer.pullSignal() end
end

modem.open(PORT)

local nodeId = computer.address()

local function send(msg)
  modem.broadcast(PORT, serialize(msg))
end

-- Announce ourselves so the kernal can pick us up without a separate
-- discovery pass if it happens to be listening already.
send({type = "HELLO", from = nodeId})

-- The kernal is whoever directly addresses us -- nothing else on this
-- network talks to a worker node. Learned on the first message received,
-- used by the "face" helpers below to call back into the kernal's own
-- hardware when this node has none of its own.
local kernalAddr = nil

local nextRpcId = 1
local function nextId()
  local id = nextRpcId
  nextRpcId = nextRpcId + 1
  return id
end

local RPC_TIMEOUT = 5

-- Ask the kernal to LIST or INVOKE one of ITS OWN components -- the
-- reverse direction of the LIST/INVOKE handling below. Used when this
-- node needs a resource it doesn't have locally (no screen of its own,
-- say) and falls back to the kernal's hardware instead, at the cost of
-- one network round trip instead of zero.
local function remoteRequest(msgType, extra)
  if not kernalAddr then
    return nil, "kernal address not known yet"
  end
  local id = nextId()
  local msg = {type = msgType, from = nodeId, to = kernalAddr, id = id}
  for k, v in pairs(extra or {}) do msg[k] = v end
  send(msg)

  local deadline = computer.uptime() + RPC_TIMEOUT
  while computer.uptime() < deadline do
    local name, _, _, port, _, data = computer.pullSignal(deadline - computer.uptime())
    if name == "modem_message" and port == PORT and type(data) == "string" then
      local reply = deserialize(data)
      if type(reply) == "table" and reply.id == id and reply.to == nodeId then
        if reply.type == "RESULT" then
          return reply.result
        elseif reply.type == "ERROR" then
          return nil, reply.error
        end
      end
    end
  end
  return nil, "timed out waiting for kernal"
end

local function remoteList()
  return remoteRequest("LIST")
end

local function remoteInvoke(address, method, args)
  return remoteRequest("INVOKE", {address = address, method = method, args = args})
end

-- Lowest-overhead rule: use a local component if this node happens to
-- have one, zero network hops; only fall back to the kernal's when this
-- node has none. Cached after the first remote lookup so repeated calls
-- don't pay for a LIST round trip every time.
local remoteGpuAddr = nil
local function faceGpu(method, ...)
  for addr in component.list("gpu") do
    return component.invoke(addr, method, ...)
  end
  if not remoteGpuAddr then
    local list, err = remoteList()
    if not list then return nil, err end
    for addr, ctype in pairs(list) do
      if ctype == "gpu" then
        remoteGpuAddr = addr
        break
      end
    end
    if not remoteGpuAddr then return nil, "kernal has no gpu component" end
  end
  local results, err = remoteInvoke(remoteGpuAddr, method, {...})
  if err then return nil, err end
  return table.unpack(results or {})
end

-- Exposed as a real global (not `local`) so JOB code -- loaded fresh via
-- `load()` each time, with no visibility into this file's own locals --
-- can still call it as `gpu.set(x, y, text)`, same shape as OpenOS's own
-- component.gpu proxy, without caring whether it ends up local or remote.
gpu = setmetatable({}, {
  __index = function(_, method)
    return function(...) return faceGpu(method, ...) end
  end,
})

-- Muxos-shaped gmux application API. Every one of these is necessarily
-- a remote call to the kernal, never local-first like `gpu` -- a
-- "process" is a job on some other physical node and a "window" lives on
-- the kernal's own real screen, so no worker could ever answer either
-- from its own state. See docs/PROTOCOL.md for what's deliberately
-- different from gmux's real api.lua and why.
gmuxapi = {
  -- gmux's api.get_processes() reads one local process table; here the
  -- kernal's own scheduler (kernal/muxos.lua's `jobs`) is the only thing
  -- that actually knows about every job across every node.
  get_processes = function()
    return remoteRequest("GETPROCESSES")
  end,

  -- gmux's create_headless_process(options) takes options.main (a
  -- function) or options.main_path (a dofile path); neither can cross
  -- the network, so this takes options.code (a Lua source string, same
  -- convention as a JOB) instead. Fire-and-forget, like gmux's own
  -- version: returns {process = {id, node}} immediately, not the result.
  create_headless_process = function(options)
    options = options or {}
    if not options.code then
      return nil, "create_headless_process needs options.code (a Lua source string)"
    end
    local result, err = remoteRequest("SPAWN", {code = options.code, args = options.args, node = options.node})
    if err then return nil, err end
    return {process = result}
  end,

  -- gmux's create_graphics_process additionally wires the spawned job's
  -- own gpu/screen/keyboard to a private virtual surface. That per-job
  -- isolated drawing surface doesn't exist here yet -- this spawns the
  -- job and creates a window of the requested size, but the job's own
  -- `gpu` face still targets the kernal's PRIMARY screen directly, not
  -- this window's buffer. Flagged, not silently pretended to work.
  create_graphics_process = function(options)
    options = options or {}
    if not options.code then
      return nil, "create_graphics_process needs options.code (a Lua source string)"
    end
    local proc, procErr = remoteRequest("SPAWN", {code = options.code, args = options.args, node = options.node})
    if not proc then return nil, procErr end
    local win, winErr = remoteRequest("CREATEWINDOW", {
      title = options.name, width = options.width, height = options.height,
    })
    if not win then return {process = proc}, winErr end
    return {process = proc, window = win}
  end,

  -- Also stands in for gmux's separate create_window_buffer: gmux draws
  -- into a window via a `func(gpu)` callback, a function value that
  -- can't cross the network; options.code (run ON the kernal, with
  -- `gpu` bound to the real gpu already pointed at this window's
  -- buffer) replaces it. Not live -- unlike gmux's create_window with a
  -- vgpu/vscreen source, this never redraws on its own.
  create_window = function(options)
    options = options or {}
    return remoteRequest("CREATEWINDOW", {
      title = options.title, x = options.x, y = options.y,
      width = options.width, height = options.height, code = options.code,
    })
  end,

  get_windows = function()
    return remoteRequest("GETWINDOWS")
  end,
}

while true do
  local name, _, from, port, _, data = computer.pullSignal()
  if name == "modem_message" and port == PORT and type(data) == "string" then
    local msg = deserialize(data)
    if type(msg) == "table" and (msg.to == nil or msg.to == nodeId) then
      kernalAddr = msg.from
      if msg.type == "PING" then
        send({type = "PONG", from = nodeId, to = msg.from, id = msg.id})
      elseif msg.type == "JOB" then
        local chunk, loadErr = load("local args = ...\n" .. msg.code, "=job", "t")
        if not chunk then
          send({type = "ERROR", from = nodeId, to = msg.from, id = msg.id, error = loadErr})
        else
          local ok, result = pcall(chunk, msg.args)
          if ok then
            send({type = "RESULT", from = nodeId, to = msg.from, id = msg.id, result = result})
          else
            send({type = "ERROR", from = nodeId, to = msg.from, id = msg.id, error = tostring(result)})
          end
        end
      elseif msg.type == "LIST" then
        -- Expose this node's own components to the kernal, so it can
        -- address them without us having to write custom JOB code for it.
        local list = {}
        for addr, ctype in component.list() do
          list[addr] = ctype
        end
        send({type = "RESULT", from = nodeId, to = msg.from, id = msg.id, result = list})
      elseif msg.type == "INVOKE" then
        -- Call a method on one of this node's own components on the
        -- kernal's behalf -- this is the "remote component" bridge:
        -- addressed like a local component.invoke(), but carried over the
        -- modem instead of being a direct in-process call.
        local packed = table.pack(pcall(component.invoke, msg.address, msg.method, table.unpack(msg.args or {})))
        if packed[1] then
          local returns = {}
          for i = 2, packed.n do returns[#returns + 1] = packed[i] end
          send({type = "RESULT", from = nodeId, to = msg.from, id = msg.id, result = returns})
        else
          send({type = "ERROR", from = nodeId, to = msg.from, id = msg.id, error = tostring(packed[2])})
        end
      end
    end
  end
end
