-- muxos installer. Runs on OpenOS.
--
--   install.lua                     menu
--   install.lua kernal [options]    install muxos on a disk and flash this
--                                   computer's EEPROM with the kernal BIOS
--   install.lua worker [options]    flash worker EEPROMs (swap them in one
--                                   after another)
--
-- Options: --disk=<address prefix or label> (kernal target), --yes (don't
-- ask; take the only disk), --count=<n> (worker: flash n EEPROMs),
-- --reboot (kernal: reboot when done).
--
-- tools/build.lua makes two forms of this file: dist/muxos-installer.lua,
-- with every file it installs carried in a comment at its end (one file
-- to wget or copy), and a floppy layout, install.lua next to a files/
-- directory. Either way the files are streamed from where they are,
-- never all held in memory. On the target disk each file is first
-- written as <name>.new and only swapped in once all of them are
-- written, so a disk that fills up mid-install leaves the old system
-- untouched.

local component = require("component")
local computer = require("computer")
local filesystem = require("filesystem")

local VERSION = "dev" -- set by tools/build.lua
local CHUNK = 8192

local options, positional = {}, {}
for _, a in ipairs({...}) do
  local k, v = tostring(a):match("^%-%-([%w%-]+)=(.*)$")
  if k then
    options[k] = v
  elseif tostring(a):match("^%-%-") then
    options[tostring(a):sub(3)] = true
  else
    positional[#positional + 1] = a
  end
end
local assumeYes = options.yes == true

local function say(...) print(...) end

local function ask(prompt)
  io.write(prompt)
  local line = io.read()
  return line and line:match("^%s*(.-)%s*$") or nil
end

local function confirm(prompt)
  if assumeYes then return true end
  local a = (ask(prompt .. " [y/N] ") or ""):lower()
  return a == "y" or a == "yes"
end

local function human(bytes)
  if bytes >= 1048576 then return string.format("%.1f MB", bytes / 1048576) end
  return string.format("%.1f KB", bytes / 1024)
end

-- --- Where the files come from ---

local function selfPath()
  local info = debug and debug.getinfo and debug.getinfo(1, "S")
  local p = info and info.source and info.source:match("^[@=](.+)$")
  if p and filesystem.exists(p) then return p end
  local fromEnv = os.getenv and os.getenv("_")
  if fromEnv and filesystem.exists(fromEnv) then return fromEnv end
  return nil
end

-- A payload: `files`, a list of {path, size}, and each(fn), calling
-- fn(path, size, read) for every file in order, where read(n) returns up
-- to n more bytes of it (nil at its end).
local function bundledPayload(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  while true do
    local line = f:read("l")
    if not line then f:close() return nil end
    if line:match("^%-%-%[=*%[MUXOS%-PAYLOAD") then break end
  end
  local count = tonumber((f:read("l") or ""):match("^@@MANIFEST (%d+)$"))
  if not count then f:close() return nil, "damaged payload (no manifest)" end
  local files = {}
  for i = 1, count do
    local size, name = (f:read("l") or ""):match("^(%d+) (.+)$")
    if not size then f:close() return nil, "damaged payload (manifest)" end
    files[i] = {path = name, size = tonumber(size)}
  end
  f:close()
  local payload = {files = files}
  function payload.each(fn)
    local g = assert(io.open(path, "rb"))
    repeat local line = g:read("l") until not line or line:match("^@@MANIFEST")
    for _ = 1, count do g:read("l") end
    for i = 1, count do
      local size, name = (g:read("l") or ""):match("^@@ (%d+) (.+)$")
      size = tonumber(size)
      if not size or name ~= files[i].path or size ~= files[i].size then
        g:close()
        error("damaged payload at " .. tostring(files[i].path), 0)
      end
      local remaining = size
      local function read(n)
        if remaining <= 0 then return nil end
        local data = g:read(math.min(n, remaining))
        if not data or data == "" then error("damaged payload: " .. name .. " is cut short", 0) end
        remaining = remaining - #data
        return data
      end
      fn(name, size, read)
      while remaining > 0 do read(CHUNK) end
      g:read(1) -- the newline after each file
    end
    g:close()
  end
  return payload
end

local function floppyPayload(dir)
  local m = io.open(dir .. "/files/MANIFEST", "r")
  if not m then return nil end
  local files = {}
  for line in m:lines() do
    local size, name = line:match("^(%d+) (.+)$")
    if size then files[#files + 1] = {path = name, size = tonumber(size)} end
  end
  m:close()
  local payload = {files = files}
  function payload.each(fn)
    for _, file in ipairs(files) do
      local g = io.open(dir .. "/files" .. file.path, "rb")
      if not g then error("missing from the installer: " .. file.path, 0) end
      fn(file.path, file.size, function(n)
        local data = g:read(n)
        if data == "" then return nil end
        return data
      end)
      g:close()
    end
  end
  return payload
end

local function findPayload()
  local me = selfPath()
  if not me then return nil, "can't tell where this installer is" end
  local payload, err = bundledPayload(me)
  if payload then return payload end
  if err then return nil, err end
  payload = floppyPayload(me:match("^(.*)/[^/]*$") or ".")
  if payload then return payload end
  return nil, "no files to install next to " .. me
end

-- Reads one (small) file of the payload whole.
local function readPayloadFile(payload, wanted)
  local found
  payload.each(function(path, _, read)
    if path == wanted then
      local parts = {}
      for data in read, CHUNK do parts[#parts + 1] = data end
      found = table.concat(parts)
    end
  end)
  return found
end

-- --- EEPROM ---

local function currentEeprom()
  local addr = component.list("eeprom")()
  return addr and component.proxy(addr)
end

local function flash(code, label, data)
  local eeprom = currentEeprom()
  if not eeprom then return nil, "there's no EEPROM in this computer" end
  local size = eeprom.getSize and eeprom.getSize() or 4096
  if #code > size then return nil, "the BIOS is " .. #code .. " bytes, the EEPROM holds " .. size end
  local ok, result, err = pcall(eeprom.set, code)
  if not ok then return nil, tostring(result) end
  if result == nil and err then return nil, tostring(err) end
  if eeprom.get() ~= code then return nil, "the EEPROM didn't keep what was written (is it read-only?)" end
  if eeprom.setLabel then pcall(eeprom.setLabel, label) end
  if data then eeprom.setData(data) end
  return eeprom.address
end

-- --- Kernal ---

local function diskList(exclude)
  local disks = {}
  local tmp = computer.tmpAddress and computer.tmpAddress()
  for addr in component.list("filesystem") do
    local fs = component.proxy(addr)
    if addr ~= exclude and addr ~= tmp and not fs.isReadOnly() then
      disks[#disks + 1] = {address = addr, fs = fs, label = fs.getLabel() or "",
        free = fs.spaceTotal() - fs.spaceUsed()}
    end
  end
  table.sort(disks, function(a, b) return a.address < b.address end)
  return disks
end

local function chooseDisk(disks)
  if options.disk then
    for _, d in ipairs(disks) do
      if d.address:sub(1, #options.disk) == options.disk or d.label == options.disk then return d end
    end
    return nil, "no writable disk matches " .. options.disk
  end
  if #disks == 0 then return nil, "no writable disk found (the installer's own disk doesn't count)" end
  say("Disks:")
  for i, d in ipairs(disks) do
    say(string.format("  %d) %s  %s  %s free", i, d.address:sub(1, 8), d.label ~= "" and d.label or "(no label)",
      human(d.free)))
  end
  if #disks == 1 and assumeYes then return disks[1] end
  local pick = tonumber(ask("Install muxos on which disk? "))
  if not pick or not disks[pick] then return nil, "no disk chosen" end
  return disks[pick]
end

local function hardwareWarnings()
  local warnings = {}
  local gpuAddr = component.list("gpu")()
  if not gpuAddr then
    warnings[#warnings + 1] = "no GPU: the kernal needs a tier 3 GPU"
  else
    local gpu = component.proxy(gpuAddr)
    local ok, depth = pcall(gpu.maxDepth)
    if not ok or depth < 8 or not gpu.allocateBuffer then
      warnings[#warnings + 1] = "the GPU isn't tier 3: muxos's compositor needs a tier 3 GPU (video buffers)"
    end
  end
  if not component.list("screen")() then warnings[#warnings + 1] = "no screen attached" end
  if not component.list("modem")() then
    warnings[#warnings + 1] = "no network card: the kernal can't reach its workers"
  end
  return warnings
end

local function readText(fs, path)
  if not fs.exists(path) then return nil end
  local h = fs.open(path, "r")
  if not h then return nil end
  local parts = {}
  while true do
    local data = fs.read(h, CHUNK)
    if not data then break end
    parts[#parts + 1] = data
  end
  fs.close(h)
  return table.concat(parts)
end

local function writeText(fs, path, text)
  local h = assert(fs.open(path, "w"))
  fs.write(h, text)
  fs.close(h)
end

local function installKernal(payload)
  local me = selfPath()
  local medium = me and filesystem.get(me)
  local disk, err = chooseDisk(diskList(medium and medium.address))
  if not disk then return nil, err end
  local target = disk.fs

  local needed = 0
  for _, file in ipairs(payload.files) do
    if not file.path:match("^/eeprom/") then needed = needed + file.size end
  end
  -- Old and new copies are both on the disk until the swap.
  if disk.free < needed + 4096 then
    return nil, "not enough space on " .. disk.address:sub(1, 8) .. ": " .. human(needed) .. " needed, "
      .. human(disk.free) .. " free"
  end

  for _, w in ipairs(hardwareWarnings()) do say("warning: " .. w) end
  local previous = readText(target, "/.muxos-version")
  say(previous and ("Upgrading muxos " .. previous:match("^%s*(.-)%s*$") .. " to " .. VERSION)
    or ("Installing muxos " .. VERSION))
  say("Target: " .. disk.address .. (disk.label ~= "" and (" (" .. disk.label .. ")") or ""))
  say("This also flashes this computer's EEPROM with the muxos kernal BIOS.")
  if not confirm("Continue?") then return nil, "cancelled" end

  local staged, kernalBios = {}, nil
  local ok, failure = pcall(payload.each, function(path, size, read)
    if path == "/eeprom/kernal.lua" then
      local parts = {}
      for data in read, CHUNK do parts[#parts + 1] = data end
      kernalBios = table.concat(parts)
      return
    elseif path:match("^/eeprom/") then
      return
    end
    local dir = path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" then target.makeDirectory(dir) end
    local tmp = path .. ".new"
    local h, openErr = target.open(tmp, "w")
    if not h then error("can't write " .. tmp .. ": " .. tostring(openErr), 0) end
    staged[#staged + 1] = path
    local written = 0
    for data in read, CHUNK do
      local wrote, writeErr = target.write(h, data)
      if not wrote then
        target.close(h)
        error("can't write " .. tmp .. ": " .. tostring(writeErr or "disk full?"), 0)
      end
      written = written + #data
    end
    target.close(h)
    if written ~= size or target.size(tmp) ~= size then error("short write: " .. path, 0) end
    say("  " .. path)
  end)
  if not ok or not kernalBios then
    for _, path in ipairs(staged) do target.remove(path .. ".new") end
    return nil, (ok and "the kernal BIOS is missing from the installer" or tostring(failure))
      .. " -- nothing was changed"
  end

  -- Everything is written: swap the new files in.
  for _, path in ipairs(staged) do
    if target.exists(path) then target.remove(path) end
    if not target.rename(path .. ".new", path) then return nil, "couldn't move " .. path .. " into place" end
  end
  writeText(target, "/.muxos-version", VERSION .. "\n")
  for _, dir in ipairs({"/bin", "/usr/bin", "/usr/lib", "/lib/mxe"}) do target.makeDirectory(dir) end

  local flashed, flashErr = flash(kernalBios, "muxos kernal", disk.address)
  if not flashed then return nil, "files installed, but flashing the EEPROM failed: " .. flashErr end
  say("Flashed the kernal BIOS (boots from " .. disk.address:sub(1, 8) .. ").")
  say("muxos " .. VERSION .. " is installed.")
  return true
end

-- --- Workers ---

local function flashWorkers(payload)
  local code = readPayloadFile(payload, "/eeprom/worker.lua")
  if not code then return nil, "the worker BIOS is missing from the installer" end
  say("Flashes the muxos worker BIOS (" .. #code .. " bytes) onto EEPROMs, one after another:")
  say("put a worker's EEPROM in this computer, flash it, swap in the next.")
  say("Put this computer's own EEPROM back when you're done.")
  local want = tonumber(options.count)
  local count, last = 0, nil
  while true do
    local eeprom = currentEeprom()
    if not eeprom then
      say("No EEPROM in this computer.")
    elseif eeprom.address == last then
      say("That's the EEPROM that was just flashed -- swap in the next one.")
    elseif confirm("Flash EEPROM " .. eeprom.address:sub(1, 8) .. " as a muxos worker?") then
      local addr, err = flash(code, "muxos worker", "")
      if addr then
        count, last = count + 1, addr
        say("Flashed worker EEPROM " .. count .. " (" .. addr:sub(1, 8) .. ").")
      else
        say("Couldn't flash it: " .. err)
      end
    end
    if want and count >= want then break end
    if assumeYes and not want then break end
    local answer = ask("Swap in the next EEPROM and press Enter, or q to finish: ")
    if not answer or answer:lower() == "q" then break end
  end
  say(count .. " worker EEPROM(s) flashed.")
  return true
end

-- --- Main ---

local function main()
  say("muxos " .. VERSION .. " installer")
  local payload, err = findPayload()
  if not payload then
    say("error: " .. tostring(err))
    return 1
  end
  local mode = positional[1]
  if not mode then
    say("  1) install the kernal on this computer")
    say("  2) flash worker EEPROMs")
    say("  3) quit")
    local pick = ask("> ")
    mode = ({["1"] = "kernal", ["2"] = "worker"})[pick or ""]
    if not mode then return 0 end
  end
  local ok, failure
  if mode == "kernal" then
    ok, failure = installKernal(payload)
    if ok then
      if options.reboot or (not assumeYes and confirm("Reboot into muxos now?")) then computer.shutdown(true) end
      say("Reboot this computer to start muxos. Workers boot from the network once flashed.")
    end
  elseif mode == "worker" then
    ok, failure = flashWorkers(payload)
  else
    say("usage: install.lua [kernal|worker] [--disk=<address|label>] [--yes] [--count=<n>] [--reboot]")
    return 1
  end
  if not ok then
    say("error: " .. tostring(failure))
    return 1
  end
  return 0
end

return main()
