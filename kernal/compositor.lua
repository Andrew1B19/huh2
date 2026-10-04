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
-- Still NOT gmux's full desktop: no dragging, resizing, or input
-- routing (gmux/lib/gmux/frontend/windows.lua, 482 lines, wasn't
-- touched). What this gives: allocate a GPU buffer per window, let code
-- draw into it, composite every dirty, unoccluded window into one
-- persistent frame buffer, and flip that onto the real screen with a
-- SINGLE bitblt -- at most once per flush() call, which muxos.lua calls
-- at most once per tick from its background dispatcher thread, not once
-- per window. This is the actual implementation of "only the display
-- node makes those budgeted calls for real, and batches them
-- responsibly" rather than each window touching the real screen on its
-- own.
--
-- Loaded via dofile() by kernal/muxos.lua as a sibling file, not
-- require() -- OpenOS's require() resolves against /lib, /usr/lib, etc,
-- not wherever this install happens to live, and dofile keeps the
-- "copy these files next to each other" install story consistent with
-- how muxos.lua itself finds node/runtime.lua.

local component = require("component")

local function scriptDir()
  local info = debug.getinfo(1, "S")
  local path = info.source:match("^@(.*)$") or info.source
  return path:match("^(.*)/[^/]*$") or "."
end

-- The encoder for "bit windows" (half-block/braille sub-cell bitmaps --
-- see bitmap.lua's own header for why that's the only way to get
-- anything bitmap-like on OC's character-cell-only GPU hardware).
-- Loaded the same way runtime.lua/compositor.lua itself are: dofile()
-- against a sibling file, not require().
local bitmap = dofile(scriptDir() .. "/bitmap.lua")

local M = {}

-- id -> {id, title, x, y, width, height, buffer, layer, dirty}
local windows = {}
local windowOrder = {} -- ids in Z-ORDER, index 1 = TOPMOST (matches gmux's convention)
local nextWindowId = 1

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

local function kernalGpu()
  if component.isAvailable("gpu") then return component.gpu end
end

local function ensureFrameBuffer(gpu)
  if frameBuffer then return frameBuffer end
  local w, h = gpu.getResolution()
  frameBuffer, _ = gpu.allocateBuffer(w, h)
  return frameBuffer
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

-- The visible fragments of the window at `index` in windowOrder (1 =
-- topmost): its own rectangle, with every window ABOVE it (indices
-- 1..index-1, if shown) cut out. Can return 0 pieces (fully covered),
-- 1 (unoccluded), or several (occluded on one side, e.g. by a window
-- overlapping a corner).
local function visibleBoxes(index)
  local win = windows[windowOrder[index]]
  local boxes = {{x = win.x, y = win.y, w = win.width, h = win.height}}
  for i = 1, index - 1 do
    local blocker = windows[windowOrder[i]]
    local blockerRect = {x = blocker.x, y = blocker.y, w = blocker.width, h = blocker.height}
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

-- Composites one window's visible fragments into the frame buffer
-- (buffer-to-buffer bitblt -- gpu.bitblt's `dst` isn't limited to the
-- real screen, confirmed in GraphicsCard.scala's own doc comment).
-- Does nothing if the window isn't dirty -- this is the actual dirty-
-- tracking half of the gmux technique: don't spend a real GPU call
-- recompositing a window that hasn't changed.
local function compositeWindow(gpu, index)
  local win = windows[windowOrder[index]]
  if not win.dirty then return end
  for _, box in ipairs(visibleBoxes(index)) do
    gpu.bitblt(frameBuffer, box.x, box.y, box.w, box.h, win.buffer, box.x - win.x + 1, box.y - win.y + 1)
  end
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
local function drawIntoBuffer(gpu, buffer, code)
  gpu.setActiveBuffer(buffer)
  local chunk, loadErr = load("local gpu = ...\n" .. code, "=window", "t")
  local ok, err
  if chunk then
    ok, err = pcall(chunk, gpu)
  else
    ok, err = false, loadErr
  end
  gpu.setActiveBuffer(0)
  if ok then return true end
  return nil, err
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
  if not gpu.allocateBuffer then return nil, "kernal's gpu does not support buffers (tier 1?)" end
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
    local ok, drawErr = drawIntoBuffer(gpu, buffer, options.code)
    if not ok then
      gpu.freeBuffer(buffer)
      return nil, "window draw code failed: " .. tostring(drawErr)
    end
  end

  local x, y = options.x or 1, options.y or 1
  local id = nextId()
  local win = {id = id, title = options.title or ("window " .. id), x = x, y = y,
    width = width, height = height, buffer = buffer, layer = options.layer or 0, dirty = true}
  windows[id] = win
  -- New windows go on top, matching gmux's layer_begin for equal layers:
  -- inserted before the first existing window whose layer is <= this one's.
  local insertAt = #windowOrder + 1
  for i, existingId in ipairs(windowOrder) do
    if windows[existingId].layer <= win.layer then
      insertAt = i
      break
    end
  end
  table.insert(windowOrder, insertAt, id)
  return win
end

function M.listWindows()
  local list = {}
  for _, id in ipairs(windowOrder) do
    list[#list + 1] = windows[id]
  end
  return list
end

-- Composites every dirty window into the frame buffer, then flips the
-- frame buffer onto the real screen with ONE bitblt -- but only if
-- something actually changed (frameDirty), so a quiet tick costs zero
-- real GPU calls. Meant to be called at most once per tick by the
-- caller (muxos.lua's background dispatcher thread); this function
-- itself doesn't rate-limit anything -- calling it twice in the same
-- tick just does the compositing work twice, redundantly but not
-- incorrectly.
function M.flush()
  local gpu = kernalGpu()
  if not gpu or not frameBuffer then return end
  for i = 1, #windowOrder do
    compositeWindow(gpu, i)
  end
  if frameDirty then
    local w, h = gpu.getBufferSize(frameBuffer)
    gpu.bitblt(0, 1, 1, w, h, frameBuffer, 1, 1)
    frameDirty = false
  end
end

return M
