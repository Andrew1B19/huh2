-- EEPROM loader for test/hardware/verify.lua (too big for an EEPROM
-- itself): finds /verify.lua on any filesystem and runs it.
for address in component.list("filesystem") do
  local handle = component.invoke(address, "open", "/verify.lua")
  if handle then
    local source = ""
    repeat
      local data = component.invoke(address, "read", handle, math.huge)
      source = source .. (data or "")
    until not data
    component.invoke(address, "close", handle)
    return assert(load(source, "=verify"))()
  end
end
error("no /verify.lua on any filesystem", 0)
