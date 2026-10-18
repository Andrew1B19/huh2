-- munix terminal runtime: a network terminal's side of a munix session.
-- muxterm (apps/muxterm.lua, an OpenOS program) fetches this file from
-- the kernal -- with the session, compositor and encoder code it runs --
-- so a terminal always runs the kernal's own version of them.
--
-- The session -- console, line editor, login prompt, desktop, taskbar,
-- windows, focus, input -- runs here, on the terminal's own GPU
-- (kernal/session.lua, the same code as the kernal's own screen). What
-- only the kernal can do -- commands and the shell (its disks), logins,
-- launching programs, the window registry -- it asks the kernal for, on
-- the terminal port. Programs draw their windows straight to this
-- terminal, each with its window's key, and get their input straight
-- from it: no hop through the kernal. A program holding this screen's
-- fullscreen grant calls its gpu directly (GPUCALL).
--
-- Started by muxterm with ctx = {kernal, port, files, modem, gpu,
-- keyboards, version}; returns why it stopped.
local ctx = ...
local CLUSTER_PORT = 4477
local PORT = ctx.port
local kernalAddr, modemAddr = ctx.kernal, ctx.modem
local myAddr = modemAddr
local component, computer = component, computer

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

local deserialize
do
  -- Messages are decoded with load(), so a message must be only data
  -- first. Outside string literals our serializer writes nothing but
  -- letters, digits, whitespace and { } [ ] = , . - + / -- so anything else
  -- (a function, a call, a method call like ("x"):rep(1e9), a comment, a
  -- long string that could hide a quote) is refused before load() sees it.
  -- That leaves table constructors of literals, which can't run code.
  local function isData(s)
    local i, n = 1, #s
    while i <= n do
      local q = s:find('"', i, true)
      local outside = s:sub(i, (q or n + 1) - 1)
      if outside:find("[^%w%s{}%[%]=,%.%-%+/]") or outside:find("%[[%[=]") or outside:find("%-%-") then
        return false
      end
      if not q then return true end
      i = q + 1
      while true do -- to the end of the string literal
        local c = s:find('[\\"]', i)
        if not c then return false end
        if s:byte(c) == 92 then
          i = c + 2
        else
          i = c + 1
          break
        end
      end
    end
    return true
  end

  deserialize = function(s)
    if not isData(s) then return nil end
    local chunk = load("return " .. s, "=msg", "t", {})
    if not chunk then return nil end
    local ok, v = pcall(chunk)
    if not ok then return nil end
    return v
  end
end

local CHUNK_SIZE = 7000
local nextMsgId = 1

-- Sends a message (framed as the cluster frames them: "MSG id i/n ...")
-- to its `to`, on the terminal port unless `port` says otherwise.
local function send(msg, port)
  local payload = serialize(msg)
  local id = nextMsgId
  nextMsgId = nextMsgId + 1
  local total = math.ceil(#payload / CHUNK_SIZE)
  for i = 1, total do
    local frame = "MSG " .. id .. " " .. i .. "/" .. total .. " " .. payload:sub((i - 1) * CHUNK_SIZE + 1, i * CHUNK_SIZE)
    component.invoke(modemAddr, "send", msg.to, port or PORT, frame)
  end
end

local incoming = {}
local function reassemble(from, data)
  local msgId, i, n, chunk = data:match("^MSG (%d+) (%d+)/(%d+) (.*)$")
  if not msgId then return nil end
  i, n = tonumber(i), tonumber(n)
  local key = from .. ":" .. msgId
  local entry = incoming[key] or {chunks = {}, total = n, at = computer.uptime()}
  incoming[key] = entry
  entry.chunks[i] = chunk
  for j = 1, entry.total do
    if not entry.chunks[j] then return nil end
  end
  incoming[key] = nil
  return table.concat(entry.chunks, "", 1, entry.total)
end

local function loadFile(name)
  local source = ctx.files[name]
  if not source then error("the kernal didn't send " .. name, 0) end
  return assert(load(source, "=" .. name, "t", _ENV))
end

-- --- This screen: the real GPU, or a GPU in memory mirrored onto it ---

local realGpu = component.proxy(ctx.gpu)
local screenW, screenH = realGpu.getResolution()
local compositorGpu, mirror = realGpu, nil
if not realGpu.allocateBuffer then
  -- A GPU without video memory (below tier 3): the compositor draws in
  -- memory (kernal/vgpu.lua) and what changed is copied onto the screen.
  compositorGpu = loadFile("vgpu.lua")().new(screenW, screenH, realGpu.getDepth())
  mirror = function()
    local cf, cb
    for _, run in ipairs(compositorGpu.takeDamage()) do
      if run[4] ~= cf then realGpu.setForeground(run[4]) cf = run[4] end
      if run[5] ~= cb then realGpu.setBackground(run[5]) cb = run[5] end
      realGpu.set(run[1], run[2], run[3])
    end
  end
end

-- --- The kernal's side, as the session sees it (K) ---

local K = {selfAddr = kernalAddr, MUNIX_VERSION = ctx.version, jobs = {}, fullscreen = {},
  commands = setmetatable({}, {__mode = "k"}), loadSibling = loadFile}
K.lineedit = loadFile("lineedit.lua")()
K.system = {home = function(name) return name == "root" and "/root" or "/home/" .. name end}

local S -- the session (below)
local running, reason = true, nil
local lastHeard, lastSent = computer.uptime(), computer.uptime()
local keys = {}        -- program window id -> its key (draws must carry it)
local userWindows = {} -- the user's windows, wherever they are (TUSERWINDOWS)
local replies, nextRequest = {}, 1
local pump -- below: handles one signal

-- Session window ids count down, so they never meet the kernal's ids for
-- program windows.
local nextLocalId = 0
function K.newCompositor(g)
  return loadFile("compositor.lua")(loadFile, {gpu = g, nextId = function()
    nextLocalId = nextLocalId - 1
    return nextLocalId
  end})
end

function K.wait(timeout)
  if K.commands[coroutine.running()] then coroutine.yield() else pump(timeout) end
end

function K.resumeCommand(_, co)
  K.commands[co] = true
  return coroutine.resume(co)
end

function K.inSession(_, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then error(err, 0) end
end

local function tell(msgType, fields)
  local msg = {type = msgType, from = myAddr, to = kernalAddr}
  for k, v in pairs(fields or {}) do msg[k] = v end
  send(msg)
  lastSent = computer.uptime()
end

-- Asks the kernal and waits for its answer (`timeout`: seconds; nil
-- waits as long as the kernal is there).
local function request(msgType, fields, timeout)
  local id = nextRequest
  nextRequest = nextRequest + 1
  local f = {id = id}
  for k, v in pairs(fields or {}) do f[k] = v end
  replies[id] = false
  tell(msgType, f)
  local deadline = timeout and computer.uptime() + timeout
  while running and not replies[id] and (not deadline or computer.uptime() < deadline) do K.wait(0.1) end
  local r = replies[id]
  replies[id] = nil
  if not r then return nil, "the kernal didn't answer" end
  if r.type == "RESULT" then return r.result end
  return nil, r.error
end

function K.liveJob(id)
  local job = K.jobs[id]
  if job and job.status == "running" then return job end
end

-- Input and other events go straight to a program's node.
function K.deliverEvent(job, event)
  send({type = "EVENT", from = myAddr, to = job.node, jobId = job.id, event = event}, CLUSTER_PORT)
end

function K.controlJob(id, verb, why) tell("TCONTROL", {job = id, verb = verb, why = why}) return true end
function K.closeWindow(id)
  if not keys[id] then return false end
  tell("TCLOSE", {window = id})
  return true
end
function K.windowGeometry(id, x, y, w, h)
  if keys[id] then tell("TGEOM", {window = id, x = x, y = y, width = w, height = h}) end
end
function K.userWindows() return userWindows end
function K.attachWindow(id) tell("TATTACH", {window = id}) return true end
function K.togglePersist(id) if keys[id] then tell("TPERSIST", {window = id}) end end
function K.endLogin() tell("TLOGOUT") end
function K.newShell() return nil end -- the shell runs on the kernal
function K.nextLogin() return K.pendingLogin end
function K.apps() return request("TAPPS", nil, 30) or {} end
function K.fileSize(path) return request("TSIZE", {path = path}, 10) end
function K.readFile(path) return request("TREAD", {path = path}, 60) end
function K.writeFile(path, data) return request("TWRITE", {path = path, data = data}, 10) end
-- The kernal launches it and reports how that went on the console.
function K.launchProgram(path, args) tell("TLAUNCH", {path = path, args = args}) return true end

-- A line typed at the console: a user name at login:, the session's own
-- commands here, everything else on the kernal (its output comes back
-- as it's printed; the answer comes when the command is done).
function K.runCommand(sess, line)
  if not sess.user then
    local name = (line or ""):match("^%s*(.-)%s*$")
    if name == "" then return end
    local r, err = request("TLOGIN", {name = name}, 30)
    if not r then sess.print(err) return end
    K.pendingLogin, sess.remoteCwd, userWindows = r.login, r.cwd, r.windows or {}
    sess.startSession(name)
    return
  end
  if sess.command(line) then return end
  local r, err = request("TCMD", {line = line, width = sess.consoleWidth()})
  if r then sess.remoteCwd = r.cwd elseif err then sess.print(err) end
end

-- --- Program windows: drawn straight here ---

local function answer(msg, result, err)
  if msg.noReply or not msg.id then return end
  if result == nil then
    send({type = "ERROR", from = myAddr, to = msg.from, id = msg.id, error = err}, CLUSTER_PORT)
  else
    send({type = "RESULT", from = myAddr, to = msg.from, id = msg.id, result = result}, CLUSTER_PORT)
  end
end

local function framesPresented(list)
  for _, p in ipairs(list) do
    local win = S.compositor.getWindow(p.id)
    if win then
      local told = {}
      local function tellJob(id)
        local job = K.liveJob(id)
        if job and not told[id] then
          told[id] = true
          K.deliverEvent(job, {"frame_presented", p.id, p.frame, p.complete})
        end
      end
      if win.ownerJobId then tellJob(win.ownerJobId) end
      for key in pairs(S.compositor.shares(p.id)) do tellJob(key) end
    end
  end
end

local function fromProgram(msg)
  local id = msg.windowId
  local win = id and S.compositor.getWindow(id)
  if msg.type == "GPUCALL" then
    local fs = K.fullscreen
    if not (fs.node and fs.node == msg.from and msg.key == fs.key) then
      return answer(msg, nil, "this screen's fullscreen grant isn't yours")
    end
    local args = type(msg.args) == "table" and msg.args or {}
    local packed = table.pack(pcall(realGpu[msg.method], table.unpack(args, 1, args.n or #args)))
    if not packed[1] then return answer(msg, nil, tostring(packed[2])) end
    local returns = {n = packed.n - 1}
    for i = 2, packed.n do returns[i - 1] = packed[i] end
    return answer(msg, returns)
  end
  if not win or not keys[id] then return answer(msg, nil, "window " .. tostring(id) .. " isn't shown here") end
  if msg.key ~= keys[id] then return answer(msg, nil, "window " .. tostring(id) .. " belongs to another process") end
  local compositor = S.compositor
  if msg.type == "DRAWWINDOW" then
    if not msg.pixels and type(msg.width) == "number" and type(msg.height) == "number"
        and (msg.width ~= win.width or msg.height ~= win.height) then
      local ok, err = compositor.setGeometry(id, win.x, win.y, msg.width, msg.height)
      if not ok then return answer(msg, nil, err) end
      K.windowGeometry(id, win.x, win.y, win.width, win.height)
    end
    local ok, err = compositor.redrawWindow(id, msg)
    return answer(msg, ok, err)
  elseif msg.type == "DRAWREGION" then
    local drawer = msg.caller == win.ownerJobId and "owner" or msg.caller
    local ok, presented = compositor.drawRegion(id, drawer, msg.frame, msg, msg.done)
    if not ok then return answer(msg, nil, presented) end
    framesPresented(presented)
    return answer(msg, true)
  elseif msg.type == "RENDERCONFIG" then
    if msg.options ~= nil and msg.caller ~= win.ownerJobId then
      return answer(msg, nil, "window " .. id .. " belongs to another process")
    end
    return answer(msg, compositor.renderConfig(id, msg.options))
  end
end

-- --- Messages from the kernal ---

local fromKernal = {}
function fromKernal.RESULT(msg) replies[msg.id] = msg end
fromKernal.ERROR = fromKernal.RESULT
function fromKernal.TOUT(msg) S.write(tostring(msg.text)) end
function fromKernal.TCLEAR() S.clearConsole() end
function fromKernal.TFG(msg)
  if msg.job then
    K.jobs[msg.job] = {id = msg.job, node = msg.node, status = "running"}
    S.beginForeground(msg.job)
  else
    S.endForeground()
  end
end
function fromKernal.TWINDOW(msg)
  local spec = msg.spec
  if spec.ownerJobId and spec.ownerNode then
    K.jobs[spec.ownerJobId] = {id = spec.ownerJobId, node = spec.ownerNode, status = "running"}
  end
  keys[spec.id] = spec.key
  local ok, err = S.display.create(spec)
  if not ok then
    keys[spec.id] = nil
    tell("TWINERR", {window = spec.id, error = tostring(err)})
  end
end
function fromKernal.TWINREMOVE(msg)
  keys[msg.window] = nil
  if S.compositor.getWindow(msg.window) then S.compositor.close(msg.window) end
end
function fromKernal.TWINSTATUS(msg)
  local win = S.compositor.getWindow(msg.window)
  if win then
    S.compositor.setStatus(msg.window, msg.status)
    local job = win.ownerJobId and K.jobs[win.ownerJobId]
    if job then job.status = "ended" end
  end
end
function fromKernal.TWINPERSIST(msg)
  S.display.persist(msg.window, msg.on == true)
end
function fromKernal.TOWNER(msg)
  K.jobs[msg.job] = {id = msg.job, node = msg.node, status = "running"}
  S.display.setOwner(msg.window, msg.job)
end
function fromKernal.TSHARE(msg)
  if msg.rect and msg.node then K.jobs[msg.job] = {id = msg.job, node = msg.node, status = "running"} end
  S.compositor.share(msg.window, msg.job, msg.rect)
end
function fromKernal.TUSERWINDOWS(msg)
  userWindows = type(msg.list) == "table" and msg.list or {}
  S.windowsChanged()
end
function fromKernal.TJOBEND(msg)
  local job = K.jobs[msg.job]
  if job then job.status = "ended" end
  for _, winId in ipairs(S.compositor.unshareAll(msg.job)) do
    local win = S.compositor.getWindow(winId)
    local owner = win and win.ownerJobId and K.liveJob(win.ownerJobId)
    if owner then K.deliverEvent(owner, {"region_lost", winId, msg.job}) end
  end
end
function fromKernal.TFULL(msg)
  K.fullscreen.node, K.fullscreen.job, K.fullscreen.key = msg.node, msg.job, msg.key
  S.compositor.setExclusive(msg.node)
end
function fromKernal.TUNFULL()
  K.fullscreen.node, K.fullscreen.job, K.fullscreen.key = nil, nil, nil
  S.compositor.setExclusive(not S.user and "console" or nil)
  S.redraw()
end
function fromKernal.TBYE(msg)
  running, reason = false, "disconnected -- " .. tostring(msg.why)
end
function fromKernal.TPING() end

-- --- Input, upkeep, and the loop ---

local INPUT = {key_down = true, key_up = true, scroll = true, clipboard = true, touch = true, drag = true, drop = true}
local held = {}

local function ours(address) return address == realGpu.getScreen() or ctx.keyboards[address] end

pump = function(timeout)
  local sig = table.pack(computer.pullSignal(timeout))
  local name = sig[1]
  local now = computer.uptime()
  if name == "modem_message" and sig[4] == PORT and type(sig[6]) == "string" then
    local payload = reassemble(sig[3], sig[6])
    local msg = payload and deserialize(payload)
    if type(msg) == "table" and msg.from == sig[3] then
      if sig[3] == kernalAddr then
        lastHeard = now
        local handler = fromKernal[msg.type]
        if handler then
          local ok, err = pcall(handler, msg)
          if not ok then S.print("terminal: " .. tostring(err)) end
        end
      else
        local ok, err = pcall(fromProgram, msg)
        if not ok then answer(msg, nil, tostring(err)) end
      end
    end
  elseif INPUT[name] and ours(sig[2]) then
    if name == "key_down" then held[sig[4]] = true elseif name == "key_up" then held[sig[4]] = nil end
    -- Ctrl+Alt+D: hang up (logging out).
    if name == "key_down" and sig[4] == 0x20 and (held[0x1D] or held[0x9D]) and (held[0x38] or held[0xB8]) then
      tell("TBYE")
      running, reason = false, "disconnected"
      return
    end
    -- Ctrl+Alt+C on this screen while a program holds it: it's let go.
    if name == "key_down" and sig[4] == 0x2E and K.fullscreen.node and (held[0x1D] or held[0x9D])
        and (held[0x38] or held[0xB8]) then
      tell("TFULLREL")
      fromKernal.TUNFULL()
    end
    local ok, err = pcall(S.input, name, sig[3], sig[4], sig[5])
    if not ok then S.print("terminal: " .. tostring(err)) end
  end
  for key, entry in pairs(incoming) do
    if now - entry.at > 30 then incoming[key] = nil end
  end
end

local function upkeep()
  local now = computer.uptime()
  local ok, err = pcall(function()
    framesPresented(S.compositor.renderTick(function(id)
      local list = {}
      for key in pairs(S.compositor.shares(id)) do
        if K.liveJob(key) then list[#list + 1] = key end
      end
      return list
    end))
    S.update()
    S.resume()
  end)
  if not ok then S.print("terminal: " .. tostring(err)) end
  if now - lastSent > 2 then tell("TPING") end
  if now - lastHeard > 10 then running, reason = false, "lost the kernal (nothing heard for 10 s)" end
end

S = loadFile("session.lua")(K, {id = 1, gpu = compositorGpu, kind = "terminal", address = myAddr, flushed = mirror})
K.inSession(S, S.showLogin)
tell("TREADY", {width = screenW, height = screenH, depth = realGpu.getDepth(), console = S.consoleWidth()})
while running do
  pump(0.05)
  upkeep()
end
return reason
