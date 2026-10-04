-- ocemu scenario: proves the forked Gmux process core actually isolates crashes under real
-- OpenOS, not just plain lua5.3. Run via tools/ocemu/run.sh <project-dir-containing-smux/> \
-- smux/test/ocemu_crash_isolation.lua
local core = require("smux/backend/core")
local process = require("smux/backend/process")

core.load()

local a_done, b_crashed, b_error = false, false, nil

process.create_process({
    name = "job_a",
    main = function()
        -- Two short sleeps via event.pull timeout, proving the process actually yields and is
        -- resumed by core.loop rather than running to completion in one shot.
        require("event").pull(0.1)
        require("event").pull(0.1)
        a_done = true
    end,
})

process.create_process({
    name = "job_b",
    error_handler = function(proc, err)
        b_crashed = true
        b_error = tostring(err)
    end,
    main = function()
        require("event").pull(0.1)
        error("deliberate crash for isolation test")
    end,
})

core.loop(function(stop)
    if a_done and b_crashed then stop() end
end)

core.finish()

print("a_done=" .. tostring(a_done))
print("b_crashed=" .. tostring(b_crashed))
print("b_error_mentions_deliberate=" .. tostring(b_error ~= nil and b_error:find("deliberate", 1, true) ~= nil))

assert(a_done, "job_a should have completed normally")
assert(b_crashed, "job_b should have crashed and been caught by its own error_handler")
assert(not (b_crashed and not a_done), "job_a must not be killed by job_b's crash")
print("CRASH ISOLATION: PASS")
