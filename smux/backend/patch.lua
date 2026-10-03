local coroutine = require("coroutine")
local config = require("smux/backend/config")

local M = {}
local process = {
    current_process = nil
}

M.set_process = function(p)
    process = p
end

-- Headless: only the non-graphical patches from Gmux's original list (00-04). 40_keyboard,
-- 50_tty, 60_io, 91_gpu, 92_keyboard, 93_term are Gmux's graphical frontend support (virtual
-- display/keyboard/terminal redirection for its windowed desktop) - out of scope for smux, and not
-- copied into smux/backend/patchs/ at all.
M.patchs = {
    require("smux/backend/patchs/00_package"),
    require("smux/backend/patchs/01_computer"),
    require("smux/backend/patchs/02_event"),
    require("smux/backend/patchs/03_component"),
    require("smux/backend/patchs/04_thread"),
}

-- package_patchs: real OpenOS module names whose package.loaded entry gets the per-process
-- metatable swap (inject_package_patchs below) - only the modules smux's own patchs/ actually
-- populate a per-process instance for. "keyboard"/"tty" dropped along with the graphical patches
-- above; "io" left to a future console-output patch, not wired yet.
M.package_patchs = {
    "computer",
    "event",
    "component",
    "package",
    "thread",
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
