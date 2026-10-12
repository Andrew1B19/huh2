-- muxterm, the network terminal, end to end: a muxos cluster (kernal +
-- worker) and a separate computer running REAL OpenOS with apps/muxterm.lua,
-- all on one network. The terminal gets a muxos session of its own --
-- login, console, programs, windows, composited on the terminal itself
-- -- while the kernal's own screen keeps its own. Programs draw to the
-- terminal and get its input directly (the packets are watched), hold
-- its screen fullscreen, and a persistent program's window moves
-- between the two screens.
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
  ["/bin/greet.lua"] = 'print("hello from " .. os.getenv("USER"))\nio.read()',
  -- Persistent; shows how often its window moved and the last key it got.
  ["/bin/keeper.mxe"] = [==[--[[mxe
name = "keeper"
]]
gmuxapi.set_persistent(true)
local det, att, last = 0, 0, "-"
local win = gmuxapi.create_window({title = "keeper", x = 3, y = 3, width = 30, height = 1,
  code = "gpu.set(1, 1, 'KEEP d0 a0 k-')"}).id
local function show()
  gmuxapi.draw_window(win, {code = "gpu.set(1, 1, args.t)", args = {t = "KEEP d" .. det .. " a" .. att .. " k" .. last .. "   "}})
end
while true do
  local e = gmuxapi.pull_event(60)
  if e and e[1] == "window_detached" then det = det + 1 end
  if e and e[1] == "window_attached" then att = att + 1 show() end
  if e and e[1] == "key_down" and (e[2] or 0) > 32 then last = string.char(e[2]) show() end
end
]==],
  ["/bin/full.mxe"] = [==[--[[mxe
name = "full"
]]
local g, err = gmuxapi.request_fullscreen()
if not g then print("FULL REFUSED " .. tostring(err)) return end
local w, h = gpu.getResolution()
gpu.setBackground(0x000000)
gpu.fill(1, 1, w, h, " ")
gpu.set(5, 5, "FULL SCREEN " .. w .. "x" .. h)
sleep(3)
gmuxapi.release_fullscreen()
]==]}
for _, f in ipairs({"muxos", "compositor", "shell", "bitmap", "lineedit", "system", "session", "vgpu", "terminals", "windows", "terminal"}) do
  kfiles["/" .. f .. ".lua"] = readFile(REPO_ROOT .. "/kernal/" .. f .. ".lua")
end
emu:addEeprom(kernal, readFile(REPO_ROOT .. "/kernal/bios.lua"), emu:addFilesystem(kernal, kfiles))
local workers = {}
for i = 1, 2 do
  workers[i] = emu:newNode("worker")
  emu:addModem(workers[i])
  emu:addEeprom(workers[i], readFile(REPO_ROOT .. "/node/bios.lua"))
end

-- What the workers send, and to whom: {to, type}.
local sent = {}
local function watch(n, log)
  local m = n.components[n.modemAddr].methods
  local send = m.send
  m.send = function(address, port, data, ...)
    local t = type(data) == "string" and data:match('%["type"%]="(%u+)"')
    if t then log[#log + 1] = {to = address, type = t} end
    return send(address, port, data, ...)
  end
end
for _, w in ipairs(workers) do watch(w, sent) end
local function sentCount(to, t)
  local n = 0
  for _, e in ipairs(sent) do if e.to == to and e.type == t then n = n + 1 end end
  return n
end
local function isWorker(address)
  for _, w in ipairs(workers) do if w.modemAddr == address then return true end end
  return false
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
local termSent = {}
watch(node, termSent)
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
local function row(b, y) return (screenOf(b) .. "\n"):match(("[^\n]*\n"):rep(y - 1) .. "([^\n]*)") or "" end
local function touch(x, y) emu:injectSignal(node, "touch", screenAddr, x, y, 0, "tester") emu:advance(0.1) end
local function ktouch(x, y) emu:injectSignal(kernal, "touch", kscreen, x, y, 0, "tester") emu:advance(0.1) end
-- The console's taskbar button gives it the keyboard back.
local function consoleFocus()
  local x = row(bufs, 22):find(" console ", 1, true)
  if x then touch(x + 2, 22) end
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
if not waitFor(terminal, "\u{23F9} - greet.lua", 10) then fail("greet ended") end
print("  OK")

print("muxterm 3: the kernal's console works at the same time, separately")
local function kkey(char, code) emu:injectSignal(kernal, "key_down", kscreen, char, code or 0, "tester") emu:step() end
for ch in ("echo at-the-kernal"):gmatch(".") do kkey(ch:byte()) end
kkey(13, 0x1C)
if not waitFor(console, "\nat-the-kernal", 10) then fail("the kernal's console") end
if terminal():find("at-the-kernal", 1, true) then fail("the kernal's output stayed off the terminal") end
print("  OK")

print("muxterm 4: an .mxe on the terminal draws its window there directly, and gets its keys directly")
local before = sentCount(kernal.modemAddr, "DRAWWINDOW")
consoleFocus()
typeLine("keeper &")
if not waitFor(terminal, "KEEP d0 a0 k-", 15) then fail("keeper's window on the terminal") end
if console():find("KEEP", 1, true) then fail("...and not on the kernal's screen") end
typeLine("q") -- the new window has the keyboard
if not waitFor(terminal, "KEEP d0 a0 kq", 10) then fail("a key reaches the program") end
if sentCount(node.modemAddr, "DRAWWINDOW") < 1 then fail("the redraw went to the terminal directly") end
if sentCount(kernal.modemAddr, "DRAWWINDOW") ~= before then fail("...not through the kernal") end
local direct = false
for _, e in ipairs(termSent) do if e.type == "EVENT" and isWorker(e.to) then direct = true end end
if not direct then fail("the key went from the terminal straight to the program's node") end
print("  OK")

print("muxterm 5: fullscreen works on the terminal's screen")
consoleFocus()
typeLine("full")
if not waitFor(terminal, "FULL SCREEN 70x22", 15) then fail("a program holds the terminal's screen") end
if console():find("FULL SCREEN", 1, true) then fail("...not the kernal's") end
if sentCount(node.modemAddr, "GPUCALL") < 1 then fail("its gpu calls went to the terminal directly") end
if not waitFor(function() return row(bufs, 22) end, "console", 10) then fail("the desktop comes back on release") end
if terminal():find("FULL SCREEN", 1, true) then fail("...redrawn") end
if not waitFor(terminal, "KEEP d0 a0 kq", 5) then fail("keeper's window survives fullscreen") end
print("  OK")

print("muxterm 6: Ctrl+Alt+D hangs up; the session ends as a logout")
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

print("muxterm 7: the persistent program kept running; the kernal's taskbar brings its window over")
emu:advance(1)
local kx = row(kbufs, 20):find("keeper", 1, true)
if not kx then fail("keeper on the kernal console's taskbar") end
ktouch(kx, 20)
if not waitFor(console, "KEEP d1 a1 kq", 10) then fail("keeper's window on the kernal's screen, content redrawn") end
print("  OK")

print("muxterm 8: a new terminal login lists it too, and takes it back")
typeLine("muxterm")
if not waitFor(terminal, "login: _", 20) then fail("reconnecting") end
typeLine("root")
if not waitFor(terminal, "root@muxos:~> _", 10) then fail("logging in again") end
emu:advance(1)
local tx = row(bufs, 22):find("keeper", 1, true)
if not tx then fail("keeper on the terminal's taskbar") end
touch(tx, 22)
if not waitFor(terminal, "KEEP d", 10) then fail("keeper's window back on the terminal") end
emu:advance(1)
if console():find("KEEP", 1, true) then fail("...and off the kernal's screen") end
if not terminal():find("a2 kq", 1, true) then fail("it heard the move") end
print("  OK")

print("muxterm 9: nothing went wrong quietly on either side")
if (console() .. terminal()):find("error (continuing)", 1, true) or terminal():find("\nterminal: ", 1, true) then
  fail("an error was logged")
end
print("  OK")
print("ALL OK")
