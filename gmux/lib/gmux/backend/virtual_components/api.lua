return function(name, module)
    local id = name
    while #id < 8 do id = id .. "0" end
    local api = {
        type = name,
        address = "virtual0-"..id:sub(0, 4).."-"..id:sub(5, 8).."-0000-component000",
    }
    setmetatable(api, {
        __index = module,
        __pairs = function(t)
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
    })
    return api
end
