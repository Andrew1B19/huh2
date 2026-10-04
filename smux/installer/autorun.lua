-- Floppy autorun (OpenOS runs this with the floppy's filesystem proxy as the argument).
-- Does nothing on a machine that has /etc/noinstall (the update machine). Same pattern as
-- refinery-power/installer/autorun.lua, adapted to smux's own paths and payload.
local proxy = ...
local fs = require("filesystem")
local computer = require("computer")

local floppy
for p, path in fs.mounts() do
    if proxy and p.address == proxy.address then floppy = path; break end
end
if not floppy then return end
if fs.exists("/etc/noinstall") then return end

local function read(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local t = f:read("*a"); f:close(); return t
end

local ok, err = xpcall(function()
    local installer = dofile(floppy .. "/installer.lua")
    local logs = dofile(floppy .. "/payload/logs.lua")
    local fsx = {
        size   = function(p) if fs.exists(p) then return #read(p) or 0 end end,
        append = function(p, s)
            fs.makeDirectory(fs.path(p))
            local f, e = io.open(p, "a"); if not f then error(e) end
            f:write(s); f:close(); return true
        end,
        rename = function(a, b) return fs.rename(a, b) end,
        remove = function(p) return fs.remove(p) end,
    }
    local ofs = {
        exists  = fs.exists,
        list    = function(d) local r = {}; for n in fs.list(d) do r[#r + 1] = n end; return r end,
        makeDir = fs.makeDirectory,
        copy    = function(a, b) return fs.copy(a, b) end,
        rename  = function(a, b) return fs.rename(a, b) end,
        remove  = fs.remove,
        read    = read,
        write   = function(p, t)
            fs.makeDirectory(fs.path(p))
            local f = io.open(p, "wb"); if not f then return false end
            f:write(t); f:close(); return true
        end,
    }
    installer.run({
        floppy = floppy, fs = ofs, fsx = fsx, logs = logs,
        free      = function(p) local px = fs.get(p); return px.spaceTotal() - px.spaceUsed() end,
        check_lua = function(p) local f, e = loadfile(p); return f ~= nil, e end,
        say       = function(m) pcall(print, m) end,
        reboot    = function() os.sleep(5); computer.shutdown(true) end,
    })
end, debug.traceback)

if not ok then
    local f = io.open(floppy .. "/logs/errors.log", "a")
    if f then f:write("installer crashed: " .. tostring(err) .. "\n"); f:close() end
end
