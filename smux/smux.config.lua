-- smux site configuration (shipped default - the installer keeps your edits across updates and
-- leaves this one next to them as smux.config.default.lua for comparison).
--
--   secret    shared auth secret: every remote client must present exactly this string on AUTH.
--             Change it before first live use; there is no per-peer keying (see session.lua).
--   trusted   list of GERTi peer addresses allowed to connect at all (the transport-level trust
--             list, same role as refinery-power's settings.hmi_address + hmi_peers). A client not
--             listed here never gets a connection opened for it.
--   jobs      programs to spawn on boot, one entry each: { name = "j1", path = "/home/smux/jobs/echo.lua" }.
--             Each job file is loaded with loadfile and called as main(console) - the console is a
--             smux/job_console object (console:read_input() / console:write_output(text)); see
--             tools/ocemu/scenarios/smux_server.lua for a working example. A job that exits ends its
--             own process; when every configured job has finished, main.lua stops cleanly.
--   endpoint  optional: "off" forces dry mode (validate config + jobs, spawn nothing, open no GERTi
--             transport) regardless of the mode file - see docs/design.md section 7.2 for what smux's
--             dry mode means and why it is not a port of refinery-power's hardware-output distinction.

return {
    secret = "CHANGE-ME",
    trusted = {
        -- "0.1",   -- e.g. the GERTi address of your console client node(s)
    },
    jobs = {
        -- { name = "j1", path = "/home/smux/jobs/echo.lua" },
    },
}
