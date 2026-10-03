-- smux per-job virtual console: an input queue (fed by remote INPUT frames) and an output
-- buffer (filled by a job's redirected io/print), plus the "attached peer" routing pointer.
--
-- Pure module: no os/io/computer/event/component/GERTi/process dependencies - just plain Lua
-- data structures, so it runs under lua5.3 for unit tests AND inside OpenComputers where the
-- serve loop and io patch actually use it.

local M = {}
M.VERSION = "1.0.0"

--[[
new() -> console

  console:push_input(text)      append a chunk of remote input to this job's stdin queue
  console:read_input()          pop one line (or the whole queued string if no newline present);
                                returns "" when nothing is queued yet (non-blocking, so a job
                                polling for input can loop without blocking the host)
  console:input_pending()       true if any input text is currently queued

  console:write_output(text)    append captured output to this job's buffer
  console:drain_output(max_len) remove and return up to max_len bytes of buffered output ("" if none);
                                used by the serve loop to push OUTPUT frames without unbounded growth
  console:output_pending()      true if any output is currently buffered

  console:set_attached(peer)    record which remote peer address is attached (nil detaches)
  console.attached              current attached peer address, or nil
]]
function M.new()
    local c = {
        input_queue = {},   -- list of strings, FIFO
        output_buf = "",    -- single growing string; drain_output trims it from the front
        attached = nil,     -- peer address (string) currently attached to this job's console
    }

    function c:push_input(text)
        if type(text) == "string" and #text > 0 then
            table.insert(self.input_queue, text)
        end
    end

    function c:input_pending()
        return #self.input_queue > 0
    end

    -- Return one line of queued input (up to and including the first "\n"), or "" if none.
    -- A job that wants blocking-style reads can loop on this; it never blocks the host because
    -- it is a plain table operation, not an event.pull.
    function c:read_input()
        local head = self.input_queue[1]
        if not head then return "" end
        local nl = head:find("\n")
        if not nl then
            table.remove(self.input_queue, 1)
            return head
        end
        local line = head:sub(1, nl - 1)
        self.input_queue[1] = head:sub(nl + 1)
        if #self.input_queue[1] == 0 then table.remove(self.input_queue, 1) end
        return line
    end

    function c:write_output(text)
        if type(text) == "string" and #text > 0 then
            self.output_buf = self.output_buf .. text
        end
    end

    function c:output_pending()
        return #self.output_buf > 0
    end

    -- Remove up to max_len bytes from the front of the buffer and return them.
    function c:drain_output(max_len)
        if self.output_buf == "" then return "" end
        max_len = max_len or 5000
        local chunk = self.output_buf:sub(1, max_len)
        self.output_buf = self.output_buf:sub(max_len + 1)
        return chunk
    end

    function c:set_attached(peer)
        self.attached = (peer ~= nil and peer ~= "") and tostring(peer) or nil
    end

    -- Reset all state (used when a job is torn down).
    function c:reset()
        self.input_queue = {}
        self.output_buf = ""
        self.attached = nil
    end

    return c
end

return M
