local _computer = {}
for k, v in pairs(require("computer")) do
    _computer[k] = v
end
local coroutine = require("coroutine")
local math = require("math")
local config = require("gmux/backend/config")
return function(instances)
    local computer = {}
    
    local metatable = {
        __index = _computer
    }
    setmetatable(computer, metatable)
    
    local signal_queue = {}
    local last_yield = 0
    
    function computer._reset_last_yield()
        last_yield = computer.uptime()
    end
    function computer._signal_queue_has_element()
        return #signal_queue > 0
    end
    function computer._check_yield()
        if computer.uptime() - last_yield > config.yield_timeout then
            coroutine.yield(config.yield_magic_value, "timeout")
        end
    end
    function computer.pushSignal(name, ...)
        table.insert(signal_queue, {name, ...})
    end
    function computer.pullSignal(timeout)
        if timeout == nil then timeout = math.huge end
        if computer.uptime() - last_yield > config.yield_timeout then
            coroutine.yield(config.yield_magic_value, "timeout")
        end
        if #signal_queue == 0 then
            coroutine.yield(config.yield_magic_value, "queue_empty", timeout)
        end
        if #signal_queue == 0 then
            return
        end
        local signal = table.remove(signal_queue, 1)
        return table.unpack(signal)
    end
    function computer.shutdown()
    end

    function computer._use_tmpfs(tmpfs)
        _computer.tmpAddress = function()
            return tmpfs.address
        end
    end

    instances.computer = computer
end
