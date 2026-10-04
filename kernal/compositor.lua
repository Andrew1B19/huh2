-- muxos compositor. This is, BY CONSTRUCTION, the only file in this
-- entire project that ever makes a real gpu.* call. "Only the display
-- node actually needs to make those budgeted calls for real" (see
-- docs/PROTOCOL.md's call-budget section: every GPU method is a
-- per-tick-budgeted `direct` call in OC's own source) -- centralizing
-- every real draw call here, instead of leaving them scattered across
-- muxos.lua, is what makes that true rather than just asserted.
--
-- NOT gmux's real desktop: no layering, dragging, resizing, or input
-- routing (gmux/lib/gmux/frontend/windows.lua + graphics.lua, 482 + 345
-- lines, weren't ported). What this gives: allocate a GPU buffer, let
-- code draw into it, blit it onto the real screen once, and remember it
-- existed. Enough to make create_window/get_windows real without
-- pretending there's a desktop here.
--
-- Loaded via dofile() by kernal/muxos.lua as a sibling file, not
-- require() -- OpenOS's require() resolves against /lib, /usr/lib, etc,
-- not wherever this install happens to live, and dofile keeps the
-- "copy these files next to each other" install story consistent with
-- how muxos.lua itself finds node/runtime.lua.

local component = require("component")

local M = {}

-- id -> {id, title, x, y, width, height, buffer}
local windows = {}
local windowOrder = {}
local nextWindowId = 1

local function nextId()
  local id = nextWindowId
  nextWindowId = nextWindowId + 1
  return id
end

local function kernalGpu()
  if component.isAvailable("gpu") then return component.gpu end
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
-- collapse into one call here). Allocates a GPU buffer, runs `code`
-- against it if given, blits it onto the real screen at (x, y) once,
-- and remembers it as a window. NOT live -- unlike gmux's create_window
-- with a vgpu/vscreen source, this never redraws itself; redrawing
-- means calling it again (or a future update, not built). Closing a
-- window also isn't built -- nothing repaints whatever was behind it.
function M.createWindow(options)
  local gpu = kernalGpu()
  if not gpu then return nil, "kernal has no gpu component" end
  if not gpu.allocateBuffer then return nil, "kernal's gpu does not support buffers (tier 1?)" end

  local width = options.width or 30
  local height = options.height or 10
  local buffer, allocErr = gpu.allocateBuffer(width, height)
  if not buffer then return nil, "could not allocate a gpu buffer: " .. tostring(allocErr) end

  if options.code then
    local ok, drawErr = drawIntoBuffer(gpu, buffer, options.code)
    if not ok then
      gpu.freeBuffer(buffer)
      return nil, "window draw code failed: " .. tostring(drawErr)
    end
  end

  local x, y = options.x or 1, options.y or 1
  gpu.bitblt(0, x, y, width, height, buffer, 1, 1)

  local id = nextId()
  local win = {id = id, title = options.title or ("window " .. id), x = x, y = y,
    width = width, height = height, buffer = buffer}
  windows[id] = win
  windowOrder[#windowOrder + 1] = id
  return win
end

function M.listWindows()
  local list = {}
  for _, id in ipairs(windowOrder) do
    list[#list + 1] = windows[id]
  end
  return list
end

return M
