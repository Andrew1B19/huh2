-- Run all smux pure-logic tests (plain lua5.3). See smux/test/ocemu_*.lua for the real-OpenOS
-- scenarios this can't exercise (run via tools/ocemu/run.sh).
package.path = "./?.lua;./nodelib/?.lua;./hmi/?.lua;./refinery-power/?.lua;" .. package.path

print("Running all smux tests...")

local FILES = {
    "smux/test/test_framing.lua",
    "smux/test/test_session.lua",
    "smux/test/test_job_console.lua",
    "smux/test/test_serve.lua",
    "smux/test/test_gertinet.lua",
    "smux/test/test_io_patch.lua",
}

for _, f in ipairs(FILES) do
    dofile(f)
end

-- job_table.lua / console_protocol.lua (v0.1) removed: job_console.lua now covers per-job state
-- tracking, and framing.lua/session.lua replace console_protocol.lua's earlier, less complete
-- attempt at the same wire framing. scheduler.lua was removed earlier (0.2.0 Gmux fork) for the
-- same reason - redundant with process.lua's own real scheduling.

print("\nAll smux tests passed successfully!")
