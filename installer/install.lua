-- muxos installer. Runs two ways:
--   * booted bare by the kernal BIOS from a disk that has no muxos on it
--     yet -- a floppy with this file at its root, as /muxos-installer.lua
--     (no OpenOS anywhere): it draws its own console and reads the keyboard;
--   * as a program on OpenOS:
--       muxos-installer.lua                     menu
--       muxos-installer.lua kernal [options]    install muxos on a disk and
--                                               flash this computer's EEPROM
--       muxos-installer.lua worker [options]    flash worker EEPROMs (swap
--                                               them in one after another)
--       muxos-installer.lua bios [options]      flash kernal BIOS EEPROMs, for
--                                               computers that will boot this
--                                               installer from a floppy
--       muxos-installer.lua check               say which BIOS an EEPROM holds
--     Options: --disk=<address prefix or label> (kernal target), --yes
--     (don't ask; take the only disk), --count=<n> (worker: flash n
--     EEPROMs), --reboot (kernal: reboot when done).
--
-- tools/build.lua makes this program (dist/muxos-installer.lua) and its
-- data file (dist/muxos-installer.dat, every file it installs). The two
-- go side by side, e.g. at a floppy's root. The program is small so it
-- starts fast -- loading runs at floppy speed -- and the data file is
-- streamed as needed, never all held in memory: the BIOS images come
-- first, so flashing EEPROMs reads only those. On the target disk each file
-- is first written as <name>.new and only swapped in once all of them are
-- written, so a disk that fills up mid-install leaves the old system
-- untouched.

local VERSION = "dev" -- set by tools/build.lua
local CHUNK = 8192

-- --- Platform: OpenOS, or bare from the kernal BIOS ---

local launchArgs = table.pack(...)
local bare = type(require) ~= "function"
local component, computer = component, computer
local osfs
if not bare then
  component, computer, osfs = require("component"), require("computer"), require("filesystem")
end

local options, positional = {}, {}
if not bare then
  for _, a in ipairs(launchArgs) do
    local k, v = tostring(a):match("^%-%-([%w%-]+)=(.*)$")
    if k then
      options[k] = v
    elseif tostring(a):match("^%-%-") then
      options[tostring(a):sub(3)] = true
    else
      positional[#positional + 1] = a
    end
  end
end
local assumeYes = options.yes == true

local function trim(s) return s and s:match("^%s*(.-)%s*$") or nil end

-- Lets the machine breathe during long work: OpenComputers ends a
-- program that runs too long without yielding.
local function breathe()
  if bare then computer.pullSignal(0) else os.sleep(0) end
end

local say, ask
if not bare then
  say = function(...) print(...) end
  ask = function(prompt)
    io.write(prompt)
    return trim(io.read())
  end
else
  -- A minimal console on the GPU: text that wraps and scrolls, and a line
  -- editor on the keyboard (printable characters, backspace, Enter).
  local gpuAddr, screenAddr = component.list("gpu")(), component.list("screen")()
  local gpu = gpuAddr and component.proxy(gpuAddr)
  local w, h, x, y = 80, 25, 1, 1
  if gpu then
    if screenAddr then gpu.bind(screenAddr) end
    w, h = gpu.getResolution()
    gpu.setBackground(0x000000)
    gpu.setForeground(0xFFFFFF)
    gpu.fill(1, 1, w, h, " ")
  end
  local function newline()
    x = 1
    if y < h then
      y = y + 1
    elseif gpu then
      gpu.copy(1, 2, w, h - 1, 0, -1)
      gpu.fill(1, h, w, 1, " ")
    end
  end
  local function write(text)
    for piece, nl in text:gmatch("([^\n]*)(\n?)") do
      while #piece > 0 do
        if x > w then newline() end
        local part = piece:sub(1, w - x + 1)
        if gpu then gpu.set(x, y, part) end
        x, piece = x + #part, piece:sub(#part + 1)
      end
      if nl ~= "" then newline() end
    end
  end
  say = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    write(table.concat(parts, "\t") .. "\n")
  end
  ask = function(prompt)
    write(prompt)
    local line = ""
    while true do
      local name, _, char, code = computer.pullSignal()
      if name == "key_down" then
        if code == 28 then
          write("\n")
          return trim(line)
        elseif code == 14 then
          if #line > 0 then
            line = line:sub(1, -2)
            if x > 1 then x = x - 1 elseif y > 1 then x, y = w, y - 1 end
            if gpu then gpu.set(x, y, " ") end
          end
        elseif char and char >= 32 and char < 127 then
          line = line .. string.char(char)
          write(string.char(char))
        end
      end
    end
  end
end

-- `defaultYes`: Enter alone means yes (for steps you're plainly there
-- to do, like flashing the EEPROM you just put in).
local function confirm(prompt, defaultYes)
  if assumeYes then return true end
  local a = (ask(prompt .. (defaultYes and " [Y/n] " or " [y/N] ")) or ""):lower()
  if a == "" then return defaultYes == true end
  return a == "y" or a == "yes"
end

local function human(bytes)
  if bytes >= 1048576 then return string.format("%.1f MB", bytes / 1048576) end
  return string.format("%.1f KB", bytes / 1024)
end

-- --- Where the files come from ---

-- The disk this installer is on and its path there: the BIOS says when
-- booted bare; on OpenOS it's found from the program's own path.
--
-- On OpenOS, debug.getinfo(1) doesn't name this file: OpenComputers wraps
-- getinfo, so level 1 is the wrapper. So walk up to the first frame that
-- is a .lua file. A relative name (`lua muxos-installer.lua`) is resolved
-- against the working directory. OpenOS's $_ is only a last resort: it
-- names the program the shell started, which is /bin/lua.lua under `lua`.
local function programPath()
  local shell = require("shell")
  if debug and debug.getinfo then
    for level = 1, 10 do
      local ok, info = pcall(debug.getinfo, level, "S")
      if not ok or not info then break end
      local src = info.source and info.source:match("^[@=](.+%.lua)$")
      if src then
        src = shell.resolve(src)
        if src and osfs.exists(src) and not osfs.isDirectory(src) then return src end
      end
    end
  end
  local underscore = os.getenv and os.getenv("_")
  if underscore and osfs.exists(underscore) then return underscore end
end

local function findMedium()
  if bare then
    local address, path = launchArgs[1], launchArgs[2]
    if type(address) ~= "string" or type(path) ~= "string" then return nil, "booted without its disk's address" end
    return {address = address, fs = component.proxy(address), path = path}
  end
  local full = programPath()
  if not full then return nil, "can't tell where this installer is" end
  local fs, mount = osfs.get(full)
  if not fs then return nil, "can't tell which disk " .. full .. " is on" end
  local rel = full:sub(#mount + 1):gsub("^/*", "/")
  return {address = fs.address, fs = fs, path = rel, osPath = full}
end

-- A buffered reader over a file on a filesystem component: line() and
-- bytes(n), nil at the end.
local function openReader(fs, path)
  local handle = fs.open(path, "r")
  if not handle then return nil end
  local buf, eof = "", false
  local function fill()
    if eof then return false end
    local data = fs.read(handle, CHUNK)
    if not data then eof = true return false end
    buf = buf .. data
    return true
  end
  local r = {}
  function r.line()
    while true do
      local i = buf:find("\n", 1, true)
      if i then
        local line = buf:sub(1, i - 1)
        buf = buf:sub(i + 1)
        return line
      end
      if not fill() then
        if buf == "" then return nil end
        local line = buf
        buf = ""
        return line
      end
    end
  end
  function r.bytes(n)
    while #buf < n and fill() do end
    if buf == "" then return nil end
    local data = buf:sub(1, n)
    buf = buf:sub(n + 1)
    return data
  end
  function r.close() fs.close(handle) end
  return r
end

-- A payload: `files`, a list of {path, size}, and each(fn), calling
-- fn(path, size, read) for every file in order, where read(n) returns up
-- to n more bytes of it (nil at its end). fn returning true stops there.
local function bundledPayload(fs, path)
  local f = openReader(fs, path)
  if not f then return nil, "not there" end
  local first
  while true do
    local line = f.line()
    first = first or line
    if not line then
      f.close()
      return nil, "it's there, but isn't a muxos data file (it starts: "
        .. string.format("%q", (first or ""):sub(1, 40)) .. ")"
    end
    if line:match("^%-%-%[=*%[MUXOS%-PAYLOAD") then
      if line:sub(-1) == "\r" then
        f.close()
        return nil, "the installer's data file had its line endings converted to CRLF, which breaks it -- "
          .. "download it again as-is (raw, not through a converting checkout)"
      end
      local version = line:match("^%-%-%[=*%[MUXOS%-PAYLOAD (%S+)")
      if VERSION ~= "dev" and version and version ~= VERSION then
        f.close()
        return nil, "it's the data file for muxos " .. version .. ", but this installer is " .. VERSION
          .. " -- get both files again, together"
      end
      break
    end
  end
  local count = tonumber((f.line() or ""):match("^@@MANIFEST (%d+)$"))
  if not count then f.close() return nil, "damaged payload (no manifest)" end
  local files = {}
  for i = 1, count do
    local size, name = (f.line() or ""):match("^(%d+) (.+)$")
    if not size then f.close() return nil, "damaged payload (manifest)" end
    files[i] = {path = name, size = tonumber(size)}
  end
  f.close()
  local payload = {files = files}
  function payload.each(fn)
    local g = assert(openReader(fs, path))
    repeat local line = g.line() until not line or line:match("^@@MANIFEST")
    for _ = 1, count do g.line() end
    for i = 1, count do
      local size, name = (g.line() or ""):match("^@@ (%d+) (.+)$")
      size = tonumber(size)
      if not size or name ~= files[i].path or size ~= files[i].size then
        g.close()
        error("damaged payload at " .. tostring(files[i].path), 0)
      end
      local remaining = size
      local function read(n)
        if remaining <= 0 then return nil end
        local data = g.bytes(math.min(n, remaining))
        if not data or data == "" then error("damaged payload: " .. name .. " is cut short", 0) end
        remaining = remaining - #data
        return data
      end
      if fn(name, size, read) then break end
      while remaining > 0 do read(CHUNK) end
      g.bytes(1) -- the newline after each file
    end
    g.close()
  end
  return payload
end

local medium, mediumErr = findMedium()
local DAT_NAME = "muxos-installer.dat"

-- OpenOS's own files, for reading the data file by its OpenOS path: the
-- same calls as a filesystem component, so openReader works on it.
local osFiles = {
  open = function(path) return io.open(path, "rb") end,
  read = function(handle, n) return handle:read(n) end,
  close = function(handle) handle:close() end,
}

-- The files to install are in muxos-installer.dat, next to this program.
-- Looked for there first, then at the root of every disk. If it isn't
-- found, the error lists every place tried and why each didn't do.
local function findPayload()
  local tried, seen = {}, {}
  local function try(fs, path, where, key)
    if key then
      if seen[key] then return end
      seen[key] = true
    end
    local payload, err = bundledPayload(fs, path)
    if payload then return payload end
    tried[#tried + 1] = "  " .. where .. ": " .. tostring(err)
  end
  local payload
  if medium then
    local dat = medium.path:gsub("[^/]*$", "") .. DAT_NAME
    local where = medium.osPath and medium.osPath:gsub("[^/]*$", "") .. DAT_NAME
      or "disk " .. tostring(medium.address):sub(1, 8) .. " " .. dat
    payload = try(medium.fs, dat, where, tostring(medium.address) .. dat)
    if not payload and medium.osPath then
      payload = try(osFiles, (medium.osPath:gsub("[^/]*$", "") .. DAT_NAME), where .. " (through OpenOS)")
    end
  else
    tried[#tried + 1] = "  next to the installer: " .. tostring(mediumErr)
  end
  if not payload then
    for address in component.list("filesystem") do
      payload = try(component.proxy(address), "/" .. DAT_NAME, "disk " .. address:sub(1, 8) .. " /" .. DAT_NAME,
        address .. "/" .. DAT_NAME)
      if payload then break end
    end
  end
  if payload then return payload end
  return nil, "can't find " .. DAT_NAME .. " (it goes next to muxos-installer.lua; the two files go together). Looked at:\n"
    .. table.concat(tried, "\n")
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
      if written % (CHUNK * 4) == 0 then breathe() end
    end
    target.close(h)
    if written ~= size or target.size(tmp) ~= size then error("short write: " .. path, 0) end
    say("  " .. path)
    breathe()
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

-- --- Flashing EEPROMs ---

-- Flashes a BIOS onto EEPROMs one after another, as they're swapped into
-- this computer: the worker BIOS for the workers, or the kernal BIOS for
-- a kernal that will boot this installer (an empty computer has nothing
-- else to start it with).
local BIOSES = {
  worker = {path = "/eeprom/worker.lua", label = "muxos worker", name = "worker"},
  kernal = {path = "/eeprom/kernal.lua", label = "muxos kernal", name = "kernal"},
}

-- Both BIOS images from the payload, in one pass.
local function readBioses(payload)
  local images = {}
  payload.each(function(path, _, read)
    for _, bios in pairs(BIOSES) do
      if path == bios.path then
        local parts = {}
        for data in read, CHUNK do parts[#parts + 1] = data end
        images[bios.name] = table.concat(parts)
      end
    end
    return images.worker ~= nil and images.kernal ~= nil
  end)
  return images
end

-- What an EEPROM holds, in words.
local function describeEeprom(eeprom, images)
  local code = eeprom.get() or ""
  local label = eeprom.getLabel and eeprom.getLabel() or ""
  if code == "" then return "blank -- nothing on it (a computer says \"no bios found\")" end
  for name, image in pairs(images) do
    if code == image then return "the muxos " .. name .. " BIOS, this version (" .. #code .. " bytes)" end
  end
  if label:match("^muxos ") then
    return "a " .. label .. " BIOS from a different muxos version (" .. #code .. " bytes) -- reflash it"
  end
  return "something else: \"" .. label .. "\", " .. #code .. " bytes"
end

-- Identifies the EEPROM in this computer, and the next ones swapped in.
local function checkEeproms(payload)
  local images = readBioses(payload)
  while true do
    local eeprom = currentEeprom()
    say(eeprom and ("EEPROM " .. eeprom.address:sub(1, 8) .. ": " .. describeEeprom(eeprom, images))
      or "No EEPROM in this computer.")
    if assumeYes then break end
    local answer = ask("Swap in another EEPROM and press Enter, or q to finish: ")
    if not answer or answer:lower() == "q" then break end
  end
  return true
end

local function flashEeproms(payload, bios)
  local images = readBioses(payload)
  local code = images[bios.name]
  if not code then return nil, "the " .. bios.name .. " BIOS is missing from the installer" end
  say("Flashes the muxos " .. bios.name .. " BIOS (" .. #code .. " bytes) onto EEPROMs, one after another:")
  say("put an EEPROM in this computer, flash it, swap in the next.")
  say(bare and "Put the kernal BIOS EEPROM back in when you're done."
    or "Put this computer's own EEPROM back when you're done.")
  local want = tonumber(options.count)
  local count, last = 0, nil
  while true do
    local eeprom = currentEeprom()
    if not eeprom then
      say("No EEPROM in this computer.")
    elseif eeprom.address == last then
      say("That's the EEPROM that was just flashed -- swap in the next one.")
    else
      say("EEPROM " .. eeprom.address:sub(1, 8) .. " now holds " .. describeEeprom(eeprom, images) .. ".")
      if confirm("Flash it as a muxos " .. bios.name .. "?", true) then
        local addr, err = flash(code, bios.label, "")
        if addr then
          count, last = count + 1, addr
          say("Flashed " .. bios.name .. " EEPROM " .. count .. " (" .. addr:sub(1, 8) .. "): "
            .. describeEeprom(eeprom, images) .. ", checked byte for byte.")
        else
          say("Couldn't flash it: " .. err)
        end
      else
        say("Skipped -- not flashed.")
      end
    end
    if want and count >= want then break end
    if assumeYes and not want then break end
    local answer = ask("Swap in the next EEPROM and press Enter, or q to finish: ")
    if not answer or answer:lower() == "q" then break end
  end
  say(count .. " " .. bios.name .. " EEPROM(s) flashed.")
  return true
end

-- --- Main ---

local function main()
  say("muxos " .. VERSION .. " installer" .. (bare and " (booted from " .. tostring(medium and medium.address or "?"):sub(1, 8) .. ")" or ""))
  local payload, err = findPayload()
  if not payload then
    say("error: " .. tostring(err))
    return 1
  end
  local mode = positional[1]
  if not mode then
    say("  1) install the kernal on this computer")
    say("  2) flash worker EEPROMs")
    say("  3) flash kernal BIOS EEPROMs (for computers that will boot this installer)")
    say("  4) check which BIOS an EEPROM holds")
    say("  5) quit")
    local pick = ask("> ")
    mode = ({["1"] = "kernal", ["2"] = "worker", ["3"] = "bios", ["4"] = "check"})[pick or ""]
    if not mode then return 0 end
  end
  local ok, failure
  if mode == "kernal" then
    ok, failure = installKernal(payload)
    if ok then
      if options.reboot or (not assumeYes and confirm("Reboot into muxos now?")) then computer.shutdown(true) end
      say("Reboot this computer to start muxos. Workers boot from the network once flashed.")
      if bare then say("(The EEPROM now boots the installed disk first; the floppy can stay in.)") end
    end
  elseif mode == "worker" then
    ok, failure = flashEeproms(payload, BIOSES.worker)
  elseif mode == "bios" then
    ok, failure = flashEeproms(payload, BIOSES.kernal)
  elseif mode == "check" then
    ok, failure = checkEeproms(payload)
  else
    say("usage: muxos-installer.lua [kernal|worker|bios|check] [--disk=<address|label>] [--yes] [--count=<n>] [--reboot]")
    return 1
  end
  if not ok then
    say("error: " .. tostring(failure))
    return 1
  end
  return 0
end

-- Booted bare there's nothing to return to: wait, then restart.
if bare then
  local ok, err = pcall(main)
  if not ok then say("error: " .. tostring(err)) end
  ask("Press Enter to restart.")
  computer.shutdown(true)
end
return main()
