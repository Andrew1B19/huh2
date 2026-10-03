-- smux/installer/installer.lua: the logic behind the floppy's autorun. Pure: every side effect goes
-- through env, so it runs under plain lua5.3 in tests (same approach as refinery-power's installer).
--
-- env.floppy        mount path of the floppy (e.g. /mnt/ab1)
-- env.fs            exists, list(dir)->names, makeDir, copy(a,b), rename(a,b), remove(path),
--                   size(path), read(path)->text|nil, write(path,text)
-- env.logs          the logs.lua module (rotating logs, file ops from env.fsx)
-- env.fsx           file ops for logs.lua (size, append, rename, remove)
-- env.free(path)    optional: free bytes on that filesystem (caps the spool copy to half of it)
-- env.check_lua(path) -> true | false, err    (compile check)
-- env.say(msg)      optional: show a progress line on the screen (every log line goes there too)
-- env.reboot()
-- Returns "ignored" | "current" | "installed" | "mode" | "failed".

local M = {}
M.VERSION = "0.1.0"

local HOME = "/home/smux"
local NOINSTALL = "/etc/noinstall"
local SHRC = "/home/.shrc"
local BEGIN, END = "# smux-begin (managed by the smux installer)", "# smux-end"
local LINE = "/home/smux/main.lua &"

-- Adds (or refreshes) the autostart block; leaves the rest of .shrc alone.
function M.ensure_shrc(text)
    text = (text or ""):gsub("\r\n", "\n")
    local block = BEGIN .. "\n" .. LINE .. "\n" .. END
    local a = text:find(BEGIN, 1, true)
    if a then
        local _, b = text:find(END, a, true)
        if b then return text:sub(1, a - 1) .. block .. text:sub(b + 1) end
    end
    if text ~= "" and not text:match("\n$") then text = text .. "\n" end
    return text .. block .. "\n"
end

-- Replaces OpenOS's boxed banner and tip (/etc/motd, run by /etc/profile) with one status line.
local MOTD_MARK = "-- smux-motd (managed by the smux installer)"
M.MOTD = MOTD_MARK .. "\n" .. [==[

local function first(p) local f = io.open(p, "r"); if not f then return nil end local t = f:read("*l"); f:close(); return t end
local v = first("/home/smux/VERSION") or "?"
local m = first("/home/smux/mode") or "live"
io.write("smux " .. v .. " [" .. (m:match("^%s*dry") and "dry" or "live") .. "]  jobs run headless, remote console over GERTi\n")
]==]

-- Keeps the original once as /etc/motd.orig; rewrites ours every time so it follows this file.
function M.ensure_motd(fs)
    local cur = fs.read("/etc/motd")
    if cur == M.MOTD then return end
    if cur and not cur:find(MOTD_MARK, 1, true) and not fs.exists("/etc/motd.orig") then
        fs.write("/etc/motd.orig", cur)
    end
    fs.write("/etc/motd", M.MOTD)
end

function M.payload_version(main_text)
    return main_text and main_text:match('M%.VERSION%s*=%s*"([^"]+)"')
end

local function trim(s) return s and s:match("^%s*(.-)%s*$") end

function M.run(env)
    local fs, floppy = env.fs, env.floppy
    if fs.exists(NOINSTALL) then return "ignored" end

    if not fs.exists(floppy .. "/logs") then fs.makeDir(floppy .. "/logs") end
    fs.write(floppy .. "/.smux-floppy", "smux floppy\n")
    local ilog = env.logs.new(env.fsx, { path = floppy .. "/logs/install.log", segments = 4, bytes = 32768 })
    local elog = env.logs.new(env.fsx, { path = floppy .. "/logs/errors.log", segments = 4, bytes = 32768 })
    local function say(msg) if env.say then env.say("[smux install] " .. msg) end end
    local function log(msg) ilog:write(msg); say(msg) end
    local function fail(msg) ilog:write("FAILED: " .. msg); say("FAILED: " .. msg); return "failed" end

    -- errors spooled to the hard drive while no floppy was in go onto this one
    for _, name in ipairs({ "errors.log.1", "errors.log" }) do
        local p = HOME .. "/logs/" .. name
        local text = fs.read(p)
        if text and text ~= "" then
            -- never take more than half of the floppy's free space; keep the newest part
            local free = env.free and env.free(floppy)
            local cap = free and math.floor(free / 2)
            if cap and cap <= 0 then
                log("floppy full: left spooled errors (" .. name .. ") on the node")
            else
                local cut = cap and #text > cap
                if cut then text = text:sub(-cap) end
                elog:write("--- spooled on the node" .. (cut and " (older part dropped: floppy space)" or "") .. " ---\n" .. text)
                fs.remove(p)
                log("copied spooled errors (" .. name .. ")" .. (cut and ", truncated to half the free floppy space" or ""))
            end
        end
    end

    local payload = floppy .. "/payload"
    local want = M.payload_version(fs.read(payload .. "/main.lua"))
    if not want then return fail("payload/main.lua missing or has no version") end
    local have = trim(fs.read(HOME .. "/VERSION"))

    local floppy_mode = trim(fs.read(floppy .. "/mode"))
    if floppy_mode ~= "live" and floppy_mode ~= "dry" then floppy_mode = nil end

    if have == want then
        local cur = trim(fs.read(HOME .. "/mode"))
        if floppy_mode and cur ~= floppy_mode then
            fs.write(HOME .. "/mode", floppy_mode .. "\n")
            log(string.format("mode %s -> %s; restarting", tostring(cur), floppy_mode))
            env.reboot()
            return "mode"
        end
        M.ensure_motd(fs)
        log("version " .. want .. " already installed")
        return "current"
    end

    log(string.format("installing %s (was %s)", want, tostring(have)))

    local new, old = HOME .. ".new", HOME .. ".old"
    -- the previous install's backup is dropped first: HOME + .old + .new together can fill a small disk
    for _, n in ipairs(fs.list("/home")) do
        n = n:gsub("/$", "")
        if n:find("^smux%.old") or n:find("^smux%.new") then fs.remove("/home/" .. n) end
    end
    fs.makeDir(new)
    for _, n in ipairs(fs.list(payload)) do
        n = n:gsub("/$", "")
        local src, dst = payload .. "/" .. n, new .. "/" .. n
        say("copying " .. n)
        if not fs.copy(src, dst) then
            local free = env.free and env.free("/home")
            fs.remove(new)
            return fail("copy failed: " .. n .. (free and (" (" .. free .. " bytes free on the node)") or ""))
        end
        -- OpenOS's fs.copy is recursive for directories; only top-level .lua FILES get compile-checked
        -- (a directory entry lists empty, a file doesn't - that distinguishes them in OpenOS).
        if n:match("%.lua$") and #(fs.list(src) or {}) == 0 then
            local ok, err = env.check_lua(dst)
            if not ok then fs.remove(new); return fail("does not compile: " .. n .. ": " .. tostring(err)) end
        end
    end

    -- keep the site's edited config; the shipped one stays next to it for comparison
    local old_cfg = fs.exists(HOME .. "/smux.config.lua") and HOME .. "/smux.config.lua"
    if old_cfg and fs.exists(new .. "/smux.config.lua") then
        fs.rename(new .. "/smux.config.lua", new .. "/smux.config.default.lua")
        fs.copy(old_cfg, new .. "/smux.config.lua")
    end
    local mode = floppy_mode or trim(fs.read(HOME .. "/mode")) or "live"
    fs.write(new .. "/mode", mode .. "\n")
    fs.write(new .. "/VERSION", want .. "\n")

    if fs.exists(old) then fs.remove(old) end
    if fs.exists(HOME) then fs.rename(HOME, old) end
    if not fs.rename(new, HOME) then
        if fs.exists(old) then fs.rename(old, HOME) end
        return fail("could not move the new install into place; old install restored")
    end
    -- logs and any job programs the site added under /home/smux/jobs survive an install
    if fs.exists(old .. "/logs") then fs.rename(old .. "/logs", HOME .. "/logs") end
    if fs.exists(old .. "/jobs") then fs.rename(old .. "/jobs", HOME .. "/jobs") end

    fs.write(SHRC, M.ensure_shrc(fs.read(SHRC)))
    M.ensure_motd(fs)
    log(string.format("installed %s, mode=%s, config %s; restarting", want, mode,
        old_cfg and "kept" or "new from floppy"))
    env.reboot()
    return "installed"
end

return M
