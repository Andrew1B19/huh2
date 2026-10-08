-- End-to-end test of the installer: builds it with tools/build.lua (and
-- checks dist/ isn't stale), runs it -- under plain Lua, with OpenOS's
-- component/computer/filesystem played by the emulator's own components
-- -- to install the kernal onto an emulated disk and flash the kernal's
-- and three workers' EEPROMs, then boots the emulator from exactly what
-- it installed and flashed.
--
--   lua5.3 test/emu/install_test.lua
local REPO_ROOT = (arg and arg[0] and arg[0]:match("^(.*)/test/emu/install_test%.lua$")) or "."
local Emulator = dofile(REPO_ROOT .. "/test/emu/emulator.lua")

local function readFile(path)
  local f = assert(io.open(path, "rb"))
  local data = f:read("a")
  f:close()
  return data
end

local TMP = os.tmpname()
os.remove(TMP)
os.execute('mkdir -p "' .. TMP .. '"')
local BUNDLE, DATA = TMP .. "/muxos-installer.lua", TMP .. "/muxos-installer.dat"

print("install 1: the build is clean, deterministic, and dist/ is up to date")
assert(os.execute('lua5.3 "' .. REPO_ROOT .. '/tools/build.lua" --out "' .. BUNDLE .. '" >/dev/null'),
  "tools/build.lua failed")
assert(readFile(BUNDLE) == readFile(REPO_ROOT .. "/dist/muxos-installer.lua")
  and readFile(DATA) == readFile(REPO_ROOT .. "/dist/muxos-installer.dat"),
  "dist/ is stale: run lua5.3 tools/build.lua")
print("  OK")

local emu = Emulator.new()
emu.timeout = 1

-- OpenOS's component/computer/filesystem for an installer running on
-- `node`, backed by the node's emulated components. `eepromOf()`, when
-- given, names the EEPROM currently in the computer (swapped by hand).
local function openosFor(node, medium, eepromOf)
  local function proxy(addr)
    local c = node.components[addr]
    if not c then return nil end
    local p = {address = addr, type = c.type}
    for name, fn in pairs(c.methods) do p[name] = fn end
    return p
  end
  local component = {
    list = function(kind)
      local list = {}
      if kind == "eeprom" and eepromOf then
        list[1] = eepromOf()
      else
        for _, addr in ipairs(node.componentOrder) do
          if node.components[addr].type == kind then list[#list + 1] = addr end
        end
      end
      local i = 0
      return function() i = i + 1 return list[i] end
    end,
    proxy = function(addr)
      if eepromOf and addr == eepromOf() then return eepromOf(true) end
      return proxy(addr)
    end,
  }
  local computer = {tmpAddress = function() return nil end, shutdown = function() error("shutdown called") end}
  -- The installer's own disk: the host's files, mounted at "/".
  local handles, nextHandle = {}, 1
  local mediumFs = {
    address = medium,
    open = function(path)
      local f = io.open(path, "rb")
      if not f then return nil, path end
      handles[nextHandle], nextHandle = f, nextHandle + 1
      return nextHandle - 1
    end,
    read = function(h, n) return handles[h]:read(math.min(n, 2048)) end,
    close = function(h) handles[h]:close() handles[h] = nil end,
  }
  local filesystem = {
    exists = function(p) local f = io.open(p, "rb") if f then f:close() return true end return false end,
    isDirectory = function() return false end,
    get = function() return mediumFs, "/" end,
  }
  local shell = {resolve = function(p) return p end}
  return {component = component, computer = computer, filesystem = filesystem, shell = shell}
end

-- Runs an installer file with arguments; `answers` feed io.read (a
-- function answer is called and its result used). Returns the exit
-- code and everything it printed.
local function runInstaller(path, openos, answers, ...)
  local out = {}
  local env = setmetatable({}, {__index = _G})
  env.require = function(name) return assert(openos[name], "installer required " .. name) end
  env.os = setmetatable({sleep = function() end}, {__index = os}) -- OpenOS's os.sleep
  env.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    out[#out + 1] = table.concat(parts, "\t") .. "\n"
  end
  env.io = setmetatable({
    write = function(...) for i = 1, select("#", ...) do out[#out + 1] = tostring((select(i, ...))) end end,
    read = function()
      local a = table.remove(answers or {}, 1)
      if type(a) == "function" then a = a() end
      out[#out + 1] = tostring(a) .. "\n"
      return a
    end,
  }, {__index = io})
  local chunk = assert(loadfile(path, "t", env))
  local code = chunk(...)
  return code, table.concat(out)
end

-- --- The kernal computer: OpenOS boots it off the installer's floppy;
-- its hard disk holds an older muxos. ---
local kernal = emu:newNode("kernal")
emu:addModem(kernal)
local _, screenAddr, screenBuffers = emu:addGpuScreen(kernal, 50, 30)
local disk = {["/.muxos-version"] = "0.0.9\n", ["/muxos.lua"] = "-- an old muxos", ["/home/keep.txt"] = "mine"}
local diskAddr = emu:addFilesystem(kernal, disk)
local medium = emu:addFilesystem(kernal, {})
local kernalEeprom = emu:addEeprom(kernal, "-- the OpenOS BIOS")
local kernalOs = openosFor(kernal, medium)
local diskMethods = kernal.components[diskAddr].methods

print("install 2: a disk too small, or a write failing midway, changes nothing")
do
  local realTotal = diskMethods.spaceTotal
  diskMethods.spaceTotal = function() return 100000 end
  local code, out = runInstaller(BUNDLE, kernalOs, nil, "kernal", "--yes")
  diskMethods.spaceTotal = realTotal
  assert(code == 1 and out:find("not enough space", 1, true), "a full disk is refused up front:\n" .. out)

  local realWrite, writes = diskMethods.write, 0
  diskMethods.write = function(...)
    writes = writes + 1
    if writes > 20 then return nil, "not enough space" end
    return realWrite(...)
  end
  code, out = runInstaller(BUNDLE, kernalOs, nil, "kernal", "--yes")
  diskMethods.write = realWrite
  assert(code == 1 and out:find("nothing was changed", 1, true), "a failed write is reported:\n" .. out)
  for path in pairs(disk) do assert(not path:match("%.new$"), "left a staged file behind: " .. path) end
  assert(disk["/muxos.lua"] == "-- an old muxos" and disk["/.muxos-version"] == "0.0.9\n", "the old install was touched")
  assert(kernal.components[kernalEeprom].methods.get() == "-- the OpenOS BIOS", "the EEPROM was flashed anyway")
end
print("  OK")

print("install 3: the single-file installer upgrades the kernal's disk and flashes its EEPROM")
do
  local code, out = runInstaller(BUNDLE, kernalOs, nil, "kernal", "--yes")
  assert(code == 0, "kernal install failed:\n" .. out)
  assert(out:find("Upgrading muxos 0.0.9 to 0.1.2", 1, true), "it noticed the old version:\n" .. out)
  assert(out:find("warning", 1, true) == nil, "no hardware warnings on a complete kernal:\n" .. out)
  assert(disk["/muxos.lua"] == readFile(REPO_ROOT .. "/kernal/muxos.lua"), "muxos.lua installed")
  assert(disk["/runtime.lua"] == readFile(REPO_ROOT .. "/node/runtime.lua"), "runtime.lua installed")
  assert(disk["/lib/core/full_text.lua"] == readFile(REPO_ROOT .. "/kernal/lib/core/full_text.lua"), "libraries installed")
  assert(disk["/.muxos-version"] == "0.1.2\n" and disk["/home/keep.txt"] == "mine", "version recorded, user files kept")
  assert(not disk["/eeprom/kernal.lua"], "BIOS images aren't disk files")
  assert(disk["/bin/opm.mxe"] == readFile(REPO_ROOT .. "/opm/opm.mxe")
    and disk["/lib/mxe/opm_core.lua"] == readFile(REPO_ROOT .. "/opm/opm_core.lua"), "opm ships with muxos")
  for path in pairs(disk) do assert(not path:match("%.new$"), "left a staged file behind: " .. path) end
  local eeprom = kernal.components[kernalEeprom].methods
  assert(eeprom.get() == readFile(REPO_ROOT .. "/kernal/bios.lua") and eeprom.getData() == diskAddr,
    "the kernal BIOS was flashed and points at the disk")
end
print("  OK")

print("install 4: without its data file next to it, the installer says so")
do
  local alone = TMP .. "/alone"
  os.execute('mkdir -p "' .. alone .. '"')
  local f = assert(io.open(alone .. "/muxos-installer.lua", "wb"))
  f:write(readFile(BUNDLE))
  f:close()
  local code, out = runInstaller(alone .. "/muxos-installer.lua", openosFor(emu:newNode("alone"), nil), nil, "worker")
  assert(code == 1 and out:find("can't find muxos-installer.dat", 1, true)
    and out:find(alone .. "/muxos-installer.dat: not there", 1, true), "a missing data file is explained:\n" .. out)
  -- A data file from another version is named as such, not used.
  local f = assert(io.open(alone .. "/muxos-installer.dat", "wb"))
  f:write((readFile(DATA):gsub("^(%-%-%[%[MUXOS%-PAYLOAD )%S+", "%10.0.1")))
  f:close()
  code, out = runInstaller(alone .. "/muxos-installer.lua", openosFor(emu:newNode("alone"), nil), nil, "worker")
  assert(code == 1 and out:find("data file for muxos 0.0.1, but this installer is 0.1.2", 1, true),
    "a mismatched data file is explained:\n" .. out)
  -- One that isn't next to the program is found on any disk's root.
  local other = emu:newNode("alone")
  emu:addEeprom(other, "")
  emu:addFilesystem(other, {["/muxos-installer.dat"] = readFile(DATA)})
  code, out = runInstaller(alone .. "/muxos-installer.lua", openosFor(other, nil), {""}, "check")
  assert(code == 0 and out:find("blank", 1, true), "the data file on another disk was found:\n" .. out)
  -- An empty or cut-short one (a copy onto a full floppy) says how big it
  -- is, how big it should be, and how full the disk is.
  local data = readFile(DATA)
  for _, broken in ipairs({"", data:sub(1, 4096)}) do
    local cut = emu:newNode("alone")
    emu:addFilesystem(cut, {["/muxos-installer.dat"] = broken})
    code, out = runInstaller(alone .. "/muxos-installer.lua", openosFor(cut, nil), nil, "worker")
    assert(code == 1 and out:find("it's " .. #broken .. " bytes, should be " .. #data, 1, true)
      and out:find("free of", 1, true) and out:find("the copy didn't finish", 1, true),
      "a cut-short data file is explained:\n" .. out)
    assert(broken ~= "" or out:find("it's there, but empty", 1, true), "an empty data file is called empty:\n" .. out)
  end
end
print("  OK")

print("install 5: worker EEPROMs are flashed one after another, swapped by hand")
local workers = {}
for i = 1, 3 do
  local w = emu:newNode("worker")
  local modem = emu:addModem(w)
  workers[i] = {node = w, modem = modem, eeprom = emu:addEeprom(w, "-- blank")}
end
do
  local current = 1
  local function eepromOf(asProxy)
    local w = workers[current]
    if not asProxy then return w.eeprom end
    local p = {address = w.eeprom, type = "eeprom"}
    for name, fn in pairs(w.node.components[w.eeprom].methods) do p[name] = fn end
    return p
  end
  local function swap() current = current + 1 return "" end
  local code, out = runInstaller(BUNDLE, openosFor(kernal, medium, eepromOf),
    {"y", swap, "y", "", "y", swap, "y", "q"}, "worker")
  assert(code == 0, "worker flashing failed:\n" .. out)
  assert(out:find("That's the EEPROM that was just flashed", 1, true), "re-flashing the same EEPROM is caught:\n" .. out)
  assert(out:find("3 worker EEPROM(s) flashed.", 1, true), out)
  for i, w in ipairs(workers) do
    assert(w.node.components[w.eeprom].methods.get() == readFile(REPO_ROOT .. "/node/bios.lua"),
      "worker " .. i .. " wasn't flashed")
  end
end
print("  OK")

print("install 5b: a kernal BIOS EEPROM, for an empty computer to boot the installer floppy with")
do
  local spare = emu:newNode("spare")
  local spareEeprom = emu:addEeprom(spare, "") -- as crafted: empty
  local function eepromOf(asProxy)
    if not asProxy then return spareEeprom end
    local p = {address = spareEeprom, type = "eeprom"}
    for name, fn in pairs(spare.components[spareEeprom].methods) do p[name] = fn end
    return p
  end
  local os_ = openosFor(kernal, medium, eepromOf)
  local code, out = runInstaller(BUNDLE, os_, {"q"}, "check")
  assert(code == 0 and out:find("blank -- nothing on it", 1, true), "check calls a new EEPROM blank:\n" .. out)
  -- Enter alone flashes: you put the EEPROM in to flash it.
  code, out = runInstaller(BUNDLE, os_, {"", "q"}, "bios")
  assert(code == 0 and out:find("1 kernal EEPROM(s) flashed.", 1, true), "kernal BIOS flashing:\n" .. out)
  assert(out:find("now holds blank", 1, true) and out:find("the muxos kernal BIOS, this version", 1, true)
    and out:find("checked byte for byte", 1, true), "it says what the EEPROM held before and after:\n" .. out)
  assert(spare.components[spareEeprom].methods.get() == readFile(REPO_ROOT .. "/kernal/bios.lua"), "it holds the kernal BIOS")
  code, out = runInstaller(BUNDLE, os_, {"q"}, "check")
  assert(out:find("the muxos kernal BIOS, this version", 1, true), "check recognizes it:\n" .. out)
  code, out = runInstaller(BUNDLE, os_, {"n", "q"}, "worker")
  assert(out:find("Skipped -- not flashed.", 1, true) and out:find("0 worker EEPROM(s) flashed.", 1, true),
    "answering no says so:\n" .. out)
end
print("  OK")

print("install 6: the installed system boots: kernal from its disk, workers from the network")
do
  -- The installer's floppy comes out; OpenOS's BIOS is gone.
  kernal.components[medium] = nil
  for i, addr in ipairs(kernal.componentOrder) do
    if addr == medium then table.remove(kernal.componentOrder, i) break end
  end
  emu:boot(kernal)
  assert(kernal.status == "running", "the kernal didn't boot from its disk")
  for _, w in ipairs(workers) do
    emu:boot(w.node)
    assert(w.node.status == "running", "a worker didn't boot")
  end
  emu:advance(4)
  local function screen()
    local rows = {}
    for y = 1, screenBuffers[0].h do
      local row, chars = screenBuffers[0].cells[y] or {}, {}
      for x = 1, screenBuffers[0].w do chars[x] = (row[x] and row[x].char) or " " end
      rows[#rows + 1] = table.concat(chars)
    end
    return table.concat(rows):gsub("%s+", " ")
  end
  local function typeLine(text)
    for i = 1, #text do
      emu:injectSignal(kernal, "key_down", screenAddr, text:byte(i), 0, "tester")
      emu:step()
    end
    emu:injectSignal(kernal, "key_down", screenAddr, 13, 0x1C, "tester")
    emu:step()
  end
  typeLine("nodes")
  emu:advance(1)
  for _, w in ipairs(workers) do
    assert(screen():find(w.modem, 1, true), "worker " .. w.modem .. " isn't listed:\n" .. screen())
  end
  typeLine("run return 6 * 7")
  emu:advance(2)
  assert(screen():find("42", 1, true), "a job didn't run:\n" .. screen())
end
print("  OK")

print("install 7: the catalog entries put the installer at a floppy's root, and opm where muxos looks")
do
  local core = dofile(REPO_ROOT .. "/opm/opm_core.lua")
  local text = readFile(REPO_ROOT .. "/dist/programs.cfg"):gsub("^%-%-[^\n]*\n", ""):gsub("\n%-%-[^\n]*", "")
  local cfg = assert(core.parse_cfg(text))
  local function concat(...) return (table.concat({...}, "/"):gsub("//+", "/")) end
  local target = core.resolve_target("abc")
  local plan = core.file_plan(cfg, core.order(cfg, "muxos-installer"), target, concat)
  local files = {}
  for _, p in ipairs(plan) do files[p.file] = p.path end
  assert(#plan == 2 and files["/mnt/abc/muxos-installer.lua"] == "muxos/dist/muxos-installer.lua"
    and files["/mnt/abc/muxos-installer.dat"] == "muxos/dist/muxos-installer.dat",
    "the installer and its data file land at the floppy's root, where the BIOS looks")
  assert(not cfg["muxos-installer"].launcher, "no launcher: a /muxos.lua on the floppy would be booted as the kernal")
  local selfPlan = core.file_plan(cfg, core.order(cfg, "opm-mxe"), "/", concat)
  local dests = {}
  for _, p in ipairs(selfPlan) do dests[p.file] = p.path end
  assert(dests["/bin/opm.mxe"] == "muxos/opm/opm.mxe" and dests["/lib/mxe/opm_core.lua"] == "muxos/opm/opm_core.lua",
    "opm-mxe updates the copy muxos ships")
end
print("  OK")

print("install 8: a CRLF checkout (git core.autocrlf) builds the same installer; a converted installer says so")
do
  local copy = TMP .. "/crlf"
  assert(os.execute('mkdir -p "' .. copy .. '" && cd "' .. REPO_ROOT .. '" && tar cf - kernal node installer tools opm | tar xf - -C "' .. copy .. '"'))
  -- Every text file to CRLF, as a converting checkout would.
  -- (Only "\n" becomes "\r\n", like git; a last line without one stays as is.)
  assert(os.execute('find "' .. copy .. '" -type f -exec perl -pi -e "s/\\n/\\r\\n/" {} +'))
  local out = TMP .. "/crlf/out/muxos-installer.lua"
  assert(os.execute('lua5.3 "' .. copy .. '/tools/build.lua" --out "' .. out .. '" >/dev/null'), "the build fails on a CRLF checkout")
  assert(readFile(out) == readFile(BUNDLE) and readFile(out:gsub("lua$", "dat")) == readFile(DATA),
    "a CRLF checkout builds a different installer")

  local converted = TMP .. "/converted/muxos-installer.lua"
  os.execute('mkdir -p "' .. TMP .. '/converted"')
  for _, pair in ipairs({{converted, BUNDLE}, {converted:gsub("lua$", "dat"), DATA}}) do
    local f = assert(io.open(pair[1], "wb"))
    f:write((readFile(pair[2]):gsub("\n", "\r\n")))
    f:close()
  end
  local node = emu:newNode("crlf")
  local code, outText = runInstaller(converted, openosFor(node, nil), nil, "kernal", "--yes")
  assert(code == 1 and outText:find("line endings converted to CRLF", 1, true),
    "a CRLF-converted installer explains itself:\n" .. outText)
end
print("  OK")

print("install 9: an empty computer boots the installer floppy with the kernal BIOS -- no OpenOS -- and installs")
do
  local node = emu:newNode("bare")
  emu:addModem(node)
  local _, screen, bufs = emu:addGpuScreen(node, 80, 25)
  local hdd = {}
  local hddAddr = emu:addFilesystem(node, hdd)
  emu:addFilesystem(node, {["/muxos-installer.lua"] = readFile(BUNDLE), ["/muxos-installer.dat"] = readFile(DATA)})
  local eeprom = emu:addEeprom(node, readFile(REPO_ROOT .. "/kernal/bios.lua"))
  local function screenText()
    local rows = {}
    for y = 1, bufs[0].h do
      local row, chars = bufs[0].cells[y] or {}, {}
      for x = 1, bufs[0].w do chars[x] = (row[x] and row[x].char) or " " end
      rows[#rows + 1] = table.concat(chars)
    end
    return table.concat(rows, "\n")
  end
  local function typeLine(text)
    for i = 1, #text do
      emu:injectSignal(node, "key_down", screen, text:byte(i), 0, "tester")
      emu:step()
    end
    emu:injectSignal(node, "key_down", screen, 13, 0x1C, "tester")
    emu:advance(1)
  end
  emu:boot(node)
  emu:advance(2)
  assert(screenText():find("muxos 0.1.2 installer (booted from", 1, true), "the BIOS booted the installer:\n" .. screenText())
  typeLine("1")
  assert(screenText():find("Install muxos on which disk?", 1, true), "it offers the hard disk:\n" .. screenText())
  typeLine("1")
  typeLine("y")
  emu:advance(5)
  assert(screenText():find("muxos 0.1.2 is installed.", 1, true), "it installed:\n" .. screenText())
  assert(hdd["/muxos.lua"] == readFile(REPO_ROOT .. "/kernal/muxos.lua") and hdd["/bin/opm.mxe"], "the files are on the hard disk")
  assert(node.components[eeprom].methods.getData() == hddAddr, "the EEPROM boots the hard disk now")
  typeLine("y")
  assert(node.status == "dead", "it rebooted")

  -- The floppy is still in: the installed system boots first.
  emu:boot(node)
  emu:advance(3)
  assert(screenText():find("muxos> _", 1, true), "muxos booted from the hard disk:\n" .. screenText())
end
print("  OK")

os.execute('rm -rf "' .. TMP .. '"')
print("ALL OK")
