-- The kernal's own EEPROM image. muxos REPLACES OpenOS on the kernal --
-- it is not a program that runs on top of it -- so there is no stock
-- OpenOS /init.lua in this picture at all, and this is not a thin
-- network-boot stub like node/bios.lua either (the kernal has its own
-- disk right here, nothing to fetch over a modem).
--
-- This mirrors the mod's own stock EEPROM image almost line for line
-- (assets/opencomputers/lua/bios.lua in the OpenComputers source,
-- verified against it directly, not guessed): same
-- getBootAddress/setBootAddress-via-the-EEPROM-component's-own-data
-- pattern, same "try the remembered boot device first, then scan every
-- filesystem component for a bootable one" fallback, same gpu/screen
-- auto-bind -- except it loads /muxos.lua instead of /init.lua, because
-- muxos IS the init here, and falls back to the muxos installer. Like
-- all EEPROM code, it runs in the mod's sandbox (machine.lua); what
-- OpenOS would add on top (event, thread, keyboard, io, ...) isn't
-- there, so kernal/muxos.lua builds what it needs itself.

local component_invoke = component.invoke
local function boot_invoke(address, method, ...)
  local result = table.pack(pcall(component_invoke, address, method, ...))
  if not result[1] then
    return nil, result[2]
  else
    return table.unpack(result, 2, result.n)
  end
end

local eeprom = component.list("eeprom")()
local function getBootAddress()
  return boot_invoke(eeprom, "getData")
end
local function setBootAddress(address)
  return boot_invoke(eeprom, "setData", address)
end

do
  local screen = component.list("screen")()
  local gpu = component.list("gpu")()
  if gpu and screen then
    boot_invoke(gpu, "bind", screen)
  end
end

-- Loads `path` from a disk: the chunk, or nil and why (nil alone when
-- the file isn't there). Read in pieces joined once, to spare memory.
local function tryLoadFrom(address, path)
  if not boot_invoke(address, "exists", path) then return nil end
  local handle, reason = boot_invoke(address, "open", path)
  if not handle then
    return nil, reason
  end
  local chunks = {}
  repeat
    local data, reason = boot_invoke(address, "read", handle, math.maxinteger or math.huge)
    if not data and reason then
      return nil, reason
    end
    chunks[#chunks + 1] = data
  until not data
  boot_invoke(address, "close", handle)
  return load(table.concat(chunks), "=" .. path)
end

-- Boot order: the disk the EEPROM remembers, then any disk with
-- /muxos.lua, then a disk with the muxos installer (a floppy made by
-- opm or the build), which runs here with no OpenOS. An installed system
-- always wins, so a forgotten installer floppy doesn't reinstall. If
-- nothing boots, the error (the Analyzer shows it) says what was tried.
local why, disks = {}, 0
local function try(address, path)
  local chunk, reason = tryLoadFrom(address, path)
  if not chunk and reason then why[#why + 1] = address:sub(1, 8) .. path .. ": " .. tostring(reason) end
  return chunk
end
local init
if getBootAddress() then
  init = try(getBootAddress(), "/muxos.lua")
end
if not init then
  setBootAddress()
  for address in component.list("filesystem") do
    if address ~= computer.tmpAddress() then disks = disks + 1 end
    init = try(address, "/muxos.lua")
    if init then
      setBootAddress(address)
      break
    end
  end
end
if not init then
  for address in component.list("filesystem") do
    local installer = try(address, "/muxos-installer.lua")
    if installer then
      computer.beep(800, 0.2)
      return installer(address, "/muxos-installer.lua")
    end
  end
end
if not init then
  error(#why > 0 and "nothing would load: " .. table.concat(why, "; ")
    or "no /muxos.lua or /muxos-installer.lua on " .. disks .. " disk(s) (is the installer floppy in a disk drive?)", 0)
end
computer.beep(1000, 0.2)
return init()
