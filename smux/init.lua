-- smux - server multiplexer for OpenComputers: the real (OpenOS) entry point.
--
-- This is where serve.new({endpoint = ...}) actually gets constructed with a REAL transport, not
-- the fake endpoint object test_serve.lua injects directly. The pattern mirrors refinery-power/
-- main.lua's b9bbbb9 wiring (GERTiClient + signal listeners that only queue; the control loop does
-- the work), but with smux's OWN gertinet endpoint instead of hmi/b9bbbb9net - same interface, own
-- port range (100..103) and trust list.
--
-- GERTi is optional: without GERTiClient installed (e.g. a plain lua5.3 test harness), M.new()
-- still works with an injected fake endpoint, exactly like serve.lua's existing tests do. On a real
-- computer it requires "GERTiClient" and builds the real smux_gertinet endpoint - that is the whole
-- point of this file: no more fake-only path when running for real.

local M = {}
M.VERSION = "1.0.0"

--[[
new(opts):
  opts.secret    required - shared secret, must match every client's
  opts.trusted   list/set of trusted peer GERTi addresses (required in the real-GERTi path; ignored
                 when a fake endpoint is injected)
  opts.endpoint  optional - an already-built b9bbbb9net-style endpoint (send/poll). When given, it
                 is used as-is (this is how tests inject a fake one); when absent, a real smux/
                 gertinet.lua endpoint over require("GERTiClient") is built.
  opts.get_job   function(job_id) -> job_console | nil   (preferred) OR
  opts.jobs      table: map job_id(string) -> job_console object
  opts.clock     function() -> seconds (default os.time; inject for tests)

Returns the serve object - call :step() from your loop's idle hook.
]]
function M.new(opts)
    assert(type(opts) == "table", "smux: opts table required")

    local endpoint = opts.endpoint
    if type(endpoint) ~= "table" then
        -- Real path: build smux's own GERTi transport endpoint (gertinet.lua), the same way
        -- refinery-power/main.lua builds its b9bbbb9net one.
        local ok_gerti, gerti = pcall(require, "GERTiClient")
        if not (ok_gerti and type(gerti) == "table") then
            error("smux: no endpoint given and GERTiClient is not installed - either inject opts.endpoint (tests) or run on a node with real GERTi", 0)
        end
        local ok_mod, gertinet = pcall(require, "smux.gertinet")
        if not ok_mod then error("smux: cannot load smux/gertinet.lua: " .. tostring(gertinet), 0) end

        local trusted = {}
        for _, a in ipairs(opts.trusted or {}) do trusted[#trusted + 1] = tostring(a) end
        endpoint = gertinet.new(gerti, { trusted = trusted })

        -- GERTi's openSocket blocks and swallows signals while it waits: queue the transport-relevant
        -- ones with event.listen (same pattern as refinery-power/main.lua and tools/ocemu scenarios),
        -- drained by serve:step() -> endpoint:poll().
        local ok_event, event = pcall(require, "event")
        if ok_event then
            for _, name in ipairs({ "GERTConnectionID", "GERTConnectionClose" }) do
                pcall(event.listen, name, function(_, a, b, c) endpoint:signal(name, a, b, c) end)
            end
        end
    end

    local serve_mod = require("smux.serve")
    return serve_mod.new({
        endpoint  = endpoint,
        secret    = opts.secret,
        get_job   = opts.get_job,
        jobs      = opts.jobs,
        clock     = opts.clock,
    })
end

return M
