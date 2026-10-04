local desktop = require("gmux/frontend/windows")
local graphics = require("gmux/frontend/graphics")
local backend = require("gmux/backend/core")
local M = {}

function M.create_headless_process(options)
    local default_components = { "computer" }
    if backend.process.current_process then
        default_components = {}
        for k, v in pairs(backend.process.current_process.instances.component._get_components()) do
            default_components[k] = v
        end
    end
    local api = backend.virtual_components.api("gmuxapi", M)
    local components = options.components or default_components
    components[api.address] = api
    local process = backend.process.create_process({
        main = options.main or function() dofile(options.main_path) end,
        components = components,
        components_auto_add = true,
        error_handler = function(process, error)
            M.show_error(string.format("Error in process %s:\n%s", process.id, error))
        end,
    })
    return {process = process}
end
function M.create_graphics_process(options)
    local default_components = { "computer" }
    local current_process = backend.process.current_process
    if current_process then
        default_components = {}
        for k, v in pairs(current_process.instances.component._get_components()) do
            local type = current_process.instances.component.type(k)
            if type == "gpu" or type == "screen" or type == "keyboard" then
                if current_process.instances.component._real_component().isPrimary(k)
                    or _G.type(v) == "table" then
                    goto continue
                end
            end
            default_components[k] = v
            ::continue::
        end
    end
    graphics.gpu.setActiveBuffer(0)
    local rx, ry = graphics.gpu.getResolution()
    options.width = math.min(options.width or 30, rx - 2)
    options.height = math.min(options.height or 10, ry - 2)
    local vgpu = backend.virtual_components.gpu({
        gpu = options.gpu or graphics.gpu,
        width = options.width,
        height = options.height
    })
    local vkeyboard = backend.virtual_components.keyboard()
    local vscreen = backend.virtual_components.screen({
        keyboards = {vkeyboard.address}
    })
    local components = options.components or default_components
    components[vgpu.address] = vgpu
    components[vkeyboard.address] = vkeyboard
    components[vscreen.address] = vscreen
    local api = backend.virtual_components.api("gmuxapi", M)
    components[api.address] = api
    local process = backend.process.create_process({
        main = options.main or function() dofile(options.main_path) end,
        components = components,
        components_auto_add = true,
        error_handler = function(process, error)
            M.show_error(string.format("Error in process %s:\n%s", process.id, error))
        end,
        name = options.name or nil
    })
    return {process = process, gpu = vgpu, keyboard = vkeyboard, screen = vscreen}
end

local keyboard_events = {key_down = 1, key_up = 1, clipboard = 1}
local screen_events = {screen_resized = 1, touch = 1, drag = 1, drop = 1, scroll = 1, walk = 1}
local function virtual_component_event_handler(options)
    return function(type, _, ...)
        if keyboard_events[type] and options.keyboard then
            options.keyboard.pushSignal(type, ...)
        end
        if screen_events[type] and options.screen then
            options.screen.pushSignal(type, ...)
        end
    end
end

function M.create_window(options)
    if not options.gpu then options.gpu = graphics.gpu end
    local source = graphics.empty_source()
    if type(options.source) == "table" then
        source = graphics.vgpu_source(options.source.gpu, options.source.screen)
    elseif type(options.source) == "number" then
        source = graphics.buffer_source(options.gpu, options.source, options.once_copy)
    end
    local event_handler = options.event_handler
    if type(event_handler) == "table" then
        event_handler = virtual_component_event_handler(event_handler)
    end
    return desktop.create_window({
        source = source,
        process = options.process or backend.process.current_process,
        event_handler = event_handler,
        title = options.title,
        x = options.x or 1,
        y = options.y or 1,
        bind = options.bind,
        onclose = options.onclose,
        layer = options.layer,
        resizable = options.resizable,
        no_focus = options.no_focus,
    })
end
function M.create_window_buffer(options, func)
    local buffer = graphics.gpu.allocateBuffer(options.width, options.height)
    if not buffer then
        return nil
    end
    graphics.gpu.setActiveBuffer(buffer)
    local status, error = xpcall(function()
        func(graphics.gpu)
    end, debug.traceback)
    if not status then
        M.show_error(string.format("Error in window buffer %s:\n%s", options.title, error))
    end
    graphics.gpu.setActiveBuffer(0)
    return M.create_window({
        source = buffer, once_copy = true,
        gpu = graphics.gpu,
        title = options.title,
        x = options.x or 1,
        y = options.y or 1,
        bind = options.bind,
        event_handler = options.event_handler,
        layer = options.layer,
        onclose = function ()
            if options.onclose then
                options.onclose()
            end
            graphics.gpu.freeBuffer(buffer)
        end,
        resizable = options.resizable,
        no_focus = options.no_focus,
    })
end
function M.get_processes()
    return backend.process.processes
end
function M.get_windows()
    return desktop.windows
end
function M.get_backend()
    return backend
end
function M.get_graphics()
    return graphics
end

function M.show_error(error)
    graphics.gpu.setActiveBuffer(0)
    local width, height = graphics.gpu.getResolution()
    width = width - 10
    height = height - 4
    local window = M.create_window_buffer({
        width = width, height = height,
        title = "Error",
        x = 5, y = 2
    }, function (gpu)
        gpu.set(1, 1, "Error")
        gpu.setForeground(0xffffff)
        gpu.setBackground(0x000000)
        gpu.fill(1, 1, width, height, " ")
        local x = 1
        local y = 1
        for i=1, #error, 1 do
            local char = error:sub(i, i)
            if char == "\n" or x > width then
                x = 1
                y = y + 1
            end
            if char ~= "\n" then
                gpu.set(x, y, char)
                x = x + 1
            end
        end
    end)
    if not window then
        M.ocelot_log("Failed to create error window buffer")
        M.ocelot_log("Error: \n" .. error)
    end
    return window
end
local ocelot;
if require("component").isAvailable("ocelot") then
    ocelot = require("component").ocelot
end
function M.ocelot_log(message)
    if not ocelot then
        return
    end
    ocelot.log(message)
end

function M.get_process()
    return backend.process.current_process
end

return M
