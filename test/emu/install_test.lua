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
local BUNDLE, FLOPPY = TMP .. "/muxos-installer.lua", TMP .. "/floppy"

print("install 1: the build is clean, deterministic, and dist/ is up to date")
assert(os.execute('lua5.3 "' .. REPO_ROOT .. '/tools/build.lua" --out "' .. BUNDLE .. '" --floppy "' .. FLOPPY .. '" >/dev/null'),
  "tools/build.lua failed")
assert(readFile(BUNDLE) == readFile(REPO_ROOT .. "/dist/muxos-installer.lua"),
  "dist/muxos-installer.lua is stale: run lua5.3 tools/build.lua")
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
  local filesystem = {
    exists = function(p) local f = io.open(p, "rb") if f then f:close() return true end return false end,
    get = function() return {address = medium}, "/mnt/installer" end,
  }
  return {component = component, computer = computer, filesystem = filesystem}
end

-- Runs an installer file with arguments; `answers` feed io.read (a
-- function answer is called and its result used). Returns the exit
-- code and everything it printed.
local function runInstaller(path, openos, answers, ...)
  local out = {}
  local env = setmetatable({}, {__index = _G})
  env.require = function(name) return assert(openos[name], "installer required " .. name) end
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
  assert(out:find("Upgrading muxos 0.0.9 to 0.1.0", 1, true), "it noticed the old version:\n" .. out)
  assert(out:find("warning", 1, true) == nil, "no hardware warnings on a complete kernal:\n" .. out)
  assert(disk["/muxos.lua"] == readFile(REPO_ROOT .. "/kernal/muxos.lua"), "muxos.lua installed")
  assert(disk["/runtime.lua"] == readFile(REPO_ROOT .. "/node/runtime.lua"), "runtime.lua installed")
  assert(disk["/lib/core/full_text.lua"] == readFile(REPO_ROOT .. "/kernal/lib/core/full_text.lua"), "libraries installed")
  assert(disk["/.muxos-version"] == "0.1.0\n" and disk["/home/keep.txt"] == "mine", "version recorded, user files kept")
  assert(not disk["/eeprom/kernal.lua"], "BIOS images aren't disk files")
  assert(disk["/bin/opm.mxe"] == readFile(REPO_ROOT .. "/opm/opm.mxe")
    and disk["/lib/mxe/opm_core.lua"] == readFile(REPO_ROOT .. "/opm/opm_core.lua"), "opm ships with muxos")
  for path in pairs(disk) do assert(not path:match("%.new$"), "left a staged file behind: " .. path) end
  local eeprom = kernal.components[kernalEeprom].methods
  assert(eeprom.get() == readFile(REPO_ROOT .. "/kernal/bios.lua") and eeprom.getData() == diskAddr,
    "the kernal BIOS was flashed and points at the disk")
end
print("  OK")

print("install 4: the floppy layout installs the same files")
do
  local node = emu:newNode("other")
  emu:addModem(node)
  emu:addGpuScreen(node, 50, 30)
  local files = {}
  emu:addFilesystem(node, files)
  local floppyMedium = emu:addFilesystem(node, {})
  emu:addEeprom(node, "-- the OpenOS BIOS")
  local code, out = runInstaller(FLOPPY .. "/install.lua", openosFor(node, floppyMedium), {"1", "y"}, "kernal")
  assert(code == 0, "floppy install failed:\n" .. out)
  assert(out:find("Installing muxos 0.1.0", 1, true), "a fresh install:\n" .. out)
  for path, data in pairs(disk) do
    if path ~= "/.muxos-version" and path ~= "/home/keep.txt" then
      assert(files[path] == data, "floppy install differs at " .. path)
    end
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

os.execute('rm -rf "' .. TMP .. '"')
print("ALL OK")
