-- munix virtual GPU: an OpenComputers tier-3 GPU in plain Lua memory,
-- for a session whose screen isn't the kernal's own -- a network
-- terminal's. The compositor draws into it exactly as it draws into the
-- real GPU (the same calls: buffers, set/fill/copy/bitblt, colors), and
-- what changed on its screen (buffer 0) since the last look comes out
-- of takeDamage() as runs of same-colored text, ready to send.
--
-- Semantics follow OC's GraphicsCard: 1-based cells, clipping at the
-- buffer's edges, set() with an optional vertical flag, copy() by an
-- offset, bitblt(dst, col, row, w, h, src, fromCol, fromRow) with OC's
-- defaults, colors as 24-bit numbers (no palette). Every character is
-- one cell (OC's double-width glyphs aren't modeled).
--
-- new(width, height, depth) -> a gpu table whose methods are called
-- with a dot, like a component proxy (gpu.set(1, 1, "hi")). `depth` is
-- the terminal's color depth (1, 4 or 8; default 8): the compositor
-- picks its colors by it, and the terminal's own GPU maps them.
local M = {}

local function newBuffer(w, h, fg, bg)
  local b = {w = w, h = h, ch = {}, fg = {}, bg = {}}
  for y = 1, h do
    local c, f, k = {}, {}, {}
    for x = 1, w do c[x], f[x], k[x] = " ", fg, bg end
    b.ch[y], b.fg[y], b.bg[y] = c, f, k
  end
  return b
end

local function chars(text)
  local out = {}
  if utf8.len(text) then
    for _, c in utf8.codes(text) do out[#out + 1] = utf8.char(c) end
  else
    for i = 1, #text do out[i] = text:sub(i, i) end
  end
  return out
end

function M.new(width, height, depth)
  depth = depth or 8
  local gpu = {}
  local fg, bg = 0xFFFFFF, 0x000000
  local buffers = {[0] = newBuffer(width, height, fg, bg)}
  local active = 0
  local nextBuffer = 1
  -- The screen's changed cells: row -> {min column, max column}.
  local damage = {}

  local function touch(b, x, y)
    if b ~= buffers[0] then return end
    local d = damage[y]
    if d then
      if x < d[1] then d[1] = x end
      if x > d[2] then d[2] = x end
    else
      damage[y] = {x, x}
    end
  end

  local function put(b, x, y, c, f, k)
    if x < 1 or y < 1 or x > b.w or y > b.h then return end
    local row = b.ch[y]
    if row[x] == c and b.fg[y][x] == f and b.bg[y][x] == k then return end
    row[x], b.fg[y][x], b.bg[y][x] = c, f, k
    touch(b, x, y)
  end

  function gpu.getResolution() return buffers[0].w, buffers[0].h end
  function gpu.maxResolution() return buffers[0].w, buffers[0].h end
  function gpu.setResolution(w, h)
    local old = buffers[0]
    if w == old.w and h == old.h then return false end
    local b = newBuffer(w, h, fg, bg)
    for y = 1, math.min(h, old.h) do
      for x = 1, math.min(w, old.w) do b.ch[y][x], b.fg[y][x], b.bg[y][x] = old.ch[y][x], old.fg[y][x], old.bg[y][x] end
    end
    buffers[0] = b
    damage = {}
    for y = 1, h do damage[y] = {1, w} end
    return true
  end
  function gpu.getDepth() return depth end
  function gpu.maxDepth() return depth end
  function gpu.setDepth() return depth end
  function gpu.getViewport() return buffers[0].w, buffers[0].h end

  function gpu.setForeground(color)
    local old = fg
    fg = math.floor(tonumber(color) or 0) & 0xFFFFFF
    return old
  end
  function gpu.setBackground(color)
    local old = bg
    bg = math.floor(tonumber(color) or 0) & 0xFFFFFF
    return old
  end
  function gpu.getForeground() return fg, false end
  function gpu.getBackground() return bg, false end

  function gpu.set(x, y, value, vertical)
    local b = buffers[active]
    x, y = math.floor(x), math.floor(y)
    for i, c in ipairs(chars(tostring(value))) do
      if vertical then put(b, x, y + i - 1, c, fg, bg) else put(b, x + i - 1, y, c, fg, bg) end
    end
    return true
  end

  function gpu.get(x, y)
    local b = buffers[active]
    x, y = math.floor(x), math.floor(y)
    if x < 1 or y < 1 or x > b.w or y > b.h then error("index out of bounds", 2) end
    return b.ch[y][x], b.fg[y][x], b.bg[y][x]
  end

  function gpu.fill(x, y, w, h, c)
    local b = buffers[active]
    c = chars(tostring(c))[1] or " "
    x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
    for yy = math.max(1, y), math.min(b.h, y + h - 1) do
      for xx = math.max(1, x), math.min(b.w, x + w - 1) do put(b, xx, yy, c, fg, bg) end
    end
    return true
  end

  -- Copies the cells of one rectangle into another; safe when they overlap.
  local function blit(dst, dx, dy, src, sx, sy, w, h)
    local cells = {}
    for yy = 0, h - 1 do
      local row = src.ch[sy + yy]
      if row then
        for xx = 0, w - 1 do
          local c = row[sx + xx]
          if c then cells[#cells + 1] = {dx + xx, dy + yy, c, src.fg[sy + yy][sx + xx], src.bg[sy + yy][sx + xx]} end
        end
      end
    end
    for _, cell in ipairs(cells) do put(dst, cell[1], cell[2], cell[3], cell[4], cell[5]) end
  end

  function gpu.copy(x, y, w, h, tx, ty)
    local b = buffers[active]
    x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
    blit(b, x + tx, y + ty, b, x, y, w, h)
    return true
  end

  function gpu.allocateBuffer(w, h)
    w, h = math.floor(w or buffers[0].w), math.floor(h or buffers[0].h)
    if w < 1 or h < 1 then return nil, "invalid buffer size" end
    local id = nextBuffer
    nextBuffer = nextBuffer + 1
    buffers[id] = newBuffer(w, h, 0xFFFFFF, 0x000000)
    return id
  end

  function gpu.freeBuffer(id)
    if not id or id == 0 or not buffers[id] then return false end
    buffers[id] = nil
    if active == id then active = 0 end
    return true
  end

  function gpu.freeAllBuffers()
    for id in pairs(buffers) do if id ~= 0 then buffers[id] = nil end end
    active = 0
  end

  function gpu.buffers()
    local list = {}
    for id in pairs(buffers) do if id ~= 0 then list[#list + 1] = id end end
    table.sort(list)
    return list
  end

  function gpu.setActiveBuffer(id)
    if not buffers[id] then return nil, "invalid buffer index" end
    local old = active
    active = id
    return old
  end
  function gpu.getActiveBuffer() return active end

  function gpu.getBufferSize(id)
    local b = buffers[id or active]
    if not b then return nil, "invalid buffer index" end
    return b.w, b.h
  end

  function gpu.bitblt(dst, col, row, w, h, src, fromCol, fromRow)
    dst, src = dst or 0, src or active
    local d, s = buffers[dst], buffers[src]
    if not d or not s then return nil, "invalid buffer index" end
    w, h = w or s.w, h or s.h
    blit(d, col or 1, row or 1, s, fromCol or 1, fromRow or 1, w, h)
    return true
  end

  -- What changed on the screen since the last call: a list of runs
  -- {x, y, text, fg, bg}, each a stretch of one row in one color pair.
  -- `all` gives the whole screen (a terminal that just connected).
  function gpu.takeDamage(all)
    local s = buffers[0]
    if all then
      damage = {}
      for y = 1, s.h do damage[y] = {1, s.w} end
    end
    local runs = {}
    local rows = {}
    for y in pairs(damage) do rows[#rows + 1] = y end
    table.sort(rows)
    for _, y in ipairs(rows) do
      local d = damage[y]
      local ch, f, k = s.ch[y], s.fg[y], s.bg[y]
      if ch then
        local x = d[1]
        while x <= math.min(d[2], s.w) do
          local start, cf, ck, parts = x, f[x], k[x], {}
          while x <= math.min(d[2], s.w) and f[x] == cf and k[x] == ck do
            parts[#parts + 1] = ch[x]
            x = x + 1
          end
          runs[#runs + 1] = {start, y, table.concat(parts), cf, ck}
        end
      end
    end
    damage = {}
    return runs
  end

  return gpu
end

return M
