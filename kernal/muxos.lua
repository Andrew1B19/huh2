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
local thread = require("thread")

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

-- The compositor (compositor.lua) is the only code that's supposed to
-- touch the real gpu/screen -- but INVOKE is a generic remote-component
-- bridge, so without this check a worker's `gpu` face could reach the
-- kernal's real display directly, bypassing the compositor entirely.
-- Blocked by default; a node holding this exclusive grant (via
-- gmuxapi.request_fullscreen()) is let through, for the one legitimate
-- case where going around the compositor is the point -- a fullscreen
-- app that wants to own the whole display and draw without buffer/blit
-- overhead. Only one node may hold it at a time. Not released
-- automatically if its holder disappears (reboots, crashes) -- a real
-- gap, flagged rather than silently handled.
local exclusiveFullscreenOwner = nil

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

-- id -> the RESULT/ERROR/PONG message that answered it. Filled in ONLY
-- by pump() (see below), read and cleared by waitForReply(). This is
-- what lets pump() run exclusively inside the background dispatcher
-- thread (started near the bottom of this file) without a second,
-- independent poller: every synchronous wait (submit/listComponents/
-- invoke/pingOnce) checks this shared table and yields with os.sleep(0)
-- between checks, instead of calling event.pull itself. Two independent
-- `event.pull(0, "modem_message")` callers would race over the same
-- queue -- whichever drains a given reply first keeps it, silently
-- starving the other -- so there must be exactly one.
local replyBox = {}

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

-- The compositor is the only code in this whole project that makes a
-- real gpu.* call -- see compositor.lua's own header for why that's
-- worth enforcing structurally, not just by convention. Loaded as a
-- sibling file via dofile(), not require(), for the same reason
-- runtime.lua is read directly off disk below rather than required.
local compositor = dofile(scriptDir() .. "/compositor.lua")

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

-- True if `address` is the kernal's own real gpu or the screen it's
-- bound to -- the two component types the compositor exists to own.
-- Deliberately narrow: INVOKE on anything else (redstone, sensors, a
-- second gpu, whatever) is unaffected by the fullscreen grant.
local function isDisplayComponent(address)
  if component.isAvailable("gpu") and component.gpu.address == address then return true end
  if component.isAvailable("screen") and component.screen.address == address then return true end
  return false
end

local function handleInvoke(msg)
  if isDisplayComponent(msg.address) and msg.from ~= exclusiveFullscreenOwner then
    send({type = "ERROR", from = selfAddr, to = msg.from, id = msg.id,
      error = "direct gpu/screen access is blocked -- use create_window, or gmuxapi.request_fullscreen() for exclusive access"})
    return
  end
  local packed = table.pack(pcall(component.invoke, msg.address, msg.method, table.unpack(msg.args or {})))
  if packed[1] then
    local returns = {}
    for i = 2, packed.n do returns[#returns + 1] = packed[i] end
    send({type = "RESULT", from = selfAddr, to = msg.from, id = msg.id, result = returns})
  else
    send({type = "ERROR", from = selfAddr, to = msg.from, id = msg.id, error = tostring(packed[2])})
  end
end

-- gmuxapi.request_fullscreen()/release_fullscreen(): the one way around
-- handleInvoke's block above. First-come-first-served -- a node already
-- holding the grant re-requesting it is a no-op success, but a second,
-- different node is refused outright rather than queued.
local function handleRequestFullscreen(msg)
  if exclusiveFullscreenOwner and exclusiveFullscreenOwner ~= msg.from then
    send({type = "ERROR", from = selfAddr, to = msg.from, id = msg.id,
      error = "fullscreen already held by " .. exclusiveFullscreenOwner})
    return
  end
  exclusiveFullscreenOwner = msg.from
  send({type = "RESULT", from = selfAddr, to = msg.from, id = msg.id, result = {granted = true}})
end

local function handleReleaseFullscreen(msg)
  if exclusiveFullscreenOwner ~= msg.from then
    send({type = "ERROR", from = selfAddr, to = msg.from, id = msg.id,
      error = "you do not hold the fullscreen grant"})
    return
  end
  exclusiveFullscreenOwner = nil
  send({type = "RESULT", from = selfAddr, to = msg.from, id = msg.id, result = {released = true}})
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

-- Both of these just delegate to the compositor (compositor.lua) -- the
-- one file in this project allowed to touch the real gpu. muxos.lua's
-- job here is only wire plumbing: unwrap the request, call in, wrap the
-- reply.
local function handleCreateWindow(msg)
  local win, err = compositor.createWindow(msg)
  if not win then
    send({type = "ERROR", from = selfAddr, to = msg.from, id = msg.id, error = err})
    return
  end
  send({type = "RESULT", from = selfAddr, to = msg.from, id = msg.id, result = win})
end

local function handleGetWindows(msg)
  send({type = "RESULT", from = selfAddr, to = msg.from, id = msg.id, result = compositor.listWindows()})
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

-- Pull and fully handle one pending modem message, if any; never
-- blocks. This is the ONLY function in the whole program allowed to
-- call event.pull(0, "modem_message") -- see replyBox's comment above
-- for why having a second independent poller would be a real bug, not
-- just a style issue. A request (BOOT/LIST/INVOKE/.../RELEASEFULLSCREEN)
-- is serviced immediately, right here. A reply (PONG/RESULT/ERROR) is
-- stashed into replyBox for whoever's waiting on that id (waitForReply,
-- below) to pick up -- never acted on directly here. Returns true if it
-- did anything (including "received something irrelevant"), false if
-- the queue was simply empty, so `while pump() do end` drains it.
--
-- Called exclusively from the background dispatcher thread started near
-- the bottom of this file -- which is what finally closes the old gap
-- here: the kernal now services requests and discovery continuously,
-- not just "whenever a REPL command happens to poll." Confirmed from
-- OpenOS's own source (lib/thread.lua, boot/02_os.lua) that this
-- actually works: threads are real coroutines cooperatively scheduled
-- through the same event.pull mechanism, and os.sleep always yields at
-- least once (`repeat event.pull(...) until deadline`) -- so the
-- background thread keeps running even while the REPL is blocked on
-- io.read() at the prompt.
local function pump()
  local name, _, from, port, _, data = event.pull(0, "modem_message")
  if not (name and port == PORT and type(data) == "string") then
    return false
  end

  local bootFrom = data:match("^BOOT (.+)$")
  if bootFrom then
    serveBoot(bootFrom)
    return true
  end

  local msg = deserialize(data)
  if type(msg) ~= "table" or not msg.from or msg.from == selfAddr then
    return true
  end

  if msg.type == "HELLO" or msg.type == "PONG" then
    noteNode(msg.from)
  end
  if msg.to ~= selfAddr then
    return true
  end

  if msg.type == "LIST" then
    handleList(msg)
  elseif msg.type == "INVOKE" then
    handleInvoke(msg)
  elseif msg.type == "GETPROCESSES" then
    handleGetProcesses(msg)
  elseif msg.type == "SPAWN" then
    handleSpawn(msg)
  elseif msg.type == "CREATEWINDOW" then
    handleCreateWindow(msg)
  elseif msg.type == "GETWINDOWS" then
    handleGetWindows(msg)
  elseif msg.type == "REQUESTFULLSCREEN" then
    handleRequestFullscreen(msg)
  elseif msg.type == "RELEASEFULLSCREEN" then
    handleReleaseFullscreen(msg)
  elseif msg.type == "PONG" or msg.type == "RESULT" or msg.type == "ERROR" then
    if msg.id then
      replyBox[msg.id] = msg
      -- Generic job-completion recording: covers BOTH a submit()-dispatched
      -- job (something is actively waitForReply()-ing on it, which still
      -- picks up this same msg from replyBox) AND a handleSpawn()-dispatched
      -- one (fire-and-forget -- nothing is waiting locally, so this is the
      -- ONLY place its completion is ever recorded).
      if (msg.type == "RESULT" or msg.type == "ERROR") and jobs[msg.id] and jobs[msg.id].status == "running" then
        local job = jobs[msg.id]
        job.finishedAt = computer.uptime()
        if msg.type == "RESULT" then
          job.status, job.result = "done", msg.result
        else
          job.status, job.error = "error", msg.error
        end
      end
    end
  end
  return true
end

-- Broadcasts PING and just waits out `wait` seconds -- the background
-- thread's own pump() calls are what actually process the HELLO/PONG
-- replies into `nodes` (noteNode) during that window; this doesn't poll
-- the modem itself.
local function discover(wait)
  send({type = "PING", from = selfAddr})
  os.sleep(wait or 1)
end

-- Block until pump() (running in the background thread) stashes a reply
-- for `id` into replyBox, or time out. The one shared wait primitive
-- behind submit()/listComponents()/invoke()/pingOnce() -- none of them
-- poll the modem themselves any more.
local function waitForReply(id, addr, timeout)
  local deadline = computer.uptime() + (timeout or TIMEOUT)
  while computer.uptime() < deadline do
    local msg = replyBox[id]
    if msg then
      replyBox[id] = nil
      return msg
    end
    os.sleep(0)
  end
  return nil, "timed out waiting for " .. tostring(addr)
end

local function awaitReply(id, addr)
  local msg, err = waitForReply(id, addr)
  if not msg then return nil, err end
  if msg.type == "RESULT" then return msg.result end
  return nil, msg.error
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
  local msg, err = waitForReply(id, addr)
  if not msg then return nil, err end
  return computer.uptime() - sentAt
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

-- Generates a small test pattern (a filled diamond, red center ring,
-- blue outer ring, transparent corners) so `bitdemo` has something
-- visually meaningful to draw without requiring anyone to type a pixel
-- grid by hand at the REPL.
local function demoPixels(size)
  local pixels = {}
  local center = (size + 1) / 2
  for y = 1, size do
    pixels[y] = {}
    for x = 1, size do
      local dist = math.abs(x - center) + math.abs(y - center)
      if dist < size / 4 then
        pixels[y][x] = 0xff0000 -- red center
      elseif dist < size / 2 then
        pixels[y][x] = 0x0000ff -- blue ring
      else
        pixels[y][x] = nil -- transparent corners
      end
    end
  end
  return pixels
end

local function printWindows()
  local list = compositor.listWindows()
  if #list == 0 then
    print("no windows created yet")
    return
  end
  for _, win in ipairs(list) do
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
  print("  bitdemo <halfblock|braille> <x> <y> -- draws a test pattern as a bit window")
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
        local win, err = compositor.createWindow({title = title, x = tonumber(x), y = tonumber(y),
          width = tonumber(w), height = tonumber(h), code = code})
        if err then print("error: " .. err) else print("created window [" .. win.id .. "]") end
      end
    elseif line == "windows" then
      printWindows()
    elseif line:match("^bitdemo%s") then
      local mode, x, y = line:match("^bitdemo%s+(%S+)%s+(%d+)%s+(%d+)$")
      if not mode or (mode ~= "halfblock" and mode ~= "braille") then
        print("usage: bitdemo <halfblock|braille> <x> <y>")
      else
        local win, err = compositor.createWindow({title = "bitdemo", x = tonumber(x), y = tonumber(y),
          pixels = demoPixels(16), width = 16, height = 16, mode = mode, bg = 0x000000})
        if err then print("error: " .. err) else print("created bit window [" .. win.id .. "] (" .. win.width .. "x" .. win.height .. " cells)") end
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

-- Background dispatcher: the sole caller of pump() (see its own comment
-- for why), draining everything currently queued every iteration -- the
-- network side isn't rate-limited (modem.send/broadcast aren't `direct`
-- calls, see docs/PROTOCOL.md's call-budget section) so there's no
-- reason to throttle message handling to once per tick. compositor.flush()
-- IS called once per iteration, though, which -- paced by the os.sleep(0.05)
-- below -- is the "upper bound of once per tick" for the real screen
-- write: every dirty window composited, at most one real bitblt to the
-- screen, however many CREATEWINDOW calls arrived since the last tick.
-- pcall-wrapped so one bad message or a draw-code error can't silently
-- kill this thread forever -- without it, an uncaught error here would
-- quietly disable boot-serving, every remote-component handler, AND the
-- compositor for the rest of the kernal's uptime, with no obvious symptom
-- beyond "nothing responds any more."
thread.create(function()
  while true do
    local ok, err = pcall(function()
      while pump() do end
      compositor.flush()
    end)
    if not ok then
      print("background dispatcher error (continuing): " .. tostring(err))
    end
    os.sleep(0.05) -- ~1 tick
  end
end)

repl()
