-- smux/main.lua: the production entry point (OpenComputers / OpenOS).
-- Usage: main [--live|--dry-run] [config-file]
--   Config defaults to <dir>/smux.config.lua; a positional argument overrides it.
--   Mode: live unless the file <dir>/mode contains "dry" (or --dry-run is given, or config has
--         endpoint = "off"). DRY MODE FOR SMUX (a real design decision - see docs/design.md 7.2):
--         smux drives no hardware outputs at all, so refinery-power's dry/live distinction ("do not
--         touch the redstone lines") does not map onto it. Here dry mode means: load and validate
--         the config (secret present, every job file exists and compiles) but DO NOT spawn any job
--         process and DO NOT open the real GERTi transport - an install can be verified without
--         actually running untrusted job programs or opening a live network endpoint. Live mode is
--         the normal state: jobs run and the remote console is served over smux/gertinet.lua.
--   Ctrl+Alt+C: stops cleanly (jobs are killed with the host; nothing to hold - no outputs).
--   Crash: logs the error, restarts with back-off 5/10/20/40/60 s, gives up after N failures in a
--         row (a run of >5 min resets the count) - same shape as refinery-power's app.supervise.
-- Runs headless: output goes to capped log files; the screen is only a convenience.
--   <dir>/logs/events.log   state changes (4 segments, oldest overwritten)
--   errors                  on the installer floppy (<floppy>/logs/errors.log) when it is in,
--                           otherwise spooled to <dir>/logs/errors.log for the installer to copy over

local component = require("component")
local computer  = require("computer")
local fs        = require("filesystem")

local src = debug.getinfo(1, "S").source:match("^[@=](.*)/")
local here = (src and src ~= "" and src ~= "machine") and src or "/home/smux"
package.path = here .. "/?.lua;" .. here .. "/lib/?.lua;" .. package.path

local config_path, flag_mode = here .. "/smux.config.lua", nil
for _, a in ipairs({ ... }) do
    if a == "--live" then flag_mode = "live"
    elseif a == "--dry-run" then flag_mode = "dry"
    elseif a == "&" then -- a stray background marker is not a config path
    else config_path = a end
end

local smux  = require("smux")          -- init.lua: M.new builds the serve object (real gertinet endpoint)
local logs  = require("logs")         -- nodelib/logs.lua, shipped next to main.lua by the installer
local process = require("smux.backend.process")

local fsx = {
    size   = function(p) if fs.exists(p) then return fs.size(p) end end,
    append = function(p, s)
        fs.makeDirectory(fs.path(p))
        local f, e = io.open(p, "a")
        if not f then error(e) end
        f:write(s); f:close()
        return true
    end,
    rename = function(a, b) return fs.rename(a, b) end,
    remove = function(p) return fs.remove(p) end,
}
-- the event log may use at most half of the disk's free space, all segments together (refinery pattern)
local function half_free()
    local px = fs.get(here)
    return math.floor((px.spaceTotal() - px.spaceUsed()) / 2)
end
local eventlog = logs.new(fsx, { path = here .. "/logs/events.log", segments = 4, budget = half_free,
    flush_every = 10, clock = computer.uptime })
local spool = logs.new(fsx, { path = here .. "/logs/errors.log", segments = 2, bytes = 16384 })

local function floppy_dir()
    for mount in fs.list("/mnt") or function() end do
        local dir = "/mnt/" .. mount:gsub("/$", "")
        if fs.exists(dir .. "/.smux-floppy") then return dir end
    end
end

local function log_error(msg)
    eventlog:flush()
    local line = string.format("[%.0f] %s", computer.uptime(), msg)
    local dir = floppy_dir()
    if dir then
        local fl = logs.new(fsx, { path = dir .. "/logs/errors.log", segments = 4, bytes = 32768 })
        if fl:write(line) then return end
    end
    spool:write(line)
end

local function screen(msg)
    if #msg > 76 then msg = msg:sub(1, 73) .. "..." end
    pcall(print, msg)
end

-- ---------------------------------------------------------------- config -------------------------

local function read_mode_file()
    local f = io.open(here .. "/mode", "r")
    local text = f and f:read("*a") or ""
    if f then f:close() end
    return text:match("^%s*dry") and "dry" or nil
end

local function load_config(path)
    local ok, cfg = pcall(dofile, path)
    if not ok or type(cfg) ~= "table" then
        error("cannot load config '" .. path .. "': " .. tostring(cfg), 0)
    end
    if type(cfg.secret) ~= "string" or cfg.secret == "" then
        error("config: secret must be a non-empty string (the shared auth secret)", 0)
    end
    local trusted = {}
    for _, a in ipairs(cfg.trusted or {}) do
        local s = tostring(a)
        if s ~= "" then trusted[#trusted + 1] = s end
    end
    local jobs = {}
    for i, j in ipairs(cfg.jobs or {}) do
        if type(j) ~= "table" or type(j.name) ~= "string" or j.name == ""
            or type(j.path) ~= "string" or j.path == "" then
            error(string.format("config: jobs[%d] needs name (string) and path (string)", i), 0)
        end
        local dup = false
        for _, k in ipairs(jobs) do if k.name == j.name then dup = true break end end
        if dup then error(string.format("config: duplicate job name '%s'", j.name), 0) end
        jobs[#jobs + 1] = { name = j.name, path = j.path }
    end
    local endpoint_off = cfg.endpoint == "off"   -- config-level switch; see dry mode above
    return { secret = cfg.secret, trusted = trusted, jobs = jobs, endpoint_off = endpoint_off }
end

-- ---------------------------------------------------------------- supervise -----------------------

-- Runs make() and keeps restarting it after a crash with a growing pause (same shape as
-- refinery-power/app.lua's M.supervise - written here independently; smux has no app object).
-- Ctrl+Alt+C ("interrupted") ends the loop. After max_restarts failures in a row (a run of >5 min
-- resets the count) it gives up. make() -> ok | nil, error text. env: clock(), sleep(s), err(text).
local function supervise(env, make, opts)
    opts = opts or {}
    local delays = { 5, 10, 20, 40, 60 }
    local fails = 0
    while true do
        local started = env.clock()
        local ok, err = make()
        if ok then return "stopped" end
        if tostring(err):find("interrupted", 1, true) then return "interrupted" end
        if env.clock() - started > 300 then fails = 0 end
        fails = fails + 1
        env.err(string.format("crash %d: %s", fails, tostring(err)))
        if fails >= (opts.max_restarts or 20) then
            env.err("giving up after " .. fails .. " failures")
            return "gave up"
        end
        env.sleep(delays[math.min(fails, #delays)])
    end
end

-- ---------------------------------------------------------------- run -----------------------------

local function make(cfg, dry)
    -- Validate every job file first (dry mode stops here; live mode proceeds to spawn).
    local mains = {}
    for _, j in ipairs(cfg.jobs) do
        local fn, lerr = loadfile(j.path)
        if not fn then
            return nil, string.format("job '%s': cannot load %s: %s", j.name, j.path, tostring(lerr))
        end
        mains[j.name] = { main = fn, path = j.path }
    end

    local jobs_map = {}   -- job name -> job_console object (serve's get_job map)
    if not dry then
        for _, j in ipairs(cfg.jobs) do
            local jc = require("smux.job_console").new()
            jobs_map[j.name] = jc
            -- The job file receives its console as the first vararg (loadfile(...)(jc)) - it does
            -- NOT rely on io_patch's global-io swap, which cannot intercept a real OpenOS process's
            -- per-process fds (see docs/design.md 4 and 7.3). A job that wants stdin/stdout uses
            -- the console object directly: local console = ...
            process.create_process({ name = j.name, main = function() mains[j.name].main(jc) end })
        end
    else
        for _, j in ipairs(cfg.jobs) do
            eventlog:write(string.format("[dry] job '%s' validated (%s), not spawned", j.name, j.path))
        end
    end

    local core = require("smux.backend.core")
    core.load()   -- patch_coroutine + inject_package_patchs (jobs need these; see smux_server.lua)
    local function finish_core() pcall(core.finish) end

    if not dry and #cfg.jobs == 0 then
        finish_core()
        return nil, "config has no jobs: smux would exit immediately (add entries to config.jobs or run in dry mode)"
    end

    local serve
    if not dry then
        -- Live mode only: build the real transport + serve object. Dry mode deliberately never
        -- opens a GERTi endpoint (no live network surface while verifying an install).
        local ok_s, err = pcall(smux.new, { secret = cfg.secret, trusted = cfg.trusted, jobs = jobs_map })
        if not ok_s then finish_core(); return nil, "serve: " .. tostring(err) end
        serve = ok_s

        -- GERTi's openSocket blocks and swallows signals while it waits: queue the transport-
        -- relevant ones with event.listen (same pattern as refinery-power/main.lua); drained by
        -- serve:step() -> endpoint:poll().
        local event = require("event")
        for _, name in ipairs({ "GERTConnectionID", "GERTConnectionClose" }) do
            pcall(event.listen, name, function(_, a, b, c) serve.endpoint:signal(name, a, b, c) end)
        end
    else
        eventlog:write("[dry] config valid; not opening the GERTi transport")
    end

    if dry then finish_core(); return true end   -- validation complete; nothing to run

    local loop_yield_timeout = require("smux.backend.config").loop_yield_timeout
    local last_yield = computer.uptime()
    local last_heartbeat = 0
    local logged_done = {}   -- process -> true once its terminal state was logged
    local serve_err_logged = false
    eventlog:write(string.format("=== boot v%s mode=live jobs=%d uptime=%.0f ===",
        smux.VERSION, #cfg.jobs, computer.uptime()))

    -- Host loop (the smux_server.lua scenario's structure, productionised): a bounded signal poll,
    -- one serve pass, one process scheduling pass - until every job has finished or Ctrl+Alt+C.
    while not process.is_empty() do
        if last_yield + loop_yield_timeout < computer.uptime() or process.all_waiting() then
            local ok_s, name, a, b, c = pcall(computer.pullSignal, 0)
            if not ok_s then error(name, 0) end   -- raised (Ctrl+Alt+C "interrupted") -> supervise
            -- A plain false return is just queue_empty/timeout: the yield happened, keep looping.
            -- GERTi signals are already queued by the event.listen handlers above; serve:step()
            -- drains them - no need to route them through here.
            last_yield = computer.uptime()
        end

        local ok_s2, err_s = pcall(serve.step, serve)
        if not ok_s2 and not serve_err_logged then
            serve_err_logged = true
            eventlog:write("serve error (jobs unaffected): " .. tostring(err_s))
        end

        local ok_p, err_p = xpcall(process.next, debug.traceback)
        if not ok_p then process.error_handler(0, err_p) end

        -- Job lifecycle logging: a dead/errored job stays in the list until a later pass removes it,
        -- so log each one exactly once.
        for _, p in ipairs(process.processes) do
            local done = (p.status == "dead" or p.status == "error") and not logged_done[p]
            if done then
                logged_done[p] = true
                eventlog:write(string.format("job '%s' %s%s", p.name, p.status,
                    p.status == "error" and (": " .. tostring(p.error)) or ""))
            end
        end

        if computer.uptime() - last_heartbeat >= 60 then
            last_heartbeat = computer.uptime()
            eventlog:write(string.format("alive uptime=%.0f jobs=%d", computer.uptime(), #process.processes))
        end
    end

    -- All jobs finished (or the host was interrupted): one final serve pass so any output buffered
    -- by a job's last action still reaches an attached peer before we exit - the exact trap the
    -- smux_server.lua scenario documents.
    pcall(serve.step, serve)
    core.finish()   -- undo the package patches before returning (clean host state on stop/restart)
    return true
end

-- ---------------------------------------------------------------- boot ----------------------------

local mode = flag_mode or read_mode_file() or "live"
local dry = (mode ~= "live")

local cfg
do
    local ok, res = pcall(load_config, config_path)
    if not ok then log_error(tostring(res)); screen("smux: cannot load config"); return end
    cfg = res
end

local result = supervise({
    clock = computer.uptime,
    sleep = function(t) eventlog:tick(); os.sleep(t) end,
    err   = function(msg) log_error(msg); screen("[smux] " .. msg) end,
}, function()
    return make(cfg, dry)
end)

eventlog:write(string.format("=== stopped: %s ===", tostring(result)))
eventlog:flush()
os.sleep(2)   -- let the final OUTPUT frames reach an attached peer before this node shuts down
