-- The installer under REAL OpenOS: boots OpenOS (the mod's own files, from
-- MightyPirates/OpenComputers) in the emulator, with the installer and its
-- data file on a floppy, and drives it at the shell -- as you would. My
-- earlier tests ran the installer against a hand-made imitation of
-- OpenOS; real OpenOS is the thing that matters.
--
--   lua5.3 test/emu/openos_test.lua
--
-- OpenOS is fetched once into test/emu/.openos-cache (git, sparse), or
-- taken from OPENOS_DIR (the mod's assets/opencomputers directory). With
-- neither available (offline), the test is skipped, not failed.
local REPO_ROOT = (arg and arg[0] and arg[0]:match("^(.*)/test/emu/openos_test%.lua$")) or "."
local Emulator = dofile(REPO_ROOT .. "/test/emu/emulator.lua")

local function readFile(p) local f = assert(io.open(p, "rb")) local d = f:read("a") f:close() return d end
local function exists(p) local f = io.open(p, "rb") if f then f:close() return true end return false end

local assets = os.getenv("OPENOS_DIR")
if not assets then
  local cache = REPO_ROOT .. "/test/emu/.openos-cache"
  assets = cache .. "/src/main/resources/assets/opencomputers"
  if not exists(assets .. "/lua/bios.lua") then
    os.execute('rm -rf "' .. cache .. '" && git clone -q --depth 1 --filter=blob:none --sparse -b master-MC1.12 '
      .. 'https://github.com/MightyPirates/OpenComputers.git "' .. cache .. '" >/dev/null 2>&1 && cd "' .. cache
      .. '" && git sparse-checkout set src/main/resources/assets/opencomputers/loot/openos '
      .. 'src/main/resources/assets/opencomputers/lua >/dev/null 2>&1')
  end
end
if not exists(assets .. "/lua/bios.lua") or not exists(assets .. "/loot/openos/init.lua") then
  print("SKIPPED: OpenOS isn't available (offline? set OPENOS_DIR to the mod's assets/opencomputers)")
  return
end

local function tree(root)
  local files = {}
  local p = io.popen('cd "' .. root .. '" && find . -type f')
  for line in p:lines() do files[line:sub(2)] = readFile(root .. line:sub(2)) end
  p:close()
  return files
end

-- One computer: OpenOS on its disk, the stock Lua BIOS, and the floppy.
local emu = Emulator.new()
emu.timeout = 5
local node = emu:newNode("openos")
local gpuAddr, screenAddr, bufs = emu:addGpuScreen(node, 80, 25)
local kb = emu:addComponent(node, "keyboard", {})
-- What OpenOS's tty uses that the emulator's gpu and screen don't model.
local g = node.components[gpuAddr].methods
local fg, bg = 0xFFFFFF, 0
local setF, setB = g.setForeground, g.setBackground
g.setForeground = function(c) fg = c return setF(c) end
g.setBackground = function(c) bg = c return setB(c) end
g.getForeground = function() return fg end
g.getBackground = function() return bg end
g.maxResolution = function() return 80, 25 end
g.setResolution = function() return false end
g.getViewport = function() return 80, 25 end
g.setViewport = function() return true end
g.getScreen = function() return screenAddr end
g.get = function(x, y) local c = (bufs[0].cells[y] or {})[x] return c and c.char or " ", fg, bg end
g.setDepth = function() return 8 end
local sm = node.components[screenAddr].methods
sm.getKeyboards = function() return {kb} end
sm.getAspectRatio = function() return 1, 1 end
sm.isPrecise = function() return false end
sm.isTouchModeInverted = function() return false end
local hdd = emu:addFilesystem(node, tree(assets .. "/loot/openos"))
node.tmpAddress = emu:addFilesystem(node, {})
local floppy = emu:addFilesystem(node, {
  ["/muxos-installer.lua"] = readFile(REPO_ROOT .. "/dist/muxos-installer.lua"),
  ["/muxos-installer.dat"] = readFile(REPO_ROOT .. "/dist/muxos-installer.dat"),
}, "floppy") -- so OpenOS mounts it at /mnt/flo
local eeprom = emu:addEeprom(node, readFile(assets .. "/lua/bios.lua"), hdd)

local function screen()
  local rows = {}
  for y = 1, bufs[0].h do
    local row, chars = bufs[0].cells[y] or {}, {}
    for x = 1, bufs[0].w do chars[x] = (row[x] and row[x].char) or " " end
    rows[#rows + 1] = (table.concat(chars):gsub("%s+$", ""))
  end
  return table.concat(rows, "\n")
end
local function typeLine(text)
  for i = 1, #text do
    emu:injectSignal(node, "key_down", kb, text:byte(i), 0, "tester")
    emu:advance(0.02)
    emu:injectSignal(node, "key_up", kb, text:byte(i), 0, "tester")
  end
  emu:injectSignal(node, "key_down", kb, 13, 0x1C, "tester")
  emu:advance(0.02)
  emu:injectSignal(node, "key_up", kb, 13, 0x1C, "tester")
end
local function waitFor(text, seconds)
  for _ = 1, (seconds or 20) * 20 do
    if screen():find(text, 1, true) then return true end
    emu:advance(0.05)
  end
  return false
end
local function fail(msg) error(msg .. "\n--- screen ---\n" .. screen(), 0) end

print("openos 1: real OpenOS boots")
emu:boot(node)
if not waitFor("/home #", 30) then fail("OpenOS didn't reach its shell") end
print("  OK")

print("openos 2: worker mode prompts quickly, and Enter flashes the EEPROM for real")
local fsm = node.components[floppy].methods
local reads, realRead = 0, fsm.read
fsm.read = function(...) reads = reads + 1 return realRead(...) end
typeLine("/mnt/*/muxos-installer.lua worker")
if not waitFor("[Y/n]") then fail("no flash prompt") end
-- Floppy reads are the slowest kind (about 1.5 per game tick on a tier 3
-- CPU, 0.5 on tier 1): everything before the first prompt must be few.
if reads > 60 then fail(reads .. " floppy reads before the first prompt -- far too slow on a real floppy") end
local promptReads = reads
typeLine("")
if not waitFor("checked byte for byte") then fail("it didn't flash") end
typeLine("q")
if not waitFor("1 worker EEPROM(s) flashed.") then fail("no summary") end
local em = node.components[eeprom].methods
if em.get() ~= readFile(REPO_ROOT .. "/node/bios.lua") or em.getLabel() ~= "muxos worker" then
  fail("the EEPROM doesn't hold the worker BIOS")
end
print("  OK (" .. promptReads .. " floppy reads before the prompt)")

print("openos 3: check mode identifies it")
typeLine("/mnt/*/muxos-installer.lua check")
if not waitFor("the muxos worker BIOS, this version") then fail("check didn't recognize the worker BIOS") end
typeLine("q")
if not waitFor("/home #") then fail("check didn't finish") end
print("  OK")

-- However it's started, it finds its data file. OpenComputers wraps
-- debug.getinfo and OpenOS's $_ names /bin/lua.lua under `lua`, so the
-- installer's idea of its own path is easy to get wrong.
print("openos 4: it finds its data file however it's started")
local mnt = "/mnt/flo"
for _, start in ipairs({
  {"lua " .. mnt .. "/muxos-installer.lua check"},
  {"cd " .. mnt, "./muxos-installer.lua check"},
  {"cd " .. mnt, "lua muxos-installer.lua check"},
  {"cd " .. mnt, mnt .. "/muxos-installer.lua check"},
}) do
  typeLine("clear")
  emu:advance(0.5)
  for _, line in ipairs(start) do typeLine(line) emu:advance(0.5) end
  if not waitFor("the muxos worker BIOS, this version") then fail("`" .. table.concat(start, "; ") .. "` didn't work") end
  typeLine("q")
  emu:advance(0.5)
  typeLine("cd /home")
  if not waitFor("/home #") then fail("`" .. table.concat(start, "; ") .. "` didn't finish") end
end
print("  OK")

-- The floppy boots on its own: an empty computer with nothing but the
-- stock Lua BIOS (what every computer starts with) and the floppy.
print("openos 5: the stock Lua BIOS boots the floppy into the installer, which installs muxos")
do
  local bare = emu:newNode("bare")
  emu:addModem(bare)
  local _, bareScreen, bareBufs = emu:addGpuScreen(bare, 80, 25)
  local hdd = {}
  local hddAddr = emu:addFilesystem(bare, hdd)
  emu:addFilesystem(bare, {
    ["/init.lua"] = readFile(REPO_ROOT .. "/dist/floppy/init.lua"),
    ["/muxos-installer.lua"] = readFile(REPO_ROOT .. "/dist/muxos-installer.lua"),
    ["/muxos-installer.dat"] = readFile(REPO_ROOT .. "/dist/muxos-installer.dat"),
  })
  local bareEeprom = emu:addEeprom(bare, readFile(assets .. "/lua/bios.lua"))
  local function text()
    local rows = {}
    for y = 1, bareBufs[0].h do
      local row, chars = bareBufs[0].cells[y] or {}, {}
      for x = 1, bareBufs[0].w do chars[x] = (row[x] and row[x].char) or " " end
      rows[#rows + 1] = table.concat(chars)
    end
    return table.concat(rows, "\n")
  end
  local function answer(line)
    for i = 1, #line do
      emu:injectSignal(bare, "key_down", bareScreen, line:byte(i), 0, "tester")
      emu:step()
    end
    emu:injectSignal(bare, "key_down", bareScreen, 13, 0x1C, "tester")
    emu:advance(1)
  end
  emu:boot(bare)
  emu:advance(3)
  if not text():find("muxos 0.1.2 installer (booted from", 1, true) then error("the floppy didn't boot:\n" .. text(), 0) end
  answer("1")
  answer("1")
  answer("y")
  emu:advance(5)
  if not text():find("muxos 0.1.2 is installed.", 1, true) then error("it didn't install:\n" .. text(), 0) end
  local em = bare.components[bareEeprom].methods
  if em.get() ~= readFile(REPO_ROOT .. "/kernal/bios.lua") or em.getData() ~= hddAddr then
    error("the kernal BIOS wasn't flashed over the stock one, pointing at the disk", 0)
  end
  answer("y")
  emu:boot(bare)
  emu:advance(3)
  if not text():find("muxos> _", 1, true) then error("muxos didn't boot from the disk:\n" .. text(), 0) end
end
print("  OK")

-- The floppy's /init.lua shows a failing installer on the screen.
print("openos 5b: under the stock BIOS, an installer that fails says so on the screen")
do
  local bare = emu:newNode("bare")
  local _, _, bareBufs = emu:addGpuScreen(bare, 80, 25)
  emu:addFilesystem(bare, {
    ["/init.lua"] = readFile(REPO_ROOT .. "/dist/floppy/init.lua"),
    ["/muxos-installer.lua"] = "error('broken on purpose')",
  })
  emu:addEeprom(bare, readFile(assets .. "/lua/bios.lua"))
  emu:boot(bare)
  emu:advance(2)
  local row, chars = bareBufs[0].cells[1] or {}, {}
  for x = 1, 80 do chars[x] = (row[x] and row[x].char) or " " end
  if bare.status ~= "dead" or not table.concat(chars):find("muxos installer stopped: /muxos-installer.lua:1: broken", 1, true) then
    error("the failure isn't on the screen: " .. table.concat(chars), 0)
  end
end
print("  OK")

-- The muxos kernal BIOS runs the installer itself, on a computer that
-- also has an OpenOS disk, a tmpfs, and an EEPROM still pointing at that
-- disk -- with or without the floppy's /init.lua.
print("openos 6: the muxos kernal BIOS boots the installer floppy next to an OpenOS disk")
for _, withInit in ipairs({true, false}) do
  local k = emu:newNode("kern")
  local _, _, kbufs = emu:addGpuScreen(k, 80, 25)
  local osHdd = emu:addFilesystem(k, tree(assets .. "/loot/openos"))
  k.tmpAddress = emu:addFilesystem(k, {})
  local files = {
    ["/muxos-installer.lua"] = readFile(REPO_ROOT .. "/dist/muxos-installer.lua"),
    ["/muxos-installer.dat"] = readFile(REPO_ROOT .. "/dist/muxos-installer.dat"),
  }
  if withInit then files["/init.lua"] = readFile(REPO_ROOT .. "/dist/floppy/init.lua") end
  emu:addFilesystem(k, files, "floppy")
  emu:addEeprom(k, readFile(REPO_ROOT .. "/kernal/bios.lua"), osHdd)
  emu:boot(k)
  emu:advance(3)
  local row, chars = kbufs[0].cells[1] or {}, {}
  for x = 1, 80 do chars[x] = (row[x] and row[x].char) or " " end
  if not table.concat(chars):find("muxos 0.1.2 installer (booted from floppy", 1, true) or k.status ~= "running" then
    error("the kernal BIOS didn't start the installer (" .. (withInit and "with" or "without") .. " /init.lua)", 0)
  end
end
print("  OK")

print("ALL OK")
