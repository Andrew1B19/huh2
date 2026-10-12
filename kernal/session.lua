-- muxos session: one person at one screen -- the kernal's own (the
-- local console) or a network terminal's (muxterm). Everything a
-- session is lives here, one instance per session: its console (output,
-- scrollback, line editor, shell), its login, its compositor (windows,
-- focus, the desktop, the taskbar), and its keyboard and pointer input.
-- The two kinds differ only in the gpu they draw with: the local
-- session's is the kernal's real GPU, a terminal's is a kernal/vgpu.lua
-- one whose changes are sent to the terminal.
--
-- Loaded by kernal/muxos.lua once per session:
--   loadSibling("session.lua")(K, opts)
-- K is the kernal's side (jobs, processes, commands -- see muxos.lua's
-- `K`); opts = {id, gpu, kind = "local" | "terminal", address (a
-- terminal's)}. Returns the session, S.
local K, opts = ...
local S = {id = opts.id, kind = opts.kind, address = opts.address, user = nil, login = 0}
local system, jobs = K.system, K.jobs
local loadSibling, launchProgram = K.loadSibling, K.launchProgram
local gpu = opts.gpu
local compositor = K.newCompositor(gpu)
S.compositor, S.gpu = compositor, gpu

-- This screen as the window registry (kernal/windows.lua) sees it: where
-- programs' windows are drawn, and how they're shown and taken away.
S.display = {
  address = K.selfAddr,
  create = function(spec)
    local win, err = compositor.createWindow(spec)
    if not win then return nil, err end
    return {width = win.width, height = win.height}
  end,
  remove = function(id) compositor.close(id) end,
  status = function(id, status) compositor.setStatus(id, status) end,
  setOwner = function(id, jobId)
    local win = compositor.getWindow(id)
    if win then win.ownerJobId = jobId end
  end,
}

-- --- The console, replacing OpenOS's io/term ---
--
-- The console's text lives in regular memory (consoleLines) and never
-- has a video buffer of its own. Normally it's a compositor text
-- window like any other, painted from its rows straight into the
-- frame buffer. Its size isn't fixed: it starts as the bottom half of
-- the screen and the `console <width> <height> [x y]` command changes
-- it at any time (cheap, since there's no buffer to reallocate). In
-- console mode (hold Ctrl+Alt+C) it's the compositor's
-- exclusive owner instead and draws straight onto the real screen at
-- full resolution.
--
-- Output is kept as logical (unwrapped) lines and wrapped only when
-- rendered, at whatever width the console currently has -- which is
-- what makes scrollback, switching between the two sizes, and
-- backspacing across a wrapped input line simple. Rendering happens at
-- most once per tick (renderConsole, from tick()).

local termW, termH = 1, 1
if gpu then
  termW, termH = gpu.getResolution()
end
S.width, S.height = termW, termH

local CONSOLE_LAYER = 0
local CONSOLE_MIN_W, CONSOLE_MIN_H = 10, 3
-- Scrollback, in lines of output (oldest dropped first).
local SCROLLBACK_LINES = 500
local consoleLines = {}      -- committed logical lines, oldest first
local consoleDirty = true
local scrollOffset = 0       -- wrapped rows scrolled back from the bottom
local editor = K.lineedit.new() -- the line being typed (kernal/lineedit.lua); one per login
local consolePartial = ""    -- program output not yet ended by a newline
local commandBusy = false    -- a command is running; see handleKeyDown

-- A window like any other, with a title bar (gmux-style): it can be
-- minimized, moved and resized. Its close button minimizes it instead.
-- The POSIX-style shell (kernal/shell.lua), loaded once the program
-- launcher it hands programs to exists (below); declared here for the
-- prompt, which shows its working directory.
local shell = nil

local consoleW, consoleH = termW, math.max(CONSOLE_MIN_H, math.floor(termH / 2))
local consoleWin = gpu and compositor.createWindow({title = "console", x = 1, y = termH - consoleH - 1,
  width = consoleW, height = consoleH, layer = CONSOLE_LAYER, text = true}) or nil

local function consoleOwnsScreen()
  return compositor.exclusiveOwner() == "console"
end

-- The console's current size: the whole screen in console mode, its
-- window otherwise.
local function viewSize()
  if consoleOwnsScreen() then return termW, termH end
  local win = consoleWin and compositor.getWindow(consoleWin.id)
  if win then return win.width, win.height end -- resized by hand too
  return consoleW, consoleH
end

-- Splits one logical line into rows of at most `width` characters
-- (UTF-8 aware; falls back to bytes for invalid UTF-8).
local function wrapLine(line, width)
  local len = utf8.len(line)
  if not len then
    local rows = {}
    for i = 1, math.max(#line, 1), width do rows[#rows + 1] = line:sub(i, i + width - 1) end
    return rows
  end
  if len <= width then return {line} end
  local rows = {}
  local startChar = 1
  while startChar <= len do
    local from = utf8.offset(line, startChar)
    local to = utf8.offset(line, startChar + width)
    rows[#rows + 1] = to and line:sub(from, to - 1) or line:sub(from)
    startChar = startChar + width
  end
  return rows
end

-- The console's prompt: `login: ` while nobody is logged in, otherwise
-- user@muxos:<working directory, ~ for home>.
function S.prompt()
  local user = S.user
  if not user then return "login: " end
  local cwd, home = S.cwd(), system.home(user)
  if cwd == home then
    cwd = "~"
  elseif cwd:sub(1, #home + 1) == home .. "/" then
    cwd = "~" .. cwd:sub(#home + 1)
  end
  return user .. "@muxos:" .. cwd .. "> "
end

-- The line being typed, and where its cursor is: a character index into
-- it, for a cursor within the line (drawn inverted), or nil when the
-- cursor is at the end (drawn as a trailing "_").
local function liveLine()
  if commandBusy then
    -- A foreground program is running: show its unfinished output line
    -- (e.g. a prompt it wrote with io.write, plus the echo of what's
    -- being typed into it).
    if consolePartial ~= "" then return consolePartial .. "_" end
    return nil
  end
  local prompt = S.prompt()
  local text = editor:text()
  if editor:cursor() < (utf8.len(text) or #text) then
    return prompt .. text, (utf8.len(prompt) or #prompt) + editor:cursor() + 1
  end
  return prompt .. text .. "_"
end

local function totalRows(width)
  local n = 0
  for _, line in ipairs(consoleLines) do n = n + #wrapLine(line, width) end
  local live = liveLine()
  if live then n = n + #wrapLine(live, width) end
  return n
end

local function setScroll(rows)
  local w, h = viewSize()
  scrollOffset = math.max(0, math.min(rows, totalRows(w) - h))
  consoleDirty = true
end

-- The h rows currently in view, top to bottom, and the cursor's row and
-- column within them when it's inside the line being typed (see
-- liveLine). Content shorter than the view starts at the top, like a
-- fresh terminal.
local function visibleRows(w, h)
  local needed = h + scrollOffset
  local rows = {}            -- collected bottom-up
  local exhausted = true
  local function addLine(line)
    local wrapped = wrapLine(line, w)
    for i = #wrapped, 1, -1 do
      rows[#rows + 1] = wrapped[i]
      if #rows >= needed then return true end
    end
  end
  local live, cursorAt = liveLine()
  local cursorUp, cursorCol -- rows up from the bottom (1 = the last one), column
  if live and cursorAt then
    local wrapped = #wrapLine(live, w)
    cursorUp, cursorCol = wrapped - (cursorAt - 1) // w, (cursorAt - 1) % w + 1
  end
  if live and addLine(live) then exhausted = false end
  if exhausted then
    for i = #consoleLines, 1, -1 do
      if addLine(consoleLines[i]) then exhausted = false break end
    end
  end
  local out, cursorRow = {}, nil
  if exhausted and #rows < h then
    for i = 1, #rows do out[i] = rows[#rows - i + 1] end
    cursorRow = cursorUp and #rows - cursorUp + 1
  else
    for r = 1, h do out[h - r + 1] = rows[scrollOffset + r] end
    cursorRow = cursorUp and h - (cursorUp - scrollOffset) + 1
  end
  if cursorRow and (cursorRow < 1 or cursorRow > h) then cursorRow = nil end
  return out, cursorRow, cursorCol
end

local function renderConsole()
  if not consoleDirty or not consoleWin then return end
  -- Another owner (a fullscreen node) has the screen: leave it alone.
  local owner = compositor.exclusiveOwner()
  if owner and owner ~= "console" then return end
  consoleDirty = false
  local w, h = viewSize()
  local rows, cursorRow, cursorCol = visibleRows(w, h)
  if scrollOffset > 0 then
    local tag = "[scrolled " .. scrollOffset .. " -- PgDn]"
    local first = rows[1] or ""
    local keep = math.max(0, w - #tag)
    local len = utf8.len(first) or #first
    if len < keep then
      first = first .. (" "):rep(keep - len)
    else
      first = first:sub(1, (utf8.offset(first, keep + 1) or (keep + 1)) - 1)
    end
    rows[1] = first .. tag
  end
  -- A cursor inside the line: that character, inverted.
  local cursorCell
  if cursorRow and rows[cursorRow] then
    local row = rows[cursorRow]
    local from = utf8.offset(row, cursorCol) or (#row + 1)
    local to = utf8.offset(row, cursorCol + 1) or (#row + 1)
    local under = row:sub(from, to - 1)
    cursorCell = under ~= "" and under or " "
    rows[cursorRow] = {{row:sub(1, from - 1)}, {cursorCell, 0x000000, 0xFFFFFF}, {row:sub(to)}}
  end
  if owner == "console" then
    compositor.drawDirect(function(g)
      g.setForeground(0xFFFFFF)
      g.setBackground(0x000000)
      g.fill(1, 1, w, h, " ")
      for y = 1, h do
        local row = rows[y]
        if type(row) == "table" then
          g.set(1, y, row[1][1] .. cursorCell .. row[3][1])
          g.setForeground(0x000000)
          g.setBackground(0xFFFFFF)
          g.set(1 + (cursorCol - 1), y, cursorCell)
          g.setForeground(0xFFFFFF)
          g.setBackground(0x000000)
        elseif row and row ~= "" then
          g.set(1, y, row)
        end
      end
    end)
  else
    compositor.setText(consoleWin.id, rows)
  end
end

local function consoleAppend(line)
  consoleLines[#consoleLines + 1] = line
  if #consoleLines > SCROLLBACK_LINES then table.remove(consoleLines, 1) end
  -- Keep a scrolled-back view still while new output arrives below it.
  if scrollOffset > 0 then scrollOffset = scrollOffset + #wrapLine(line, (viewSize())) end
  consoleDirty = true
end

-- Shadows the native `print` (which only logs to the Java server
-- console, not the in-game screen -- see this file's header) for every
-- call below this point in the same chunk.
local function print(...)
  local n = select("#", ...)
  local parts = {}
  for i = 1, n do parts[i] = tostring((select(i, ...))) end
  local text = table.concat(parts, "\t")
  if consolePartial ~= "" then
    consoleAppend(consolePartial)
    consolePartial = ""
  end
  for line in (text .. "\n"):gmatch("(.-)\n") do consoleAppend(line) end
end
S.print = print

-- Program output (OUTPUT messages): may end mid-line, so the unfinished
-- part is held in consolePartial until its newline arrives.
local function consoleWrite(text)
  local start = 1
  while true do
    local nl = text:find("\n", start, true)
    if not nl then
      consolePartial = consolePartial .. text:sub(start)
      break
    end
    consoleAppend(consolePartial .. text:sub(start, nl - 1))
    consolePartial = ""
    start = nl + 1
  end
  consoleDirty = true
end
S.write = consoleWrite

-- --- Minimal keyboard modifier tracking, replacing OpenOS's keyboard library ---

-- Same key-code constants OpenOS's own lib/keyboard.lua uses internally
-- (verified against its source) -- just tracked by hand here since
-- there's no keyboard.pressedCodes table to read without it.
local KEYS = {BACK = 0x0E, ENTER = 0x1C, LCONTROL = 0x1D, RCONTROL = 0x9D, LMENU = 0x38, RMENU = 0xB8, C = 0x2E}
local heldKeys = {}
local function isControlDown() return heldKeys[KEYS.LCONTROL] or heldKeys[KEYS.RCONTROL] end
local function isAltDown() return heldKeys[KEYS.LMENU] or heldKeys[KEYS.RMENU] end


-- UI constants: PgUp/PgDn key codes, how long Ctrl+Alt+C is held for
-- console mode, and the narrowest a window can be resized to (room for
-- the title bar's buttons).
local UI = {KEY_PAGEUP = 0xC9, KEY_PAGEDOWN = 0xD1, CONSOLE_HOLD_SECONDS = 1, MIN_WINDOW_WIDTH = 8}

-- Keys typed while a command is still running, replayed in order once
-- it returns.
local queuedKeys = {}

-- The kernal-level interrupt: bring the console up and show it alone,
-- whatever else is going on (a stuck fullscreen app, a window covering
-- everything). `comp` returns to normal compositing.
-- Ctrl+Alt+C, pressed: exit whatever is fullscreen -- a node's
-- fullscreen grant (force-released, so a crashed holder can't trap the
-- screen), or console mode.
local function exitFullscreen()
  local fullscreen = K.fullscreen
  if S.kind == "local" and fullscreen.node then
    print("Ctrl+Alt+C: force-releasing fullscreen grant held by " .. fullscreen.node)
    fullscreen.node = nil
    fullscreen.job = nil
  end
  -- Logged out, the screen is the login prompt's alone.
  compositor.setExclusive(not S.user and "console" or nil)
  consoleDirty = true
end
S.exitFullscreen = exitFullscreen

-- Ctrl+Alt+C, held for UI.CONSOLE_HOLD_SECONDS: the kernal-level
-- interrupt that drops into the full-screen kernal console.
local comboPressedAt, comboHoldFired = nil, false

local function consoleInterrupt()
  exitFullscreen()
  compositor.setExclusive("console")
  if consoleWin then compositor.setFocus(consoleWin.id) end
  scrollOffset = 0
  consoleDirty = true
  print("console only -- type 'comp' to show windows again")
end

local function scrollConsole(rows)
  setScroll(scrollOffset + rows)
end

-- The process that gets keyboard/scroll input right now: the owner of
-- the focused window, if it's a live process. Otherwise (console mode,
-- the console focused, or a window whose process has ended) the console
-- gets it. Ctrl+Alt+C always reaches the kernal.
local function focusedProcess()
  if consoleOwnsScreen() then return nil end
  local win = compositor.getFocus()
  if not win or (consoleWin and win.id == consoleWin.id) or not win.ownerJobId then return nil end
  return K.liveJob(win.ownerJobId)
end

local deliverEvent = K.deliverEvent

-- The program running in the foreground from the console (see
-- runForeground), which gets the console's typed input. The kernal
-- echoes it like a terminal: printable characters, backspace (only over
-- what was typed since the last Enter), and Enter.
local foregroundTyped = ""

local function feedForeground(char, code)
  local job = jobs[S.foregroundJob]
  if not job or job.status ~= "running" then return false end
  deliverEvent(job, {"key_down", char, code})
  if code == KEYS.ENTER then
    consoleAppend(consolePartial)
    consolePartial, foregroundTyped = "", ""
  elseif code == KEYS.BACK then
    local len = utf8.len(foregroundTyped)
    if len and len > 0 then
      local cut = utf8.offset(foregroundTyped, -1)
      local removed = #foregroundTyped - cut + 1
      foregroundTyped = foregroundTyped:sub(1, cut - 1)
      consolePartial = consolePartial:sub(1, #consolePartial - removed)
    end
  elseif char and char >= 32 then
    local ok, ch = pcall(utf8.char, char)
    if ok then
      foregroundTyped = foregroundTyped .. ch
      consolePartial = consolePartial .. ch
    end
  end
  consoleDirty = true
  return true
end

local startCommand -- below

local function handleKeyDown(char, code)
  heldKeys[code] = true
  -- Ctrl+Alt+C was OpenOS's own interrupt shortcut; muxos has no OpenOS
  -- underneath, so it's reclaimed as the kernal's console interrupt.
  if code == KEYS.C and isControlDown() and isAltDown() then
    -- Key repeat sends more key_downs while it's held; only the first
    -- one is a press.
    if not comboPressedAt then
      comboPressedAt, comboHoldFired = computer.uptime(), false
      exitFullscreen()
    end
    return
  end
  local target = focusedProcess()
  if target then
    deliverEvent(target, {"key_down", char, code})
    return
  end
  -- Scrolling never waits behind a running command.
  if code == UI.KEY_PAGEUP then scrollConsole(select(2, viewSize()) - 1) return end
  if code == UI.KEY_PAGEDOWN then scrollConsole(-(select(2, viewSize()) - 1)) return end
  if commandBusy and S.foregroundJob and feedForeground(char, code) then return end
  if commandBusy then
    queuedKeys[#queuedKeys + 1] = {char, code}
    return
  end
  local line = editor:key(char, code)
  if type(line) == "string" then
    consoleAppend(S.prompt() .. line)
    scrollOffset = 0
    startCommand(line)
  elseif line then
    scrollOffset = 0
    consoleDirty = true
  end
end

-- A typed line runs as a command in its own coroutine: one that waits
-- (on a worker's reply, a program in the foreground, `sleep`) yields
-- back to the kernal, which keeps every other session going meanwhile
-- and resumes this one each tick (S.resume).
local command = nil

startCommand = function(line)
  commandBusy, consoleDirty = true, true
  command = coroutine.create(function() return K.runCommand(S, line) end)
  S.resume()
end

function S.resume()
  if not command then return end
  local ok, err = K.resumeCommand(S, command)
  if coroutine.status(command) ~= "dead" then return end
  command, commandBusy, consoleDirty = nil, false, true
  if not ok then print("command error: " .. tostring(err)) end
  while #queuedKeys > 0 and not commandBusy do
    local key = table.remove(queuedKeys, 1)
    handleKeyDown(key[1], key[2])
  end
end

function S.busy() return commandBusy end

-- A paste (OpenComputers' "clipboard" signal): the focused program gets
-- it as the signal; the console takes it as typing, each newline an
-- Enter -- so a pasted script runs line by line, like in a terminal.
local function paste(text)
  local target = focusedProcess()
  if target then
    deliverEvent(target, {"clipboard", text})
    return
  end
  text = text:gsub("\r\n?", "\n")
  local held = {heldKeys[0], heldKeys[KEYS.ENTER]}
  local function feed(c)
    if c == 10 then handleKeyDown(13, KEYS.ENTER) elseif c >= 32 then handleKeyDown(c, 0) end
  end
  if utf8.len(text) then
    for _, c in utf8.codes(text) do feed(c) end
  else
    for i = 1, #text do feed(text:byte(i)) end
  end
  heldKeys[0], heldKeys[KEYS.ENTER] = held[1], held[2]
end

local function handleKeyUp(char, code)
  heldKeys[code] = nil
  if code == KEYS.C or not (isControlDown() and isAltDown()) then
    comboPressedAt = nil
  end
  local target = focusedProcess()
  if target then deliverEvent(target, {"key_up", char, code}) end
end

local function handleScroll(x, y, direction)
  local target = focusedProcess()
  if target then
    deliverEvent(target, {"scroll", x, y, direction})
  else
    -- Mouse wheel over the screen: positive direction is up.
    scrollConsole((direction or 0) > 0 and 3 or -3)
  end
end

-- --- Touch: window decorations and pointer input (gmux's touch_event) ---
--
-- A touch focuses and raises the window under it. On the title bar it
-- hits a button (minimize, maximize, close -- close also kills the
-- owner process, as in gmux) or starts a move that following drags
-- carry out; on a resizable window's bottom-right body cell it starts a
-- resize. Anything else reaches the window's owner process as
-- {"touch"/"drag"/"drop", x, y, button} in the body's own coordinates.
-- A resized window's owner gets {"window_resized", id, width, height}.
-- Nothing here while one owner has the whole screen.
local currentGrab = nil

local function windowProcess(win)
  return win.ownerJobId and K.liveJob(win.ownerJobId)
end

local function notifyResized(win)
  local job = windowProcess(win)
  if job then deliverEvent(job, {"window_resized", win.id, win.width, win.height}) end
end

local function closeWindow(win)
  -- The console can't go away: closing it minimizes it.
  if consoleWin and win.id == consoleWin.id then compositor.minimize(win.id, true) return end
  -- A program's window: gone everywhere, and its program with it.
  if win.ownerJobId and K.closeWindow(win.id) then return end
  compositor.close(win.id)
end

-- A program window moved or changed size here: the registry keeps its
-- place, for wherever it's shown next.
local function noteGeometry(win)
  if win.ownerJobId then K.windowGeometry(win.id, win.x, win.y, win.width, win.height) end
end

-- --- The desktop: gmux's -- a background and a column of app icons ---
--
-- A full-screen text window on the lowest layer, under the console and
-- every other window. Its icons are the console and every program in
-- /bin and /usr/bin (.mxe preferred over .lua, like the launcher);
-- touching one starts it, as if typed at the console with a trailing
-- "&" (a legacy program gets its own terminal window). Rebuilt at boot
-- and on `comp`, so newly installed programs appear.
local desktop = {apps = {}, ICON_W = 9, ICON_H = 5, -- 4 rows of art, then the name
  ART = {"/-------\\", "| -|... |", "|- | ...|", "\\-------/"}}
do
  local okDepth, depth = pcall(function() return gpu and gpu.getDepth() end)
  desktop.mono = okDepth and depth == 1
  -- gmux's colors: background, icon art (its "secondary"), text.
  desktop.colors = desktop.mono and {bg = 0x000000, art = 0xFFFFFF, text = 0xFFFFFF, accent = 0xFFFFFF}
    or {bg = 0x444444, art = 0xFF8844, text = 0xFFFFFF, accent = 0x44FFFF}
  desktop.win = gpu and compositor.createWindow({title = "desktop", x = 1, y = 1, width = termW, height = termH,
    layer = -2000, text = true, decorated = false, bg = desktop.colors.bg, fg = desktop.colors.text}) or nil
end

function desktop.perColumn()
  return math.max(1, math.floor((termH - 3) / (desktop.ICON_H + 1))) -- above the taskbar
end

-- A text cell-width-exact: cut or padded (centered) to `width` columns.
function desktop.fit(text, width, center)
  text = tostring(text or "")
  local len = utf8.len(text) or #text
  if len > width then
    return text:sub(1, (utf8.offset(text, width + 1) or (width + 1)) - 1)
  end
  local pad = width - len
  local left = center and pad // 2 or 0
  return (" "):rep(left) .. text .. (" "):rep(pad - left)
end

-- The apps: the console, and every program in /bin and /usr/bin, with
-- its icon if it has one (K.apps: an .mxe header's `icon`/`icon_color`,
-- or a <name>.icon file), fitted to the desktop's icon size.
function desktop.scan()
  local apps = {{name = "console", console = true}}
  for _, app in ipairs(K.apps()) do
    local icon
    if type(app.art) == "table" and #app.art > 0 then
      icon = {rows = {}, colors = {}}
      for i = 1, 4 do
        icon.rows[i] = desktop.fit(app.art[i], desktop.ICON_W, true)
        local c = type(app.color) == "table" and app.color[i] or app.color
        icon.colors[i] = (not desktop.mono and math.type(c) == "integer") and c or nil
      end
    end
    apps[#apps + 1] = {name = app.name, path = app.path, icon = icon}
  end
  desktop.apps = apps
end

-- Rows of colored spans, from {x, text, fg} pieces placed on each row.
function desktop.spans(width, placed)
  table.sort(placed, function(a, b) return a[1] < b[1] end)
  local row, col = {}, 1
  for _, piece in ipairs(placed) do
    if piece[1] > col then row[#row + 1] = {(" "):rep(piece[1] - col)} col = piece[1] end
    row[#row + 1] = {piece[2], piece[3], piece[4]}
    col = col + (utf8.len(piece[2]) or #piece[2])
  end
  if col <= width then row[#row + 1] = {(" "):rep(width - col + 1)} end
  return row
end

-- --- Wallpaper: a PPM image (P3 or P6), stretched over the screen in
-- half-block cells (kernal/bitmap.lua) behind the icons. `wallpaper
-- <file.ppm>` sets it (remembered in /etc/wallpaper), `wallpaper none`
-- clears it.
desktop.bitmap = loadSibling("bitmap.lua")()
desktop.WALLPAPER_CONFIG = "/etc/wallpaper"
desktop.MAX_WALLPAPER = 1024 * 1024

-- A PPM image: width, height and pixel(x, y) -> 0xRRGGBB, or nil and why.
function desktop.readPPM(data)
  local pos, fields = 1, {}
  while #fields < 4 do
    local token, nextPos = data:match("^%s*([^%s#]+)()", pos)
    if not token then
      local comment = data:match("^%s*#[^\n]*\n()", pos)
      if not comment then return nil, "not a PPM image (bad header)" end
      pos = comment
    else
      fields[#fields + 1], pos = token, nextPos
    end
  end
  local magic, w, h, maxval = fields[1], tonumber(fields[2]), tonumber(fields[3]), tonumber(fields[4])
  if (magic ~= "P6" and magic ~= "P3") or not w or not h or not maxval or w < 1 or h < 1 or maxval < 1 or maxval > 255 then
    return nil, "not a PPM image (only P3/P6 with 8-bit colors)"
  end
  local scale = 255 / maxval
  local function rgb(r, g, b)
    return (math.floor(r * scale) << 16) | (math.floor(g * scale) << 8) | math.floor(b * scale)
  end
  if magic == "P6" then
    local start = pos + 1 -- one whitespace byte ends the header
    if #data < start + w * h * 3 - 1 then return nil, "the image is cut short" end
    return w, h, function(x, y)
      local i = start + ((y - 1) * w + (x - 1)) * 3
      return rgb(data:byte(i), data:byte(i + 1), data:byte(i + 2))
    end
  end
  local values = {}
  for n in data:sub(pos):gmatch("%d+") do values[#values + 1] = tonumber(n) end
  if #values < w * h * 3 then return nil, "the image is cut short" end
  return w, h, function(x, y)
    local i = ((y - 1) * w + (x - 1)) * 3
    return rgb(values[i + 1], values[i + 2], values[i + 3])
  end
end

-- The wallpaper's cells for this screen, or nil and why.
function desktop.wallpaperCells(path)
  local size = K.fileSize(path)
  if not size then return nil, path .. ": no such file" end
  if size > desktop.MAX_WALLPAPER then return nil, path .. ": too big (1 MB at most)" end
  local data = K.readFile(path)
  if not data then return nil, path .. ": can't read it" end
  local w, h, pixel = desktop.readPPM(data)
  if not w then return nil, path .. ": " .. tostring(h) end
  local pw, ph = termW, termH * 2
  local pixels = {}
  for y = 1, ph do
    local row, sy = {}, math.floor((y - 1) * h / ph) + 1
    for x = 1, pw do row[x] = pixel(math.floor((x - 1) * w / pw) + 1, sy) end
    pixels[y] = row
  end
  return (desktop.bitmap.encode("halfblock", pixels, pw, ph, desktop.colors.bg))
end

function desktop.loadWallpaper()
  desktop.wall = nil
  local config = K.readFile(desktop.WALLPAPER_CONFIG)
  local path = config and config:match("^%s*(.-)%s*$")
  if not path or path == "" then return end
  local cells, err = desktop.wallpaperCells(path)
  if cells then desktop.wall = cells else print("wallpaper: " .. tostring(err)) end
end

function desktop.render()
  if not desktop.win then return end
  local W, H, C = desktop.ICON_W, desktop.ICON_H, desktop.colors
  -- The background: the wallpaper's cells, or the plain color.
  local grid = {}
  for y = 1, termH do
    local row, wall = {}, desktop.wall and desktop.wall[y]
    for x = 1, termW do
      local cell = wall and wall[x]
      row[x] = cell and {cell.char, cell.fg, cell.bg} or {" ", C.text, C.bg}
    end
    grid[y] = row
  end
  -- The icons, each on a tile of the desktop's color.
  local per = desktop.perColumn()
  local function put(x, y, text, fg)
    if not grid[y] then return end
    local i = 0
    for _, code in utf8.codes(text) do
      local cell = grid[y][x + i]
      if cell then cell[1], cell[2], cell[3] = utf8.char(code), fg, C.bg end
      i = i + 1
    end
  end
  for i, app in ipairs(desktop.apps) do
    local x, y = 2 + (i - 1) // per * (W + 1), 2 + (i - 1) % per * (H + 1)
    if x + W - 1 <= termW then
      for j = 1, 4 do
        put(x, y + j - 1, app.icon and app.icon.rows[j] or desktop.ART[j], app.icon and app.icon.colors[j] or C.art)
      end
      put(x, y + 4, desktop.fit(app.name, W, true), C.text)
    end
  end
  -- Rows of spans: runs of cells sharing their colors.
  local rows = {}
  for y = 1, termH do
    local spans, row, x = {}, grid[y], 1
    while x <= termW do
      local fg, bg, chars = row[x][2], row[x][3], {}
      while x <= termW and row[x][2] == fg and row[x][3] == bg do
        chars[#chars + 1] = row[x][1]
        x = x + 1
      end
      spans[#spans + 1] = {table.concat(chars), fg, bg}
    end
    rows[y] = spans
  end
  compositor.setText(desktop.win.id, rows)
end

function desktop.refresh()
  desktop.scan()
  desktop.loadWallpaper()
  desktop.render()
end

-- The `wallpaper` command: <file.ppm> sets it, `none` clears it.
function desktop.setWallpaper(arg)
  if not arg or arg == "" then
    local config = K.readFile(desktop.WALLPAPER_CONFIG)
    print("wallpaper: " .. (config and config:match("^%s*(.-)%s*$") or "none")
      .. "  (wallpaper <file.ppm> | wallpaper none)")
    return
  end
  if arg == "none" then
    K.writeFile(desktop.WALLPAPER_CONFIG, nil)
    desktop.wall = nil
    desktop.render()
    print("wallpaper cleared")
    return
  end
  local path = arg
  if path:sub(1, 1) ~= "/" then path = S.cwd() .. "/" .. path end
  local cells, err = desktop.wallpaperCells(path)
  if not cells then print("wallpaper: " .. tostring(err)) return end
  K.writeFile(desktop.WALLPAPER_CONFIG, path .. "\n")
  desktop.wall = cells
  desktop.render()
  print("wallpaper: " .. path)
end

function desktop.showConsole()
  if not consoleWin then return end
  local win = compositor.getWindow(consoleWin.id)
  if win and win.minimized then compositor.minimize(consoleWin.id, false) end
  compositor.raise(consoleWin.id)
  compositor.setFocus(consoleWin.id)
  consoleDirty = true
end

-- Starts an app from the desktop, the start menu or the taskbar.
function desktop.launch(app)
  if app.console then desktop.showConsole() return end
  local id, addrOrErr = launchProgram(app.path, {})
  if id == true then return end -- asked; the kernal reports how it went
  if id then
    print("[" .. id .. "] " .. app.path .. " started on " .. addrOrErr)
  else
    print("error: " .. tostring(addrOrErr))
  end
end

-- A touch on the desktop: the icon under it, if any, starts.
function desktop.touch(lx, ly)
  local W, H, per = desktop.ICON_W, desktop.ICON_H, desktop.perColumn()
  local col, colOff = (lx - 2) // (W + 1), (lx - 2) % (W + 1)
  local row, rowOff = (ly - 2) // (H + 1), (ly - 2) % (H + 1)
  if lx < 2 or ly < 2 or colOff >= W or rowOff >= H or row >= per then return end
  local app = desktop.apps[col * per + row + 1]
  if app then desktop.launch(app) end
end

-- --- The taskbar: a start button, a button per window, and a clock ---
--
-- The bottom row, above every window. Touching a window's button
-- restores and raises it -- or minimizes it, if it's already the
-- focused window on top. The start button opens a menu of every app
-- (the desktop's icons can be covered by windows).
desktop.bar = {buttons = {}, signature = nil, nextCheck = 0}
desktop.bar.win = gpu and compositor.createWindow({title = "taskbar", x = 1, y = termH, width = termW, height = 1,
  layer = 3000, text = true, decorated = false, bg = 0x222222, fg = 0xFFFFFF}) or nil
-- (A new window takes the focus: the console has it at boot.)
if consoleWin then compositor.setFocus(consoleWin.id) end

-- The taskbar's windows: this screen's, then the user's programs'
-- windows shown elsewhere or nowhere (`away`; touching one brings it
-- here) -- a user's running programs are on every one of their taskbars.
function desktop.bar.windows()
  local list, here = {}, {}
  for _, w in ipairs(compositor.listWindows()) do
    if w.id ~= (desktop.win and desktop.win.id) and w.id ~= (desktop.bar.win and desktop.bar.win.id)
        and w.id ~= (desktop.menu and desktop.menu.id) then
      list[#list + 1] = w
      here[w.id] = true
    end
  end
  for _, w in ipairs(S.user and K.userWindows(S.user) or {}) do
    if not here[w.id] and not w.status then
      w.away = true
      list[#list + 1] = w
    end
  end
  table.sort(list, function(a, b) return a.id < b.id end)
  return list
end

-- The user's windows changed somewhere: redraw the taskbar soon.
function S.windowsChanged() desktop.bar.nextCheck = 0 end

-- Brings one of the user's windows here from wherever it is.
local function fetchWindow(id)
  local ok, err = K.attachWindow(id, S)
  if not ok then print("can't bring window " .. id .. " here: " .. tostring(err)) return end
  desktop.bar.show(id)
end

function desktop.bar.render(list)
  local C, focus = desktop.colors, compositor.getFocus()
  local okClock, clock = pcall(os.date, "%H:%M")
  if not okClock or type(clock) ~= "string" then
    local t = math.floor(computer.uptime())
    clock = string.format("%d:%02d", t // 3600, t // 60 % 60)
  end
  clock = " " .. clock .. " "
  local placed, buttons = {}, {}
  local start = desktop.mono and "[muxos]" or " \u{2261} muxos "
  placed[#placed + 1] = {1, start, desktop.mono and 0xFFFFFF or 0x000000, desktop.mono and 0x000000 or C.accent}
  buttons[#buttons + 1] = {from = 1, to = utf8.len(start), start = true}
  local x, limit = utf8.len(start) + 2, termW - #clock
  -- Every window gets a button: titles shrink (14 characters down to 3)
  -- until all fit; past that, a "+N" button lists the rest in a menu.
  local room, title = limit - x + 2, 14 -- a button is title + 2 spaces + 1 gap
  while title > 3 and #list * (title + 3) > room do title = title - 1 end
  local shown, more = #list, nil
  if #list * (title + 3) > room then
    more = " +" .. #list .. " "
    shown = math.max(0, (room - #more - 1) // (title + 3))
    more = " +" .. (#list - shown) .. " "
  end
  for i = 1, shown do
    local w = list[i]
    local label = " " .. desktop.fit(w.title, math.min(title, utf8.len(w.title) or #w.title)) .. " "
    local width = utf8.len(label) or #label
    local fg, bg = 0xFFFFFF, 0x555555
    if w.away then
      fg, bg = 0x88AAFF, 0x222244 -- running, shown elsewhere or nowhere
    elseif w.minimized then
      fg, bg = 0x999999, 0x333333
    elseif focus and focus.id == w.id then
      fg, bg = 0x000000, 0xFFFFFF
    end
    if desktop.mono then fg, bg = 0xFFFFFF, 0x000000 end
    placed[#placed + 1] = {x, label, fg, bg}
    buttons[#buttons + 1] = {from = x, to = x + width - 1, window = w.id, away = w.away}
    x = x + width + 1
  end
  if more then
    placed[#placed + 1] = {x, more, 0x000000, desktop.mono and 0xFFFFFF or C.accent}
    buttons[#buttons + 1] = {from = x, to = x + #more - 1, more = true}
  end
  placed[#placed + 1] = {termW - #clock + 1, clock, 0xFFFFFF, nil}
  desktop.bar.buttons = buttons
  compositor.setText(desktop.bar.win.id, {desktop.spans(termW, placed)})
end

-- Redraws the bar when its windows, focus or the clock changed --
-- checked at most twice a second, from tick(), or at once when forced.
function desktop.bar.update(force)
  if not desktop.bar.win or compositor.exclusiveOwner() then return end
  local now = computer.uptime()
  if not force and now < desktop.bar.nextCheck then return end
  desktop.bar.nextCheck = now + 0.5
  local list = desktop.bar.windows()
  local focus = compositor.getFocus()
  local parts = {focus and focus.id or 0, math.floor(now / 30)}
  for _, w in ipairs(list) do parts[#parts + 1] = w.id .. w.title .. tostring(w.minimized) .. tostring(w.away) end
  local okClock, clock = pcall(os.date, "%H:%M")
  parts[#parts + 1] = okClock and tostring(clock) or ""
  local signature = table.concat(parts, "|")
  if force or signature ~= desktop.bar.signature then
    desktop.bar.signature = signature
    desktop.bar.render(list)
  end
end

-- Shows a window: restored if minimized, raised, focused.
function desktop.bar.show(id)
  local win = compositor.getWindow(id)
  if not win then return end
  if win.minimized then compositor.minimize(id, false) end
  compositor.raise(id)
  compositor.setFocus(id)
end

function desktop.bar.touch(lx)
  for _, b in ipairs(desktop.bar.buttons) do
    if lx >= b.from and lx <= b.to then
      if b.start then
        desktop.toggleMenu()
      elseif b.more then
        -- Every window, by title; touching one shows it.
        local items = {}
        for _, w in ipairs(desktop.bar.windows()) do
          local id = w.id
          items[#items + 1] = {label = w.title .. (w.minimized and " (minimized)" or "")
            .. (w.away and " (elsewhere)" or ""),
            action = function() if w.away then fetchWindow(id) else desktop.bar.show(id) end end}
        end
        desktop.toggleMenu(items, b.from)
      elseif b.away then
        fetchWindow(b.window)
      else
        local win = compositor.getWindow(b.window)
        local focus = compositor.getFocus()
        local top -- the topmost ordinary window showing
        for _, w in ipairs(compositor.listWindows()) do
          if w.id ~= desktop.bar.win.id and w.id ~= (desktop.menu and desktop.menu.id) and not w.minimized then
            top = w
            break
          end
        end
        if win then
          if not win.minimized and focus and focus.id == win.id and top and top.id == win.id then
            compositor.minimize(win.id, true)
          else
            desktop.bar.show(win.id)
          end
        end
      end
      break
    end
  end
  desktop.bar.update(true)
end

-- A menu above the taskbar, one item per row: the start menu (every
-- app) by default, or the given items ({label, action}) at column x.
-- Open already: closes it instead.
function desktop.toggleMenu(items, x)
  if desktop.menu then
    compositor.close(desktop.menu.id)
    desktop.menu, desktop.menuItems = nil, nil
    return
  end
  if not items then
    items = {}
    for _, app in ipairs(desktop.apps) do
      items[#items + 1] = {label = app.name, action = function() desktop.launch(app) end}
    end
  end
  if #items == 0 then return end
  local rows, width = {}, 8
  for _, item in ipairs(items) do width = math.max(width, (utf8.len(item.label) or #item.label) + 2) end
  width = math.min(width, termW)
  local height = math.min(#items, termH - 2)
  for i = 1, height do rows[i] = " " .. desktop.fit(items[i].label, width - 1) end
  local focus = compositor.getFocus()
  desktop.menu = compositor.createWindow({title = "menu", x = math.max(1, math.min(x or 1, termW - width + 1)),
    y = termH - height, width = width, height = height,
    layer = 2900, text = true, decorated = false, bg = 0xFFFFFF, fg = 0x000000})
  if focus then compositor.setFocus(focus.id) end -- the menu doesn't take it
  if desktop.menu then
    desktop.menuItems = items
    compositor.setText(desktop.menu.id, rows)
  end
end

function desktop.menuTouch(ly)
  local item = desktop.menuItems and desktop.menuItems[ly]
  desktop.toggleMenu()
  if item then item.action() end
  desktop.bar.update(true)
end

local function handleTouch(name, x, y, button)
  if compositor.exclusiveOwner() then currentGrab = nil return end
  if currentGrab then
    local grab = currentGrab
    local win = compositor.getWindow(grab.id)
    if name == "drop" or not win then currentGrab = nil return end
    if name == "drag" then
      if grab.kind == "move" then
        compositor.move(win.id, x - grab.dx, y)
        noteGeometry(win)
      else
        local w = math.max(UI.MIN_WINDOW_WIDTH, x - win.x + 1)
        local h = math.max(1, y - compositor.bodyTop(win) + 1)
        if (w ~= win.width or h ~= win.height) and compositor.resize(win.id, w, h) then
          notifyResized(win)
          noteGeometry(win)
        end
      end
      return
    end
    currentGrab = nil -- a fresh touch ends the grab and is handled below
  end
  local win, part, lx, ly = compositor.hitTest(x, y)
  if not win then return end
  if desktop.menu and win.id ~= desktop.menu.id and name == "touch" then desktop.toggleMenu() end
  if desktop.menu and win.id == desktop.menu.id then
    if name == "touch" then desktop.menuTouch(ly) end
    return
  end
  if desktop.bar.win and win.id == desktop.bar.win.id then
    if name == "touch" then desktop.bar.touch(lx) end
    return
  end
  if desktop.win and win.id == desktop.win.id then
    if name == "touch" then desktop.touch(lx, ly) end
    return
  end
  if name == "touch" then
    compositor.setFocus(win.id)
    compositor.raise(win.id)
  end
  if part == "title" then
    if name ~= "touch" then return end
    local w = win.width
    if lx == w - 5 or lx == w - 4 then
      compositor.minimize(win.id)
    elseif (lx == w - 3 or lx == w - 2) and win.resizable then
      if compositor.maximize(win.id) then
        notifyResized(win)
        noteGeometry(win)
      end
    elseif lx == w - 1 or lx == w then
      closeWindow(win)
    else
      currentGrab = {id = win.id, kind = "move", dx = lx - 1}
    end
    return
  end
  if name == "touch" and win.resizable and win.decorated and lx == win.width and ly == win.height then
    currentGrab = {id = win.id, kind = "resize"}
    return
  end
  local job = windowProcess(win)
  if job then deliverEvent(job, {name, lx, ly, button}) end
end

-- Input from this session's screen and keyboard -- the kernal's own
-- signals, or a terminal's messages -- as OpenComputers' signal name and
-- the arguments after the screen/keyboard address.
function S.input(name, a, b, c)
  if name == "key_down" then
    handleKeyDown(a, b)
  elseif name == "key_up" then
    handleKeyUp(a, b)
  elseif name == "scroll" then
    handleScroll(a, b, c)
  elseif name == "clipboard" and type(a) == "string" then
    paste(a)
  elseif name == "touch" or name == "drag" or name == "drop" then
    handleTouch(name, a, b, c)
  end
end

-- Once per kernal tick: the Ctrl+Alt+C hold, then drawing.
function S.update()
  if comboPressedAt and not comboHoldFired and heldKeys[KEYS.C] and isControlDown() and isAltDown()
      and computer.uptime() - comboPressedAt >= UI.CONSOLE_HOLD_SECONDS then
    comboHoldFired = true
    consoleInterrupt()
  end
  renderConsole()
  desktop.bar.update()
  compositor.flush()
  if opts.flushed then opts.flushed(S) end
end


-- A program runs in the foreground (K.runForeground): the console
-- waits for it, feeding it typed input meanwhile, like an OpenOS shell.
function S.beginForeground(id)
  S.foregroundJob, foregroundTyped = id, ""
end
function S.endForeground()
  S.foregroundJob = nil
  if consolePartial ~= "" then
    consoleAppend(consolePartial)
    consolePartial = ""
  end
end
function S.consoleWidth() return (viewSize()) end
function S.clearConsole()
  for i = #consoleLines, 1, -1 do consoleLines[i] = nil end
  scrollOffset, consoleDirty = 0, true
end


-- Generates a small test pattern (a filled diamond, red center ring,
-- blue outer ring, transparent corners) so `bitdemo` has something
-- visually meaningful to draw without requiring anyone to type a pixel
-- grid by hand at the REPL.
local function demoPixels(size)
  local pixels = {}
  local center = (size + 1) / 2
  for y = 1, size do
    pixels[y] = {}
    for x = 1, size do
      local dist = math.abs(x - center) + math.abs(y - center)
      if dist < size / 4 then
        pixels[y][x] = 0xff0000 -- red center
      elseif dist < size / 2 then
        pixels[y][x] = 0x0000ff -- blue ring
      else
        pixels[y][x] = nil -- transparent corners
      end
    end
  end
  return pixels
end

local function printWindows()
  local list = compositor.listWindows()
  if #list == 0 then
    print("no windows created yet")
    return
  end
  local focus = compositor.getFocus()
  for _, win in ipairs(list) do
    local tags = ""
    if focus and win.id == focus.id then tags = tags .. " (focused)" end
    if win.ownerJobId then tags = tags .. " (owner job " .. win.ownerJobId .. ")" end
    if win.minimized then tags = tags .. " (minimized)" end
    if win.maximized then tags = tags .. " (maximized)" end
    if win.status then tags = tags .. " (process " .. win.status .. ")" end
    print(string.format("[%d] %q  %dx%d at (%d,%d)%s", win.id, win.title, win.width, win.height, win.x, win.y, tags))
  end
end


-- --- The shell and logins ---

-- The working directory: the shell's, else home.
function S.cwd()
  return shell and shell.cwd() or S.remoteCwd or (S.user and system.home(S.user)) or "/"
end

-- A shell line: POSIX-style commands, pipes and redirection, programs
-- (kernal/shell.lua). Each login gets a fresh shell.
function S.shellRun(line)
  if shell then shell.run(line) else print("no shell -- run `update` with the installer floppy in") end
end

-- Says why this session's user may not do something a flag reserves
-- for root, and returns true; nothing (nil) if they may.
function S.deny(flagName, doing)
  local ok, why = system.allowed(S.user, flagName, doing)
  if not ok then print(why) return true end
end

-- The login screen: the console alone, asking for a user name.
function S.showLogin()
  local fullscreen = K.fullscreen
  if S.kind == "local" and fullscreen.node then fullscreen.node, fullscreen.job = nil, nil end
  compositor.setExclusive("console")
  if consoleWin then compositor.setFocus(consoleWin.id) end
  print("muxos " .. K.MUXOS_VERSION .. " -- " .. tostring(K.selfAddr)
    .. (S.kind == "terminal" and (" (terminal " .. tostring(S.address):sub(1, 8) .. ")") or ""))
  print("Log in with your user name (no password).")
  scrollOffset, consoleDirty = 0, true
end

function S.startSession(name)
  S.user, S.login = name, K.nextLogin()
  shell = K.newShell(S, name)
  editor = K.lineedit.new()
  if compositor.exclusiveOwner() == "console" then compositor.setExclusive(nil) end
  desktop.refresh()
  desktop.showConsole()
  print("logged in as " .. name .. " (home " .. system.home(name) .. ") -- type 'help' for commands")
  consoleDirty = true
end

-- At the login: prompt, a typed line is a user name.
function S.loginLine(line)
  local name = (line or ""):match("^%s*(.-)%s*$")
  if name == "" then return end
  if not system.userExists(name) then
    print("no such user: " .. name)
    return
  end
  S.startSession(name)
end

-- Ends the login: its processes (flag logout_ends_jobs; never a
-- persistent one's), its programs' windows (detached: still running,
-- they wait for the user's next session), the console's contents; back
-- to login:.
function S.logout()
  K.endLogin(S)
  for _, w in ipairs(compositor.listWindows()) do
    local own = w.id == (consoleWin and consoleWin.id) or w.id == (desktop.win and desktop.win.id)
      or w.id == (desktop.bar.win and desktop.bar.win.id)
    local job = w.ownerJobId and jobs[w.ownerJobId]
    if not own and not (job and job.status == "running" and not job.loggedOut) then compositor.close(w.id) end
  end
  if desktop.menu then desktop.toggleMenu() end
  S.user = nil
  shell = nil
  editor = K.lineedit.new()
  for i = #consoleLines, 1, -1 do consoleLines[i] = nil end
  S.showLogin()
end

-- The session's own commands -- its console, windows and desktop.
-- Returns true if `line` was one of them.
function S.command(line)
  if line == "exit" or line == "logout" then
    S.logout()
  elseif line == "wallpaper" or line:match("^wallpaper%s") then
    desktop.setWallpaper(line:match("^wallpaper%s+(.-)%s*$"))
  elseif line:match("^window%s") then
    local title, x, y, w, h, code = line:match("^window%s+(%S+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(.*)$")
    if not title then
      print("usage: window <title> <x> <y> <width> <height> <lua code drawing into `gpu`>")
    else
      local win, err = compositor.createWindow({title = title, x = tonumber(x), y = tonumber(y),
        width = tonumber(w), height = tonumber(h), code = code})
      if err then print("error: " .. err) else print("created window [" .. win.id .. "]") end
    end
  elseif line == "windows" then
    printWindows()
  elseif line:match("^console%s") then
    local w, h, x, y = line:match("^console%s+(%d+)%s+(%d+)%s*(%d*)%s*(%d*)$")
    w, h, x, y = tonumber(w), tonumber(h), tonumber(x), tonumber(y)
    if not w then
      print("usage: console <width> <height> [x y]  (default: docked bottom-left)")
    elseif w < CONSOLE_MIN_W or h < CONSOLE_MIN_H or w > termW or h > termH - 2 then
      print(string.format("console size must be between %dx%d and %dx%d", CONSOLE_MIN_W, CONSOLE_MIN_H, termW, termH - 2))
    else
      -- y is the title bar's row; the text is below it, above the taskbar.
      x, y = x or 1, y or (termH - h - 1)
      if x + w - 1 > termW or y + h > termH - 1 then
        print("that doesn't fit on the screen")
      else
        compositor.setGeometry(consoleWin.id, x, y, w, h)
        consoleW, consoleH = w, h
        setScroll(scrollOffset)
        consoleDirty = true
        print(string.format("console is now %dx%d at (%d,%d)", w, h, x, y))
      end
    end
  elseif line == "comp" then
    -- Back to normal compositing from console mode -- never taking the
    -- screen from a node holding the fullscreen grant.
    if consoleOwnsScreen() then compositor.setExclusive(nil) end
    scrollOffset = 0
    consoleDirty = true
    desktop.refresh()
    print("desktop restored -- all windows shown")
  elseif line:match("^focus%s") then
    local idStr = line:match("^focus%s+(%d+)$")
    if not idStr then
      print("usage: focus <window id>")
    else
      local ok, err = compositor.setFocus(tonumber(idStr))
      if ok then print("window [" .. idStr .. "] focused") else print("error: " .. err) end
    end
  elseif line:match("^bitdemo%s") then
    local mode, x, y = line:match("^bitdemo%s+(%S+)%s+(%d+)%s+(%d+)$")
    if not mode or (mode ~= "halfblock" and mode ~= "braille") then
      print("usage: bitdemo <halfblock|braille> <x> <y>")
    else
      local win, err = compositor.createWindow({title = "bitdemo", x = tonumber(x), y = tonumber(y),
        pixels = demoPixels(16), width = 16, height = 16, mode = mode, bg = 0x000000})
      if err then print("error: " .. err) else print("created bit window [" .. win.id .. "] (" .. win.width .. "x" .. win.height .. " cells)") end
    end
  else
    return false
  end
  return true
end

-- Whether a window is one of the session's own (console, desktop,
-- taskbar, menu) rather than a program's.
function S.ownWindow(id)
  return id == (consoleWin and consoleWin.id) or id == (desktop.win and desktop.win.id)
    or id == (desktop.bar.win and desktop.bar.win.id) or id == (desktop.menu and desktop.menu.id)
end

-- The console in console mode (the local session's Ctrl+Alt+C, or the
-- fullscreen grant ending) needs a full redraw.
function S.redraw() consoleDirty = true end

return S
