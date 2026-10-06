-- muxos kernal "init" for huh2. This REPLACES OpenOS on the kernal --
-- it is the entire resident environment, not a program that runs under
-- one. kernal/bios.lua (this node's own tiny EEPROM image, mirroring
-- the mod's own stock EEPROM bios almost line for line) loads and calls
-- this file directly off the boot filesystem; there is no OpenOS
-- /init.lua anywhere in this picture.
--
-- This runs inside the mod's own sandbox (its machine.lua), not on raw
-- Lua: what's there is component (list/type/slot/methods/invoke/doc/
-- proxy), computer (including computer.pullSignal, pushSignal,
-- shutdown, uptime), the standard libraries with a wrapped
-- coroutine.yield/resume, and a debug table with only getinfo/
-- traceback/getlocal/getupvalue. What OpenOS would add on top --
-- event.pull/listen, thread.create, the keyboard library,
-- io/print-to-screen -- isn't there, so this file builds what it needs
-- itself (the sandbox has no `print` at all).
--
-- Install: kernal/bios.lua (flashed to the EEPROM), this file,
-- kernal/compositor.lua, kernal/bitmap.lua, and node/runtime.lua all
-- need to sit together at the ROOT of the kernal's boot filesystem
-- (/bios.lua, /muxos.lua, /compositor.lua, /bitmap.lua, /runtime.lua) --
-- fixed, hardcoded root paths, not resolved relative to wherever this
-- script happens to live the way a normal OpenOS install could:
-- debug.getinfo's source path would just be the synthetic chunk name
-- bios.lua loaded this under ("=muxos"), not a real filesystem path, so
-- there is nothing to resolve a sibling directory from any more.
--
-- Wire format: see docs/PROTOCOL.md. The serializer below is a
-- deliberate duplicate of the one in node/runtime.lua, not a shared
-- dependency -- neither side can require() anything, so keeping both
-- self-contained avoids a split-brain "shared lib" only one side could
-- actually load.

local PORT = 4477
local MUXOS_VERSION = "0.1.0"
local TIMEOUT = 5 -- seconds to wait for a worker reply before giving up

-- Every blocking wait goes through the sandbox's computer.pullSignal,
-- which yields to the machine. (A bare coroutine.yield(timeout) does
-- NOT: the sandbox wraps coroutine.yield to yield (nil, ...) as a user
-- yield, so the timeout is lost and the wait only ends on a signal.)
local function pullSignal(timeout)
  return computer.pullSignal(timeout)
end

-- Falling off the end of this file is NOT a clean shutdown -- the
-- machine treats that as the kernel stopping unexpectedly -- so
-- "quit"/"exit" go through this.
local function shutdown(reboot)
  computer.shutdown(reboot)
end

-- Our OWN tiny component-proxy helper -- NOT OpenOS's
-- component.proxy()/dot-shorthand sugar (confirmed absent from the
-- native ComponentAPI.scala surface), but the same calling convention,
-- built from the real primitive (component.invoke) so the rest of this
-- file can keep writing modem.broadcast(...)/gpu.set(...) instead of
-- component.invoke(addr, "broadcast", ...) everywhere. A duplicate of
-- this same tiny helper lives in kernal/compositor.lua too -- no shared
-- module either side could require().
local function componentProxy(address)
  return setmetatable({address = address}, {
    __index = function(_, method)
      return function(...) return component.invoke(address, method, ...) end
    end,
  })
end

local function primaryComponent(ctype)
  local address = component.list(ctype)()
  if not address then return nil end
  return componentProxy(address), address
end

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

local modem, modemAddr = primaryComponent("modem")
if not modem then
  error("no network/linked card found on this node")
end
modem.open(PORT)

-- Re-derive the filesystem this kernal booted from, the same way
-- kernal/bios.lua found it (the EEPROM's own stored boot address) --
-- there's no OpenOS mount table to resolve a path like "/compositor.lua"
-- through any more, so every sibling file this program needs is read
-- directly off this ONE filesystem component instead.
local eepromAddr = component.list("eeprom")()
local function tryInvoke(address, method, ...)
  local ok, a, b = pcall(component.invoke, address, method, ...)
  if ok then return a, b end
  return nil, a
end
local fsAddr = eepromAddr and tryInvoke(eepromAddr, "getData")
if not fsAddr or fsAddr == "" then
  fsAddr = component.list("filesystem")()
end
if not fsAddr then
  error("no filesystem component found to read sibling files from")
end

local function readFile(path)
  local handle, err = tryInvoke(fsAddr, "open", path, "r")
  if not handle then return nil, err end
  local parts = {}
  while true do
    local data = tryInvoke(fsAddr, "read", handle, math.huge)
    if not data then break end
    parts[#parts + 1] = data
  end
  tryInvoke(fsAddr, "close", handle)
  return table.concat(parts)
end

-- Hands a sibling file's LOADED chunk back, not its source -- the
-- caller decides whether/how to call it (compositor.lua is called with
-- loadSibling itself as its own argument, so it can load bitmap.lua the
-- same way; runtime.lua's source is served to workers as-is, never
-- called here, so it goes through readFile() directly instead, below).
local function loadSibling(name)
  local source, err = readFile("/" .. name)
  if not source then error("could not read /" .. name .. ": " .. tostring(err), 0) end
  local chunk, loadErr = load(source, "=" .. name)
  if not chunk then error("could not load /" .. name .. ": " .. tostring(loadErr), 0) end
  return chunk
end

-- Every node's wire identity is its network card's address, not
-- computer.address(): modem_message reports the SENDING CARD's address,
-- so this is the only identity a receiver can check a payload's `from`
-- against, and it's what node/bios.lua learns as kernalAddr from the
-- boot handshake.
local selfAddr = modemAddr
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
-- overhead. Only one node may hold it at a time.
local exclusiveFullscreenOwner = nil

-- The compositor is the only code in this whole project that makes a
-- real gpu.* call for WINDOW content -- see compositor.lua's own header
-- for why that's worth enforcing structurally, not just by convention.
-- It's loaded with loadSibling itself as its chunk argument, so it can
-- load bitmap.lua the same way this file loaded it.
local compositor = loadSibling("compositor.lua")(loadSibling)

-- The kernal's own gpu/screen, cached once -- used for
-- isDisplayComponent (below) and to size the console window.
local gpu, gpuAddr = primaryComponent("gpu")
local _, screenAddr = primaryComponent("screen")
if gpu and screenAddr then
  tryInvoke(gpuAddr, "bind", screenAddr)
end

-- --- The console, replacing OpenOS's io/term ---
--
-- The console's text lives in regular memory (consoleLines) and never
-- has a video buffer of its own. Normally it's a compositor text
-- window on the bottom layer, painted from its rows straight into the
-- frame buffer. Its size isn't fixed: it starts as the bottom half of
-- the screen and the `console <width> <height> [x y]` command changes
-- it at any time (cheap, since there's no buffer to reallocate). In
-- console mode (hold Ctrl+Alt+C) it's the compositor's
-- exclusive owner instead and draws straight onto the real screen at
-- full resolution.
--
-- Output is kept as logical (unwrapped) lines and wrapped only when
-- rendered, at whatever width the console currently has -- which is
-- what makes scrollback, switching between the two sizes, and
-- backspacing across a wrapped input line simple. Rendering happens at
-- most once per tick (renderConsole, from tick()).

local termW, termH = 1, 1
if gpu then
  termW, termH = gpu.getResolution()
end

local CONSOLE_LAYER = -1000
local CONSOLE_MIN_W, CONSOLE_MIN_H = 10, 3
-- Scrollback, in lines of output (oldest dropped first).
local SCROLLBACK_LINES = 500
local consoleLines = {}      -- committed logical lines, oldest first
local consoleDirty = true
local scrollOffset = 0       -- wrapped rows scrolled back from the bottom
local inputBuffer = ""       -- the REPL's line being typed
local consolePartial = ""    -- program output not yet ended by a newline
local commandBusy = false    -- a command is running; see handleKeyDown

local consoleW, consoleH = termW, math.max(CONSOLE_MIN_H, math.floor(termH / 2))
local consoleWin = gpu and compositor.createWindow({title = "console", x = 1, y = termH - consoleH + 1,
  width = consoleW, height = consoleH, layer = CONSOLE_LAYER, text = true, decorated = false}) or nil

local function consoleOwnsScreen()
  return compositor.exclusiveOwner() == "console"
end

-- The console's current size: the whole screen in console mode, its
-- window otherwise.
local function viewSize()
  if consoleOwnsScreen() then return termW, termH end
  return consoleW, consoleH
end

-- Splits one logical line into rows of at most `width` characters
-- (UTF-8 aware; falls back to bytes for invalid UTF-8).
local function wrapLine(line, width)
  local len = utf8.len(line)
  if not len then
    local rows = {}
    for i = 1, math.max(#line, 1), width do rows[#rows + 1] = line:sub(i, i + width - 1) end
    return rows
  end
  if len <= width then return {line} end
  local rows = {}
  local startChar = 1
  while startChar <= len do
    local from = utf8.offset(line, startChar)
    local to = utf8.offset(line, startChar + width)
    rows[#rows + 1] = to and line:sub(from, to - 1) or line:sub(from)
    startChar = startChar + width
  end
  return rows
end

local function liveLine()
  if commandBusy then
    -- A foreground program is running: show its unfinished output line
    -- (e.g. a prompt it wrote with io.write, plus the echo of what's
    -- being typed into it).
    if consolePartial ~= "" then return consolePartial .. "_" end
    return nil
  end
  return "muxos> " .. inputBuffer .. "_"
end

local function totalRows(width)
  local n = 0
  for _, line in ipairs(consoleLines) do n = n + #wrapLine(line, width) end
  local live = liveLine()
  if live then n = n + #wrapLine(live, width) end
  return n
end

local function setScroll(rows)
  local w, h = viewSize()
  scrollOffset = math.max(0, math.min(rows, totalRows(w) - h))
  consoleDirty = true
end

-- The h rows currently in view, top to bottom. Content shorter than the
-- view starts at the top, like a fresh terminal.
local function visibleRows(w, h)
  local needed = h + scrollOffset
  local rows = {}            -- collected bottom-up
  local exhausted = true
  local function addLine(line)
    local wrapped = wrapLine(line, w)
    for i = #wrapped, 1, -1 do
      rows[#rows + 1] = wrapped[i]
      if #rows >= needed then return true end
    end
  end
  local live = liveLine()
  if live and addLine(live) then exhausted = false end
  if exhausted then
    for i = #consoleLines, 1, -1 do
      if addLine(consoleLines[i]) then exhausted = false break end
    end
  end
  local out = {}
  if exhausted and #rows < h then
    for i = 1, #rows do out[i] = rows[#rows - i + 1] end
  else
    for r = 1, h do out[h - r + 1] = rows[scrollOffset + r] end
  end
  return out
end

local function renderConsole()
  if not consoleDirty or not consoleWin then return end
  -- Another owner (a fullscreen node) has the screen: leave it alone.
  local owner = compositor.exclusiveOwner()
  if owner and owner ~= "console" then return end
  consoleDirty = false
  local w, h = viewSize()
  local rows = visibleRows(w, h)
  if scrollOffset > 0 then
    local tag = "[scrolled " .. scrollOffset .. " -- PgDn]"
    local first = rows[1] or ""
    local keep = math.max(0, w - #tag)
    local len = utf8.len(first) or #first
    if len < keep then
      first = first .. (" "):rep(keep - len)
    else
      first = first:sub(1, (utf8.offset(first, keep + 1) or (keep + 1)) - 1)
    end
    rows[1] = first .. tag
  end
  if owner == "console" then
    compositor.drawDirect(function(g)
      g.setForeground(0xFFFFFF)
      g.setBackground(0x000000)
      g.fill(1, 1, w, h, " ")
      for y = 1, h do
        if rows[y] and rows[y] ~= "" then g.set(1, y, rows[y]) end
      end
    end)
  else
    compositor.setText(consoleWin.id, rows)
  end
end

local function consoleAppend(line)
  consoleLines[#consoleLines + 1] = line
  if #consoleLines > SCROLLBACK_LINES then table.remove(consoleLines, 1) end
  -- Keep a scrolled-back view still while new output arrives below it.
  if scrollOffset > 0 then scrollOffset = scrollOffset + #wrapLine(line, (viewSize())) end
  consoleDirty = true
end

-- Shadows the native `print` (which only logs to the Java server
-- console, not the in-game screen -- see this file's header) for every
-- call below this point in the same chunk.
local function print(...)
  local n = select("#", ...)
  local parts = {}
  for i = 1, n do parts[i] = tostring((select(i, ...))) end
  local text = table.concat(parts, "\t")
  if consolePartial ~= "" then
    consoleAppend(consolePartial)
    consolePartial = ""
  end
  for line in (text .. "\n"):gmatch("(.-)\n") do consoleAppend(line) end
end

-- Program output (OUTPUT messages): may end mid-line, so the unfinished
-- part is held in consolePartial until its newline arrives.
local function consoleWrite(text)
  local start = 1
  while true do
    local nl = text:find("\n", start, true)
    if not nl then
      consolePartial = consolePartial .. text:sub(start)
      break
    end
    consoleAppend(consolePartial .. text:sub(start, nl - 1))
    consolePartial = ""
    start = nl + 1
  end
  consoleDirty = true
end

-- --- Minimal keyboard modifier tracking, replacing OpenOS's keyboard library ---

-- Same key-code constants OpenOS's own lib/keyboard.lua uses internally
-- (verified against its source) -- just tracked by hand here since
-- there's no keyboard.pressedCodes table to read without it.
local KEY_BACK, KEY_ENTER = 0x0E, 0x1C
local KEY_LCONTROL, KEY_RCONTROL = 0x1D, 0x9D
local KEY_LMENU, KEY_RMENU = 0x38, 0xB8
local KEY_C = 0x2E
local heldKeys = {}
local function isControlDown() return heldKeys[KEY_LCONTROL] or heldKeys[KEY_RCONTROL] end
local function isAltDown() return heldKeys[KEY_LMENU] or heldKeys[KEY_RMENU] end

-- Every message over the modem is chunked, not just boot's CODE --
-- even a tiny PING gets wrapped as one chunk, uniformly, rather than
-- having two different wire shapes (chunked vs not) depending on size.
-- "MSG <id> <i>/<n> <chunk>" frames the ALREADY-serialized Lua-table
-- string; <id> is a per-sender counter, used together with the sending
-- component's real network address (which the receiver gets for free
-- from the modem_message signal itself, before any payload is even
-- parsed) to key reassembly -- see reassemble() below.
local CHUNK_SIZE = 7000
local nextMsgId = 1

local function send(msg)
  local payload = serialize(msg)
  local id = nextMsgId
  nextMsgId = nextMsgId + 1
  local total = math.ceil(#payload / CHUNK_SIZE)
  for i = 1, total do
    local chunk = payload:sub((i - 1) * CHUNK_SIZE + 1, i * CHUNK_SIZE)
    modem.broadcast(PORT, "MSG " .. id .. " " .. i .. "/" .. total .. " " .. chunk)
  end
end

-- senderAddr:msgId -> {chunks = {[i] = chunkString}, total = n, startedAt}
-- Swept for abandoned entries (a sender that sent some but not all
-- chunks of a message, e.g. it rebooted mid-send) by sweepStaleChunks(),
-- called once per tick -- otherwise an abandoned partial reassembly
-- would sit in this table forever.
local incomingChunks = {}

-- Feeds one "MSG ..." wire frame in; returns the fully reassembled,
-- still-serialized payload once every chunk of that message has
-- arrived, or nil if this was a partial chunk (still waiting on more)
-- or not a MSG frame at all. Does NOT deserialize -- callers do that
-- themselves once they have the complete string.
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

-- Any verified message from a node counts as a sign of life -- there's
-- no dedicated heartbeat. See checkLiveness() for how a quiet node is
-- probed and eventually marked down.
local function noteNode(addr)
  if not nodes[addr] then
    nodes[addr] = {}
    nodeOrder[#nodeOrder + 1] = addr
  end
  local node = nodes[addr]
  node.lastSeen = computer.uptime()
  node.probedAt = nil
  if node.down then
    node.down = nil
    print("node " .. addr .. " is responding again")
  end
end

-- Nodes that can take new work: up, and not being drained.
local function liveNodeCount()
  local n = 0
  for _, addr in ipairs(nodeOrder) do
    if not nodes[addr].down and not nodes[addr].draining then n = n + 1 end
  end
  return n
end

-- Round-robin with a simple multi-core balancer on top: the live node
-- with the fewest running jobs wins, and round-robin order breaks ties
-- (so an idle rack still rotates instead of piling onto node 1).
local function nextLiveNode(avoid)
  local best, bestLoad
  for _ = 1, #nodeOrder do
    local addr = nodeOrder[nextNode]
    nextNode = (nextNode % #nodeOrder) + 1
    local node = nodes[addr]
    if not node.down and not node.draining and addr ~= avoid then
      local load = node.running or 0
      if not best or load < bestLoad then best, bestLoad = addr, load end
      if load == 0 then break end
    end
  end
  if best then
    for i, addr in ipairs(nodeOrder) do
      if addr == best then nextNode = (i % #nodeOrder) + 1 break end
    end
  end
  return best
end

local function nextId()
  local id = nextJobId
  nextJobId = nextJobId + 1
  return id
end

-- id -> {id, node, status, code, startedAt, finishedAt, result, error,
-- parent, appName, orphanPolicy}. status is "running", "done", "error",
-- or "killed". `parent`/`appName`/`orphanPolicy` are nil for an
-- ordinary top-level job (REPL `run`/`spawn`, or a SPAWN with no
-- parent) -- see docs/PROTOCOL.md's ".mxe process model" section for
-- the full design these implement.
local jobs = {}

-- Finished jobs are kept for `processes`/get_processes, but only the
-- most recent MAX_FINISHED_JOBS of them, and without their full source
-- (a short `codePreview` stays). Running jobs are always kept.
local MAX_FINISHED_JOBS = 100
local finishedOrder = {}
local CODE_PREVIEW_CHARS = 40

local function codePreview(code)
  if type(code) ~= "string" then return nil end
  local len = utf8.len(code)
  if not len then return code:sub(1, CODE_PREVIEW_CHARS) end
  if len <= CODE_PREVIEW_CHARS then return code end
  return code:sub(1, utf8.offset(code, CODE_PREVIEW_CHARS + 1) - 1) .. "..."
end

local function orderedJobIds()
  local ids = {}
  for id in pairs(jobs) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

-- Indexes kept alongside `jobs` so the per-tick and per-completion work
-- (scheduler stress, fan-out counts, orphan sweeps, orphan policy) is
-- proportional to what's live, not to every job ever dispatched.
local runningJobs = {}   -- id -> true while status == "running"
local runningCount = 0
local childrenOf = {}    -- parent id -> {child id, ...}

-- appName -> {jobId, jobId, ...}. Only ever holds jobs whose
-- orphanPolicy is "orphan" -- the pool a relaunched app's
-- gmuxapi.get_orphans(name) draws from (handleGetOrphans, below).
-- Entries are added at spawn time and removed once reclaimed, so this
-- never accumulates jobs nobody will ever ask for again except by
-- genuinely relaunching under the same name.
local appsByName = {}

local function registerOrphanCandidate(appName, id)
  if not appName then return end
  appsByName[appName] = appsByName[appName] or {}
  local list = appsByName[appName]
  list[#list + 1] = id
end

local function unregisterOrphanCandidate(appName, id)
  if not appName or not appsByName[appName] then return end
  local list = appsByName[appName]
  for i, existingId in ipairs(list) do
    if existingId == id then
      table.remove(list, i)
      break
    end
  end
end

-- id -> the RESULT/ERROR/PONG message that answered it. Filled in by
-- handleModemMessage (see below), read and cleared by waitForReply.
-- Only replies someone is actually waiting on (`awaiting`: id -> the
-- address expected to answer) are stored -- otherwise every
-- fire-and-forget spawned job's RESULT, and every reply that arrived
-- after its waiter timed out, would sit here forever.
local replyBox = {}
local awaiting = {}

-- Record a job's dispatch and actually send it, WITHOUT waiting for the
-- result -- shared by submit() (which then blocks on awaitReply itself)
-- and handleSpawn() (which must return to the calling worker immediately,
-- gmux's own create_headless_process/create_graphics_process being
-- fire-and-forget: you get a handle back right away, not the result).
-- `parent`/`appName`/`orphanPolicy` are nil for anything dispatched
-- without a parent (REPL `run`/`spawn`, or a plain SPAWN) -- only a
-- SPAWN carrying an explicit `parent` (its own job id, which
-- node/runtime.lua now exposes to running job code as the global
-- `jobId`) sets these.
local function dispatchJob(code, args, targetAddr, parent, appName, orphanPolicy, program)
  if targetAddr then
    if not nodes[targetAddr] then return nil, "unknown node: " .. tostring(targetAddr) end
    if nodes[targetAddr].down then return nil, "node is down: " .. targetAddr end
  else
    if liveNodeCount() == 0 then
      return nil, "no live worker nodes -- try 'discover'"
    end
    -- Least-busy live node (see nextLiveNode). A worker runs one job at
    -- a time, so a job sent to a busy worker just waits in that
    -- worker's own queue -- not denied, not queued at the kernal.
    targetAddr = nextLiveNode()
  end
  nodes[targetAddr].lastDispatch = computer.uptime()
  local id = nextId()
  -- rootId is the ultimate ancestor of this job's tree -- itself, for
  -- a top-level job; inherited in O(1) from the parent's own rootId
  -- otherwise (never a chain-walk). This is what the fan-out cap below
  -- counts against: "how many jobs in THIS tree are running right
  -- now," not a global count, so one tree hitting its cap doesn't
  -- block unrelated top-level work.
  local rootId = parent and jobs[parent] and jobs[parent].rootId or id
  jobs[id] = {id = id, node = targetAddr, status = "running", code = code, codePreview = codePreview(code),
    startedAt = computer.uptime(),
    parent = parent, appName = appName, orphanPolicy = parent and (orphanPolicy or "orphan") or nil,
    rootId = rootId, path = program and program.path, kind = program and program.kind,
    program = program, args = args}
  runningJobs[id] = true
  runningCount = runningCount + 1
  nodes[targetAddr].running = (nodes[targetAddr].running or 0) + 1
  if parent then
    childrenOf[parent] = childrenOf[parent] or {}
    local siblings = childrenOf[parent]
    siblings[#siblings + 1] = id
  end
  if parent and jobs[id].orphanPolicy == "orphan" then
    registerOrphanCandidate(appName, id)
  end
  send({type = "JOB", from = selfAddr, to = targetAddr, id = id, code = code, args = args, program = program})
  return id, targetAddr
end

-- --- Program launcher ---
--
-- Works like OpenOS's: a name typed at the console is looked up on
-- PROGRAM_PATH (.mxe before .lua), or a path is used as given. A .lua
-- program runs in the OpenOS environment; an .mxe declares, in a
-- header at the top of the file, the muxos version it targets and any
-- libraries it wants beyond the native API:
--
--   --[[mxe
--   muxos = "0.1.0"
--   libraries = {"name", ...}
--   ]]
--
-- and gets a response (the global `launch` in its environment): the
-- actual version, whether it matches (a mismatch never stops it from
-- running), and which libraries were found. Libraries live at
-- MXE_LIBRARY_DIR/<name>.lua on the kernal's disk and are shipped with
-- the program. Either way, the scheduler places it.
local PROGRAM_PATH = {"/bin", "/usr/bin"}
-- Libraries built into the worker runtime rather than shipped from disk.
local BUILTIN_MXE_LIBRARIES = {mux = true}
local MXE_LIBRARY_DIR = "/lib/mxe/"

local function fileExists(path)
  return tryInvoke(fsAddr, "exists", path) == true
end

local function resolveProgram(name)
  local candidates = {}
  local function add(base)
    if base:match("%.mxe$") or base:match("%.lua$") then
      candidates[#candidates + 1] = base
    else
      candidates[#candidates + 1] = base .. ".mxe"
      candidates[#candidates + 1] = base .. ".lua"
    end
  end
  if name:find("/", 1, true) then
    add(name)
  else
    for _, dir in ipairs(PROGRAM_PATH) do add(dir .. "/" .. name) end
  end
  for _, path in ipairs(candidates) do
    if fileExists(path) then return path end
  end
end

-- The header is evaluated as Lua assignments in an empty environment --
-- it's data, not a place to run code. It runs in its own coroutine, so
-- one that never finishes is ended by the machine's own "too long
-- without yielding" deadline without taking the kernal down.
local function readManifest(source)
  local body = source:match("^%s*%-%-%[%[mxe(.-)%]%]")
  if not body then return {} end
  local env = {}
  local chunk, err = load(body, "=mxe header", "t", env)
  if not chunk then return nil, "bad .mxe header: " .. tostring(err) end
  local co = coroutine.create(chunk)
  local ok, runErr = coroutine.resume(co)
  if not ok then return nil, "bad .mxe header: " .. tostring(runErr) end
  return {muxos = env.muxos, libraries = env.libraries}
end

local function versionParts(v)
  local parts = {}
  for n in tostring(v):gmatch("%d+") do parts[#parts + 1] = tonumber(n) end
  return parts
end

local function sameVersion(a, b)
  local x, y = versionParts(a), versionParts(b)
  for i = 1, math.max(#x, #y, 1) do
    if (x[i] or 0) ~= (y[i] or 0) then return false end
  end
  return true
end

local function launchProgram(path, args, parent)
  local source, err = readFile(path)
  if not source then return nil, "can't read " .. path .. ": " .. tostring(err) end
  local program = {path = path, kind = path:match("%.mxe$") and "mxe" or "legacy"}
  if program.kind == "mxe" then
    local manifest, manifestErr = readManifest(source)
    if not manifest then return nil, manifestErr end
    local response = {muxos = MUXOS_VERSION, requested = manifest.muxos, libraries = {},
      versionMatch = manifest.muxos == nil or sameVersion(manifest.muxos, MUXOS_VERSION)}
    local libs = {}
    for _, name in ipairs(type(manifest.libraries) == "table" and manifest.libraries or {}) do
      if BUILTIN_MXE_LIBRARIES[name] then
        response.libraries[name] = true
        libs[name] = true
      elseif type(name) == "string" and name:match("^[%w_%.%-]+$") then
        local libSource = readFile(MXE_LIBRARY_DIR .. name .. ".lua")
        response.libraries[name] = libSource ~= nil
        libs[name] = libSource
      end
    end
    program.launch, program.libs = response, libs
  end
  local appName = path:match("([^/]+)%.%w+$")
  return dispatchJob(source, args, nil, parent, appName, nil, program)
end

-- Fan-out/depth cap on recursive spawning: "for as many nodes as
-- there is" -- a job tree (the top-level job plus every descendant it
-- spawned, directly or through several levels) may not have more jobs
-- "running" at once than there are live worker nodes. Counts the WHOLE
-- tree via each job's own rootId, not just direct children, so a
-- grandchild spawning its own child is covered the same as a direct
-- child -- "depth" and "fan-out" collapse into the same single check
-- this way, rather than needing two separate limits.
local function countRunningInTree(rootId)
  local count = 0
  for id in pairs(runningJobs) do
    if jobs[id].rootId == rootId then
      count = count + 1
    end
  end
  return count
end

-- Applies a job's declared orphan policy once its PARENT is no longer
-- running -- called from the generic completion-recording path below,
-- for every child of whatever job just finished. See docs/PROTOCOL.md
-- for the policy semantics (orphan/kill/promote) -- this is purely the
-- mechanical side:
-- - "orphan": nothing to do -- it just keeps running, already tracked
--   in appsByName for a future gmuxapi.get_orphans(name) to reclaim.
-- - "promote": it's now a top-level job in every sense -- clear
--   `parent` and stop tracking it as reclaimable (nobody declared by
--   this name will ever "come back" for it; it's independent now).
-- - "kill": best-effort only -- broadcasts a raw, unchunked "KILL
--   <id>" (same convention as boot's BOOT/CODE, bypassing the generic
--   MSG framing since this needs to be checked cheaply and can't wait
--   on reassembly) that node/runtime.lua's runJobCode checks for at
--   the job's own cooperative yield points. A job that never yields
--   can't be killed early this way -- same fundamental limit as the
--   instruction-budget circuit breaker (see "JOB code and the
--   non-yielding timeout"), not a gap specific to this feature.
local function applyOrphanPolicyForChildrenOf(parentId)
  for _, id in ipairs(childrenOf[parentId] or {}) do
    local job = jobs[id]
    if not job then
      -- already dropped from history
    elseif job.orphanPolicy == "promote" then
      unregisterOrphanCandidate(job.appName, id)
      job.parent = nil
    elseif job.orphanPolicy == "kill" then
      if job.status == "running" then
        job.killReason = "killed (orphan policy, parent no longer running)"
        modem.broadcast(PORT, "KILL " .. id .. " " .. job.node)
      end
      job.parent = nil
    elseif job.orphanPolicy == "orphan" then
      -- Marks WHEN this job actually became orphaned -- the clock
      -- sweepStaleOrphans() (below) measures against, not when it
      -- was originally spawned (which could have been long before
      -- its parent actually finished).
      job.orphanedAt = computer.uptime()
    end
  end
  childrenOf[parentId] = nil
end

-- How loaded the scheduler is right now: running jobs per worker node.
-- Can exceed 1 -- "running" counts every job the kernal has dispatched
-- and not yet seen finish, including ones still queued behind another
-- job at the same busy worker (see dispatchJob's own comment on why a
-- busy target just queues rather than being denied) -- so this is a
-- real backlog measure, not just "is anything happening at all."
local function schedulerStress()
  local live = liveNodeCount()
  if live == 0 then return 0 end
  return runningCount / live
end

-- "Timeout is dependent on scheduler stress": an orphan nobody's
-- reclaimed sits for up to BASE_ORPHAN_TIMEOUT seconds while the
-- system is idle, shrinking as load climbs -- freeing capacity sooner
-- precisely when capacity is actually scarce, rather than holding an
-- unreclaimed job's slot regardless of whether anything else needs it.
-- The exact curve (simple inverse, BASE/(1+stress)) is a judgment
-- call, not measured against real hardware or real workloads.
local BASE_ORPHAN_TIMEOUT = 300

local function orphanTimeoutSeconds()
  return BASE_ORPHAN_TIMEOUT / (1 + schedulerStress())
end

-- Called every tick (see the main loop below) but only does work about
-- once a second -- the timeout is minutes, so per-tick precision buys
-- nothing. Finds every
-- "orphan"-policy job that's actually been orphaned (orphanedAt set)
-- and still running, and kills it (same best-effort raw KILL broadcast
-- as the "kill" policy, same cooperative-yield-point limitation) once
-- it's been unclaimed longer than the current dynamic timeout.
-- Re-broadcasts periodically (not just once) in case the first KILL
-- never reached a job that wasn't yielding yet when it was sent.
local KILL_RETRY_INTERVAL = 10
local ORPHAN_SWEEP_INTERVAL = 1
local lastOrphanSweep = -math.huge

local function sweepStaleOrphans()
  local now = computer.uptime()
  if now - lastOrphanSweep < ORPHAN_SWEEP_INTERVAL then return end
  lastOrphanSweep = now
  local timeout = orphanTimeoutSeconds()
  for id in pairs(runningJobs) do
    local job = jobs[id]
    if job.orphanPolicy == "orphan" and job.orphanedAt
        and now - job.orphanedAt > timeout then
      if not job.lastKillSentAt or now - job.lastKillSentAt > KILL_RETRY_INTERVAL then
        job.killReason = "killed (unclaimed orphan timed out)"
        modem.broadcast(PORT, "KILL " .. id .. " " .. job.node)
        job.lastKillSentAt = now
        unregisterOrphanCandidate(job.appName, id)
      end
    end
  end
end

-- Records a job as no longer running ("done", "error", or "lost"),
-- applies its children's orphan policies, and trims history.
local function finishJob(id, status, result, err)
  local job = jobs[id]
  runningJobs[id] = nil
  runningCount = runningCount - 1
  local node = nodes[job.node]
  if node and node.running then node.running = node.running - 1 end
  job.paused = nil
  job.status, job.result, job.error = status, result, err
  job.finishedAt = computer.uptime()
  job.code, job.program, job.args, job.migrating = nil, nil, nil, nil
  finishedOrder[#finishedOrder + 1] = id
  while #finishedOrder > MAX_FINISHED_JOBS do
    local old = table.remove(finishedOrder, 1)
    local oldJob = jobs[old]
    if oldJob then
      unregisterOrphanCandidate(oldJob.appName, old)
      jobs[old] = nil
      childrenOf[old] = nil
    end
  end
  -- Its windows stay up, marked like gmux's: ended (done or killed) or
  -- failed (error, lost).
  local windowStatus = (status == "done" or status == "killed") and "dead" or "error"
  for _, winId in ipairs(compositor.windowsOwnedBy(id)) do
    compositor.setStatus(winId, windowStatus)
  end
  -- This job is no longer running -- apply whatever orphan policy ITS
  -- OWN children declared at spawn time.
  applyOrphanPolicyForChildrenOf(id)
end

-- Liveness without a dedicated heartbeat: every message a node sends
-- refreshes it (noteNode), and workers answer PING at their jobs' yield
-- points, so a node running a job only needs probing when it has gone
-- quiet. Only nodes with running jobs are watched -- an idle node that
-- died is found out the first time a job is sent its way and goes
-- unacknowledged.
local PROBE_AFTER = 3
local DOWN_AFTER = 10
local lastLivenessCheck = -math.huge

local function markNodeDown(addr)
  nodes[addr].down = true
  print("node " .. addr .. " stopped responding -- marking it down")
  if exclusiveFullscreenOwner == addr then
    exclusiveFullscreenOwner = nil
    compositor.setExclusive(nil)
    consoleDirty = true
  end
  local lost = {}
  for id in pairs(runningJobs) do
    if jobs[id].node == addr then lost[#lost + 1] = id end
  end
  table.sort(lost)
  for _, id in ipairs(lost) do
    finishJob(id, "lost", nil, "node stopped responding")
  end
end

local function checkLiveness()
  local now = computer.uptime()
  if now - lastLivenessCheck < 1 then return end
  lastLivenessCheck = now
  local watched = {}
  for id in pairs(runningJobs) do watched[jobs[id].node] = true end
  for addr in pairs(watched) do
    local node = nodes[addr]
    if node and not node.down then
      local silent = now - math.max(node.lastSeen or 0, node.lastDispatch or 0)
      if silent > DOWN_AFTER then
        markNodeDown(addr)
      elseif silent > PROBE_AFTER and (not node.probedAt or now - node.probedAt > PROBE_AFTER) then
        node.probedAt = now
        send({type = "PING", from = selfAddr, to = addr})
      end
    end
  end
end

-- Pause, resume, or end a running process. Raw broadcasts like KILL
-- (see node/runtime.lua's noteControl); the worker acts on them at the
-- process's yield points, so a pause/kill takes effect at its next
-- yield, and a process still queued on its node is held/refused
-- before it starts.
local function controlJob(id, verb, reason)
  local job = jobs[id]
  if not job or job.status ~= "running" then
    return false, "no running job " .. tostring(id)
  end
  if verb == "PAUSE" then
    job.paused = true
  elseif verb == "RESUME" then
    job.paused = nil
  elseif verb == "KILL" then
    job.killReason = reason or "killed"
  else
    return false, "unknown control " .. tostring(verb)
  end
  modem.broadcast(PORT, verb .. " " .. id .. " " .. job.node)
  return true
end

local function isDescendantOf(id, ancestorId)
  local job = jobs[id]
  local seen = 0
  while job and job.parent and seen < 1000 do
    if job.parent == ancestorId then return true end
    job = jobs[job.parent]
    seen = seen + 1
  end
  return false
end

-- --- .mxe migration (optional, through the `mux` library) ---
--
-- An .mxe that called mux.migratable(save) is marked `migratable`. To
-- move it, the kernal broadcasts a raw "MIGRATE <id>"; at the process's
-- next yield point its worker calls `save`, sends the state back
-- (MIGRATED) and ends it there, and the kernal starts it again on the
-- target node under the SAME job id -- so its parent, children,
-- windows and app identity are untouched -- where mux.restored()
-- returns that state. A process that never opted in isn't moved; legacy
-- programs never are.
local function migrateJob(id, target)
  local job = jobs[id]
  if not job or job.status ~= "running" then return false, "no running job " .. tostring(id) end
  if not job.migratable then return false, "job " .. id .. " isn't migratable (it never called mux.migratable)" end
  if job.migrating then return false, "job " .. id .. " is already being migrated" end
  if target then
    if not nodes[target] or nodes[target].down then return false, "node isn't up: " .. tostring(target) end
    if target == job.node then return false, "job " .. id .. " is already on " .. target end
  else
    target = nextLiveNode(job.node)
    if not target then return false, "no other live node to move job " .. id .. " to" end
  end
  job.migrating = target
  modem.broadcast(PORT, "MIGRATE " .. id .. " " .. job.node)
  return true, target
end

local function handleMigrated(msg)
  local job = jobs[msg.jobId]
  if not job or job.status ~= "running" or job.node ~= msg.from or not job.migrating then return end
  local from, target = job.node, job.migrating
  if not nodes[target] or nodes[target].down then
    target = nextLiveNode(from)
  end
  job.migrating = nil
  if not target then
    finishJob(job.id, "lost", nil, "migration had no live node to restart on")
    return
  end
  if nodes[from].running then nodes[from].running = nodes[from].running - 1 end
  job.node = target
  nodes[target].running = (nodes[target].running or 0) + 1
  nodes[target].lastDispatch = computer.uptime()
  job.migrations = (job.migrations or 0) + 1
  send({type = "JOB", from = selfAddr, to = target, id = job.id, code = job.code, args = job.args,
    program = job.program, restore = msg.state})
  print("job [" .. job.id .. "] migrated from " .. from .. " to " .. target)
end

local function handleMigrateFailed(msg)
  local job = jobs[msg.jobId]
  if not job or job.node ~= msg.from or not job.migrating then return end
  job.migrating = nil
  print("job [" .. job.id .. "] couldn't migrate: " .. tostring(msg.error))
end

local function handleMigratable(msg)
  local job = jobs[msg.jobId]
  if job and job.status == "running" and job.node == msg.from and job.kind == "mxe" then
    job.migratable = true
  end
end

-- Take a node out of rotation: no new work goes to it, and every
-- migratable process on it is moved off. Others finish where they are.
local function drainNode(addr)
  local node = nodes[addr]
  if not node then return false, "unknown node: " .. tostring(addr) end
  node.draining = true
  local moved, staying = 0, 0
  for id in pairs(runningJobs) do
    local job = jobs[id]
    if job.node == addr then
      if job.migratable and migrateJob(id) then moved = moved + 1 else staying = staying + 1 end
    end
  end
  return true, moved, staying
end

local runtimeSource = nil -- loaded lazily and cached, see loadRuntime()

local function loadRuntime()
  if runtimeSource then return runtimeSource end
  local source, err = readFile("/runtime.lua")
  if not source then return nil, "could not read /runtime.lua: " .. tostring(err) end
  runtimeSource = source
  return runtimeSource
end

-- Answer a worker's BOOT request (node/bios.lua's network-boot stub) with
-- its real runtime, broadcast once -- any OTHER worker still waiting on
-- its own BOOT picks up the same reply for free, since they all need the
-- identical payload. Not wrapped in the serialized-table protocol: BOOT
-- happens before a worker has that runtime loaded at all, so it uses its
-- own plain "WORD <payload>" convention (see node/bios.lua).
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
  return address == gpuAddr or address == screenAddr
end

local function handleInvoke(msg)
  if isDisplayComponent(msg.address) and msg.from ~= exclusiveFullscreenOwner then
    send({type = "ERROR", from = selfAddr, to = msg.from, id = msg.id,
      error = "direct gpu/screen access is blocked -- use create_window, or gmuxapi.request_fullscreen() for exclusive access"})
    return
  end
  local args = msg.args or {}
  local packed = table.pack(pcall(component.invoke, msg.address, msg.method, table.unpack(args, 1, args.n or #args)))
  if packed[1] then
    -- Indexed with an explicit `n`, not appended: appending skipped
    -- nils, so a method's `nil, "reason"` came back as `"reason"` alone,
    -- a truthy first value that reads as success.
    local returns = {n = packed.n - 1}
    for i = 2, packed.n do returns[i - 1] = packed[i] end
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
  compositor.setExclusive(msg.from)
  send({type = "RESULT", from = selfAddr, to = msg.from, id = msg.id, result = {granted = true}})
end

local function handleReleaseFullscreen(msg)
  if exclusiveFullscreenOwner ~= msg.from then
    send({type = "ERROR", from = selfAddr, to = msg.from, id = msg.id,
      error = "you do not hold the fullscreen grant"})
    return
  end
  exclusiveFullscreenOwner = nil
  compositor.setExclusive(nil)
  consoleDirty = true
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
local VALID_ORPHAN_POLICIES = {orphan = true, kill = true, promote = true}

local function handleSpawn(msg)
  if not msg.code then
    send({type = "ERROR", from = selfAddr, to = msg.from, id = msg.id,
      error = "spawn needs options.code (a Lua source string) -- gmux's options.main/main_path can't cross the network"})
    return
  end
  if msg.orphanPolicy and not VALID_ORPHAN_POLICIES[msg.orphanPolicy] then
    send({type = "ERROR", from = selfAddr, to = msg.from, id = msg.id,
      error = "orphanPolicy must be one of orphan/kill/promote, got " .. tostring(msg.orphanPolicy)})
    return
  end
  if msg.parent and jobs[msg.parent] then
    local rootId = jobs[msg.parent].rootId or msg.parent
    local running = countRunningInTree(rootId)
    local live = liveNodeCount()
    if running >= live then
      send({type = "ERROR", from = selfAddr, to = msg.from, id = msg.id,
        error = "fan-out cap reached: this job tree already has " .. running ..
          " running job(s), as many as there are live worker nodes (" .. live .. ")"})
      return
    end
  end
  local jobId, targetAddr = dispatchJob(msg.code, msg.args, msg.node, msg.parent, msg.appName, msg.orphanPolicy)
  if not jobId then
    send({type = "ERROR", from = selfAddr, to = msg.from, id = msg.id, error = targetAddr})
    return
  end
  send({type = "RESULT", from = selfAddr, to = msg.from, id = msg.id, result = {id = jobId, node = targetAddr}})
end

-- gmuxapi.get_orphans(name): hands back the still-unclaimed orphan
-- handles registered under that app name, and removes them from the
-- pool -- claimed once, not re-handed-out to a second caller. This is
-- the mechanism a relaunched app uses to pick up where its last
-- instance's orphaned children left off (see docs/PROTOCOL.md's "App
-- identity and orphan reclaim").
--
-- Only jobs that are actually orphaned (their parent is no longer
-- running) can be claimed -- a child whose parent is alive stays with
-- that parent, so a second instance of the same app can't take it.
-- Orphans that already finished are returned too, with their status and
-- result, so a relaunched app can see what happened while it was gone.
-- A process may pause/resume/kill only its own descendants.
local function handleControl(msg)
  local caller = jobs[msg.caller]
  if not caller or caller.status ~= "running" or caller.node ~= msg.from then
    send({type = "ERROR", from = selfAddr, to = msg.from, id = msg.id, error = "not called from a running process"})
    return
  end
  if not isDescendantOf(msg.jobId, msg.caller) then
    send({type = "ERROR", from = selfAddr, to = msg.from, id = msg.id,
      error = "job " .. tostring(msg.jobId) .. " is not a descendant of job " .. tostring(msg.caller)})
    return
  end
  local ok, err = controlJob(msg.jobId, msg.verb, "killed by parent job " .. tostring(msg.caller))
  if not ok then
    send({type = "ERROR", from = selfAddr, to = msg.from, id = msg.id, error = err})
    return
  end
  send({type = "RESULT", from = selfAddr, to = msg.from, id = msg.id, result = true})
end

-- The process making a request, if it's really running on the node
-- that sent it.
local function callerJob(msg)
  local job = jobs[msg.caller]
  if job and job.status == "running" and job.node == msg.from then return job end
end

local function handleOutput(msg)
  local job = jobs[msg.jobId]
  if job and job.node == msg.from and type(msg.text) == "string" then
    consoleWrite(msg.text)
  end
end

-- gmuxapi.launch: a process launching a program becomes its parent.
local function handleLaunch(msg)
  local caller = callerJob(msg)
  local path = type(msg.path) == "string" and resolveProgram(msg.path)
  local reply
  if not caller then
    reply = "not called from a running process"
  elseif not path then
    reply = "program not found: " .. tostring(msg.path)
  else
    local id, addrOrErr = launchProgram(path, type(msg.args) == "table" and msg.args or {}, caller.id)
    if id then
      send({type = "RESULT", from = selfAddr, to = msg.from, id = msg.id, result = {id = id, node = addrOrErr, path = path}})
      return
    end
    reply = addrOrErr
  end
  send({type = "ERROR", from = selfAddr, to = msg.from, id = msg.id, error = reply})
end

local function handleGetOrphans(msg)
  local list, keep = {}, {}
  for _, id in ipairs(appsByName[msg.appName] or {}) do
    local job = jobs[id]
    if job and job.orphanedAt then
      list[#list + 1] = {id = job.id, node = job.node, status = job.status,
        result = job.result, error = job.error}
    elseif job then
      keep[#keep + 1] = id
    end
  end
  appsByName[msg.appName] = #keep > 0 and keep or nil
  send({type = "RESULT", from = selfAddr, to = msg.from, id = msg.id, result = list})
end

-- Both of these just delegate to the compositor (compositor.lua) -- the
-- one file in this project allowed to touch the real gpu for window
-- content. muxos.lua's job here is only wire plumbing: unwrap the
-- request, call in, wrap the reply.
local function handleCreateWindow(msg)
  msg.text = nil -- text windows are the kernal's own (the console)
  -- A window belongs to the process it was made for (create_graphics_
  -- process names its child), otherwise to the process that made it.
  if not msg.ownerJobId then
    local caller = callerJob(msg)
    msg.ownerJobId = caller and caller.id
  end
  local win, err = compositor.createWindow(msg)
  if not win then
    send({type = "ERROR", from = selfAddr, to = msg.from, id = msg.id, error = err})
    return
  end
  send({type = "RESULT", from = selfAddr, to = msg.from, id = msg.id, result = compositor.describe(win)})
end

-- Redraw an existing window. Only its owner process (or an ancestor of
-- it) may draw into it.
local function handleDrawWindow(msg)
  local caller = callerJob(msg)
  local win = compositor.getWindow(msg.windowId)
  local reply
  if not caller then
    reply = "not called from a running process"
  elseif not win then
    reply = "no such window: " .. tostring(msg.windowId)
  elseif win.ownerJobId ~= caller.id and not (win.ownerJobId and isDescendantOf(win.ownerJobId, caller.id)) then
    reply = "window " .. tostring(msg.windowId) .. " belongs to another process"
  end
  if not reply then
    local ok, err = compositor.redrawWindow(msg.windowId, msg)
    if ok then
      send({type = "RESULT", from = selfAddr, to = msg.from, id = msg.id, result = true})
      return
    end
    reply = err
  end
  send({type = "ERROR", from = selfAddr, to = msg.from, id = msg.id, error = reply})
end

local function handleGetWindows(msg)
  send({type = "RESULT", from = selfAddr, to = msg.from, id = msg.id, result = compositor.listWindows()})
end

-- First real slice of the gmux application API, muxos-shaped:
-- api.get_processes() in gmux reads one local process table; here it has
-- to be a request, since the jobs it's asking about run on other
-- physical nodes. Returns the same job records `jobs` holds -- a plain
-- list, serializable as-is since each entry is only strings/numbers.
--
-- Summaries only (no source, no result); gmuxapi.get_process(id) (the
-- GETPROCESS message) returns one job in full.
local SUMMARY_FIELDS = {"id", "node", "status", "startedAt", "finishedAt", "parent", "appName",
  "orphanPolicy", "rootId", "codePreview", "error", "paused", "kind", "path", "migratable", "migrations"}

local function handleGetProcesses(msg)
  local list = {}
  for _, id in ipairs(orderedJobIds()) do
    local job, summary = jobs[id], {}
    for _, field in ipairs(SUMMARY_FIELDS) do summary[field] = job[field] end
    list[#list + 1] = summary
  end
  send({type = "RESULT", from = selfAddr, to = msg.from, id = msg.id, result = list})
end

local function handleGetProcess(msg)
  local job = jobs[msg.jobId]
  if not job then
    send({type = "ERROR", from = selfAddr, to = msg.from, id = msg.id,
      error = "no such job (or it has been dropped from history): " .. tostring(msg.jobId)})
    return
  end
  send({type = "RESULT", from = selfAddr, to = msg.from, id = msg.id, result = job})
end

-- Fully handle one already-reassembled, deserialized message -- a
-- request (BOOT/LIST/INVOKE/.../RELEASEFULLSCREEN) is serviced
-- immediately, right here; a reply (PONG/RESULT/ERROR) is stashed into
-- replyBox for whoever's waiting on that id (waitForReply, below) to
-- pick up.
local function handleModemMessage(from, port, data)
  if not (port == PORT and type(data) == "string") then return end

  local bootFrom = data:match("^BOOT (.+)$")
  if bootFrom then
    serveBoot(bootFrom)
    return
  end

  local payload = reassemble(from, data)
  if not payload then
    return -- a partial chunk (more still coming), or not a MSG frame at all
  end

  local msg = deserialize(payload)
  -- `from` (the transport-reported sending card) is the only sender
  -- identity that can't be forged from inside a payload. Without this,
  -- any node could claim to be the fullscreen holder (bypassing
  -- handleInvoke's gate) or answer for another node's job.
  if type(msg) ~= "table" or msg.from ~= from or from == selfAddr then
    return
  end

  -- HELLO/PONG introduce a node; anything else from a known node just
  -- refreshes it (an unknown sender isn't enrolled as a worker by, say,
  -- a stray RESULT).
  if msg.type == "HELLO" or msg.type == "PONG" or nodes[msg.from] then
    noteNode(msg.from)
  end
  if msg.to ~= selfAddr then
    return
  end

  if msg.type == "LIST" then
    handleList(msg)
  elseif msg.type == "INVOKE" then
    handleInvoke(msg)
  elseif msg.type == "GETPROCESSES" then
    handleGetProcesses(msg)
  elseif msg.type == "GETPROCESS" then
    handleGetProcess(msg)
  elseif msg.type == "SPAWN" then
    handleSpawn(msg)
  elseif msg.type == "GETORPHANS" then
    handleGetOrphans(msg)
  elseif msg.type == "CONTROL" then
    handleControl(msg)
  elseif msg.type == "OUTPUT" then
    handleOutput(msg)
  elseif msg.type == "MIGRATED" then
    handleMigrated(msg)
  elseif msg.type == "MIGRATEFAILED" then
    handleMigrateFailed(msg)
  elseif msg.type == "MIGRATABLE" then
    handleMigratable(msg)
  elseif msg.type == "LAUNCH" then
    handleLaunch(msg)
  elseif msg.type == "CREATEWINDOW" then
    handleCreateWindow(msg)
  elseif msg.type == "GETWINDOWS" then
    handleGetWindows(msg)
  elseif msg.type == "DRAWWINDOW" then
    handleDrawWindow(msg)
  elseif msg.type == "REQUESTFULLSCREEN" then
    handleRequestFullscreen(msg)
  elseif msg.type == "RELEASEFULLSCREEN" then
    handleReleaseFullscreen(msg)
  elseif msg.type == "PONG" or msg.type == "RESULT" or msg.type == "ERROR" then
    if msg.id then
      if awaiting[msg.id] == msg.from then
        replyBox[msg.id] = msg
      end
      -- Generic job-completion recording: covers BOTH a submit()-dispatched
      -- job (something is actively waitForReply()-ing on it, which still
      -- picks up this same msg from replyBox) AND a handleSpawn()-dispatched
      -- one (fire-and-forget -- nothing is waiting locally, so this is the
      -- ONLY place its completion is ever recorded).
      if (msg.type == "RESULT" or msg.type == "ERROR") and jobs[msg.id] and jobs[msg.id].status == "running"
          and jobs[msg.id].node == msg.from then
        local job = jobs[msg.id]
        if msg.type == "RESULT" then
          finishJob(msg.id, "done", msg.result, nil)
        elseif job.killReason and msg.error == "killed" then
          finishJob(msg.id, "killed", nil, job.killReason)
        else
          finishJob(msg.id, "error", nil, msg.error)
        end
      end
    end
  end
end

-- Runs the command the REPL's line editor (below) just collected.
-- Forward-declared; assigned once everything it calls exists.
local runCommand

local KEY_PAGEUP, KEY_PAGEDOWN = 0xC9, 0xD1

-- Keys typed while a command is still running. Handling them inline
-- used to run a second command NESTED inside the first one's wait;
-- now they're replayed, in order, once the running command returns.
local queuedKeys = {}

-- The kernal-level interrupt: bring the console up and show it alone,
-- whatever else is going on (a stuck fullscreen app, a window covering
-- everything). `comp` returns to normal compositing.
-- Ctrl+Alt+C, pressed: exit whatever is fullscreen -- a node's
-- fullscreen grant (force-released, so a crashed holder can't trap the
-- screen), or console mode.
local function exitFullscreen()
  if exclusiveFullscreenOwner then
    print("Ctrl+Alt+C: force-releasing fullscreen grant held by " .. exclusiveFullscreenOwner)
    exclusiveFullscreenOwner = nil
  end
  compositor.setExclusive(nil)
  consoleDirty = true
end

-- Ctrl+Alt+C, held for CONSOLE_HOLD_SECONDS: the kernal-level
-- interrupt that drops into the full-screen kernal console.
local CONSOLE_HOLD_SECONDS = 1
local comboPressedAt, comboHoldFired = nil, false

local function consoleInterrupt()
  exitFullscreen()
  compositor.setExclusive("console")
  if consoleWin then compositor.setFocus(consoleWin.id) end
  scrollOffset = 0
  consoleDirty = true
  print("console only -- type 'comp' to show windows again")
end

local function scrollConsole(rows)
  setScroll(scrollOffset + rows)
end

-- The process that gets keyboard/scroll input right now: the owner of
-- the focused window, if it's a live process. Otherwise (console mode,
-- the console focused, or a window whose process has ended) the console
-- gets it. Ctrl+Alt+C always reaches the kernal.
local function focusedProcess()
  if consoleOwnsScreen() then return nil end
  local win = compositor.getFocus()
  if not win or (consoleWin and win.id == consoleWin.id) or not win.ownerJobId then return nil end
  local job = jobs[win.ownerJobId]
  if job and job.status == "running" and nodes[job.node] and not nodes[job.node].down then return job end
end

local function deliverEvent(job, event)
  send({type = "EVENT", from = selfAddr, to = job.node, jobId = job.id, event = event})
end

-- The program running in the foreground from the console (see
-- runForeground), which gets the console's typed input. The kernal
-- echoes it like a terminal: printable characters, backspace (only over
-- what was typed since the last Enter), and Enter.
local foregroundJob = nil
local foregroundTyped = ""

local function feedForeground(char, code)
  local job = jobs[foregroundJob]
  if not job or job.status ~= "running" then return false end
  deliverEvent(job, {"key_down", char, code})
  if code == KEY_ENTER then
    consoleAppend(consolePartial)
    consolePartial, foregroundTyped = "", ""
  elseif code == KEY_BACK then
    local len = utf8.len(foregroundTyped)
    if len and len > 0 then
      local cut = utf8.offset(foregroundTyped, -1)
      local removed = #foregroundTyped - cut + 1
      foregroundTyped = foregroundTyped:sub(1, cut - 1)
      consolePartial = consolePartial:sub(1, #consolePartial - removed)
    end
  elseif char and char >= 32 then
    local ok, ch = pcall(utf8.char, char)
    if ok then
      foregroundTyped = foregroundTyped .. ch
      consolePartial = consolePartial .. ch
    end
  end
  consoleDirty = true
  return true
end

local function handleKeyDown(char, code)
  heldKeys[code] = true
  -- Ctrl+Alt+C was OpenOS's own interrupt shortcut; muxos has no OpenOS
  -- underneath, so it's reclaimed as the kernal's console interrupt.
  if code == KEY_C and isControlDown() and isAltDown() then
    -- Key repeat sends more key_downs while it's held; only the first
    -- one is a press.
    if not comboPressedAt then
      comboPressedAt, comboHoldFired = computer.uptime(), false
      exitFullscreen()
    end
    return
  end
  local target = focusedProcess()
  if target then
    deliverEvent(target, {"key_down", char, code})
    return
  end
  -- Scrolling never waits behind a running command.
  if code == KEY_PAGEUP then scrollConsole(select(2, viewSize()) - 1) return end
  if code == KEY_PAGEDOWN then scrollConsole(-(select(2, viewSize()) - 1)) return end
  if commandBusy and foregroundJob and feedForeground(char, code) then return end
  if commandBusy then
    queuedKeys[#queuedKeys + 1] = {char, code}
    return
  end
  if code == KEY_ENTER then
    local line = inputBuffer
    inputBuffer = ""
    consoleAppend("muxos> " .. line)
    scrollOffset = 0
    commandBusy = true
    consoleDirty = true
    local ok, err = pcall(runCommand, line)
    commandBusy = false
    consoleDirty = true
    if not ok then print("command error: " .. tostring(err)) end
    while #queuedKeys > 0 and not commandBusy do
      local key = table.remove(queuedKeys, 1)
      handleKeyDown(key[1], key[2])
    end
  elseif code == KEY_BACK then
    local len = utf8.len(inputBuffer)
    if len and len > 0 then
      inputBuffer = inputBuffer:sub(1, utf8.offset(inputBuffer, -1) - 1)
    elseif #inputBuffer > 0 then
      inputBuffer = inputBuffer:sub(1, -2)
    end
    consoleDirty = true
  elseif char and char >= 32 then
    local ok, ch = pcall(utf8.char, char)
    if ok then
      inputBuffer = inputBuffer .. ch
      scrollOffset = 0
      consoleDirty = true
    end
  end
  -- No arrow-key history, no cursor movement within the line, no paste
  -- handling -- a flat append/backspace-only line editor.
end

local function handleKeyUp(char, code)
  heldKeys[code] = nil
  if code == KEY_C or not (isControlDown() and isAltDown()) then
    comboPressedAt = nil
  end
  local target = focusedProcess()
  if target then deliverEvent(target, {"key_up", char, code}) end
end

local function handleScroll(x, y, direction)
  local target = focusedProcess()
  if target then
    deliverEvent(target, {"scroll", x, y, direction})
  else
    -- Mouse wheel over the screen: positive direction is up.
    scrollConsole((direction or 0) > 0 and 3 or -3)
  end
end

-- --- Touch: window decorations and pointer input (gmux's touch_event) ---
--
-- A touch focuses and raises the window under it. On the title bar it
-- hits a button (minimize, maximize, close -- close also kills the
-- owner process, as in gmux) or starts a move that following drags
-- carry out; on a resizable window's bottom-right body cell it starts a
-- resize. Anything else reaches the window's owner process as
-- {"touch"/"drag"/"drop", x, y, button} in the body's own coordinates.
-- A resized window's owner gets {"window_resized", id, width, height}.
-- Nothing here while one owner has the whole screen.
local currentGrab = nil
local MIN_WINDOW_WIDTH = 8 -- room for the title bar's buttons

local function windowProcess(win)
  local job = win.ownerJobId and jobs[win.ownerJobId]
  if job and job.status == "running" and nodes[job.node] and not nodes[job.node].down then return job end
end

local function notifyResized(win)
  local job = windowProcess(win)
  if job then deliverEvent(job, {"window_resized", win.id, win.width, win.height}) end
end

local function closeWindow(win)
  local job = windowProcess(win)
  compositor.close(win.id)
  if job then controlJob(job.id, "KILL", "killed (window closed)") end
end

local function handleTouch(name, x, y, button)
  if compositor.exclusiveOwner() then currentGrab = nil return end
  if currentGrab then
    local grab = currentGrab
    local win = compositor.getWindow(grab.id)
    if name == "drop" or not win then currentGrab = nil return end
    if name == "drag" then
      if grab.kind == "move" then
        compositor.move(win.id, x - grab.dx, y)
      else
        local w = math.max(MIN_WINDOW_WIDTH, x - win.x + 1)
        local h = math.max(1, y - compositor.bodyTop(win) + 1)
        if (w ~= win.width or h ~= win.height) and compositor.resize(win.id, w, h) then notifyResized(win) end
      end
      return
    end
    currentGrab = nil -- a fresh touch ends the grab and is handled below
  end
  local win, part, lx, ly = compositor.hitTest(x, y)
  if not win then return end
  if name == "touch" then
    compositor.setFocus(win.id)
    compositor.raise(win.id)
  end
  if part == "title" then
    if name ~= "touch" then return end
    local w = win.width
    if lx == w - 5 or lx == w - 4 then
      compositor.minimize(win.id)
    elseif (lx == w - 3 or lx == w - 2) and win.resizable then
      if compositor.maximize(win.id) then notifyResized(win) end
    elseif lx == w - 1 or lx == w then
      closeWindow(win)
    else
      currentGrab = {id = win.id, kind = "move", dx = lx - 1}
    end
    return
  end
  if name == "touch" and win.resizable and win.decorated and lx == win.width and ly == win.height then
    currentGrab = {id = win.id, kind = "resize"}
    return
  end
  local job = windowProcess(win)
  if job then deliverEvent(job, {name, lx, ly, button}) end
end

-- Pulls and fully handles exactly one signal, or times out -- the ONE
-- place every wait in this program funnels through, whether that's the
-- REPL idling at its prompt or something deep in a submit()/awaitReply()
-- blocking on a specific network reply. This replaces BOTH the old
-- "separate background thread polling pump()" design AND the old
-- os.sleep(0.05)-paced maintenance loop: there is exactly one coroutine
-- here (no OpenOS thread library to fake concurrency with any more), so
-- servicing everything inline, on every signal, from wherever a wait
-- happens to be nested, is the only correct shape now -- not a
-- simplification taken for convenience, the actual consequence of there
-- being no OpenOS underneath to schedule a second thread with.
--
-- pcall-wrapped around the dispatch + maintenance work for the same
-- reason the old design's background thread was: without it, an
-- uncaught error in any single handler (a bad INVOKE, a window draw-
-- code bug, anything) would propagate all the way out of this, the
-- kernal's ONLY coroutine now -- not just killing a background thread
-- the REPL could still survive without, but the whole event loop.
local function tick(timeout)
  local name, a2, a3, a4, a5, a6 = pullSignal(timeout)
  local ok, err = pcall(function()
    if name == "key_down" then
      handleKeyDown(a3, a4)
    elseif name == "key_up" then
      handleKeyUp(a3, a4)
    elseif name == "scroll" then
      handleScroll(a3, a4, a5)
    elseif name == "touch" or name == "drag" or name == "drop" then
      handleTouch(name, a3, a4, a5)
    elseif name == "modem_message" then
      handleModemMessage(a3, a4, a6)
    end
    if comboPressedAt and not comboHoldFired and heldKeys[KEY_C] and isControlDown() and isAltDown()
        and computer.uptime() - comboPressedAt >= CONSOLE_HOLD_SECONDS then
      comboHoldFired = true
      consoleInterrupt()
    end
    sweepStaleChunks()
    sweepStaleOrphans()
    checkLiveness()
    renderConsole()
    compositor.flush()
  end)
  if not ok then
    print("tick error (continuing): " .. tostring(err))
  end
end

local function waitSeconds(duration)
  local deadline = computer.uptime() + duration
  while computer.uptime() < deadline do
    tick(deadline - computer.uptime())
  end
end

-- Broadcasts PING and just waits out `wait` seconds -- tick() (called by
-- waitSeconds) is what actually processes the HELLO/PONG replies into
-- `nodes` (noteNode) during that window.
local function discover(wait)
  send({type = "PING", from = selfAddr})
  waitSeconds(wait or 1)
end

-- Block until a reply for `id` lands in replyBox, or time out. The one
-- shared wait primitive behind submit()/listComponents()/invoke()/
-- pingOnce().
local function waitForReply(id, addr, timeout)
  local deadline = computer.uptime() + (timeout or TIMEOUT)
  awaiting[id] = addr
  while computer.uptime() < deadline do
    local msg = replyBox[id]
    if msg then
      replyBox[id] = nil
      awaiting[id] = nil
      return msg
    end
    tick(deadline - computer.uptime())
  end
  awaiting[id] = nil
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
-- node round-robin unless targetAddr is given.
-- Runs a launched program in the foreground: the console waits until it
-- ends (any way: done, error, killed, lost), feeding it typed input
-- meanwhile, like an OpenOS shell.
local function runForeground(id)
  foregroundJob, foregroundTyped = id, ""
  while jobs[id] and jobs[id].status == "running" do
    tick(0.5)
  end
  foregroundJob = nil
  if consolePartial ~= "" then
    consoleAppend(consolePartial)
    consolePartial = ""
  end
  local job = jobs[id]
  if job and job.status ~= "done" then
    print(job.status .. ": " .. tostring(job.error))
  end
end

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
    print(string.format("[%d] %s  (last seen %.1fs ago)%s", i, addr, computer.uptime() - nodes[addr].lastSeen,
      nodes[addr].down and " DOWN" or (nodes[addr].draining and " DRAINING" or "")))
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
  local ids = orderedJobIds()
  if #ids == 0 then
    print("no jobs dispatched yet")
    return
  end
  for _, id in ipairs(ids) do
    local job = jobs[id]
    local parentInfo = ""
    if job.appName or job.orphanPolicy then
      parentInfo = string.format(" (parent=%s app=%s policy=%s)",
        job.parent and tostring(job.parent) or "none", tostring(job.appName), tostring(job.orphanPolicy))
    end
    print(string.format("[%d] %s on %s%s%s", job.id, job.paused and "paused" or job.status, job.node,
      job.error and (" -- " .. job.error) or "", parentInfo))
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
  local focus = compositor.getFocus()
  for _, win in ipairs(list) do
    local tags = ""
    if focus and win.id == focus.id then tags = tags .. " (focused)" end
    if win.ownerJobId then tags = tags .. " (owner job " .. win.ownerJobId .. ")" end
    if win.minimized then tags = tags .. " (minimized)" end
    if win.maximized then tags = tags .. " (maximized)" end
    if win.status then tags = tags .. " (process " .. win.status .. ")" end
    print(string.format("[%d] %q  %dx%d at (%d,%d)%s", win.id, win.title, win.width, win.height, win.x, win.y, tags))
  end
end

runCommand = function(line)
  if not line or line == "quit" or line == "exit" then
    shutdown(false)
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
      if nodes[addr].down then goto continue end
      local result, err = submit(code, nil, addr)
      if err then print(addr .. ": error: " .. err)
      else print(addr .. ": " .. tostring(result)) end
      ::continue::
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
  elseif line:match("^console%s") then
    local w, h, x, y = line:match("^console%s+(%d+)%s+(%d+)%s*(%d*)%s*(%d*)$")
    w, h, x, y = tonumber(w), tonumber(h), tonumber(x), tonumber(y)
    if not w then
      print("usage: console <width> <height> [x y]  (default: docked bottom-left)")
    elseif w < CONSOLE_MIN_W or h < CONSOLE_MIN_H or w > termW or h > termH then
      print(string.format("console size must be between %dx%d and %dx%d", CONSOLE_MIN_W, CONSOLE_MIN_H, termW, termH))
    else
      x, y = x or 1, y or (termH - h + 1)
      if x + w - 1 > termW or y + h - 1 > termH then
        print("that doesn't fit on the screen")
      else
        compositor.setGeometry(consoleWin.id, x, y, w, h)
        consoleW, consoleH = w, h
        setScroll(scrollOffset)
        consoleDirty = true
        print(string.format("console is now %dx%d at (%d,%d)", w, h, x, y))
      end
    end
  elseif line:match("^pause%s") or line:match("^resume%s") or line:match("^kill%s") then
    local verb, idStr = line:match("^(%a+)%s+(%d+)$")
    if not verb then
      print("usage: pause|resume|kill <job id>")
    else
      local ok, err = controlJob(tonumber(idStr), verb:upper(), "killed by user")
      if ok then print(verb .. " sent to job [" .. idStr .. "]") else print("error: " .. err) end
    end
  elseif line:match("^migrate%s") then
    local idStr, target = line:match("^migrate%s+(%d+)%s*(%S*)$")
    if not idStr then
      print("usage: migrate <job id> [node]")
    else
      local ok, result = migrateJob(tonumber(idStr), target ~= "" and resolveNode(target) or nil)
      if ok then print("migrating job [" .. idStr .. "] to " .. result) else print("error: " .. result) end
    end
  elseif line:match("^drain%s") or line:match("^undrain%s") then
    local verb, target = line:match("^(%a+)%s+(%S+)$")
    local addr = target and resolveNode(target)
    if not addr then
      print("usage: drain|undrain <node>")
    elseif verb == "undrain" then
      if nodes[addr] then nodes[addr].draining = nil print(addr .. " takes new work again") else print("unknown node: " .. addr) end
    else
      local ok, moved, staying = drainNode(addr)
      if ok then
        print(string.format("draining %s: moving %d migratable job(s), %d will finish there", addr, moved, staying))
      else
        print("error: " .. moved)
      end
    end
  elseif line == "comp" then
    -- Back to normal compositing from console mode.
    -- Only takes the screen back from the console, never from a node
    -- holding the fullscreen grant.
    if consoleOwnsScreen() then compositor.setExclusive(nil) end
    scrollOffset = 0
    consoleDirty = true
    print("compositor restored -- all windows shown")
  elseif line:match("^focus%s") then
    -- Manual stand-in for the gesture that will eventually move focus
    -- for real (there's no mouse/click component anywhere in this
    -- project) -- see kernal/compositor.lua's M.setFocus. Moving focus
    -- doesn't yet DO anything beyond being observable via `windows`
    -- (handleKeyDown below still only ever feeds the kernal's own REPL
    -- input buffer) -- that's the next piece, not this one.
    local idStr = line:match("^focus%s+(%d+)$")
    if not idStr then
      print("usage: focus <window id>")
    else
      local ok, err = compositor.setFocus(tonumber(idStr))
      if ok then print("window [" .. idStr .. "] focused") else print("error: " .. err) end
    end
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
    -- Not a built-in: run it as a program, OpenOS-shell style. A
    -- trailing "&" runs it in the background.
    local words = {}
    for word in line:gmatch("%S+") do words[#words + 1] = word end
    local background = words[#words] == "&"
    if background then table.remove(words) end
    local path = words[1] and resolveProgram(words[1])
    if not path then
      print("unknown command")
      return
    end
    local id, addrOrErr = launchProgram(path, {table.unpack(words, 2)})
    if not id then
      print("error: " .. addrOrErr)
    elseif background then
      print("[" .. id .. "] " .. path .. " started on " .. addrOrErr)
    else
      runForeground(id)
    end
  end
end

print("muxos kernal -- " .. selfAddr)
print("commands:")
print("  discover | nodes | ping <node> [count] | quit")
print("  run <lua code> | runall <lua code> | processes | pause|resume|kill <job id>")
print("  migrate <job id> [node] | drain|undrain <node>")
print("  spawn <node> <lua code>")
print("  window <title> <x> <y> <width> <height> <lua code drawing into `gpu`> | windows")
print("  console <width> <height> [x y] -- resize/move the console window")
print("  comp -- leave console mode (hold Ctrl+Alt+C to enter it; a press exits fullscreen); PgUp/PgDn or the wheel scroll")
print("  focus <window id> -- moves keyboard focus (manual stand-in -- no mouse/click gesture exists yet)")
print("  bitdemo <halfblock|braille> <x> <y> -- draws a test pattern as a bit window")
print("  components <node> | call <node> <component addr> <method> [args table]")
print("(<node> is either a [n] index from 'nodes' or a full node address)")
discover(1)
listNodes()

while true do
  tick(0.05) -- ~1 tick between idle maintenance passes (sweepStaleChunks/compositor.flush)
end
