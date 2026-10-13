-- muxos system bus: programs (and the kernal) talking to each other by
-- name -- muxos's D-Bus. Not the cluster *component* bus (hardware on
-- any node); this one is for software.
--
-- - Names: a process owns a name ("player", "backup.status") while it
--   runs; others call its methods by that name, wherever it runs and
--   whoever started it. Names under "muxos." are the kernal's own
--   services (muxos.system, muxos.update -- OPM's interface).
-- - Calls: the kernal routes a call to the name's owner as an event
--   ({"sysbus_call", call, name, method, caller, args}) and its answer
--   (op "reply") back to the caller. A call not answered in its timeout
--   fails, as does one whose service ends.
-- - Signals: a process emits a signal ("backup.done"); every process
--   listening for it (or a pattern: "backup.*", "*") gets
--   {"sysbus_signal", signal, sender, args}. The kernal emits
--   muxos.login/muxos.logout {user, where} and muxos.node {address,
--   "up"/"down"}.
-- `caller`/`sender` are {job, user} ({kernal = true} for the kernal);
-- `args` are packed lists ({n = ...}) of plain data.
--
-- Loaded by kernal/muxos.lua: loadSibling("sysbus.lua")(K, {send, selfAddr}).
-- The worker runtime's `sysbus` library is the programs' side (node/runtime.lua).
local K, deps = ...
local send, selfAddr = deps.send, deps.selfAddr

local B = {names = {}, calls = {}, listeners = {}, kernal = {}, running = {}}
local DEFAULT_TIMEOUT, MAX_TIMEOUT = 30, 86400
local nextCall = 0

local function validName(name)
  return type(name) == "string" and #name <= 64 and name:match("^[%w_%-]+[%w_%-%.]*$") ~= nil
    and not name:find("..", 1, true) and name:sub(-1) ~= "."
end

local function reserved(name)
  return name == "muxos" or name:sub(1, 6) == "muxos."
end

local function answer(msg, result, err)
  if not msg.id or msg.noReply then return end
  if err ~= nil then
    send({type = "ERROR", from = selfAddr, to = msg.from, id = msg.id, error = tostring(err)})
  else
    send({type = "RESULT", from = selfAddr, to = msg.from, id = msg.id, result = result})
  end
end

local function packed(t)
  if type(t) ~= "table" then return {n = 0} end
  t.n = math.tointeger(t.n) or #t
  return t
end

-- A kernal service: `methods[name](ctx, ...)` returns the call's
-- results or raises its error. ctx = {job, user} (job nil from the
-- console). Each call runs in a coroutine of its own, so a method may
-- take its time (K.wait).
function B.provide(name, methods)
  B.kernal[name] = methods
  B.names[name] = {kernal = true}
end

local function finishCall(c, ok, results)
  if c.finished then return end
  c.finished = true
  if c.id then B.calls[c.id] = nil end
  if c.console then
    c.done, c.ok, c.results = true, ok, results
  elseif ok then
    answer(c.msg, packed(results))
  else
    answer(c.msg, nil, results)
  end
end

local function step(entry)
  local prev = K.current
  K.current = nil
  local ok, res = coroutine.resume(entry.co)
  K.current = prev
  if coroutine.status(entry.co) ~= "dead" then return false end
  K.commands[entry.co] = nil
  if ok then finishCall(entry.call, true, res) else finishCall(entry.call, false, tostring(res)) end
  return true
end

-- Starts call `c` ({msg | console, caller, user, timeout}) of `method`
-- on `name` with `args`.
local function startCall(c, name, method, args)
  local target = validName(name) and B.names[name]
  local job = target and target.job and K.liveJob(target.job)
  if target and target.job and not job then
    B.names[name], target = nil, nil
  end
  if not target then return finishCall(c, false, "no service named " .. tostring(name)) end
  if type(method) ~= "string" or method == "" then return finishCall(c, false, "no method name") end
  nextCall = nextCall + 1
  c.id, c.name, c.method = nextCall, name, method
  c.deadline = computer.uptime() + c.timeout
  B.calls[c.id] = c
  if target.kernal then
    local fn = B.kernal[name][method]
    if type(fn) ~= "function" then return finishCall(c, false, name .. " has no method " .. method) end
    local ctx = {job = c.caller, user = c.user}
    local co = coroutine.create(function() return table.pack(fn(ctx, table.unpack(args, 1, args.n))) end)
    K.commands[co] = true
    local entry = {co = co, call = c}
    if not step(entry) then B.running[#B.running + 1] = entry end
  else
    c.service = job.id
    K.deliverEvent(job, {"sysbus_call", c.id, name, method, {job = c.caller, user = c.user}, args})
  end
end

local function matches(pattern, signal)
  if pattern == "*" or pattern == signal then return true end
  local prefix = pattern:match("^(.*)%.%*$")
  return prefix ~= nil and signal:sub(1, #prefix + 1) == prefix .. "."
end

-- Emits `signal` from `sender` ({job, user} or {kernal = true}).
function B.signal(signal, sender, args)
  args = packed(args)
  for jobId, patterns in pairs(B.listeners) do
    local job = K.liveJob(jobId)
    if not job then
      B.listeners[jobId] = nil
    else
      for pattern in pairs(patterns) do
        if matches(pattern, signal) then
          K.deliverEvent(job, {"sysbus_signal", signal, sender, args})
          break
        end
      end
    end
  end
end

-- The kernal's own signals.
function B.emit(signal, ...)
  B.signal(signal, {kernal = true}, table.pack(...))
end

-- Every name and who has it.
function B.list()
  local list = {}
  for name, t in pairs(B.names) do
    local job = t.job and K.jobs[t.job]
    list[#list + 1] = {name = name, job = t.job, user = job and job.user, kernal = t.kernal or nil}
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

-- An SBUS message from process `caller` (checked by the kernal).
function B.message(msg, caller)
  if not caller then return answer(msg, nil, "not called from a running process") end
  local op = msg.op
  if op == "call" then
    local timeout = tonumber(msg.timeout) or DEFAULT_TIMEOUT
    timeout = math.max(0.1, math.min(timeout, MAX_TIMEOUT))
    return startCall({msg = msg, caller = caller.id, user = caller.user, timeout = timeout},
      msg.name, msg.method, packed(msg.args))
  elseif op == "reply" then
    local c = B.calls[msg.call]
    if c and c.service == caller.id then
      if msg.ok == false then finishCall(c, false, tostring(msg.error)) else finishCall(c, true, msg.result) end
    end
    return answer(msg, true)
  elseif op == "emit" then
    if not validName(msg.signal) or reserved(msg.signal) then
      return answer(msg, nil, "bad signal name: " .. tostring(msg.signal))
    end
    B.signal(msg.signal, {job = caller.id, user = caller.user}, msg.args)
    return answer(msg, true)
  elseif op == "listen" or op == "unlisten" then
    local pattern = msg.pattern
    if not (pattern == "*" or validName(pattern) or (type(pattern) == "string" and validName(pattern:match("^(.*)%.%*$")))) then
      return answer(msg, nil, "bad signal pattern: " .. tostring(pattern))
    end
    local set = B.listeners[caller.id] or {}
    B.listeners[caller.id] = set
    set[pattern] = op == "listen" or nil
    return answer(msg, true)
  elseif op == "own" then
    local name = msg.name
    if not validName(name) then return answer(msg, nil, "bad name: " .. tostring(name)) end
    if reserved(name) then return answer(msg, nil, name .. " is the kernal's") end
    local t = B.names[name]
    local holder = t and t.job and K.liveJob(t.job)
    if holder and holder.id ~= caller.id then
      return answer(msg, nil, name .. " is taken (process " .. holder.id .. ")")
    end
    B.names[name] = {job = caller.id}
    return answer(msg, true)
  elseif op == "release" then
    local t = B.names[msg.name]
    if t and t.job == caller.id then B.names[msg.name] = nil end
    return answer(msg, true)
  elseif op == "list" then
    return answer(msg, B.list())
  end
  answer(msg, nil, "unknown system bus operation: " .. tostring(op))
end

-- A call from a session's console (a command coroutine): waits for the
-- answer. Returns ok, results (or the error).
function B.consoleCall(S, name, method, args)
  local c = {console = true, user = S and S.user, timeout = DEFAULT_TIMEOUT}
  startCall(c, name, method, packed(args))
  while not c.done do K.wait(0.05) end
  return c.ok, c.results
end

-- A process ended: its names go, its calls in progress fail.
function B.jobEnded(id)
  for name, t in pairs(B.names) do
    if t.job == id then B.names[name] = nil end
  end
  B.listeners[id] = nil
  for _, c in pairs(B.calls) do
    if c.service == id then finishCall(c, false, c.name .. " ended before answering") end
    if c.caller == id and not c.console then B.calls[c.id] = nil end
  end
end

-- Runs fn after `seconds`, from the tick (a kernal service's work after
-- its answer has gone: a reboot).
function B.after(seconds, fn)
  local co = coroutine.create(function()
    local deadline = computer.uptime() + seconds
    while computer.uptime() < deadline do K.wait(0.05) end
    fn()
  end)
  K.commands[co] = true
  B.running[#B.running + 1] = {co = co, call = {finished = true}}
end

-- Each tick: kernal services' calls carry on; late calls fail.
function B.resume()
  for i = #B.running, 1, -1 do
    if step(B.running[i]) then table.remove(B.running, i) end
  end
  local now = computer.uptime()
  for _, c in pairs(B.calls) do
    if now > c.deadline then
      finishCall(c, false, "no answer from " .. c.name .. " in " .. c.timeout .. " s")
    end
  end
end

return B
