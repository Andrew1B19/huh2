local coroutine = require("coroutine")
local config = require("gmux/backend/config")

local M = {}
local process = {
    current_process = nil
}

M.set_process = function(p)
    process = p
end

M.patchs = {
    require("gmux/backend/patchs/00_package"),
    require("gmux/backend/patchs/01_computer"),
    require("gmux/backend/patchs/02_event"),
    require("gmux/backend/patchs/03_component"),
    require("gmux/backend/patchs/04_thread"),
    require("gmux/backend/patchs/40_keyboard"),
    require("gmux/backend/patchs/50_tty"),
    require("gmux/backend/patchs/60_io"),
    require("gmux/backend/patchs/91_gpu"),
    require("gmux/backend/patchs/92_keyboard"),
    require("gmux/backend/patchs/93_term"),
}

M.patchs_blank = {
    require("gmux/backend/patchs_blank/01_computer"),
    require("gmux/backend/patchs_blank/03_component"),
}

M.package_patchs = {
    "computer",
    "event",
    "component",
    "package",
    "thread",
    "keyboard",
    "tty",
}

function M.patch_coroutine()
    local _resume = coroutine.resume
    coroutine.resume = function(co, ...)
        while true do
            local result = table.pack(_resume(co, ...))
            if result[0] ~= config.yield_magic_value then
                return table.unpack(result)
            end
            coroutine.yield(table.unpack(result, 1, #result))
        end
    end
end

function M.create_patch_instances(options)
    local instances = {
        loads = {
            load = {},
            unload = {}
        }
    }
    for _, patch in ipairs(options.patchs or M.patchs) do
        patch(instances, options)
    end
    return instances
end

function M.inject_package_patchs()
    for _, patch in ipairs(M.package_patchs) do
        require(patch)
        local obj = package.loaded[patch]
        local real = {}
        for k, v in pairs(obj) do
            real[k] = v
        end
        local metatable = {
            __index = function(_, key)
                if key == "__real" then return real end
                if process.current_process and process.current_process.instances[patch] then
                    return process.current_process.instances[patch][key]
                end
                return real[key]
            end,
            __newindex = function(_, key, value)
                if process.current_process and process.current_process.instances[patch] then
                    process.current_process.instances[patch][key] = value
                end
                real[key] = value
            end,
            __pairs = function(t)
                local module = process.current_process and process.current_process.instances[patch] or real
                local parent = false
                return function(_, key)
                    if parent then
                        return next(module, key)
                    else
                        local k, v = next(t, key)
                        if not k then
                            parent = true
                            return next(module)
                        else
                            return k, v
                        end
                    end
                end
            end
        }
        setmetatable(real, getmetatable(obj))
        setmetatable(obj, nil)
        for k, _ in pairs(obj) do
            obj[k] = nil
        end
        setmetatable(obj, metatable)
    end
end

function M.undo()
    for _, patch in ipairs(M.package_patchs) do
        local obj = package.loaded[patch]
        local real = obj.__real
        setmetatable(obj, nil)
        for k, v in pairs(real) do
            obj[k] = v
        end
        setmetatable(obj, getmetatable(real))
    end
end

return M
