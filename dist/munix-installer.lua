






























local VERSION = "0.1.2"
local DAT_SIZE = 401705
local INIT_LUA = "-- The munix installer floppy's boot file, installed as /init.lua at the\
-- floppy's root next to munix-installer.lua. Any BIOS that boots /init.lua\
-- runs it -- the stock OpenComputers Lua BIOS every computer starts with\
-- -- so an empty computer boots this floppy straight into the installer,\
-- with no OpenOS and no munix BIOS. (The munix kernal BIOS finds\
-- /munix-installer.lua itself.) Installing flashes the kernal BIOS.\
-- If it can't start the installer it stops with why; the installer\
-- handles (and dumps) its own crashes.\
local invoke, path = component.invoke, \"/munix-installer.lua\"\
local function call(a, m, ...)\
  local r = table.pack(pcall(invoke, a, m, ...))\
  if r[1] then return table.unpack(r, 2, r.n) end\
  return nil, r[2]\
end\
-- Stops with the error, which OpenComputers' crash screen shows.\
local function fail(text) error(text, 0) end\
-- Opened directly, like the stock BIOS does, rather than asking `exists`.\
local function has(address)\
  local handle = call(address, \"open\", path)\
  if handle then call(address, \"close\", handle) end\
  return handle ~= nil\
end\
local address = computer.getBootAddress and computer.getBootAddress()\
if not (address and has(address)) then\
  address = nil\
  for a in component.list(\"filesystem\") do\
    if has(a) then address = a break end\
  end\
end\
if not address then fail(\"munix installer: \" .. path .. \" isn't on any disk -- copy it next to this init.lua\") end\
local handle, why = call(address, \"open\", path)\
if not handle then fail(\"munix installer: can't open \" .. path .. \": \" .. tostring(why)) end\
local chunks = {}\
repeat\
  local data, why = call(address, \"read\", handle, math.maxinteger or math.huge)\
  if not data and why then fail(\"munix installer: reading \" .. path .. \" failed: \" .. tostring(why)) end\
  chunks[#chunks + 1] = data\
until not data\
call(address, \"close\", handle)\
local installer, err = load(table.concat(chunks), \"=\" .. path)\
chunks = nil\
if not installer then fail(\"munix installer didn't load: \" .. tostring(err)) end\
return installer(address, path)\
"
local CHUNK = 8192



local launchArgs = table.pack(...)
local bare = type(require) ~= "function"
local component, computer = component, computer
local osfs
if not bare then
component, computer, osfs = require("component"), require("computer"), require("filesystem")
end

local options, positional = {}, {}
if not bare then
for _, a in ipairs(launchArgs) do
local k, v = tostring(a):match("^%-%-([%w%-]+)=(.*)$")
if k then
options[k] = v
elseif tostring(a):match("^%-%-") then
options[tostring(a):sub(3)] = true
else
positional[#positional + 1] = a
end
end
end
local assumeYes = options.yes == true

local function trim(s) return s and s:match("^%s*(.-)%s*$") or nil end



local function breathe()
if bare then computer.pullSignal(0) else os.sleep(0) end
end

local say, ask
local page = function() end
if not bare then
say = function(...) print(...) end
ask = function(prompt)
io.write(prompt)
return trim(io.read())
end
else


local gpuAddr, screenAddr = component.list("gpu")(), component.list("screen")()
local gpu = gpuAddr and component.proxy(gpuAddr)
local w, h, x, y = 80, 25, 1, 1
if gpu then
if screenAddr then gpu.bind(screenAddr) end
w, h = gpu.getResolution()

local ok, vw, vh = pcall(gpu.getViewport)
if ok and tonumber(vw) and tonumber(vh) then w, h = math.min(w, vw), math.min(h, vh) end
gpu.setBackground(0x000000)
gpu.setForeground(0xFFFFFF)
gpu.fill(1, 1, w, h, " ")
end

page = function()
if gpu then gpu.fill(1, 1, w, h, " ") end
x, y = 1, 1
end
local function newline()
x = 1
if y < h then
y = y + 1
elseif gpu then
gpu.copy(1, 2, w, h - 1, 0, -1)
gpu.fill(1, h, w, 1, " ")
end
end
local function write(text)
for piece, nl in text:gmatch("([^\n]*)(\n?)") do
while #piece > 0 do
if x > w then newline() end
local part = piece:sub(1, w - x + 1)
if gpu then gpu.set(x, y, part) end
x, piece = x + #part, piece:sub(#part + 1)
end
if nl ~= "" then newline() end
end
end
say = function(...)
local parts = {}
for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
write(table.concat(parts, "\t") .. "\n")
end
ask = function(prompt)
write(prompt)
local line = ""
while true do
local name, _, char, code = computer.pullSignal()
if name == "key_down" then
if code == 28 or code == 156 or char == 13 then
write("\n")
return trim(line)
elseif code == 14 or char == 8 then
if #line > 0 then
line = line:sub(1, -2)
if x > 1 then x = x - 1 elseif y > 1 then x, y = w, y - 1 end
if gpu then gpu.set(x, y, " ") end
end
elseif char and char >= 32 and char < 127 then
line = line .. string.char(char)
write(string.char(char))
end
end
end
end
end




local function confirm(prompt, defaultYes)
if assumeYes then return true end
while true do
local a = ask(prompt .. (defaultYes and " [Y/n] " or " [y/N] "))
if not a then return defaultYes == true end
a = a:lower()
if a == "" then return defaultYes == true end
if a == "y" or a == "yes" then return true end
if a == "n" or a == "no" then return false end
say("Please answer y or n.")
end
end


local function pickNumber(prompt, n)
while true do
local a = ask(prompt)
if not a or a:lower() == "q" then return nil end
local pick = tonumber(a)
if pick and pick == math.floor(pick) and pick >= 1 and pick <= n then return pick end
say("Type a number from 1 to " .. n .. ", or q to cancel.")
end
end

local function human(bytes)
if bytes >= 1048576 then return string.format("%.1f MB", bytes / 1048576) end
return string.format("%.1f KB", bytes / 1024)
end











local function programPath()
local shell = require("shell")
if debug and debug.getinfo then
for level = 1, 10 do
local ok, info = pcall(debug.getinfo, level, "S")
if not ok or not info then break end
local src = info.source and info.source:match("^[@=](.+%.lua)$")
if src then
src = shell.resolve(src)
if src and osfs.exists(src) and not osfs.isDirectory(src) then return src end
end
end
end
local underscore = os.getenv and os.getenv("_")
if underscore and osfs.exists(underscore) then return underscore end
end

local function findMedium()
if bare then
local address, path = launchArgs[1], launchArgs[2]
if type(address) ~= "string" or type(path) ~= "string" then return nil, "booted without its disk's address" end
return {address = address, fs = component.proxy(address), path = path}
end
local full = programPath()
if not full then return nil, "can't tell where this installer is" end
local fs, mount = osfs.get(full)
if not fs then return nil, "can't tell which disk " .. full .. " is on" end
local rel = full:sub(#mount + 1):gsub("^/*", "/")
return {address = fs.address, fs = fs, path = rel, osPath = full}
end



local function openReader(fs, path)
local handle = fs.open(path, "r")
if not handle then return nil end
local buf, eof = "", false
local function fill()
if eof then return false end
local data = fs.read(handle, CHUNK)
if not data then eof = true return false end
buf = buf .. data
return true
end
local r = {}
function r.line()
while true do
local i = buf:find("\n", 1, true)
if i then
local line = buf:sub(1, i - 1)
buf = buf:sub(i + 1)
return line
end
if not fill() then
if buf == "" then return nil end
local line = buf
buf = ""
return line
end
end
end
function r.bytes(n)
while #buf < n and fill() do end
if buf == "" then return nil end
local data = buf:sub(1, n)
buf = buf:sub(n + 1)
return data
end
function r.close() fs.close(handle) end
return r
end




local function bundledPayload(fs, path)
local f = openReader(fs, path)
if not f then return nil, "not there" end
local first, consumed = nil, 0
while true do
local line = f.line()
first = first or line
consumed = consumed + #(line or "") + 1
if not line then
f.close()
if not first then return nil, "it's there, but empty" end
return nil, "it's there, but isn't a munix data file (it starts: "
.. string.format("%q", (first or ""):sub(1, 40)) .. ")"
end
if line:match("^%-%-%[=*%[MUNIX%-PAYLOAD") then
if line:sub(-1) == "\r" then
f.close()
return nil, "the installer's data file had its line endings converted to CRLF, which breaks it -- "
.. "download it again as-is (raw, not through a converting checkout)"
end
local version = line:match("^%-%-%[=*%[MUNIX%-PAYLOAD (%S+)")
if VERSION ~= "dev" and version and version ~= VERSION then
f.close()
return nil, "it's the data file for munix " .. version .. ", but this installer is " .. VERSION
.. " -- get both files again, together"
end
break
end
end
local manifest = f.line() or ""
consumed = consumed + #manifest + 1
local count = tonumber(manifest:match("^@@MANIFEST (%d+)$"))
if not count then f.close() return nil, "damaged payload (no manifest)" end
local files, expected = {}, 0
for i = 1, count do
local line = f.line() or ""
consumed = consumed + #line + 1
local size, name = line:match("^(%d+) (.+)$")
if not size then f.close() return nil, "damaged payload (manifest)" end
files[i] = {path = name, size = tonumber(size)}
expected = expected + #("@@ " .. size .. " " .. name .. "\n") + files[i].size + 1
end
f.close()


expected = consumed + expected + #"@@END\n"
local okSize, size = pcall(fs.size, path)
if okSize and tonumber(size) and size > 0 and size ~= expected then
return nil, "it's damaged: " .. (size < expected and "cut short" or "longer than its contents")
end
local payload = {files = files, fs = fs, path = path}
function payload.each(fn)
local g = assert(openReader(fs, path))
repeat local line = g.line() until not line or line:match("^@@MANIFEST")
for _ = 1, count do g.line() end
for i = 1, count do
local size, name = (g.line() or ""):match("^@@ (%d+) (.+)$")
size = tonumber(size)
if not size or name ~= files[i].path or size ~= files[i].size then
g.close()
error("damaged payload at " .. tostring(files[i].path), 0)
end
local remaining = size
local function read(n)
if remaining <= 0 then return nil end
local data = g.bytes(math.min(n, remaining))
if not data or data == "" then error("damaged payload: " .. name .. " is cut short", 0) end
remaining = remaining - #data
return data
end
if fn(name, size, read) then break end
while remaining > 0 do read(CHUNK) end
g.bytes(1)
end
g.close()
end
return payload
end

local medium, mediumErr = findMedium()
local DAT_NAME = "munix-installer.dat"



local osFiles = {
size = function(path) return osfs and osfs.size(path) or 0 end,
open = function(path) return io.open(path, "rb") end,
read = function(handle, n) return handle:read(n) end,
close = function(handle) handle:close() end,
}




local function findPayload()
local tried, seen = {}, {}
local function try(fs, path, where, key)
if key then
if seen[key] then return end
seen[key] = true
end
local payload, err = bundledPayload(fs, path)
if payload then return payload end



if err ~= "not there" and fs.size then
local ok, size = pcall(fs.size, path)
if ok and size then
err = err .. "; it's " .. size .. " bytes" .. (DAT_SIZE and ", should be " .. DAT_SIZE or "")
local okT, total = pcall(function() return fs.spaceTotal() end)
local okU, used = pcall(function() return fs.spaceUsed() end)
if okT and okU and tonumber(total) and tonumber(used) and total < math.huge then
err = err .. "; its disk has " .. human(total - used) .. " free of " .. human(total)
end
if DAT_SIZE and size < DAT_SIZE then
err = err .. " -- the copy didn't finish (a full disk?): free up space and copy it again"
end
end
end
tried[#tried + 1] = "  " .. where .. ": " .. tostring(err)
end
local payload
if medium then
local dat = medium.path:gsub("[^/]*$", "") .. DAT_NAME
local where = medium.osPath and medium.osPath:gsub("[^/]*$", "") .. DAT_NAME
or "disk " .. tostring(medium.address):sub(1, 8) .. " " .. dat
payload = try(medium.fs, dat, where, tostring(medium.address) .. dat)
if not payload and medium.osPath and tried[#tried]:sub(-9) == "not there" then
payload = try(osFiles, (medium.osPath:gsub("[^/]*$", "") .. DAT_NAME), where .. " (through OpenOS)")
end
else
tried[#tried + 1] = "  next to the installer: " .. tostring(mediumErr)
end
if not payload then
for address in component.list("filesystem") do
payload = try(component.proxy(address), "/" .. DAT_NAME, "disk " .. address:sub(1, 8) .. " /" .. DAT_NAME,
address .. "/" .. DAT_NAME)
if payload then break end
end
end
if payload then return payload end
return nil, "can't find " .. DAT_NAME .. " (it goes next to munix-installer.lua; the two files go together). Looked at:\n"
.. table.concat(tried, "\n")
end



local function currentEeprom()
local addr = component.list("eeprom")()
return addr and component.proxy(addr)
end

local function flash(code, label, data)
local eeprom = currentEeprom()
if not eeprom then return nil, "there's no EEPROM in this computer" end
local size = eeprom.getSize and eeprom.getSize() or 4096
if #code > size then return nil, "the BIOS is " .. #code .. " bytes, the EEPROM holds " .. size end
local ok, result, err = pcall(eeprom.set, code)
if not ok then return nil, tostring(result) end
if result == nil and err then return nil, tostring(err) end
if eeprom.get() ~= code then return nil, "the EEPROM didn't keep what was written (is it read-only?)" end
if eeprom.setLabel then pcall(eeprom.setLabel, label) end
if data then eeprom.setData(data) end
return eeprom.address
end



local function diskList(exclude)
local disks = {}
local tmp = computer.tmpAddress and computer.tmpAddress()
for addr in component.list("filesystem") do
local fs = component.proxy(addr)
if addr ~= exclude and addr ~= tmp and not fs.isReadOnly() then
disks[#disks + 1] = {address = addr, fs = fs, label = fs.getLabel() or "",
free = fs.spaceTotal() - fs.spaceUsed()}
end
end
table.sort(disks, function(a, b) return a.address < b.address end)
return disks
end

local function chooseDisk(disks)
if options.disk then
for _, d in ipairs(disks) do
if d.address:sub(1, #options.disk) == options.disk or d.label == options.disk then return d end
end
return nil, "no writable disk matches " .. options.disk
end
if #disks == 0 then return nil, "no writable disk found (the installer's own disk doesn't count)" end
page()
say("Disks:")
for i, d in ipairs(disks) do
say(string.format("  %d) %s  %s  %s free", i, d.address:sub(1, 8), d.label ~= "" and d.label or "(no label)",
human(d.free)))
end
if #disks == 1 and assumeYes then return disks[1] end
local pick = pickNumber("Install munix on which disk? ", #disks)
if not pick then return nil, "no disk chosen" end
return disks[pick]
end

local function hardwareWarnings()
local warnings = {}
local gpuAddr = component.list("gpu")()
if not gpuAddr then
warnings[#warnings + 1] = "no GPU: the kernal needs a tier 3 GPU"
else
local gpu = component.proxy(gpuAddr)
local ok, depth = pcall(gpu.maxDepth)
if not ok or depth < 8 or not gpu.allocateBuffer then
warnings[#warnings + 1] = "the GPU isn't tier 3: munix's compositor needs a tier 3 GPU (video buffers)"
end
end
if not component.list("screen")() then warnings[#warnings + 1] = "no screen attached" end
if not component.list("modem")() then
warnings[#warnings + 1] = "no network card: the kernal can't reach its workers"
end
return warnings
end

local function readText(fs, path)
if not fs.exists(path) then return nil end
local h = fs.open(path, "r")
if not h then return nil end
local parts = {}
while true do
local data = fs.read(h, CHUNK)
if not data then break end
parts[#parts + 1] = data
end
fs.close(h)
return table.concat(parts)
end

local function writeText(fs, path, text)
local h = assert(fs.open(path, "w"))
fs.write(h, text)
fs.close(h)
end

local function installKernal(payload)
local disk, err = chooseDisk(diskList(medium and medium.address))
if not disk then return nil, err end
local target = disk.fs

local needed = 0
for _, file in ipairs(payload.files) do
if not file.path:match("^/eeprom/") then needed = needed + file.size end
end

if disk.free < needed + 4096 then
return nil, "not enough space on " .. disk.address:sub(1, 8) .. ": " .. human(needed) .. " needed, "
.. human(disk.free) .. " free"
end

for _, w in ipairs(hardwareWarnings()) do say("warning: " .. w) end

local previous = readText(target, "/.munix-version")
local oldName = not previous and readText(target, "/.muxos-version")
previous = previous or oldName
say(previous and ("Upgrading " .. (oldName and "muxos " or "munix ") .. previous:match("^%s*(.-)%s*$")
.. " to " .. (oldName and "munix " or "") .. VERSION) or ("Installing munix " .. VERSION))
say("Target: " .. disk.address .. (disk.label ~= "" and (" (" .. disk.label .. ")") or ""))
say("This also flashes this computer's EEPROM with the munix kernal BIOS.")
if not confirm("Continue?") then return nil, "cancelled" end

local staged, kernalBios = {}, nil
local ok, failure = pcall(payload.each, function(path, size, read)
if path == "/eeprom/kernal.lua" then
local parts = {}
for data in read, CHUNK do parts[#parts + 1] = data end
kernalBios = table.concat(parts)
return
elseif path:match("^/eeprom/") then
return
end
local dir = path:match("^(.*)/[^/]+$")
if dir and dir ~= "" then target.makeDirectory(dir) end
local tmp = path .. ".new"
local h, openErr = target.open(tmp, "w")
if not h then error("can't write " .. tmp .. ": " .. tostring(openErr), 0) end
staged[#staged + 1] = path
local written = 0
for data in read, CHUNK do
local wrote, writeErr = target.write(h, data)
if not wrote then
target.close(h)
error("can't write " .. tmp .. ": " .. tostring(writeErr or "disk full?"), 0)
end
written = written + #data
if written % (CHUNK * 4) == 0 then breathe() end
end
target.close(h)
if written ~= size or target.size(tmp) ~= size then error("short write: " .. path, 0) end
say("  " .. path)
breathe()
end)
if not ok or not kernalBios then
for _, path in ipairs(staged) do target.remove(path .. ".new") end
return nil, (ok and "the kernal BIOS is missing from the installer" or tostring(failure))
.. " -- nothing was changed"
end


for _, path in ipairs(staged) do
if target.exists(path) then target.remove(path) end
if not target.rename(path .. ".new", path) then return nil, "couldn't move " .. path .. " into place" end
end
writeText(target, "/.munix-version", VERSION .. "\n")

for _, old in ipairs({"/muxos.lua", "/.muxos-version"}) do
if target.exists(old) then target.remove(old) end
end
for _, dir in ipairs({"/bin", "/usr/bin", "/usr/lib", "/lib/mxe"}) do target.makeDirectory(dir) end

local flashed, flashErr = flash(kernalBios, "munix kernal", disk.address)
if not flashed then return nil, "files installed, but flashing the EEPROM failed: " .. flashErr end
say("Flashed the kernal BIOS (boots from " .. disk.address:sub(1, 8) .. ").")
say("munix " .. VERSION .. " is installed.")
return true
end







local BIOSES = {
worker = {path = "/eeprom/worker.lua", label = "munix worker", name = "worker"},
kernal = {path = "/eeprom/kernal.lua", label = "munix kernal", name = "kernal"},
}


local function readBioses(payload)
local images = {}
payload.each(function(path, _, read)
for _, bios in pairs(BIOSES) do
if path == bios.path then
local parts = {}
for data in read, CHUNK do parts[#parts + 1] = data end
images[bios.name] = table.concat(parts)
end
end
return images.worker ~= nil and images.kernal ~= nil
end)
return images
end


local function describeEeprom(eeprom, images)
local code = eeprom.get() or ""
local label = eeprom.getLabel and eeprom.getLabel() or ""
if code == "" then return "blank -- nothing on it (a computer says \"no bios found\")" end
for name, image in pairs(images) do
if code == image then return "the munix " .. name .. " BIOS, this version (" .. #code .. " bytes)" end
end
if label:match("^munix ") or label:match("^muxos ") then
return "a " .. label .. " BIOS from a different munix version (" .. #code .. " bytes) -- reflash it"
end
return "something else: \"" .. label .. "\", " .. #code .. " bytes"
end


local function checkEeproms(payload)
local images = readBioses(payload)
while true do
local eeprom = currentEeprom()
say(eeprom and ("EEPROM " .. eeprom.address:sub(1, 8) .. ": " .. describeEeprom(eeprom, images))
or "No EEPROM in this computer.")
if assumeYes then break end
local answer = ask("Swap in another EEPROM and press Enter, or q to finish: ")
if not answer or answer:lower() == "q" then break end
end
return true
end

local function flashEeproms(payload, bios)
local images = readBioses(payload)
local code = images[bios.name]
if not code then return nil, "the " .. bios.name .. " BIOS is missing from the installer" end
say("Flashes the munix " .. bios.name .. " BIOS (" .. #code .. " bytes) onto EEPROMs, one after another:")
say("put an EEPROM in this computer, flash it, swap in the next.")
say(bare and "Put the kernal BIOS EEPROM back in when you're done."
or "Put this computer's own EEPROM back when you're done.")
local want = tonumber(options.count)
local count, last = 0, nil
while true do
local eeprom = currentEeprom()
if not eeprom then
say("No EEPROM in this computer.")
elseif eeprom.address == last then
say("That's the EEPROM that was just flashed -- swap in the next one.")
else
say("EEPROM " .. eeprom.address:sub(1, 8) .. " now holds " .. describeEeprom(eeprom, images) .. ".")
if confirm("Flash it as a munix " .. bios.name .. "?", true) then
local addr, err = flash(code, bios.label, "")
if addr then
count, last = count + 1, addr
say("Flashed " .. bios.name .. " EEPROM " .. count .. " (" .. addr:sub(1, 8) .. "): "
.. describeEeprom(eeprom, images) .. ", checked byte for byte.")
else
say("Couldn't flash it: " .. err)
end
else
say("Skipped -- not flashed.")
end
end
if want and count >= want then break end
if assumeYes and not want then break end
local answer = ask("Swap in the next EEPROM and press Enter, or q to finish: ")
if not answer or answer:lower() == "q" then break end
end
say(count .. " " .. bios.name .. " EEPROM(s) flashed.")
return true
end










local FLOPPY_SIZE = 512 * 1024

local function mountsOf(address)
if not osfs or not osfs.mounts then return "" end
local paths = {}
for proxy, path in osfs.mounts() do
if proxy.address == address and path ~= "/" then paths[#paths + 1] = path end
end
table.sort(paths)
return table.concat(paths, " ")
end

local function rootAddress()
if not osfs then return nil end
local fs = osfs.get("/")
return fs and fs.address
end

local function makeFloppy(payload)
if not INIT_LUA then return nil, "this installer wasn't built with the floppy's init.lua (run tools/build.lua)" end
local program = medium and readText(medium.fs, medium.path)
if not program then return nil, "can't read this installer's own file to copy it" end
local root = rootAddress()
local disks = {}
for _, d in ipairs(diskList(medium and medium.address)) do
if d.address ~= root then
d.total = d.fs.spaceTotal()
d.floppy = d.total <= FLOPPY_SIZE + 4096
d.where = mountsOf(d.address)
disks[#disks + 1] = d
end
end
table.sort(disks, function(a, b)
if a.floppy ~= b.floppy then return a.floppy end
return a.address < b.address
end)
local disk
if options.disk then
disk = chooseDisk(disks)
elseif #disks == 0 then
return nil, "no disk to write it to: put a floppy in a drive this computer can see"
else
page()
say("Disks (not this computer's own" .. (root and " OpenOS disk" or "") .. "):")
for i, d in ipairs(disks) do
say(string.format("  %d) %s  %s%s  %s, %s free%s", i, d.address:sub(1, 8),
d.label ~= "" and d.label or "(no label)", d.where ~= "" and "  " .. d.where or "",
human(d.total), human(d.free), d.floppy and "  <- floppy" or ""))
end
local only = #disks == 1 and disks[1].floppy
local pick = only and assumeYes and 1 or pickNumber("Write the installer floppy to which disk? ", #disks)
disk = pick and disks[pick]
end
if not disk then return nil, "no disk chosen" end
if not disk.floppy then
say("Disk " .. disk.address:sub(1, 8) .. " is " .. human(disk.total) .. " -- bigger than a floppy.")
if not confirm("Write the installer there anyway (it gets an /init.lua and boots into the installer)?") then
return nil, "nothing written"
end
end
local target = disk.fs
local files = {
{"/init.lua", #INIT_LUA},
{"/munix-installer.lua", #program},
{"/munix-installer.dat", DAT_SIZE or payload.fs.size(payload.path)},
}
local needed, freed = 0, 0
for _, f in ipairs(files) do
needed = needed + f[2]
if target.exists(f[1]) then freed = freed + target.size(f[1]) end
end
if disk.free + freed < needed then
return nil, "the disk has " .. human(disk.free + freed) .. " free (counting the installer files already on it) "
.. "and the installer needs " .. human(needed) .. ": delete something from it first"
end
for _, f in ipairs(files) do target.remove(f[1]) end
say("Writing the installer to " .. disk.address:sub(1, 8) .. "...")
writeText(target, "/init.lua", INIT_LUA)
writeText(target, "/munix-installer.lua", program)
local from = assert(payload.fs.open(payload.path, "r"))
local to = assert(target.open("/munix-installer.dat", "w"))
while true do
local data = payload.fs.read(from, CHUNK)
if not data then break end
local ok, err = target.write(to, data)
if not ok then
payload.fs.close(from)
target.close(to)
return nil, "writing munix-installer.dat failed: " .. tostring(err)
end
breathe()
end
payload.fs.close(from)
target.close(to)
if readText(target, "/init.lua") ~= INIT_LUA or readText(target, "/munix-installer.lua") ~= program then
return nil, "the files didn't read back the same (is the disk full or read-only?)"
end
local check, err = bundledPayload(target, "/munix-installer.dat")
if not check then return nil, "munix-installer.dat didn't read back right: " .. tostring(err) end
say("Done: " .. disk.address:sub(1, 8) .. (disk.where ~= "" and " (" .. disk.where .. ")" or "")
.. " now boots into the munix installer, under the stock Lua BIOS or the munix kernal BIOS.")
return true
end





local function placementWarnings()
if bare or not medium or medium.address ~= rootAddress() then return end
say("Note: this installer is on this computer's own disk, not a floppy. To make the")
say("installer floppy, put a floppy in and choose 'make an installer floppy' (or run")
say("munix-installer.lua floppy).")
local ok, init = pcall(readText, medium.fs, "/init.lua")
if INIT_LUA and ok and init == INIT_LUA then
say("Warning: this disk's /init.lua is the installer floppy's, so this computer will")
say("boot into the munix installer instead of OpenOS. Reinstall OpenOS onto it (boot")
say("the OpenOS floppy and run `install`) or delete /init.lua and copy OpenOS's back.")
end
end

local MODES = {"kernal", "worker", "bios", "check", "floppy"}

local function run(mode, payload)
local ok, failure
if mode == "kernal" then
ok, failure = installKernal(payload)
if ok then
if options.reboot or (not assumeYes and confirm("Reboot into munix now?", bare)) then computer.shutdown(true) end
say("Reboot this computer to start munix. Workers boot from the network once flashed.")
if bare then say("(The EEPROM now boots the installed disk first; the floppy can stay in.)") end
end
elseif mode == "worker" then
ok, failure = flashEeproms(payload, BIOSES.worker)
elseif mode == "bios" then
ok, failure = flashEeproms(payload, BIOSES.kernal)
elseif mode == "floppy" then
ok, failure = makeFloppy(payload)
elseif mode == "check" then
ok, failure = checkEeproms(payload)
end
if not ok then say("error: " .. tostring(failure)) end
return ok
end

local function main()
local title = "munix " .. VERSION .. " installer"
.. (bare and " (booted from " .. tostring(medium and medium.address or "?"):sub(1, 8) .. ")" or "")
say(title)
local payload, err = findPayload()
if not payload then
say("error: " .. tostring(err))
return 1
end
placementWarnings()
local mode = positional[1]
if mode then
local known = false
for _, m in ipairs(MODES) do known = known or m == mode end
if not known then
say("usage: munix-installer.lua [kernal|worker|bios|check|floppy] [--disk=<address|label>] [--yes] [--count=<n>] [--reboot]")
return 1
end
return run(mode, payload) and 0 or 1
end


while true do
page()
say(title)
say("  1) install the kernal on this computer")
say("  2) flash worker EEPROMs")
say("  3) flash kernal BIOS EEPROMs (for computers that will boot this installer)")
say("  4) check which BIOS an EEPROM holds")
say("  5) make an installer floppy")
say(bare and "  6) quit (restarts the computer)" or "  6) quit")
local pick = pickNumber("> ", 6)
if not pick or pick == 6 then return 0 end
run(MODES[pick], payload)
if not ask("Press Enter to go back to the menu.") then return 0 end
end
end





local function crashDump(err)
local function try(f, ...) local ok, a, b = pcall(f, ...) if ok then return a, b end end
local d = {"munix installer crash dump (" .. VERSION .. ")", err, "",
"uptime " .. computer.uptime() .. "  memory " .. computer.freeMemory() .. "/" .. computer.totalMemory()
.. "  energy " .. computer.energy() .. "/" .. computer.maxEnergy()}
local tmp, disk = computer.tmpAddress and computer.tmpAddress()
if medium and not try(medium.fs.isReadOnly) then disk = medium.fs end
for address, kind in component.list() do
local line = address .. " " .. kind
if kind == "filesystem" then
local fs = component.proxy(address)
line = line .. ' "' .. tostring(try(fs.getLabel)) .. '" ro=' .. tostring(try(fs.isReadOnly)) .. " "
.. tostring(try(fs.spaceUsed)) .. "/" .. tostring(try(fs.spaceTotal)) .. ": "
.. table.concat(try(fs.list, "/") or {}, " ")
if not disk and address ~= tmp and try(fs.isReadOnly) == false then disk = fs end
end
d[#d + 1] = line
end
local handle = disk and try(disk.open, "/munix-boot-dump.txt", "w")
if not handle then return nil end
try(disk.write, handle, table.concat(d, "\n") .. "\n")
try(disk.close, handle)
return disk.address:sub(1, 8) .. "/munix-boot-dump.txt"
end



if bare then
local ok, err = xpcall(main, debug.traceback)
if not ok then
say("error: " .. tostring(err))
local where = crashDump(tostring(err))
if where then say("Dump: " .. where) end
ask("Press Enter to restart.")
end
computer.shutdown(true)
end
return main()
