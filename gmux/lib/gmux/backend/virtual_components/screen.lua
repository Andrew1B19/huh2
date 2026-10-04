return function(options)
    if options == nil then
        options = {}
    end
    local screen = {
        type = "screen",
        address = options.address or "virtual0-scre-en00-0000-component000",
    }
    local isOn = true
    function screen.isOn() return isOn end
    function screen.turnOn() isOn = true end
    function screen.turnOff() isOn = false end

    function screen.getAspectRatio() return 1, 1 end
    function screen.getKeyboards() return options.keyboards or {} end
    local isPrecise = false
    function screen.isPrecise() return isPrecise end
    function screen.setPrecise(precise) isPrecise = precise end
    local isTouchModeInverted = false
    function screen.isTouchModeInverted() return isTouchModeInverted end
    function screen.setTouchModeInverted(inverted) isTouchModeInverted = inverted end

    function screen.pushSignal(...) end

    function screen._status() return { isOn = isOn, isPrecise = isPrecise, isTouchModeInverted = isTouchModeInverted } end
    return screen
end
