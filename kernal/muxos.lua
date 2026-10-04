-- muxos kernal "init" for huh2. This REPLACES OpenOS on the kernal --
-- it is the entire resident environment, not a program that runs under
-- one. kernal/bios.lua (this node's own tiny EEPROM image, mirroring
-- the mod's own stock EEPROM bios almost line for line) loads and calls
-- this file directly off the boot filesystem; there is no OpenOS
-- /init.lua anywhere in this picture.
--
-- Everything OpenOS would normally provide at this point --
-- computer.pullSignal, event.pull/listen, thread.create, the keyboard
-- library, io/print-to-screen, component.proxy/dot-shorthand access --
-- is confirmed ABSENT from the mod's own native Lua sandbox surface,
-- verified directly against its Scala source
-- (li.cil.oc.server.machine.luac.{ComponentAPI,ComputerAPI,SystemAPI}):
-- component's real surface is only list/type/slot/methods/invoke/doc;
-- computer has no pullSignal at all (the real primitive is yielding the
-- kernel coroutine, caught by NativeLuaArchitecture.runThreaded); and
-- the native `print` only logs to the Java server console per its own
-- source comment ("Until we get to ingame screens we log to Java's
-- stdout"), never the in-game screen. So this file builds every one of
-- those itself from the real primitives (component.list/component.invoke,
-- coroutine.yield) instead of assuming OpenOS is there to provide them
-- -- the same bare-metal discipline node/bios.lua and node/runtime.lua
-- already had to follow, just applied here too now instead of resting
-- on a normal OpenOS boot underneath.
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
local TIMEOUT = 5 -- seconds to wait for a worker reply before giving up

-- The real primitive behind every blocking wait in this file. Yielding
-- the kernel coroutine with a timeout (in seconds) IS computer.pullSignal's
-- actual underlying mechanism -- confirmed from NativeLuaArchitecture's
-- runThreaded, which resumes a yielded coroutine with the next signal's
-- name + args once one arrives (or with nothing, if the timeout simply
-- elapses first).
local function pullSignal(timeout)
  return coroutine.yield(timeout)
end

-- Yielding a plain boolean is the real shutdown/reboot primitive
-- (false = power off, true = reboot) -- OpenOS's own computer.shutdown()
-- is just a wrapper over this. Falling off the end of this file instead
-- (a normal Lua `return`) is NOT a clean shutdown -- the mod's own
-- runThreaded treats that as "the kernel stopped unexpectedly" and logs
-- a warning, so "quit"/"exit" at the REPL go through this instead.
local function shutdown(reboot)
  coroutine.yield(reboot and true or false)
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
-- overhead. Only one node may hold it at a time.
local exclusiveFullscreenOwner = nil

-- The compositor is the only code in this whole project that makes a
-- real gpu.* call for WINDOW content -- see compositor.lua's own header
-- for why that's worth enforcing structurally, not just by convention.
-- It's loaded with loadSibling itself as its chunk argument, so it can
-- load bitmap.lua the same way this file loaded it.
local compositor = loadSibling("compositor.lua")(loadSibling)

-- The kernal's own gpu/screen, cached once -- used for isDisplayComponent
-- (below) AND for the REPL's own minimal text console (see "Minimal
-- built-in terminal" below): there is no OpenOS io/term to print through
-- any more, so the REPL draws onto the SAME real screen the compositor
-- owns, directly, the one other place in this project allowed to touch
-- the real gpu (the compositor's own windows still composite on top of
-- whatever the console drew, in z-order, same as any other screen content).
local gpu, gpuAddr = primaryComponent("gpu")
local _, screenAddr = primaryComponent("screen")
if gpu and screenAddr then
  tryInvoke(gpuAddr, "bind", screenAddr)
end

-- --- Minimal built-in terminal, replacing OpenOS's io/term entirely ---

local termW, termH = 1, 1
if gpu then
  termW, termH = gpu.getResolution()
end
local cursorX, cursorY = 1, 1

local function scrollUp()
  gpu.copy(1, 2, termW, termH - 1, 0, -1)
  gpu.fill(1, termH, termW, 1, " ")
end

local function newline()
  cursorX = 1
  cursorY = cursorY + 1
  if cursorY > termH then
    scrollUp()
    cursorY = termH
  end
end

-- No word-wrap, no scrollback, no resize handling -- a flat fixed-width
-- console that scrolls one row at a time. A real gap against a proper
-- terminal, flagged rather than hidden, same honesty-over-coverage
-- standard as everything else in this project; good enough for a REPL
-- whose output is mostly short status lines.
local function termWrite(text)
  if not gpu then return end
  local pos = 1
  local len = #text
  while pos <= len do
    local nl = text:find("\n", pos, true)
    local lineEnd = (nl or len + 1) - 1
    while pos <= lineEnd do
      local available = termW - cursorX + 1
      local take = math.min(available, lineEnd - pos + 1)
      if take > 0 then
        gpu.set(cursorX, cursorY, text:sub(pos, pos + take - 1))
        cursorX = cursorX + take
        pos = pos + take
      end
      if cursorX > termW then
        newline()
      end
    end
    if nl then
      newline()
      pos = nl + 1
    end
  end
end

-- Shadows the native `print` (which only logs to the Java server
-- console, not the in-game screen -- see this file's header) for every
-- call below this point in the same chunk.
local function print(...)
  local n = select("#", ...)
  local parts = {}
  for i = 1, n do parts[i] = tostring((select(i, ...))) end
  termWrite(table.concat(parts, "\t") .. "\n")
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

-- id -> {id, node, status, code, startedAt, finishedAt, result, error}
-- status is "running", "done", or "error".
local jobs = {}
local jobOrder = {}

-- id -> the RESULT/ERROR/PONG message that answered it. Filled in by
-- handleModemMessage (see below), read and cleared by waitForReply.
local replyBox = {}

-- Record a job's dispatch and actually send it, WITHOUT waiting for the
-- result -- shared by submit() (which then blocks on awaitReply itself)
-- and handleSpawn() (which must return to the calling worker immediately,
-- gmux's own create_headless_process/create_graphics_process being
-- fire-and-forget: you get a handle back right away, not the result).
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
-- one file in this project allowed to touch the real gpu for window
-- content. muxos.lua's job here is only wire plumbing: unwrap the
-- request, call in, wrap the reply.
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
  if type(msg) ~= "table" or not msg.from or msg.from == selfAddr then
    return
  end

  if msg.type == "HELLO" or msg.type == "PONG" then
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
end

-- Runs the command the REPL's line editor (below) just collected.
-- Forward-declared; assigned once everything it calls exists.
local runCommand

-- The REPL's current input line, built up one key_down signal at a time
-- (see "Minimal built-in terminal" and handleKeyDown below) since there
-- is no io.read() to block on any more.
local inputBuffer = ""

local function promptLine()
  termWrite("muxos> ")
end

local function handleKeyDown(char, code)
  heldKeys[code] = true
  -- Local escape hatch: Ctrl+Alt+C at the kernal force-releases the
  -- fullscreen grant regardless of who holds it, so a crashed/
  -- disconnected holder doesn't require restarting the kernal.
  --
  -- REAL CONFLICT, not hidden: Ctrl+Alt+C is OpenOS's OWN built-in
  -- process-interrupt shortcut (see docs/PROTOCOL.md for the full
  -- finding). That conflict no longer applies quite the same way now
  -- that muxos doesn't run under OpenOS at all -- there is no OpenOS
  -- process-interrupt mechanism here to collide with any more -- but
  -- the combo is kept as specified rather than reclaimed for something
  -- else, since it's still a reasonable "exit fullscreen" mnemonic on
  -- its own.
  if code == KEY_C and isControlDown() and isAltDown() then
    if exclusiveFullscreenOwner then
      print("Ctrl+Alt+C: force-releasing fullscreen grant held by " .. exclusiveFullscreenOwner)
      exclusiveFullscreenOwner = nil
    end
    return
  end
  if code == KEY_ENTER then
    termWrite("\n")
    local line = inputBuffer
    inputBuffer = ""
    runCommand(line)
    promptLine()
  elseif code == KEY_BACK then
    if #inputBuffer > 0 then
      inputBuffer = inputBuffer:sub(1, -2)
      if cursorX > 1 then
        cursorX = cursorX - 1
        gpu.set(cursorX, cursorY, " ")
      end
    end
  elseif char and char >= 32 then
    local ok, ch = pcall(utf8.char, char)
    if ok then
      inputBuffer = inputBuffer .. ch
      termWrite(ch)
    end
  end
  -- No arrow-key history, no cursor movement within the line, no paste
  -- handling -- a flat append/backspace-only line editor. A real gap
  -- against a proper shell, flagged rather than hidden, same standard
  -- as the rest of this project.
end

local function handleKeyUp(code)
  heldKeys[code] = nil
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
      handleKeyUp(a4)
    elseif name == "modem_message" then
      handleModemMessage(a3, a4, a6)
    end
    sweepStaleChunks()
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
  while computer.uptime() < deadline do
    local msg = replyBox[id]
    if msg then
      replyBox[id] = nil
      return msg
    end
    tick(deadline - computer.uptime())
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
-- node round-robin unless targetAddr is given.
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
promptLine()

while true do
  tick(0.05) -- ~1 tick between idle maintenance passes (sweepStaleChunks/compositor.flush)
end
