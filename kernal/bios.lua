-- muxos kernal BIOS; see docs/PROTOCOL.md.
local invoke = component.invoke
local function call(a, m, ...)
  local r = table.pack(pcall(invoke, a, m, ...))
  if r[1] then return table.unpack(r, 2, r.n) end
  return nil, r[2]
end
local list, tmp = component.list, computer.tmpAddress()
local eeprom, gpu, screen = list("eeprom")(), list("gpu")(), list("screen")()
if gpu and screen then call(gpu, "bind", screen) end

-- Crude screen output: one line each, top down. The final error is
-- shown by OpenComputers' own crash screen.
local lines = {}
local function say(text)
  lines[#lines + 1] = text
  if gpu and screen then call(gpu, "set", 1, #lines, text) end
end
if gpu and screen then call(gpu, "fill", 1, 1, 160, 50, " ") end

-- Failure: dump to a writable disk, stop.
local function stop(text)
  say(text)
  local disk
  local d = {"muxos BIOS dump", table.concat(lines, "\n"), "",
    "uptime " .. computer.uptime() .. "  memory " .. computer.freeMemory() .. "/" .. computer.totalMemory()
    .. "  energy " .. computer.energy() .. "/" .. computer.maxEnergy(), "eeprom data " .. tostring(call(eeprom, "getData"))}
  for a, t in list() do
    local x = a .. " " .. t
    if t == "filesystem" then
      x = x .. " \"" .. tostring(call(a, "getLabel")) .. "\" ro=" .. tostring(call(a, "isReadOnly"))
        .. " " .. tostring(call(a, "spaceUsed")) .. "/" .. tostring(call(a, "spaceTotal")) .. ": "
        .. table.concat(call(a, "list", "/") or {}, " ")
      if not disk and a ~= tmp and not call(a, "isReadOnly") then disk = a end
    end
    d[#d + 1] = x
  end
  local h = disk and call(disk, "open", "/muxos-boot-dump.txt", "w")
  if h then
    call(disk, "write", h, table.concat(d, "\n") .. "\n")
    call(disk, "close", h)
    say("Dump: " .. disk:sub(1, 8) .. "/muxos-boot-dump.txt")
  end
  error(table.concat(lines, "\n"), 0)
end

-- Opened directly, like the stock BIOS.
local function loadFrom(a, path)
  local h, why = call(a, "open", path)
  if not h then return nil, why ~= path and why ~= "file not found" and why or nil end
  local parts = {}
  repeat
    local data, why = call(a, "read", h, math.maxinteger or math.huge)
    if not data and why then return nil, why end
    parts[#parts + 1] = data
  until not data
  call(a, "close", h)
  return load(table.concat(parts), "=" .. path)
end

local problems = {}
local function try(a, path)
  local chunk, why = loadFrom(a, path)
  if not chunk and why then problems[#problems + 1] = a:sub(1, 8) .. path .. ": " .. tostring(why) end
  return chunk
end

local init
local remembered = call(eeprom, "getData")
if remembered and remembered ~= "" then init = try(remembered, "/muxos.lua") end
if not init then
  call(eeprom, "setData", "")
  for a in list("filesystem") do
    init = try(a, "/muxos.lua")
    if init then
      call(eeprom, "setData", a)
      break
    end
  end
end
if init then
  computer.beep(1000, 0.2)
  return init()
end

-- The installer (it handles its own crashes), retried for 5 s: a rack's
-- drive can attach late.
say("muxos: no system; looking for the installer floppy...")
local wait = computer.uptime() + 5
repeat
  problems = {}
  for a in list("filesystem") do
    local installer = try(a, "/muxos-installer.lua")
    if installer then
      computer.beep(800, 0.2)
      return installer(a, "/muxos-installer.lua")
    end
  end
  computer.pullSignal(1)
until computer.uptime() > wait

say("Nothing to boot. Disks this computer can see, and their files:")
for a in list("filesystem") do
  local names, why = call(a, "list", "/")
  say("  " .. a:sub(1, 8) .. (a == tmp and " (tmpfs)" or "") .. " \"" .. tostring(call(a, "getLabel") or "")
    .. "\": " .. (names and table.concat(names, " ") or "can't list: " .. tostring(why)))
end
for _, p in ipairs(problems) do say("  " .. p) end
stop("Put the installer floppy in a drive connected to this computer.")
