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
local MUXOS_VERSION = "0.1.0"

-- node/bios.lua passes this in: the address of whoever's CODE chunks
-- actually completed the boot handshake -- the ONE place a worker ever
-- learns which node is "the kernal". Kept authoritative for this
-- node's whole lifetime: nothing re-derives it from incoming messages
-- (it once did, which let any node pose as the kernal).
local kernalAddr = ...

-- tostring() would round floats to 14 significant digits and turn
-- inf/nan into bare identifiers that deserialize as nil.
local function serializeNumber(v)
  if v ~= v then return "0/0" end
  if v == math.huge then return "1/0" end
  if v == -math.huge then return "-1/0" end
  if math.type(v) == "integer" then return tostring(v) end
  local s = string.format("%.17g", v)
  if not s:find("[%.eE]") then s = s .. ".0" end
  return s
end

local function serialize(v, seen)
  seen = seen or {}
  local t = type(v)
  if t == "nil" or t == "boolean" then
    return tostring(v)
  elseif t == "number" then
    return serializeNumber(v)
  elseif t == "string" then
    return string.format("%q", v)
  elseif t == "table" then
    if seen[v] then error("cannot serialize a cyclic table") end
    seen[v] = true
    -- The array part goes positionally (no "[i]=" per element, which
    -- would roughly double list-heavy messages), the rest as [k]=v.
    local parts = {}
    local n = #v
    for i = 1, n do parts[i] = serialize(v[i], seen) end
    for k, val in pairs(v) do
      if not (math.type(k) == "integer" and k >= 1 and k <= n) then
        parts[#parts + 1] = "[" .. serialize(k, seen) .. "]=" .. serialize(val, seen)
      end
    end
    -- Only tables on the current path count as cycles; the same table
    -- referenced twice elsewhere is fine.
    seen[v] = nil
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

-- --- Processes ---
--
-- A worker runs every process placed on it side by side: each is a
-- coroutine, and the scheduler at the bottom of this file resumes
-- whichever can run, round-robin. A process gives up the node only when
-- it waits (sleep, pull_event, readLine, any kernal call) or yields;
-- what it's waiting for is a condition (a deadline, an RPC reply, an
-- input event), checked by the scheduler, so one waiting process never
-- holds the node. Every signal is received in one place (`receive`),
-- whoever happens to be waiting.
local procs, procOrder = {}, {} -- id -> process; ids in round-robin order
local current = nil             -- the process being resumed right now
local WAIT = {}                 -- what a process yields with, plus its condition
local COOPERATE = {cooperate = true}
local rpcWaiting, rpcReplies = {}, {} -- RPC id -> true while awaited; -> reply
local receive, handleMessage    -- defined below

local function findModem()
  for addr in component.list("modem") do
    return addr
  end
end

local modemAddr = findModem()
if not modemAddr then
  -- No network/wireless card present -- there is no way to receive jobs.
  -- Beep and halt rather than spin silently.
  computer.beep(200, 0.5)
  while true do computer.pullSignal() end
end

component.invoke(modemAddr, "open", PORT)

-- The network card's address, not computer.address() -- see
-- kernal/muxos.lua's selfAddr for why identity has to be the card.
local nodeId = modemAddr

-- Every message over the modem is chunked, not just boot's CODE --
-- even a tiny PONG gets wrapped as one chunk, uniformly, rather than
-- having two different wire shapes depending on size. "MSG <id> <i>/<n>
-- <chunk>" frames the ALREADY-serialized Lua-table string; <id> is a
-- per-sender counter, used together with the sending component's real
-- network address (free from the modem_message signal itself, before
-- any payload is parsed) to key reassembly.
local CHUNK_SIZE = 7000
local nextMsgId = 1

local function send(msg)
  local payload = serialize(msg)
  local id = nextMsgId
  nextMsgId = nextMsgId + 1
  local total = math.ceil(#payload / CHUNK_SIZE)
  for i = 1, total do
    local chunk = payload:sub((i - 1) * CHUNK_SIZE + 1, i * CHUNK_SIZE)
    component.invoke(modemAddr, "broadcast", PORT, "MSG " .. id .. " " .. i .. "/" .. total .. " " .. chunk)
  end
end

-- senderAddr:msgId -> {chunks = {[i] = chunkString}, total = n, startedAt}.
-- Filled by `receive`; abandoned entries are swept by the scheduler.
local incomingChunks = {}

local function reassemble(senderAddr, data)
  local msgId, i, n, chunk = data:match("^MSG (%d+) (%d+)/(%d+) (.*)$")
  if not msgId then return nil end
  i, n = tonumber(i), tonumber(n)
  local key = senderAddr .. ":" .. msgId
  local entry = incomingChunks[key]
  if not entry then
    entry = {chunks = {}, total = n, startedAt = computer.uptime()}
    incomingChunks[key] = entry
  end
  entry.chunks[i] = chunk
  for j = 1, entry.total do
    if not entry.chunks[j] then return nil end
  end
  incomingChunks[key] = nil
  return table.concat(entry.chunks, "", 1, entry.total)
end

local function sweepStaleChunks()
  local now = computer.uptime()
  for key, entry in pairs(incomingChunks) do
    if now - entry.startedAt > 10 then
      incomingChunks[key] = nil
    end
  end
end


-- Process control from the kernal: raw, unchunked "KILL <id> <node>",
-- "PAUSE ...", "RESUME ...", "MIGRATE ..." broadcasts (cheap to recognize at every
-- signal, no reassembly). Recorded per job id whether or not that job
-- is running yet (a control can arrive before its JOB) -- and acted on by
-- the scheduler the next time it would resume that process.
-- id -> "KILL" | "PAUSE" | "MIGRATE"
local controlState = {}
local CONTROL_VERBS = {KILL = true, PAUSE = true, RESUME = true, MIGRATE = true}

-- Controls are "VERB <id> <node>": every worker sees the broadcast, but
-- only the node running (or holding queued) that job records it -- a
-- job id can later run on another node after a migration.
local function noteControl(port, data)
  if port ~= PORT or type(data) ~= "string" then return nil end
  local verb, id, node = data:match("^(%u+) (%d+) (%S+)$")
  if not CONTROL_VERBS[verb] then return nil end
  if node ~= nodeId then return verb end
  id = tonumber(id)
  if verb == "RESUME" then
    if controlState[id] == "PAUSE" then controlState[id] = nil end
  elseif controlState[id] ~= "KILL" then
    controlState[id] = verb
  end
  return verb
end

-- job id -> the save function an .mxe registered with mux.migratable.
local migrationHandlers = {}

-- Input events (keyboard, ...) the kernal has routed to a process on
-- this node: job id -> list of packed events, oldest first. Read with
-- gmuxapi.pull_event(). Capped so a process that never reads them can't
-- grow this without bound.
local eventQueues = {}
local MAX_QUEUED_EVENTS = 64

local function queueEvent(id, event)
  if type(id) ~= "number" or type(event) ~= "table" then return end
  local q = eventQueues[id]
  if not q then q = {}; eventQueues[id] = q end
  if #q < MAX_QUEUED_EVENTS then q[#q + 1] = event end
end

-- Program output (print, io.write) is buffered per process and sent to
-- the kernal's console as OUTPUT messages -- at the process's yield
-- points, when it ends, before it reads input, or once the buffer
-- passes OUTPUT_FLUSH_AT -- rather than one message per call.
local outputBuffers = {}
local OUTPUT_FLUSH_AT = 1024

-- --- Cluster component bus: this node's side ---
--
-- Every node's components are visible to processes anywhere in the
-- cluster (see docs/PROTOCOL.md, "Cluster component bus"). This node
-- reports its components to the kernal (COMPONENTS: at boot, when asked,
-- and when one is added or removed) and services calls on them that the
-- kernal relays (INVOKE, and VALUECALL for values a call returned) --
-- at its jobs' yield points too, so a caller never waits for a whole job
-- to finish. Never on the bus: the display and keyboard (the kernal's
-- compositor owns them), network cards (the cluster's own link), and
-- EEPROMs/computer components (node firmware and power).
local BUS_EXCLUDED = {gpu = true, screen = true, keyboard = true, modem = true, tunnel = true,
  eeprom = true, computer = true}

-- Values a component call returned that can't cross the wire (an
-- internet request handle, a socket, ...) stay here; the caller gets
-- {__busValue = n, node = this node} and calls its methods through
-- VALUECALL. Capped: the oldest is closed and dropped.
local busValues, busValueCount, nextBusValue = {}, 0, 1
local MAX_BUS_VALUES = 64

local function isPlain(v, depth)
  local t = type(v)
  if t == "nil" or t == "boolean" or t == "number" or t == "string" then return true end
  if t ~= "table" or depth > 8 then return false end
  for k, x in pairs(v) do
    if not isPlain(k, depth + 1) or not isPlain(x, depth + 1) then return false end
  end
  return true
end

local function exportValue(v)
  if isPlain(v, 0) then return v end
  if busValueCount >= MAX_BUS_VALUES then
    local oldest = math.huge
    for k in pairs(busValues) do if k < oldest then oldest = k end end
    local old = busValues[oldest]
    busValues[oldest], busValueCount = nil, busValueCount - 1
    pcall(function() old.close() end)
  end
  local n = nextBusValue
  nextBusValue, busValueCount = n + 1, busValueCount + 1
  busValues[n] = v
  return {__busValue = n, node = nodeId}
end

-- Calls a method on one of this node's components (INVOKE) or on a value
-- one returned (VALUECALL) for the kernal, and replies.
local function serviceBusCall(msg)
  local args = type(msg.args) == "table" and msg.args or {n = 0}
  local n = args.n or #args
  local packed
  if msg.type == "INVOKE" then
    packed = table.pack(pcall(component.invoke, msg.address, msg.method, table.unpack(args, 1, n)))
  else
    local v = busValues[msg.value]
    if v == nil then
      packed = {false, "that value is gone (closed, or its node restarted)", n = 2}
    else
      packed = table.pack(pcall(function() return v[msg.method](table.unpack(args, 1, n)) end))
      if msg.method == "close" then busValues[msg.value], busValueCount = nil, busValueCount - 1 end
    end
  end
  local reply
  if packed[1] then
    local returns = {n = packed.n - 1}
    for i = 2, packed.n do returns[i - 1] = exportValue(packed[i]) end
    reply = {type = "RESULT", from = nodeId, to = msg.from, id = msg.id, result = returns}
  else
    reply = {type = "ERROR", from = nodeId, to = msg.from, id = msg.id, error = tostring(packed[2])}
  end
  if not pcall(send, reply) then
    send({type = "ERROR", from = nodeId, to = msg.from, id = msg.id, error = "the result can't be sent"})
  end
end

local function reportComponents()
  if not kernalAddr then return end
  local list = {}
  for addr, ctype in component.list() do
    if not BUS_EXCLUDED[ctype] then
      local ok, methods = pcall(component.methods, addr)
      list[addr] = {type = ctype, methods = ok and methods or {}}
    end
  end
  send({type = "COMPONENTS", from = nodeId, to = kernalAddr, components = list})
end

-- Receives one signal, whoever is waiting: the scheduler, or a wait
-- outside any process. A PING is answered on the spot (that's how the
-- kernal knows a busy node is alive, with no heartbeat); a reply to an
-- RPC is kept for the process awaiting it; everything else from the
-- kernal is handled at once (handleMessage).
receive = function(name, _, from, port, _, data)
  if name == "component_added" or name == "component_removed" then reportComponents() return end
  if name ~= "modem_message" or noteControl(port, data) then return end
  if port ~= PORT or type(data) ~= "string" then return end
  local payload = reassemble(from, data)
  local msg = payload and deserialize(payload)
  if type(msg) ~= "table" or msg.from ~= from then return end
  if msg.to ~= nil and msg.to ~= nodeId then return end
  if msg.type == "PING" then
    send({type = "PONG", from = nodeId, to = msg.from, id = msg.id})
    return
  end
  -- Everything else runs code or touches hardware on this node, so it's
  -- only accepted from the kernal itself, never from a peer.
  if from ~= kernalAddr then return end
  if msg.type == "RESULT" or msg.type == "ERROR" then
    if rpcWaiting[msg.id] then rpcReplies[msg.id] = msg end
    return
  end
  handleMessage(msg)
end

local function satisfied(w)
  if w.cooperate then return true end
  if w.rpc and rpcReplies[w.rpc] then return true end
  if w.events then
    local q = eventQueues[w.events]
    if q and #q > 0 then return true end
  end
  return w.deadline ~= nil and computer.uptime() >= w.deadline
end

-- Waits for condition `w` ({deadline}, {rpc}, {events = process id},
-- COOPERATE). A process yields it to the scheduler. Anywhere else (the
-- scheduler itself finishing a process, or a coroutine a program made
-- for itself) it waits right here, receiving meanwhile -- other
-- processes on the node don't run until it's done.
local function wait(w)
  if current and coroutine.running() == current.co then
    coroutine.yield(WAIT, w)
    return
  end
  repeat
    local timeout = nil
    if w.cooperate then
      timeout = 0
    elseif w.deadline then
      timeout = math.max(0, w.deadline - computer.uptime())
    end
    receive(computer.pullSignal(timeout))
  until w.cooperate or satisfied(w)
end

-- Announce ourselves so the kernal can pick up our HELLO (it already
-- knows kernalAddr from the boot handshake above, so this is purely
-- for the kernal's own discovery bookkeeping, not for learning
-- anything on our end).
send({type = "HELLO", from = nodeId})
reportComponents()

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
  -- RPC ids are this node's own counter; the kernal's JOB ids are a
  -- different counter, but only RESULT/ERROR count as replies.
  rpcWaiting[id] = true
  local w = {rpc = id, deadline = computer.uptime() + RPC_TIMEOUT}
  while not satisfied(w) do wait(w) end
  rpcWaiting[id] = nil
  local reply = rpcReplies[id]
  rpcReplies[id] = nil
  if not reply then return nil, "timed out waiting for kernal" end
  if reply.type == "RESULT" then return reply.result end
  return nil, reply.error
end

-- id -> function(force): pushes a legacy process's virtual gpu changes
-- to its window (see "Legacy virtual components"). Called wherever
-- output is flushed; `force` before the process blocks, otherwise it's
-- rate-limited.
local graphicsFlushers = {}
-- id -> function(ok, result), run when the job ends (a legacy program
-- writes its error into its own window).
local jobEndHooks = {}

local function flushOutput(id, force)
  local buf = outputBuffers[id]
  if buf and #buf > 0 and kernalAddr then
    outputBuffers[id] = nil
    send({type = "OUTPUT", from = nodeId, to = kernalAddr, jobId = id, text = table.concat(buf)})
  end
  local flushGraphics = graphicsFlushers[id]
  if flushGraphics then flushGraphics(force) end
end

local function writeOutput(id, text)
  local buf = outputBuffers[id]
  if not buf then buf = {n = 0}; outputBuffers[id] = buf end
  buf[#buf + 1] = text
  buf.n = buf.n + #text
  if buf.n >= OUTPUT_FLUSH_AT then flushOutput(id) end
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
  -- table.pack/`n` on both legs: a nil in the middle of the arguments or
  -- the results (a component's `nil, "reason"` failure return, say)
  -- must stay in place, not shift the values after it left.
  local results, err = remoteInvoke(remoteGpuAddr, method, table.pack(...))
  if err then return nil, err end
  results = results or {}
  return table.unpack(results, 1, results.n or #results)
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

-- The process being resumed right now (the scheduler sets it), so
-- gmuxapi calls can tell the kernal "I am job X" -- e.g. as the parent
-- when asking for a child. The job itself sees its own id as
-- `jobId` in its process environment.
local currentJobId = nil

-- --- Cluster component bus: the client side ---
--
-- What a process's `component` sees: every node's components (the
-- kernal's registry, BUSLIST, cached for BUS_LIST_TTL), called directly
-- when they're on this node and through the kernal (BUSINVOKE) when not.
-- A returned value that can't cross the wire comes back as a proxy whose
-- methods are VALUECALLs to the node holding it.
local BUS_LIST_TTL = 1
local busCache, busCacheAt = nil, -math.huge

local function busList()
  if busCache and computer.uptime() - busCacheAt < BUS_LIST_TTL then return busCache end
  local list = remoteRequest("BUSLIST", {caller = currentJobId})
  if type(list) ~= "table" then return busCache or {} end
  busCache, busCacheAt = list, computer.uptime()
  return list
end

local importValues

local function valueProxy(ref)
  return setmetatable({}, {__index = function(_, method)
    return function(...)
      local reply, err = remoteRequest("VALUECALL", {node = ref.node, value = ref.__busValue, method = method,
        args = table.pack(...), caller = currentJobId})
      if not reply then error(err, 2) end
      return importValues(reply)
    end
  end})
end

importValues = function(results)
  results = type(results) == "table" and results or {n = 0}
  local n = results.n or #results
  for i = 1, n do
    local v = results[i]
    if type(v) == "table" and v.__busValue then results[i] = valueProxy(v) end
  end
  return table.unpack(results, 1, n)
end

local function busInvoke(addr, method, ...)
  local ok, localType = pcall(component.type, addr)
  if ok and localType and not BUS_EXCLUDED[localType] then return component.invoke(addr, method, ...) end
  local reply, err = remoteRequest("BUSINVOKE", {address = addr, method = method, args = table.pack(...),
    caller = currentJobId})
  if not reply then error(err, 2) end
  return importValues(reply)
end

-- OpenOS's `component` API over the bus. `extra()`, if given, returns
-- address -> device for devices that aren't on the bus (a legacy
-- program's virtual gpu/screen/keyboard); they come first for "primary",
-- then this node's own components, then the rest of the cluster's.
local function newBusComponentFace(extra)
  local proxies = {}
  local function busProxy(addr, info)
    local p = proxies[addr]
    if p and p.type == info.type then return p end
    local methods = info.methods
    p = setmetatable({address = addr, type = info.type, slot = -1}, {__index = function(_, m)
      if type(methods) == "table" and next(methods) ~= nil and methods[m] == nil then return nil end
      return function(...) return busInvoke(addr, m, ...) end
    end})
    proxies[addr] = p
    return p
  end
  local function devices()
    local all = {}
    for addr, info in pairs(busList()) do all[addr] = {type = info.type, node = info.node, info = info} end
    for addr, dev in pairs(extra and extra() or {}) do all[addr] = {type = dev.type, device = dev} end
    return all
  end
  local function deviceOf(entry, addr) return entry.device or busProxy(addr, entry.info) end
  local function primary(kind)
    local all, bestRank, bestAddr = devices(), nil, nil
    for addr, e in pairs(all) do
      if e.type == kind then
        local rank = e.device and 0 or (e.node == nodeId and 1 or 2)
        if not bestRank or rank < bestRank or (rank == bestRank and addr < bestAddr) then
          bestRank, bestAddr = rank, addr
        end
      end
    end
    return bestAddr and deviceOf(all[bestAddr], bestAddr)
  end
  local face = {}
  function face.list(filter, exact)
    local found = {}
    for addr, e in pairs(devices()) do
      if filter == nil or (exact and e.type == filter) or (not exact and e.type:find(filter, 1, true)) then
        found[addr] = e.type
      end
    end
    local key
    return setmetatable(found, {__call = function()
      key = next(found, key)
      if key then return key, found[key] end
    end})
  end
  function face.proxy(addr)
    local e = devices()[addr]
    if not e then return nil, "no such component" end
    return deviceOf(e, addr)
  end
  function face.invoke(addr, method, ...)
    local dev = face.proxy(addr)
    if not dev then error("no such component", 2) end
    local fn = dev[method]
    if type(fn) ~= "function" then error("no such method", 2) end
    return fn(...)
  end
  function face.type(addr)
    local e = devices()[addr]
    if not e then return nil, "no such component" end
    return e.type
  end
  function face.slot(addr)
    if not devices()[addr] then return nil, "no such component" end
    return -1
  end
  function face.methods(addr)
    local e = devices()[addr]
    if not e then return nil, "no such component" end
    if e.info then return e.info.methods or {} end
    local methods = {}
    for k, f in pairs(e.device) do if type(f) == "function" then methods[k] = true end end
    return methods
  end
  function face.fields() return {} end
  function face.doc() return nil end
  function face.isAvailable(kind) return primary(kind) ~= nil end
  function face.getPrimary(kind)
    local dev = primary(kind)
    if not dev then error("no primary '" .. tostring(kind) .. "' available", 2) end
    return dev
  end
  function face.setPrimary() end
  return setmetatable(face, {__index = function(_, kind)
    local dev = primary(kind)
    if not dev then error("no primary '" .. tostring(kind) .. "' available", 2) end
    return dev
  end})
end

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
  -- Summaries only (no source or result); get_process(id) for one job
  -- in full.
  get_processes = function()
    return remoteRequest("GETPROCESSES")
  end,

  get_process = function(id)
    return remoteRequest("GETPROCESS", {jobId = id})
  end,

  -- gmux's create_headless_process(options) takes options.main (a
  -- function) or options.main_path (a dofile path); neither can cross
  -- the network, so this takes options.code (a Lua source string, same
  -- convention as a JOB) instead. Fire-and-forget, like gmux's own
  -- version: returns {process = {id, node}} immediately, not the result.
  --
  -- The parent (this node's currently-running job, see above)
  -- is always included automatically -- the calling job never needs to
  -- know or supply its own id for this to work. `options.orphan_policy`
  -- ("orphan" (default) / "kill" / "promote") and `options.name` (the
  -- app identity used for reclaim) implement the parent/child model
  -- documented in docs/PROTOCOL.md's ".mxe process model" -- see there
  -- for the full semantics; this is purely wire plumbing.
  create_headless_process = function(options)
    options = options or {}
    if not options.code then
      return nil, "create_headless_process needs options.code (a Lua source string)"
    end
    local result, err = remoteRequest("SPAWN", {code = options.code, args = options.args, node = options.node,
      parent = currentJobId, appName = options.name, orphanPolicy = options.orphan_policy})
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
    local proc, procErr = remoteRequest("SPAWN", {code = options.code, args = options.args, node = options.node,
      parent = currentJobId, appName = options.name, orphanPolicy = options.orphan_policy})
    if not proc then return nil, procErr end
    -- `ownerJobId = proc.id` links this window to the job it was just
    -- created FOR, not to whichever node happened to make this
    -- CREATEWINDOW request (this call itself can run on a totally
    -- different node than the child it just spawned). This is the one
    -- piece of scaffolding focus-based keyboard delivery actually
    -- needs from this call: given a focused window, the kernal can
    -- look up its ownerJobId and, from there, jobs[ownerJobId].node --
    -- no separate bookkeeping required. See kernal/compositor.lua's
    -- M.setFocus/M.getFocus for the tracking side of this.
    local win, winErr = remoteRequest("CREATEWINDOW", {
      title = options.name, x = options.x, y = options.y, width = options.width, height = options.height,
      resizable = options.resizable, decorated = options.title_bar, ownerJobId = proc.id,
      caller = currentJobId,
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
    -- pixels/mode/bg make this a "bit window" (see kernal/bitmap.lua):
    -- a 2D pixel grid encoded into half-block or braille sub-cell
    -- characters instead of running `code` -- OC's GPUs have no pixel
    -- API, so this is the only way to get anything bitmap-like.
    return remoteRequest("CREATEWINDOW", {
      title = options.title, x = options.x, y = options.y,
      width = options.width, height = options.height, code = options.code,
      pixels = options.pixels, mode = options.mode, bg = options.bg, args = options.args,
      resizable = options.resizable, decorated = options.title_bar, caller = currentJobId,
    })
  end,

  -- Redraw a window this process owns (or one owned by a descendant):
  -- `options.code` (+ `options.args`, visible to the code as `args`),
  -- and/or `options.pixels`/`mode`/`width`/`height` like create_window;
  -- `options.clear = false` draws over the existing content instead of
  -- blanking it first. Same sandbox as create_window.
  draw_window = function(id, options)
    options = options or {}
    return remoteRequest("DRAWWINDOW", {windowId = id, code = options.code, args = options.args,
      pixels = options.pixels, mode = options.mode, width = options.width, height = options.height,
      bg = options.bg, clear = options.clear, caller = currentJobId})
  end,

  get_windows = function()
    return remoteRequest("GETWINDOWS")
  end,

  -- Not part of gmux's real API at all -- gmux never needs this,
  -- because its apps already share the host process's real gpu/screen
  -- directly. Added here because `gpu`'s remote fallback (above) and
  -- the kernal's generic INVOKE bridge both go through the compositor's
  -- gatekeeping now (kernal/compositor.lua, kernal/muxos.lua's
  -- handleInvoke): direct gpu/screen access from a worker is blocked by
  -- default, and this is how a node gets let through it, for the one
  -- legitimate case where bypassing the compositor's buffer/blit
  -- indirection is the point -- a fullscreen app that wants to own the
  -- whole display. First-come-first-served, one holder at a time; NOT
  -- released automatically if the holder disappears (reboots, crashes).
  request_fullscreen = function()
    return remoteRequest("REQUESTFULLSCREEN")
  end,

  release_fullscreen = function()
    return remoteRequest("RELEASEFULLSCREEN")
  end,

  -- Hands back the still-unclaimed orphan handles (each {id, node})
  -- registered under `name` -- the mechanism a relaunched app uses to
  -- pick up where its last instance's "orphan"-policy children left
  -- off. Claimed once: the kernal removes them from its own pool the
  -- moment this returns them, so a second call returns an empty list
  -- until new orphans accumulate under that name. See
  -- docs/PROTOCOL.md's "App identity and orphan reclaim".
  get_orphans = function(name)
    return remoteRequest("GETORPHANS", {appName = name})
  end,

  -- The next input event the kernal routed to this process (keyboard
  -- events while one of its windows has focus), or nil after `timeout`
  -- seconds (nil timeout: wait indefinitely). Events come back as
  -- {name, ...} lists, e.g. {"key_down", char, code}.
  pull_event = function(timeout)
    local id = currentJobId
    flushOutput(id, true)
    local w = {events = id, deadline = timeout and (computer.uptime() + timeout)}
    while true do
      local q = eventQueues[id]
      if q and #q > 0 then return table.remove(q, 1) end
      if w.deadline and computer.uptime() >= w.deadline then return nil end
      wait(w)
    end
  end,

  -- Launch a program (name or path, like typing it at the console); the
  -- calling process becomes its parent. Returns {id, node, path}.
  launch = function(program, args)
    return remoteRequest("LAUNCH", {path = program, args = args, caller = currentJobId})
  end,

  -- Pause, resume, or end one of this process's own descendants. The
  -- kernal refuses anything else.
  pause_process = function(id) return remoteRequest("CONTROL", {jobId = id, verb = "PAUSE", caller = currentJobId}) end,
  resume_process = function(id) return remoteRequest("CONTROL", {jobId = id, verb = "RESUME", caller = currentJobId}) end,
  kill_process = function(id) return remoteRequest("CONTROL", {jobId = id, verb = "KILL", caller = currentJobId}) end,
}

-- Long-running jobs. OpenComputers ends any coroutine that runs longer
-- than system.timeout() (5s by default) without the machine getting a
-- yield -- the sandbox's coroutine.resume enforces it on every
-- coroutine. A process runs in its own coroutine, so one that never
-- yields is ended that way and comes back as an ordinary ERROR; the node
-- survives. There's no preemption (no debug.sethook in the sandbox), so
-- until it yields, nothing else on its node runs either.
--
-- `yield()` is how a long computation cooperates: the scheduler runs the
-- node's other processes and handles what arrived, then resumes it.
-- `sleep(seconds)` waits, letting everything else run meanwhile.
function yield()
  wait(COOPERATE)
end

function sleep(seconds)
  if currentJobId then flushOutput(currentJobId, true) end
  local w = {deadline = computer.uptime() + (seconds or 0)}
  repeat wait(w) until computer.uptime() >= w.deadline
end

local KILLED = "killed"
-- A process's end when it handed over its state to move.
local MIGRATED = {}

-- Acts on a MIGRATE control at a yield point: calls the process's save
-- function and, if it produced state that can cross the wire, returns
-- it (the process then ends here and restarts on another node).
-- Otherwise tells the kernal why and lets the process carry on.
local function tryMigrate(id)
  controlState[id] = nil
  local save = migrationHandlers[id]
  local reason
  if not save then
    reason = "it never called mux.migratable"
  else
    local ok, state = pcall(save)
    if ok then
      local fine, err = pcall(serialize, state)
      if fine then return true, state end
      reason = "its state can't be sent: " .. tostring(err)
    else
      reason = "its save function failed: " .. tostring(state)
    end
  end
  send({type = "MIGRATEFAILED", from = nodeId, to = kernalAddr, jobId = id, error = reason})
  return false
end

-- --- Process environments ---
--
-- Every process gets its own environment table, so one program's
-- globals never leak into another's on the same node. What it can see
-- through it (read-only) is the native API: the standard libraries,
-- yield/sleep, gpu, gmuxapi, and a computer subset. Deliberately absent:
-- `debug` (a process could remove its own instruction budget with it)
-- and raw `component` (an .mxe makes kernel calls rather than driving
-- hardware itself). `load` defaults to the process's own environment so
-- code it loads can't reach this file's globals.
local function readOnly(t, name)
  return setmetatable({}, {
    __index = t,
    __newindex = function() error(name .. " is read-only", 2) end,
  })
end

local NATIVE = {}
for _, k in ipairs({"assert", "error", "ipairs", "next", "pairs", "pcall", "rawequal", "rawget",
    "rawlen", "rawset", "select", "setmetatable", "getmetatable", "tonumber", "tostring", "type", "xpcall"}) do
  NATIVE[k] = _ENV[k]
end
for _, lib in ipairs({"string", "table", "math", "utf8", "coroutine"}) do
  if _ENV[lib] then NATIVE[lib] = readOnly(_ENV[lib], lib) end
end
NATIVE.computer = readOnly({uptime = computer.uptime, address = computer.address}, "computer")
NATIVE.gpu = gpu
-- A native process's (and an .mxe's) view of hardware: the whole
-- cluster's components, over the bus -- open visibility, minus what the
-- kernal keeps to itself (display, network, firmware).
NATIVE.component = readOnly(newBusComponentFace(nil), "component")
NATIVE.gmuxapi = readOnly(gmuxapi, "gmuxapi")
NATIVE.yield = yield
NATIVE.sleep = sleep
NATIVE.muxos = readOnly({version = MUXOS_VERSION}, "muxos")

local function printTo(id)
  return function(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do parts[i] = tostring((select(i, ...))) end
    writeOutput(id, table.concat(parts, "\t") .. "\n")
  end
end

local function newProcessEnv(id)
  local env = setmetatable({jobId = id, print = printTo(id)}, {__index = NATIVE})
  env._G = env
  env.load = function(chunk, name, mode, e) return load(chunk, name, mode, e or env) end
  return env
end

-- An .mxe: the native environment, plus the launcher's response
-- (`launch`) and `require` for the libraries it asked for and was
-- granted. Libraries are loaded into the process's own environment.
-- Libraries built into the runtime (the kernal ships `true` for them
-- instead of source). `mux` is migration: mux.migratable(save) opts the
-- process in -- `save` returns a state table whenever the kernal moves
-- it -- and mux.restored() returns that state after a move (nil on a
-- fresh start).
local BUILTIN_LIBRARIES = {
  mux = function(id, restored)
    return {
      migratable = function(save)
        if type(save) ~= "function" then error("mux.migratable needs a function returning a state table", 2) end
        migrationHandlers[id] = save
        send({type = "MIGRATABLE", from = nodeId, to = kernalAddr, jobId = id})
      end,
      restored = function() return restored end,
      -- OpenOS's shell.parse rules: -abc, --name, --name=value; "--"
      -- ends options; everything else is positional.
      parseArgs = function(...)
        local args, options, ended = {}, {}, false
        for i = 1, select("#", ...) do
          local a = tostring((select(i, ...)))
          if ended or a == "-" or a:sub(1, 1) ~= "-" then
            args[#args + 1] = a
          elseif a == "--" then
            ended = true
          elseif a:sub(1, 2) == "--" then
            local k, v = a:match("^%-%-([^=]+)=(.*)$")
            if k then options[k] = v else options[a:sub(3)] = true end
          else
            for c in a:sub(2):gmatch(".") do options[c] = true end
          end
        end
        return args, options
      end,
    }
  end,
  -- HTTP over whichever internet card the bus offers, this node's first
  -- (docs/MXE.md section 7.6).
  http = function()
    local function card()
      if not NATIVE.component.isAvailable("internet") then error("there's no internet card in the cluster", 3) end
      return NATIVE.component.getPrimary("internet")
    end
    local function encode(data)
      if type(data) ~= "table" then return data end
      local parts = {}
      for k, v in pairs(data) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
      table.sort(parts)
      return table.concat(parts, "&")
    end
    local http = {}
    -- A streaming handle: finishConnect(), response() -> status, message,
    -- headers, read([n]) -> data or nil at the end, close().
    function http.request(url, data, headers, method)
      if type(url) ~= "string" then error("bad argument #1 (string expected)", 2) end
      local req, reason = card().request(url, encode(data), headers, method)
      if not req then return nil, reason end
      local h = {}
      function h.finishConnect() return req.finishConnect() end
      function h.response() return req.response() end
      function h.close() return req.close() end
      function h.read(n)
        while true do
          local d, err = req.read(n)
          if d == nil then return nil, err end
          if #d > 0 then return d end
          sleep(0.05)
        end
      end
      return h
    end
    -- The whole body: body, status, headers -- or nil, error.
    function http.get(url, headers, timeout)
      local h, err = http.request(url, nil, headers)
      if not h then return nil, err end
      local ok, result = pcall(function()
        local deadline = computer.uptime() + (timeout or 30)
        while true do
          local connected, reason = h.finishConnect()
          if connected then break end
          if connected == nil then error(reason or "connection failed", 0) end
          if computer.uptime() > deadline then error("timed out connecting to " .. url, 0) end
          sleep(0.05)
        end
        local parts = {}
        while true do
          local d, readErr = h.read(65536)
          if not d then
            if readErr then error(readErr, 0) end
            break
          end
          parts[#parts + 1] = d
        end
        local status, _, responseHeaders = h.response()
        return {table.concat(parts), status, responseHeaders}
      end)
      pcall(h.close)
      if not ok then return nil, tostring(result) end
      return result[1], result[2], result[3]
    end
    return http
  end,
}

local function newMxeEnv(id, program, restored)
  local env = newProcessEnv(id)
  local launch = program.launch or {libraries = {}}
  launch.errors = {}
  env.launch = launch
  local loaded = {}
  env.require = function(name)
    local value = loaded[name]
    if value == nil then error("library '" .. tostring(name) .. "' wasn't granted at launch", 2) end
    return value
  end
  -- Dependencies first (program.libOrder, from the launcher).
  local order = program.libOrder
  if type(order) ~= "table" then
    order = {}
    for name in pairs(program.libs or {}) do order[#order + 1] = name end
  end
  local function loadLibraries()
    for _, name in ipairs(order) do
      local source = (program.libs or {})[name]
      if source == true and BUILTIN_LIBRARIES[name] then
        loaded[name] = BUILTIN_LIBRARIES[name](id, restored)
        goto continue
      end
      local fn, err = nil, "library source missing"
      if type(source) == "string" then fn, err = load(source, "=lib:" .. name, "t", env) end
      local ok, value = false, err
      if fn then ok, value = pcall(fn) end
      if ok then
        loaded[name] = value == nil and true or value
      else
        launch.libraries[name] = false
        launch.errors[name] = tostring(value)
      end
      ::continue::
    end
  end
  return env, loadLibraries
end

-- A .lua program: the OpenOS environment -- the standard libraries,
-- print/io/os, checkArg, and OpenOS's `require`; nothing muxos-specific
-- (no gmuxapi; parent/child processes are an .mxe concept).
--
-- `require` works like OpenOS's, with a per-process package.loaded.
-- Machine-level modules are faces built in here (LEGACY_FACES); every
-- other module is a file on the kernal's disk (/lib, /usr/lib -- the
-- vendored OpenOS libraries and whatever else is installed), either
-- shipped with the program (the ones it requires by a literal name) or
-- fetched with GETMODULE. See kernal/lib/README.md.
local EXIT = {}

-- OpenOS's checkArg (a global there, from machine.lua).
local function checkArg(n, have, ...)
  have = type(have)
  for i = 1, select("#", ...) do
    if have == select(i, ...) then return end
  end
  error(string.format("bad argument #%d (%s expected, got %s)", n, table.concat({...}, " or "), have), 3)
end

-- The legacy virtual components' addresses (gmux's). OpenOS signals
-- carry the component's address.
local VGPU_ADDRESS = "virtual0-gpu0-0000-0000-component000"
local VSCREEN_ADDRESS = "virtual0-scre-en00-0000-component000"
local VKEYBOARD_ADDRESS = "virtual0-keyb-oard-0000-component000"

-- A muxos event ({name, ...}) in OpenOS's signal shape.
local function toSignal(e)
  local name = e[1]
  if name == "key_down" or name == "key_up" then
    return table.pack(name, VKEYBOARD_ADDRESS, e[2], e[3], "player")
  elseif name == "touch" or name == "drag" or name == "drop" or name == "scroll" then
    return table.pack(name, VSCREEN_ADDRESS, e[2], e[3], e[4], "player")
  end
  return table.pack(table.unpack(e, 1, e.n or #e))
end

-- The next signal for a legacy process (its own pushed ones first), or
-- nil after `timeout`. Keeps OpenOS's keyboard library's pressed-key
-- tables current and runs event.listen handlers, as OpenOS does.
local function legacyPull(ctx, timeout)
  local sig = table.remove(ctx.pushed, 1)
  if not sig then
    local e = gmuxapi.pull_event(timeout)
    if not e then return nil end
    sig = toSignal(e)
    -- A user resize of its window is a resolution change, as in gmux.
    if sig[1] == "window_resized" and ctx.vgpu and sig[2] == ctx.windowId then
      ctx.vgpu.resize(sig[3], sig[4])
      sig = table.pack("screen_resized", VSCREEN_ADDRESS, sig[3], sig[4])
    end
  end
  local kb = ctx.loaded.keyboard
  if type(kb) == "table" and type(kb.pressedCodes) == "table" then
    local down = sig[1] == "key_down" or nil
    if sig[1] == "key_down" or sig[1] == "key_up" then
      if sig[3] then kb.pressedChars[sig[3]] = down end
      if sig[4] then kb.pressedCodes[sig[4]] = down end
    end
  end
  local handlers = ctx.listeners[sig[1]]
  if handlers then
    for _, handler in ipairs({table.unpack(handlers)}) do
      local ok, keep = pcall(handler, table.unpack(sig, 1, sig.n))
      if not ok then
        writeOutput(ctx.id, "event handler error: " .. tostring(keep) .. "\n")
      elseif keep == false then
        for i, h in ipairs(handlers) do
          if h == handler then table.remove(handlers, i) break end
        end
      end
    end
  end
  return sig
end

-- OpenOS's event filter: the name is a pattern, other arguments must be
-- equal where given.
local function signalMatches(sig, filter)
  local name = filter[1]
  if name ~= nil and not (type(sig[1]) == "string" and sig[1]:match(name)) then return false end
  for i = 2, filter.n or #filter do
    if filter[i] ~= nil and filter[i] ~= sig[i] then return false end
  end
  return true
end

local function pullMatching(ctx, timeout, accept)
  local deadline = timeout and computer.uptime() + timeout
  while true do
    local sig = legacyPull(ctx, deadline and math.max(0, deadline - computer.uptime()))
    if sig and accept(sig) then return table.unpack(sig, 1, sig.n) end
    if not sig or (deadline and computer.uptime() >= deadline) then return nil end
  end
end

local hostUnicode = unicode

-- --- Legacy virtual components, forked from gmux ---
--
-- gmux's virtual_components (gpu/screen/keyboard) draw into real gpu
-- buffers on the machine they run on. Workers have no gpu, so here the
-- virtual gpu keeps its screen and buffers as cell grids in memory,
-- with gmux's API, and its window lives on the kernal: created on the
-- first draw that reaches a flush (sized to the resolution, resizable),
-- then sent the rows that changed, as same-color runs, without waiting
-- for a reply. Flushes happen at the process's yield points -- always
-- before it blocks (sleep, waiting for input), at most every
-- GRAPHICS_FLUSH_INTERVAL otherwise. setResolution resizes the window;
-- the user resizing the window is a resolution change for the program
-- (screen_resized), as in gmux.
local VGPU_MAX_W, VGPU_MAX_H = 160, 50
local VGPU_MEMORY = VGPU_MAX_W * VGPU_MAX_H * 2 -- cells, for allocateBuffer
local GRAPHICS_FLUSH_INTERVAL = 0.05
-- Rows arrive as {y, x, fg, bg, text, x, fg, bg, text, ...}.
local WINDOW_DRAW_CODE = "for _, row in ipairs(args.rows) do local y = row[1] for i = 2, #row, 4 do " ..
  "gpu.setForeground(row[i + 1]) gpu.setBackground(row[i + 2]) gpu.set(row[i], y, row[i + 3]) end end"

local function newGrid(w, h, fg, bg)
  local g = {w = w, h = h, chars = {}, fgs = {}, bgs = {}}
  for y = 1, h do
    local c, f, b = {}, {}, {}
    for x = 1, w do c[x], f[x], b[x] = " ", fg, bg end
    g.chars[y], g.fgs[y], g.bgs[y] = c, f, b
  end
  return g
end

-- Copies a w x h block of `src` at (sx, sy) to `dst` at (dx, dy),
-- clipped to both (the two may be the same grid and overlap).
-- `onRow(y)` hears about each destination row written.
local function blit(dst, dx, dy, src, sx, sy, w, h, onRow)
  local snapC, snapF, snapB = {}, {}, {}
  for j = 0, h - 1 do
    local y = sy + j
    local cr, fr, br = src.chars[y], src.fgs[y], src.bgs[y]
    local c, f, b = {}, {}, {}
    if cr then
      for i = math.max(0, 1 - sx), math.min(w - 1, src.w - sx) do
        c[i], f[i], b[i] = cr[sx + i], fr[sx + i], br[sx + i]
      end
    end
    snapC[j], snapF[j], snapB[j] = c, f, b
  end
  for j = 0, h - 1 do
    local y = dy + j
    if y >= 1 and y <= dst.h then
      local cr, fr, br = dst.chars[y], dst.fgs[y], dst.bgs[y]
      local c, f, b = snapC[j], snapF[j], snapB[j]
      local wrote = false
      for i, ch in pairs(c) do
        local x = dx + i
        if x >= 1 and x <= dst.w then
          cr[x], fr[x], br[x] = ch, f[i], b[i]
          wrote = true
        end
      end
      if wrote and onRow then onRow(y) end
    end
  end
end

local function splitChars(value)
  local chars = {}
  if utf8.len(value) then
    for ch in value:gmatch(utf8.charpattern) do chars[#chars + 1] = ch end
  else
    for i = 1, #value do chars[i] = value:sub(i, i) end
  end
  return chars
end

local function newVirtualGpu(ctx, w, h)
  local palette = {}
  for i = 0, 15 do palette[i] = (i + 1) * 0x0F0F0F end
  local grids = {[0] = newGrid(w, h, 0xFFFFFF, 0x000000)}
  local nextBuffer, active = 1, 0
  local fg, bg, fgIndex, bgIndex = 0xFFFFFF, 0x000000, nil, nil
  local viewW, viewH = w, h
  local v = {dirtyRows = {}, dirty = false, lastFlush = -math.huge}

  local function touchRow(gridId, y)
    if gridId == 0 then
      v.dirtyRows[y] = true
      v.dirty = true
    end
  end
  local function onScreenRow(y) touchRow(0, y) end
  local function activeRowHook() return active == 0 and onScreenRow or nil end
  function v.grid() return grids[0] end
  function v.resize(nw, nh)
    local old = grids[0]
    local g = newGrid(nw, nh, 0xFFFFFF, 0x000000)
    blit(g, 1, 1, old, 1, 1, math.min(old.w, nw), math.min(old.h, nh))
    grids[0], viewW, viewH = g, nw, nh
    for y = 1, nh do v.dirtyRows[y] = true end
    v.dirty = true
  end
  local function usedMemory()
    local used = 0
    for id, g in pairs(grids) do
      if id ~= 0 then used = used + g.w * g.h end
    end
    return used
  end

  local gpu = {type = "gpu", address = VGPU_ADDRESS}
  function gpu.bind() return true end
  function gpu.getScreen() return VSCREEN_ADDRESS end
  function gpu.getForeground() return fgIndex or fg, fgIndex ~= nil end
  function gpu.getBackground() return bgIndex or bg, bgIndex ~= nil end
  function gpu.setForeground(color, isIndex)
    checkArg(1, color, "number")
    local old, oldIndex = fg, fgIndex
    if isIndex then fgIndex, fg = color, palette[color] or 0 else fgIndex, fg = nil, color end
    return old, oldIndex
  end
  function gpu.setBackground(color, isIndex)
    checkArg(1, color, "number")
    local old, oldIndex = bg, bgIndex
    if isIndex then bgIndex, bg = color, palette[color] or 0 else bgIndex, bg = nil, color end
    return old, oldIndex
  end
  function gpu.getPaletteColor(i) return palette[i] end
  function gpu.setPaletteColor(i, color)
    local old = palette[i]
    palette[i] = color
    return old
  end
  function gpu.maxDepth() return 8 end
  function gpu.getDepth() return 8 end
  function gpu.setDepth() return 8 end
  function gpu.maxResolution() return VGPU_MAX_W, VGPU_MAX_H end
  function gpu.getResolution() return grids[0].w, grids[0].h end
  function gpu.setResolution(nw, nh)
    checkArg(1, nw, "number")
    checkArg(2, nh, "number")
    nw, nh = math.floor(nw), math.floor(nh)
    if nw < 1 or nh < 1 or nw > VGPU_MAX_W or nh > VGPU_MAX_H then error("unsupported resolution", 2) end
    if nw == grids[0].w and nh == grids[0].h then return false end
    v.resize(nw, nh)
    ctx.pushed[#ctx.pushed + 1] = table.pack("screen_resized", VSCREEN_ADDRESS, nw, nh)
    return true
  end
  function gpu.getViewport() return viewW, viewH end
  function gpu.setViewport(vw, vh)
    if vw > grids[0].w or vh > grids[0].h then return false end
    viewW, viewH = vw, vh
    return true
  end
  function gpu.get(x, y)
    local g = grids[active]
    x, y = math.floor(x), math.floor(y)
    if x < 1 or y < 1 or x > g.w or y > g.h then error("index out of bounds", 2) end
    return g.chars[y][x], g.fgs[y][x], g.bgs[y][x], nil, nil
  end
  function gpu.set(x, y, value, vertical)
    checkArg(1, x, "number")
    checkArg(2, y, "number")
    checkArg(3, value, "string")
    local g = grids[active]
    x, y = math.floor(x), math.floor(y)
    local chars = splitChars(value)
    if vertical then
      if x >= 1 and x <= g.w then
        for i, ch in ipairs(chars) do
          local yy = y + i - 1
          if yy >= 1 and yy <= g.h then
            g.chars[yy][x], g.fgs[yy][x], g.bgs[yy][x] = ch, fg, bg
            touchRow(active, yy)
          end
        end
      end
    elseif y >= 1 and y <= g.h then
      local cr, fr, br = g.chars[y], g.fgs[y], g.bgs[y]
      for i = math.max(1, 2 - x), math.min(#chars, g.w - x + 1) do
        local xx = x + i - 1
        cr[xx], fr[xx], br[xx] = chars[i], fg, bg
      end
      touchRow(active, y)
    end
    return true
  end
  function gpu.fill(x, y, fw, fh, char)
    checkArg(5, char, "string")
    local chars = splitChars(char)
    if #chars ~= 1 then error("invalid fill value", 2) end
    local ch = chars[1]
    local g = grids[active]
    x, y, fw, fh = math.floor(x), math.floor(y), math.floor(fw), math.floor(fh)
    for yy = math.max(1, y), math.min(g.h, y + fh - 1) do
      local cr, fr, br = g.chars[yy], g.fgs[yy], g.bgs[yy]
      for xx = math.max(1, x), math.min(g.w, x + fw - 1) do
        cr[xx], fr[xx], br[xx] = ch, fg, bg
      end
      touchRow(active, yy)
    end
    return true
  end
  function gpu.copy(x, y, cw, ch, tx, ty)
    local g = grids[active]
    blit(g, x + tx, y + ty, g, x, y, cw, ch, activeRowHook())
    return true
  end
  function gpu.getActiveBuffer() return active end
  function gpu.setActiveBuffer(index)
    index = index or 0
    if not grids[index] then return nil, "invalid buffer index" end
    local old = active
    active = index
    return old
  end
  function gpu.buffers()
    local list = {}
    for id in pairs(grids) do if id ~= 0 then list[#list + 1] = id end end
    table.sort(list)
    return list
  end
  function gpu.allocateBuffer(bw, bh)
    bw, bh = math.floor(bw or grids[0].w), math.floor(bh or grids[0].h)
    if bw < 1 or bh < 1 then return nil, "invalid page dimensions: must be greater than zero" end
    if bw * bh > VGPU_MEMORY - usedMemory() then return nil, "not enough video memory" end
    local id = nextBuffer
    nextBuffer = nextBuffer + 1
    grids[id] = newGrid(bw, bh, 0xFFFFFF, 0x000000)
    return id
  end
  function gpu.freeBuffer(index)
    index = index or active
    if index == 0 or not grids[index] then return false end
    grids[index] = nil
    if active == index then active = 0 end
    return true
  end
  function gpu.freeAllBuffers()
    for id in pairs(grids) do if id ~= 0 then grids[id] = nil end end
    active = 0
  end
  function gpu.totalMemory() return VGPU_MEMORY end
  function gpu.freeMemory() return VGPU_MEMORY - usedMemory() end
  function gpu.getBufferSize(index)
    local g = grids[index or active]
    if not g then return nil, "invalid buffer index" end
    return g.w, g.h
  end
  function gpu.bitblt(dst, col, row, bw, bh, src, fromCol, fromRow)
    dst, src = dst or 0, src or active
    local d, sg = grids[dst], grids[src]
    if not d or not sg then return nil, "invalid buffer index" end
    blit(d, col or 1, row or 1, sg, fromCol or 1, fromRow or 1, bw or sg.w, bh or sg.h,
      dst == 0 and onScreenRow or nil)
    return true
  end
  v.proxy = gpu
  return v
end

-- Sends the virtual gpu's changed rows to the process's window,
-- creating the window on the first flush.
local function flushVirtualGpu(ctx, force)
  local v = ctx.vgpu
  -- `creating`: creating the window waits for the kernal, and the
  -- process's other flush points run meanwhile; they mustn't make a
  -- second one.
  if not v or not v.dirty or v.broken or v.creating then return end
  local now = computer.uptime()
  if not force and now - v.lastFlush < GRAPHICS_FLUSH_INTERVAL then return end
  local g = v.grid()
  if not ctx.windowId then
    v.creating = true
    local win, err = remoteRequest("CREATEWINDOW", {title = ctx.name, width = g.w, height = g.h,
      resizable = true, caller = ctx.id})
    v.creating = nil
    g = v.grid() -- the resolution may have changed meanwhile
    if not win then
      v.broken = true
      writeOutput(ctx.id, "no window for gpu output: " .. tostring(err) .. "\n")
      return
    end
    ctx.windowId = win.id
  end
  local rows = {}
  for y in pairs(v.dirtyRows) do
    if y <= g.h then
      local cr, fr, br = g.chars[y], g.fgs[y], g.bgs[y]
      local row = {y}
      local x = 1
      while x <= g.w do
        local f, b, start = fr[x], br[x], x
        local text = {}
        while x <= g.w and fr[x] == f and br[x] == b do
          text[#text + 1] = cr[x]
          x = x + 1
        end
        local n = #row
        row[n + 1], row[n + 2], row[n + 3], row[n + 4] = start, f, b, table.concat(text)
      end
      rows[#rows + 1] = row
    end
  end
  v.dirtyRows, v.dirty, v.lastFlush = {}, false, now
  send({type = "DRAWWINDOW", from = nodeId, to = kernalAddr, id = nextId(), windowId = ctx.windowId,
    code = WINDOW_DRAW_CODE, args = {rows = rows}, clear = false, width = g.w, height = g.h,
    caller = ctx.id, noReply = true})
end

-- The process's virtual gpu, screen and keyboard: address -> proxy.
local function virtualDevices(ctx)
  if ctx.devices then return ctx.devices end
  local size = ctx.screenSize or {}
  local v = newVirtualGpu(ctx, math.min(80, size[1] or 80), math.min(25, (size[2] or 26) - 1))
  ctx.vgpu = v
  graphicsFlushers[ctx.id] = function(force) flushVirtualGpu(ctx, force) end
  local isOn, precise, inverted = true, false, false
  local screen = {
    type = "screen", address = VSCREEN_ADDRESS,
    isOn = function() return isOn end,
    turnOn = function() local was = isOn isOn = true return not was end,
    turnOff = function() local was = isOn isOn = false return was end,
    getAspectRatio = function() return 1, 1 end,
    getKeyboards = function() return {VKEYBOARD_ADDRESS} end,
    isPrecise = function() return precise end,
    setPrecise = function(p) precise = p end,
    isTouchModeInverted = function() return inverted end,
    setTouchModeInverted = function(i) inverted = i end,
  }
  local keyboard = {type = "keyboard", address = VKEYBOARD_ADDRESS}
  ctx.devices = {[VGPU_ADDRESS] = v.proxy, [VSCREEN_ADDRESS] = screen, [VKEYBOARD_ADDRESS] = keyboard}
  -- The kernal's disk, the OS filesystem (see "Legacy filesystem").
  if ctx.fsAddress then
    local fsProxy = {type = "filesystem", address = ctx.fsAddress}
    for _, op in ipairs({"exists", "isDirectory", "size", "lastModified", "list", "makeDirectory", "remove",
        "rename", "spaceUsed", "spaceTotal", "isReadOnly", "getLabel", "open", "read", "write", "seek", "close"}) do
      fsProxy[op] = function(...) return ctx.fsCall(op, ...) end
    end
    ctx.devices[ctx.fsAddress] = fsProxy
  end
  return ctx.devices
end

-- A legacy program's terminal, drawn on its virtual gpu like gmux's tty:
-- print/io.write/term output wraps and scrolls in its own window, and
-- io.read/term.read echo there.
local function newTerminal(ctx)
  local t = {x = 1, y = 1}
  local function gpu() return virtualDevices(ctx)[VGPU_ADDRESS] end
  local function newline()
    local g = gpu()
    local w, h = g.getResolution()
    t.x = 1
    if t.y < h then
      t.y = t.y + 1
    else
      g.copy(1, 2, w, h - 1, 0, -1)
      g.fill(1, h, w, 1, " ")
    end
  end
  function t.write(value)
    local g = gpu()
    local w, h = g.getResolution()
    t.y = math.min(t.y, h)
    for piece, ctl in tostring(value):gmatch("([^\n\r\t]*)([\n\r\t]?)") do
      local chars = splitChars(piece)
      local i = 1
      while i <= #chars do
        if t.x > w then newline() end
        local n = math.min(#chars - i + 1, w - t.x + 1)
        g.set(t.x, t.y, table.concat(chars, "", i, i + n - 1))
        t.x, i = t.x + n, i + n
      end
      if ctl == "\n" then
        newline()
      elseif ctl == "\r" then
        t.x = 1
      elseif ctl == "\t" then
        t.write(string.rep(" ", 8 - (t.x - 1) % 8))
      end
    end
  end
  function t.clear()
    local g = gpu()
    local w, h = g.getResolution()
    g.fill(1, 1, w, h, " ")
    t.x, t.y = 1, 1
  end
  function t.clearLine()
    local g = gpu()
    g.fill(1, t.y, (g.getResolution()), 1, " ")
    t.x = 1
  end
  -- Draws (or erases) the input cursor at the current position.
  function t.cursor(on)
    local g = gpu()
    local w, h = g.getResolution()
    if t.x <= w and t.y <= h then g.set(t.x, t.y, on and "_" or " ") end
  end
  function t.back()
    if t.x > 1 then
      t.x = t.x - 1
    elseif t.y > 1 then
      t.x, t.y = (gpu().getResolution()), t.y - 1
    end
    t.cursor(false)
  end
  return t
end

-- One line of keyboard input, echoed in the program's window.
local function legacyReadLine(ctx)
  local term = ctx.term
  local chars = {}
  term.cursor(true)
  while true do
    local sig = legacyPull(ctx)
    if sig and sig[1] == "key_down" then
      local char, code = sig[3], sig[4]
      if code == 28 then
        term.cursor(false)
        term.write("\n")
        return table.concat(chars)
      elseif code == 14 then
        if #chars > 0 then
          chars[#chars] = nil
          term.cursor(false)
          term.back()
          term.cursor(true)
        end
      elseif char and char >= 32 then
        local ok, ch = pcall(utf8.char, char)
        if ok then
          chars[#chars + 1] = ch
          term.write(ch)
          term.cursor(true)
        end
      end
    end
  end
end

-- --- Legacy filesystem ---
--
-- Like a gmux app, a legacy program uses the OS's own filesystem: the
-- kernal's disk, through FS requests (kernal/muxos.lua's handleFs). The
-- `filesystem` face is OpenOS's API (paths are from the root);
-- io.open/io.lines/loadfile/dofile resolve relative paths against PWD,
-- as OpenOS's shell does. Files are buffered here: reads fetch
-- FS_READ_CHUNK at a time, writes go out past FS_WRITE_CHUNK or on
-- flush/seek/close.
local FS_READ_CHUNK = 16384
local FS_WRITE_CHUNK = 4096

local function pathSegments(path)
  local parts = {}
  for part in path:gmatch("[^/\\]+") do
    if part == ".." then
      parts[#parts] = nil
    elseif part ~= "." then
      parts[#parts + 1] = part
    end
  end
  return parts
end

local function rootPath(path)
  return "/" .. table.concat(pathSegments(path), "/")
end

local function newFileStream(ctx, handle)
  local f = {}
  local rbuf, wbuf, wsize, closed = "", {}, 0, false
  local function flushWrites()
    if wsize > 0 then
      local data = table.concat(wbuf)
      wbuf, wsize = {}, 0
      return ctx.fsCall("write", handle, data)
    end
    return true
  end
  local function fill()
    local data = ctx.fsCall("read", handle, FS_READ_CHUNK)
    if type(data) ~= "string" then return false end
    rbuf = rbuf .. data
    return true
  end
  local function readLine(keep)
    while true do
      local i = rbuf:find("\n", 1, true)
      if i then
        local line = rbuf:sub(1, keep and i or i - 1)
        rbuf = rbuf:sub(i + 1)
        return line
      end
      if not fill() then
        if rbuf == "" then return nil end
        local line = rbuf
        rbuf = ""
        return line
      end
    end
  end
  local function readOne(fmt)
    if type(fmt) == "number" then
      while #rbuf < fmt and fill() do end
      if rbuf == "" and fmt > 0 then return nil end
      local data = rbuf:sub(1, fmt)
      rbuf = rbuf:sub(fmt + 1)
      return data
    end
    fmt = tostring(fmt):gsub("^%*", ""):sub(1, 1)
    if fmt == "a" then
      while fill() do end
      local data = rbuf
      rbuf = ""
      return data
    elseif fmt == "n" then
      while not rbuf:find("%S%s") and fill() do end
      local num, rest = rbuf:match("^%s*(%S+)(.*)$")
      rbuf = rest or ""
      return tonumber(num)
    end
    return readLine(fmt == "L")
  end
  function f:read(...)
    if closed then return nil, "file is closed" end
    local n = select("#", ...)
    if n == 0 then return readOne("l") end
    local out = {}
    for i = 1, n do
      out[i] = readOne((select(i, ...)))
      if out[i] == nil then return table.unpack(out, 1, i) end
    end
    return table.unpack(out, 1, n)
  end
  function f:lines(fmt)
    return function() return f:read(fmt or "l") end
  end
  function f:write(...)
    if closed then return nil, "file is closed" end
    for i = 1, select("#", ...) do
      local data = tostring((select(i, ...)))
      wbuf[#wbuf + 1] = data
      wsize = wsize + #data
    end
    if wsize >= FS_WRITE_CHUNK then
      local ok, err = flushWrites()
      if not ok then return nil, err end
    end
    return self
  end
  function f:flush()
    flushWrites()
    return self
  end
  function f:seek(whence, offset)
    flushWrites()
    whence, offset = whence or "cur", offset or 0
    if whence == "cur" then offset = offset - #rbuf end
    rbuf = ""
    return ctx.fsCall("seek", handle, whence, offset)
  end
  function f:close()
    if closed then return nil, "file is closed" end
    flushWrites()
    closed = true
    return ctx.fsCall("close", handle)
  end
  function f:setvbuf() return true end
  return f
end

-- Opens `path` (already resolved) as a buffered stream.
local function openFile(ctx, path, mode)
  mode = (mode or "r"):gsub("[b+]", "")
  local handle, err = ctx.fsCall("open", path, mode)
  if not handle then return nil, err or (path .. ": no such file or directory") end
  return newFileStream(ctx, handle)
end

local function newFilesystemFace(ctx)
  local fs = {}
  local call = ctx.fsCall
  function fs.canonical(path)
    local result = table.concat(pathSegments(path), "/")
    return path:sub(1, 1) == "/" and "/" .. result or result
  end
  function fs.concat(...) return fs.canonical(table.concat({...}, "/")) end
  function fs.segments(path) return pathSegments(path) end
  function fs.path(path)
    local parts = pathSegments(path)
    local result = table.concat(parts, "/", 1, #parts - 1) .. "/"
    return path:sub(1, 1) == "/" and "/" .. result or result
  end
  function fs.name(path)
    local parts = pathSegments(path)
    return parts[#parts]
  end
  function fs.realPath(path) return rootPath(path) end
  function fs.exists(path) return call("exists", rootPath(path)) == true end
  function fs.isDirectory(path) return call("isDirectory", rootPath(path)) == true end
  function fs.size(path) return call("size", rootPath(path)) or 0 end
  function fs.lastModified(path) return call("lastModified", rootPath(path)) or 0 end
  function fs.makeDirectory(path) return call("makeDirectory", rootPath(path)) end
  function fs.remove(path) return call("remove", rootPath(path)) end
  function fs.rename(from, to) return call("rename", rootPath(from), rootPath(to)) end
  function fs.isLink() return false end
  function fs.list(path)
    local names, err = call("list", rootPath(path))
    if type(names) ~= "table" then return nil, err or "no such file or directory" end
    local sorted = {}
    for i = 1, names.n or #names do sorted[#sorted + 1] = names[i] end
    table.sort(sorted)
    local i = 0
    return function()
      i = i + 1
      return sorted[i]
    end
  end
  function fs.open(path, mode) return openFile(ctx, rootPath(path), mode) end
  function fs.copy(from, to)
    local src, err = fs.open(from, "rb")
    if not src then return nil, err end
    local dst, err2 = fs.open(to, "wb")
    if not dst then src:close() return nil, err2 end
    dst:write(src:read("a") or "")
    src:close()
    dst:close()
    return true
  end
  function fs.get(path)
    return virtualDevices(ctx)[ctx.fsAddress], "/"
  end
  function fs.mounts()
    local done = false
    return function()
      if done then return nil end
      done = true
      return virtualDevices(ctx)[ctx.fsAddress], "/"
    end
  end
  function fs.isAutorunEnabled() return false end
  function fs.setAutorunEnabled() end
  return fs
end

-- --- Native file and console APIs (docs/MXE.md) ---
--
-- `fs`: the OS filesystem (the kernal's disk) for native processes and
-- .mxe programs, over the same FS requests and buffered streams as a
-- legacy program's. Paths are absolute. `readLine([prompt])`: a typed
-- line, for the console's foreground program only.
do
  local nativeCtx = {}
  function nativeCtx.fsCall(op, ...)
    local result, err = remoteRequest("FS", {op = op, args = table.pack(...), caller = currentJobId})
    if not result then return nil, err end
    return table.unpack(result, 1, result.n or #result)
  end
  local call = nativeCtx.fsCall
  local function abs(path)
    if type(path) ~= "string" then error("bad argument (path expected, got " .. type(path) .. ")", 3) end
    return rootPath(path)
  end
  local api = {}
  function api.exists(path) return call("exists", abs(path)) == true end
  function api.isDirectory(path) return call("isDirectory", abs(path)) == true end
  function api.size(path) return call("size", abs(path)) or 0 end
  function api.lastModified(path) return call("lastModified", abs(path)) or 0 end
  function api.makeDirectory(path) return call("makeDirectory", abs(path)) end
  function api.remove(path) return call("remove", abs(path)) end
  function api.rename(from, to) return call("rename", abs(from), abs(to)) end
  -- Names in a directory, sorted; directories end with "/".
  function api.list(path)
    local names, err = call("list", abs(path))
    if type(names) ~= "table" then return nil, err or "no such directory" end
    local out = {}
    for i = 1, names.n or #names do out[#out + 1] = names[i] end
    table.sort(out)
    return out
  end
  function api.open(path, mode) return openFile(nativeCtx, abs(path), mode) end
  function api.read(path)
    local f, err = api.open(path, "r")
    if not f then return nil, err end
    local data = f:read("a")
    f:close()
    return data
  end
  -- Writes a whole file, making its directory if needed.
  function api.write(path, text)
    local full = abs(path)
    local dir = full:match("^(.*)/[^/]*$")
    if dir and dir ~= "" and not api.isDirectory(dir) then api.makeDirectory(dir) end
    local f, err = openFile(nativeCtx, full, "w")
    if not f then return nil, err end
    local ok, writeErr = f:write(tostring(text))
    f:close()
    if not ok then return nil, writeErr end
    return true
  end
  function api.copy(from, to)
    local data, err = api.read(from)
    if not data then return nil, err end
    return api.write(to, data)
  end
  NATIVE.fs = readOnly(api, "fs")

  -- The console echoes what's typed (kernal/muxos.lua's feedForeground);
  -- this collects it up to Enter.
  NATIVE.readLine = function(prompt)
    local id = currentJobId
    local ok, err = remoteRequest("ISFOREGROUND", {caller = id})
    if not ok then return nil, err end
    if prompt ~= nil then writeOutput(id, tostring(prompt)) end
    local chars = {}
    while true do
      local e = gmuxapi.pull_event()
      if e and e[1] == "key_down" then
        local char, code = e[2], e[3]
        if code == 28 then
          return table.concat(chars)
        elseif code == 14 then
          chars[#chars] = nil
        elseif char and char >= 32 then
          local fine, ch = pcall(utf8.char, char)
          if fine then chars[#chars + 1] = ch end
        end
      end
    end
  end
end

local function unavailable(name)
  return setmetatable({}, {__index = function(_, k)
    error(name .. "." .. tostring(k) .. " isn't available to legacy programs yet", 2)
  end})
end

local LEGACY_FACES = {
  computer = function(ctx)
    return {
      uptime = computer.uptime, address = computer.address,
      freeMemory = computer.freeMemory, totalMemory = computer.totalMemory,
      energy = computer.energy, maxEnergy = computer.maxEnergy, beep = computer.beep,
      pullSignal = function(timeout)
        local sig = legacyPull(ctx, timeout)
        if sig then return table.unpack(sig, 1, sig.n) end
      end,
      pushSignal = function(...)
        ctx.pushed[#ctx.pushed + 1] = table.pack(...)
        return true
      end,
    }
  end,
  event = function(ctx)
    local event = {}
    function event.pull(...)
      local args = table.pack(...)
      local timeout
      if type(args[1]) == "number" then
        timeout = args[1]
        args = table.pack(table.unpack(args, 2, args.n))
      end
      return pullMatching(ctx, timeout, function(sig) return signalMatches(sig, args) end)
    end
    function event.pullFiltered(timeout, filter)
      if type(timeout) == "function" then timeout, filter = nil, timeout end
      return pullMatching(ctx, timeout, function(sig) return filter(table.unpack(sig, 1, sig.n)) end)
    end
    function event.push(...)
      ctx.pushed[#ctx.pushed + 1] = table.pack(...)
      return true
    end
    function event.listen(name, handler)
      checkArg(1, name, "string")
      checkArg(2, handler, "function")
      local handlers = ctx.listeners[name] or {}
      ctx.listeners[name] = handlers
      for _, h in ipairs(handlers) do
        if h == handler then return false end
      end
      handlers[#handlers + 1] = handler
      return true
    end
    function event.ignore(name, handler)
      for i, h in ipairs(ctx.listeners[name] or {}) do
        if h == handler then table.remove(ctx.listeners[name], i) return true end
      end
      return false
    end
    return setmetatable(event, getmetatable(unavailable("event")))
  end,
  term = function(ctx)
    local t = ctx.term
    local blink = true
    return {
      write = function(value) t.write(value) end,
      read = function() return legacyReadLine(ctx) .. "\n" end,
      pull = function(...) return ctx.require("event").pull(...) end,
      clear = t.clear, clearLine = t.clearLine,
      getCursor = function() return t.x, t.y end,
      setCursor = function(x, y) t.x, t.y = math.floor(x), math.floor(y) end,
      getCursorBlink = function() return blink end,
      setCursorBlink = function(b) blink = b end,
      getViewport = function()
        local w, h = virtualDevices(ctx)[VGPU_ADDRESS].getResolution()
        return w, h, 0, 0, t.x, t.y
      end,
      gpu = function() return virtualDevices(ctx)[VGPU_ADDRESS] end,
      screen = function() return VSCREEN_ADDRESS end,
      keyboard = function() return VKEYBOARD_ADDRESS end,
      isAvailable = function() return true end,
    }
  end,
  filesystem = function(ctx)
    return newFilesystemFace(ctx)
  end,
  unicode = function()
    return readOnly(hostUnicode or {}, "unicode")
  end,
  process = function(ctx)
    local info = {path = ctx.path, command = ctx.path, env = {}, data = {}}
    return setmetatable({
      info = function() return info end,
      running = function() return ctx.path end,
    }, getmetatable(unavailable("process")))
  end,
  buffer = function()
    return unavailable("buffer")
  end,
  -- gmux-style: the process's own virtual gpu, screen and keyboard,
  -- the OS filesystem, and every other component in the cluster over
  -- the bus.
  component = function(ctx)
    return newBusComponentFace(function() return virtualDevices(ctx) end)
  end,
  package = function(ctx)
    return {
      loaded = ctx.loaded,
      path = "/lib/?.lua;/usr/lib/?.lua;/lib/?/init.lua;/usr/lib/?/init.lua",
      -- OpenOS's package.delay: the rest of `lib` is loaded from `file`
      -- the first time something missing is looked up in it.
      delay = function(lib, file)
        local mt = {}
        function mt.__index(tbl, key)
          mt.__index = nil
          ctx.env.dofile(file)
          return tbl[key]
        end
        if lib.internal then setmetatable(lib.internal, mt) end
        setmetatable(lib, mt)
      end,
    }
  end,
}

local function newLegacyEnv(id, program)
  local env = {}
  for _, k in ipairs({"assert", "error", "ipairs", "next", "pairs", "pcall", "rawequal", "rawget",
      "rawlen", "rawset", "select", "setmetatable", "getmetatable", "tonumber", "tostring", "type", "xpcall"}) do
    env[k] = _ENV[k]
  end
  for _, lib in ipairs({"string", "table", "math", "utf8", "coroutine"}) do env[lib] = NATIVE[lib] end
  env.checkArg = checkArg
  env.computer = NATIVE.computer
  local loaded = {}
  local path = program and program.path
  local ctx = {id = id, env = env, loaded = loaded, pushed = {}, listeners = {}, path = path,
    name = path and path:match("([^/]+)$") or "legacy", screenSize = program and program.screen,
    fsAddress = program and program.fsAddress,
    osEnv = {PWD = "/", HOME = "/home", PATH = "/bin:/usr/bin:/home/bin:.", TERM = "term", SHELL = "/bin/sh"}}
  function ctx.fsCall(op, ...)
    local result, err = remoteRequest("FS", {op = op, args = table.pack(...), caller = id})
    if not result then return nil, err end
    return table.unpack(result, 1, result.n or #result)
  end
  -- Like gmux, the program's window (its terminal) exists from the
  -- start: it appears at the first flush even if nothing is printed.
  local devices = virtualDevices(ctx)
  local term = newTerminal(ctx)
  ctx.term = term
  term.clear()
  local vgpu = devices[VGPU_ADDRESS]
  local function errorWrite(text)
    local old = vgpu.setForeground(0xFF0000)
    term.write(text)
    vgpu.setForeground(old)
  end
  jobEndHooks[id] = function(ok, result)
    if not ok and result ~= EXIT and result ~= KILLED then errorWrite(tostring(result) .. "\n") end
  end
  env.print = function(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do parts[i] = tostring((select(i, ...))) end
    term.write(table.concat(parts, "\t") .. "\n")
  end
  local function resolve(p)
    p = tostring(p)
    if p:sub(1, 1) ~= "/" then p = (ctx.osEnv.PWD or "/") .. "/" .. p end
    return rootPath(p)
  end
  local function write(...)
    for i = 1, select("#", ...) do term.write(tostring((select(i, ...)))) end
  end
  local stdout = {write = function(self, ...) write(...) return self end, flush = function(self) return self end,
    setvbuf = function() return true end}
  local stderr = {write = function(self, ...)
    for i = 1, select("#", ...) do errorWrite(tostring((select(i, ...)))) end
    return self
  end, flush = function(self) return self end, setvbuf = function() return true end}
  local function readTerminal(format)
    local line = legacyReadLine(ctx)
    if format == "n" or format == "*n" then return tonumber(line) end
    if format == "L" or format == "*L" then return line .. "\n" end
    return line
  end
  local stdin = {read = function(self, format) return readTerminal(format) end,
    lines = function(self) return function() return readTerminal("l") end end, close = function() return true end}
  env.io = {
    write = write,
    read = readTerminal,
    stdin = stdin,
    stdout = stdout,
    stderr = stderr,
    open = function(p, mode) return openFile(ctx, resolve(p), mode) end,
    lines = function(p, fmt)
      if p == nil then return stdin:lines() end
      local f, err = openFile(ctx, resolve(p), "r")
      if not f then error(err, 2) end
      return function()
        local value = f:read(fmt or "l")
        if value == nil then f:close() end
        return value
      end
    end,
    input = function() return stdin end,
    output = function() return stdout end,
    type = function(v)
      if v == stdin or v == stdout or v == stderr then return "file" end
      if type(v) == "table" and v.read and v.close then return "file" end
      return nil
    end,
  }
  local hostOs = _ENV.os or {}
  env.os = {
    sleep = sleep,
    clock = computer.uptime,
    time = hostOs.time or function() return math.floor(computer.uptime()) end,
    date = hostOs.date,
    difftime = hostOs.difftime,
    getenv = function(k)
      if k == nil then return ctx.osEnv end
      return ctx.osEnv[k]
    end,
    setenv = function(k, v) ctx.osEnv[k] = v ~= nil and tostring(v) or nil return v end,
    remove = function(p) return ctx.fsCall("remove", resolve(p)) end,
    rename = function(a, b) return ctx.fsCall("rename", resolve(a), resolve(b)) end,
    tmpname = function() return "/tmp/" .. id .. "-" .. math.floor(computer.uptime() * 1000) end,
    exit = function() error(EXIT, 0) end,
  }
  env._G = env
  env.load = function(chunk, name, mode, e) return load(chunk, name, mode, e or env) end
  for _, k in ipairs({"_G", "string", "table", "math", "utf8", "coroutine", "io", "os"}) do
    loaded[k] = env[k]
  end

  local shipped = program and program.modules or {}
  -- Source for a module name or a /lib path: shipped, else asked for.
  local function moduleSource(name)
    if shipped[name] then return shipped[name], name end
    local reply, err = remoteRequest("GETMODULE", {name = name, caller = id})
    if not reply then return nil, err end
    return reply.source, reply.path
  end
  local loading = {}
  function ctx.require(name)
    checkArg(1, name, "string")
    local value = loaded[name]
    if value ~= nil then return value end
    if loading[name] then error("module '" .. name .. "' is required while it's being loaded", 2) end
    if LEGACY_FACES[name] then
      value = LEGACY_FACES[name](ctx)
    else
      local source, pathOrErr = moduleSource(name)
      if not source then error("module '" .. name .. "' not found:\n\t" .. tostring(pathOrErr), 2) end
      local chunk, err = load(source, "=" .. tostring(pathOrErr), "t", env)
      if not chunk then error(err, 2) end
      loading[name] = true
      local ok, result = pcall(chunk, name)
      loading[name] = nil
      if not ok then error(result, 0) end
      value = result
      if value == nil then value = loaded[name] end
      if value == nil then value = true end
    end
    loaded[name] = value
    return value
  end
  env.require = ctx.require
  env.loadfile = function(p, mode, e)
    local resolved = resolve(p)
    local f, err = openFile(ctx, resolved, "r")
    if not f then return nil, err end
    local source = f:read("a")
    f:close()
    return load(source or "", "=" .. resolved, mode or "t", e or env)
  end
  env.dofile = function(p)
    local chunk, err = env.loadfile(p)
    if not chunk then error(err, 2) end
    return chunk()
  end
  return env
end

-- Sends a reply, turning a value that can't cross the wire (a
-- function, a cyclic table) into an ERROR for the requester. send()
-- serializes before broadcasting anything, so a failure here sends
-- nothing partial. Unguarded, that error used to escape the main loop
-- and kill this worker's whole runtime.
local function sendReply(msg, what)
  local ok, err = pcall(send, msg)
  if not ok then
    send({type = "ERROR", from = nodeId, to = msg.to, id = msg.id,
      error = "could not send " .. what .. ": " .. tostring(err)})
  end
end

-- --- The scheduler ---

local function removeProc(p)
  procs[p.id] = nil
  for i, id in ipairs(procOrder) do
    if id == p.id then table.remove(procOrder, i) break end
  end
end

-- A process ended: clean up after it and tell the kernal how.
local function finishProc(p, ok, result, migratedState)
  removeProc(p)
  local id = p.id
  local endHook = jobEndHooks[id]
  jobEndHooks[id] = nil
  if endHook then pcall(endHook, ok, result) end
  flushOutput(id, true)
  graphicsFlushers[id] = nil
  controlState[id] = nil
  eventQueues[id] = nil
  migrationHandlers[id] = nil
  if result == MIGRATED then
    send({type = "MIGRATED", from = nodeId, to = kernalAddr, jobId = id, state = migratedState})
    return
  end
  if not ok and result == EXIT then ok, result = true, nil end
  if ok then
    sendReply({type = "RESULT", from = nodeId, to = kernalAddr, id = id, result = result}, "job result")
  else
    send({type = "ERROR", from = nodeId, to = kernalAddr, id = id, error = tostring(result)})
  end
end

-- Can `p` run now? Controls are acted on when it's next resumed: a
-- killed or migrating process is "runnable" so that happens; a paused
-- one isn't.
local function runnable(p)
  local state = controlState[p.id]
  if state == "KILL" or state == "MIGRATE" then return true end
  if state == "PAUSE" then return false end
  return not p.started or p.wait == nil or satisfied(p.wait)
end

-- Runs `p` until it next waits, yields or ends.
local function stepProc(p)
  local state = controlState[p.id]
  if state == "KILL" then return finishProc(p, false, KILLED) end
  if state == "MIGRATE" then
    if not p.started then
      -- Never ran here: it restarts on the target with no state.
      controlState[p.id] = nil
      return finishProc(p, false, MIGRATED, nil)
    end
    local moved, saved = tryMigrate(p.id)
    if moved then return finishProc(p, false, MIGRATED, saved) end
  end
  local first = not p.started
  p.started, p.wait = true, nil
  current, currentJobId = p, p.id
  local ok, a, b
  if first then
    ok, a, b = coroutine.resume(p.co, p.args)
  else
    ok, a, b = coroutine.resume(p.co)
  end
  current, currentJobId = nil, nil
  if not ok then return finishProc(p, false, a) end
  if coroutine.status(p.co) == "dead" then return finishProc(p, true, a) end
  -- A bare coroutine.yield() from the program is a cooperative yield.
  p.wait = (a == WAIT and type(b) == "table") and b or COOPERATE
  flushOutput(p.id)
end

-- A JOB from the kernal becomes a process: compiled in the environment
-- for its kind, then left for the scheduler to start. A launched
-- program (msg.program) gets its arguments as `...`; plain code gets
-- the native environment and `args`. `msg.id` is the job's id.
local function spawnProc(msg)
  if procs[msg.id] then return end
  local program, chunk, loadErr, entry = msg.program
  if type(program) == "table" then
    local env, loadLibraries
    if program.kind == "mxe" then
      env, loadLibraries = newMxeEnv(msg.id, program, msg.restore)
    else
      env = newLegacyEnv(msg.id, program)
    end
    chunk, loadErr = load(msg.code, "=" .. tostring(program.path), "t", env)
    if chunk then
      local args = type(msg.args) == "table" and msg.args or {}
      entry = function()
        if loadLibraries then loadLibraries() end
        return chunk(table.unpack(args, 1, args.n or #args))
      end
    end
  else
    chunk, loadErr = load("local args = ...\n" .. msg.code, "=job", "t", newProcessEnv(msg.id))
    entry = chunk
  end
  if not chunk then
    send({type = "ERROR", from = nodeId, to = kernalAddr, id = msg.id, error = loadErr})
    return
  end
  local p = {id = msg.id, co = coroutine.create(entry), args = msg.args}
  procs[p.id] = p
  procOrder[#procOrder + 1] = p.id
end

-- What the kernal asks of this node (anything from the kernal that isn't
-- an RPC reply; see `receive`).
handleMessage = function(msg)
  if msg.type == "JOB" then
    spawnProc(msg)
  elseif msg.type == "EVENT" then
    queueEvent(msg.jobId, msg.event)
  elseif msg.type == "LIST" then
    -- This node's own components, for the kernal's `components` command.
    local list = {}
    for addr, ctype in component.list() do
      list[addr] = ctype
    end
    send({type = "RESULT", from = nodeId, to = msg.from, id = msg.id, result = list})
  elseif msg.type == "INVOKE" or msg.type == "VALUECALL" then
    -- The bus: a call on one of this node's components (or a value one
    -- returned) on the kernal's behalf.
    serviceBusCall(msg)
  elseif msg.type == "GETCOMPONENTS" then
    reportComponents()
  end
end

-- The scheduler: a round over every process that can run, then the
-- signals that arrived -- without waiting if something is runnable,
-- otherwise until the nearest deadline (at most SWEEP_EVERY, so stale
-- partial messages still get swept).
local SWEEP_EVERY = 10
local MAX_SIGNALS_PER_ROUND = 32
local lastSweep = computer.uptime()
while true do
  for _, id in ipairs({table.unpack(procOrder)}) do
    local p = procs[id]
    if p and runnable(p) then stepProc(p) end
  end
  local timeout = SWEEP_EVERY
  for _, id in ipairs(procOrder) do
    local p = procs[id]
    if runnable(p) then
      timeout = 0
      break
    end
    -- (A paused process's deadline doesn't count: it can't run until
    -- resumed, and its passed deadline would make this spin.)
    local deadline = controlState[p.id] ~= "PAUSE" and p.wait and p.wait.deadline
    if deadline then timeout = math.min(timeout, math.max(0, deadline - computer.uptime())) end
  end
  for n = 1, MAX_SIGNALS_PER_ROUND do
    local name, a, b, c, d, e = computer.pullSignal(n == 1 and timeout or 0)
    if not name then break end
    receive(name, a, b, c, d, e)
  end
  if computer.uptime() - lastSweep >= SWEEP_EVERY then
    sweepStaleChunks()
    lastSweep = computer.uptime()
  end
end
