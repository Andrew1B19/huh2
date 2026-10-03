-- Arbiter program for huh2. Runs under a normal OpenOS boot on the main
-- rack node (own CPU/RAM/EEPROM/HDD, same as any OC computer). Discovers
-- worker nodes flashed with node/bios.lua over the rack's shared network
-- segment and dispatches Lua jobs to them.
--
-- Install: copy onto the arbiter's filesystem (e.g. /home/rackos.lua) and
-- run it from the OpenOS shell.
--
-- Wire format: see docs/PROTOCOL.md. The serializer below is a deliberate
-- duplicate of the one in node/bios.lua, not a shared dependency -- EEPROM
-- firmware can't `require` anything, so keeping both sides self-contained
-- avoids a split-brain "shared lib" that only one side can actually load.

local component = require("component")
local event = require("event")
local computer = require("computer")

local PORT = 4477
local TIMEOUT = 5 -- seconds to wait for a worker reply before giving up

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

if not component.isAvailable("modem") then
  error("no network/linked card found on this node")
end
local modem = component.modem
modem.open(PORT)

local selfAddr = computer.address()
local nodes = {}      -- address -> {lastSeen = computer.uptime()}
local nodeOrder = {}  -- address list, stable iteration/round-robin order
local nextJobId = 1
local nextNode = 1

local function send(msg)
  modem.broadcast(PORT, serialize(msg))
end

local function noteNode(addr)
  if not nodes[addr] then
    nodes[addr] = {}
    nodeOrder[#nodeOrder + 1] = addr
  end
  nodes[addr].lastSeen = computer.uptime()
end

-- Pull one pending modem message, if any, without blocking. Used both by
-- discovery and by submit()'s wait loop.
local function pump()
  local name, _, from, port, _, data = event.pull(0, "modem_message")
  if name and port == PORT and type(data) == "string" then
    local msg = deserialize(data)
    if type(msg) == "table" and msg.from and msg.from ~= selfAddr then
      if msg.type == "HELLO" or msg.type == "PONG" then
        noteNode(msg.from)
      end
      return msg
    end
  end
end

local function discover(wait)
  send({type = "PING", from = selfAddr})
  local deadline = computer.uptime() + (wait or 1)
  while computer.uptime() < deadline do
    pump()
  end
end

-- Submit `code` (compiled as a chunk and called with `args` as its only
-- argument) to one worker node and block for the result. Picks the next
-- node round-robin unless targetAddr is given.
local function submit(code, args, targetAddr)
  if #nodeOrder == 0 then
    return nil, "no worker nodes discovered yet -- try 'discover'"
  end

  local addr = targetAddr
  if not addr then
    addr = nodeOrder[nextNode]
    nextNode = (nextNode % #nodeOrder) + 1
  end

  local id = nextJobId
  nextJobId = nextJobId + 1
  send({type = "JOB", from = selfAddr, to = addr, id = id, code = code, args = args})

  local deadline = computer.uptime() + TIMEOUT
  while computer.uptime() < deadline do
    local msg = pump()
    if type(msg) == "table" and msg.id == id and msg.to == selfAddr then
      if msg.type == "RESULT" then
        return msg.result
      elseif msg.type == "ERROR" then
        return nil, msg.error
      end
    end
  end
  return nil, "timed out waiting for " .. addr
end

local function listNodes()
  if #nodeOrder == 0 then
    print("no worker nodes known -- try 'discover'")
    return
  end
  for _, addr in ipairs(nodeOrder) do
    print(string.format("%s  (last seen %.1fs ago)", addr, computer.uptime() - nodes[addr].lastSeen))
  end
end

local function repl()
  print("rackos arbiter -- " .. selfAddr)
  print("commands: discover | nodes | run <lua code> | runall <lua code> | quit")
  discover(1)
  listNodes()
  while true do
    io.write("rackos> ")
    local line = io.read()
    if not line or line == "quit" or line == "exit" then
      break
    elseif line == "discover" then
      discover(1)
      listNodes()
    elseif line == "nodes" then
      listNodes()
    elseif line:match("^run%s") then
      local result, err = submit(line:sub(5), nil)
      if err then print("error: " .. err) else print(tostring(result)) end
    elseif line:match("^runall%s") then
      local code = line:sub(8)
      for _, addr in ipairs(nodeOrder) do
        local result, err = submit(code, nil, addr)
        if err then print(addr .. ": error: " .. err)
        else print(addr .. ": " .. tostring(result)) end
      end
    elseif line ~= "" then
      print("unknown command")
    end
  end
end

repl()
