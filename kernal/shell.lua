-- muxos shell: POSIX-style commands at the kernal console.
--
-- Loaded by kernal/muxos.lua with loadSibling, like the compositor, and
-- handed what it needs from the kernal as its one argument (see `ctx`
-- below). Everything the console doesn't recognize as one of muxos's own
-- commands comes here.
--
-- What it does, to a reasonable degree of POSIX sh:
--   quoting ('...', "...", \), variables ($VAR, ${VAR}, $?, $$, VAR=value,
--   export/unset), ~, globbing (* ? [...]) in any path component,
--   comments (#), pipelines (|), redirection (> >> < 2> 2>> 2>&1, with
--   /dev/null), lists (; && ||) and & (background, for programs).
-- The core utilities are built in, busybox-style, and run on the kernal
-- itself against its disks -- no worker is involved -- so they're quick.
-- Paths: "/" is the kernal's disk, /tmp its tmpfs, and every other disk
-- (the installer floppy, say) is /mnt/<first characters of its address>,
-- as in OpenOS. Anything not built in is a program (/bin, /usr/bin: .mxe
-- or legacy .lua) or a muxos console command, run as before; their output
-- goes to the console, so it can't be piped or redirected.
--
-- Not done: command substitution, here-documents, functions, control
-- flow (if/for/while), job control beyond &, and grep's patterns are Lua
-- patterns rather than POSIX regular expressions (grep -F matches text).
local ctx = ...
-- ctx = {
--   invoke(address, method, ...)   a component call: results, or nil, err
--   root                           the kernal's disk (filesystem address)
--   tmp                            the tmpfs address, or nil
--   list(type)                     component.list
--   write(text)                    console output (may end mid-line)
--   external(argv, background)     runs a program or console command:
--                                  returns an exit status (127: not found)
--   width()                        the console's width, for ls's columns
--   clear()                        clears the console
--   sleep(seconds)                 waits, keeping the kernal responsive
--   info                           {version, address, uptime(), memory()}
-- }
local M = {}

local env = {HOME = "/home", PATH = "/bin:/usr/bin", PWD = "/", SHELL = "/bin/sh", USER = "root",
  TERM = "muxos"}
local exported = {HOME = true, PATH = true, PWD = true, SHELL = true, USER = true, TERM = true}
local lastStatus = 0

-- --- Paths and disks ---

local function normalize(path)
  local parts = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      parts[#parts] = nil
    elseif part ~= "." then
      parts[#parts + 1] = part
    end
  end
  return "/" .. table.concat(parts, "/")
end

local function absolute(path)
  if path == "~" or path:sub(1, 2) == "~/" then path = env.HOME .. path:sub(2) end
  if path:sub(1, 1) ~= "/" then path = env.PWD .. "/" .. path end
  return normalize(path)
end

-- Every disk other than the kernal's own and the tmpfs, by its /mnt name:
-- the shortest unique prefix of its address, at least 3 characters.
local function mounts()
  local addrs = {}
  for addr in ctx.list("filesystem") do
    if addr ~= ctx.root and addr ~= ctx.tmp then addrs[#addrs + 1] = addr end
  end
  local byName = {}
  for _, addr in ipairs(addrs) do
    local n = 3
    while true do
      local name, clash = addr:sub(1, n), false
      for _, other in ipairs(addrs) do
        if other ~= addr and other:sub(1, n) == name then clash = true break end
      end
      if not clash or n >= #addr then byName[name] = addr break end
      n = n + 1
    end
  end
  return byName
end

-- The disk and path within it for an absolute path. "/mnt" itself is a
-- directory of mount points with no disk of its own (nil).
local function locate(path)
  if path == "/mnt" then return nil, "/" end
  local name, rest = path:match("^/mnt/([^/]+)(.*)$")
  if name then
    local addr = mounts()[name]
    if addr then return addr, rest == "" and "/" or rest end
    return nil, nil
  end
  if ctx.tmp and (path == "/tmp" or path:sub(1, 5) == "/tmp/") then
    local rest2 = path:sub(5)
    return ctx.tmp, rest2 == "" and "/" or rest2
  end
  return ctx.root, path
end

local fs = {}

function fs.call(path, method, ...)
  local addr, rel = locate(path)
  if not addr then return nil, path .. ": no such disk" end
  return ctx.invoke(addr, method, rel, ...)
end

function fs.isDir(path)
  if path == "/" or path == "/mnt" or path == "/tmp" and ctx.tmp then return true end
  local addr, rel = locate(path)
  if not addr then return false end
  if rel == "/" then return true end
  return ctx.invoke(addr, "isDirectory", rel) == true
end

function fs.exists(path)
  if fs.isDir(path) then return true end
  local addr = locate(path)
  return addr ~= nil and fs.call(path, "exists") == true
end

-- Sorted names in a directory; subdirectories end in "/".
function fs.list(path)
  if path == "/mnt" then
    local names = {}
    for name in pairs(mounts()) do names[#names + 1] = name .. "/" end
    table.sort(names)
    return names
  end
  local names, err = fs.call(path, "list")
  if type(names) ~= "table" then return nil, err or (path .. ": not a directory") end
  local out = {}
  for _, n in ipairs(names) do out[#out + 1] = n end
  if path == "/" then
    local seen = {}
    for _, n in ipairs(out) do seen[n] = true end
    if not seen["mnt/"] then out[#out + 1] = "mnt/" end
    if ctx.tmp and not seen["tmp/"] then out[#out + 1] = "tmp/" end
  end
  table.sort(out)
  return out
end

function fs.read(path)
  if path == "/dev/null" then return "" end
  if fs.isDir(path) then return nil, path .. ": is a directory" end
  local h, err = fs.call(path, "open", "r")
  if not h then return nil, path .. ": no such file" end
  local addr = locate(path)
  local parts = {}
  while true do
    local data, readErr = ctx.invoke(addr, "read", h, math.huge)
    if not data then
      ctx.invoke(addr, "close", h)
      if readErr then return nil, path .. ": " .. tostring(readErr) end
      return table.concat(parts)
    end
    parts[#parts + 1] = data
  end
end

function fs.write(path, data, append)
  if path == "/dev/null" then return true end
  if fs.isDir(path) then return nil, path .. ": is a directory" end
  local h, err = fs.call(path, "open", append and "a" or "w")
  if not h then return nil, path .. ": can't write (" .. tostring(err) .. ")" end
  local addr = locate(path)
  for i = 1, #data, 8192 do
    if not ctx.invoke(addr, "write", h, data:sub(i, i + 8191)) then
      ctx.invoke(addr, "close", h)
      return nil, path .. ": write failed (disk full?)"
    end
  end
  ctx.invoke(addr, "close", h)
  return true
end

function fs.size(path) return fs.call(path, "size") or 0 end
function fs.mkdir(path) return fs.call(path, "makeDirectory") end
function fs.remove(path) return fs.call(path, "remove") end

-- Recursively (a directory) or not: true, or nil and why.
function fs.copy(from, to)
  if fs.isDir(from) then
    fs.mkdir(to)
    for _, n in ipairs(fs.list(from) or {}) do
      local name = n:gsub("/$", "")
      local ok, err = fs.copy(from .. "/" .. name, to .. "/" .. name)
      if not ok then return nil, err end
    end
    return true
  end
  local data, err = fs.read(from)
  if not data then return nil, err end
  return fs.write(to, data)
end

function fs.removeAll(path)
  if fs.isDir(path) then
    for _, n in ipairs(fs.list(path) or {}) do fs.removeAll(path .. "/" .. n:gsub("/$", "")) end
  end
  return fs.remove(path)
end

local function basename(path)
  return path:match("([^/]*)/*$")
end

local function dirname(path)
  local d = path:match("^(.*)/[^/]*/*$")
  if not d then return "." end
  if d == "" then return "/" end
  return d
end

-- --- Glob patterns ---

-- A shell glob as a Lua pattern, anchored: * ? [...] [!...].
local function globPattern(glob)
  local out, i = {"^"}, 1
  while i <= #glob do
    local c = glob:sub(i, i)
    if c == "*" then
      out[#out + 1] = ".*"
    elseif c == "?" then
      out[#out + 1] = "."
    elseif c == "[" and glob:find("]", i + 1, true) then
      local close = glob:find("]", i + 1, true)
      local set = glob:sub(i + 1, close - 1):gsub("^!", "^"):gsub("%%", "%%%%")
      out[#out + 1] = "[" .. set .. "]"
      i = close
    else
      out[#out + 1] = c:gsub("%p", "%%%0")
    end
    i = i + 1
  end
  return table.concat(out) .. "$"
end

local function hasGlob(word)
  return word:find("[%*%?%[]") ~= nil
end

-- Every path matching `word` (globs allowed in any component), sorted;
-- none matching gives the word back unchanged, as in sh.
local function expandGlob(word)
  local isAbs = word:sub(1, 1) == "/"
  local parts = {}
  for p in word:gmatch("[^/]+") do parts[#parts + 1] = p end
  local found = {isAbs and "" or "."}
  for i, part in ipairs(parts) do
    local nextFound = {}
    for _, base in ipairs(found) do
      local dir = base == "" and "/" or base
      if hasGlob(part) then
        local pat = globPattern(part)
        for _, n in ipairs(fs.list(absolute(dir)) or {}) do
          local name = n:gsub("/$", "")
          if name:match(pat) and (name:sub(1, 1) ~= "." or part:sub(1, 1) == ".") then
            nextFound[#nextFound + 1] = (base == "." and "" or base .. "/") .. name
          end
        end
      else
        local candidate = (base == "." and "" or base .. "/") .. part
        if i < #parts or fs.exists(absolute(candidate)) then nextFound[#nextFound + 1] = candidate end
      end
    end
    found = nextFound
  end
  if #found == 0 then return {word} end
  table.sort(found)
  return found
end

-- --- Parsing ---

-- Words and operators. A word is {text, glob}: `glob` when it has an
-- unquoted * ? or [. Variables and ~ are expanded here, as sh does.
local OPERATORS = {"2>>", "2>&1", "&&", "||", ">>", "2>", ";", "|", "&", ">", "<"}

local function variable(name)
  if name == "?" then return tostring(lastStatus) end
  if name == "$" then return "1" end
  return env[name] or ""
end

local function tokenize(line)
  local tokens, i, n = {}, 1, #line
  while i <= n do
    local c = line:sub(i, i)
    if c:match("%s") then
      i = i + 1
    elseif c == "#" then
      break
    else
      local op
      for _, o in ipairs(OPERATORS) do
        if line:sub(i, i + #o - 1) == o then op = o break end
      end
      if op then
        tokens[#tokens + 1] = {op = op}
        i = i + #op
      else
        local buf, glob, quoted = {}, false, false
        while i <= n do
          c = line:sub(i, i)
          if c:match("%s") or c == ";" or c == "|" or c == "&" or c == ">" or c == "<" then break end
          if c == "'" then
            local close = line:find("'", i + 1, true)
            if not close then return nil, "unmatched '" end
            buf[#buf + 1] = line:sub(i + 1, close - 1)
            quoted, i = true, close + 1
          elseif c == '"' then
            i, quoted = i + 1, true
            while true do
              if i > n then return nil, 'unmatched "' end
              c = line:sub(i, i)
              if c == '"' then i = i + 1 break end
              if c == "\\" and line:sub(i + 1, i + 1):match('[\\"$`]') then
                buf[#buf + 1] = line:sub(i + 1, i + 1)
                i = i + 2
              elseif c == "$" then
                local name, after = line:match("^%${([%w_]+)}()", i)
                if not name then name, after = line:match("^%$([%a_][%w_]*)()", i) end
                if not name then name, after = line:match("^%$([%?%$])()", i) end
                if name then
                  buf[#buf + 1] = {var = name}
                  i = after
                else
                  buf[#buf + 1] = "$"
                  i = i + 1
                end
              else
                buf[#buf + 1] = c
                i = i + 1
              end
            end
          elseif c == "\\" then
            buf[#buf + 1] = line:sub(i + 1, i + 1)
            i = i + 2
          elseif c == "$" then
            local name, after = line:match("^%${([%w_]+)}()", i)
            if not name then name, after = line:match("^%$([%a_][%w_]*)()", i) end
            if not name then name, after = line:match("^%$([%?%$])()", i) end
            if name then
              buf[#buf + 1] = {var = name}
              i = after
            else
              buf[#buf + 1] = "$"
              i = i + 1
            end
          elseif c == "~" and #buf == 0 and (i == n or line:sub(i + 1, i + 1):match("[/%s]")) then
            buf[#buf + 1] = {var = "HOME"}
            i = i + 1
          else
            if c == "*" or c == "?" or c == "[" then glob = true end
            buf[#buf + 1] = c
            i = i + 1
          end
        end
        tokens[#tokens + 1] = {parts = buf, glob = glob, quoted = quoted}
      end
    end
  end
  return tokens
end

-- A word's text, its variables expanded now -- when its command runs, so
-- `X=1; echo $X` sees the 1.
local function wordText(word)
  local out = {}
  for _, part in ipairs(word.parts) do
    out[#out + 1] = type(part) == "table" and variable(part.var) or part
  end
  return table.concat(out)
end

-- A list of pipelines joined by ; && ||: {{commands, background, join}}.
-- Each command: {words, stdin, stdout = {path, append}, stderr = {...}}.
local function parse(tokens)
  local list, pipeline, cmd = {}, nil, nil
  local function newPipeline()
    pipeline = {commands = {}}
    cmd = {words = {}}
    pipeline.commands[1] = cmd
  end
  newPipeline()
  local i = 1
  while i <= #tokens do
    local t = tokens[i]
    if t.op == "|" then
      if #cmd.words == 0 then return nil, "syntax error near |" end
      cmd = {words = {}}
      pipeline.commands[#pipeline.commands + 1] = cmd
    elseif t.op == ";" or t.op == "&&" or t.op == "||" or t.op == "&" then
      if #cmd.words == 0 then
        if t.op ~= ";" or #pipeline.commands > 1 then return nil, "syntax error near " .. t.op end
      else
        pipeline.background = t.op == "&"
        pipeline.join = (t.op == "&&" or t.op == "||") and t.op or nil
        list[#list + 1] = pipeline
      end
      newPipeline()
    elseif t.op == "2>&1" then
      cmd.stderrToOut = true
    elseif t.op then
      local target = tokens[i + 1]
      if not target or target.op then return nil, "syntax error near " .. t.op end
      i = i + 1
      if t.op == "<" then
        cmd.stdin = target
      elseif t.op == ">" or t.op == ">>" then
        cmd.stdout = {word = target, append = t.op == ">>"}
      else
        cmd.stderr = {word = target, append = t.op == "2>>"}
      end
    else
      cmd.words[#cmd.words + 1] = t
    end
    i = i + 1
  end
  if #cmd.words > 0 then
    list[#list + 1] = pipeline
  elseif #pipeline.commands > 1 or list[#list] and list[#list].join then
    return nil, "syntax error: unexpected end of line"
  end
  return list
end

-- --- Built-in commands ---
--
-- Each is fn(args, io) -> exit status (nil means 0), where io has
-- stdin (a string, or nil when nothing was piped or redirected in),
-- out(text) and err(text). Options are parsed POSIX-style: -abc, and --
-- ends them.

local builtins = {}
local help = {}

local function options(args, known)
  local opts, rest, i = {}, {}, 1
  while i <= #args do
    local a = args[i]
    if a == "--" then
      for j = i + 1, #args do rest[#rest + 1] = args[j] end
      break
    elseif a:match("^%-%a") and not a:match("^%-%d") then
      for ch in a:sub(2):gmatch(".") do
        if known:find(ch .. ":", 1, true) then
          opts[ch] = a:sub(a:find(ch, 2, true) + 1)
          if opts[ch] == "" then i = i + 1 opts[ch] = args[i] end
          break
        elseif known:find(ch, 1, true) then
          opts[ch] = true
        else
          return nil, "-" .. ch .. ": unknown option"
        end
      end
    else
      rest[#rest + 1] = a
    end
    i = i + 1
  end
  return opts, rest
end

-- The text of each named file ("-" or none: stdin), for the filters.
local function inputs(files, io)
  if #files == 0 then return {{name = "-", text = io.stdin or ""}} end
  local out = {}
  for _, f in ipairs(files) do
    if f == "-" then
      out[#out + 1] = {name = "-", text = io.stdin or ""}
    else
      local text, err = fs.read(absolute(f))
      out[#out + 1] = {name = f, text = text, err = err}
    end
  end
  return out
end

local function lines(text)
  local out = {}
  for l in text:gmatch("([^\n]*)\n") do out[#out + 1] = l end
  local tail = text:match("([^\n]+)$")
  if tail then out[#out + 1] = tail end
  return out
end

local function define(name, usage, fn)
  builtins[name] = fn
  help[#help + 1] = usage
end

define("echo", "echo [-n] [text...]", function(args, io)
  local newline = true
  if args[1] == "-n" then newline = false table.remove(args, 1) end
  io.out(table.concat(args, " ") .. (newline and "\n" or ""))
end)

local function unescape(s)
  return (s:gsub("\\(.)", {n = "\n", t = "\t", ["\\"] = "\\", r = "\r", a = "\a", ["0"] = "\0"}))
end

define("printf", "printf format [args...]", function(args, io)
  local format = args[1]
  if not format then io.err("printf: usage: printf format [args...]\n") return 1 end
  local values, used = {table.unpack(args, 2)}, 0
  repeat
    local out = unescape(format):gsub("%%([%-#0 +]*%d*%.?%d*)([sdifxXoceEgGc%%])", function(flags, conv)
      if conv == "%" then return "%" end
      used = used + 1
      local v = values[used]
      if conv:match("[dioxXc]") then
        v = math.floor(tonumber(v) or 0)
      elseif conv:match("[feEgG]") then
        v = tonumber(v) or 0
      else
        v = v or ""
      end
      local ok, s = pcall(string.format, "%" .. flags .. conv, v)
      return ok and s or ""
    end)
    io.out(out)
  until used >= #values or used == 0
end)

define("pwd", "pwd", function(_, io) io.out(env.PWD .. "\n") end)

define("cd", "cd [dir|-]", function(args, io)
  local target = args[1] or env.HOME
  if target == "-" then target = env.OLDPWD or env.PWD end
  local path = absolute(target)
  if not fs.isDir(path) then io.err("cd: " .. target .. ": no such directory\n") return 1 end
  env.OLDPWD, env.PWD = env.PWD, path
end)

define("ls", "ls [-a] [-l] [-1] [path...]", function(args, io)
  local opts, paths = options(args, "al1")
  if not opts then io.err("ls: " .. paths .. "\n") return 2 end
  if #paths == 0 then paths = {"."} end
  local status = 0
  local function show(names, dir)
    local shown = {}
    for _, n in ipairs(names) do
      if opts.a or n:sub(1, 1) ~= "." then shown[#shown + 1] = n end
    end
    if opts.l then
      for _, n in ipairs(shown) do
        local isDir = n:sub(-1) == "/"
        local size = isDir and 0 or fs.size(dir and normalize(dir .. "/" .. n) or absolute(n))
        io.out(string.format("%s %8d %s\n", isDir and "d" or "-", size, n))
      end
    elseif opts["1"] or io.captured then
      for _, n in ipairs(shown) do io.out(n .. "\n") end
    elseif #shown > 0 then
      local widest = 0
      for _, n in ipairs(shown) do widest = math.max(widest, #n) end
      local perRow = math.max(1, (ctx.width() + 2) // (widest + 2))
      local row = {}
      for i, n in ipairs(shown) do
        row[#row + 1] = i % perRow == 0 and n or n .. (" "):rep(widest + 2 - #n)
        if i % perRow == 0 or i == #shown then
          io.out((table.concat(row):gsub("%s+$", "")) .. "\n")
          row = {}
        end
      end
    end
  end
  for i, p in ipairs(paths) do
    local path = absolute(p)
    if fs.isDir(path) then
      if #paths > 1 then io.out((i > 1 and "\n" or "") .. p .. ":\n") end
      show(fs.list(path) or {}, path)
    elseif fs.exists(path) then
      show({p}, nil)
    else
      io.err("ls: " .. p .. ": no such file or directory\n")
      status = 2
    end
  end
  return status
end)

define("cat", "cat [file...]", function(args, io)
  local status = 0
  for _, f in ipairs(inputs(args, io)) do
    if f.text then io.out(f.text) else io.err("cat: " .. f.err .. "\n") status = 1 end
  end
  return status
end)

define("mkdir", "mkdir [-p] dir...", function(args, io)
  local opts, dirs = options(args, "p")
  if not opts then io.err("mkdir: " .. dirs .. "\n") return 2 end
  local status = 0
  for _, d in ipairs(dirs) do
    local path = absolute(d)
    if fs.exists(path) and not opts.p then
      io.err("mkdir: " .. d .. ": already exists\n") status = 1
    elseif not opts.p and not fs.isDir(dirname(path)) then
      io.err("mkdir: " .. d .. ": no such parent directory\n") status = 1
    elseif not fs.mkdir(path) and not fs.isDir(path) then
      io.err("mkdir: " .. d .. ": can't create\n") status = 1
    end
  end
  return status
end)

define("rmdir", "rmdir dir...", function(args, io)
  local status = 0
  for _, d in ipairs(args) do
    local path = absolute(d)
    if not fs.isDir(path) then
      io.err("rmdir: " .. d .. ": not a directory\n") status = 1
    elseif #(fs.list(path) or {}) > 0 then
      io.err("rmdir: " .. d .. ": not empty\n") status = 1
    else
      fs.remove(path)
    end
  end
  return status
end)

define("rm", "rm [-r] [-f] path...", function(args, io)
  local opts, paths = options(args, "rRf")
  if not opts then io.err("rm: " .. paths .. "\n") return 2 end
  local status = 0
  for _, p in ipairs(paths) do
    local path = absolute(p)
    if not fs.exists(path) then
      if not opts.f then io.err("rm: " .. p .. ": no such file or directory\n") status = 1 end
    elseif fs.isDir(path) and not (opts.r or opts.R) then
      io.err("rm: " .. p .. ": is a directory (use -r)\n") status = 1
    elseif path == "/" or path == "/mnt" then
      io.err("rm: refusing to remove " .. path .. "\n") status = 1
    else
      fs.removeAll(path)
    end
  end
  return status
end)

-- cp/mv: sources into a target; a directory target takes them by name.
local function transfer(name, args, io, move)
  local opts, paths = options(args, move and "f" or "rRf")
  if not opts then io.err(name .. ": " .. paths .. "\n") return 2 end
  if #paths < 2 then io.err(name .. ": usage: " .. name .. " source... target\n") return 2 end
  local target = absolute(table.remove(paths))
  local intoDir = fs.isDir(target)
  if #paths > 1 and not intoDir then io.err(name .. ": " .. target .. ": not a directory\n") return 1 end
  local status = 0
  for _, p in ipairs(paths) do
    local from = absolute(p)
    local to = intoDir and (target .. "/" .. basename(from)) or target
    if not fs.exists(from) then
      io.err(name .. ": " .. p .. ": no such file or directory\n") status = 1
    elseif fs.isDir(from) and not move and not (opts.r or opts.R) then
      io.err(name .. ": " .. p .. ": is a directory (use -r)\n") status = 1
    elseif from == to or to:sub(1, #from + 1) == from .. "/" then
      io.err(name .. ": " .. p .. ": can't " .. name .. " into itself\n") status = 1
    else
      local done
      if move and locate(from) == locate(to) then
        if fs.exists(to) and not fs.isDir(to) then fs.remove(to) end
        done = fs.call(from, "rename", select(2, locate(to)))
      end
      if not done then
        local ok, err = fs.copy(from, to)
        if not ok then
          io.err(name .. ": " .. tostring(err) .. "\n") status = 1
        elseif move then
          fs.removeAll(from)
        end
      end
    end
  end
  return status
end

define("cp", "cp [-r] source... target", function(args, io) return transfer("cp", args, io, false) end)
define("mv", "mv source... target", function(args, io) return transfer("mv", args, io, true) end)

define("touch", "touch file...", function(args, io)
  local status = 0
  for _, f in ipairs(args) do
    local path = absolute(f)
    if not fs.exists(path) then
      local ok, err = fs.write(path, "")
      if not ok then io.err("touch: " .. err .. "\n") status = 1 end
    end
  end
  return status
end)

local function headTail(name, args, io, fromEnd)
  local opts, files = options(args, "n:")
  if not opts then io.err(name .. ": " .. files .. "\n") return 2 end
  local count = tonumber(opts.n or 10) or 10
  local status = 0
  for _, f in ipairs(inputs(files, io)) do
    if not f.text then
      io.err(name .. ": " .. f.err .. "\n") status = 1
    else
      local all = lines(f.text)
      local first = fromEnd and math.max(1, #all - count + 1) or 1
      local last = fromEnd and #all or math.min(#all, count)
      for i = first, last do io.out(all[i] .. "\n") end
    end
  end
  return status
end

define("head", "head [-n N] [file...]", function(args, io) return headTail("head", args, io, false) end)
define("tail", "tail [-n N] [file...]", function(args, io) return headTail("tail", args, io, true) end)

define("wc", "wc [-l] [-w] [-c] [file...]", function(args, io)
  local opts, files = options(args, "lwc")
  if not opts then io.err("wc: " .. files .. "\n") return 2 end
  local all = not (opts.l or opts.w or opts.c)
  local status = 0
  for _, f in ipairs(inputs(files, io)) do
    if not f.text then
      io.err("wc: " .. f.err .. "\n") status = 1
    else
      local _, nl = f.text:gsub("\n", "")
      local words = 0
      for _ in f.text:gmatch("%S+") do words = words + 1 end
      local cols = {}
      if all or opts.l then cols[#cols + 1] = nl end
      if all or opts.w then cols[#cols + 1] = words end
      if all or opts.c then cols[#cols + 1] = #f.text end
      io.out(table.concat(cols, " ") .. (f.name ~= "-" and (" " .. f.name) or "") .. "\n")
    end
  end
  return status
end)

define("grep", "grep [-i] [-v] [-n] [-c] [-F] pattern [file...]  (Lua patterns)", function(args, io)
  local opts, rest = options(args, "ivncF")
  if not opts then io.err("grep: " .. rest .. "\n") return 2 end
  local pattern = table.remove(rest, 1)
  if not pattern then io.err("grep: usage: grep [-ivncF] pattern [file...]\n") return 2 end
  if opts.i then pattern = pattern:lower() end
  local any, status = false, 0
  local files = inputs(rest, io)
  for _, f in ipairs(files) do
    if not f.text then
      io.err("grep: " .. f.err .. "\n") status = 2
    else
      local count = 0
      for n, l in ipairs(lines(f.text)) do
        local subject = opts.i and l:lower() or l
        local ok, hit = pcall(string.find, subject, pattern, 1, opts.F == true)
        if not ok then io.err("grep: bad pattern: " .. tostring(hit) .. "\n") return 2 end
        if (hit ~= nil) ~= (opts.v == true) then
          count, any = count + 1, true
          if not opts.c then
            io.out((#files > 1 and f.name .. ":" or "") .. (opts.n and n .. ":" or "") .. l .. "\n")
          end
        end
      end
      if opts.c then io.out((#files > 1 and f.name .. ":" or "") .. count .. "\n") end
    end
  end
  if status ~= 0 then return status end
  return any and 0 or 1
end)

define("sort", "sort [-r] [-n] [-u] [file...]", function(args, io)
  local opts, files = options(args, "rnu")
  if not opts then io.err("sort: " .. files .. "\n") return 2 end
  local all = {}
  for _, f in ipairs(inputs(files, io)) do
    if not f.text then io.err("sort: " .. f.err .. "\n") return 2 end
    for _, l in ipairs(lines(f.text)) do all[#all + 1] = l end
  end
  local function key(l) return opts.n and (tonumber(l:match("^%s*([%-%d%.]+)")) or 0) or l end
  table.sort(all, function(a, b)
    local ka, kb = key(a), key(b)
    if ka == kb then return a < b end
    if opts.r then return ka > kb end
    return ka < kb
  end)
  local last
  for _, l in ipairs(all) do
    if not (opts.u and l == last) then io.out(l .. "\n") end
    last = l
  end
end)

define("uniq", "uniq [-c] [file]", function(args, io)
  local opts, files = options(args, "c")
  if not opts then io.err("uniq: " .. files .. "\n") return 2 end
  local f = inputs(files, io)[1]
  if not f.text then io.err("uniq: " .. f.err .. "\n") return 1 end
  local last, count = nil, 0
  local function flush()
    if last then io.out((opts.c and string.format("%7d ", count) or "") .. last .. "\n") end
  end
  for _, l in ipairs(lines(f.text)) do
    if l == last then
      count = count + 1
    else
      flush()
      last, count = l, 1
    end
  end
  flush()
end)

define("tee", "tee [-a] file...", function(args, io)
  local opts, files = options(args, "a")
  if not opts then io.err("tee: " .. files .. "\n") return 2 end
  local text, status = io.stdin or "", 0
  for _, f in ipairs(files) do
    local ok, err = fs.write(absolute(f), text, opts.a)
    if not ok then io.err("tee: " .. err .. "\n") status = 1 end
  end
  io.out(text)
  return status
end)

-- tr's sets: ranges like a-z, and escapes.
local function trSet(s)
  s = unescape(s)
  local out, i = {}, 1
  while i <= #s do
    local a, b = s:sub(i, i), s:sub(i + 2, i + 2)
    if s:sub(i + 1, i + 1) == "-" and b ~= "" then
      for c = a:byte(), b:byte() do out[#out + 1] = string.char(c) end
      i = i + 3
    else
      out[#out + 1] = a
      i = i + 1
    end
  end
  return out
end

define("tr", "tr [-d] set1 [set2]", function(args, io)
  local opts, sets = options(args, "d")
  if not opts or not sets[1] then io.err("tr: usage: tr [-d] set1 [set2]\n") return 2 end
  local from, to, map = trSet(sets[1]), trSet(sets[2] or ""), {}
  for i, c in ipairs(from) do map[c] = opts.d and "" or (to[i] or to[#to] or c) end
  io.out(((io.stdin or ""):gsub(".", map)))
end)

define("cut", "cut -d delim -f fields [file...]  (or -c ranges)", function(args, io)
  local opts, files = options(args, "d:f:c:")
  if not opts or not (opts.f or opts.c) then io.err("cut: usage: cut -d delim -f fields [file...]\n") return 2 end
  local function wanted(list)
    local set = {}
    for part in list:gmatch("[^,]+") do
      local a, b = part:match("^(%d*)%-(%d*)$")
      if a then
        for k = tonumber(a) or 1, tonumber(b) or 1000 do set[k] = true end
      else
        set[tonumber(part) or 0] = true
      end
    end
    return set
  end
  local set = wanted(opts.f or opts.c)
  local delim = opts.d or "\t"
  for _, f in ipairs(inputs(files, io)) do
    if not f.text then io.err("cut: " .. f.err .. "\n") return 1 end
    for _, l in ipairs(lines(f.text)) do
      local fields, out = {}, {}
      if opts.c then
        for k = 1, #l do if set[k] then out[#out + 1] = l:sub(k, k) end end
        io.out(table.concat(out) .. "\n")
      else
        for field in (l .. delim):gmatch("(.-)" .. delim:gsub("%p", "%%%0")) do fields[#fields + 1] = field end
        for k, v in ipairs(fields) do if set[k] then out[#out + 1] = v end end
        io.out(table.concat(out, delim) .. "\n")
      end
    end
  end
end)

define("seq", "seq [first [step]] last", function(args, io)
  local nums = {}
  for i, a in ipairs(args) do nums[i] = tonumber(a) end
  if #nums == 0 or #nums ~= #args then io.err("seq: usage: seq [first [step]] last\n") return 2 end
  local first, step, last = 1, 1, nums[#nums]
  if #nums >= 2 then first = nums[1] end
  if #nums == 3 then step = nums[2] end
  if step == 0 then io.err("seq: step can't be 0\n") return 2 end
  for v = first, last, step do io.out(string.format(math.type(v) == "float" and v % 1 ~= 0 and "%g\n" or "%d\n", v)) end
end)

define("basename", "basename path [suffix]", function(args, io)
  if not args[1] then io.err("basename: usage: basename path [suffix]\n") return 2 end
  local b = basename(args[1])
  if args[2] and b ~= args[2] and b:sub(-#args[2]) == args[2] then b = b:sub(1, -#args[2] - 1) end
  io.out(b .. "\n")
end)

define("dirname", "dirname path", function(args, io)
  if not args[1] then io.err("dirname: usage: dirname path\n") return 2 end
  io.out(dirname(args[1]) .. "\n")
end)

-- Where a name comes from: built in, or a program on the PATH.
local function whichOne(name)
  if builtins[name] then return name .. ": built in" end
  for dir in env.PATH:gmatch("[^:]+") do
    for _, ext in ipairs({"", ".mxe", ".lua"}) do
      local p = normalize(dir .. "/" .. name .. ext)
      if (ext ~= "" or name:find("%.")) and fs.exists(p) and not fs.isDir(p) then return p end
    end
  end
end

define("which", "which name...", function(args, io)
  local status = 0
  for _, name in ipairs(args) do
    local found = whichOne(name)
    if found then io.out(found .. "\n") else status = 1 end
  end
  return status
end)
builtins.type = function(args, io)
  local status = 0
  for _, name in ipairs(args) do
    local found = whichOne(name)
    if not found then
      io.err(name .. ": not found\n") status = 1
    elseif builtins[name] then
      io.out(name .. " is a shell builtin\n")
    else
      io.out(name .. " is " .. found .. "\n")
    end
  end
  return status
end

-- test / [ : files, strings and integers, with ! and -a/-o.
local function evaluate(a)
  local function primary(i)
    local t = a[i]
    if t == "!" then
      local v, j = primary(i + 1)
      return not v, j
    end
    if t == "(" then
      local v, j = primary(i + 1)
      return v, j + 1
    end
    local unary = {
      ["-e"] = function(x) return fs.exists(absolute(x)) end,
      ["-f"] = function(x) local p = absolute(x) return fs.exists(p) and not fs.isDir(p) end,
      ["-d"] = function(x) return fs.isDir(absolute(x)) end,
      ["-s"] = function(x) local p = absolute(x) return fs.exists(p) and fs.size(p) > 0 end,
      ["-z"] = function(x) return x == "" end,
      ["-n"] = function(x) return x ~= "" end,
    }
    local op, rhs = a[i + 1], a[i + 2]
    local binary = {
      ["="] = function(x, y) return x == y end, ["!="] = function(x, y) return x ~= y end,
      ["-eq"] = function(x, y) return tonumber(x) == tonumber(y) end,
      ["-ne"] = function(x, y) return tonumber(x) ~= tonumber(y) end,
      ["-lt"] = function(x, y) return (tonumber(x) or 0) < (tonumber(y) or 0) end,
      ["-le"] = function(x, y) return (tonumber(x) or 0) <= (tonumber(y) or 0) end,
      ["-gt"] = function(x, y) return (tonumber(x) or 0) > (tonumber(y) or 0) end,
      ["-ge"] = function(x, y) return (tonumber(x) or 0) >= (tonumber(y) or 0) end,
    }
    if op and binary[op] and rhs ~= nil then return binary[op](t, rhs), i + 3 end
    if unary[t] and a[i + 1] ~= nil then return unary[t](a[i + 1]), i + 2 end
    return t ~= nil and t ~= "", i + 1
  end
  local function expr(i)
    local v, j = primary(i)
    while a[j] == "-a" or a[j] == "-o" do
      local w, k = primary(j + 1)
      if a[j] == "-a" then v = v and w else v = v or w end
      j = k
    end
    return v, j
  end
  if #a == 0 then return false end
  return (expr(1))
end

define("test", "test expression  (or [ expression ])", function(args)
  return evaluate(args) and 0 or 1
end)
builtins["["] = function(args, io)
  if args[#args] ~= "]" then io.err("[: missing ]\n") return 2 end
  args[#args] = nil
  return evaluate(args) and 0 or 1
end

define("true", "true", function() return 0 end)
define("false", "false", function() return 1 end)
define("sleep", "sleep seconds", function(args, io)
  local s = tonumber(args[1])
  if not s then io.err("sleep: usage: sleep seconds\n") return 2 end
  ctx.sleep(s)
end)

define("env", "env", function(_, io)
  local names = {}
  for k in pairs(exported) do if env[k] then names[#names + 1] = k end end
  table.sort(names)
  for _, k in ipairs(names) do io.out(k .. "=" .. env[k] .. "\n") end
end)
define("set", "set  (shell variables)", function(_, io)
  local names = {}
  for k in pairs(env) do names[#names + 1] = k end
  table.sort(names)
  for _, k in ipairs(names) do io.out(k .. "=" .. env[k] .. "\n") end
end)
define("export", "export NAME[=value]...", function(args)
  for _, a in ipairs(args) do
    local k, v = a:match("^([%a_][%w_]*)=(.*)$")
    k = k or a
    if v then env[k] = v end
    exported[k] = true
  end
end)
define("unset", "unset NAME...", function(args)
  for _, k in ipairs(args) do env[k], exported[k] = nil, nil end
end)

define("date", "date", function(_, io)
  local ok, s = pcall(os.date, "%Y-%m-%d %H:%M:%S")
  io.out((ok and s or ("uptime " .. ctx.info.uptime() .. "s")) .. "\n")
end)
define("uptime", "uptime", function(_, io)
  local t = math.floor(ctx.info.uptime())
  io.out(string.format("up %d:%02d:%02d\n", t // 3600, t // 60 % 60, t % 60))
end)
define("uname", "uname [-a]", function(args, io)
  if args[1] == "-a" then
    io.out("muxos " .. ctx.info.address:sub(1, 8) .. " " .. ctx.info.version .. " OpenComputers\n")
  else
    io.out("muxos\n")
  end
end)
define("hostname", "hostname", function(_, io) io.out(ctx.info.address:sub(1, 8) .. "\n") end)
define("whoami", "whoami", function(_, io) io.out(env.USER .. "\n") end)
define("free", "free", function(_, io)
  local free, total = ctx.info.memory()
  io.out(string.format("memory: %d KB free of %d KB\n", free // 1024, total // 1024))
end)

define("df", "df", function(_, io)
  io.out(string.format("%-12s %10s %10s %10s\n", "Mounted on", "Size", "Used", "Avail"))
  local rows = {{"/", ctx.root}}
  if ctx.tmp then rows[#rows + 1] = {"/tmp", ctx.tmp} end
  local names = {}
  for name in pairs(mounts()) do names[#names + 1] = name end
  table.sort(names)
  local m = mounts()
  for _, name in ipairs(names) do rows[#rows + 1] = {"/mnt/" .. name, m[name]} end
  for _, r in ipairs(rows) do
    local total = ctx.invoke(r[2], "spaceTotal") or 0
    local used = ctx.invoke(r[2], "spaceUsed") or 0
    if total == math.huge then total = used end
    io.out(string.format("%-12s %9dK %9dK %9dK\n", r[1], total // 1024, used // 1024, (total - used) // 1024))
  end
end)

define("du", "du [-s] [path...]", function(args, io)
  local opts, paths = options(args, "s")
  if not opts then io.err("du: " .. paths .. "\n") return 2 end
  if #paths == 0 then paths = {"."} end
  local function walk(path, shown, report)
    local total = 0
    if fs.isDir(path) then
      for _, n in ipairs(fs.list(path) or {}) do
        local name = n:gsub("/$", "")
        total = total + walk(path .. (path == "/" and "" or "/") .. name, shown .. "/" .. name, report and not opts.s)
      end
    else
      total = fs.size(path)
    end
    if report and fs.isDir(path) then io.out(string.format("%d\t%s\n", (total + 1023) // 1024, shown)) end
    return total
  end
  for _, p in ipairs(paths) do
    local path = absolute(p)
    local total = walk(path, p, not opts.s)
    if opts.s or not fs.isDir(path) then io.out(string.format("%d\t%s\n", (total + 1023) // 1024, p)) end
  end
end)

define("clear", "clear", function() ctx.clear() end)

define("help", "help", function(_, io)
  io.out("shell commands (POSIX-style; | > >> < 2> ; && || & quotes $VAR * ? work):\n")
  local sorted = {}
  for _, u in ipairs(help) do sorted[#sorted + 1] = u end
  table.sort(sorted)
  for _, u in ipairs(sorted) do io.out("  " .. u .. "\n") end
  io.out("plus programs in $PATH and the muxos commands listed at boot (nodes, run, update, ...)\n")
end)

-- --- Running a line ---

-- Words to arguments: globs expanded.
local function argv(words)
  local out = {}
  for _, w in ipairs(words) do
    local text = wordText(w)
    if w.glob then
      for _, p in ipairs(expandGlob(text)) do out[#out + 1] = p end
    else
      out[#out + 1] = text
    end
  end
  return out
end

local function runPipeline(pipeline)
  local input, status = nil, 0
  for i, cmd in ipairs(pipeline.commands) do
    local args = argv(cmd.words)
    -- NAME=value words before the command (or alone) set variables.
    local assigned = {}
    while args[1] and args[1]:match("^[%a_][%w_]*=") do
      local k, v = table.remove(args, 1):match("^([%a_][%w_]*)=(.*)$")
      assigned[k] = v
    end
    local errOut = {}
    if cmd.stdin then
      local text, err = fs.read(absolute(wordText(cmd.stdin)))
      if not text then ctx.write("sh: " .. err .. "\n") return 1 end
      input = text
    end
    local captured = i < #pipeline.commands or cmd.stdout ~= nil
    local outBuf = {}
    local io = {stdin = input, captured = captured}
    io.out = function(text)
      if captured then outBuf[#outBuf + 1] = text else ctx.write(text) end
    end
    io.err = function(text)
      if cmd.stderrToOut then io.out(text)
      elseif cmd.stderr then errOut[#errOut + 1] = text
      else ctx.write(text) end
    end
    if #args == 0 then
      for k, v in pairs(assigned) do env[k] = v end
      status = 0
    elseif builtins[args[1]] then
      local name = table.remove(args, 1)
      local ok, result = pcall(builtins[name], args, io)
      if ok then
        status = tonumber(result) or 0
      else
        io.err(name .. ": " .. tostring(result) .. "\n")
        status = 1
      end
    else
      if captured or input then
        ctx.write("sh: " .. args[1] .. ": a program's output goes to the console, so it can't be piped or redirected\n")
      end
      status = ctx.external(args, pipeline.background)
    end
    if cmd.stderr then
      local ok, err = fs.write(absolute(wordText(cmd.stderr.word)), table.concat(errOut), cmd.stderr.append)
      if not ok then ctx.write("sh: " .. err .. "\n") end
    end
    local output = table.concat(outBuf)
    if cmd.stdout then
      local ok, err = fs.write(absolute(wordText(cmd.stdout.word)), output, cmd.stdout.append)
      if not ok then ctx.write("sh: " .. err .. "\n") status = 1 end
      input = nil
    else
      input = output
    end
  end
  return status
end

-- Runs one console line. Returns its exit status (also left in $?).
function M.run(line)
  local tokens, err = tokenize(line)
  local list
  if tokens then list, err = parse(tokens) end
  if not list then
    ctx.write("sh: " .. err .. "\n")
    lastStatus = 2
    return 2
  end
  local status, skip = lastStatus, nil
  for _, pipeline in ipairs(list) do
    if not skip then status = runPipeline(pipeline) end
    lastStatus = status
    -- && runs the next only after success, || only after failure.
    if pipeline.join == "&&" then
      skip = status ~= 0 and true or nil
    elseif pipeline.join == "||" then
      skip = status == 0 and true or nil
    else
      skip = nil
    end
  end
  return status
end

M.isBuiltin = function(name) return builtins[name] ~= nil end
M.cwd = function() return env.PWD end
M.env = env

-- The home directory exists from the start, as on any system.
if not fs.isDir(env.HOME) then fs.mkdir(env.HOME) end
if fs.isDir(env.HOME) then env.PWD = env.HOME end

return M
