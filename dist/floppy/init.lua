-- The muxos installer floppy's boot file, installed as /init.lua at the
-- floppy's root next to muxos-installer.lua. Any BIOS that boots /init.lua
-- runs it -- the stock OpenComputers Lua BIOS every computer starts with
-- -- so an empty computer boots this floppy straight into the installer,
-- with no OpenOS and no muxos BIOS. (The muxos kernal BIOS finds
-- /muxos-installer.lua itself.) Installing flashes the kernal BIOS.
-- Anything that goes wrong is shown on the screen, not only the Analyzer.
local invoke, path = component.invoke, "/muxos-installer.lua"
local gpu, screen = component.list("gpu")(), component.list("screen")()
local function fail(text)
  if gpu and screen then
    pcall(invoke, gpu, "bind", screen)
    local w, h = invoke(gpu, "getResolution")
    invoke(gpu, "fill", 1, 1, w, h, " ")
    local y = 1
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
      while #line > 0 and y <= h do
        invoke(gpu, "set", 1, y, line:sub(1, w))
        line, y = line:sub(w + 1), y + 1
      end
    end
  end
  error(text, 0)
end
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
if not address then fail("muxos installer: " .. path .. " isn't on any disk -- copy it next to this init.lua") end
local handle = assert(invoke(address, "open", path))
local chunks = {}
repeat
  local data = invoke(address, "read", handle, math.maxinteger or math.huge)
  chunks[#chunks + 1] = data
until not data
invoke(address, "close", handle)
local installer, err = load(table.concat(chunks), "=" .. path)
chunks = nil
if not installer then fail("muxos installer didn't load: " .. tostring(err)) end
local ok, failure = xpcall(installer, debug.traceback, address, path)
if not ok then fail("muxos installer stopped: " .. tostring(failure)) end
