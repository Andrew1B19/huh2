-- kernal/vgpu.lua: the virtual GPU a network terminal's session draws
-- with -- checked on its own, then with the real compositor drawing
-- into it. Run from the repo root: lua5.3 test/emu/vgpu_test.lua
local REPO_ROOT = "."
local function readFile(path)
  local f = assert(io.open(path, "rb"))
  local data = f:read("a")
  f:close()
  return data
end
local function loadSibling(name) return assert(load(readFile(REPO_ROOT .. "/kernal/" .. name), "=" .. name)) end
local vgpu = loadSibling("vgpu.lua")()

local function row(gpu, y, x1, x2)
  local out = {}
  for x = x1, x2 do out[#out + 1] = (gpu.get(x, y)) end
  return table.concat(out)
end

print("vgpu 1: set, get, fill, colors, clipping")
do
  local g = vgpu.new(10, 4)
  g.setForeground(0xFF0000)
  g.setBackground(0x0000FF)
  g.set(9, 1, "abc") -- clipped at the edge
  assert(row(g, 1, 8, 10) == " ab", row(g, 1, 8, 10))
  local c, f, b = g.get(9, 1)
  assert(c == "a" and f == 0xFF0000 and b == 0x0000FF, "colors kept per cell")
  g.set(1, 2, "xyz", true)
  assert((g.get(1, 2)) == "x" and (g.get(1, 4)) == "z", "vertical set")
  g.fill(2, 2, 3, 2, "#")
  assert(row(g, 3, 1, 5) == "y### ", row(g, 3, 1, 5))
  g.set(1, 1, "é✖")
  assert((g.get(2, 1)) == "✖", "one cell per character, UTF-8 aware")
end
print("  OK")

print("vgpu 2: copy (overlapping), buffers and bitblt")
do
  local g = vgpu.new(8, 2)
  g.set(1, 1, "abcdef")
  g.copy(1, 1, 6, 1, 2, 0)
  assert(row(g, 1, 1, 8) == "ababcdef", "an overlapping copy: " .. row(g, 1, 1, 8))
  local b = g.allocateBuffer(3, 1)
  assert(b and select(1, g.getBufferSize(b)) == 3)
  g.setActiveBuffer(b)
  g.set(1, 1, "XYZ")
  g.setActiveBuffer(0)
  g.bitblt(0, 4, 2, 3, 1, b, 1, 1)
  assert(row(g, 2, 1, 8) == "   XYZ  ", row(g, 2, 1, 8))
  assert(#g.buffers() == 1 and g.freeBuffer(b) and #g.buffers() == 0)
end
print("  OK")

print("vgpu 3: damage comes out as runs of one color pair, then resets")
do
  local g = vgpu.new(10, 3)
  g.takeDamage()
  g.setForeground(0xFFFFFF)
  g.set(2, 2, "hi")
  g.setForeground(0x00FF00)
  g.set(4, 2, "yo")
  local runs = g.takeDamage()
  assert(#runs == 2 and runs[1][1] == 2 and runs[1][3] == "hi" and runs[2][1] == 4 and runs[2][3] == "yo"
    and runs[2][4] == 0x00FF00, "two runs")
  assert(#g.takeDamage() == 0, "nothing new")
  g.setForeground(0xFFFFFF)
  g.set(2, 2, "hi") -- the same characters in the same colors
  assert(#g.takeDamage() == 0, "writing what's already there isn't a change")
  local all = g.takeDamage(true)
  assert(#all >= 3, "takeDamage(true): the whole screen")
end
print("  OK")

print("vgpu 4: the real compositor draws a desktop into it")
do
  local g = vgpu.new(40, 12)
  local ids = 0
  local compositor = loadSibling("compositor.lua")(loadSibling, {gpu = g, nextId = function() ids = ids + 1 return 100 + ids end})
  local text = assert(compositor.createWindow({title = "console", x = 1, y = 6, width = 40, height = 5, text = true}))
  compositor.setText(text.id, {"hello from a session"})
  local code = assert(compositor.createWindow({title = "drawn", x = 3, y = 1, width = 10, height = 2,
    code = 'gpu.setBackground(0x0000FF) gpu.fill(1, 1, 10, 2, " ") gpu.set(2, 1, "code!")'}))
  assert(text.id == 101 and code.id == 102, "ids from the shared allocator")
  compositor.flush()
  assert(row(g, 7, 1, 20) == "hello from a session", "the text window: " .. row(g, 7, 1, 20))
  assert(row(g, 1, 3, 6) == "draw", "a title bar (cut short of its buttons): " .. row(g, 1, 3, 8))
  assert(row(g, 2, 4, 8) == "code!" and select(3, g.get(4, 2)) == 0x0000FF, "draw code ran in the window's buffer")
  local runs = g.takeDamage()
  assert(#runs > 0, "the frame came out as damage")
  compositor.minimize(code.id, true)
  compositor.flush()
  assert(row(g, 2, 4, 8) ~= "code!", "minimizing uncovers what's behind")
end
print("  OK")
print("ALL OK")
