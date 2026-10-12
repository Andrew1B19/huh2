-- muxos window registry: every program window, wherever it's shown.
--
-- A program's window belongs to its process and its user, not to a
-- screen. It's shown by (attached to) at most one session at a time --
-- the kernal's own screen, or a network terminal, whose compositor
-- holds its pixels -- and it can move: detached when its session ends
-- (a program that keeps running after its user logs out), attached
-- again from any of that user's sessions (their taskbar lists all of
-- them). The registry is the kernal's record of each one: owner, user,
-- title and geometry, the session showing it, and a key -- the secret
-- that lets a process draw into it directly at that session's screen.
-- Whoever holds a window's route (its owner, processes drawing its
-- regions, ancestors that asked) hears {"window_route", id, address,
-- key, width, height} when it moves -- address nil while detached.
--
-- Loaded by kernal/muxos.lua: loadSibling("windows.lua")(K).
-- A session's display (S.display) does the showing:
--   display.address          where its windows are drawn (a node address)
--   display.create(spec)     makes window spec.id there; returns the
--                            window's {width, height} in cells, or nil, err
--   display.remove(id)       takes it off the screen
--   display.status(id, s)    marks it ended ("dead"/"error")
local K = ...
local W = {byId = {}}

local function newKey()
  local parts = {}
  for i = 1, 4 do parts[i] = string.format("%04x", math.random(0, 0xFFFF)) end
  return table.concat(parts)
end

-- A plain description, safe to hand to any process (no key).
function W.describe(rec)
  local S = rec.session and K.byId[rec.session]
  return {id = rec.id, title = rec.title, x = rec.x, y = rec.y, width = rec.width, height = rec.height,
    ownerJobId = rec.owner, user = rec.user, resizable = rec.resizable, decorated = rec.decorated,
    attached = S ~= nil, session = S and S.id, status = rec.status}
end

function W.get(id) return W.byId[id] end

-- Where window `rec` is drawn now, and with what key: nil while detached.
function W.route(rec)
  local S = rec.session and K.byId[rec.session]
  if not S then return nil end
  return S.display.address, rec.key, S.display.port
end

-- Tells everyone holding the window's route where it is now.
local function announce(rec)
  local address, key, port = W.route(rec)
  for id in pairs(rec.holders) do
    local job = K.liveJob(id)
    if job then K.deliverEvent(job, {"window_route", rec.id, address or false, key or false, rec.width, rec.height, port}) end
  end
end

-- Opens a program's window in session S: `spec` is create_window's
-- options; `owner` the process it belongs to. Returns the record.
function W.open(S, spec, owner)
  if not S or not S.display then return nil, "its session has ended -- no screen to open a window on" end
  K.windowIds = K.windowIds + 1
  local id = K.windowIds
  local job = owner and K.jobs[owner]
  local shown = {}
  for k, v in pairs(spec) do shown[k] = v end
  shown.id, shown.ownerJobId, shown.text = id, owner, nil
  local size, err = S.display.create(shown)
  if not size then return nil, err end
  local rec = {id = id, owner = owner, user = job and job.user or S.user, session = S.id,
    title = tostring(spec.title or ("window " .. id)), x = spec.x or 1, y = spec.y or 1,
    width = size.width, height = size.height, resizable = spec.resizable == true,
    decorated = spec.decorated ~= false, key = newKey(), holders = {}}
  if owner then rec.holders[owner] = true end
  W.byId[id] = rec
  K.windowsChanged(rec.user)
  return rec
end

-- Gives a process the window's route (it may draw into it), recording it
-- so it hears of moves. The caller has checked it may.
function W.hold(rec, jobId)
  rec.holders[jobId] = true
  return W.route(rec)
end

-- Takes the window off whatever screen shows it; it keeps existing.
function W.detach(rec)
  local S = rec.session and K.byId[rec.session]
  rec.session = nil
  if S then pcall(S.display.remove, rec.id) end
  announce(rec)
  K.windowsChanged(rec.user)
end

-- Shows the window in session S (taking it from wherever it was). Its
-- holders hear the new route and redraw; the window starts blank.
function W.attach(rec, S)
  if rec.session == S.id then return true end
  local old = rec.session and K.byId[rec.session]
  if old then pcall(old.display.remove, rec.id) end
  rec.session = nil
  local size, err = S.display.create({id = rec.id, title = rec.title, x = rec.x, y = rec.y,
    width = rec.width, height = rec.height, resizable = rec.resizable, decorated = rec.decorated,
    ownerJobId = rec.owner, code = "gpu.setBackground(0x000000) gpu.fill(1, 1, " .. rec.width .. ", " .. rec.height .. ", ' ')"})
  if not size then
    K.windowsChanged(rec.user)
    return nil, err
  end
  rec.session, rec.key = S.id, newKey()
  if rec.status and S.display.status then S.display.status(rec.id, rec.status) end
  announce(rec)
  K.windowsChanged(rec.user)
  return true
end

-- The window is gone (closed, or its program ended unseen).
function W.close(rec)
  local S = rec.session and K.byId[rec.session]
  W.byId[rec.id] = nil
  if S then pcall(S.display.remove, rec.id) end
  K.windowsChanged(rec.user)
end

-- A display reports a window's new place or size (moved, resized).
function W.moved(rec, x, y, width, height)
  rec.x, rec.y = x or rec.x, y or rec.y
  rec.width, rec.height = width or rec.width, height or rec.height
end

function W.ownedBy(jobId)
  local list = {}
  for _, rec in pairs(W.byId) do
    if rec.owner == jobId then list[#list + 1] = rec end
  end
  return list
end

-- A user's windows, wherever they are: for their taskbars.
function W.ofUser(user)
  local list = {}
  for _, rec in pairs(W.byId) do
    if rec.user == user then list[#list + 1] = W.describe(rec) end
  end
  table.sort(list, function(a, b) return a.id < b.id end)
  return list
end

-- A process ended: its windows say so; any not shown anywhere go.
function W.jobEnded(jobId, status)
  for _, rec in ipairs(W.ownedBy(jobId)) do
    rec.status = status
    local S = rec.session and K.byId[rec.session]
    if S then
      if S.display.status then S.display.status(rec.id, status) end
    else
      W.close(rec)
    end
    K.windowsChanged(rec.user)
  end
  for _, rec in pairs(W.byId) do rec.holders[jobId] = nil end
end

-- A session ends: what it showed is detached (programs still running
-- keep their windows) or closed (programs that have ended).
function W.sessionEnded(S)
  for _, rec in pairs(W.byId) do
    if rec.session == S.id then
      if rec.status then W.close(rec) else W.detach(rec) end
    end
  end
end

return W
