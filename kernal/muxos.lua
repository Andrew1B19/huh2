-- muxos kernal program for huh2. Runs under a normal OpenOS boot on the
-- main rack node (own CPU/RAM/EEPROM/HDD, same as any OC computer).
-- Discovers worker nodes flashed with node/bios.lua over the rack's shared
-- network segment, serves them their actual runtime (node/runtime.lua) at
-- boot, and dispatches Lua jobs to them.
--
-- Install: copy this AND node/runtime.lua onto the kernal's filesystem as
-- siblings (e.g. /home/muxos.lua and /home/runtime.lua) and run this from
-- the OpenOS shell. Workers only ever get bios.lua flashed to their
-- EEPROM -- this script reads runtime.lua's source off the kernal's own
-- disk and serves it to them over the modem (see serveBoot() below).
--
-- Wire format: see docs/PROTOCOL.md. The serializer below is a deliberate
-- duplicate of the one in node/runtime.lua, not a shared dependency --
-- that file can't `require` anything either, so keeping both sides
-- self-contained avoids a split-brain "shared lib" that only one side
-- can actually load.

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

-- The kernal is the scheduler, so it's the one place that actually knows
-- about every job dispatched to any node -- this is what lets
-- get_processes() (the muxos equivalent of gmux's api.get_processes())
-- be a real answer instead of each worker only knowing about its own
-- single in-flight job. id -> {id, node, status, code, startedAt,
-- finishedAt, result, error}. status is "running", "done", or "error",
-- mirroring gmux's own process status values closely enough to be
-- recognizable without claiming exact parity with its "waiting"/"dead".
local jobs = {}
local jobOrder = {}

-- Minimal window registry -- NOT a port of gmux's real desktop
-- (lib/gmux/frontend/windows.lua + graphics.lua: layering, dragging,
-- resizing, routing input by topmost-window-under-cursor). What this
-- gives: allocate a GPU buffer, let code draw into it, blit it onto the
-- kernal's own real screen at a fixed (x, y), and remember it existed.
-- Enough to make create_window/get_windows real without pretending
-- there's a desktop here. id -> {id, title, x, y, width, height, buffer}.
local windows = {}
local windowOrder = {}

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

local function nextId()
  local id = nextJobId
  nextJobId = nextJobId + 1
  return id
end

-- Record a job's dispatch and actually send it, WITHOUT waiting for the
-- result -- shared by submit() (which then blocks on awaitReply itself)
-- and handleSpawn() (which must return to the calling worker immediately,
-- gmux's own create_headless_process/create_graphics_process being
-- fire-and-forget: you get a handle back right away, not the result).
-- Completion is recorded generically in pump() below, so it's tracked
-- correctly either way.
local function dispatchJob(code, args, targetAddr)
  if not targetAddr then
    if #nodeOrder == 0 then
      return nil, "no worker nodes discovered yet -- try 'discover'"
    end
    targetAddr = nodeOrder[nextNode]
    nextNode = (nextNode % #nodeOrder) + 1
  end
  local id = nextId()
  jobs[id] = {id = id, node = targetAddr, status = "running", code = code, startedAt = computer.uptime()}
  jobOrder[#jobOrder + 1] = id
  send({type = "JOB", from = selfAddr, to = targetAddr, id = id, code = code, args = args})
  return id, targetAddr
end

-- Resolve runtime.lua as a sibling of wherever this script is actually
-- running from, so installs aren't tied to a hardcoded /home/ path.
local function scriptDir()
  local info = debug.getinfo(1, "S")
  local path = info.source:match("^@(.*)$") or info.source
  return path:match("^(.*)/[^/]*$") or "."
end

local RUNTIME_PATH = scriptDir() .. "/runtime.lua"
local runtimeSource = nil -- loaded lazily and cached, see loadRuntime()

local function loadRuntime()
  if runtimeSource then return runtimeSource end
  local f, openErr = io.open(RUNTIME_PATH, "r")
  if not f then return nil, "could not open " .. RUNTIME_PATH .. ": " .. tostring(openErr) end
  runtimeSource = f:read("a")
  f:close()
  return runtimeSource
end

-- Answer a worker's BOOT request (node/bios.lua's network-boot stub) with
-- its real runtime, broadcast once -- any OTHER worker still waiting on
-- its own BOOT picks up the same reply for free, since they all need the
-- identical payload. Not wrapped in the serialized-table protocol: BOOT
-- happens before a worker has that runtime loaded at all, so it uses its
-- own plain "WORD <payload>" convention (see node/bios.lua).
-- Stay comfortably under maxNetworkPacketSize (8192, confirmed from
-- application.conf -- see docs/PROTOCOL.md) even accounting for the
-- "CODE <i>/<n> " prefix on each chunk.
local BOOT_CHUNK_SIZE = 7000

local function serveBoot(workerAddr)
  local source, err = loadRuntime()
  if not source then
    print("boot request from " .. workerAddr .. " but " .. err)
    return
  end
  local total = math.ceil(#source / BOOT_CHUNK_SIZE)
  for i = 1, total do
    local chunk = source:sub((i - 1) * BOOT_CHUNK_SIZE + 1, i * BOOT_CHUNK_SIZE)
    modem.broadcast(PORT, "CODE " .. i .. "/" .. total .. " " .. chunk)
  end
end

-- Service a LIST/INVOKE request FROM a worker, against the kernal's OWN
-- components. This is the reverse direction of the "remote component"
-- bridge in node/bios.lua: a worker with no screen/disk of its own asks
-- the kernal to act on its behalf, same wire shape either direction.
local function handleList(msg)
  local list = {}
  for addr, ctype in component.list() do
    list[addr] = ctype
  end
  send({type = "RESULT", from = selfAddr, to = msg.from, id = msg.id, result = list})
end

local function handleInvoke(msg)
  local packed = table.pack(pcall(component.invoke, msg.address, msg.method, table.unpack(msg.args or {})))
  if packed[1] then
    local returns = {}
    for i = 2, packed.n do returns[#returns + 1] = packed[i] end
    send({type = "RESULT", from = selfAddr, to = msg.from, id = msg.id, result = returns})
  else
    send({type = "ERROR", from = selfAddr, to = msg.from, id = msg.id, error = tostring(packed[2])})
  end
end

-- Muxos-shaped create_headless_process/create_graphics_process: a
-- worker asks the kernal to dispatch a NEW job (possibly on a different
-- node than the one asking), fire-and-forget -- gmux's own versions
-- return a process handle immediately too, not the eventual result.
-- gmux's `options.main` is a function value; that can't cross the
-- network, so this takes `options.code` (a Lua source string, same
-- convention as JOB) instead -- the one deliberate shape difference from
-- the real API, documented in docs/PROTOCOL.md.
local function handleSpawn(msg)
  if not msg.code then
    send({type = "ERROR", from = selfAddr, to = msg.from, id = msg.id,
      error = "spawn needs options.code (a Lua source string) -- gmux's options.main/main_path can't cross the network"})
    return
  end
  local jobId, targetAddr = dispatchJob(msg.code, msg.args, msg.node)
  if not jobId then
    send({type = "ERROR", from = selfAddr, to = msg.from, id = msg.id, error = targetAddr})
    return
  end
  send({type = "RESULT", from = selfAddr, to = msg.from, id = msg.id, result = {id = jobId, node = targetAddr}})
end

local function kernalGpu()
  if component.isAvailable("gpu") then return component.gpu end
end

-- Runs `code` (compiled fresh, same convention as JOB/a job's `gpu`
-- face) with a `gpu` local already pointed at the given buffer, so
-- window-drawing code looks like ordinary gpu-face code -- it's just
-- executed directly on the kernal instead of forwarded there, since gmux's
-- own `func(gpu)` draw callback is a function value and can't cross the
-- network the way `gpu`-face JOB code already doesn't need to.
--
-- Every GPU method (set/fill/copy/bitblt/...) is a Callback(direct =
-- true) in OC's own source (confirmed in GraphicsCard.scala) -- meaning
-- it executes with NO yield, straight-line, against a per-tick call
-- budget (Machine.scala: resets once per tick, tier-scaled). `code` here
-- runs as one uninterrupted resume with no yields in between, so a
-- caller doing a big fill via many individual gpu.set() calls instead of
-- one gpu.fill()/bitblt() is exactly the shape that can exhaust that
-- budget mid-draw. Prefer fill/copy/bitblt over set-loops in window
-- draw code for this reason, not just speed.
local function drawIntoBuffer(gpu, buffer, code)
  gpu.setActiveBuffer(buffer)
  local chunk, loadErr = load("local gpu = ...\n" .. code, "=window", "t")
  local ok, err
  if chunk then
    ok, err = pcall(chunk, gpu)
  else
    ok, err = false, loadErr
  end
  gpu.setActiveBuffer(0)
  if ok then return true end
  return nil, err
end

-- Muxos-shaped create_window (also standing in for gmux's separate
-- create_window_buffer -- see docs/PROTOCOL.md for why those two
-- collapse into one remote call here). Allocates a GPU buffer, runs
-- `code` against it if given, blits it onto the kernal's real screen at
-- (x, y) once, and remembers it as a window. NOT live -- unlike gmux's
-- create_window with a vgpu/vscreen source, this never redraws itself;
-- redrawing means calling it again (or a future update, not built).
local function createWindow(options)
  local gpu = kernalGpu()
  if not gpu then return nil, "kernal has no gpu component" end
  if not gpu.allocateBuffer then return nil, "kernal's gpu does not support buffers (tier 1?)" end

  local width = options.width or 30
  local height = options.height or 10
  local buffer, allocErr = gpu.allocateBuffer(width, height)
  if not buffer then return nil, "could not allocate a gpu buffer: " .. tostring(allocErr) end

  if options.code then
    local ok, drawErr = drawIntoBuffer(gpu, buffer, options.code)
    if not ok then
      gpu.freeBuffer(buffer)
      return nil, "window draw code failed: " .. tostring(drawErr)
    end
  end

  local x, y = options.x or 1, options.y or 1
  gpu.bitblt(0, x, y, width, height, buffer, 1, 1)

  local id = nextId()
  local win = {id = id, title = options.title or ("window " .. id), x = x, y = y,
    width = width, height = height, buffer = buffer}
  windows[id] = win
  windowOrder[#windowOrder + 1] = id
  return win
end

local function handleCreateWindow(msg)
  local win, err = createWindow(msg)
  if not win then
    send({type = "ERROR", from = selfAddr, to = msg.from, id = msg.id, error = err})
    return
  end
  send({type = "RESULT", from = selfAddr, to = msg.from, id = msg.id, result = win})
end

local function handleGetWindows(msg)
  local list = {}
  for _, id in ipairs(windowOrder) do
    list[#list + 1] = windows[id]
  end
  send({type = "RESULT", from = selfAddr, to = msg.from, id = msg.id, result = list})
end

-- First real slice of the gmux application API, muxos-shaped:
-- api.get_processes() in gmux reads one local process table; here it has
-- to be a request, since the jobs it's asking about run on other
-- physical nodes. Returns the same job records `jobs` holds -- a plain
-- list, serializable as-is since each entry is only strings/numbers.
local function handleGetProcesses(msg)
  local list = {}
  for _, id in ipairs(jobOrder) do
    list[#list + 1] = jobs[id]
  end
  send({type = "RESULT", from = selfAddr, to = msg.from, id = msg.id, result = list})
end

-- Pull one pending modem message, if any, without blocking. Used by
-- discovery, submit()'s wait loop, and the REPL's startup discover(1)
-- call. Incoming BOOT requests and LIST/INVOKE requests (from a worker
-- calling back into the kernal) are serviced here directly and never
-- returned -- they aren't a reply anything is waiting on.
--
-- Caveat: this only runs while something is actively polling (discover,
-- awaitReply, pingOnce). While the REPL is blocked on io.read() at the
-- prompt, nothing pumps the modem at all, so a worker's BOOT or remote
-- call can sit unanswered until the next command triggers a pump()
-- somewhere. A worker's own boot loop retries every 5s, so it recovers
-- once a command does, but a kernal that's sitting idle at the prompt
-- the moment a worker powers on will stall it for a while. Fixing that
-- needs real concurrency (a background thread/event.listen), which is
-- exactly the kind of thing the "multi-threading kernel API" is meant to
-- eventually provide -- not done here.
local function pump()
  local name, _, from, port, _, data = event.pull(0, "modem_message")
  if name and port == PORT and type(data) == "string" then
    local bootFrom = data:match("^BOOT (.+)$")
    if bootFrom then
      serveBoot(bootFrom)
      return nil
    end
    local msg = deserialize(data)
    if type(msg) == "table" and msg.from and msg.from ~= selfAddr then
      if msg.type == "HELLO" or msg.type == "PONG" then
        noteNode(msg.from)
      elseif msg.to == selfAddr and msg.type == "LIST" then
        handleList(msg)
        return nil
      elseif msg.to == selfAddr and msg.type == "INVOKE" then
        handleInvoke(msg)
        return nil
      elseif msg.to == selfAddr and msg.type == "GETPROCESSES" then
        handleGetProcesses(msg)
        return nil
      elseif msg.to == selfAddr and msg.type == "SPAWN" then
        handleSpawn(msg)
        return nil
      elseif msg.to == selfAddr and msg.type == "CREATEWINDOW" then
        handleCreateWindow(msg)
        return nil
      elseif msg.to == selfAddr and msg.type == "GETWINDOWS" then
        handleGetWindows(msg)
        return nil
      elseif msg.to == selfAddr and (msg.type == "RESULT" or msg.type == "ERROR")
          and jobs[msg.id] and jobs[msg.id].status == "running" then
        -- Generic job-completion recording: covers BOTH a submit()-dispatched
        -- job (something is actively awaitReply()-ing on it, which still
        -- gets this same msg via the `return msg` below) AND a
        -- handleSpawn()-dispatched one (fire-and-forget -- nothing is
        -- waiting locally, so this is the ONLY place its completion is
        -- ever recorded).
        local job = jobs[msg.id]
        job.finishedAt = computer.uptime()
        if msg.type == "RESULT" then
          job.status, job.result = "done", msg.result
        else
          job.status, job.error = "error", msg.error
        end
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

-- Submit `code` (compiled as a chunk and called with `args` as its only
-- argument) to one worker node and block for the result. Picks the next
-- node round-robin unless targetAddr is given. Completion is recorded in
-- `jobs` by pump()'s generic handling above, not here -- dispatchJob()
-- already created the record before this blocks on awaitReply.
local function submit(code, args, targetAddr)
  local id, addrOrErr = dispatchJob(code, args, targetAddr)
  if not id then
    return nil, addrOrErr
  end
  return awaitReply(id, addrOrErr)
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

-- No network round trip needed here, unlike get_processes() as seen from
-- a worker (handleGetProcesses) -- the REPL runs in the same process as
-- `jobs` itself.
local function printProcesses()
  if #jobOrder == 0 then
    print("no jobs dispatched yet")
    return
  end
  for _, id in ipairs(jobOrder) do
    local job = jobs[id]
    print(string.format("[%d] %s on %s%s", job.id, job.status, job.node,
      job.error and (" -- " .. job.error) or ""))
  end
end

local function printWindows()
  if #windowOrder == 0 then
    print("no windows created yet")
    return
  end
  for _, id in ipairs(windowOrder) do
    local win = windows[id]
    print(string.format("[%d] %q  %dx%d at (%d,%d)", win.id, win.title, win.width, win.height, win.x, win.y))
  end
end

local function repl()
  print("muxos kernal -- " .. selfAddr)
  print("commands:")
  print("  discover | nodes | ping <node> [count] | quit")
  print("  run <lua code> | runall <lua code> | processes")
  print("  spawn <node> <lua code>")
  print("  window <title> <x> <y> <width> <height> <lua code drawing into `gpu`> | windows")
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
    elseif line == "processes" then
      printProcesses()
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
    elseif line:match("^spawn%s") then
      local node, code = line:match("^spawn%s+(%S+)%s+(.*)$")
      if not node then
        print("usage: spawn <node> <lua code>")
      else
        local id, addrOrErr = dispatchJob(code, nil, resolveNode(node))
        if not id then print("error: " .. addrOrErr) else print("spawned job [" .. id .. "] on " .. addrOrErr) end
      end
    elseif line:match("^window%s") then
      local title, x, y, w, h, code = line:match("^window%s+(%S+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(.*)$")
      if not title then
        print("usage: window <title> <x> <y> <width> <height> <lua code drawing into `gpu`>")
      else
        local win, err = createWindow({title = title, x = tonumber(x), y = tonumber(y),
          width = tonumber(w), height = tonumber(h), code = code})
        if err then print("error: " .. err) else print("created window [" .. win.id .. "]") end
      end
    elseif line == "windows" then
      printWindows()
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
