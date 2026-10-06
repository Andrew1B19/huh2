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
-- node's whole lifetime; the main loop below no longer re-derives it
-- from arbitrary incoming messages (see the real bug this fixes, noted
-- where kernalAddr used to be reassigned, further down).
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
    local parts = {}
    for k, val in pairs(v) do
      parts[#parts + 1] = "[" .. serialize(k, seen) .. "]=" .. serialize(val, seen)
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

-- Waiting for a signal. At the top level this is the sandbox's
-- computer.pullSignal, which yields to the machine. Inside a running
-- job (sleep, a gmuxapi call, pull_event) it yields the timeout to
-- runJobCode instead, which does the real wait and hands the job the
-- signal -- so controls (pause/kill) and liveness probes are handled
-- in one place. (A bare coroutine.yield(timeout) at the top level would
-- NOT work: the sandbox wraps coroutine.yield as a user yield and the
-- timeout is lost.)
local jobCoroutine = nil

local function pullSignal(timeout)
  if jobCoroutine and coroutine.running() == jobCoroutine then
    return coroutine.yield(timeout)
  end
  return computer.pullSignal(timeout)
end

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
  while true do pullSignal() end
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
-- Shared by the main dispatch loop AND remoteRequest()'s own nested wait
-- loop below (that one bypasses the main loop entirely while waiting on
-- a specific reply, so it needs its own reassembly, not just the main
-- loop's). Swept for abandoned entries by the main loop -- see its
-- pullSignal(10) timeout, below.
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

-- Fully reassembled messages ({from = sending card, msg = table}) that
-- arrived while this node was waiting on something else -- a
-- remoteRequest() reply, or a job's sleep(). The main loop handles
-- these before pulling anything new. Stashing the reassembled message,
-- rather than computer.pushSignal-ing the raw frame back, is what lets
-- a multi-chunk message survive (its earlier chunks are already gone
-- from the signal queue) and keeps a waiter from re-pulling its own
-- pushed-back signal in a tight loop until its deadline.
local pendingMessages = {}

-- Process control from the kernal: raw, unchunked "KILL <id> <node>",
-- "PAUSE ...", "RESUME ...", "MIGRATE ..." broadcasts (cheap to recognize at every
-- signal, no reassembly). Recorded per job id whether or not that job
-- is running yet -- a control can arrive while the target is still
-- queued here behind another job -- and acted on by runJobCode at the
-- job's yield points, or by the main loop before a queued JOB starts.
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

-- Sets aside one signal pulled while waiting for something else -- a
-- job's yield(), sleep(), or a gmuxapi call. A PING is answered on the
-- spot: that's how the kernal knows a node busy with a job is still
-- alive (see kernal/muxos.lua's checkLiveness) without a dedicated
-- heartbeat. Non-modem signals are dropped -- a worker has no use for
-- them.
local function stashSignal(name, from, port, data)
  if name ~= "modem_message" or noteControl(port, data) then return end
  if port ~= PORT or type(data) ~= "string" then return end
  local payload = reassemble(from, data)
  local msg = payload and deserialize(payload)
  if type(msg) ~= "table" then return end
  if msg.type == "PING" and msg.from == from and (msg.to == nil or msg.to == nodeId) then
    send({type = "PONG", from = nodeId, to = msg.from, id = msg.id})
  elseif msg.type == "EVENT" and from == kernalAddr and msg.from == from and msg.to == nodeId then
    queueEvent(msg.jobId, msg.event)
  else
    pendingMessages[#pendingMessages + 1] = {from = from, msg = msg}
  end
end

-- Announce ourselves so the kernal can pick up our HELLO (it already
-- knows kernalAddr from the boot handshake above, so this is purely
-- for the kernal's own discovery bookkeeping, not for learning
-- anything on our end).
send({type = "HELLO", from = nodeId})

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
    local name, _, from, port, _, data = pullSignal(deadline - computer.uptime())
    if name == "modem_message" and from == kernalAddr and port == PORT
        and type(data) == "string" and data:sub(1, 4) == "MSG " then
      local payload = reassemble(from, data)
      local reply = payload and deserialize(payload)
      -- The type check matters: the kernal's own JOB ids and this
      -- node's RPC ids are independent counters, so a JOB for a child
      -- placed on this node can carry the same id as the reply being
      -- waited for -- it used to match here and be silently dropped.
      if type(reply) == "table" and reply.id == id and reply.to == nodeId
          and (reply.type == "RESULT" or reply.type == "ERROR") then
        if reply.type == "RESULT" then return reply.result end
        return nil, reply.error
      elseif type(reply) == "table" then
        -- Anything else (most importantly a JOB for a child the kernal
        -- placed on this same node) is kept for the main loop rather
        -- than dropped.
        pendingMessages[#pendingMessages + 1] = {from = from, msg = reply}
      end
    else
      stashSignal(name, from, port, data)
    end
  end
  return nil, "timed out waiting for kernal"
end

local function flushOutput(id)
  local buf = outputBuffers[id]
  if buf and #buf > 0 and kernalAddr then
    outputBuffers[id] = nil
    send({type = "OUTPUT", from = nodeId, to = kernalAddr, jobId = id, text = table.concat(buf)})
  end
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

-- The job this node is running right now (a worker runs one at a
-- time), so gmuxapi calls can tell the kernal "I am job X" -- e.g. as
-- the parent when asking for a child. The job itself sees its own id as
-- `jobId` in its process environment.
local currentJobId = nil

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
      title = options.name, width = options.width, height = options.height, ownerJobId = proc.id,
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
      caller = currentJobId,
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
    flushOutput(currentJobId)
    local deadline = timeout and (computer.uptime() + timeout)
    while true do
      local q = eventQueues[currentJobId]
      if q and #q > 0 then return table.remove(q, 1) end
      if deadline and computer.uptime() >= deadline then return nil end
      local name, _, from, port, _, data = pullSignal(deadline and (deadline - computer.uptime()) or nil)
      stashSignal(name, from, port, data)
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
-- coroutine with a debug hook ("too long without yielding"). A job runs
-- in its own coroutine, so one that never yields is ended that way and
-- comes back as an ordinary ERROR; this node survives as long as it
-- yields to the machine promptly afterwards, which the main loop does.
-- (The sandbox has no debug.sethook of its own to build a tighter
-- budget with, and a Lua 5.3 hook can't yield anyway, so there is no
-- forced preemption.)
--
-- `yield()` is how a long job cooperates: it suspends the job, and
-- runJobCode does a real (zero-timeout) wait -- which is what resets the
-- machine's deadline -- answers a PING, sets other traffic aside, acts
-- on pause/kill, then resumes the job.
--
-- It yields a distinct sentinel because a job's own waits (sleep, a
-- gmuxapi call) also yield to runJobCode, with their timeout: the
-- sentinel tells the two apart, so a voluntary yield() gets a brief
-- pass while a wait gets a real signal handed back to it.
local YIELD_COOPERATE = "__cooperate"

function yield()
  coroutine.yield(YIELD_COOPERATE)
end

-- Exposed to JOB code: wait `seconds` without losing what arrives
-- meanwhile. A job that waited with a bare coroutine.yield(timeout)
-- would be handed (and silently consume) every signal that came in --
-- including the JOB message for a child the kernal had just queued on
-- this node. Everything is set aside for the main loop instead.
function sleep(seconds)
  local deadline = computer.uptime() + (seconds or 0)
  while computer.uptime() < deadline do
    local name, _, from, port, _, data = pullSignal(deadline - computer.uptime())
    stashSignal(name, from, port, data)
  end
end

local KILLED = "killed"
-- runJobCode's return when a process handed over its state to move.
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

-- Blocks while `id` is paused (answering pings and setting traffic
-- aside meanwhile). Returns true if it was killed instead of resumed.
local function waitWhilePaused(id)
  while controlState[id] == "PAUSE" do
    local name, _, from, port, _, data = pullSignal()
    stashSignal(name, from, port, data)
  end
  return controlState[id] == "KILL"
end

-- `selfId` is this job's own id, used to pick out controls addressed at
-- it among the broadcasts every worker sees. Controls are acted on at
-- the job's yield points -- a job that never yields can't be paused or
-- ended early, no sooner than its instruction-budget circuit breaker
-- would catch it anyway.
local function runJobCode(chunk, args, selfId)
  if controlState[selfId] == "PAUSE" and waitWhilePaused(selfId) then return false, KILLED end
  if controlState[selfId] == "KILL" then return false, KILLED end
  if controlState[selfId] == "MIGRATE" then
    -- Never started here: restart it on the target with no state.
    controlState[selfId] = nil
    return false, MIGRATED, nil
  end
  local co = coroutine.create(chunk)
  jobCoroutine = co
  local ok, a = coroutine.resume(co, args)
  while ok and coroutine.status(co) ~= "dead" do
    local resumeWith
    if a == YIELD_COOPERATE then
      -- The job's own voluntary yield(): a brief pass over whatever
      -- arrived (a PING answered, everything else set aside for the main
      -- loop), then resume with nothing.
      local sig = table.pack(pullSignal(0))
      if sig.n > 0 and sig[1] ~= nil then
        stashSignal(sig[1], sig[3], sig[4], sig[6])
      end
      resumeWith = {n = 0}
    else
      -- The job's own wait (sleep, a gmuxapi call, pull_event): hand it
      -- the real signal, unless it's a control, which is handled here.
      local sig = table.pack(pullSignal(type(a) == "number" and a or nil))
      if sig[1] == "modem_message" and noteControl(sig[4], sig[6]) then
        resumeWith = {n = 0}
      else
        resumeWith = sig
      end
    end
    flushOutput(selfId)
    if controlState[selfId] == "PAUSE" and waitWhilePaused(selfId) then return false, KILLED end
    if controlState[selfId] == "KILL" then return false, KILLED end
    if controlState[selfId] == "MIGRATE" then
      local moved, state = tryMigrate(selfId)
      if moved then return false, MIGRATED, state end
    end
    ok, a = coroutine.resume(co, table.unpack(resumeWith, 1, resumeWith.n))
  end
  return ok, a
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
    }
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
  local function loadLibraries()
    for name, source in pairs(program.libs or {}) do
      if source == true and BUILTIN_LIBRARIES[name] then
        loaded[name] = BUILTIN_LIBRARIES[name](id, restored)
        goto continue
      end
      local fn, err = load(source, "=lib:" .. name, "t", env)
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
-- print/io/os, and nothing muxos-specific (no gmuxapi; parent/child
-- processes are an .mxe concept). The rest of the OpenOS userland
-- (require-able libraries, virtual components) isn't built yet.
local EXIT = {}

local function readLine(id)
  flushOutput(id)
  local line = ""
  while true do
    local event = gmuxapi.pull_event()
    if event and event[1] == "key_down" then
      local char, code = event[2], event[3]
      if code == 28 then
        return line
      elseif code == 14 then
        local len = utf8.len(line)
        if len and len > 0 then line = line:sub(1, utf8.offset(line, -1) - 1) end
      elseif char and char >= 32 then
        local ok, ch = pcall(utf8.char, char)
        if ok then line = line .. ch end
      end
    end
  end
end

local function newLegacyEnv(id)
  local env = {}
  for _, k in ipairs({"assert", "error", "ipairs", "next", "pairs", "pcall", "rawequal", "rawget",
      "rawlen", "rawset", "select", "setmetatable", "getmetatable", "tonumber", "tostring", "type", "xpcall"}) do
    env[k] = _ENV[k]
  end
  for _, lib in ipairs({"string", "table", "math", "utf8", "coroutine"}) do env[lib] = NATIVE[lib] end
  env.computer = NATIVE.computer
  env.print = printTo(id)
  local function write(...)
    for i = 1, select("#", ...) do writeOutput(id, tostring((select(i, ...)))) end
  end
  local stream = {write = function(self, ...) write(...) return self end}
  env.io = {
    write = write,
    read = function(format)
      local line = readLine(id)
      if format == "n" or format == "*n" then return tonumber(line) end
      if format == "L" or format == "*L" then return line .. "\n" end
      return line
    end,
    stdout = stream,
    stderr = stream,
  }
  env.os = {
    sleep = sleep,
    clock = computer.uptime,
    time = function() return math.floor(computer.uptime()) end,
    exit = function() error(EXIT, 0) end,
  }
  env.require = function(name)
    error("module '" .. tostring(name) .. "' not found: muxos doesn't provide the OpenOS libraries yet", 2)
  end
  env._G = env
  env.load = function(chunk, name, mode, e) return load(chunk, name, mode, e or env) end
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

local function handleMessage(from, msg)
  if msg.to ~= nil and msg.to ~= nodeId then return end
  -- The payload's `from` has to be the card that actually sent it.
  if msg.from ~= from then return end
  -- Real bug, fixed: this used to do `kernalAddr = msg.from` here,
  -- treating whoever just messaged this node as "the kernal". kernalAddr
  -- is seeded once from the boot handshake (see the top of this file)
  -- and only ever compared against from then on.
  if msg.type == "PING" then
    send({type = "PONG", from = nodeId, to = msg.from, id = msg.id})
    return
  end
  -- Everything else runs code or touches hardware on this node, so it's
  -- only accepted from the kernal itself, never from a peer.
  if from ~= kernalAddr then return end

  if msg.type == "JOB" then
    -- `msg.id` is the job's own id (dispatchJob uses one id as both the
    -- job's identity and this message's RPC id). A launched program
    -- (msg.program) gets the environment for its kind and its arguments
    -- as `...`; plain code gets the native environment and `args`.
    local program, chunk, loadErr, entry = msg.program
    if type(program) == "table" then
      local env, loadLibraries
      if program.kind == "mxe" then
        env, loadLibraries = newMxeEnv(msg.id, program, msg.restore)
      else
        env = newLegacyEnv(msg.id)
      end
      chunk, loadErr = load(msg.code, "=" .. tostring(program.path), "t", env)
      if chunk then
        local args = type(msg.args) == "table" and msg.args or {}
        if loadLibraries then
          entry = function() loadLibraries() return chunk(table.unpack(args, 1, args.n or #args)) end
        else
          entry = function() return chunk(table.unpack(args, 1, args.n or #args)) end
        end
      end
    else
      chunk, loadErr = load("local args = ...\n" .. msg.code, "=job", "t", newProcessEnv(msg.id))
      entry = chunk
    end
    if not chunk then
      send({type = "ERROR", from = nodeId, to = msg.from, id = msg.id, error = loadErr})
      return
    end
    currentJobId = msg.id
    local ok, result, migratedState = runJobCode(entry, msg.args, msg.id)
    currentJobId = nil
    flushOutput(msg.id)
    controlState[msg.id] = nil
    eventQueues[msg.id] = nil
    migrationHandlers[msg.id] = nil
    if result == MIGRATED then
      send({type = "MIGRATED", from = nodeId, to = msg.from, jobId = msg.id, state = migratedState})
      return
    end
    if not ok and result == EXIT then ok, result = true, nil end
    if ok then
      sendReply({type = "RESULT", from = nodeId, to = msg.from, id = msg.id, result = result}, "job result")
    else
      send({type = "ERROR", from = nodeId, to = msg.from, id = msg.id, error = tostring(result)})
    end
  elseif msg.type == "EVENT" then
    -- For a process still queued on this node; it reads it once it runs.
    queueEvent(msg.jobId, msg.event)
  elseif msg.type == "LIST" then
    -- Expose this node's own components to the kernal, so it can
    -- address them without us having to write custom JOB code for it.
    local list = {}
    for addr, ctype in component.list() do
      list[addr] = ctype
    end
    send({type = "RESULT", from = nodeId, to = msg.from, id = msg.id, result = list})
  elseif msg.type == "INVOKE" then
    -- The "remote component" bridge: call a method on one of this
    -- node's own components on the kernal's behalf. Results keep an
    -- explicit `n` so a nil in the middle doesn't shift what follows.
    local args = msg.args or {}
    local packed = table.pack(pcall(component.invoke, msg.address, msg.method, table.unpack(args, 1, args.n or #args)))
    if packed[1] then
      local returns = {n = packed.n - 1}
      for i = 2, packed.n do returns[i - 1] = packed[i] end
      sendReply({type = "RESULT", from = nodeId, to = msg.from, id = msg.id, result = returns}, "invoke result")
    else
      send({type = "ERROR", from = nodeId, to = msg.from, id = msg.id, error = tostring(packed[2])})
    end
  end
end

while true do
  local pending = table.remove(pendingMessages, 1)
  if pending then
    handleMessage(pending.from, pending.msg)
  else
    -- A bounded timeout (rather than blocking indefinitely) so stale,
    -- abandoned partial reassemblies get swept out periodically even if
    -- nothing else arrives for a while.
    local name, _, from, port, _, data = pullSignal(10)
    sweepStaleChunks()
    if name == "modem_message" and not noteControl(port, data) and port == PORT and type(data) == "string" then
      local payload = reassemble(from, data)
      local msg = payload and deserialize(payload)
      if type(msg) == "table" then
        handleMessage(from, msg)
      end
    end
  end
end
