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
    local event = instances.event
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

    local adding = {}
    local primaries = {}
    function component._push_components()
        for address, _ in pairs(components) do
            if address ~= "_index" then
                computer.pushSignal("components_added", address, component.type(address))
            end
        end
    end
    function component._push_primaries()
        for address in pairs(components) do
            if address ~= "_index" then
                component.getPrimary(component.type(address))
            end
        end
    end

    -------------------------------------------------------------------------------

    -- This allows writing component.modem.open(123) instead of writing
    -- component.getPrimary("modem").open(123), which may be nicer to read.
    setmetatable(component, {
        __index = function(_, key)
            return component.getPrimary(key)
        end,
        __pairs = function(self)
            local parent = false
            return function(_, key)
            if parent then
                return next(primaries, key)
            else
                local k, v = next(self, key)
                if not k then
                parent = true
                return next(primaries)
                else
                return k, v
                end
            end
            end
        end
    })

    function component.get(address, componentType)
        checkArg(1, address, "string")
        checkArg(2, componentType, "string", "nil")
        for c in component.list(componentType, true) do
            if c:sub(1, address:len()) == address then
            return c
            end
        end
        return nil, "no such component"
    end

    function component.isAvailable(componentType)
        checkArg(1, componentType, "string")
        if not primaries[componentType] and not adding[componentType] then
            -- This is mostly to avoid out of memory errors preventing proxy
            -- creation cause confusion by trying to create the proxy again,
            -- causing the oom error to be thrown again.
            component.setPrimary(componentType, component.list(componentType, true)())
        end
        return primaries[componentType] ~= nil
    end

    function component.isPrimary(address)
        local componentType = component.type(address)
        if componentType then
            if component.isAvailable(componentType) then
            return primaries[componentType].address == address
            end
        end
        return false
    end

    function component.getPrimary(componentType)
        checkArg(1, componentType, "string")
        assert(component.isAvailable(componentType),
            "no primary '" .. componentType .. "' available")
        return primaries[componentType]
    end

    function component.setPrimary(componentType, address)
        checkArg(1, componentType, "string")
        checkArg(2, address, "string", "nil")
        if address ~= nil then
            address = component.get(address, componentType)
            assert(address, "no such component")
        end

        local wasAvailable = primaries[componentType]
        if wasAvailable and address == wasAvailable.address then
            return
        end
        local wasAdding = adding[componentType]
        if wasAdding and address == wasAdding.address then
            return
        end
        if wasAdding then
            event.cancel(wasAdding.timer)
        end
        primaries[componentType] = nil
        adding[componentType] = nil

        local primary = address and component.proxy(address) or nil
        if wasAvailable then
            computer.pushSignal("component_unavailable", componentType)
        end
        if primary then
            if wasAvailable or wasAdding then
            adding[componentType] = {
                address=address,
                proxy = primary,
                timer=event.timer(0.1, function()
                adding[componentType] = nil
                primaries[componentType] = primary
                computer.pushSignal("component_available", componentType)
                end)
            }
            else
            primaries[componentType] = primary
            computer.pushSignal("component_available", componentType)
            end
        end
    end

    -------------------------------------------------------------------------------

    local function onComponentAdded(_, address, componentType)
    local prev = primaries[componentType] or (adding[componentType] and adding[componentType].proxy)

    if prev then
        -- special handlers -- some components are just better at being primary
        if componentType == "screen" then
        --the primary has no keyboards but we do
        if #prev.getKeyboards() == 0 then
            local first_kb = component.invoke(address, 'getKeyboards')[1]
            if first_kb then
            -- just in case our kb failed to achieve primary
            -- possible if existing primary keyboard became primary first without a screen
            -- then prev (a screen) was added without a keyboard
            -- and then we attached this screen+kb pair, and our kb fired first - failing to achieve primary
            -- also, our kb may fire right after this, which is fine
            component.setPrimary("keyboard", first_kb)
            prev = nil -- nil meaning we should take this new one over the previous
            end
        end
        elseif componentType == "keyboard" then
        -- to reduce signal noise, if this kb is also the prev, we do not need to reset primary
        if address ~= prev.address then
            --keyboards never replace primary keyboards unless the are the only keyboard on the primary screen
            local current_screen = primaries.screen or (adding.screen and adding.screen.proxy)
            --if there is not yet a screen, do not use this keyboard, it's not any better
            if current_screen then
            -- the next phase is complicated
            -- there is already a screen and there is already a keyboard
            -- this keyboard is only better if this is a keyboard of the primary screen AND the current keyboard is not
            -- i don't think we can trust kb order (1st vs 2nd), 2nd could fire first
            -- but if there are two kbs on a screen, we can give preferred treatment to the first
            -- thus, assume 2nd is not attached for the purposes of primary kb
            -- and THUS, whichever (if either) is the 1st kb of the current screen
            -- this is only possible if
            -- 1. the only kb on the system (current) has no screen
            -- 2. a screen is added without a kb
            -- 3. this kb is added later manually

            -- prev is true when addr is not equal to the primary keyboard of the current screen -- meaning
            -- when addr is different, and thus it is not the primary keyboard, then we ignore this
            -- keyboard, and keep the previous
            -- prev is false means we should take this new keyboard
            prev = address ~= current_screen.getKeyboards()[1]
            end
        end
        end
    end

    if not prev then
        component.setPrimary(componentType, address)
    end
    end

    local function onComponentRemoved(_, address, componentType)
    if primaries[componentType] and primaries[componentType].address == address or
        adding[componentType] and adding[componentType].address == address
    then
        local next = component.list(componentType, true)()
        component.setPrimary(componentType, next)

        if componentType == "screen" and next then
        -- setPrimary already set the proxy (if successful)
        local proxy = (primaries.screen or (adding.screen and adding.screen.proxy))
        if proxy then
            -- if a screen is removed, and the primary keyboard is actually attached to another, non-primary, screen
            -- then the `next` screen, if it has a keyboard, should TAKE priority
            local next_kb = proxy.getKeyboards()[1] -- costly, don't call this method often
            local old_kb = primaries.keyboard or adding.keyboard
            -- if the next screen doesn't have a kb, this operation is without purpose, leave things as they are
            -- if there was no previous kb, use the new one
            if next_kb and (not old_kb or old_kb.address ~= next_kb) then
            component.setPrimary("keyboard", next_kb)
            end
        end
        end
    end
    end

    event.listen("component_added", onComponentAdded)
    event.listen("component_removed", onComponentRemoved)

    if _G.boot_screen then
    component.setPrimary("screen", _G.boot_screen)
    end
    _G.boot_screen = nil
    
    instances.component = component
end
