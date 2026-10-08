-- The muxos installer floppy's boot file, installed as /init.lua at the
-- floppy's root next to muxos-installer.lua. Any BIOS that boots /init.lua
-- runs it -- the stock OpenComputers Lua BIOS every computer starts with
-- -- so an empty computer boots this floppy straight into the installer,
-- with no OpenOS and no muxos BIOS. (The muxos kernal BIOS finds
-- /muxos-installer.lua itself.) Installing flashes the kernal BIOS.
local invoke, path = component.invoke, "/muxos-installer.lua"
local function has(address)
  local ok, found = pcall(invoke, address, "exists", path)
  return ok and found
end
local address = computer.getBootAddress and computer.getBootAddress()
if not (address and has(address)) then
  address = nil
  for a in component.list("filesystem") do
    if has(a) then address = a break end
  end
end
if not address then error("muxos installer: " .. path .. " isn't on any disk -- copy it next to this init.lua", 0) end
local handle = assert(invoke(address, "open", path))
local chunks = {}
repeat
  local data = invoke(address, "read", handle, math.maxinteger or math.huge)
  chunks[#chunks + 1] = data
until not data
invoke(address, "close", handle)
local installer, err = load(table.concat(chunks), "=" .. path)
chunks = nil
if not installer then error("muxos installer didn't load: " .. tostring(err), 0) end
return installer(address, path)
