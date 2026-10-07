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
-- Every node boots through the mod's OWN machine.lua (vendored,
-- unmodified, in test/emu/oc/): the emulator plays the Java host --
-- raw computer/component/system/unicode APIs underneath, resuming
-- machine.lua's main loop with signals and honoring what it yields
-- (a sleep timeout, a shutdown boolean, an indirect component call).
-- So muxos's EEPROM code runs inside the real sandbox: wrapped
-- coroutine.yield/resume, the Lua-side computer.pullSignal, no
-- debug.sethook, no eris, and the real "too long without yielding"
-- deadline (measured in host CPU time via os.clock; `emu.timeout`
-- plays system.timeout()). An earlier version ran the boot code
-- directly against raw Lua primitives instead, which hid three
-- real-hardware breakages (see docs/PROTOCOL.md's "The real sandbox").
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

local MACHINE_PATH = (debug.getinfo(1, "S").source:match("^@(.*)emulator%.lua$") or "./") .. "oc/machine.lua"
local machineSource
do
  local f = assert(io.open(MACHINE_PATH, "r"), "missing " .. MACHINE_PATH)
  machineSource = f:read("a")
  f:close()
end

function Emulator.new()
  local self = setmetatable({}, Emulator)
  self.nodes = {}
  self.nodeOrder = {}
  self.now = 0.0
  self._nextAddr = 1
  self.timeout = 5 -- seconds of host CPU time per slice, like system.timeout()
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
  -- The machine's own "computer" component (machine.lua's
  -- computer.beep etc. invoke it at computer.address()).
  node.components[address] = {type = "computer", methods = {
    beep = function(...) self:_logf(node, "BEEP(%s)", table.concat({...}, ", ")) return true end,
    getDeviceInfo = function() return {} end,
  }}
  node.componentOrder[#node.componentOrder + 1] = address
  return node
end

function Emulator:addComponent(node, ctype, methods)
  local addr = self:allocAddress(ctype)
  node.components[addr] = {type = ctype, methods = methods}
  node.componentOrder[#node.componentOrder + 1] = addr
  return addr
end

-- --- The host side machine.lua runs on (what the mod's Java code provides) ---

local function hostComponentAPI(node)
  return {
    list = function(filter, exact)
      local result = {}
      for _, addr in ipairs(node.componentOrder) do
        local t = node.components[addr].type
        if not filter or (exact and t == filter) or (not exact and t:find(filter, 1, true)) then
          result[addr] = t
        end
      end
      return result
    end,
    type = function(address)
      local c = node.components[address]
      if not c then return nil, "no such component" end
      return c.type
    end,
    slot = function(address)
      if not node.components[address] then return nil, "no such component" end
      return -1
    end,
    methods = function(address)
      local c = node.components[address]
      if not c then return nil, "no such component" end
      local methods = {}
      for name in pairs(c.methods) do methods[name] = {direct = true, getter = false, setter = false} end
      return methods
    end,
    doc = function() return nil end,
    -- Host convention machine.lua's processResult expects: (true, ...)
    -- on success, (false, reason) on failure.
    invoke = function(address, method, ...)
      local c = node.components[address]
      if not c then return false, "no such component" end
      local fn = c.methods[method]
      if not fn then return false, "no such method" end
      local result = table.pack(pcall(fn, ...))
      if result[1] then return true, table.unpack(result, 2, result.n) end
      return false, result[2]
    end,
  }
end

local function hostComputerAPI(node)
  return {
    address = function() return node.address end,
    uptime = function() return node.emu.now end,
    realTime = os.clock,
    pushSignal = function(...)
      node.signalQueue[#node.signalQueue + 1] = table.pack(...)
      return true
    end,
    freeMemory = function() return 1024 * 1024 end,
    totalMemory = function() return 2 * 1024 * 1024 end,
    energy = function() return 10000 end,
    maxEnergy = function() return 10000 end,
    users = function() return end,
    addUser = function() return nil, "not supported" end,
    removeUser = function() return false end,
    isRobot = function() return false end,
    tmpAddress = function() return nil end,
    getArchitecture = function() return "Lua 5.3" end,
    getArchitectures = function() return {"Lua 5.3"} end,
    setArchitecture = function() return false end,
    getBootAddress = function() return nil end,
    setBootAddress = function() end,
  }
end

local function hostUnicodeAPI()
  local function chars(s)
    local t = {}
    for _, cp in utf8.codes(s) do t[#t + 1] = utf8.char(cp) end
    return t
  end
  return {
    char = utf8.char,
    len = function(s) return utf8.len(s) or #s end,
    sub = function(s, i, j)
      local t = chars(s)
      local n = #t
      i = i or 1; j = j or n
      if i < 0 then i = n + i + 1 end
      if j < 0 then j = n + j + 1 end
      return table.concat(t, "", math.max(i, 1), math.min(j, n))
    end,
    lower = string.lower,
    upper = string.upper,
    reverse = function(s)
      local t, r = chars(s), {}
      for i = #t, 1, -1 do r[#r + 1] = t[i] end
      return table.concat(r)
    end,
    isWide = function() return false end,
    charWidth = function() return 1 end,
    wlen = function(s) return utf8.len(s) or #s end,
    wtrunc = function(s, n) return s:sub(1, n - 1) end,
  }
end

function Emulator:_machineEnv(node)
  local env = {}
  for _, name in ipairs({"assert", "error", "getmetatable", "ipairs", "load", "next", "pairs", "pcall",
      "rawequal", "rawget", "rawlen", "rawset", "select", "setmetatable", "tonumber", "tostring", "type",
      "xpcall", "_VERSION"}) do
    env[name] = _G[name]
  end
  env.string, env.table, env.math, env.coroutine, env.debug, env.utf8 = string, table, math, coroutine, debug, utf8
  env.os = {time = os.time, date = os.date, clock = os.clock}
  env.computer = hostComputerAPI(node)
  env.component = hostComponentAPI(node)
  env.unicode = hostUnicodeAPI()
  env.system = {
    timeout = function() return self.timeout end,
    allowBytecode = function() return false end,
    allowGC = function() return false end,
  }
  env.userdata = {}
  env._G = env
  return env
end

-- ---------------------------------------------------------------- --
-- Simulated components.
-- ---------------------------------------------------------------- --

-- Network Card: open()/broadcast() only -- confirmed by direct audit
-- that nothing in this project's production files ever calls
-- modem.send (unicast); every message type is broadcast, with logical
-- addressing carried inside the payload's own `to` field instead.
--
-- modem_message's first two arguments are the RECEIVING and SENDING
-- network cards' own component addresses -- not either computer's
-- computer.address(). Real OC raises the signal from the receiving
-- card's component (Machine prepends that component's address) with
-- packet.source, which NetworkCard sets to its own node address. This
-- emulator used to pass the computers' addresses instead, which hid a
-- real bug: node/runtime.lua was addressing the kernal by the
-- boot-handshake sender address (a card address on real hardware)
-- while the kernal only answered to its computer address, so on real
-- hardware every worker->kernal request would have been ignored.
function Emulator:addModem(node)
  local addr = self:addComponent(node, "modem", {
    open = function(port) node.modemOpenPorts[port] = true; return true end,
    broadcast = function(port, ...)
      for _, otherAddr in ipairs(node.emu.nodeOrder) do
        if otherAddr ~= node.address then
          local other = node.emu.nodes[otherAddr]
          if other.modemAddr and other.modemOpenPorts[port] then
            other.signalQueue[#other.signalQueue + 1] =
              {"modem_message", other.modemAddr, node.modemAddr, port, 0, ...}
          end
        end
      end
      return true
    end,
    -- To one card only, like the real network card's send.
    send = function(address, port, ...)
      for _, otherAddr in ipairs(node.emu.nodeOrder) do
        local other = node.emu.nodes[otherAddr]
        if otherAddr ~= node.address and other.modemAddr == address and other.modemOpenPorts[port] then
          other.signalQueue[#other.signalQueue + 1] =
            {"modem_message", other.modemAddr, node.modemAddr, port, 0, ...}
        end
      end
      return true
    end,
  })
  node.modemAddr = addr
  return addr
end

-- EEPROM: holds the node's boot code (machine.lua's bootstrap reads it
-- with `get`) and the small data area kernal/bios.lua uses to remember
-- its boot filesystem.
function Emulator:addEeprom(node, code, data)
  data = data or ""
  return self:addComponent(node, "eeprom", {
    get = function() return code end,
    set = function(c) code = c; return true end,
    getData = function() return data end,
    setData = function(d) data = d or ""; return true end,
    getSize = function() return 4096 end,
  })
end

-- Filesystem: in-memory, pre-populated from `files` (path -> content).
-- `read`'s handle convention (a plain number, not an io.open()-style
-- object) matches the real component filesystem API this wraps.
function Emulator:addFilesystem(node, files)
  local handles = {}
  local nextHandle = 1
  local dirs = {["/"] = true}
  local modified = {}
  local clock = 0
  local function norm(path)
    local parts = {}
    for part in tostring(path):gmatch("[^/]+") do parts[#parts + 1] = part end
    return "/" .. table.concat(parts, "/")
  end
  local function touch(path)
    clock = clock + 1
    modified[path] = clock
  end
  local function isDir(path)
    path = norm(path)
    if dirs[path] then return true end
    local prefix = path == "/" and "/" or path .. "/"
    for f in pairs(files) do
      if f:sub(1, #prefix) == prefix then return true end
    end
    return false
  end
  -- Real OC caps one read at 2048 bytes (maxReadBuffer).
  local READ_CAP = 2048
  return self:addComponent(node, "filesystem", {
    open = function(path, mode)
      path, mode = norm(path), mode or "r"
      if mode:match("[wa]") then
        if mode:match("w") or not files[path] then files[path] = "" end
        touch(path)
      elseif not files[path] then
        return nil, path
      end
      local h = nextHandle
      nextHandle = nextHandle + 1
      handles[h] = {path = path, pos = mode:match("a") and #files[path] + 1 or 1, mode = mode}
      return h
    end,
    read = function(handle, n)
      local h = handles[handle]
      if not h then return nil, "bad file descriptor" end
      local content = files[h.path]
      if h.pos > #content then return nil end
      n = math.min(n or math.huge, #content - h.pos + 1, READ_CAP)
      local chunk = content:sub(h.pos, h.pos + n - 1)
      h.pos = h.pos + #chunk
      return chunk
    end,
    write = function(handle, data)
      local h = handles[handle]
      if not h or not h.mode:match("[wa]") then return nil, "bad file descriptor" end
      local content = files[h.path]
      files[h.path] = content:sub(1, h.pos - 1) .. data .. content:sub(h.pos + #data)
      h.pos = h.pos + #data
      touch(h.path)
      return true
    end,
    seek = function(handle, whence, offset)
      local h = handles[handle]
      if not h then return nil, "bad file descriptor" end
      local base = whence == "set" and 0 or whence == "end" and #files[h.path] or h.pos - 1
      h.pos = math.max(0, base + (offset or 0)) + 1
      return h.pos - 1
    end,
    close = function(handle) handles[handle] = nil; return true end,
    exists = function(path) path = norm(path) return files[path] ~= nil or isDir(path) end,
    isDirectory = function(path) return isDir(path) end,
    size = function(path) return #(files[norm(path)] or "") end,
    lastModified = function(path) return modified[norm(path)] or 0 end,
    list = function(path)
      path = norm(path)
      if not isDir(path) then return nil, "no such file or directory" end
      local prefix = path == "/" and "/" or path .. "/"
      local seen, out = {}, {}
      local function add(name)
        if not seen[name] then seen[name] = true out[#out + 1] = name end
      end
      for f in pairs(files) do
        if f:sub(1, #prefix) == prefix then
          local rest = f:sub(#prefix + 1)
          local first = rest:match("^[^/]+")
          add(rest:find("/", 1, true) and first .. "/" or first)
        end
      end
      for d in pairs(dirs) do
        if d ~= path and d:sub(1, #prefix) == prefix and not d:sub(#prefix + 1):find("/", 1, true) then
          add(d:sub(#prefix + 1) .. "/")
        end
      end
      table.sort(out)
      out.n = #out
      return out
    end,
    makeDirectory = function(path) dirs[norm(path)] = true return true end,
    remove = function(path)
      path = norm(path)
      if files[path] then files[path] = nil return true end
      if dirs[path] then dirs[path] = nil return true end
      return false
    end,
    rename = function(from, to)
      from, to = norm(from), norm(to)
      if not files[from] then return false end
      files[to], files[from] = files[from], nil
      touch(to)
      return true
    end,
    spaceUsed = function() return 0 end,
    spaceTotal = function() return 1048576 end,
    isReadOnly = function() return false end,
    getLabel = function() return "kernal" end,
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
    -- One cell per character, like the real gpu (UTF-8 aware; raw
    -- bytes for invalid UTF-8). Wide glyphs aren't modelled.
    set = function(x, y, text)
      local buf = buffers[active]
      local i = 0
      local chars = utf8.len(text) and text:gmatch(utf8.charpattern) or text:gmatch(".")
      for ch in chars do
        local cell = getCell(buf, x + i, y)
        cell.char, cell.fg, cell.bg = ch, fg, bg
        i = i + 1
      end
      return true
    end,
    getDepth = function() return 8 end,
    maxDepth = function() return 8 end,
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

-- Boots a node the way the mod does: machine.lua's chunk, run as the
-- node's coroutine; it reads the EEPROM itself and runs its code in
-- the sandbox. Its first yield is the memory-baseline one, resumed at
-- once.
function Emulator:boot(node)
  local chunk = assert(load(machineSource, "=machine", "t", self:_machineEnv(node)))
  node.co = coroutine.create(chunk)
  node.status = "running"
  self:_resume(node)
  self:_resume(node)
end

function Emulator:_resume(node, ...)
  if node.status ~= "running" then return end
  local ok, a, b = coroutine.resume(node.co, ...)
  -- An indirect component call: machine.lua yields a function for the
  -- host to run on its own thread and resumes with the result.
  while ok and type(a) == "function" and coroutine.status(node.co) ~= "dead" do
    ok, a, b = coroutine.resume(node.co, a())
  end
  if not ok then
    node.status = "dead"
    self:_logf(node, "CRASHED: %s", tostring(a))
    return
  end
  if coroutine.status(node.co) == "dead" then
    node.status = "dead"
    -- machine.lua returns (false, reason) when the machine crashes.
    self:_logf(node, "halted (%s, %s)", tostring(a), tostring(b))
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
      self:_resume(node, table.unpack(sig, 1, sig.n or #sig))
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
  node.signalQueue[#node.signalQueue + 1] = table.pack(...)
end

return Emulator
