local colors_colorful = {
    background = 0x666666,
    background_input = 0x555555,
    background_selected = 0x222222,
    primary_selected = 0x00ffff,
    primary = 0x00ffff,
    secondary_selected = 0xff8800,
    secondary = 0xff8800,
    text = 0xffffff,
    text_input = 0xffffff,
}
local black = 0x000000
local white = 0xffffff
local colors_blackwhite = {
    background = black,
    background_input = black,
    background_selected = white,
    primary_selected = black,
    primary = white,
    secondary_selected = black,
    secondary = white,
    text = white,
    text_input = black
}

local function subwindow(title, func)
    local component = require("component")
    local api = component.gmuxapi

    local result = api.create_graphics_process({
        width = 20, height = 20,
        main = func
    })
    local window = api.create_window({
        source = result,
        process = result.process,
        title = title,
        event_handler = result,
        x = 2, y = 2,
        bind = true
    })
    return window
end

local function change_value(colors, x, y, value)
    local term = require("term")
    local component = require("component")
    local computer = require("computer")
    local gpu = component.gpu
    term.setCursor(x, y)
    gpu.setForeground(colors.text_input)
    gpu.setBackground(colors.background_selected)
    term.clearLine()
    term.setCursor(x, y)
    computer.pushSignal("key_down", term.keyboard(), 9, 15, "")
    computer.pushSignal("key_up", term.keyboard(), 9, 15, "")
    local v = term.read({
        dobreak = false,
        hint = function(line, pos)
            return pos == 1 and {value} or {}
        end
    })
    if v ~= nil and v:sub(#v) == "\n" then
        v = v:sub(1, #v - 1)
    end
    return v ~= nil and v or value
end

local function term_input(colors, x, y, hint)
    local term = require("term")
    local component = require("component")
    local gpu = component.gpu
    term.setCursor(x, y)
    gpu.setForeground(colors.text_input)
    gpu.setBackground(colors.background_selected)
    term.clearLine()
    term.setCursor(x, y)
    local v = term.read({
        dobreak = false,
        hint = hint,
    })
    if v ~= nil and v:sub(#v) == "\n" then
        v = v:sub(1, #v - 1)
    end
    return v
end

local function find(short)
    local component = require("component")
    for address, _ in component.__real.list() do
        if address:sub(1, #short) == short then
            return address
        end
    end
    return nil
end

local component_types = require("gmux/apps/simulator/component_types")

local function create_proxy(obj)
    return setmetatable({}, {
        __index = function(t, k)
            return obj[k]
        end,
        __pairs = function(t)
            return pairs(obj)
        end,
    })
end

local function create_env()
    local env = {
        bit32 = create_proxy(require("bit32")),
        math = create_proxy(require("math")),
        unicode = create_proxy(require("unicode")),
        coroutine = create_proxy(require("coroutine")),
        table = table,
        os = create_proxy(require("os")),
        string = string,
        debug = debug,
    
        pairs = pairs,
        ipairs = ipairs,
        pcall = pcall,
        xpcall = xpcall,
        assert = assert,
        error = error,
        type = type,
        tostring = tostring,
        tonumber = tonumber,
        select = select,
        next = next,
        print = print,
        rawget = rawget,
        rawset = rawset,
        rawequal = rawequal,
        getmetatable = getmetatable,
        setmetatable = setmetatable,
        load = load,
---@diagnostic disable-next-line: undefined-global
        checkArg = checkArg,
        _VERSION = _VERSION,
    }
    env._G = env
    return env
end

local function run_simulate(config, name)
    local component = require("component")
    local api = component.gmuxapi
    local component_real = component.__real
    local backend = require("gmux/backend/core")
    local patch = require("gmux/backend/patch")

    local components = {}
    table.insert(components, "computer")
    local env = create_env()
    local patchs = table.pack(table.unpack(patch.patchs_blank))
    table.insert(patchs, function(instances, options)
        env.computer = instances.computer
        env.component = instances.component
    end)
    local posts = {}
    local data = {
        patchs = patchs,
        posts = posts,
    }

    local auto_add_passes = {}

    local machine_file = io.open(config.machine_lua, "r")
    if not machine_file then
        error("Failed to open machine.lua: " .. config.machine_lua)
    end
    local machine_code = machine_file:read("*a")
    machine_file:close()
    local machine, err = load(machine_code, "=machine.lua", "t", env)
    if not machine then
        error("Failed to load machine.lua: " .. err)
    end

    for _, config in ipairs(config.components) do
        if not config.virtual then
            local address = find(config.address)
            if not address then
                error("Component " .. config.address .. " not found")
            end
            components[address] = true
            if component_real.type(address) == "disk_drive" then
                local media = component_real.invoke(address, "media")
                if media then
                    components[media] = true
                end
                table.insert(auto_add_passes, function(source)
                    return source == component_real.invoke(address, "media")
                end)
            end
            goto continue
        end
        local type = config.type
        local component = component_types[type]
        if not component then
            error("Unknown component type: " .. type)
        end
        local create = component_types[type].create
        if not create then
            error("Unknown component type: " .. type)
        end
        create(config, components, data)
        ::continue::
    end

    local options = {
        components = components,
        components_auto_add = function(source)
            for _, pass in ipairs(auto_add_passes) do
                if pass(source) then
                    return true
                end
            end
        end,

        name = "Simulate " .. (name or "Unknown"),
        patchs = patchs,

        error_handler = function(process, error)
            api.show_error(string.format("Error in process %s:\n%s", process.id, error))
        end,
        main = machine,
    }

    local process = backend.process.create_process(options)

    env.computer.shutdown = function()
        process:kill()
    end

    data.process = process
    for _, post in ipairs(posts) do
        post(data)
    end
end

local function add_component(components, redraw)
    local window;
    window = subwindow("Add Component", function()
        window.resizable = false
        local component = require("component")
        local event = require("event")
        local colors = colors_colorful
        local gpu = component.gpu
        if gpu.getDepth() == 1 then
            colors = colors_blackwhite
        end
        local w, h = gpu.getResolution()
        gpu.setBackground(colors.background)
        gpu.setForeground(colors.primary)
        gpu.fill(1, 1, w, h, " ")
        gpu.set(1, 1, "[Real Component]")
        local y = 2
        local keys = {}
        for key, _ in pairs(component_types) do
            table.insert(keys, key)
        end
        table.sort(keys)
        for i, key in ipairs(keys) do
            local name = component_types[key] and component_types[key].name or key
            if _G.type(name) == "function" then
                name = name({})
            end
            gpu.set(1, y, name)
            y = y + 1
            if y > h then
                break
            end
        end
        while true do
            local _, source, x, y, mask = event.pull("touch")
            if source ~= component.screen.address then
                goto continue
            end
            if y == 1 then
                local address = term_input(colors, 1, 1, function(line, pos)
                    local results = {}
                    for key, _ in component.__real.list() do
                        if key:sub(1, #line) == line then
                            table.insert(results, key)
                        end
                    end
                    table.sort(results)
                    return results
                end)
                address = address and find(address) or nil
                if address and component.__real.list()[address] then
                    table.insert(components, {
                        type = component.__real.type(address),
                        address = address,
                        virtual = false,
                    })
                    redraw()
                    window:close()
                end
            end
            local index = y - 1
            if index < 1 or index > #keys then
                goto continue
            end
            local key = keys[index]
            local component_type = component_types[key]
            if not component_type then
                goto continue
            end
            local config = {
                type = key,
                virtual = true
            }
            for _, a in ipairs(component_type.configs) do
                config[a[1]] = a[4] or nil
            end
            table.insert(components, config)
            redraw()
            window:close()
            ::continue::
        end
    end)
end
local function edit_component(comp, _redraw)
    local window;
    window = subwindow("Edit Component", function()
        local component = require("component")
        local event = require("event")
        local colors = colors_colorful
        local gpu = component.gpu
        if gpu.getDepth() == 1 then
            colors = colors_blackwhite
        end
        local interacts = {}
        local function redraw()
            local w, h = gpu.getResolution()
            gpu.setBackground(colors.background)
            gpu.setForeground(colors.primary)
            gpu.fill(1, 1, w, h, " ")
            local name = component_types[comp.type].name or comp.type
            if _G.type(name) == "function" then
                name = name(comp)
            end
            gpu.set(1, 1, name)
            local y = 2
            interacts = {}
            for _, a in ipairs(component_types[comp.type].configs) do
                if a[3] == "boolean" then
                    gpu.setBackground(colors.background_selected)
                    gpu.setForeground(colors.secondary_selected)
                    gpu.fill(1, y, w, 1, " ")
                    gpu.set(1, y, a[2])
                    gpu.set(w - 4, y, comp[a[1]] and "[X]" or "[ ]")
                    interacts[y] = function()
                        comp[a[1]] = not comp[a[1]]
                        redraw()
                    end
                    y = y + 1
                else
                    gpu.setBackground(colors.background)
                    gpu.setForeground(colors.secondary)
                    gpu.fill(1, y, w, 1, " ")
                    gpu.set(1, y, a[2])
                    y = y + 1
                    gpu.setBackground(colors.background_input)
                    gpu.setForeground(colors.text)
                    gpu.fill(1, y, w, 1, " ")
                    gpu.set(3, y, tostring(comp[a[1]] or "<nil>"))
                    local input_y = y
                    y = y + 1
                    interacts[input_y] = function()
                        local value = change_value(colors, 3, input_y, tostring(comp[a[1]] or ""))
                        if value then
                            if a[3] == "number" then
                                value = tonumber(value)
                            end
                            if value == "" then
                                value = nil
                            end
                            comp[a[1]] = value
                            redraw()
                        end
                    end
                end
            end
            gpu.setBackground(colors.background_selected)
            gpu.setForeground(colors.secondary_selected)
            gpu.fill(1, y, w, 1, " ")
            gpu.set(1, y, "Close")
            interacts[y] = function()
                window:close()
            end
            _redraw()
        end
        redraw()
        while true do
            local type, source, x, y, mask = event.pull()
            if source ~= component.screen.address then
                goto continue
            end
            if type == "touch" and interacts[y] then
                interacts[y]()
            end
            if type == "screen_resized" then
                redraw()
            end
            ::continue::
        end
    end)
end

local function main()
    local component = require("component")
    local event = require("event")
    local serialization = require("serialization")
    local fs = require("filesystem")
    local colors = colors_colorful
    local gpu = component.gpu
    if gpu.getDepth() == 1 then
        colors = colors_blackwhite
    end
    local api = component.gmuxapi
    local redraw;

    local config_file = "/home/simulator_config.cfg"

    local config = {
        machine_lua = "/usr/share/gmux/apps/simulator/machine.lua",
        components = {
            { type = "filesystem", virtual = true, filesystem = "tmpfs", as_tmpfs = true, path = "/simulator/config", label = "TmpFs" },
            { type = "eeprom", virtual = true, store = "/usr/share/gmux/apps/simulator/eeprom/lua_shell.lua", label = "Lua Shell", readonly = true },
            { type = "gpu", virtual = true, width = 60, height = 20 },
            { type = "screen", virtual = true, with_keyboard = true },
        }
    }

    local function load_config()
        if not fs.exists(config_file) then
            return
        end
        local file = io.open(config_file, "r")
        if not file then
            return
        end
        local data = file:read("*a")
        file:close()
        config = serialization.unserialize(data)
        redraw()
    end
    local function save_config()
        local file = io.open(config_file, "w")
        if not file then
            return
        end
        file:write(serialization.serialize(config))
        file:close()
    end

    local function redraw_general()
        local y = 1
        local w, h = gpu.getResolution()
        gpu.setBackground(colors.background)
        gpu.setForeground(colors.primary)
        gpu.fill(1, y, w, 1, " ")
        gpu.set(1, y, "General")
        gpu.setForeground(colors.secondary)
        gpu.set(11, y, "Config File: ")
        y = y + 1
        gpu.setBackground(colors.background_input)
        gpu.setForeground(colors.text)
        gpu.fill(1, y, w, 1, " ")
        gpu.set(3, y, config_file)
        y = y + 1
        gpu.setBackground(colors.background_selected)
        gpu.setForeground(colors.secondary_selected)
        gpu.fill(1, y, w, 1, " ")
        gpu.set(1, y, "Save")
        gpu.set(11, y, "Run")
    end
    local function touch_general(x, y, mask)
        local begin_y = 1
        if y == begin_y + 1 then
            config_file = change_value(colors, 3, y, config_file)
            load_config()
        end
        if y == begin_y + 2 then
            if x < 11 then
                save_config()
            else
                local ok, err = xpcall(run_simulate, debug.traceback, config, config_file)
                if not ok then
                    api.show_error(err)
                end
            end
        end
    end

    local selected_component = nil

    local function redraw_components()
        local y = 4
        local w, h = gpu.getResolution()
        gpu.setBackground(colors.background)
        gpu.setForeground(colors.primary)
        gpu.fill(1, y, w, 1, " ")
        gpu.set(1, y, "Components")
        gpu.setBackground(colors.background_selected)
        gpu.setForeground(colors.secondary_selected)
        y = y + 1
        gpu.set(1, y, "Add")
        gpu.set(11, y, "Remove")
        gpu.set(21, y, "Edit")
        gpu.setBackground(colors.background)
        gpu.setForeground(colors.primary)
        y = y + 1
        gpu.fill(1, y, w, h, " ")
        for i, component in ipairs(config.components) do
            if selected_component == component then
                gpu.setBackground(colors.background_selected)
                gpu.setForeground(colors.primary_selected)
            else
                gpu.setBackground(colors.background)
                gpu.setForeground(colors.primary)
            end
            gpu.fill(1, y, w, 1, " ")
            local name = component_types[component.type] and component_types[component.type].name or component.type
            if _G.type(name) == "function" then
                name = name(component)
            elseif not component.virtual then
                name = name .. " " .. component.address:sub(1, 8) .. "*"
            end
            gpu.set(1, y, name)
            y = y + 1
        end
    end
    local function input_components(x, y, mask)
        local begin_y = 4
        if y == begin_y then return end
        if y == begin_y + 1 then
            local index = math.floor((x - 1) / 10)
            if index == 0 then
                add_component(config.components, redraw_components)
            elseif index == 1 then
                if not selected_component then
                    return
                end
                for i, comp in ipairs(config.components) do
                    if comp == selected_component then
                        table.remove(config.components, i)
                        break
                    end
                end
                redraw_components()
            elseif index == 2 then
                if not selected_component then
                    return
                end
                if not selected_component.virtual then
                    return
                end
                edit_component(selected_component, redraw_components)
            end
        end
        local index = y - (begin_y + 2) + 1
        if index < 1 or index > #config.components then
            return
        end
        selected_component = config.components[index]
        redraw_components()
    end

    redraw = function()
        redraw_general()
        redraw_components()
    end
    load_config()

    event.listen("screen_resized", function(_, x, y)
        redraw()
    end, math.huge, math.huge)

    while true do
        local type, source, x, y, mask = event.pull(1, "touch")
        if type == nil then
            redraw()
            goto continue
        end
        if source ~= component.screen.address then
            goto continue
        end
        if y <= 3 then
            touch_general(x, y, mask)
        elseif y > 3 then
            input_components(x, y, mask)
        end
        ::continue::
    end
end

return {
    name = "Simulator",
    draw_icon = function(gpu, colors, x, y)
        gpu.setBackground(colors.background)
        gpu.setForeground(colors.primary)
        gpu.set(x  , y+1, "EEPROM --")
        gpu.set(x  , y+2, "   Launch")
        gpu.setForeground(colors.secondary)
        gpu.set(x  , y  , "---------")
        gpu.set(x  , y+3, "---------")
        gpu.setBackground(colors.background)
        gpu.setForeground(colors.text)
        gpu.set(x  , y+4, "Simulator")
    end,
    graphics_process = {
        width = 40, height = 20,
        main = main, name = "Simulator"
    },
}
