-- smux per-job io redirection patch (the console-output half of Gmux's 60_io.lua pattern).
--
-- Gmux's reference/gmux/lib/gmux/backend/patchs/60_io.lua redirects a job's io.input/output/error
-- and io.write to its virtual tty stream, swapping them in on process load and restoring the real
-- ones on unload (via instances.loads.load / .unload). We do the SAME mechanism but point the sink
-- at a smux/job_console object instead of a screen-backed tty: a job's print()/io.write land in that
-- job's output buffer, and its io.read pulls from that job's input queue. No gpu/screen/keyboard is
-- involved (headless), so we do NOT port 60_io.lua itself - just the general "redirect io to a
-- stream object" approach it demonstrates.
--
-- Pure module: no os/io/computer/event/component/GERTi/process dependencies, and NO dependency on
-- OpenOS's `buffer` module (which is not present under plain lua5.3). The file-like streams are
-- built as plain tables from an injected sink; the io setters themselves are injectable so tests can
-- drive a fake io without touching PUC Lua's real one. Runs under lua5.3 for unit tests and inside
-- OpenComputers where it is actually installed per-job by smux/serve.lua.

local M = {}
M.VERSION = "1.0.0"

------------------------------------------------------------------- streams --

-- make_sink(console) -> { write(text), read() -> string|nil, close() }
-- Adapts a smux/job_console object to the minimal file-like interface io needs:
--   write  -> console:write_output (captured for remote OUTPUT frames)
--   read   -> console:read_input  (one queued line at a time; nil when nothing is queued, so an
--             io.read() call blocks-style returns nil rather than hanging the host - a job that
--             wants to wait should poll in its own loop, matching how OpenOS io.read behaves on EOF)
function M.make_sink(console)
    return {
        write = function(_, text)
            if type(text) == "string" then console:write_output(text) end
        end,
        read = function(_)
            local line = console:read_input()
            -- io.read semantics: nil at EOF / no data. An empty string is a valid (blank) line.
            return line ~= "" and line or nil
        end,
        close = function() end,
    }
end

-- make_streams(sink) -> stdin, stdout, stderr  (plain file-like tables wrapping one sink).
-- Gmux gives stderr its own red-colouring wrapper; here there is no screen to colour for, so all
-- three share the same underlying console sink. Kept as distinct objects so io.input/output/error
-- can each be pointed at their own handle independently (matching OpenOS's expectation of separate
-- handles), and so a future per-stream filter has somewhere to live.
function M.make_streams(sink)
    local function stream()
        return {
            write = sink.write,
            read  = sink.read,
            close = sink.close,
            -- io.output()/io.input() in OpenOS accept any object exposing these methods; `seek` is
            -- present so code that probes for a "real" file handle doesn't choke.
            seek  = function() return nil, "console: invalid operation" end,
            -- OpenOS's print (boot/00_base.lua) calls stdout:flush() after writing - a no-op here,
            -- the console buffer is already updated synchronously by write(). Missing this method
            -- crashes real OpenOS print(); only caught under the emulator, not plain lua5.3 tests.
            flush = function(_) return true end,
        }
    end
    local stdin  = stream()
    local stdout = stream()
    local stderr = stream()
    -- Mark as tty-like the way Gmux's core_stdin/stdout/stderr do (`.tty = true`), so any code that
    -- branches on `handle.tty` treats these like a terminal.
    stdin.tty  = true
    stdout.tty = true
    stderr.tty = true
    return stdin, stdout, stderr
end

------------------------------------------------------------------- patch ----

--[[
patch(instances, options):
  A Gmux-style per-process patch (same signature as smux/backend/patchs/*.lua and reference/gmux's
  own patches). Registers load/unload handlers on instances.loads that swap the job's io handles to
  point at its console sink while the process is running, then restore them afterwards.

  options:
    .console   required - a smux/job_console object for this job (the sink source)
    .io        optional - the io table to patch (defaults to the global `io`). Injectable so tests
                can drive a fake io without touching PUC Lua's real one; under OpenComputers the real
                io is used and accepts these plain-table handles.

  This function does NOT itself require any OpenOS module, so it is safe to unit-test under lua5.3.
]]
function M.patch(instances, options)
    assert(type(options) == "table" and type(options.console) == "table",
        "io_patch: options.console (a job_console object) is required")

    local io = options.io or _G.io
    if type(io) ~= "table" then error("io_patch: no io table to patch") end

    local sink   = M.make_sink(options.console)
    local stdin, stdout, stderr = M.make_streams(sink)

    -- Capture the current handles so unload can restore exactly what was there before.
    local saved = nil

    if instances and instances.loads then
        table.insert(instances.loads.load, function()
            saved = { input = io.input(), output = io.output(), error = io.error(), write = io.write }
            io.input(stdin)
            io.output(stdout)
            io.error(stderr)
            -- Explicitly override io.write too (Gmux does this): OpenOS's print() routes through
            -- io.write, and pointing it straight at the sink avoids any ambiguity about which handle
            -- is "current".
            io.write = function(...) return stdout:write(...) end
        end)

        table.insert(instances.loads.unload, function()
            if saved then
                io.input(saved.input)
                io.output(saved.output)
                io.error(saved.error)
                io.write = saved.write
                saved = nil
            end
        end)
    else
        -- No instances/loads table (e.g. a bare call in tests): apply immediately so the caller can
        -- still exercise the swap, and expose an explicit restore for symmetry.
        M._apply_now(io, stdin, stdout, stderr)
    end

    return { stdin = stdin, stdout = stdout, stderr = stderr }
end

-- Helper used when there is no instances.loads to hook into; also handy in tests.
function M._apply_now(io, stdin, stdout, stderr)
    io.input(stdin)
    io.output(stdout)
    io.error(stderr)
    io.write = function(...) return stdout:write(...) end
end

return M
