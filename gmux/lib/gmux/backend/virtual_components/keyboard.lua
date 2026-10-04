return function(options)
    if options == nil then
        options = {}
    end
    local keyboard = {
        type = "keyboard",
        address = options.address or "virtual0-keyb-oard-0000-component000",
    }
    function keyboard.pushSignal(...) end
    return keyboard
end
