-- muxos kernal BIOS (the kernal's EEPROM image; see docs/PROTOCOL.md,
-- "The kernal BIOS"). Boots, in order: the disk the EEPROM remembers, any
-- disk with /muxos.lua, then the installer floppy (/muxos-installer.lua).
-- If nothing boots, or the installer fails, it lists on the screen every
-- disk it can see and what's on it, then stops with the same text as its
-- error (what the Analyzer shows).
local invoke = component.invoke
local function call(address, method, ...)
  local result = table.pack(pcall(invoke, address, method, ...))
  if not result[1] then return nil, result[2] end
  return table.unpack(result, 2, result.n)
end

local eeprom = component.list("eeprom")()
local gpu, screen = component.list("gpu")(), component.list("screen")()
if gpu and screen then call(gpu, "bind", screen) end

-- Every line goes to the screen (if there is one) and into the error.
local lines = {}
local function say(text)
  lines[#lines + 1] = text
  if gpu and screen then
    local w, h = call(gpu, "getResolution")
    if #lines == 1 then call(gpu, "fill", 1, 1, w, h, " ") end
    if #lines > h then
      call(gpu, "copy", 1, 2, w, h - 1, 0, -1)
      call(gpu, "fill", 1, h, w, 1, " ")
    end
    call(gpu, "set", 1, math.min(#lines, h), text)
  end
end
local function stop(text)
  say(text)
  error(table.concat(lines, "\n"), 0)
end

-- Loads `path` from a disk: the chunk, or nil and why (nil alone when
-- it isn't there). Read in pieces joined once, to spare memory.
local function loadFrom(address, path)
  if not call(address, "exists", path) then return nil end
  local handle, reason = call(address, "open", path)
  if not handle then return nil, reason end
  local chunks = {}
  repeat
    local data, reason = call(address, "read", handle, math.maxinteger or math.huge)
    if not data and reason then return nil, reason end
    chunks[#chunks + 1] = data
  until not data
  call(address, "close", handle)
  return load(table.concat(chunks), "=" .. path)
end

local problems = {}
local function try(address, path)
  local chunk, reason = loadFrom(address, path)
  if not chunk and reason then problems[#problems + 1] = address:sub(1, 8) .. path .. ": " .. tostring(reason) end
  return chunk
end

local init
local remembered = call(eeprom, "getData")
if remembered and remembered ~= "" then init = try(remembered, "/muxos.lua") end
if not init then
  call(eeprom, "setData", "")
  for address in component.list("filesystem") do
    init = try(address, "/muxos.lua")
    if init then
      call(eeprom, "setData", address)
      break
    end
  end
end
if init then
  computer.beep(1000, 0.2)
  return init()
end

for address in component.list("filesystem") do
  local installer = try(address, "/muxos-installer.lua")
  if installer then
    computer.beep(800, 0.2)
    local ok, err = xpcall(installer, debug.traceback, address, "/muxos-installer.lua")
    if ok then return end
    lines = {}
    stop("muxos installer stopped: " .. tostring(err))
  end
end

say("muxos: nothing to boot. Disks this computer can see:")
local count = 0
for address in component.list("filesystem") do
  count = count + 1
  local has = {}
  for _, name in ipairs({"muxos.lua", "muxos-installer.lua", "muxos-installer.dat", "init.lua"}) do
    if call(address, "exists", "/" .. name) then has[#has + 1] = name end
  end
  say("  " .. address:sub(1, 8) .. (address == computer.tmpAddress() and " (tmpfs)" or "")
    .. " \"" .. tostring(call(address, "getLabel") or "") .. "\": "
    .. (#has > 0 and table.concat(has, " ") or "none of muxos's files"))
end
if count == 0 then say("  none") end
for _, problem in ipairs(problems) do say("  " .. problem) end
stop("Put the installer floppy (with muxos-installer.lua at its root) in a disk drive connected to this computer.")
