local shell = require("shell")
local component = require("component")

if not component.isAvailable("gmuxapi") then
    io.stderr:write("Error: gmuxapi not available")
    return
end

local args, ops = shell.parse(...)

if #args ~= 1 then
    io.stderr:write("Usage: start <path>")
    return
end

local resolved = shell.resolve(args[1])

local api = component.gmuxapi
local result = api.create_graphics_process({
    width = 90, height = 20,
    main_path = resolved,
})
local window = api.create_window({
    source = result,
    process = result.process,
    title = resolved,
    event_handler = result,
    x = 10, y = 10
})
