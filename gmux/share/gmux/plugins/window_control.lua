local windows = require("gmux/frontend/windows")
local keyboard = require("keyboard")
local component = require("component")

local function toggle_window()
    local index = nil
    for i, window in ipairs(windows.windows) do
        if window == windows.focused_window then
            index = i
            break
        end
    end
    if index == nil then
        index = 1
    end
    if keyboard.isShiftDown() then
        index = index - 1
    else
        index = index + 1
    end
    if index < 1 then
        index = #windows.windows
    elseif index > #windows.windows then
        index = 1
    end
    if windows.windows[index] then
        windows.windows[index]:focus(true)
    end
end
local function move_window_cherry(offset_x, offset_y)
    return function ()
        if not windows.focused_window then
            return
        end
        local x, y = windows.focused_window:position()
        windows.focused_window:set_position(x + offset_x, y + offset_y)
    end
end
local function resize_window_cherry(delta_x, delta_y)
    return function ()
        if not windows.focused_window then
            return
        end
        local w, h = windows.focused_window:size()
        windows.focused_window:set_size(w + delta_x, h + delta_y)
    end
end
local function close_window()
    if not windows.focused_window then
        return
    end
    windows.focused_window:close()
end
local function minimize_window()
    if not windows.focused_window then
        return
    end
    windows.focused_window:minimize()
end
local function maximize_window()
    if not windows.focused_window then
        return
    end
    windows.focused_window:maximize()
end

local actions = {
    [keyboard.keys.q] = toggle_window,
    [keyboard.keys.w] = move_window_cherry(0, -1),
    [keyboard.keys.s] = move_window_cherry(0, 1),
    [keyboard.keys.a] = move_window_cherry(-1, 0),
    [keyboard.keys.d] = move_window_cherry(1, 0),
    [keyboard.keys.left] = resize_window_cherry(-1, 0),
    [keyboard.keys.right] = resize_window_cherry(1, 0),
    [keyboard.keys.up] = resize_window_cherry(0, -1),
    [keyboard.keys.down] = resize_window_cherry(0, 1),
    [keyboard.keys.z] = minimize_window,
    [keyboard.keys.x] = maximize_window,
    [keyboard.keys.c] = close_window,
}

table.insert(windows.signal_filters, function(signal, source, char, code, player)
    if signal == "key_down" and keyboard.isAltDown() and component.isPrimary(source) then
        if actions[code] then
            actions[code]()
            return true
        end
        return false
    end
    return false
end)