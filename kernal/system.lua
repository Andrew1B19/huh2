-- muxos system settings: kernal flags (/etc/kernal.cfg) and users
-- (/etc/users). Loaded by the kernal with its disk helpers:
--   loadSibling("system.lua")({read = readFile, write = writeFile, mkdir = makeDirectory})
--
-- Flags are policy that shouldn't be hard coded. /etc/kernal.cfg holds
-- `name = value` lines (and # comments); anything not in it has its
-- default. A bad line is reported at boot and that flag keeps its
-- default -- never guessed at.
--
-- Users are names only: no passwords, no file ownership, no permission
-- system. `root` always exists. Each user has a home folder,
-- /home/<name> (root's is /root). Users are created explicitly
-- (useradd), never by logging in with a new name -- a typo at login:
-- just asks again.
local disk = ...

local M = {}

local CONFIG, USERS = "/etc/kernal.cfg", "/etc/users"

-- Every flag: its type, default, and what it does. `reboot = true`:
-- takes effect at the next boot (the kernal reads it once).
local FLAGS = {
  {name = "login_required", type = "boolean", default = true, reboot = true,
    help = "the console asks for a user name at boot (false: logged in as root)"},
  {name = "update_requires_root", type = "boolean", default = true,
    help = "only root can update the kernal and its modules"},
  {name = "reboot_requires_root", type = "boolean", default = false,
    help = "only root can reboot or shut down"},
  {name = "drain_requires_root", type = "boolean", default = false,
    help = "only root can drain, undrain or migrate"},
  {name = "useradd_requires_root", type = "boolean", default = true,
    help = "only root can add or remove users"},
  {name = "kill_requires_owner", type = "boolean", default = false,
    help = "only a process's own user (or root) can pause, resume or kill it"},
  {name = "logout_ends_jobs", type = "boolean", default = true,
    help = "logging out ends the processes started from that login"},
  {name = "scheduler", type = "choice", choices = {"load", "count"}, default = "load",
    help = "where new work goes: the worker with the lowest load average, or the fewest processes"},
  {name = "remote_terminals", type = "boolean", default = true, reboot = true,
    help = "network terminals (muxterm) can log in"},
  {name = "terminal_port", type = "number", default = 4478, min = 1, max = 65535, reboot = true,
    not_ = 4477, help = "the network port terminals use (not 4477, the cluster's)"},
}
local byName = {}
for _, f in ipairs(FLAGS) do byName[f.name] = f end
M.FLAGS = FLAGS

local values = {}

-- A flag's value from text, or nil and why not.
local function parse(flag, text)
  text = text:match("^%s*(.-)%s*$")
  if flag.type == "boolean" then
    if text == "true" or text == "yes" or text == "on" then return true end
    if text == "false" or text == "no" or text == "off" then return false end
    return nil, flag.name .. " is true or false, not \"" .. text .. "\""
  elseif flag.type == "number" then
    local n = math.tointeger(tonumber(text))
    if not n or (flag.min and n < flag.min) or (flag.max and n > flag.max) or n == flag.not_ then
      return nil, flag.name .. " is a whole number" .. (flag.min and (" from " .. flag.min .. " to " .. flag.max) or "")
        .. (flag.not_ and (" other than " .. flag.not_) or "") .. ", not \"" .. text .. "\""
    end
    return n
  elseif flag.choices then
    for _, c in ipairs(flag.choices) do if c == text then return text end end
    return nil, flag.name .. " is one of " .. table.concat(flag.choices, ", ") .. ", not \"" .. text .. "\""
  end
  return text
end

-- Reads /etc/kernal.cfg. Returns a list of problems (empty if none).
function M.loadFlags()
  values = {}
  local problems = {}
  local text = disk.read(CONFIG)
  if not text then return problems end
  local n = 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    local body = line:gsub("#.*", ""):match("^%s*(.-)%s*$")
    if body ~= "" then
      local name, value = body:match("^([%w_]+)%s*=%s*(.-)$")
      local flag = name and byName[name]
      if not name then
        problems[#problems + 1] = CONFIG .. ":" .. n .. ": not `name = value`: " .. line
      elseif not flag then
        problems[#problems + 1] = CONFIG .. ":" .. n .. ": no flag called " .. name
      else
        local v, why = parse(flag, value)
        if v == nil then
          problems[#problems + 1] = CONFIG .. ":" .. n .. ": " .. why .. " -- using " .. tostring(flag.default)
        else
          values[name] = v
        end
      end
    end
  end
  return problems
end

function M.flag(name)
  local flag = assert(byName[name], "no flag called " .. tostring(name))
  if values[name] == nil then return flag.default end
  return values[name]
end

-- Sets a flag and saves it, keeping the file's other lines (and
-- comments) as they are. Returns the flag, or nil and why not.
function M.setFlag(name, text)
  local flag = byName[name]
  if not flag then return nil, "no flag called " .. tostring(name) .. " (`flags` lists them)" end
  local v, why = parse(flag, text)
  if v == nil then return nil, why end
  local lines, done = {}, false
  local old = disk.read(CONFIG) or ""
  for line in old:gmatch("[^\n]+") do
    if line:match("^%s*([%w_]+)%s*=") == name then
      if not done then lines[#lines + 1] = name .. " = " .. tostring(v) done = true end
    else
      lines[#lines + 1] = line
    end
  end
  if not done then lines[#lines + 1] = name .. " = " .. tostring(v) end
  disk.mkdir("/etc")
  local ok, err = disk.write(CONFIG, table.concat(lines, "\n") .. "\n")
  if not ok then return nil, "can't write " .. CONFIG .. ": " .. tostring(err) end
  values[name] = v
  return flag
end

-- Whether `user` may do something a `<what>_requires_root` flag
-- governs; nil and the message to show if not.
function M.allowed(user, flagName, doing)
  if user == "root" or not M.flag(flagName) then return true end
  return nil, doing .. ": only root can do that (flag " .. flagName .. "); log in as root"
end

-- --- Users ---

local VALID = "^[a-z_][a-z0-9_%-]*$"

function M.users()
  local list, seen = {"root"}, {root = true}
  for line in (disk.read(USERS) or ""):gmatch("[^\n]+") do
    local name = line:gsub("#.*", ""):match("^%s*(%S+)")
    if name and name:match(VALID) and not seen[name] then
      list[#list + 1] = name
      seen[name] = true
    end
  end
  return list
end

function M.userExists(name)
  for _, u in ipairs(M.users()) do if u == name then return true end end
  return false
end

function M.home(name)
  return name == "root" and "/root" or "/home/" .. name
end

function M.addUser(name)
  if type(name) ~= "string" or not name:match(VALID) or #name > 32 then
    return nil, "a user name is lowercase letters, digits, _ and -, up to 32, starting with a letter or _"
  end
  if M.userExists(name) then return nil, name .. " already exists" end
  local list = M.users()
  list[#list + 1] = name
  table.remove(list, 1) -- root is implicit
  disk.mkdir("/etc")
  local ok, err = disk.write(USERS, table.concat(list, "\n") .. "\n")
  if not ok then return nil, "can't write " .. USERS .. ": " .. tostring(err) end
  disk.mkdir(M.home(name))
  return true
end

-- Removes the user; their home folder is kept.
function M.removeUser(name)
  if name == "root" then return nil, "root can't be removed" end
  if not M.userExists(name) then return nil, "no such user: " .. tostring(name) end
  local list = {}
  for _, u in ipairs(M.users()) do if u ~= name and u ~= "root" then list[#list + 1] = u end end
  local ok, err = disk.write(USERS, #list > 0 and table.concat(list, "\n") .. "\n" or "")
  if not ok then return nil, "can't write " .. USERS .. ": " .. tostring(err) end
  return true
end

return M
