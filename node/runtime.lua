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
    flushOutput(currentJobId, true)
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
  if currentJobId then flushOutput(currentJobId, true) end
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
  -- gmux-style: the process sees its own virtual gpu, screen and
  -- keyboard, and nothing else.
  component = function(ctx)
    local component = {}
    local function devices() return virtualDevices(ctx) end
    local function primary(kind)
      for _, dev in pairs(devices()) do
        if dev.type == kind then return dev end
      end
    end
    function component.list(filter, exact)
      local found = {}
      for addr, dev in pairs(devices()) do
        if filter == nil or (exact and dev.type == filter) or (not exact and dev.type:find(filter, 1, true)) then
          found[addr] = dev.type
        end
      end
      local key
      return setmetatable(found, {__call = function()
        key = next(found, key)
        if key then return key, found[key] end
      end})
    end
    function component.proxy(addr)
      local dev = devices()[addr]
      if not dev then return nil, "no such component" end
      return dev
    end
    function component.invoke(addr, method, ...)
      local dev = devices()[addr]
      if not dev then error("no such component", 2) end
      if type(dev[method]) ~= "function" then error("no such method", 2) end
      return dev[method](...)
    end
    function component.type(addr)
      local dev = devices()[addr]
      if not dev then return nil, "no such component" end
      return dev.type
    end
    function component.slot(addr)
      if not devices()[addr] then return nil, "no such component" end
      return -1
    end
    function component.methods(addr)
      local dev = devices()[addr]
      if not dev then return nil, "no such component" end
      local methods = {}
      for k, f in pairs(dev) do if type(f) == "function" then methods[k] = true end end
      return methods
    end
    function component.fields() return {} end
    function component.doc() return nil end
    function component.isAvailable(kind) return primary(kind) ~= nil end
    function component.getPrimary(kind)
      local dev = primary(kind)
      if not dev then error("no primary '" .. tostring(kind) .. "' available", 2) end
      return dev
    end
    function component.setPrimary() end
    return setmetatable(component, {__index = function(_, kind)
      local dev = primary(kind)
      if not dev then error("no primary '" .. tostring(kind) .. "' available", 2) end
      return dev
    end})
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
        env = newLegacyEnv(msg.id, program)
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
    local endHook = jobEndHooks[msg.id]
    jobEndHooks[msg.id] = nil
    if endHook then pcall(endHook, ok, result) end
    currentJobId = nil
    flushOutput(msg.id, true)
    graphicsFlushers[msg.id] = nil
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
