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
-- muxos IS the init here. Everything past this point (computer.pullSignal,
-- event, thread, keyboard, io, component.proxy/dot-shorthand, ...) is
-- OpenOS's own lib/boot code, confirmed absent from the mod's native
-- Scala-registered API surface (ComponentAPI.scala/ComputerAPI.scala),
-- so kernal/muxos.lua builds every one of those itself from the real
-- primitives (component.list/component.invoke, coroutine.yield) rather
-- than assuming they exist.

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

local function tryLoadFrom(address)
  local handle, reason = boot_invoke(address, "open", "/muxos.lua")
  if not handle then
    return nil, reason
  end
  local buffer = ""
  repeat
    local data, reason = boot_invoke(address, "read", handle, math.maxinteger or math.huge)
    if not data and reason then
      return nil, reason
    end
    buffer = buffer .. (data or "")
  until not data
  boot_invoke(address, "close", handle)
  return load(buffer, "=muxos")
end

local init, reason
if getBootAddress() then
  init, reason = tryLoadFrom(getBootAddress())
end
if not init then
  setBootAddress()
  for address in component.list("filesystem") do
    init, reason = tryLoadFrom(address)
    if init then
      setBootAddress(address)
      break
    end
  end
end
if not init then
  error("no bootable medium found" .. (reason and (": " .. tostring(reason)) or ""), 0)
end
computer.beep(1000, 0.2)
return init()
