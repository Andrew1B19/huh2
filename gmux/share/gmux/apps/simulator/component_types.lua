local virtual_components = require("gmux/backend/core").virtual_components
local computer = require("computer")

local function find(short)
    local component = require("component")
    for address, _ in component.__real.list() do
        if address:sub(1, #short) == short then
            return address
        end
    end
    return nil
end

return {
    eeprom = {
        name = "EEPROM",
        create = function(config, components)
            local store = ""
            if config.store then
                local file = io.open(config.store, "r")
                if not file then
                    error("Failed to open EEPROM: " .. config.store)
                end
                store = file:read("*a")
                file:close()
            end
            local eeprom = virtual_components.eeprom({
                store = store,
                address = config.address,
                label = config.label or "EEPROM",
                readonly = config.readonly or false,
                onset = function(value)
                    local file = io.open(config.store, "w")
                    if file then
                        file:write(value)
                        file:close()
                    end
                end
            })
            components[eeprom.address] = eeprom
        end,
        configs = {
            { "address", "Address", "string" },
            { "label", "Label", "string", "EEPROM" },
            { "store", "Store(Path)", "string" },
            { "readonly", "Readonly", "boolean", false },
        }
    },
    gpu = {
        name = "GPU",
        create = function(config, components, data)
            local component = require("component")
            local gpu = virtual_components.gpu({
                gpu = component.gmuxapi.get_graphics().gpu,
                address = config.address,
                width = config.width or 60,
                height = config.height or 20
            })
            components[gpu.address] = gpu
            data.gpu = gpu

            table.insert(data.posts, function(data)
                component.gmuxapi.create_window({
                    source = data,
                    process = data.process,
                    title = data.process.name,
                    event_handler = data,
                    x = 2, y = 2,
                    bind = true
                })
            end)
        end,
        configs = {
            { "address", "Address", "string" },
            { "width", "Width", "number", 60 },
            { "height", "Height", "number", 20 },
        }
    },
    screen = {
        name = "Screen",
        create = function(config, components, data)
            local keyboards = {}
            if config.with_keyboard then
                local keyboard = virtual_components.keyboard()
                keyboards = {keyboard.address}
                components[keyboard.address] = keyboard
                data.keyboard = keyboard
            end
            local screen = virtual_components.screen({
                address = config.address,
                keyboards = keyboards,
            })
            components[screen.address] = screen
            data.screen = screen
        end,
        configs = {
            { "address", "Address", "string" },
            { "with_keyboard", "With Keyboard", "boolean", false },
        }
    },
    keyboard = {
        name = "Keyboard",
    },
    filesystem = {
        name = function(config)
            return "FileSystem " .. (config.filesystem or config.address or ""):sub(1, 8)
                .. (config.path and (" " .. config.path) or "") .. (not config.virtual and "*" or "")
        end,
        create = function(config, components, data)
            local filesystem = config.filesystem
            if filesystem == "tmpfs" then
                filesystem = computer.tmpAddress()
            end
            filesystem = find(filesystem)
            local component = require("component")
            local fs = virtual_components.filesystem({
                address = config.address,
                filesystem = component.__real.proxy(filesystem),
                path = config.path,
                id = config.filesystem,
                label = config.label,
            })
            components[fs.address] = fs
            table.insert(data.patchs, function(instances, options)
                if config.as_tmpfs then
                    instances.computer._use_tmpfs(fs)
                end
            end)
        end,
        configs = {
            { "address", "Address", "string" },
            { "filesystem", "FS ID(short) or `tmpfs`", "string", "tmpfs" },
            { "path", "Path", "string", "/simulator" },
            { "as_tmpfs", "As TmpFs", "boolean", false },
            { "label", "Label", "string", nil },
        }
    },
    api = {
        name = function(config)
            return "API " .. (config.name or "")
        end,
        create = function(config, components)
            local original = package.path
            package.path = original .. ";?.lua"
            local api = virtual_components.api(
                config.name,
                require(config.path)
            )
            package.path = original
            components[api.address] = api
        end,
        configs = {
            { "name", "Name", "string", "api" },
            { "path", "Path", "string", "/usr/share/gmux/apps/simulator/api/demo.lua" },
        }
    }
}