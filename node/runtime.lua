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

-- `computer.pullSignal` and `component.proxy` are both OpenOS
-- convenience wrappers, not native (confirmed against the mod's own
-- ComputerAPI.scala/ComponentAPI.scala -- neither is registered there,
-- and the stock bios.lua itself never calls either). The real primitive
-- for receiving a signal is `coroutine.yield(timeout)`, caught by
-- NativeLuaArchitecture.runThreaded; component addressing is done with
-- plain component.invoke, no proxy object needed.
local function pullSignal(timeout)
  return coroutine.yield(timeout)
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

-- Job ids the kernal has broadcast a raw "KILL <id>" for. A KILL can
-- arrive while the target job is still queued here behind another job
-- (so runJobCode never sees it); the main loop checks this before
-- starting a JOB.
local killedIds = {}

local function noteKill(port, data)
  if port ~= PORT or type(data) ~= "string" then return nil end
  local id = data:match("^KILL (%d+)$")
  if id then
    id = tonumber(id)
    killedIds[id] = true
  end
  return id
end

-- Sets aside one signal pulled while waiting for something else -- a
-- job's yield(), sleep(), or a gmuxapi call. A PING is answered on the
-- spot: that's how the kernal knows a node busy with a job is still
-- alive (see kernal/muxos.lua's checkLiveness) without a dedicated
-- heartbeat. Non-modem signals are dropped -- a worker has no use for
-- them.
local function stashSignal(name, from, port, data)
  if name ~= "modem_message" or noteKill(port, data) then return end
  if port ~= PORT or type(data) ~= "string" then return end
  local payload = reassemble(from, data)
  local msg = payload and deserialize(payload)
  if type(msg) ~= "table" then return end
  if msg.type == "PING" and msg.from == from and (msg.to == nil or msg.to == nodeId) then
    send({type = "PONG", from = nodeId, to = msg.from, id = msg.id})
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

-- Set by the main loop (below) to this node's own currently-running
-- job's id, right before running its code -- exposed as a real global
-- (same reasoning as `gpu`/`gmuxapi`/`yield`: JOB code is load()ed
-- fresh each time with no visibility into this file's own locals) so
-- a job can tell the kernal "I am job X" when asking for a child --
-- see create_headless_process's `parent = jobId` below, and
-- docs/PROTOCOL.md's ".mxe process model" for why the kernal needs
-- this to track parent/child relationships at all.
jobId = nil

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
  -- `parent = jobId` (this node's own currently-running job, see above)
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
      parent = jobId, appName = options.name, orphanPolicy = options.orphan_policy})
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
      parent = jobId, appName = options.name, orphanPolicy = options.orphan_policy})
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
      pixels = options.pixels, mode = options.mode, bg = options.bg,
    })
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
}

-- OpenComputers really does kill a computer that runs too long without
-- yielding -- not guessed: `system.timeout` is a real exposed value
-- (confirmed in SystemAPI.scala), and OpenOS's OWN boot code
-- (lib/core/boot.lua) explicitly calls `pull(0)` at least once a second
-- during boot specifically to "protect from timeouts", pushing
-- whatever it steals back onto the queue with computer.pushSignal so
-- the real recipient still gets it. Before this fix, a JOB's code ran
-- as one uninterrupted `pcall` with no yield inside it at all -- a job
-- with a long loop and no yield of its own risked the MOD killing this
-- node's whole computer, not just erroring the job, and this node would
-- also be unable to answer PING or anything else while it ran.
--
-- The obvious fix -- a `debug.sethook` count hook that forces a yield
-- periodically, whether the job's own code yields or not -- does NOT
-- work: confirmed empirically against the real lua5.3 binary (not
-- guessed from docs), yielding from inside a debug hook raises
-- "attempt to yield across a C-call boundary" every time. Lua 5.3
-- genuinely does not allow a hook to suspend execution; only ordinary
-- code (not a hook callback) can yield. So real preemption of
-- non-cooperating job code is not possible here, on real Lua 5.3, full
-- stop -- not a muxos limitation, a language one.
--
-- What IS possible, and what this builds instead:
-- 1. `yield()` -- exposed to job code as a real global, so code that
--    expects to run long can voluntarily cooperate: calling it actually
--    suspends the job's own coroutine (an ordinary yield from regular
--    code, not from a hook, which works fine -- confirmed), at which
--    point runJobCode pulls any pending signal, answers a PING on the
--    spot and sets everything else aside for the main loop, so this
--    node keeps answering for as long as the job keeps cooperating.
-- 2. A hard instruction-budget circuit breaker (also `debug.sethook`,
--    but erroring instead of yielding -- confirmed that DOES work from
--    a hook) that kills a job outright, with a clear Lua error, if it
--    runs for PREEMPT_INSTRUCTIONS VM instructions without the job
--    EVER yielding or finishing. This can't resume a job that blows the
--    budget -- only this node's own availability is being protected,
--    not that specific job's progress -- but it guarantees a job that
--    never cooperates gets killed by muxos, cleanly, well before it
--    risks the mod killing this node's whole computer instead.
-- PREEMPT_INSTRUCTIONS is a judgment call, not empirically measured
-- against real hardware: large enough that ordinary job code doesn't
-- trip it by accident, small enough to still be "well before" OC's own
-- unverified real timeout.
local PREEMPT_INSTRUCTIONS = 2000000

-- Exposed as a real global (not `local`), like `gpu`/`gmuxapi` above --
-- JOB code can call this periodically during a long computation to stay
-- cooperative; see the header comment above for why this is the only
-- real way to keep this node responsive during a long job.
--
-- Yields a distinct sentinel, not a bare `coroutine.yield()`, for a
-- real reason found the hard way: job code can ALSO reach `gmuxapi.*`
-- (e.g. `request_fullscreen()`), which internally calls `remoteRequest()`
-- -- and THAT does its own nested wait via this same file's `pullSignal`
-- (`coroutine.yield(timeout)`), expecting to receive the actual network
-- reply it's waiting for as the resume value. Once job code runs inside
-- its own wrapped coroutine (`runJobCode`, below), both kinds of yield
-- are bare `coroutine.yield(...)` calls somewhere down the call stack
-- with no other way to tell them apart from the outside -- confirmed by
-- actually hitting this: an early version of this fix treated every
-- yield as "voluntary cooperation" and swallowed the real reply
-- `remoteRequest` needed, hanging it forever. The sentinel lets
-- `runJobCode` give the two cases their correct, different handling:
-- a voluntary `yield()` gets a brief, bounded service pass; anything
-- else (a bare number, or nothing) is `pullSignal`'s own wait and gets
-- a REAL signal transparently forwarded into it, exactly as if the job
-- coroutine were this node's top-level one.
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

local function armBudgetHook(co)
  -- A debug.sethook count hook's count is a running total of
  -- instructions executed by that coroutine, NOT reset by a
  -- yield/resume cycle on its own (confirmed empirically) -- so without
  -- re-arming it before every resume, a cooperating job that calls
  -- yield() periodically would still eventually trip the SAME lifetime
  -- budget just by running long enough overall, defeating the whole
  -- point of cooperating. Re-arming here before each resume gives every
  -- voluntary yield a FRESH budget for its next slice (confirmed this
  -- actually works: a job yielding every ~300 instructions survives 5
  -- slices against a 1000-instruction budget that would kill it in one
  -- continuous run) -- cooperating costs nothing, not cooperating still
  -- gets caught within one slice.
  local message = "job exceeded its instruction budget (" .. PREEMPT_INSTRUCTIONS ..
    ") without yielding or finishing -- call yield() periodically if it needs to run this long"
  debug.sethook(co, function()
    -- Once tripped, error on EVERY instruction: a plain one-shot error
    -- is just a Lua error, so job code wrapping its loop in pcall could
    -- catch it and keep spinning forever. Each re-raise unwinds one
    -- more pcall level, so the job dies after at most its nesting depth.
    debug.sethook(co, function() error(message, 0) end, "", 1)
    error(message, 0)
  end, "", PREEMPT_INSTRUCTIONS)
end

-- A raw, unchunked "KILL <id>" broadcast -- same convention as boot's
-- own BOOT/CODE, bypassing the generic MSG framing deliberately: this
-- needs to be checked cheaply, at every signal a running job's
-- cooperative loop sees, without waiting on chunk reassembly (and a
-- kill message is tiny -- it never needs to be chunked in the first
-- place). Sent by the kernal when a "kill"-orphan-policy job's parent
-- finishes (see kernal/muxos.lua's applyOrphanPolicyForChildrenOf).
-- Returns true if `sig` (a packed pullSignal() result) is a KILL for
-- `selfId` specifically -- every other worker running a DIFFERENT job
-- just sees a non-matching id and ignores it, consistent with this
-- project's all-broadcast design.
local function isKillSignalFor(sig, selfId)
  if sig[1] ~= "modem_message" or sig[4] ~= PORT or type(sig[6]) ~= "string" then return false end
  local targetId = sig[6]:match("^KILL (%d+)$")
  return targetId ~= nil and tonumber(targetId) == selfId
end

-- `selfId` is this job's own id (set as the `jobId` global by the main
-- loop just before calling this) -- only used here to recognize a KILL
-- addressed at THIS specific job among the broadcasts every worker sees.
local function runJobCode(chunk, args, selfId)
  local co = coroutine.create(chunk)
  armBudgetHook(co)
  local ok, a = coroutine.resume(co, args)
  while ok and coroutine.status(co) ~= "dead" do
    if a == YIELD_COOPERATE then
      -- The job's own voluntary yield() -- a brief, bounded pause, not
      -- a wait for anything specific. Resume with no extra argument,
      -- matching coroutine.yield()'s own "returns nothing" convention
      -- for a bare cooperative pause. This is also the only point a
      -- "kill"-policy orphan actually CAN be killed early -- a job
      -- that never yields can't be reached here any sooner than its
      -- own instruction-budget circuit breaker would catch it anyway.
      -- Anything that arrived is set aside for the main loop (and a
      -- PING answered) rather than pushed back onto the signal queue,
      -- which made every later yield() re-pull the same signal.
      local sig = table.pack(pullSignal(0))
      if sig.n > 0 and sig[1] ~= nil then
        if isKillSignalFor(sig, selfId) then
          return false, "killed (orphan policy, parent no longer running)"
        end
        stashSignal(sig[1], sig[3], sig[4], sig[6])
      end
      armBudgetHook(co)
      ok, a = coroutine.resume(co)
    else
      -- Anything else is the job's OWN internal pullSignal() wait (for
      -- example gmuxapi.*'s remoteRequest(), waiting on a specific
      -- reply id) -- forward a REAL signal through transparently,
      -- exactly as if the job coroutine were the top-level one, so its
      -- own wait for a specific reply actually completes instead of
      -- spinning forever on signals it never receives. Still checked
      -- for a KILL first -- that takes priority over whatever this
      -- job's own nested wait was hoping to receive.
      local sig = table.pack(pullSignal(type(a) == "number" and a or nil))
      if isKillSignalFor(sig, selfId) then
        return false, "killed (orphan policy, parent no longer running)"
      end
      armBudgetHook(co)
      ok, a = coroutine.resume(co, table.unpack(sig, 1, sig.n))
    end
  end
  return ok, a
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
    if killedIds[msg.id] then
      -- Its parent finished (with a "kill" policy) while this job was
      -- still queued here, so it never started -- don't start it now.
      killedIds[msg.id] = nil
      send({type = "ERROR", from = nodeId, to = msg.from, id = msg.id,
        error = "killed (orphan policy, parent no longer running)"})
      return
    end
    local chunk, loadErr = load("local args = ...\n" .. msg.code, "=job", "t")
    if not chunk then
      send({type = "ERROR", from = nodeId, to = msg.from, id = msg.id, error = loadErr})
      return
    end
    -- jobId is this job's OWN id -- `msg.id` IS that id for a JOB
    -- message (dispatchJob uses one id as both the job's identity and
    -- this message's RPC id). Exposed as a real global so the job can
    -- tell the kernal "I am job X" when asking for a child
    -- (gmuxapi.create_headless_process's `parent = jobId`), and passed to
    -- runJobCode so it can recognize a KILL addressed at this job.
    jobId = msg.id
    local ok, result = runJobCode(chunk, msg.args, msg.id)
    jobId = nil
    if ok then
      sendReply({type = "RESULT", from = nodeId, to = msg.from, id = msg.id, result = result}, "job result")
    else
      send({type = "ERROR", from = nodeId, to = msg.from, id = msg.id, error = tostring(result)})
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
    if name == "modem_message" and not noteKill(port, data) and port == PORT and type(data) == "string" then
      local payload = reassemble(from, data)
      local msg = payload and deserialize(payload)
      if type(msg) == "table" then
        handleMessage(from, msg)
      end
    end
  end
end
