-- The muxos installer floppy's boot file, installed as /init.lua at the
-- floppy's root next to muxos-installer.lua. Any BIOS that boots /init.lua
-- runs it -- the stock OpenComputers Lua BIOS every computer starts with
-- -- so an empty computer boots this floppy straight into the installer,
-- with no OpenOS and no muxos BIOS. (The muxos kernal BIOS finds
-- /muxos-installer.lua itself.) Installing flashes the kernal BIOS.
-- Anything that goes wrong is shown on the screen and dumped to a file.
local invoke, path = component.invoke, "/muxos-installer.lua"
local gpu, screen = component.list("gpu")(), component.list("screen")()
-- On failure: the error on the screen, and a dump -- the error, the
-- machine, every component and every disk's root listing -- written to
-- /muxos-boot-dump.txt on this floppy (else any writable disk), for
-- debugging. Then stop, with the error for the Analyzer.
local function call(a, m, ...)
  local r = table.pack(pcall(invoke, a, m, ...))
  if r[1] then return table.unpack(r, 2, r.n) end
  return nil, r[2]
end
local function fail(text, disk)
  local shown = {text}
  local d = {"muxos floppy init.lua boot dump", text, "",
    "uptime " .. computer.uptime() .. "  memory " .. computer.freeMemory() .. "/" .. computer.totalMemory()
    .. "  energy " .. computer.energy() .. "/" .. computer.maxEnergy(),
    "boot address " .. tostring(computer.getBootAddress and computer.getBootAddress())}
  local tmp = computer.tmpAddress()
  for a, t in component.list() do
    local x = a .. " " .. t
    if t == "filesystem" then
      x = x .. " \"" .. tostring(call(a, "getLabel")) .. "\" ro=" .. tostring(call(a, "isReadOnly"))
        .. " " .. tostring(call(a, "spaceUsed")) .. "/" .. tostring(call(a, "spaceTotal")) .. ": "
        .. table.concat(call(a, "list", "/") or {}, " ")
      if not disk and a ~= tmp and not call(a, "isReadOnly") then disk = a end
    end
    d[#d + 1] = x
  end
  if disk and call(disk, "isReadOnly") then disk = nil end
  local h = disk and call(disk, "open", "/muxos-boot-dump.txt", "w")
  if h then
    call(disk, "write", h, table.concat(d, "\n") .. "\n")
    call(disk, "close", h)
    shown[#shown + 1] = "Dump: " .. disk:sub(1, 8) .. "/muxos-boot-dump.txt"
  end
  if gpu and screen then
    pcall(invoke, gpu, "bind", screen)
    local w, h = invoke(gpu, "getResolution")
    invoke(gpu, "fill", 1, 1, w, h, " ")
    local y = 1
    for line in (table.concat(shown, "\n") .. "\n"):gmatch("([^\n]*)\n") do
      while #line > 0 and y <= h do
        invoke(gpu, "set", 1, y, line:sub(1, w))
        line, y = line:sub(w + 1), y + 1
      end
    end
  end
  error(text, 0)
end
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
if not handle then fail("muxos installer: can't open " .. path .. ": " .. tostring(why), address) end
local chunks = {}
repeat
  local data, why = call(address, "read", handle, math.maxinteger or math.huge)
  if not data and why then fail("muxos installer: reading " .. path .. " failed: " .. tostring(why), address) end
  chunks[#chunks + 1] = data
until not data
call(address, "close", handle)
local installer, err = load(table.concat(chunks), "=" .. path)
chunks = nil
if not installer then fail("muxos installer didn't load: " .. tostring(err), address) end
local ok, failure = xpcall(installer, debug.traceback, address, path)
if not ok then fail("muxos installer stopped: " .. tostring(failure), address) end
