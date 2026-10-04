local _component = {}
for k, v in pairs(require("component")) do
    _component[k] = v
end
return function(instances, options)
    local _primaries = {}
    for k, v in _component.list() do
        if _component.isPrimary(k) then
            _primaries[k] = v
        end
    end
    local computer = instances.computer
    local component = {}

    local components = options.components or {}
    for i, v in ipairs(components) do
        local address = _component.list(v)()
        if address then
            components[address] = true
        end
        components[i] = nil
    end
    for _, v in pairs(components) do
        if type(v) == "table" and v.pushSignal then
            v.pushSignal = function(name, ...)
                computer.pushSignal(name, v.address, ...)
            end
        end
    end
    function component._get_components()
        return components
    end
    function component._real_component()
        return _component
    end
    function component._add_component(table)
        if type(table) == "table" then
            components[table.address] = table
            if table.pushSignal then
                table.pushSignal = function(name, ...)
                    computer.pushSignal(name, table.address, ...)
                end
            end
            computer.pushSignal("component_added", table.address, table.type)
            return
        end
        components[table] = true
        computer.pushSignal("component_added", table, _component.type(table))
    end
    function component._remove_component(address)
        computer.pushSignal("component_removed", address, component.type(address))
        components[address] = nil
    end
    function component._has_component(address)
        return components[address] ~= nil
    end
    function component._handle_component_signal_1(name, source, ...)
        if name == "component_added" and options.components_auto_add then
            if type(options.components_auto_add) == "function" then
                if not options.components_auto_add(source) then
                    return
                end
            end
            component._add_component(source)
        end
    end
    function component._handle_component_signal_2(name, source, ...)
        if name == "component_removed" then
            component._remove_component(source)
        end
    end
    function component.doc(address, method)
        if type(components[address]) ~= "table" then
            return _component.doc(address, method)
        end
        if components[address] then
            if not components[address][method] then
                error("no such method")
            end
            return tostring(components[address][method])
        end
        error("no such component")
    end
    function component.invoke(address, method, ...)
        if type(components[address]) ~= "table" then
            return _component.invoke(address, method, ...)
        end
        if components[address] then
            if not components[address][method] then
                error("no such method")
            end
            return components[address][method](...)
        end
        error("no such component")
    end
    function component.list(filter, exact)
        local output = {}
        local output_list = {}
        local function filte(v)
            if not filter then
                return true
            end
            if exact then
                return component.type(v) == filter
            else
                return component.type(v):match(filter)
            end
        end
        for k, v in pairs(_component.list()) do
            if component._has_component(k) then
                if _primaries[k] ~= nil and filte(k) then
                    output[k] = component.type(k)
                    table.insert(output_list, k)
                end
            end
        end
        for k, v in pairs(components) do
            if k == "_index" or type(v) ~= "table" then
                goto continue
            end
            if not filte(v) then
                goto continue
            end
            output[k] = component.type(k)
            table.insert(output_list, k)
            ::continue::
        end
        for k, v in pairs(components) do
            if k == "_index" or output[k] then
                goto continue
            end
            if not filte(type(v) == "table" and v or k) then
                goto continue
            end
            output[k] = component.type(k)
            table.insert(output_list, k)
            ::continue::
        end

        local _index = 0
        setmetatable(output, {
            __call = function (t)
                _index = _index + 1
                if not output_list[_index] then return end
                return output_list[_index], component.type(output_list[_index])
            end,
            __pairs = function (t)
                local _index = 0
                return function (t, k)
                    _index = _index + 1
                    if not output_list[_index] then return end
                    return output_list[_index], component.type(output_list[_index])
                end, t, 0
            end
        })
        return output
    end
    function component.methods(address)
        if type(components[address]) ~= "table" then
            return _component.methods(address)
        end
        if components[address] then
            local methods = {}
            for k, v in pairs(components[address]) do
                methods[k] = type(v) == "function"
            end
            return methods
        end
        error("no such component")
    end
    local function wrap_proxy(proxy)
        return proxy
        -- if not proxy or proxy._wrapped then
        --     return proxy
        -- end
        -- proxy._wrapped = true
        -- local output = {}
        -- for k, v in pairs(proxy) do
        --     if type(v) == "function" and k:sub(1, 1) ~= "_" then
        --         output[k] = {}
        --         setmetatable(output[k], {
        --             __call = function(_, ...)
        --                 instances.computer._check_yield()
        --                 return v(...)
        --             end,
        --             __tostring = function()
        --                 return tostring(v)
        --             end,
        --         })
        --     else
        --         output[k] = v
        --     end
        -- end
        -- return output
    end
    function component.proxy(address)
        if type(components[address]) ~= "table" then
            return wrap_proxy(_component.proxy(address))
        end
        if components[address] then
            return wrap_proxy(components[address])
        end
        error("no such component")
    end
    function component.type(address)
        if type(address) == "table" then
            return address.type
        end
        if type(components[address]) ~= "table" then
            return _component.type(address)
        end
        if components[address] then
            return components[address].type
        end
        error("no such component")
    end
    function component.slot(address)
        if type(components[address]) ~= "table" then
            return _component.slot(address)
        end
        if components[address] then
            return -1
        end
        error("no such component")
    end

    instances.component = component
end
