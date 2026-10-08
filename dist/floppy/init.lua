-- The muxos installer floppy's boot file, installed as /init.lua at the
-- floppy's root next to muxos-installer.lua. Any BIOS that boots /init.lua
-- runs it -- the stock OpenComputers Lua BIOS every computer starts with
-- -- so an empty computer boots this floppy straight into the installer,
-- with no OpenOS and no muxos BIOS. (The muxos kernal BIOS finds
-- /muxos-installer.lua itself.) Installing flashes the kernal BIOS.
-- If it can't start the installer it stops with why; the installer
-- handles (and dumps) its own crashes.
local invoke, path = component.invoke, "/muxos-installer.lua"
local function call(a, m, ...)
  local r = table.pack(pcall(invoke, a, m, ...))
  if r[1] then return table.unpack(r, 2, r.n) end
  return nil, r[2]
end
-- Stops with the error, which OpenComputers' crash screen shows.
local function fail(text) error(text, 0) end
-- Opened directly, like the stock BIOS does, rather than asking `exists`.
local function has(address)
  local handle = call(address, "open", path)
  if handle then call(address, "close", handle) end
  return handle ~= nil
end
local address = computer.getBootAddress and computer.getBootAddress()
if not (address and has(address)) then
  address = nil
  for a in component.list("filesystem") do
    if has(a) then address = a break end
  end
end
if not address then fail("muxos installer: " .. path .. " isn't on any disk -- copy it next to this init.lua") end
local handle, why = call(address, "open", path)
if not handle then fail("muxos installer: can't open " .. path .. ": " .. tostring(why)) end
local chunks = {}
repeat
  local data, why = call(address, "read", handle, math.maxinteger or math.huge)
  if not data and why then fail("muxos installer: reading " .. path .. " failed: " .. tostring(why)) end
  chunks[#chunks + 1] = data
until not data
call(address, "close", handle)
local installer, err = load(table.concat(chunks), "=" .. path)
chunks = nil
if not installer then fail("muxos installer didn't load: " .. tostring(err)) end
return installer(address, path)
