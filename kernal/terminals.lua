-- muxos terminal server: the kernal's side of network terminals.
--
-- A terminal (muxterm, an OpenOS program) runs its session itself --
-- console, desktop, taskbar, windows, its own compositor on its own GPU
-- -- with the code it fetches from here (kernal/terminal.lua). What only
-- the kernal can do it asks for here, and here it has a session of its
-- own (a proxy, P) for that: P runs the terminal's commands -- the shell
-- works on the kernal's disks -- and owns the processes they start; its
-- display is the terminal, where the window registry (kernal/windows.lua)
-- shows that user's windows. Programs draw those straight to the
-- terminal, with their windows' keys; nothing of a terminal's screen
-- passes through here.
--
-- Loaded by kernal/muxos.lua:
--   loadSibling("terminals.lua")(K, {modem, send})
--
-- On the terminal port (flag terminal_port, 4478; framed as the cluster
-- frames messages), terminal -> kernal:
--   TERMHELLO                  muxterm starting: TCODE comes back
--                              ({files = {name = source}, version})
--   TREADY {width, height, depth, console}   the session is up
--   TLOGIN {name} -> {login, cwd, windows}
--   TCMD {line, width} -> {cwd}  output comes meanwhile as TOUT
--   TAPPS, TSIZE {path}, TREAD {path}, TWRITE {path, data}
--   TLAUNCH {path, args}, TCONTROL {job, verb}, TCLOSE {window},
--   TGEOM {window, x, y, width, height}, TATTACH {window}, TLOGOUT,
--   TWINERR {window, error}, TFULLREL, TPING, TBYE
-- kernal -> terminal: TOUT {text}, TCLEAR, TFG {job, node},
--   TWINDOW {spec}, TWINREMOVE {window}, TWINSTATUS {window, status},
--   TOWNER {window, job, node}, TSHARE {window, job, rect, node},
--   TUSERWINDOWS {list}, TJOBEND {job}, TFULL {node, job, key}, TUNFULL,
--   TPING, TBYE {why},
--   and RESULT/ERROR answering requests.
-- A terminal silent for 10 s is hung up on: its session logs out.
local K, deps = ...
local system = K.system

local T = {byAddress = {}}
local PORT = system.flag("terminal_port")
T.PORT = PORT
local SILENT, QUIET = 10, 2
local MAX_READ = 1024 * 1024
local FILES = {"terminal.lua", "session.lua", "compositor.lua", "bitmap.lua", "lineedit.lua", "vgpu.lua"}

if system.flag("remote_terminals") then deps.modem.open(PORT) end

local function sendTo(address, msg)
  msg.from, msg.to = K.selfAddr, address
  deps.send(msg, PORT)
end

local function newKey()
  return string.format("%04x%04x%04x", math.random(0, 0xFFFF), math.random(0, 0xFFFF), math.random(0, 0xFFFF))
end

-- A terminal's session, as the kernal keeps it.
local function newProxy(address, info)
  local now = computer.uptime()
  local P = {kind = "terminal", address = address, width = tonumber(info.console) or 80,
    screen = {tonumber(info.width) or 80, tonumber(info.height) or 25}, lastSeen = now, lastSent = now}
  P.display = {
    address = address, port = PORT,
    create = function(spec)
      local w, h = math.tointeger(tonumber(spec.width)) or 30, math.tointeger(tonumber(spec.height)) or 10
      sendTo(address, {type = "TWINDOW", spec = {id = spec.id, title = spec.title, x = spec.x, y = spec.y,
        width = w, height = h, resizable = spec.resizable, decorated = spec.decorated, ownerJobId = spec.ownerJobId,
        ownerNode = spec.ownerNode, key = spec.key, code = spec.code, args = spec.args, cells = spec.cells, bg = spec.bg}})
      return {width = w, height = h}
    end,
    remove = function(id) sendTo(address, {type = "TWINREMOVE", window = id}) end,
    status = function(id, status) sendTo(address, {type = "TWINSTATUS", window = id, status = status}) end,
    setOwner = function(id, jobId, node) sendTo(address, {type = "TOWNER", window = id, job = jobId, node = node}) end,
    share = function(id, jobId, rect, node) sendTo(address, {type = "TSHARE", window = id, job = jobId, rect = rect, node = node}) end,
  }
  P.width, P.height = P.screen[1], P.screen[2] -- a legacy program's default resolution
  P.consoleColumns = tonumber(info.console) or 80
  function P.write(text) sendTo(address, {type = "TOUT", text = tostring(text)}) P.lastSent = computer.uptime() end
  function P.print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    P.write(table.concat(parts, "\t") .. "\n")
  end
  function P.command() return false end
  function P.deny(flagName, doing)
    local ok, why = system.allowed(P.user, flagName, doing)
    if not ok then P.print(why) return true end
  end
  function P.shellRun(line)
    if P.shell then P.shell.run(line) else P.print("no shell -- run `update` with the installer floppy in") end
  end
  function P.cwd() return P.shell and P.shell.cwd() or (P.user and system.home(P.user)) or "/" end
  function P.beginForeground(id)
    P.foregroundJob = id
    local job = K.jobs[id]
    sendTo(address, {type = "TFG", job = id, node = job and job.node})
  end
  function P.endForeground()
    P.foregroundJob = nil
    sendTo(address, {type = "TFG"})
  end
  function P.consoleWidth() return P.consoleColumns end
  function P.clearConsole() sendTo(address, {type = "TCLEAR"}) end
  function P.windowsChanged()
    if P.user then sendTo(address, {type = "TUSERWINDOWS", list = K.win.ofUser(P.user)}) end
  end
  function P.update() end
  function P.input() end
  function P.redraw() end
  -- The terminal's command, run here in a coroutine of its own (K.wait
  -- yields to the kernal's loop); its answer goes back when it's done.
  function P.resume()
    if not P.co then return end
    local ok, err = K.resumeCommand(P, P.co)
    if coroutine.status(P.co) == "dead" then
      local id = P.cmdId
      P.co, P.cmdId = nil, nil
      if not ok then P.print("command error: " .. tostring(err)) end
      sendTo(address, {type = "RESULT", id = id, result = {cwd = P.cwd()}})
    end
  end
  function P.logout()
    K.endLogin(P)
    P.user, P.shell, P.login = nil, nil, nil
  end
  return P
end

local function reply(P, msg, result, err)
  if not msg.id then return end
  if result == nil then
    sendTo(P.address, {type = "ERROR", id = msg.id, error = err})
  else
    sendTo(P.address, {type = "RESULT", id = msg.id, result = result})
  end
end

local function hangUp(P, why)
  T.byAddress[P.address] = nil
  K.endSession(P)
  sendTo(P.address, {type = "TBYE", why = why})
end

-- What a terminal may ask, once its session is up.
local handlers = {}
function handlers.TLOGIN(P, msg)
  local name = tostring(msg.name)
  if not system.userExists(name) then return reply(P, msg, nil, "no such user: " .. name) end
  if P.user then K.endLogin(P) end
  P.user, P.login = name, K.nextLogin()
  P.shell = K.newShell(P, name)
  reply(P, msg, {login = P.login, cwd = P.cwd(), windows = K.win.ofUser(name)})
end
function handlers.TCMD(P, msg)
  if not P.user then return reply(P, msg, nil, "log in first") end
  if P.co then return reply(P, msg, nil, "a command is already running") end
  P.consoleColumns = tonumber(msg.width) or P.consoleColumns
  local line = tostring(msg.line)
  P.cmdId = msg.id
  P.co = coroutine.create(function() return K.runCommand(P, line) end)
  P.resume()
end
function handlers.TAPPS(P, msg) reply(P, msg, K.apps()) end
function handlers.TSIZE(P, msg) reply(P, msg, K.fileSize(tostring(msg.path)) or false) end
function handlers.TREAD(P, msg)
  local path = tostring(msg.path)
  local size = K.fileSize(path)
  if not size then return reply(P, msg, false) end
  if size > MAX_READ then return reply(P, msg, nil, path .. ": too big") end
  reply(P, msg, K.readFile(path) or false)
end
function handlers.TWRITE(P, msg)
  if not P.user then return reply(P, msg, nil, "log in first") end
  reply(P, msg, K.writeFile(tostring(msg.path), msg.data) or false)
end
function handlers.TLAUNCH(P, msg)
  if not P.user then return end
  K.inSession(P, function()
    local id, addrOrErr = K.launchProgram(tostring(msg.path), type(msg.args) == "table" and msg.args or {})
    if id then
      P.print("[" .. id .. "] " .. tostring(msg.path) .. " started on " .. addrOrErr)
    else
      P.print("error: " .. tostring(addrOrErr))
    end
  end)
end
function handlers.TCONTROL(P, msg)
  local job = K.jobs[msg.job]
  if not P.user or not job then return end
  if job.user ~= P.user and P.user ~= "root" and system.flag("kill_requires_owner") then
    return P.print("process " .. tostring(msg.job) .. " is " .. tostring(job.user) .. "'s (flag kill_requires_owner)")
  end
  K.controlJob(job.id, tostring(msg.verb), msg.why or ("killed by " .. P.user))
end
function handlers.TCLOSE(P, msg)
  local rec = K.win.get(msg.window)
  if rec and rec.user == P.user then K.closeWindow(rec.id) end
end
function handlers.TGEOM(P, msg)
  local rec = K.win.get(msg.window)
  if rec and rec.session == P.id then K.windowGeometry(rec.id, msg.x, msg.y, msg.width, msg.height) end
end
function handlers.TATTACH(P, msg)
  if not P.user then return end
  local ok, err = K.attachWindow(msg.window, P)
  if not ok then P.print("can't bring window " .. tostring(msg.window) .. " here: " .. tostring(err)) end
end
function handlers.TLOGOUT(P)
  K.endLogin(P)
  P.user, P.shell, P.login = nil, nil, nil
end
function handlers.TWINERR(P, msg)
  local rec = K.win.get(msg.window)
  if rec and rec.session == P.id then
    P.print("window " .. rec.id .. " couldn't be shown here: " .. tostring(msg.error))
    K.win.detach(rec)
  end
end
function handlers.TFULLREL(P)
  if P.fullscreen then P.fullscreen = nil end
end
function handlers.TPING() end
function handlers.TBYE(P)
  T.byAddress[P.address] = nil
  K.endSession(P)
end

-- A message on the terminal port, already reassembled and decoded.
function T.message(from, msg)
  if msg.type == "TERMHELLO" then
    if not system.flag("remote_terminals") then
      return sendTo(from, {type = "TBYE", why = "this muxos doesn't take terminals (flag remote_terminals)"})
    end
    local files = {}
    for _, name in ipairs(FILES) do files[name] = K.readFile("/" .. name) end
    return sendTo(from, {type = "TCODE", files = files, version = K.MUXOS_VERSION})
  elseif msg.type == "TREADY" then
    local old = T.byAddress[from]
    if old then hangUp(old, "restarted") end
    local P = newProxy(from, msg)
    K.addSession(P)
    T.byAddress[from] = P
    return
  end
  local P = T.byAddress[from]
  if not P then
    if msg.type ~= "TBYE" then sendTo(from, {type = "TBYE", why = "no session here -- restart muxterm"}) end
    return
  end
  P.lastSeen = computer.uptime()
  local handler = handlers[msg.type]
  if handler then
    local ok, err = pcall(handler, P, msg)
    if not ok then reply(P, msg, nil, tostring(err)) end
  end
end

-- Hangs up on terminals gone quiet; tells the others the kernal's here.
function T.sweep()
  local now = computer.uptime()
  for _, P in pairs(T.byAddress) do
    if now - P.lastSeen > SILENT then
      hangUp(P, "the terminal stopped answering")
    elseif now - P.lastSent > QUIET then
      sendTo(P.address, {type = "TPING"})
      P.lastSent = now
    end
  end
end

-- A process in a terminal's session asks for its screen whole: it gets
-- the terminal's address and a key, and calls the terminal's gpu there.
function T.grantFullscreen(P, job)
  local holder = P.fullscreen and K.liveJob(P.fullscreen.job)
  if holder and holder.id ~= job.id then
    return nil, "this terminal's screen is held by process " .. holder.id
  end
  local key = newKey()
  P.fullscreen = {job = job.id, node = job.node, key = key}
  sendTo(P.address, {type = "TFULL", node = job.node, job = job.id, key = key})
  return {P.address, key, PORT}
end

-- Lets go of any terminal screen process `jobId` holds; true if one.
function T.releaseFullscreen(jobId)
  local any = false
  for _, P in pairs(T.byAddress) do
    if P.fullscreen and P.fullscreen.job == jobId then
      P.fullscreen = nil
      sendTo(P.address, {type = "TUNFULL"})
      any = true
    end
  end
  return any
end

-- A process ended: terminals forget it (its shares go, its input stops).
function T.jobEnded(jobId)
  for _, P in pairs(T.byAddress) do sendTo(P.address, {type = "TJOBEND", job = jobId}) end
end

function T.list()
  local list = {}
  for _, P in pairs(T.byAddress) do list[#list + 1] = P end
  return list
end

return T
