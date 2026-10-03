-- Bare-metal worker firmware for huh2.
--
-- Flash this directly onto a worker node's EEPROM (see README.md). It is
-- the ENTIRE runtime for that node -- there is no OS, no filesystem, no
-- `require`. It boots straight into an event loop that waits for jobs from
-- the arbiter and executes them.
--
-- Wire format: see docs/PROTOCOL.md. The serializer below is duplicated in
-- arbiter/rackos.lua on purpose -- EEPROM code can't load other files, so
-- both sides keep their own copy in sync by hand.

local PORT = 4477

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

local function findModem()
  for addr in component.list("modem") do
    return component.proxy(addr)
  end
end

local modem = findModem()
if not modem then
  -- No network/wireless card present -- there is no way to receive jobs.
  -- Beep and halt rather than spin silently.
  computer.beep(200, 0.5)
  while true do computer.pullSignal() end
end

modem.open(PORT)

local nodeId = computer.address()

local function send(msg)
  modem.broadcast(PORT, serialize(msg))
end

-- Announce ourselves so the arbiter can pick us up without a separate
-- discovery pass if it happens to be listening already.
send({type = "HELLO", from = nodeId})

while true do
  local name, _, from, port, _, data = computer.pullSignal()
  if name == "modem_message" and port == PORT and type(data) == "string" then
    local msg = deserialize(data)
    if type(msg) == "table" and (msg.to == nil or msg.to == nodeId) then
      if msg.type == "PING" then
        send({type = "PONG", from = nodeId, to = msg.from, id = msg.id})
      elseif msg.type == "JOB" then
        local chunk, loadErr = load("local args = ...\n" .. msg.code, "=job", "t")
        if not chunk then
          send({type = "ERROR", from = nodeId, to = msg.from, id = msg.id, error = loadErr})
        else
          local ok, result = pcall(chunk, msg.args)
          if ok then
            send({type = "RESULT", from = nodeId, to = msg.from, id = msg.id, result = result})
          else
            send({type = "ERROR", from = nodeId, to = msg.from, id = msg.id, error = tostring(result)})
          end
        end
      elseif msg.type == "LIST" then
        -- Expose this node's own components to the arbiter, so it can
        -- address them without us having to write custom JOB code for it.
        local list = {}
        for addr, ctype in component.list() do
          list[addr] = ctype
        end
        send({type = "RESULT", from = nodeId, to = msg.from, id = msg.id, result = list})
      elseif msg.type == "INVOKE" then
        -- Call a method on one of this node's own components on the
        -- arbiter's behalf -- this is the "remote component" bridge:
        -- addressed like a local component.invoke(), but carried over the
        -- modem instead of being a direct in-process call.
        local packed = table.pack(pcall(component.invoke, msg.address, msg.method, table.unpack(msg.args or {})))
        if packed[1] then
          local returns = {}
          for i = 2, packed.n do returns[#returns + 1] = packed[i] end
          send({type = "RESULT", from = nodeId, to = msg.from, id = msg.id, result = returns})
        else
          send({type = "ERROR", from = nodeId, to = msg.from, id = msg.id, error = tostring(packed[2])})
        end
      end
    end
  end
end
