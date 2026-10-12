-- muxterm, the network terminal, end to end: a muxos cluster (kernal +
-- worker) and a separate computer running REAL OpenOS with apps/muxterm.lua,
-- all on one network. The terminal gets a muxos session of its own --
-- login, console, programs, windows -- while the kernal's own screen
-- keeps its own.
--
--   lua5.3 test/emu/muxterm_test.lua
--
-- Needs OpenOS (see openos_test.lua); skipped, not failed, without it.
local REPO_ROOT = (arg and arg[0] and arg[0]:match("^(.*)/test/emu/muxterm_test%.lua$")) or "."
local Emulator = dofile(REPO_ROOT .. "/test/emu/emulator.lua")

local function readFile(p) local f = assert(io.open(p, "rb")) local d = f:read("a") f:close() return d end
local function exists(p) local f = io.open(p, "rb") if f then f:close() return true end return false end

local assets = os.getenv("OPENOS_DIR") or (REPO_ROOT .. "/test/emu/.openos-cache/src/main/resources/assets/opencomputers")
if not exists(assets .. "/lua/bios.lua") or not exists(assets .. "/loot/openos/init.lua") then
  print("SKIPPED: OpenOS isn't available (run openos_test.lua once online, or set OPENOS_DIR)")
  return
end
local function tree(root)
  local files = {}
  local p = io.popen('cd "' .. root .. '" && find . -type f')
  for line in p:lines() do files[line:sub(2)] = readFile(root .. line:sub(2)) end
  p:close()
  return files
end

local emu = Emulator.new()
emu.timeout = 5

-- The muxos cluster.
local kernal = emu:newNode("kernal")
emu:addModem(kernal)
local _, kscreen, kbufs = emu:addGpuScreen(kernal, 60, 20)
local kfiles = {["/etc/kernal.cfg"] = "login_required = false\n", ["/runtime.lua"] = readFile(REPO_ROOT .. "/node/runtime.lua"),
  ["/bin/greet.lua"] = 'print("hello from " .. os.getenv("USER"))\nio.read()'}
for _, f in ipairs({"muxos", "compositor", "shell", "bitmap", "lineedit", "system", "session", "vgpu", "terminals", "windows"}) do
  kfiles["/" .. f .. ".lua"] = readFile(REPO_ROOT .. "/kernal/" .. f .. ".lua")
end
emu:addEeprom(kernal, readFile(REPO_ROOT .. "/kernal/bios.lua"), emu:addFilesystem(kernal, kfiles))
local workers = {}
for i = 1, 2 do
  workers[i] = emu:newNode("worker")
  emu:addModem(workers[i])
  emu:addEeprom(workers[i], readFile(REPO_ROOT .. "/node/bios.lua"))
end

-- The terminal: OpenOS, with muxterm installed.
local node = emu:newNode("openos")
emu:addModem(node)
local gpuAddr, screenAddr, bufs = emu:addGpuScreen(node, 70, 22)
local kb = emu:addComponent(node, "keyboard", {})
local g = node.components[gpuAddr].methods
local fg, bg = 0xFFFFFF, 0
local setF, setB = g.setForeground, g.setBackground
g.setForeground = function(c) fg = c return setF(c) end
g.setBackground = function(c) bg = c return setB(c) end
g.getForeground = function() return fg end
g.getBackground = function() return bg end
g.maxResolution = function() return 70, 22 end
g.setResolution = function() return false end
g.getViewport = function() return 70, 22 end
g.setViewport = function() return true end
g.getScreen = function() return screenAddr end
g.get = function(x, y) local c = (bufs[0].cells[y] or {})[x] return c and c.char or " ", fg, bg end
g.getDepth = function() return 8 end
g.setDepth = function() return 8 end
local sm = node.components[screenAddr].methods
sm.getKeyboards = function() return {kb} end
sm.getAspectRatio = function() return 1, 1 end
sm.isPrecise = function() return false end
sm.isTouchModeInverted = function() return false end
local osFiles = tree(assets .. "/loot/openos")
osFiles["/usr/bin/muxterm.lua"] = readFile(REPO_ROOT .. "/apps/muxterm.lua")
local hdd = emu:addFilesystem(node, osFiles)
node.tmpAddress = emu:addFilesystem(node, {})
emu:addEeprom(node, readFile(assets .. "/lua/bios.lua"), hdd)

local function screenOf(b)
  local rows = {}
  for y = 1, b[0].h do
    local row, chars = b[0].cells[y] or {}, {}
    for x = 1, b[0].w do chars[x] = (row[x] and row[x].char) or " " end
    rows[#rows + 1] = (table.concat(chars):gsub("%s+$", ""))
  end
  return table.concat(rows, "\n")
end
local function terminal() return screenOf(bufs) end
local function console() return screenOf(kbufs) end
local function key(char, code, down)
  emu:injectSignal(node, down == false and "key_up" or "key_down", kb, char, code or 0, "tester")
  emu:advance(0.02)
end
local function typeLine(text)
  for i = 1, #text do key(text:byte(i)) key(text:byte(i), 0, false) end
  key(13, 0x1C) key(13, 0x1C, false)
end
local function waitFor(get, text, seconds)
  for _ = 1, (seconds or 20) * 20 do
    if get():find(text, 1, true) then return true end
    emu:advance(0.05)
  end
  return false
end
local function fail(msg) error(msg .. "\n--- terminal ---\n" .. terminal() .. "\n--- kernal screen ---\n" .. console(), 0) end

emu:boot(kernal)
for _, w in ipairs(workers) do emu:boot(w) end
emu:boot(node)
emu:advance(4)
if not waitFor(terminal, "/home #", 30) then fail("OpenOS didn't reach its shell") end

print("muxterm 1: it connects and gets a login of its own")
typeLine("muxterm")
if not waitFor(terminal, "login: _", 20) then fail("no login screen on the terminal") end
if not console():find("root@muxos:~> _", 1, true) then fail("the kernal's own console isn't affected") end
typeLine("root")
if not waitFor(terminal, "root@muxos:~> _", 10) then fail("logging in at the terminal") end
print("  OK")

print("muxterm 2: commands run in the terminal's session, its programs open windows there")
typeLine("echo from-the-terminal > /root/t.txt; whoami")
if not waitFor(terminal, "\nroot", 10) then fail("whoami") end
emu:advance(1)
if kfiles["/root/t.txt"] ~= "from-the-terminal\n" then fail("the shell ran on the kernal's disk") end
typeLine("who")
if not waitFor(terminal, "logged in: console, terminal", 10) then fail("who lists both sessions") end
typeLine("greet")
if not waitFor(terminal, "hello from root", 15) then fail("a legacy program's window on the terminal") end
if console():find("hello from root", 1, true) then fail("...and not on the kernal's screen") end
typeLine("") -- greet ends
print("  OK")

print("muxterm 3: the kernal's console works at the same time, separately")
local function kkey(char, code) emu:injectSignal(kernal, "key_down", kscreen, char, code or 0, "tester") emu:step() end
for ch in ("echo at-the-kernal"):gmatch(".") do kkey(ch:byte()) end
kkey(13, 0x1C)
if not waitFor(console, "\nat-the-kernal", 10) then fail("the kernal's console") end
if terminal():find("at-the-kernal", 1, true) then fail("the kernal's output stayed off the terminal") end
print("  OK")

print("muxterm 4: Ctrl+Alt+D hangs up; the session ends as a logout")
key(0, 0x1D) key(0, 0x38) key(string.byte("d"), 0x20)
if not waitFor(terminal, "muxterm: disconnected", 10) then fail("Ctrl+Alt+D") end
key(string.byte("d"), 0x20, false) key(0, 0x38, false) key(0, 0x1D, false)
emu:advance(2)
for ch in ("who"):gmatch(".") do kkey(ch:byte()) end
kkey(13, 0x1C)
emu:advance(2)
local after = console():match("who\n(.-)root@muxos") or ""
if after:find("terminal", 1, true) then fail("the terminal's session ended") end
print("  OK")
print("ALL OK")
