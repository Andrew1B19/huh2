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
  and readFile(DATA) == readFile(REPO_ROOT .. "/dist/muxos-installer.dat")
  and readFile(TMP .. "/floppy/init.lua") == readFile(REPO_ROOT .. "/dist/floppy/init.lua"),
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
  assert(#plan == 3 and files["/mnt/abc/muxos-installer.lua"] == "muxos/dist/muxos-installer.lua"
    and files["/mnt/abc/muxos-installer.dat"] == "muxos/dist/muxos-installer.dat"
    and files["/mnt/abc/init.lua"] == "muxos/dist/floppy/init.lua",
    "the installer, its data file and the boot file land at the floppy's root, where the BIOS looks")
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

print("install 10: a kernal BIOS that can't boot says why (screen, Analyzer, and a dump)")
do
  local function crash(files)
    local node = emu:newNode("bare")
    local _, _, bufs = emu:addGpuScreen(node, 100, 25)
    if files then emu:addFilesystem(node, files) end
    emu:addEeprom(node, readFile(REPO_ROOT .. "/kernal/bios.lua"))
    local mark = #emu.log
    emu:boot(node)
    emu:advance(8) -- it waits 5 s for a late floppy first
    assert(node.status == "dead", "the BIOS stopped")
    local rows = {}
    for y = 1, bufs[0].h do
      local row, chars = bufs[0].cells[y] or {}, {}
      for x = 1, bufs[0].w do chars[x] = (row[x] and row[x].char) or " " end
      rows[#rows + 1] = table.concat(chars)
    end
    for i = mark + 1, #emu.log do
      if emu.log[i].node == node.address and emu.log[i].msg:find("^halted") then
        return emu.log[i].msg, table.concat(rows, "\n")
      end
    end
    error("no crash logged")
  end
  local why, screen = crash(nil)
  assert(why:find("muxos: no system; looking for the installer floppy...", 1, true)
    and why:find("Nothing to boot. Disks this computer can see, and their files:", 1, true)
    and why:find("Put the installer floppy", 1, true), why)
  assert(screen:find("Nothing to boot. Disks this computer can see, and their files:", 1, true),
    "shown on the screen:\n" .. screen)
  local files = {["/muxos-installer.lua"] = "this is not lua (", ["/notes.txt"] = "hi"}
  why, screen = crash(files)
  -- A dump for debugging, on the disk: the error, the machine, every
  -- component, and each disk's root listing.
  local dump = files["/muxos-boot-dump.txt"] or ""
  assert(dump:find("muxos BIOS dump", 1, true) and dump:find("syntax error", 1, true)
    and dump:find("memory %d+/%d+") and dump:find(" eeprom") and dump:find(" gpu")
    and dump:find("filesystem \"[^\n]*: muxos%-installer%.lua notes%.txt"), "the dump:\n" .. dump)
  assert(screen:find("Dump: filesyst/muxos-boot-dump.txt", 1, true), "the dump is named on the screen:\n" .. screen)
  assert(screen:find('": muxos-installer.lua notes.txt', 1, true), "each disk's files are on the screen:\n" .. screen)
  assert(why:find("filesyst/muxos-installer.lua: ", 1, true), why)
  assert(screen:find("filesyst/muxos-installer.lua: ", 1, true), "the load error is on the screen:\n" .. screen)
  -- An installer that can't even start crashes the machine with its error
  -- (OpenComputers' crash screen shows it); the BIOS doesn't wrap it.
  why = crash({["/muxos-installer.lua"] = "error('broken on purpose')"})
  assert(why:find("/muxos-installer.lua:1: broken on purpose", 1, true), why)
end
print("  OK")

print("install 11: the kernal BIOS boots the floppy even where `exists` says no (it opens, like the stock BIOS)")
do
  local node = emu:newNode("bare")
  local _, _, bufs = emu:addGpuScreen(node, 80, 25)
  local floppy = emu:addFilesystem(node, {["/muxos-installer.lua"] = readFile(BUNDLE), ["/muxos-installer.dat"] = readFile(DATA)})
  node.components[floppy].methods.exists = function() return false end
  emu:addEeprom(node, readFile(REPO_ROOT .. "/kernal/bios.lua"))
  emu:boot(node)
  emu:advance(2)
  local row, chars = bufs[0].cells[1] or {}, {}
  for x = 1, 80 do chars[x] = (row[x] and row[x].char) or " " end
  assert(table.concat(chars):find("muxos 0.1.2 installer (booted from", 1, true), "it booted the installer: " .. table.concat(chars))
end
print("  OK")

print("install 11b: on a small screen, wrong keys ask again, each question starts at the top, and actions return to the menu")
do
  local node = emu:newNode("bare")
  local _, screen, bufs = emu:addGpuScreen(node, 50, 16) -- a tier 1 screen
  for _ = 1, 4 do emu:addFilesystem(node, {}, nil, 4194304) end
  emu:addFilesystem(node, {["/muxos-installer.lua"] = readFile(BUNDLE), ["/muxos-installer.dat"] = readFile(DATA)}, "floppy", 512 * 1024)
  emu:addEeprom(node, readFile(REPO_ROOT .. "/kernal/bios.lua"))
  local function text()
    local rows = {}
    for y = 1, bufs[0].h do
      local row, chars = bufs[0].cells[y] or {}, {}
      for x = 1, bufs[0].w do chars[x] = (row[x] and row[x].char) or " " end
      rows[#rows + 1] = table.concat(chars)
    end
    return table.concat(rows, "\n")
  end
  local function answer(line)
    for i = 1, #line do
      emu:injectSignal(node, "key_down", screen, line:byte(i), 0, "tester")
      emu:advance(0.02)
    end
    emu:injectSignal(node, "key_down", screen, 13, 0x1C, "tester")
    emu:advance(0.5)
  end
  emu:boot(node)
  emu:advance(3)
  answer("x")
  answer("9")
  assert(node.status == "running" and text():find("Type a number from 1 to 6, or q to cancel.", 1, true),
    "a wrong menu key asks again:\n" .. text())
  answer("4")
  answer("q")
  assert(text():find("Press Enter to go back to the menu.", 1, true), "check mode finished:\n" .. text())
  answer("")
  assert(text():find("^muxos 0.1.2 installer") and text():find("6) quit (restarts the computer)", 1, true),
    "back at the menu, on a fresh screen:\n" .. text())
  answer("1")
  local t = text()
  assert(t:find("^Disks:") and t:find("Install muxos on which disk?", 1, true), "the disk question starts at the top:\n" .. t)
  answer("z")
  assert(text():find("Type a number from 1 to 4, or q to cancel.", 1, true), "a wrong disk answer asks again:\n" .. text())
  answer("q")
  assert(text():find("error: no disk chosen", 1, true) and text():find("Press Enter to go back to the menu.", 1, true),
    "q cancels back toward the menu:\n" .. text())
  answer("")
  answer("6")
  assert(node.status == "dead", "quit restarts the computer")
end
print("  OK")

print("install 12: the installer handles its own crash: error and traceback on its console, a dump on the floppy")
do
  local node = emu:newNode("bare")
  local _, screen, bufs = emu:addGpuScreen(node, 100, 30)
  local floppyFiles = {["/muxos-installer.lua"] = readFile(BUNDLE), ["/muxos-installer.dat"] = readFile(DATA)}
  emu:addFilesystem(node, floppyFiles, "floppy", 512 * 1024)
  local eeprom = emu:addEeprom(node, readFile(REPO_ROOT .. "/kernal/bios.lua"))
  emu:boot(node)
  emu:advance(2)
  node.components[eeprom].methods.get = function() error("EEPROM on fire") end
  emu:injectSignal(node, "key_down", screen, string.byte("2"), 0, "tester")
  emu:step()
  emu:injectSignal(node, "key_down", screen, 13, 0x1C, "tester")
  emu:advance(2)
  local rows = {}
  for y = 1, bufs[0].h do
    local row, chars = bufs[0].cells[y] or {}, {}
    for x = 1, bufs[0].w do chars[x] = (row[x] and row[x].char) or " " end
    rows[#rows + 1] = table.concat(chars)
  end
  local text = table.concat(rows, "\n")
  assert(text:find("error: ", 1, true) and text:find("EEPROM on fire", 1, true) and text:find("stack traceback", 1, true)
    and text:find("Dump: floppy%-%d*/muxos%-boot%-dump%.txt") and text:find("Press Enter to restart.", 1, true),
    "the crash is on the installer's console:\n" .. text)
  local dump = floppyFiles["/muxos-boot-dump.txt"] or ""
  assert(dump:find("muxos installer crash dump (0.1.2)", 1, true) and dump:find("EEPROM on fire", 1, true)
    and dump:find("stack traceback", 1, true) and dump:find("memory %d+/%d+")
    and dump:find("filesystem \"[^\n]*: muxos%-installer%.dat muxos%-installer%.lua"), "the dump:\n" .. dump)
end
print("  OK")

print("install 13: the kernal BIOS waits for a floppy whose drive attaches just after power-on (a rack's)")
do
  local node = emu:newNode("bare")
  local _, _, bufs = emu:addGpuScreen(node, 80, 25)
  emu:addFilesystem(node, {}) -- the node's own empty disk
  emu:addEeprom(node, readFile(REPO_ROOT .. "/kernal/bios.lua"))
  emu:boot(node)
  emu:advance(2)
  assert(node.status == "running", "still waiting, not crashed")
  local floppy = emu:addFilesystem(node, {["/muxos-installer.lua"] = readFile(BUNDLE), ["/muxos-installer.dat"] = readFile(DATA)})
  emu:injectSignal(node, "component_added", floppy, "filesystem")
  emu:advance(2)
  local row, chars = bufs[0].cells[1] or {}, {}
  for x = 1, 80 do chars[x] = (row[x] and row[x].char) or " " end
  assert(table.concat(chars):find("muxos 0.1.2 installer (booted from", 1, true), "it booted the late floppy: " .. table.concat(chars))
end
print("  OK")

print("install 14: workers waiting for a kernal don't flood the network (they used to set each other off)")
do
  local storm = Emulator.new()
  local count = 0
  local workers = {}
  for i = 1, 3 do
    local w = storm:newNode("worker")
    local m = w.components[storm:addModem(w)].methods
    local real = m.broadcast
    m.broadcast = function(...) count = count + 1 return real(...) end
    storm:addEeprom(w, readFile(REPO_ROOT .. "/node/bios.lua"))
    workers[i] = w
  end
  local listener = storm:newNode("kernal")
  storm:addModem(listener)
  for _, w in ipairs(workers) do storm:boot(w) end
  local steps, deadline = 0, storm.now + 10
  while storm.now < deadline and steps < 5000 do
    if not storm:step() then break end
    steps = steps + 1
  end
  assert(storm.now >= deadline and count <= 9,
    count .. " broadcasts in " .. storm.now .. " simulated s: the workers are flooding the network")
end
print("  OK")

print("install 15: `update` in muxos installs a new version from the installer floppy, BIOS included")
do
  -- The payload's files, and a way to write a modified payload back out.
  local function parsePayload(data)
    local files, pos = {}, data:find("@@ ", 1, true)
    while true do
      local size, path, at = data:match("^@@ (%d+) ([^\n]+)\n()", pos)
      if not size then break end
      files[#files + 1] = {path = path, data = data:sub(at, at + tonumber(size) - 1)}
      pos = at + tonumber(size) + 1
    end
    return files
  end
  local function writePayload(version, files)
    local out = {"--[[MUXOS-PAYLOAD " .. version .. "\n", "@@MANIFEST " .. #files .. "\n"}
    for _, f in ipairs(files) do out[#out + 1] = #f.data .. " " .. f.path .. "\n" end
    for _, f in ipairs(files) do out[#out + 1] = "@@ " .. #f.data .. " " .. f.path .. "\n" .. f.data .. "\n" end
    out[#out + 1] = "@@END\n"
    return table.concat(out)
  end
  local current = parsePayload(readFile(DATA))
  -- An installed kernal, as the installer leaves it.
  local disk = {["/.muxos-version"] = "0.1.1\n"}
  local kernalBios
  for _, f in ipairs(current) do
    if f.path == "/eeprom/kernal.lua" then kernalBios = f.data
    elseif not f.path:match("^/eeprom/") then disk[f.path] = f.data end
  end
  -- The new version: one more program, and a changed kernal BIOS.
  local newBios = kernalBios .. "-- the next version\n"
  local newer = {}
  for _, f in ipairs(current) do
    newer[#newer + 1] = {path = f.path, data = f.path == "/eeprom/kernal.lua" and newBios or f.data}
  end
  newer[#newer + 1] = {path = "/bin/newprog.lua", data = 'print("new")'}
  local floppyFiles = {["/muxos-installer.dat"] = writePayload("0.1.3", newer)}

  local node = emu:newNode("kernal")
  emu:addModem(node)
  local _, screen, bufs = emu:addGpuScreen(node, 80, 25)
  local diskAddr = emu:addFilesystem(node, disk)
  local floppy = emu:addFilesystem(node, floppyFiles, "floppy", 512 * 1024)
  local eeprom = emu:addEeprom(node, kernalBios, diskAddr)
  local function text()
    local rows = {}
    for y = 1, bufs[0].h do
      local row, chars = bufs[0].cells[y] or {}, {}
      for x = 1, bufs[0].w do chars[x] = (row[x] and row[x].char) or " " end
      rows[#rows + 1] = table.concat(chars)
    end
    return table.concat(rows, "\n")
  end
  local function typeLine(line)
    for i = 1, #line do
      emu:injectSignal(node, "key_down", screen, line:byte(i), 0, "tester")
      emu:step()
    end
    emu:injectSignal(node, "key_down", screen, 13, 0x1C, "tester")
    emu:advance(3)
  end
  emu:boot(node)
  emu:advance(3)
  assert(text():find("muxos> _", 1, true), "muxos booted:\n" .. text())

  -- A damaged data file changes nothing.
  local good = floppyFiles["/muxos-installer.dat"]
  floppyFiles["/muxos-installer.dat"] = good:sub(1, #good // 2)
  typeLine("update")
  assert(text():find("nothing was changed", 1, true), "a damaged data file is refused:\n" .. text())
  assert(not disk["/bin/newprog.lua"] and disk["/.muxos-version"] == "0.1.1\n", "nothing changed")
  floppyFiles["/muxos-installer.dat"] = good

  typeLine("update")
  assert(text():find("update: muxos 0.1.3 installed", 1, true) and text():find("the kernal BIOS was re-flashed", 1, true),
    "update reports what it did:\n" .. text())
  assert(disk["/bin/newprog.lua"] == 'print("new")' and disk["/.muxos-version"] == "0.1.3\n", "the new files are installed")
  for path in pairs(disk) do assert(not path:match("%.new$"), "left a staged file behind: " .. path) end
  local em = node.components[eeprom].methods
  assert(em.get() == newBios and em.getData() == diskAddr, "the kernal BIOS was re-flashed, still booting the same disk")
  typeLine("reboot")
  assert(node.status == "dead", "reboot restarts the computer")
  emu:boot(node)
  emu:advance(3)
  assert(text():find("muxos> _", 1, true), "the new version boots:\n" .. text())
end
print("  OK")

os.execute('rm -rf "' .. TMP .. '"')
print("ALL OK")
