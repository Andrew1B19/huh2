-- A purpose-built, faithful-to-source OpenComputers emulator for huh2's
-- bare-metal files. NOT the community OCEmu -- that needs a full LÖVE2D
-- graphics runtime, which isn't installable headless in this project's
-- dev environment. This instead models exactly the native primitives
-- the real production files actually use, each verified against the
-- mod's own Scala source this session (see docs/PROTOCOL.md's "The
-- kernal is bare-metal" section): `component.list`/`invoke`,
-- `coroutine.yield`-based signal pulling, `computer.address`/`beep`/
-- `uptime`/`pushSignal`, a broadcast-only Network Card, a filesystem
-- component (`open`/`read`/`close`/`exists`), an EEPROM component
-- (`getData`/`setData`), and a Tier-3 GPU/screen pair
-- (`allocateBuffer`/`freeBuffer`/`setActiveBuffer`/`getBufferSize`/
-- `getResolution`/`bind`/`set`/`fill`/`copy`/`bitblt`/`setForeground`/
-- `setBackground`).
--
-- Each node runs its REAL boot file, unmodified, as a genuine Lua
-- coroutine, driven the same way the mod's own
-- NativeLuaArchitecture.runThreaded drives a real computer: resumed
-- with a signal's name+args once one arrives, or with nothing once a
-- yielded timeout elapses, whichever comes first. Every node's globals
-- table deliberately does NOT include `os`, `io`, `require`, `dofile`,
-- or `loadfile` -- the same absence real bare hardware has -- so if any
-- production file ever accidentally reaches for one of those, this
-- emulator fails the same way real hardware would, rather than
-- silently succeeding against the test host's own real standard
-- library.
--
-- Known, deliberate simplifications (not hidden): no energy/power
-- model, no call-budget enforcement (`callBudget`/`direct` methods --
-- see docs/PROTOCOL.md's "Call budget" section -- are not simulated;
-- this emulator is about CORRECTNESS of the Lua-level protocol and
-- control flow, not about reproducing OC's per-tick GPU-call ceiling),
-- no network latency/relay-delay model beyond "delivered on the next
-- scheduler step" (see docs/PROTOCOL.md's "Measured vs. documented
-- latency" -- this was never confirmed from source either), and no
-- Minecraft world/item simulation at all.

local Emulator = {}
Emulator.__index = Emulator

local BASE_GLOBALS = {
  "assert", "error", "ipairs", "load", "next", "pairs", "pcall", "print",
  "rawequal", "rawget", "rawlen", "rawset", "select", "setmetatable",
  "tonumber", "tostring", "type", "xpcall",
}

function Emulator.new()
  local self = setmetatable({}, Emulator)
  self.nodes = {}
  self.nodeOrder = {}
  self.now = 0.0
  self._nextAddr = 1
  self.log = {} -- {t, node, msg} -- every node's own print() output, captured
  return self
end

function Emulator:allocAddress(prefix)
  local n = self._nextAddr
  self._nextAddr = n + 1
  return string.format("%s-%08x", prefix, n)
end

function Emulator:_logf(node, fmt, ...)
  self.log[#self.log + 1] = {t = self.now, node = node.address, msg = string.format(fmt, ...)}
end

-- ---------------------------------------------------------------- --
-- Node creation and the native component/computer API each one gets.
-- ---------------------------------------------------------------- --

function Emulator:newNode(kind)
  local address = self:allocAddress(kind)
  local node = {
    address = address,
    kind = kind,
    emu = self,
    components = {},      -- addr -> {type=, methods={name -> fn}}
    componentOrder = {},
    modemOpenPorts = {},  -- port -> true, for whichever modem component this node has
    signalQueue = {},
    status = "fresh",     -- fresh | running | dead
    wakeAt = nil,          -- sim-time to resume even without a signal; nil = wait forever
    co = nil,
    env = nil,
  }
  self.nodes[address] = node
  self.nodeOrder[#self.nodeOrder + 1] = address
  return node
end

function Emulator:addComponent(node, ctype, methods)
  local addr = self:allocAddress(ctype)
  node.components[addr] = {type = ctype, methods = methods}
  node.componentOrder[#node.componentOrder + 1] = addr
  return addr
end

local function makeComponentAPI(node)
  return {
    list = function(filter)
      local matches = {}
      for _, addr in ipairs(node.componentOrder) do
        local c = node.components[addr]
        if not filter or c.type == filter then
          matches[#matches + 1] = {addr, c.type}
        end
      end
      local i = 0
      return function()
        i = i + 1
        if matches[i] then return matches[i][1], matches[i][2] end
        return nil
      end
    end,
    invoke = function(address, method, ...)
      local c = node.components[address]
      if not c then error("no such component: " .. tostring(address), 0) end
      local fn = c.methods[method]
      if not fn then error("no such method '" .. tostring(method) .. "' on a " .. c.type, 0) end
      return fn(...)
    end,
    type = function(address)
      local c = node.components[address]
      if not c then return nil, "no such component" end
      return c.type
    end,
  }
end

local function makeComputerAPI(node)
  return {
    address = function() return node.address end,
    uptime = function() return node.emu.now end,
    beep = function(...) node.emu:_logf(node, "BEEP(%s)", table.concat({...}, ", ")) end,
    pushSignal = function(...)
      node.signalQueue[#node.signalQueue + 1] = {...}
    end,
  }
end

-- Deliberately excludes os/io/require/dofile/loadfile -- see this
-- file's own header for why that absence is the point, not an
-- oversight.
function Emulator:buildEnv(node)
  local env = {}
  for _, name in ipairs(BASE_GLOBALS) do
    env[name] = _G[name]
  end
  env.string, env.table, env.math, env.utf8, env.debug, env.coroutine =
    string, table, math, utf8, debug, coroutine
  env._G = env
  env.component = makeComponentAPI(node)
  env.computer = makeComputerAPI(node)
  -- A bare `load(chunk, name)` call with no explicit 4th argument
  -- defaults to the REAL host _G, not the calling chunk's own _ENV --
  -- confirmed empirically, not assumed. On real hardware this is
  -- harmless (there's only one _G per computer, already holding the
  -- native component/computer globals), which is exactly why
  -- kernal/bios.lua's own `load(buffer, "=muxos")` call (and
  -- kernal/muxos.lua's `loadSibling`) never pass an explicit env --
  -- but this emulator runs all 4 nodes in ONE real Lua state, so
  -- without this wrapper, any bare load() inside a node's code would
  -- silently leak the TEST HOST's real globals (real os/io, no
  -- simulated component/computer) into whatever it loads. Rebinding
  -- this node's own `load` to default to ITS OWN env reproduces the
  -- single-shared-_G-per-computer behavior real hardware gets for
  -- free.
  env.load = function(chunk, chunkname, mode, loadEnv)
    return load(chunk, chunkname, mode, loadEnv or env)
  end
  -- The real native `print` only logs to the Java server console, never
  -- the in-game screen (confirmed from SystemAPI.scala's own source
  -- comment) -- captured here the same way, into the emulator's shared
  -- log, rather than either reaching a "screen" or polluting the test
  -- run's own stdout.
  env.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    node.emu:_logf(node, "%s", table.concat(parts, "\t"))
  end
  node.env = env
  return env
end

-- ---------------------------------------------------------------- --
-- Simulated components.
-- ---------------------------------------------------------------- --

-- Network Card: open()/broadcast() only -- confirmed by direct audit
-- that nothing in this project's production files ever calls
-- modem.send (unicast); every message type is broadcast, with logical
-- addressing carried inside the payload's own `to` field instead.
function Emulator:addModem(node)
  local addr = self:addComponent(node, "modem", {
    open = function(port) node.modemOpenPorts[port] = true; return true end,
    broadcast = function(port, ...)
      for _, otherAddr in ipairs(node.emu.nodeOrder) do
        if otherAddr ~= node.address then
          local other = node.emu.nodes[otherAddr]
          if other.modemOpenPorts[port] then
            other.signalQueue[#other.signalQueue + 1] =
              {"modem_message", otherAddr, node.address, port, 0, ...}
          end
        end
      end
      return true
    end,
  })
  return addr
end

-- EEPROM: only getData/setData are used (the boot-address memory both
-- kernal/bios.lua and kernal/muxos.lua's own re-discovery rely on) --
-- not a real code-storage EEPROM, since this emulator calls each
-- node's real boot chunk directly rather than "flashing" it first.
function Emulator:addEeprom(node)
  local data = ""
  return self:addComponent(node, "eeprom", {
    getData = function() return data end,
    setData = function(d) data = d or ""; return true end,
  })
end

-- Filesystem: in-memory, pre-populated from `files` (path -> content).
-- `read`'s handle convention (a plain number, not an io.open()-style
-- object) matches the real component filesystem API this wraps.
function Emulator:addFilesystem(node, files)
  local handles = {}
  local nextHandle = 1
  return self:addComponent(node, "filesystem", {
    open = function(path, mode)
      if not files[path] then return nil, "file not found" end
      local h = nextHandle
      nextHandle = nextHandle + 1
      handles[h] = {path = path, pos = 1}
      return h
    end,
    read = function(handle, n)
      local h = handles[handle]
      if not h then return nil, "invalid handle" end
      local content = files[h.path]
      if h.pos > #content then return nil end
      n = math.min(n or math.huge, #content - h.pos + 1)
      local chunk = content:sub(h.pos, h.pos + n - 1)
      h.pos = h.pos + #chunk
      return chunk
    end,
    close = function(handle) handles[handle] = nil; return true end,
    exists = function(path) return files[path] ~= nil end,
  })
end

-- GPU + screen (Tier 3): buffer 0 is always the screen, matching the
-- real convention confirmed in GraphicsCard.scala's own doc comment
-- ("Index 0 is always reserved for the screen"). Returns the gpu
-- component's address AND the live `buffers` table (buffers[0] is the
-- screen) so test scenarios can inspect rendered output directly.
function Emulator:addGpuScreen(node, screenW, screenH)
  local buffers = {[0] = {w = screenW, h = screenH, cells = {}}}
  local nextBuf = 1
  local active = 0
  local fg, bg = 0xFFFFFF, 0x000000
  local boundScreen = nil

  local function getCell(buf, x, y)
    buf.cells[y] = buf.cells[y] or {}
    local row = buf.cells[y]
    row[x] = row[x] or {char = " ", fg = 0xFFFFFF, bg = 0x000000}
    return row[x]
  end

  local gpuMethods = {
    bind = function(screenAddr) boundScreen = screenAddr; return true end,
    getResolution = function() return buffers[0].w, buffers[0].h end,
    allocateBuffer = function(w, h)
      w = w or buffers[0].w
      h = h or buffers[0].h
      local idx = nextBuf
      nextBuf = nextBuf + 1
      buffers[idx] = {w = w, h = h, cells = {}}
      return idx
    end,
    freeBuffer = function(idx) buffers[idx] = nil; return true end,
    getBufferSize = function(idx)
      local b = buffers[idx]
      if not b then return nil, "invalid buffer" end
      return b.w, b.h
    end,
    setActiveBuffer = function(idx) active = idx; return true end,
    getActiveBuffer = function() return active end,
    setForeground = function(c) local old = fg; fg = c; return old end,
    setBackground = function(c) local old = bg; bg = c; return old end,
    set = function(x, y, text)
      local buf = buffers[active]
      for i = 1, #text do
        local cell = getCell(buf, x + i - 1, y)
        cell.char, cell.fg, cell.bg = text:sub(i, i), fg, bg
      end
      return true
    end,
    fill = function(x, y, w, h, char)
      local buf = buffers[active]
      for row = y, y + h - 1 do
        for col = x, x + w - 1 do
          local cell = getCell(buf, col, row)
          cell.char, cell.fg, cell.bg = char, fg, bg
        end
      end
      return true
    end,
    copy = function(x, y, w, h, tx, ty)
      local buf = buffers[active]
      -- Snapshot first -- source and destination regions can overlap
      -- (this is exactly how a scroll-up is implemented in
      -- kernal/muxos.lua's own termWrite/scrollUp).
      local snapshot = {}
      for row = y, y + h - 1 do
        snapshot[row] = {}
        for col = x, x + w - 1 do
          local c = getCell(buf, col, row)
          snapshot[row][col] = {char = c.char, fg = c.fg, bg = c.bg}
        end
      end
      for row = y, y + h - 1 do
        for col = x, x + w - 1 do
          local src = snapshot[row][col]
          local dst = getCell(buf, col + tx, row + ty)
          dst.char, dst.fg, dst.bg = src.char, src.fg, src.bg
        end
      end
      return true
    end,
    bitblt = function(dstIdx, x, y, w, h, srcIdx, fx, fy)
      dstIdx = dstIdx or 0
      srcIdx = srcIdx or active
      local dst, src = buffers[dstIdx], buffers[srcIdx]
      if not dst or not src then return nil, "invalid buffer" end
      w = w or src.w
      h = h or src.h
      fx = fx or 1
      fy = fy or 1
      for row = 0, h - 1 do
        for col = 0, w - 1 do
          local s = getCell(src, fx + col, fy + row)
          local d = getCell(dst, x + col, y + row)
          d.char, d.fg, d.bg = s.char, s.fg, s.bg
        end
      end
      return true
    end,
  }
  local gpuAddr = self:addComponent(node, "gpu", gpuMethods)
  local screenAddr = self:addComponent(node, "screen", {
    isOn = function() return true end,
    turnOn = function() return true end,
    turnOff = function() return false end,
  })
  return gpuAddr, screenAddr, buffers
end

-- ---------------------------------------------------------------- --
-- Scheduling -- drives each node's coroutine the same way the mod's
-- own NativeLuaArchitecture.runThreaded drives a real computer.
-- ---------------------------------------------------------------- --

function Emulator:boot(node, chunk, ...)
  node.co = coroutine.create(chunk)
  node.status = "running"
  self:_resume(node, ...)
end

function Emulator:_resume(node, ...)
  if node.status ~= "running" then return end
  local ok, a = coroutine.resume(node.co, ...)
  if not ok then
    node.status = "dead"
    self:_logf(node, "CRASHED: %s", tostring(a))
    return
  end
  if coroutine.status(node.co) == "dead" then
    node.status = "dead"
    self:_logf(node, "halted (chunk returned: %s)", tostring(a))
    return
  end
  if type(a) == "number" then
    node.wakeAt = self.now + a
  elseif type(a) == "boolean" then
    node.status = "dead"
    self:_logf(node, a and "rebooting" or "shut down")
  else
    node.wakeAt = nil -- wait indefinitely for a signal (a bare coroutine.yield())
  end
end

-- Runs exactly one scheduler step: service a queued signal if any node
-- has one (zero added delay, matching a real popSignal() being ready
-- immediately), otherwise advance `now` to the earliest pending
-- wakeAt and resume that node. Returns false if nothing is scheduled
-- (every running node is waiting forever with an empty queue).
function Emulator:step()
  for _, addr in ipairs(self.nodeOrder) do
    local node = self.nodes[addr]
    if node.status == "running" and #node.signalQueue > 0 then
      local sig = table.remove(node.signalQueue, 1)
      self:_resume(node, table.unpack(sig))
      return true
    end
  end
  local earliest, earliestNode = nil, nil
  for _, addr in ipairs(self.nodeOrder) do
    local node = self.nodes[addr]
    if node.status == "running" and node.wakeAt then
      if not earliest or node.wakeAt < earliest then
        earliest, earliestNode = node.wakeAt, node
      end
    end
  end
  if not earliestNode then return false end
  self.now = earliest
  self:_resume(earliestNode)
  return true
end

-- Advances simulated time by `seconds`, running as many steps as
-- needed (including ones with zero added delay, like queued signals).
function Emulator:advance(seconds)
  local deadline = self.now + seconds
  while self.now < deadline do
    if not self:step() then
      self.now = deadline
      break
    end
  end
  if self.now < deadline then self.now = deadline end
end

-- Runs steps until `predicate()` is true or `maxSteps` is hit (default
-- 200000) or nothing is scheduled any more. Returns whether the
-- predicate ended up true.
function Emulator:runUntil(predicate, maxSteps)
  for _ = 1, (maxSteps or 200000) do
    if predicate() then return true end
    if not self:step() then return predicate() end
  end
  return predicate()
end

-- Delivers a signal directly into a node's queue -- used by test
-- scenarios to inject key_down/key_up (the REPL has no other input
-- source) the same way a real keyboard component's events arrive.
function Emulator:injectSignal(node, ...)
  node.signalQueue[#node.signalQueue + 1] = {...}
end

return Emulator
