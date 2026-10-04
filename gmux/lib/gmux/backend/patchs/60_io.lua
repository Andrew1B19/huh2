local _component = require("component")
return function(instances)
	local buffer = require("buffer")
	local tty_stream = instances.tty.stream

	local core_stdin = buffer.new("r", tty_stream)
	local core_stdout = buffer.new("w", tty_stream)
	local core_stderr = buffer.new(
		"w",
		setmetatable({
			write = function(_, str)
				return tty_stream:write("\27[31m" .. str .. "\27[37m")
			end,
		}, { __index = tty_stream })
	)

	core_stdout:setvbuf("no")
	core_stderr:setvbuf("no")
	core_stdin.tty = true
	core_stdout.tty = true
	core_stderr.tty = true

	core_stdin.close = tty_stream.close
	core_stdout.close = tty_stream.close
	core_stderr.close = tty_stream.close

	local olds = {}
	table.insert(instances.loads.load, function()
		olds = { io.input(), io.output(), io.error(), io.write }
		io.input(core_stdin)
		io.output(core_stdout)
		io.error(core_stderr)
        io.write = function (...) return core_stdout:write(...) end
	end)

	table.insert(instances.loads.unload, function()
		io.input(olds[1])
		io.output(olds[2])
		io.error(olds[3])
        io.write = olds[4]
	end)
end
