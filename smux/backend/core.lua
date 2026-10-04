-- smux host loop: forked directly from reference/gmux/lib/gmux/backend/core.lua, headless. The
-- host loop itself is NOT a "compute a deadline per job and wait exactly that long" design -
-- that was a real design trap a previous attempt at this file got stuck re-deriving without ever
-- writing it down: each Process already tracks its own pull_timeout and only actually resumes
-- itself when that has elapsed or a signal is pending (process.lua's Process:update, forked
-- unchanged) - the host loop doesn't need to duplicate that logic, just call process.next() in a
-- tight loop and let each process decide for itself whether it has anything to do this pass.
-- CPU cost is bounded the same way Gmux bounds it: a real (but short, non-blocking-poll) signal
-- pull only every `config.loop_yield_timeout` seconds, or immediately when every process is
-- already waiting (nothing to gain by spinning through process.next() with nothing ready).
local process = require("smux/backend/process")
local patch = require("smux/backend/patch")
local computer = require("computer")
local config = require("smux/backend/config")

local M = {}
local exited = false

function M.load()
    patch.patch_coroutine()
    patch.inject_package_patchs()
    exited = false
end

function M.finish()
    patch.undo()
end

function M.exit()
    exited = true
end

-- on_idle(poll_fn): called once per loop pass, host context (not inside any job). poll_fn(timeout)
-- does a real computer.pullSignal and (if the signal is a GERTi/transport one) feeds it to the
-- network layer instead of job processes - used by the real serve entry point; tests and the bare
-- local-only mode can omit it. stop_fn(): call to end M.loop cleanly (set from on_idle).
M.cpu_usage = 0
function M.loop(on_idle)
    local last_yield = computer.uptime()
    local last_check = computer.uptime()
    local do_stop = false
    local function stop() do_stop = true end
    while not do_stop do
        -- OR, not AND (a real bug introduced porting this from Gmux's `process.is_empty() or
        -- exited` - AND means the loop never ends once every job has naturally finished unless
        -- something ALSO explicitly called M.exit(), hanging forever): either every job is
        -- already gone, or the host was told to exit regardless of remaining jobs.
        if process.is_empty() or exited then
            break
        end
        if last_yield + config.loop_yield_timeout < computer.uptime() or process.all_waiting() then
            local data = table.pack(pcall(computer.pullSignal, 0))
            if data[1] then
                process.push_signal(table.unpack(data, 2))
            end
            last_yield = computer.uptime()
        end
        if on_idle then on_idle(stop) end
        if exited or process.is_empty() then break end
        local ok, err = xpcall(process.next, debug.traceback)
        if not ok then
            process.error_handler(0, err)
        end
        if process.is_begin() then
            local deltat = computer.uptime() - last_check
            last_check = computer.uptime()
            M.cpu_usage = deltat / config.loop_yield_timeout
        end
    end
    -- Kill children before parents, same as Gmux - a job that spawned sub-threads shouldn't
    -- outlive the parent job record that owns them.
    local killed = {}
    local function kill_with_children(proc)
        if killed[proc] then return end
        for _, child in pairs(process.processes) do
            if child.parent == proc then kill_with_children(child) end
        end
        proc:kill()
        proc:remove()
        killed[proc] = true
    end
    for _, proc in pairs(process.processes) do
        kill_with_children(proc)
    end
end

M.process = process
-- Headless: no gpu/keyboard/screen virtual components (that's Gmux's graphical frontend, out of
-- scope here) - filesystem is the only one smux's backend needs so far. eeprom may be worth
-- adding later if a job needs to read its own GERTi address/boot config, not needed for the
-- process-isolation core this file proves out.
M.virtual_components = {
    filesystem = require("smux/backend/virtual_components/filesystem"),
}

return M
