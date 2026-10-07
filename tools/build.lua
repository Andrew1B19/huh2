-- Builds the muxos installer. Run from anywhere with plain Lua 5.3:
--
--   lua5.3 tools/build.lua                  dist/muxos-installer.lua
--   lua5.3 tools/build.lua --floppy <dir>   also a floppy layout in <dir>:
--                                           install.lua + files/
--   lua5.3 tools/build.lua --out <file>     the single-file installer elsewhere
--
-- Checks first, and builds nothing if any fails: every file compiles,
-- both EEPROM images fit in 4096 bytes, and the kernal and worker runtime
-- agree on the version. The output is deterministic (files in a fixed
-- order), so dist/ only changes when what it installs does;
-- test/emu/install_test.lua fails if dist/ is stale.

local ROOT = (arg[0]:match("^(.*)/tools/build%.lua$")) or "."
local EEPROM_SIZE = 4096

local function readFile(path)
  local f = assert(io.open(ROOT .. "/" .. path, "rb"), "missing " .. path)
  local data = f:read("a")
  f:close()
  return data
end

local function writeFile(path, data)
  local f = assert(io.open(path, "wb"))
  f:write(data)
  f:close()
end

local function listDir(dir)
  local out = {}
  local p = assert(io.popen('cd "' .. ROOT .. "/" .. dir .. '" && find . -type f | LC_ALL=C sort'))
  for line in p:lines() do out[#out + 1] = line:sub(3) end
  p:close()
  return out
end

-- What gets installed: target path on the kernal's disk -> repo file.
-- /eeprom/* are the BIOS images the installer flashes, not disk files.
local FILES = {
  {"/muxos.lua", "kernal/muxos.lua"},
  {"/compositor.lua", "kernal/compositor.lua"},
  {"/bitmap.lua", "kernal/bitmap.lua"},
  {"/runtime.lua", "node/runtime.lua"},
}
for _, rel in ipairs(listDir("kernal/lib")) do
  if rel ~= "README.md" then FILES[#FILES + 1] = {"/lib/" .. rel, "kernal/lib/" .. rel} end
end
FILES[#FILES + 1] = {"/eeprom/kernal.lua", "kernal/bios.lua"}
FILES[#FILES + 1] = {"/eeprom/worker.lua", "node/bios.lua"}

local function build()
  local errors = {}
  local contents = {}
  for i, entry in ipairs(FILES) do
    local data = readFile(entry[2])
    contents[i] = data
    if entry[2]:match("%.lua$") then
      local ok, err = load(data, "=" .. entry[2], "t")
      if not ok then errors[#errors + 1] = err end
    end
    if entry[1]:match("^/eeprom/") and #data > EEPROM_SIZE then
      errors[#errors + 1] = entry[2] .. " is " .. #data .. " bytes; an EEPROM holds " .. EEPROM_SIZE
    end
  end
  local version = readFile("kernal/muxos.lua"):match('local MUXOS_VERSION = "([^"]+)"')
  local runtimeVersion = readFile("node/runtime.lua"):match('local MUXOS_VERSION = "([^"]+)"')
  if not version or version ~= runtimeVersion then
    errors[#errors + 1] = "kernal version " .. tostring(version) .. " ~= runtime version " .. tostring(runtimeVersion)
  end
  local installer = readFile("installer/install.lua")
  local n
  installer, n = installer:gsub('local VERSION = "dev"', 'local VERSION = "' .. tostring(version) .. '"', 1)
  if n ~= 1 then errors[#errors + 1] = "installer/install.lua has no VERSION line to fill in" end
  local ok, err = load(installer, "=installer/install.lua", "t")
  if not ok then errors[#errors + 1] = err end
  if #errors > 0 then return nil, table.concat(errors, "\n") end
  return {version = version, installer = installer, contents = contents}
end

-- The payload rides in a long comment, at a bracket level no file uses.
local function bundle(b)
  local level = 1
  local function clash(eq)
    local close = "]" .. eq .. "]"
    for _, data in ipairs(b.contents) do
      if data:find(close, 1, true) then return true end
    end
    return false
  end
  while clash(("="):rep(level)) do level = level + 1 end
  local eq = ("="):rep(level)
  local out = {b.installer, "\n--[" .. eq .. "[MUXOS-PAYLOAD " .. b.version .. "\n", "@@MANIFEST " .. #FILES .. "\n"}
  for i, entry in ipairs(FILES) do out[#out + 1] = #b.contents[i] .. " " .. entry[1] .. "\n" end
  for i, entry in ipairs(FILES) do
    out[#out + 1] = "@@ " .. #b.contents[i] .. " " .. entry[1] .. "\n"
    out[#out + 1] = b.contents[i]
    out[#out + 1] = "\n"
  end
  out[#out + 1] = "@@END\n]" .. eq .. "]\n"
  return table.concat(out)
end

local function floppy(b, dir)
  os.execute('mkdir -p "' .. dir .. '/files"')
  writeFile(dir .. "/install.lua", b.installer)
  local manifest = {}
  for i, entry in ipairs(FILES) do
    local target = dir .. "/files" .. entry[1]
    os.execute('mkdir -p "' .. target:match("^(.*)/[^/]*$") .. '"')
    writeFile(target, b.contents[i])
    manifest[#manifest + 1] = #b.contents[i] .. " " .. entry[1]
  end
  writeFile(dir .. "/files/MANIFEST", table.concat(manifest, "\n") .. "\n")
end

local out, floppyDir = ROOT .. "/dist/muxos-installer.lua", nil
local i = 1
while arg[i] do
  if arg[i] == "--floppy" then floppyDir = arg[i + 1] i = i + 2
  elseif arg[i] == "--out" then out = arg[i + 1] i = i + 2
  else io.stderr:write("unknown argument " .. arg[i] .. "\n") os.exit(2) end
end

local b, err = build()
if not b then
  io.stderr:write("build failed:\n" .. err .. "\n")
  os.exit(1)
end
local single = bundle(b)
os.execute('mkdir -p "' .. (out:match("^(.*)/[^/]*$") or ".") .. '"')
writeFile(out, single)
print(string.format("muxos %s: %s (%d files, %.1f KB)", b.version, out, #FILES, #single / 1024))
if floppyDir then
  floppy(b, floppyDir)
  print("floppy layout: " .. floppyDir)
end
