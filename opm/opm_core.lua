-- opm_core: the pure logic of opm (Open Computers Pull Manager). No I/O, so it runs under plain
-- lua5.3 in tests. opm.lua supplies the filesystem and the package sources.
local M = {}

function M.parse_cfg(text)
  local fn, err = load("return " .. text, "=programs.cfg", "t", {})
  if not fn then return nil, "programs.cfg: " .. tostring(err) end
  local ok, cfg = pcall(fn)
  if not ok then return nil, "programs.cfg: " .. tostring(cfg) end
  return cfg
end

local SYSTEM_DIRS = { usr = true, home = true, bin = true, lib = true, etc = true, tmp = true, mnt = true, boot = true }

-- No target = /usr. A path under a system dir is taken as is; anything else is a floppy name under /mnt.
function M.resolve_target(t)
  if not t then return "/usr" end
  local first = t:match("^/?([^/]+)")
  if not first then return "/usr" end
  if first == "mnt" or SYSTEM_DIRS[first] then return "/" .. t:gsub("^/+", "") end
  return "/mnt/" .. t:gsub("^/+", "")
end

-- Package names to install, dependencies first, each once. Cycles are tolerated.
function M.order(cfg, name)
  local out, state = {}, {}
  local function visit(n)
    n = n:lower()
    if state[n] then return end
    local pkg = cfg[n]
    if not pkg then error("unknown package '" .. n .. "'", 0) end
    state[n] = true
    for k, v in pairs(pkg.dependencies or {}) do visit(type(k) == "number" and v or k) end
    out[#out + 1] = n
  end
  visit(name)
  return out
end

-- A package's own `target` (e.g. /home/refinery) overrides the one asked for.
-- Every file to copy for the given packages: { package, path (repo path without the branch dir), dir, file }.
-- `concat` is filesystem.concat.
function M.file_plan(cfg, names, target, concat)
  local plan = {}
  for _, n in ipairs(names) do
    local files, keys = cfg[n].files or {}, {}
    local tgt = cfg[n].target or target
    for key in pairs(files) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
      if key:sub(1, 1) == ":" then error("folder entries (':') are not supported: " .. key, 0) end
      local path = key:match("^[^/]+/(.+)$")
      if not path then error("bad file key " .. key, 0) end
      local dest = files[key]
      local dir = dest:sub(1, 2) == "//" and dest:sub(2) or concat(tgt, dest)
      plan[#plan + 1] = { package = n, path = path, dir = dir, file = concat(dir, path:match("([^/]+)$")) }
    end
  end
  return plan
end

function M.launcher_text(pkg, name, target, concat)
  local nl, lines = string.char(10), {}
  if pkg.env then lines[#lines + 1] = "os.setenv(" .. string.format("%q", pkg.env) .. ", " .. string.format("%q", target) .. ")" end
  lines[#lines + 1] = "assert(loadfile(" .. string.format("%q", concat(target, "bin", name .. ".lua")) .. "))(...)"
  return table.concat(lines, nl) .. nl
end

function M.autorun_text(pkg, name, target, autorun, concat)
  local line = concat(target, "bin", name .. ".lua")
  local extra = type(autorun) == "string" and autorun or pkg.autorun
  if extra then line = line .. " " .. extra:gsub("{target}", target) end
  return "os.execute(" .. string.format("%q", line) .. ")\n", line
end

-- The version a file declares: a line like  M.VERSION = "0.5.16"  or  local VERSION = "1.2".
function M.find_version(body)
  return body:match('[%w_.]*VERSION%s*=%s*"([^"\n]+)"')
end

-- Package names for completion: the display name of each package (REMCS, not remcs), sorted.
function M.package_names(cfg)
  local out = {}
  for key, pkg in pairs(cfg) do out[#out + 1] = pkg.name or key end
  table.sort(out, function(x, y) return x:lower() < y:lower() end)
  return out
end

-- Decides what `opm update -a` / `opm update <package>` should re-pull, given the recorded
-- installed map (lowercase name -> target path, opm.lua's own job to persist/load) and the
-- current programs.cfg. A single named package that isn't installed or fell out of the catalog is
-- a real error (nothing sensible to do, raised via error() same as this module's other functions).
-- -a instead returns a `skipped` list for anything no longer in the catalog rather than aborting
-- the whole batch - "update everything installed" shouldn't fail entirely over one stale entry.
function M.plan_update(installed, cfg, selector)
  if selector == "-a" then
    local names = {}
    for n in pairs(installed) do names[#names + 1] = n end
    table.sort(names)
    local plan, skipped = {}, {}
    for _, n in ipairs(names) do
      if cfg[n] then
        plan[#plan + 1] = { name = n, target = installed[n] }
      else
        skipped[#skipped + 1] = { name = n, reason = "no longer in programs.cfg" }
      end
    end
    return plan, skipped
  end
  local name = selector:lower()
  local target = installed[name]
  if not target then
    error("package '" .. name .. "' is not recorded as installed here - pull it first with  opm pull " .. name .. " <target>", 0)
  end
  if not cfg[name] then
    error("package '" .. name .. "' is no longer in programs.cfg", 0)
  end
  return { { name = name, target = target } }, {}
end

local SUBCOMMANDS = { "bundle", "hook", "list", "pull", "update" }

-- Tab completion for a command line (the text before the cursor): the list of whole completed lines,
-- or nil when the line is not an opm command line this knows how to complete.
function M.complete(names, line, suffix)
  suffix = suffix or ""
  local function pick(prefix, word, candidates)
    local out, w = {}, word:lower()
    for _, c in ipairs(candidates) do
      if c:lower():sub(1, #w) == w then out[#out + 1] = prefix .. c .. " " .. suffix end
    end
    return out
  end
  local pre, word = line:match("^(%s*opm%s+)(%S*)$")
  if pre then return pick(pre, word, SUBCOMMANDS) end
  local pre2, sub, word2 = line:match("^(%s*opm%s+(%a+)%s+)(%S*)$")
  if pre2 and (sub == "pull" or sub == "bundle") and not word2:find("^%-") then return pick(pre2, word2, names) end
  return nil
end

return M
