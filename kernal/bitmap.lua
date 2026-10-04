-- muxos bitmap encoder: turns a pixel grid into character-cell runs,
-- since OC's GPU hardware has no pixel API at all (confirmed:
-- get/set/copy/fill/bitblt all operate on a TextBuffer -- codepoint +
-- fg + bg per cell -- see docs/PROTOCOL.md). Two sub-cell techniques:
--
-- "halfblock": 1x2 sub-pixels per cell (U+2580 upper half block), TWO
-- real colors per cell (fg = top pixel, bg = bottom pixel). Best for
-- color content -- icons, a toolbar, a wallpaper.
-- "braille": 2x4 sub-pixels per cell (U+2800 + an 8-bit dot pattern),
-- higher density but only ONE effective color per cell (dots are a
-- single foreground color against the background) -- best for line
-- art/outlines, not full-color images.
--
-- A pixel grid is pixels[y][x] = a 24-bit color number, or nil/false
-- for "background" (renders as `bg`). 1-based, y then x, matching how
-- the rest of this project indexes (OC itself is 1-based for
-- gpu.set/fill/etc).
--
-- gpu.set() paints a whole string under ONE current foreground/
-- background pair -- confirmed from GraphicsCard.scala, color is GPU
-- state, not per-character within a single call -- so encode() groups
-- each output row into RUNS of cells sharing the same (char, fg, bg)
-- rather than one cell at a time; draw() then costs one
-- setForeground+setBackground+set per run, not per cell. This is both
-- the only way to batch multiple cells into one `set` call at all, and
-- the same call-minimization the call-budget investigation already
-- called for elsewhere in this project.
--
-- Loaded via dofile() by kernal/compositor.lua as a sibling file, same
-- reasoning as compositor.lua's own header: not require(), to keep the
-- "copy these files next to each other" install story consistent.

local M = {}

local function getPixel(pixels, x, y, width, height)
  if x < 1 or x > width or y < 1 or y > height then return nil end
  local row = pixels[y]
  return row and row[x] or nil
end

-- 1 column x 2 rows per cell, two real colors.
local function encodeHalfBlock(pixels, width, height, bg)
  local cols = width
  local rows = math.ceil(height / 2)
  local upperHalf = utf8.char(0x2580) -- ▀
  local lowerHalf = utf8.char(0x2584) -- ▄
  local cells = {}
  for row = 1, rows do
    cells[row] = {}
    for col = 1, cols do
      local top = getPixel(pixels, col, row * 2 - 1, width, height)
      local bottom = getPixel(pixels, col, row * 2, width, height)
      local fg, cellBg, char
      if not top and not bottom then
        fg, cellBg, char = bg, bg, " "
      elseif top and bottom and top == bottom then
        fg, cellBg, char = top, top, " "
      elseif top and not bottom then
        fg, cellBg, char = top, bg, upperHalf
      elseif bottom and not top then
        fg, cellBg, char = bottom, bg, lowerHalf
      else
        fg, cellBg, char = top, bottom, upperHalf
      end
      cells[row][col] = {char = char, fg = fg, bg = cellBg}
    end
  end
  return cells, cols, rows
end

-- 2 columns x 4 rows per cell. Standard Unicode braille dot-to-bit
-- layout: dots 1/2/3 top-to-bottom on the left column (bits 0x01/0x02/
-- 0x04), dot 7 below them (bit 0x40); dots 4/5/6 top-to-bottom on the
-- right column (bits 0x08/0x10/0x20), dot 8 below them (bit 0x80).
-- {dx, dy, bit} -- dx/dy are 1-based offsets within the 2x4 cell.
local DOT_BITS = {
  {1, 1, 0x01}, {1, 2, 0x02}, {1, 3, 0x04}, {1, 4, 0x40},
  {2, 1, 0x08}, {2, 2, 0x10}, {2, 3, 0x20}, {2, 4, 0x80},
}

-- Only ONE effective foreground color per cell (the color of the
-- first "on" sub-pixel found, scanning dots in the order above) --
-- mixed colors within one cell aren't representable this way, a real
-- limitation of the format, not a bug.
local function encodeBraille(pixels, width, height, bg)
  local cols = math.ceil(width / 2)
  local rows = math.ceil(height / 4)
  local cells = {}
  for row = 1, rows do
    cells[row] = {}
    for col = 1, cols do
      local bits = 0
      local fg = nil
      for _, d in ipairs(DOT_BITS) do
        local dx, dy, bit = d[1], d[2], d[3]
        local px = getPixel(pixels, (col - 1) * 2 + dx, (row - 1) * 4 + dy, width, height)
        if px then
          bits = bits | bit
          if not fg then fg = px end
        end
      end
      local char = bits == 0 and " " or utf8.char(0x2800 + bits)
      cells[row][col] = {char = char, fg = fg or bg, bg = bg}
    end
  end
  return cells, cols, rows
end

-- mode: "halfblock" (default) or "braille". Returns cells[row][col] =
-- {char, fg, bg}, plus the resulting character-grid width (cols) and
-- height (rows) -- this is the buffer size createWindow() should
-- allocate.
function M.encode(mode, pixels, width, height, bg)
  bg = bg or 0x000000
  if mode == "braille" then
    return encodeBraille(pixels, width, height, bg)
  end
  return encodeHalfBlock(pixels, width, height, bg)
end

-- Draws pre-encoded cells into `gpu` (already pointed at the right
-- buffer) at (originX, originY), run-length batching consecutive
-- cells on the same row that share (char, fg, bg) into one
-- setForeground+setBackground+set call instead of one per cell.
function M.draw(gpu, cells, rows, cols, originX, originY)
  for row = 1, rows do
    local rowCells = cells[row]
    local col = 1
    while col <= cols do
      local cell = rowCells[col]
      local runEnd = col
      while runEnd + 1 <= cols
          and rowCells[runEnd + 1].char == cell.char
          and rowCells[runEnd + 1].fg == cell.fg
          and rowCells[runEnd + 1].bg == cell.bg do
        runEnd = runEnd + 1
      end
      gpu.setForeground(cell.fg)
      gpu.setBackground(cell.bg)
      gpu.set(originX + col - 1, originY + row - 1, cell.char:rep(runEnd - col + 1))
      col = runEnd + 1
    end
  end
end

return M
