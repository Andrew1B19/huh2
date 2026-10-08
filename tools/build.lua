-- Builds the muxos installer. Run from anywhere with plain Lua 5.3:
--
--   lua5.3 tools/build.lua               dist/muxos-installer.lua (the program)
--                                        + dist/muxos-installer.dat (its files)
--   lua5.3 tools/build.lua --out <file>  the same pair elsewhere (<file>.lua
--                                        and, next to it, the .dat)
--
-- Checks first, and builds nothing if any fails: every file compiles,
-- both EEPROM images fit in 4096 bytes, and the kernal and worker runtime
-- agree on the version. The output is deterministic (files in a fixed
-- order), so dist/ only changes when what it installs does;
-- test/emu/install_test.lua fails if dist/ is stale.

local ROOT = (arg[0]:match("^(.*)/tools/build%.lua$")) or "."
local EEPROM_SIZE = 4096

-- Line endings are normalized to LF: a checkout converted to CRLF (git's
-- core.autocrlf on Windows) builds the same installer, byte for byte.
local function readFile(path)
  local f = assert(io.open(ROOT .. "/" .. path, "rb"), "missing " .. path)
  local data = f:read("a")
  f:close()
  return (data:gsub("\r\n", "\n"))
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
-- The BIOS images come first: flashing EEPROMs needs only them, so the
-- installer stops reading there instead of streaming the whole payload.
local FILES = {
  {"/eeprom/kernal.lua", "kernal/bios.lua"},
  {"/eeprom/worker.lua", "node/bios.lua"},
  {"/muxos.lua", "kernal/muxos.lua"},
  {"/compositor.lua", "kernal/compositor.lua"},
  {"/bitmap.lua", "kernal/bitmap.lua"},
  {"/runtime.lua", "node/runtime.lua"},
}
for _, rel in ipairs(listDir("kernal/lib")) do
  if rel ~= "README.md" then FILES[#FILES + 1] = {"/lib/" .. rel, "kernal/lib/" .. rel} end
end
-- OPM, the package manager, ships with muxos.
FILES[#FILES + 1] = {"/bin/opm.mxe", "opm/opm.mxe"}
FILES[#FILES + 1] = {"/lib/mxe/opm_core.lua", "opm/opm_core.lua"}

local function build()
  local errors = {}
  local contents = {}
  for i, entry in ipairs(FILES) do
    local data = readFile(entry[2])
    contents[i] = data
    if entry[2]:match("%.lua$") or entry[2]:match("%.mxe$") then
      local ok, err = load(data, "=" .. entry[2], "t")
      if not ok then errors[#errors + 1] = err end
    end
    if entry[1]:match("^/eeprom/") and #data > EEPROM_SIZE then
      errors[#errors + 1] = entry[2] .. " is " .. #data .. " bytes; an EEPROM holds " .. EEPROM_SIZE
    end
  end
  -- The wire codec is duplicated by hand in the kernal and the worker
  -- runtime (neither can require a shared file); the two must not drift.
  local function codec(text)
    local a = text:find("local function serializeNumber", 1, true)
    local b = a and text:find("\n  deserialize = function", a, true)
    local e = b and text:find("\nend\n", b, true)
    return e and text:sub(a, e)
  end
  local kernalCodec, runtimeCodec = codec(readFile("kernal/muxos.lua")), codec(readFile("node/runtime.lua"))
  if not kernalCodec or kernalCodec ~= runtimeCodec then
    errors[#errors + 1] = "the wire codec (serialize/deserialize) differs between kernal/muxos.lua and node/runtime.lua"
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

-- The payload: every file the installer installs, in the data file next
-- to it (muxos-installer.dat). Kept out of the program itself so OpenOS --
-- and the kernal BIOS, booting bare -- only load a small program: loading
-- runs at floppy speed, and a 300 KB program took tens of seconds to
-- start. The installer reads the data file as it needs it.
local function payload(b)
  local out = {"--[[MUXOS-PAYLOAD " .. b.version .. "\n", "@@MANIFEST " .. #FILES .. "\n"}
  for i, entry in ipairs(FILES) do out[#out + 1] = #b.contents[i] .. " " .. entry[1] .. "\n" end
  for i, entry in ipairs(FILES) do
    out[#out + 1] = "@@ " .. #b.contents[i] .. " " .. entry[1] .. "\n"
    out[#out + 1] = b.contents[i]
    out[#out + 1] = "\n"
  end
  out[#out + 1] = "@@END\n"
  return table.concat(out)
end

local out = ROOT .. "/dist/muxos-installer.lua"
local i = 1
while arg[i] do
  if arg[i] == "--out" then out = arg[i + 1] i = i + 2
  else io.stderr:write("unknown argument " .. arg[i] .. "\n") os.exit(2) end
end
local dat = out:gsub("%.lua$", "") .. ".dat"

local b, err = build()
if not b then
  io.stderr:write("build failed:\n" .. err .. "\n")
  os.exit(1)
end
local data = payload(b)
local sized
b.installer, sized = b.installer:gsub("local DAT_SIZE = nil", "local DAT_SIZE = " .. #data, 1)
if sized ~= 1 then
  io.stderr:write("build failed:\ninstaller/install.lua has no DAT_SIZE line to fill in\n")
  os.exit(1)
end
os.execute('mkdir -p "' .. (out:match("^(.*)/[^/]*$") or ".") .. '"')
writeFile(out, b.installer)
writeFile(dat, data)
print(string.format("muxos %s: %s (%.1f KB) + %s (%d files, %.1f KB)", b.version, out, #b.installer / 1024,
  dat, #FILES, #data / 1024))
