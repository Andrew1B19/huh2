local windows = require("gmux/frontend/windows")
local graphics = require("gmux/frontend/graphics")
local keyboard = require("keyboard")
local component = require("component")
local computer = require("computer")
local unicode = require("unicode")
local desktop = require("gmux/frontend/desktop")

local main = ...

local enabled = false
local block = nil
local operator = nil
local x, y = 1, 1
local function update_block()
    if not block then
        return
    end
    block:set_position(x, y)
end
local touch_sent = false
local modify = 0
local function signal_touch(mod)
    if not enabled then
        return
    end
    if touch_sent then
        return
    end
    touch_sent = true
    modify = mod
    local screen = component.screen.address
    main.handle_signal("$touch", screen, x, y, modify, operator)
end
local function signal_drag()
    if not enabled then
        return
    end
    if not touch_sent then
        return
    end
    local screen = component.screen.address
    main.handle_signal("$drag", screen, x, y, modify, operator)
end
local function signal_drop()
    if not enabled then
        return
    end
    if not touch_sent then
        return
    end
    touch_sent = false
    modify = 0
    local screen = component.screen.address
    main.handle_signal("$drop", screen, x, y, modify, operator)
end
local function toggle(event)
    if event ~= "key_down" then
        return true
    end
    if block then
        block:remove()
        block = nil
    end
    enabled = not enabled
    if enabled then
        block = graphics.Block:new({
            x = 1,
            y = 1,
            layer = 1000,
            find_block = false,
            source = {
                copy = function(col, row, x, y, w, h)
                    graphics.gpu.setActiveBuffer(0)
                    local reverse = computer.uptime() % 2 < 1
                    if reverse then
                        graphics.gpu.setForeground(desktop.colors.background)
                        graphics.gpu.setBackground(desktop.colors.primary)
                    else
                        graphics.gpu.setForeground(desktop.colors.primary)
                        graphics.gpu.setBackground(desktop.colors.background)
                    end
                    graphics.gpu.set(col, row, unicode.char(0x21D6))
                end,
                need_copy = function()
                    return true
                end,
                size = function()
                    return 1, 1
                end,
            }
        })
        update_block()
    end
    return true
end
local function move(dx, dy)
    return function(event)
        if not enabled then
            return false
        end
        if event ~= "key_down" then
            return true
        end
        graphics.gpu.setActiveBuffer(0)
        local w, h = graphics.gpu.getResolution()
        x = math.min(math.max(x + dx, 1), w)
        y = math.min(math.max(y + dy, 1), h)
        update_block()
        signal_drag()
        return true
    end
end
local function key(mod)
    return function(event)
        if not enabled then
            return false
        end
        if event == "key_down" then
            signal_touch(mod)
            return true
        end
        if event == "key_up" then
            signal_drop()
            return true
        end
        return false
    end
end

local actions = {
    [keyboard.keys.h] = toggle,
    [keyboard.keys.j] = key(0),
    [keyboard.keys.k] = key(1),

    [keyboard.keys.w] = move(0, -1),
    [keyboard.keys.s] = move(0, 1),
    [keyboard.keys.a] = move(-1, 0),
    [keyboard.keys.d] = move(1, 0),
}

local keyboard_signal = {
    key_down = true, key_up = true,
}

table.insert(windows.signal_filters, function(signal, source, char, code, player)
    operator = player
    if keyboard_signal[signal] and keyboard.isAltDown() and component.isPrimary(source) then
        if actions[code] then
            return actions[code](signal)
        end
        return false
    end
    return false
end)