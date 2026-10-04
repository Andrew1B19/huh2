local _keyboard = {}
for k, v in pairs(require("keyboard")) do
    _keyboard[k] = v
end
local coroutine = require("coroutine")
local config = require("gmux/backend/config")
return function(instances)
    local keyboard = {
        pressedChars = {},
        pressedCodes = {}
    }
    
    local metatable = {
        __index = _keyboard,
        __pairs = function(t)
            local parent = false
            return function(_, key)
                if parent then
                    return next(_keyboard, key)
                else
                    local k, v = next(t, key)
                    if not k then
                        parent = true
                        return next(_keyboard)
                    else
                        return k, v
                    end
                end
            end
        end
    }
    setmetatable(keyboard, metatable)
    

    instances.keyboard = keyboard
end
