-- smux remote-console serve bridge: connects a b9bbbb9net transport endpoint to per-job virtual
-- consoles through the pure session/auth layer, so a remote peer can attach to a job, feed it
-- input (INPUT frames -> job's stdin queue) and read its output (job's stdout buffer -> OUTPUT
-- frames). This is where host-side process.lua + the new session/transport code actually meet:
-- each job's real process was given a smux/job_console object as its io sink by smux/io_patch.lua,
-- and this file routes that console to whichever remote peer is attached.
--
-- Transport contract (b9bbbb9net): send(addr, msg) / poll() -> addr, msg where `msg` is a TABLE
-- (GERTi drops bare tables only at the socket level; b9bbbb9net re-encodes them with hmi/proto).
-- We therefore wrap each SMX1 wire frame (a string from smux/framing.lua) in a small envelope
-- table { type = "SMUX", f = <frame_string> } so it survives b9bbbb9net's proto.encode/decode.
--
-- Testable under plain lua5.3: the endpoint and clock are injected, so routing/auth/output-push
-- logic can be exercised with a fake endpoint + real job_console objects - no GERTi or process.lua
-- needed for that part (only the actual wire transport needs two emulated nodes).

local framing = require("smux/framing")
local session_mod = require("smux/session")

local M = {}
M.VERSION = "1.0.0"

--[[
new(opts):
  opts.endpoint   required - a b9bbbb9net endpoint (send(addr,msg)/poll() -> addr,msg)
  opts.secret     required - shared secret, must match the client's
  opts.get_job    function(job_id) -> job_console | nil   (preferred) OR
  opts.jobs       table: map job_id(string) -> job_console object
  opts.clock      function() -> seconds   (default os.time; inject for tests)

serve:step()
  One serve-loop pass, safe to call repeatedly from the host loop's on_idle hook. Drains all
  pending inbound frames (authenticating each via session.handle), sends any reply frames back,
  then pushes up-to-date OUTPUT frames to every attached peer that has buffered job output.

serve:forget_idle(now) -> count of peers whose idle session expired (delegates to the session).
]]
function M.new(opts)
    assert(type(opts) == "table", "serve: opts table required")
    local endpoint = opts.endpoint
    if type(endpoint) ~= "table" or type(endpoint.send) ~= "function" or type(endpoint.poll) ~= "function" then
        error("serve: a b9bbbb9net-style endpoint (send/poll) is required")
    end

    -- Resolve the job lookup to a single function.
    local get_job = opts.get_job
    if type(get_job) ~= "function" then
        local jobs = opts.jobs or {}
        get_job = function(job_id)
            local jc = jobs[job_id]
            -- Accept either a bare job_console object, or { console = <job_console> }.
            if type(jc) == "table" and type(jc.console) == "table" then return jc.console end
            return jc
        end
    end

    local clock = opts.clock or (os.time and function() return os.time() end or function() return 0 end)

    -- peer -> job_id currently attached.
    local attachments = {}

    local serve = { endpoint = endpoint, get_job = get_job, clock = clock }

    -- The authenticated request handler passed to the session layer. Only runs after the frame's
    -- token has already matched the shared secret (session.lua guarantees this).
    local function execute(peer, frame)
        if frame.type == "AUTH" then
            return { framing.encode("ACK", frame.seq, "", "") }

        elseif frame.type == "ATTACH" then
            local job_id = frame.body
            local jc = get_job(job_id)
            if type(jc) ~= "table" or type(jc.set_attached) ~= "function" then
                return { framing.encode("DENY", frame.seq, "", "") }
            end
            -- Detach this peer from any job it was previously attached to.
            local prev = attachments[peer]
            if prev and prev ~= job_id then
                local old_jc = get_job(prev)
                if old_jc and old_jc.attached == peer then old_jc:set_attached(nil) end
            end
            -- If another peer was attached to this same job, clear their attachment record too.
            for other_peer, other_job in pairs(attachments) do
                if other_peer ~= peer and other_job == job_id then
                    attachments[other_peer] = nil
                end
            end
            jc:set_attached(peer)
            attachments[peer] = job_id
            return { framing.encode("ACK", frame.seq, "", "") }

        elseif frame.type == "INPUT" then
            local job_id = attachments[peer]
            if not job_id then return { framing.encode("DENY", frame.seq, "", "") } end
            local jc = get_job(job_id)
            if type(jc) ~= "table" or type(jc.push_input) ~= "function" then
                return { framing.encode("DENY", frame.seq, "", "") }
            end
            -- Verify this peer is still the attached one (another peer may have taken over).
            if jc.attached ~= peer then
                attachments[peer] = nil
                return { framing.encode("DENY", frame.seq, "", "") }
            end
            jc:push_input(frame.body)
            return { framing.encode("ACK", frame.seq, "", "") }

        elseif frame.type == "DETACH" then
            local job_id = attachments[peer]
            if job_id then
                local jc = get_job(job_id)
                if jc and jc.attached == peer then jc:set_attached(nil) end
                attachments[peer] = nil
            end
            return { framing.encode("ACK", frame.seq, "", "") }

        elseif frame.type == "BYE" then
            -- End the session: drop this peer's attachment; the session layer forgets its own state.
            local job_id = attachments[peer]
            if job_id then
                local jc = get_job(job_id)
                if jc and jc.attached == peer then jc:set_attached(nil) end
            end
            attachments[peer] = nil
            return { framing.encode("ACK", frame.seq, "", "") }

        else
            -- Unknown authenticated type: deny rather than crash.
            return { framing.encode("DENY", frame.seq, "", "") }
        end
    end

    serve.session = session_mod.new({ secret = opts.secret, execute = execute })

    function serve:_send_frame(peer, frame_string)
        endpoint:send(peer, { type = "SMUX", f = frame_string })
    end

    -- Push all buffered output for one attached peer as OUTPUT frames (chunked to MAX_BODY).
    local function push_output(peer, jc)
        while jc:output_pending() do
            local chunk = jc:drain_output(framing.MAX_BODY)
            if chunk == "" then break end
            serve:_send_frame(peer, framing.encode("OUTPUT", 0, "", chunk))
        end
    end

    function serve:step()
        local now = clock()

        -- Inbound: drain every pending frame, authenticate + route, send replies.
        while true do
            local from, msg = endpoint:poll()
            if not from then break end
            if type(msg) ~= "table" or msg.type ~= "SMUX" or type(msg.f) ~= "string" then
                goto continue
            end
            local responses = serve.session:handle(from, msg.f, now)
            for _, f in ipairs(responses) do
                serve:_send_frame(from, f)
            end
            ::continue::
        end

        -- Outbound: flush any job output to the peer currently attached to each job.
        for peer, job_id in pairs(attachments) do
            local jc = get_job(job_id)
            if type(jc) == "table" and jc.attached == peer then
                push_output(peer, jc)
            end
        end

        return serve.session:forget_idle(now)
    end

    function serve:forget_idle(now)
        return serve.session:forget_idle(now or clock())
    end

    -- Expose for tests/inspection.
    serve.attachments = attachments

    return serve
end

return M
