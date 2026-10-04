-- Tests for smux/installer/installer.lua against an in-memory filesystem.
-- Run: cd <repo-root> && lua5.3 smux/installer/test/test_installer.lua
package.path = "./?.lua;./nodelib/?.lua;./smux/installer/?.lua;" .. package.path
local installer = require("installer")
local logs = require("logs")

local passed = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error("FAIL " .. name .. ": " .. tostring(err), 0) end
    passed = passed + 1
    print("PASS " .. name)
end

-- files: path -> text; dirs: path -> true
local function world()
    local w = { files = {}, dirs = { ["/"] = true }, reboots = 0, broken_lua = {} }
    local function under(dir, p) return p:sub(1, #dir + 1) == dir .. "/" end
    local fs = {}
    function fs.exists(p) return w.files[p] ~= nil or w.dirs[p] ~= nil end
    function fs.makeDir(p) w.dirs[p] = true; return true end
    function fs.read(p) return w.files[p] end
    function fs.write(p, t) w.files[p] = t; return true end
    -- OpenOS's filesystem module has no size(); the installer must tolerate its absence.
    function fs.copy(a, b) w.files[b] = w.files[a]; return w.files[a] ~= nil end
    function fs.remove(p)
        w.files[p], w.dirs[p] = nil, nil
        for k in pairs(w.files) do if under(p, k) then w.files[k] = nil end end
        for k in pairs(w.dirs) do if under(p, k) then w.dirs[k] = nil end end
        return true
    end
    function fs.rename(a, b)
        if not fs.exists(a) then return false end
        local moved = {}
        for k, v in pairs(w.files) do if k == a or under(a, k) then moved[#moved + 1] = { k, v, "f" } end end
        for k, v in pairs(w.dirs) do if k == a or under(a, k) then moved[#moved + 1] = { k, true, "d" } end end
        for _, m in ipairs(moved) do (m[3] == "f" and w.files or w.dirs)[m[1]] = nil end
        for _, m in ipairs(moved) do
            local nk = b .. m[1]:sub(#a + 1)
            if m[3] == "f" then w.files[nk] = m[2] else w.dirs[nk] = true end
        end
        return true
    end
    function fs.list(d)
        local r = {}
        for k in pairs(w.files) do
            local rest = under(d, k) and k:sub(#d + 2)
            if rest and not rest:find("/", 1, true) then r[#r + 1] = rest end
        end
        table.sort(r)
        return r
    end
    local fsx = {
        size   = function(p) return w.files[p] and #w.files[p] or nil end,
        append = function(p, s) w.files[p] = (w.files[p] or "") .. s; return true end,
        rename = function(a, b) w.files[b] = w.files[a]; w.files[a] = nil end,
        remove = function(p) w.files[p] = nil end,
    }
    w.env = { floppy = "/mnt/abc", fs = fs, fsx = fsx, logs = logs,
        check_lua = function(p) if w.broken_lua[p:match("[^/]+$")] then return false, "syntax" end return true end,
        reboot = function() w.reboots = w.reboots + 1 end }
    return w
end

local PAYLOAD_MAIN = 'local M = {}\nM.VERSION = "%s"\nreturn M\n'

local function floppy(w, version)
    w.dirs["/mnt/abc"] = true
    w.files["/mnt/abc/payload/main.lua"] = string.format(PAYLOAD_MAIN, version)
    w.files["/mnt/abc/payload/init.lua"] = "return { new = function() end }"
    w.files["/mnt/abc/payload/logs.lua"] = "-- logs"
    w.files["/mnt/abc/payload/smux.config.lua"] = "return { secret = \"s\", trusted = {}, jobs = {} }"
end

test("fresh install: copies everything, live mode, autostart, reboots, logs to the floppy", function()
    local w = world(); floppy(w, "1.0.0")
    assert(installer.run(w.env) == "installed")
    assert(w.files["/home/smux/main.lua"] and w.files["/home/smux/logs.lua"])
    assert(w.files["/home/smux/smux.config.lua"]:find("secret"))
    assert(w.files["/home/smux/VERSION"]:find("1.0.0") and w.files["/home/smux/mode"]:find("live"))
    local shrc = w.files["/home/.shrc"] or ""
    assert(shrc:find("/home/smux/main.lua &", 1, true), "autostart line present")
    assert(w.reboots == 1)
    assert(w.files["/mnt/abc/logs/install.log"]:find("installed 1.0.0", 1, true))
    assert(w.files["/mnt/abc/.smux-floppy"])
    assert(not w.dirs["/home/smux.new"])
end)

test("install progress is shown on the screen through env.say", function()
    local w = world(); floppy(w, "1.0.0")
    local said = {}
    w.env.say = function(m) said[#said + 1] = m end
    installer.run(w.env)
    local all = table.concat(said, ";")
    assert(all:find("copying main.lua", 1, true) and all:find("installed 1.0.0", 1, true))
end)

test("the OpenOS banner is replaced once, the original kept as motd.orig", function()
    local w = world(); floppy(w, "1.0.0")
    w.files["/etc/motd"] = "-- stock banner"
    installer.run(w.env)
    assert(w.files["/etc/motd"] == installer.MOTD and w.files["/etc/motd.orig"] == "-- stock banner")
    assert(load(w.files["/etc/motd"]), "motd compiles")
    floppy(w, "1.0.1"); installer.run(w.env)
    assert(w.files["/etc/motd.orig"] == "-- stock banner", "original is not overwritten by ours")
end)

test("same version again does nothing, no reboot loop", function()
    local w = world(); floppy(w, "1.0.0")
    installer.run(w.env); w.reboots = 0
    assert(installer.run(w.env) == "current" and w.reboots == 0)
end)

test("update keeps the edited config and logs, keeps the old tree, preserves mode", function()
    local w = world(); floppy(w, "1.0.0")
    installer.run(w.env)
    w.files["/home/smux/smux.config.lua"] = "return { secret = \"edited\" }"
    w.dirs["/home/smux/logs"] = true
    w.files["/home/smux/logs/events.log"] = "history"
    w.dirs["/home/smux/jobs"] = true
    w.files["/home/smux/jobs/myjob.lua"] = "-- job program"
    w.files["/home/smux/mode"] = "live\n"
    floppy(w, "1.0.1"); w.reboots = 0
    assert(installer.run(w.env) == "installed")
    assert(w.files["/home/smux/smux.config.lua"]:find("edited"))
    assert(w.files["/home/smux/smux.config.default.lua"]:find("secret"))
    assert(w.files["/home/smux/logs/events.log"] == "history")
    assert(w.files["/home/smux/jobs/myjob.lua"], "site job programs survive an install too")
    assert(w.files["/home/smux/mode"]:find("live"), "mode carried over")
    assert(w.files["/home/smux.old/VERSION"]:find("1.0.0"), "previous version kept")
    assert(w.reboots == 1)
end)

test("a broken payload leaves the running install untouched", function()
    local w = world(); floppy(w, "1.0.0")
    installer.run(w.env)
    floppy(w, "1.0.1"); w.broken_lua["main.lua"] = true; w.reboots = 0
    assert(installer.run(w.env) == "failed")
    assert(w.files["/home/smux/VERSION"]:find("1.0.0") and not w.dirs["/home/smux.new"] and w.reboots == 0)
    assert(w.files["/mnt/abc/logs/install.log"]:find("does not compile", 1, true))
end)

test("the ignore marker makes the floppy do nothing at all", function()
    local w = world(); floppy(w, "1.0.0")
    w.files["/etc/noinstall"] = ""
    assert(installer.run(w.env) == "ignored")
    assert(not w.files["/home/smux/main.lua"] and not w.files["/mnt/abc/logs/install.log"])
end)

test("spooled errors are copied to the floppy and removed from the disk", function()
    local w = world(); floppy(w, "1.0.0")
    installer.run(w.env)
    w.files["/home/smux/logs/errors.log"] = "[12] crash 1: boom\n"
    assert(installer.run(w.env) == "current")
    assert(w.files["/mnt/abc/logs/errors.log"]:find("crash 1: boom", 1, true))
    assert(w.files["/home/smux/logs/errors.log"] == nil)
end)

test("spool copy is capped to half the floppy's free space (newest part kept)", function()
    local w = world(); floppy(w, "1.0.0")
    installer.run(w.env)
    w.env.free = function() return 100 end
    w.files["/home/smux/logs/errors.log"] = string.rep("a", 200) .. "NEWEST\n"
    assert(installer.run(w.env) == "current")
    local got = w.files["/mnt/abc/logs/errors.log"]
    assert(got:find("NEWEST", 1, true) and not got:find(string.rep("a", 60), 1, true), "kept only the tail")
    assert(w.files["/home/smux/logs/errors.log"] == nil)
    w.files["/home/smux/logs/errors.log"] = "keep me\n"
    w.env.free = function() return 0 end
    installer.run(w.env)
    assert(w.files["/home/smux/logs/errors.log"] == "keep me\n", "full floppy: spool stays on the node")
end)

test("a mode file on the floppy switches dry/live on the node with a restart", function()
    local w = world(); floppy(w, "1.0.0")
    installer.run(w.env); w.reboots = 0
    w.files["/mnt/abc/mode"] = "dry\n"
    assert(installer.run(w.env) == "mode" and w.reboots == 1)
    assert(w.files["/home/smux/mode"]:find("dry"))
    w.reboots = 0
    assert(installer.run(w.env) == "current" and w.reboots == 0)
end)

test("autostart block is added once and refreshed, other .shrc lines survive", function()
    local t = installer.ensure_shrc("echo hi")
    assert(t:find("echo hi", 1, true) and t:find("smux-begin", 1, true))
    assert(installer.ensure_shrc(t) == t, "idempotent")
    local t2 = installer.ensure_shrc("a\n" .. t .. "b\n")
    local _, n = t2:gsub("smux%-begin", "")
    assert(n == 1 and t2:find("b\n", 1, true))
end)

print(string.format("ALL %d TESTS PASSED", passed))
