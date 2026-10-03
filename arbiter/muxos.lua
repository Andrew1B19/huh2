-- muxos arbiter program for huh2. Runs under a normal OpenOS boot on the
-- main rack node (own CPU/RAM/EEPROM/HDD, same as any OC computer).
-- Discovers worker nodes flashed with node/bios.lua over the rack's shared
-- network segment and dispatches Lua jobs to them.
--
-- Install: copy onto the arbiter's filesystem (e.g. /home/muxos.lua) and
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

-- Block until a RESULT/ERROR for `id` comes back from `addr`, or time out.
local function awaitReply(id, addr)
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

local function nextId()
  local id = nextJobId
  nextJobId = nextJobId + 1
  return id
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

  local id = nextId()
  send({type = "JOB", from = selfAddr, to = addr, id = id, code = code, args = args})
  return awaitReply(id, addr)
end

-- List the components physically attached to a remote node: address -> type.
local function listComponents(addr)
  local id = nextId()
  send({type = "LIST", from = selfAddr, to = addr, id = id})
  return awaitReply(id, addr)
end

-- Call a method on a component attached to a remote node. This is the
-- "remote component" bridge: addressed the same way component.invoke()
-- would be locally, but carried over the modem. Returns a list of the
-- remote call's return values (component methods can return more than
-- one), or nil + an error string.
local function invoke(addr, componentAddr, method, args)
  local id = nextId()
  send({type = "INVOKE", from = selfAddr, to = addr, id = id, address = componentAddr, method = method, args = args})
  return awaitReply(id, addr)
end

-- Round-trip latency probe: times a single targeted PING/PONG exchange.
-- Unlike discover()'s broadcast PING, this one sets `to` so only the
-- named node answers, and we measure wall time from send to the matching
-- PONG. Exists to measure the rack's actual message latency empirically --
-- see docs/PROTOCOL.md for why that number isn't otherwise documented.
local function pingOnce(addr, id)
  local sentAt = computer.uptime()
  send({type = "PING", from = selfAddr, to = addr, id = id})
  local deadline = sentAt + TIMEOUT
  while computer.uptime() < deadline do
    local msg = pump()
    if type(msg) == "table" and msg.type == "PONG" and msg.id == id and msg.to == selfAddr then
      return computer.uptime() - sentAt
    end
  end
  return nil, "timed out waiting for " .. addr
end

local function pingReport(addr, count)
  count = count or 3
  local min, max, total, replies = nil, nil, 0, 0
  for _ = 1, count do
    local rtt, err = pingOnce(addr, nextId())
    if rtt then
      replies = replies + 1
      total = total + rtt
      min = (not min or rtt < min) and rtt or min
      max = (not max or rtt > max) and rtt or max
      print(string.format("  reply from %s: time=%.1fms", addr, rtt * 1000))
    else
      print(string.format("  no reply from %s (%s)", addr, err))
    end
  end
  if replies > 0 then
    print(string.format("%d/%d replies -- min/avg/max = %.1f/%.1f/%.1fms",
      replies, count, min * 1000, (total / replies) * 1000, max * 1000))
  end
end

-- Let REPL commands refer to a node by its position in `nodes`/`discover`
-- output (easier to type than a full UUID) as well as by full address.
local function resolveNode(token)
  local index = tonumber(token)
  if index and nodeOrder[index] then
    return nodeOrder[index]
  end
  return token
end

local function listNodes()
  if #nodeOrder == 0 then
    print("no worker nodes known -- try 'discover'")
    return
  end
  for i, addr in ipairs(nodeOrder) do
    print(string.format("[%d] %s  (last seen %.1fs ago)", i, addr, computer.uptime() - nodes[addr].lastSeen))
  end
end

local function printComponents(addr)
  local list, err = listComponents(addr)
  if err then
    print("error: " .. err)
    return
  end
  for compAddr, ctype in pairs(list) do
    print(string.format("%s  %s", compAddr, ctype))
  end
end

local function repl()
  print("muxos arbiter -- " .. selfAddr)
  print("commands:")
  print("  discover | nodes | ping <node> [count] | quit")
  print("  run <lua code> | runall <lua code>")
  print("  components <node> | call <node> <component addr> <method> [args table]")
  print("(<node> is either a [n] index from 'nodes' or a full node address)")
  discover(1)
  listNodes()
  while true do
    io.write("muxos> ")
    local line = io.read()
    if not line or line == "quit" or line == "exit" then
      break
    elseif line == "discover" then
      discover(1)
      listNodes()
    elseif line == "nodes" then
      listNodes()
    elseif line:match("^ping%s") then
      local node, countStr = line:match("^ping%s+(%S+)%s*(%S*)$")
      if not node then
        print("usage: ping <node> [count]")
      else
        pingReport(resolveNode(node), tonumber(countStr))
      end
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
    elseif line:match("^components%s") then
      printComponents(resolveNode(line:match("^components%s+(%S+)")))
    elseif line:match("^call%s") then
      local node, compAddr, method, rest = line:match("^call%s+(%S+)%s+(%S+)%s+(%S+)%s*(.*)$")
      if not node then
        print("usage: call <node> <component addr> <method> [args table]")
      else
        local args, parseOk = nil, true
        if rest ~= "" then
          args = deserialize(rest)
          if args == nil then
            print("could not parse args table: " .. rest)
            parseOk = false
          end
        end
        if parseOk then
          local result, err = invoke(resolveNode(node), compAddr, method, args)
          if err then print("error: " .. err) else print(serialize(result)) end
        end
      end
    elseif line ~= "" then
      print("unknown command")
    end
  end
end

repl()
