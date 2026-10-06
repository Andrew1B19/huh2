-- muxos compositor. This is, BY CONSTRUCTION, the only file in this
-- entire project that ever makes a real gpu.* call. "Only the display
-- node actually needs to make those budgeted calls for real" (see
-- docs/PROTOCOL.md's call-budget section: every GPU method is a
-- per-tick-budgeted `direct` call in OC's own source) -- centralizing
-- every real draw call here, instead of leaving them scattered across
-- muxos.lua, is what makes that true rather than just asserted.
--
-- The z-order/occlusion-culling/dirty-tracking model below is adapted
-- from gmux's real one (gmux/lib/gmux/frontend/graphics.lua's Block/
-- get_boxes/subtract_rectangle) -- not a port of its live vgpu-source
-- polling (`need_copy()` asking a virtual gpu "has anything drawn into
-- you changed since last copy", which assumes an app sharing this Lua
-- state; our windows are one-shot draws from code, possibly dispatched
-- over the network, so "dirty" here just means "drawn since last
-- flush", set once by createWindow rather than polled continuously).
-- Window decorations (title bar, minimize/maximize/close, title-drag
-- moving, corner resizing) are copied from gmux's windows.lua -- see
-- "Decorations" below; muxos.lua turns touch signals into calls here.
-- What this gives: allocate a GPU buffer per window, let code
-- draw into it, composite every dirty, unoccluded window into one
-- persistent frame buffer, and flip that onto the real screen with a
-- SINGLE bitblt -- at most once per flush() call, which muxos.lua calls
-- at most once per tick from its background dispatcher thread, not once
-- per window. This is the actual implementation of "only the display
-- node makes those budgeted calls for real, and batches them
-- responsibly" rather than each window touching the real screen on its
-- own.
--
-- muxos replaces OpenOS on the kernal entirely -- there is no
-- require(), no dofile(), no debug.getinfo-based script path (this
-- whole file is loaded from a plain string by kernal/muxos.lua's own
-- loadSibling(), under a synthetic chunk name, not a real path). The
-- native `component` global (list/type/slot/methods/invoke/doc, see
-- ComponentAPI.scala) is already visible here with no require needed
-- -- it's a real Lua global, not something sandboxed per-module.
--
-- `loadSibling`, the one piece of context muxos.lua passes in as this
-- chunk's own `...`, is how this file reads bitmap.lua off the same
-- boot filesystem muxos.lua itself was loaded from -- same mechanism,
-- duplicated rather than shared (same "both sides keep their own copy"
-- reasoning as the wire-protocol serializer in node/runtime.lua and
-- kernal/muxos.lua).
local loadSibling = ...
local bitmap = loadSibling("bitmap.lua")()

-- Our OWN tiny component-proxy helper -- NOT OpenOS's
-- component.proxy()/dot-shorthand sugar (confirmed absent from
-- ComponentAPI.scala's native surface: only list/type/slot/methods/
-- invoke/doc are real), but the same calling convention, built from
-- the real primitive (component.invoke) so the rest of this file can
-- keep writing gpu.set(...)/gpu.allocateBuffer(...) instead of
-- component.invoke(addr, "set", ...) everywhere. Duplicated from
-- kernal/muxos.lua's own copy for the same "no shared module to
-- require" reason as everywhere else in this project.
local function componentProxy(address)
  return setmetatable({address = address}, {
    __index = function(_, method)
      return function(...) return component.invoke(address, method, ...) end
    end,
  })
end

local function primaryComponent(ctype)
  local address = component.list(ctype)()
  if not address then return nil end
  return componentProxy(address), address
end

local M = {}

-- id -> {id, title, x, y, width, height, buffer, layer, dirty, ownerJobId}
local windows = {}
local windowOrder = {} -- ids in Z-ORDER, index 1 = TOPMOST (matches gmux's convention)
local nextWindowId = 1

-- Scaffolding for focus-based keyboard delivery (see docs/PROTOCOL.md's
-- ".mxe hardware access model" -- the design calls for the kernal to
-- send keyboard updates straight to whichever .mxe job currently has
-- focus, instead of through a virtual keyboard component). This is
-- ONLY the tracking half: which window is focused, and which job (if
-- any) owns it. Nothing actually forwards a key_down signal anywhere
-- yet -- kernal/muxos.lua's handleKeyDown still only ever feeds the
-- kernal's own REPL input buffer. That wiring is the next step, not
-- this one, and needs this tracking to already exist first.
local focusedId = nil

-- The compositor's special mode: while set, ONE owner has the real
-- screen to itself and compositing stops entirely -- either the
-- kernal's console (Ctrl+Alt+C; it draws straight onto the screen via
-- M.drawDirect, so it needs no full-screen buffer of its own) or a node
-- holding the fullscreen grant. Clearing it rebuilds the composited
-- picture from the window buffers.
local exclusiveOwner = nil

-- Persistent off-screen surface the whole desktop composites into
-- before any real screen write. Allocated lazily (first window/flush),
-- sized to the screen's own resolution.
local frameBuffer = nil
local frameDirty = false

local function nextId()
  local id = nextWindowId
  nextWindowId = nextWindowId + 1
  return id
end

-- Resolved once: flush() runs every tick, and a fresh component.list
-- plus a new proxy each time is pure overhead for a component that
-- doesn't change while muxos is running.
local cachedGpu = nil
local function kernalGpu()
  if not cachedGpu then cachedGpu = primaryComponent("gpu") end
  return cachedGpu
end

-- The screen's own rectangle, which every window is clipped to (one
-- dragged partly off-screen must not be blitted outside the frame
-- buffer).
local screenRect = nil

local function ensureFrameBuffer(gpu)
  if frameBuffer then return frameBuffer end
  local w, h = gpu.getResolution()
  frameBuffer, _ = gpu.allocateBuffer(w, h)
  screenRect = {x = 1, y = 1, w = w, h = h}
  return frameBuffer
end

local function clipToScreen(r)
  if not screenRect then return r end
  local x1, y1 = math.max(r.x, 1), math.max(r.y, 1)
  local x2 = math.min(r.x + r.w, screenRect.w + 1)
  local y2 = math.min(r.y + r.h, screenRect.h + 1)
  return {x = x1, y = y1, w = math.max(0, x2 - x1), h = math.max(0, y2 - y1)}
end

-- --- pure geometry, no gpu calls -- adapted from gmux's graphics.lua ---

local function rectanglesOverlap(a, b)
  return not (a.x >= b.x + b.w or a.x + a.w <= b.x or a.y >= b.y + b.h or a.y + a.h <= b.y)
end

-- Cuts `blocker`'s overlap out of `rect`, returning the (0-4) remaining
-- rectangles that cover what's left.
local function subtractRectangle(rect, blocker)
  if not rectanglesOverlap(rect, blocker) then return {rect} end
  local pieces = {}
  if rect.x < blocker.x then
    pieces[#pieces + 1] = {x = rect.x, y = rect.y, w = blocker.x - rect.x, h = rect.h}
  end
  if rect.x + rect.w > blocker.x + blocker.w then
    pieces[#pieces + 1] = {x = blocker.x + blocker.w, y = rect.y,
      w = (rect.x + rect.w) - (blocker.x + blocker.w), h = rect.h}
  end
  if rect.y < blocker.y then
    local left, right = math.max(rect.x, blocker.x), math.min(rect.x + rect.w, blocker.x + blocker.w)
    if right > left then
      pieces[#pieces + 1] = {x = left, y = rect.y, w = right - left, h = blocker.y - rect.y}
    end
  end
  if rect.y + rect.h > blocker.y + blocker.h then
    local left, right = math.max(rect.x, blocker.x), math.min(rect.x + rect.w, blocker.x + blocker.w)
    if right > left then
      pieces[#pieces + 1] = {x = left, y = blocker.y + blocker.h, w = right - left,
        h = (rect.y + rect.h) - (blocker.y + blocker.h)}
    end
  end
  local kept = {}
  for _, p in ipairs(pieces) do
    if p.w > 0 and p.h > 0 then kept[#kept + 1] = p end
  end
  return kept
end

-- Characters [first, first + count - 1] of a row (UTF-8 aware, bytes
-- for invalid UTF-8).
local function textSlice(row, first, count)
  local len = utf8.len(row)
  if not len then return row:sub(first, first + count - 1) end
  if first > len then return "" end
  local from = utf8.offset(row, first)
  local to = utf8.offset(row, first + count)
  return to and row:sub(from, to - 1) or row:sub(from)
end

-- --- Decorations, copied from gmux/lib/gmux/frontend/windows.lua ---
--
-- A decorated window's x,y is its title bar; its body (width x height)
-- sits on the rows below. Same colors, glyphs and button columns as
-- gmux: minimize at w-5, maximize at w-3 (resizable windows only),
-- close at w-1, each also hit on the cell to its right (the glyphs can
-- be double-width). The title bar is painted straight into the frame
-- buffer -- no video memory of its own.
local COLORS_MONO = {title_bg = 0xFFFFFF, title_text = 0x000000, title_active = 0x000000, button = 0x000000}
local COLORS_COLOR = {title_bg = 0xFFFFFF, title_text = 0x888888, title_active = 0x000000, button = 0x4488FF}
local colors, monochrome = nil, false

local function titleColors(gpu)
  if not colors then
    local ok, depth = pcall(gpu.getDepth)
    monochrome = ok and depth == 1
    colors = monochrome and COLORS_MONO or COLORS_COLOR
  end
  return colors
end

local GLYPH_MINIMIZE = utf8.char(0x1F783)
local GLYPH_RESTORE = utf8.char(0x20DF)
local GLYPH_MAXIMIZE = utf8.char(0x2BC5)
local GLYPH_CLOSE = utf8.char(0x2716)
local GLYPH_FOCUSED = utf8.char(0x1F5AE) -- marks focus on a 1-bit screen
-- The owner process's state, gmux's process_prefix: the window stays
-- up after its process ends, marked.
local STATUS_PREFIX = {dead = utf8.char(0x23F9) .. " - ", error = utf8.char(0x274C) .. " - "}

local function titleRows(win)
  return win.decorated and 1 or 0
end

local function bodyTop(win)
  return win.y + titleRows(win)
end

-- Everything the window covers on screen: title bar plus body, or just
-- the title bar while minimized.
local function outerRect(win)
  local h = win.minimized and titleRows(win) or win.height + titleRows(win)
  return {x = win.x, y = win.y, w = win.width, h = h}
end

local function titleText(win)
  local text = (STATUS_PREFIX[win.status] or "") .. win.title
  if monochrome and focusedId == win.id then text = GLYPH_FOCUSED .. " " .. text end
  -- Leave the button columns clear.
  return textSlice(text, 1, math.max(0, win.width - 6))
end

local function titleButtons(win)
  local w = win.width
  return {
    {col = w - 5, glyph = win.minimized and GLYPH_RESTORE or GLYPH_MINIMIZE},
    win.resizable and {col = w - 3, glyph = win.maximized and GLYPH_RESTORE or GLYPH_MAXIMIZE} or nil,
    {col = w - 1, glyph = GLYPH_CLOSE},
  }
end

-- Paints the part of `win`'s title bar inside `box` (whose top row is
-- the title row) into the active buffer (the frame buffer).
local function paintTitle(gpu, win, box)
  local c = titleColors(gpu)
  gpu.setBackground(c.title_bg)
  gpu.setForeground(focusedId == win.id and c.title_active or c.title_text)
  gpu.fill(box.x, win.y, box.w, 1, " ")
  local piece = textSlice(titleText(win), box.x - win.x + 1, box.w)
  if piece ~= "" then gpu.set(box.x, win.y, piece) end
  gpu.setForeground(c.button)
  for _, b in pairs(titleButtons(win)) do
    local sx = win.x + b.col - 1
    if b.col >= 1 and sx >= box.x and sx < box.x + box.w then gpu.set(sx, win.y, b.glyph) end
  end
end

-- The visible fragments of the window at `index` in windowOrder (1 =
-- topmost): its own rectangle, with every window ABOVE it (indices
-- 1..index-1, if shown) cut out. Can return 0 pieces (fully covered),
-- 1 (unoccluded), or several (occluded on one side, e.g. by a window
-- overlapping a corner).
local function visibleBoxes(order, index)
  local win = windows[order[index]]
  local boxes = {clipToScreen(outerRect(win))}
  if boxes[1].h <= 0 or boxes[1].w <= 0 then return {} end
  for i = 1, index - 1 do
    local blockerRect = outerRect(windows[order[i]])
    local cut = {}
    for _, box in ipairs(boxes) do
      for _, piece in ipairs(subtractRectangle(box, blockerRect)) do
        cut[#cut + 1] = piece
      end
    end
    boxes = cut
    if #boxes == 0 then break end
  end
  return boxes
end

-- A text window has no gpu buffer at all: its rows live in regular
-- memory (win.textRows) and are drawn straight into the frame buffer
-- here, clipped to whatever part of it is visible.
local function paintTextBox(gpu, win, box, top)
  gpu.setForeground(win.fg)
  gpu.setBackground(win.bg)
  gpu.fill(box.x, box.y, box.w, box.h, " ")
  for y = box.y, box.y + box.h - 1 do
    local row = win.textRows[y - top + 1]
    if row and row ~= "" then
      local piece = textSlice(tostring(row), box.x - win.x + 1, box.w)
      if piece ~= "" then gpu.set(box.x, y, piece) end
    end
  end
end

-- Composites one window's visible fragments into the frame buffer
-- (buffer-to-buffer bitblt -- gpu.bitblt's `dst` isn't limited to the
-- real screen, confirmed in GraphicsCard.scala's own doc comment).
-- Does nothing if the window isn't dirty -- this is the actual dirty-
-- tracking half of the gmux technique: don't spend a real GPU call
-- recompositing a window that hasn't changed.
local function compositeWindow(gpu, order, index)
  local win = windows[order[index]]
  if not win.dirty then return end
  local top = bodyTop(win)
  gpu.setActiveBuffer(frameBuffer)
  for _, box in ipairs(visibleBoxes(order, index)) do
    local body = box
    if win.decorated and box.y == win.y then
      paintTitle(gpu, win, box)
      body = box.h > 1 and {x = box.x, y = box.y + 1, w = box.w, h = box.h - 1} or nil
    end
    if body and not win.minimized then
      if win.textRows then
        paintTextBox(gpu, win, body, top)
      else
        gpu.bitblt(frameBuffer, body.x, body.y, body.w, body.h, win.buffer, body.x - win.x + 1, body.y - top + 1)
      end
    end
  end
  gpu.setActiveBuffer(0)
  win.dirty = false
  frameDirty = true
end

-- Runs `code` (compiled fresh, same convention as JOB/a job's `gpu`
-- face) with a `gpu` local already pointed at the given buffer, so
-- window-drawing code looks like ordinary gpu-face code -- it's just
-- executed directly here instead of forwarded, since gmux's own
-- `func(gpu)` draw callback is a function value and can't cross the
-- network the way `gpu`-face JOB code already doesn't need to.
--
-- Every GPU method (set/fill/copy/bitblt/...) is a Callback(direct =
-- true) in OC's own source (confirmed in GraphicsCard.scala) -- meaning
-- it executes with NO yield, straight-line, against a per-tick call
-- budget (Machine.scala: resets once per tick, tier-scaled). `code`
-- here runs as one uninterrupted resume with no yields in between, so a
-- caller doing a big fill via many individual gpu.set() calls instead
-- of one gpu.fill()/bitblt() is exactly the shape that can exhaust that
-- budget mid-draw. Prefer fill/copy/bitblt over set-loops in window
-- draw code for this reason, not just speed.
--
-- `code` arrives from any worker and runs ON the kernal, so it gets a
-- sandbox: no kernal globals (component/computer/load/...), copies of
-- the pure libraries (so it can't clobber the kernal's own), and a gpu
-- that only exposes drawing calls against the buffer already made
-- active (setActiveBuffer(0)/bind would otherwise be a way around the
-- fullscreen gate). It runs in its own coroutine: one that never
-- finishes is ended by the machine's own "too long without yielding"
-- deadline (the sandbox's coroutine.resume enforces it on every
-- coroutine) without taking the kernal down -- though the kernal is
-- stalled until then (system.timeout(), 5s by default). The sandbox has
-- no debug.sethook, so there's no finer-grained budget to use.
local WINDOW_GPU_METHODS = {
  set = true, fill = true, copy = true, get = true,
  setForeground = true, setBackground = true, getForeground = true, getBackground = true,
}

local function copyTable(t)
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

local function windowEnv(gpu)
  local drawGpu = setmetatable({}, {
    __index = function(_, method)
      if not WINDOW_GPU_METHODS[method] then
        return function() error("gpu." .. tostring(method) .. " isn't available to window draw code", 2) end
      end
      return function(...) return gpu[method](...) end
    end,
  })
  return {
    gpu = drawGpu,
    math = copyTable(math), string = copyTable(string), table = copyTable(table), utf8 = copyTable(utf8),
    pairs = pairs, ipairs = ipairs, next = next, select = select,
    tostring = tostring, tonumber = tonumber, type = type, error = error, assert = assert,
  }
end

-- Compiles window draw code into its own sandbox environment. Returns
-- the chunk and its environment (kept together so a window can cache
-- them and redraw without recompiling), or nil and the error.
local function compileWindowCode(gpu, code)
  local env = windowEnv(gpu)
  local chunk, err = load(code, "=window", "t", env)
  if not chunk then return nil, err end
  return chunk, env
end

-- Runs compiled draw code against `buffer` in its own coroutine,
-- with `args` visible to it as the global `args`.
local function runWindowCode(gpu, buffer, chunk, env, args)
  env.args = args
  local co = coroutine.create(chunk)
  gpu.setActiveBuffer(buffer)
  local ok, err = coroutine.resume(co)
  gpu.setActiveBuffer(0)
  if ok and coroutine.status(co) ~= "dead" then
    ok, err = false, "window draw code can't yield"
  end
  if ok then return true end
  return nil, err
end

local function drawIntoBuffer(gpu, buffer, code, args)
  local chunk, envOrErr = compileWindowCode(gpu, code)
  if not chunk then return nil, envOrErr end
  return runWindowCode(gpu, buffer, chunk, envOrErr, args)
end

-- Adds a window to the z-order and gives it focus. New windows go on
-- top, matching gmux's layer_begin for equal layers: inserted before the
-- first existing window whose layer is <= this one's. A freshly created
-- window also takes focus, same convention as it taking the top
-- z-order slot (see M.setFocus to change that later).
local function insertInOrder(win)
  local insertAt = #windowOrder + 1
  for i, existingId in ipairs(windowOrder) do
    if windows[existingId].layer <= win.layer then
      insertAt = i
      break
    end
  end
  table.insert(windowOrder, insertAt, win.id)
end

local function removeFromOrder(id)
  for i, existingId in ipairs(windowOrder) do
    if existingId == id then table.remove(windowOrder, i) return end
  end
end

-- Focus moves the focused title bar's colors, so both the old and the
-- new focused window repaint.
local function moveFocus(id)
  if focusedId == id then return end
  local old = focusedId and windows[focusedId]
  if old and old.decorated then old.dirty = true end
  focusedId = id
  local new = id and windows[id]
  if new and new.decorated then new.dirty = true end
end

local function registerWindow(win)
  windows[win.id] = win
  insertInOrder(win)
  moveFocus(win.id)
  return win
end

-- Muxos-shaped create_window (also standing in for gmux's separate
-- create_window_buffer -- see docs/PROTOCOL.md for why those two
-- collapse into one call here). Allocates a GPU buffer, draws into it,
-- and marks the window dirty -- it does NOT touch the real screen
-- itself any more. The actual screen write happens in flush(), batched
-- with every other dirty window, at most once per call. NOT live --
-- unlike gmux's create_window with a vgpu/vscreen source, nothing here
-- redraws on its own; redrawing means calling it again (or a future
-- update, not built). Closing a window isn't built either, but the
-- data model now supports it correctly in principle: removing a window
-- and marking every remaining one dirty would make whatever was behind
-- it reappear on the next flush.
--
-- Two ways to specify what's drawn, each giving options.width/height a
-- DIFFERENT meaning:
-- - `options.code` -- character-mode, as before: Lua source run with a
--   `gpu` local pointed at the buffer. width/height mean the buffer's
--   own character-cell size (default 30x10).
-- - `options.pixels` -- a "bit window": a 2D pixel grid (pixels[y][x]
--   = a 24-bit color or nil for background), encoded via bitmap.lua
--   into character-cell runs (`options.mode`: "halfblock" (default) or
--   "braille", `options.bg`: background color for off pixels). Here
--   width/height are REQUIRED and mean the pixel grid's own dimensions
--   -- NOT inferred from the grid itself (a row with no "on" pixels
--   has Lua-`#`-visible length 0 regardless of its real width; this
--   isn't a hypothetical, it's what the `bitdemo` REPL command's own
--   test pattern hit). The allocated buffer is sized to fit the
--   ENCODED cell grid, which is smaller than the pixel grid (1x2 or
--   2x4 pixels per cell).
-- Giving both `code` and `pixels` is not an error; `code` just runs
-- after the bitmap is drawn, so it could annotate over it.
function M.createWindow(options)
  local gpu = kernalGpu()
  if not gpu then return nil, "kernal has no gpu component" end
  -- muxos assumes a Tier 3 GPU + a minimum of 1 Tier 3 screen on the
  -- kernal, always -- this isn't a guess at the installed tier, it's a
  -- stated hardware requirement. Still checked cheaply at runtime so a
  -- misconfigured kernal fails with a clear message instead of a
  -- confusing one.
  if not gpu.allocateBuffer then return nil, "kernal's gpu does not support buffers -- muxos requires Tier 3" end
  if not ensureFrameBuffer(gpu) then return nil, "could not allocate the frame buffer" end

  local width, height, cells, cellCols, cellRows
  if options.pixels then
    -- options.width/height, in this mode, mean the PIXEL grid's own
    -- dimensions -- required explicitly rather than inferred via `#`:
    -- a row with no "on" pixels is a table whose first (and every)
    -- entry is nil, and Lua's `#` on such a table reports 0 regardless
    -- of how many columns it conceptually has. Found for real testing
    -- a demo pattern whose first row happened to be entirely
    -- background -- not a hypothetical edge case.
    if not options.width or not options.height then
      return nil, "options.pixels needs options.width/options.height (the pixel grid's own dimensions -- can't be inferred reliably from the grid itself)"
    end
    cells, cellCols, cellRows = bitmap.encode(options.mode, options.pixels, options.width, options.height, options.bg)
    width, height = cellCols, cellRows
  else
    width = options.width or 30
    height = options.height or 10
  end

  -- A text window (options.text) keeps its content in regular memory and
  -- is painted straight into the frame buffer -- no video memory of its
  -- own. Used for the kernal's console.
  if options.text then
    local x, y = options.x or 1, options.y or 1
    local id = nextId()
    local win = {id = id, title = options.title or ("window " .. id), x = x, y = y,
      width = width, height = height, layer = options.layer or 0, dirty = true,
      textRows = {}, fg = options.fg or 0xFFFFFF, bg = options.bg or 0x000000,
      decorated = options.decorated ~= false, resizable = true}
    return registerWindow(win)
  end

  local buffer, allocErr = gpu.allocateBuffer(width, height)
  if not buffer then return nil, "could not allocate a gpu buffer: " .. tostring(allocErr) end

  if cells then
    gpu.setActiveBuffer(buffer)
    local ok, drawErr = pcall(bitmap.draw, gpu, cells, cellRows, cellCols, 1, 1)
    gpu.setActiveBuffer(0)
    if not ok then
      gpu.freeBuffer(buffer)
      return nil, "bitmap draw failed: " .. tostring(drawErr)
    end
  end

  if options.code then
    local ok, drawErr = drawIntoBuffer(gpu, buffer, options.code, options.args)
    if not ok then
      gpu.freeBuffer(buffer)
      return nil, "window draw code failed: " .. tostring(drawErr)
    end
  end

  local x, y = options.x or 1, options.y or 1
  local id = nextId()
  -- `ownerJobId` is OPTIONAL and purely informational to the
  -- compositor itself -- it's whatever node/runtime.lua's
  -- create_graphics_process passed through CREATEWINDOW's `ownerJobId`
  -- field (handleCreateWindow forwards the whole message as `options`,
  -- so this needs no wiring here beyond just reading it). A plain
  -- create_window / the REPL's own `window` command leaves it nil --
  -- there's no job to deliver keyboard input to for those, and that's
  -- fine, not an error.
  local win = {id = id, title = options.title or ("window " .. id), x = x, y = y,
    width = width, height = height, buffer = buffer, layer = options.layer or 0, dirty = true,
    ownerJobId = options.ownerJobId, drawCache = {}, drawCacheSize = 0,
    decorated = options.decorated ~= false, resizable = options.resizable == true}
  return registerWindow(win)
end

-- A plain, serializable description of a window -- what crosses the
-- wire (the record itself holds a gpu buffer index and compiled draw
-- code).
function M.describe(win)
  return {id = win.id, title = win.title, x = win.x, y = win.y, width = win.width, height = win.height,
    layer = win.layer, ownerJobId = win.ownerJobId, decorated = win.decorated, resizable = win.resizable,
    minimized = win.minimized or false, maximized = win.maximized or false, status = win.status}
end

function M.listWindows()
  local list = {}
  for _, id in ipairs(windowOrder) do
    list[#list + 1] = M.describe(windows[id])
  end
  return list
end

-- Returns the currently-focused window's own record, or nil if no
-- window has ever been created (or, in principle, once a real
-- "destroy window" exists and removes the focused one -- not a case
-- that can happen yet, since nothing ever removes a window today).
function M.getFocus()
  return focusedId and windows[focusedId]
end

-- Explicit focus change -- there's no mouse/click anywhere in this
-- project (no pointer component is wired up at all), so this is the
-- only way focus can move until some other input gesture is designed.
-- Exposed mainly for kernal/muxos.lua's own `focus <id>` REPL command,
-- a manual stand-in for whatever gesture eventually does this for
-- real. Returns false + an error for an id that doesn't exist, rather
-- than silently leaving the old focus in place or focusing nothing.
function M.getWindow(id)
  return windows[id]
end

function M.setFocus(id)
  if not windows[id] then
    return false, "no such window: " .. tostring(id)
  end
  moveFocus(id)
  return true
end

-- Puts a window on top of the others in its layer (gmux's as_top).
-- Only it needs repainting: nothing that was over it is any more.
function M.raise(id)
  local win = windows[id]
  if not win then return false, "no such window: " .. tostring(id) end
  removeFromOrder(id)
  insertInOrder(win)
  win.dirty = true
  return true
end

-- The window and part under a screen cell, topmost first: returns the
-- window record, "title" or "body", and the cell's column/row within
-- that part (the body's own coordinates, as its owner draws them).
function M.hitTest(x, y)
  for _, id in ipairs(windowOrder) do
    local win = windows[id]
    local r = outerRect(win)
    if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
      if win.decorated and y == win.y then return win, "title", x - win.x + 1, 1 end
      return win, "body", x - win.x + 1, y - bodyTop(win) + 1
    end
  end
end

function M.bodyTop(win)
  return bodyTop(win)
end

-- Ids of the windows a process owns.
function M.windowsOwnedBy(jobId)
  local ids = {}
  for id, win in pairs(windows) do
    if win.ownerJobId == jobId then ids[#ids + 1] = id end
  end
  table.sort(ids)
  return ids
end

-- The owner process's state for the title prefix: nil (running),
-- "dead" or "error".
function M.setStatus(id, status)
  local win = windows[id]
  if not win or win.status == status then return end
  win.status = status
  win.dirty = true
end

-- Removes a window, freeing its buffer; focus passes to the topmost
-- remaining window. Returns the removed record.
function M.close(id)
  local win = windows[id]
  if not win then return nil, "no such window: " .. tostring(id) end
  removeFromOrder(id)
  windows[id] = nil
  local gpu = kernalGpu()
  if win.buffer and gpu then gpu.freeBuffer(win.buffer) end
  if focusedId == id then moveFocus(windowOrder[1]) end
  M.invalidateAll()
  return win
end

function M.move(id, x, y)
  local win = windows[id]
  if not win then return false, "no such window: " .. tostring(id) end
  if win.x == x and win.y == y then return true end
  win.x, win.y = x, y
  M.invalidateAll()
  return true
end

-- Collapses a decorated window to its title bar, or expands it again
-- (toggles when `minimized` is nil). Un-maximizes first, like gmux.
function M.minimize(id, minimized)
  local win = windows[id]
  if not win or not win.decorated then return false, "window can't be minimized" end
  if win.maximized then M.maximize(id, false) end
  if minimized == nil then minimized = not win.minimized end
  win.minimized = minimized or nil
  M.invalidateAll()
  return true
end

-- Marks every window dirty and blanks the frame buffer, so the next
-- flush rebuilds the whole picture -- needed whenever what's shown
-- changes wholesale (leaving the exclusive mode).
function M.invalidateAll()
  local gpu = kernalGpu()
  if gpu and frameBuffer then
    gpu.setActiveBuffer(frameBuffer)
    gpu.setBackground(0x000000)
    local w, h = gpu.getBufferSize(frameBuffer)
    gpu.fill(1, 1, w, h, " ")
    gpu.setActiveBuffer(0)
  end
  for _, win in pairs(windows) do win.dirty = true end
end

function M.setExclusive(owner)
  local was = exclusiveOwner
  exclusiveOwner = owner
  if was and not owner then M.invalidateAll() end
end

function M.exclusiveOwner()
  return exclusiveOwner
end

-- Draws straight onto the real screen -- only for the exclusive owner
-- living on the kernal (the console); the frame buffer isn't involved.
function M.drawDirect(fn)
  local gpu = kernalGpu()
  if not gpu then return end
  gpu.setActiveBuffer(0)
  fn(gpu)
end

-- Moves/resizes a text window. Only text windows: a buffered window's
-- content was drawn once into a buffer of its original size and can't
-- be regenerated at another size.
-- A buffered window can only be resized if it was created
-- `resizable` (its owner is told, and redraws at the new size): its
-- buffer is reallocated, keeping whatever of the old content fits.
function M.setGeometry(id, x, y, width, height)
  local win = windows[id]
  if not win then return false, "no such window: " .. tostring(id) end
  if not win.resizable then return false, "window " .. tostring(id) .. " isn't resizable" end
  width, height = math.max(1, math.floor(width)), math.max(1, math.floor(height))
  if win.buffer and (width ~= win.width or height ~= win.height) then
    local gpu = kernalGpu()
    if not gpu then return false, "kernal has no gpu component" end
    local buffer, err = gpu.allocateBuffer(width, height)
    if not buffer then return false, "could not allocate a gpu buffer: " .. tostring(err) end
    gpu.bitblt(buffer, 1, 1, math.min(width, win.width), math.min(height, win.height), win.buffer, 1, 1)
    gpu.freeBuffer(win.buffer)
    win.buffer = buffer
  end
  win.x, win.y, win.width, win.height = x, y, width, height
  -- What was behind its old outline has to show again.
  M.invalidateAll()
  return true
end

function M.resize(id, width, height)
  local win = windows[id]
  if not win then return false, "no such window: " .. tostring(id) end
  return M.setGeometry(id, win.x, win.y, width, height)
end

-- gmux's maximize: a resizable window fills the screen (title bar
-- included), or goes back to where it was (toggles when `maximized`
-- is nil).
function M.maximize(id, maximized)
  local win = windows[id]
  if not win or not win.resizable then return false, "window can't be maximized" end
  if win.minimized then win.minimized = nil end
  if maximized == nil then maximized = not win.maximized end
  if maximized and not win.maximized then
    local gpu = kernalGpu()
    if not gpu then return false, "kernal has no gpu component" end
    local w, h = gpu.getResolution()
    local saved = {win.x, win.y, win.width, win.height}
    local ok, err = M.setGeometry(id, 1, 1, w, h - titleRows(win))
    if not ok then return false, err end
    win.restoreGeometry, win.maximized = saved, true
  elseif not maximized and win.maximized then
    local g = win.restoreGeometry
    win.maximized, win.restoreGeometry = nil, nil
    local ok, err = M.setGeometry(id, g[1], g[2], g[3], g[4])
    if not ok then return false, err end
  end
  M.invalidateAll()
  return true
end

-- Redraws an existing buffered window -- the persistent-handle half of
-- the window model: an app keeps its window and pushes new content into
-- it whenever it wants. Same sandbox as at creation.
-- `options`: `code` (+ `args`), and/or `pixels`/`mode` like createWindow;
-- `clear` (default true) blanks the buffer to `bg` first. Compiled draw
-- code is cached per window, keyed by its source, so an app that redraws
-- with the same code and different `args` doesn't recompile each time.
local DRAW_CACHE_LIMIT = 8

function M.redrawWindow(id, options)
  local win = windows[id]
  local gpu = kernalGpu()
  if not win then return nil, "no such window: " .. tostring(id) end
  if win.textRows or not win.buffer then return nil, "window " .. tostring(id) .. " has no drawable buffer" end
  if not gpu then return nil, "kernal has no gpu component" end
  if options.clear ~= false then
    gpu.setActiveBuffer(win.buffer)
    gpu.setBackground(options.bg or 0x000000)
    gpu.fill(1, 1, win.width, win.height, " ")
    gpu.setActiveBuffer(0)
  end
  if options.pixels then
    if not options.width or not options.height then
      return nil, "options.pixels needs options.width/options.height"
    end
    local cells, cellCols, cellRows = bitmap.encode(options.mode, options.pixels, options.width, options.height, options.bg)
    gpu.setActiveBuffer(win.buffer)
    local ok, err = pcall(bitmap.draw, gpu, cells, math.min(cellRows, win.height), math.min(cellCols, win.width), 1, 1)
    gpu.setActiveBuffer(0)
    if not ok then return nil, "bitmap draw failed: " .. tostring(err) end
  end
  if options.code then
    local cached = win.drawCache[options.code]
    if not cached then
      local chunk, envOrErr = compileWindowCode(gpu, options.code)
      if not chunk then return nil, envOrErr end
      if win.drawCacheSize >= DRAW_CACHE_LIMIT then
        win.drawCache, win.drawCacheSize = {}, 0
      end
      cached = {chunk = chunk, env = envOrErr}
      win.drawCache[options.code] = cached
      win.drawCacheSize = win.drawCacheSize + 1
    end
    local ok, err = runWindowCode(gpu, win.buffer, cached.chunk, cached.env, options.args)
    if not ok then return nil, "window draw code failed: " .. tostring(err) end
  end
  win.dirty = true
  return true
end

-- Replaces a text window's rows (strings, top to bottom) and marks it
-- dirty.
function M.setText(id, rows)
  local win = windows[id]
  if not win or not win.textRows then return end
  win.textRows = rows
  win.dirty = true
end

-- Composites every dirty window into the frame buffer, then flips it
-- onto the real screen with ONE bitblt -- only if something changed, so
-- a quiet tick costs zero real GPU calls. Nothing else draws on the
-- real screen while compositing is active, so the frame buffer never
-- needs syncing back FROM the screen; whoever draws directly (the
-- console in console mode, a fullscreen node) does so only as the
-- exclusive owner, when this does nothing.
function M.flush()
  local gpu = kernalGpu()
  if exclusiveOwner or not gpu or not frameBuffer then return end
  for i = 1, #windowOrder do
    compositeWindow(gpu, windowOrder, i)
  end
  if frameDirty then
    local w, h = gpu.getBufferSize(frameBuffer)
    gpu.bitblt(0, 1, 1, w, h, frameBuffer, 1, 1)
    frameDirty = false
  end
end

return M
