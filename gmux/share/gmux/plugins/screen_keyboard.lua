local main = ...

local component = require("component")

local screen = component.screen

if #screen.getKeyboards() ~= 0 and false then
    return
end

local api = require("gmux/frontend/api")
local windows = require("gmux/frontend/windows")
local graphics = require("gmux/frontend/graphics")
local desktop = require("gmux/frontend/desktop")
local keyboard = require("keyboard")
local unicode = require("unicode")

local colors = {
    background = 0x777777,
    key_background = 0x333333,
    text = 0xFFFFFF,
}

local keys = [[
Es F1 F2 F3 F4 F5 F6 F7 F8 F9 FA FB FC Del In
`~ 1! 2@ 3# 4$ 5% 6^ 7& 8* 9( 0) -_ =+ Bac Ho
Tab qQ wW eE rR tT yY uU iI oO pP [{ ]} \| PU
Caps aA sS dD fF gG hH jJ kK lL ;: '" Ente PD
Shift zZ xX cC vV bB nN mM ,< .> /? ShR Up Ed
Ctrl    Alt Space           AlR CtrR Le Do Ri
]]

local specials = {
    ["Es"] = {0x1B, 0x1B, 27, name = unicode.char(0x241B) },
    ["F1"] = {0x00, 0x00, "f1", name = "F1"},
    ["F2"] = {0x00, 0x00, "f2", name = "F2"},
    ["F3"] = {0x00, 0x00, "f3", name = "F3"},
    ["F4"] = {0x00, 0x00, "f4", name = "F4"},
    ["F5"] = {0x00, 0x00, "f5", name = "F5"},
    ["F6"] = {0x00, 0x00, "f6", name = "F6"},
    ["F7"] = {0x00, 0x00, "f7", name = "F7"},
    ["F8"] = {0x00, 0x00, "f8", name = "F8"},
    ["F9"] = {0x00, 0x00, "f9", name = "F9"},
    ["FA"] = {0x00, 0x00, "f10", name = "FA"},
    ["FB"] = {0x00, 0x00, "f11", name = "FB"},
    ["FC"] = {0x00, 0x00, "f12", name = "FC"},
    ["In"] = {0x00, 0x00, "insert", name = "In"},
    ["Del"] = {0x00, 0x00, "delete", name = "Del"},
    ["`~"] = {0x60, 0x7E, "grave"},
    ["-_"] = {0x2D, 0x5F, "minus"},
    ["=+"] = {0x3D, 0x2B, "equals"},
    ["Bac"] = {0x00, 0x00, "back", name = unicode.char(0x232B)},
    ["Tab"] = {0x00, 0x00, "tab", name = unicode.char(0x2B7E)},
    ["[{"] = {0x5B, 0x7B, "lbracket"},
    ["]}"] = {0x5D, 0x7D, "rbracket"},
    ["\\|"] = {0x5C, 0x7C, "backslash"},
    ["Ho"] = {0x00, 0x00, "home", name = "Ho"},
    ["PU"] = {0x00, 0x00, "pageUp", name = "PU"},
    ["PD"] = {0x00, 0x00, "pageDown", name = "PD"},
    ["Ed"] = {0x00, 0x00, "end", name = "Ed"},
    ["Caps"] = {0x00, 0x00, "capital", "caps", name = "Caps"},
    ["Ente"] = {0x00, 0x00, "enter", name = unicode.char(0x21B5)},
    ["Shift"] = {0x00, 0x00, "shift", "shift", name = "Shift"},
    ["Ctrl"] = {0x00, 0x00, "lcontrol", "ctrl", name = "Ctrl"},
    ["Alt"] = {0x00, 0x00, "lmenu", "alt", name = "Alt"},
    ["Space"] = {0x20, 0x20, "space", name = "Space"},
    ["AlR"] = {0x00, 0x00, "rmenu", "alt", name = "Alt"},
    ["CtrR"] = {0x00, 0x00, "rctrl", "ctrl", name = "Ctrl"},
    ["ShR"] = {0x00, 0x00, "rshift", "shift", name = unicode.char(0x21E7)},
    ["Up"] = {0x00, 0x00, "up", name = unicode.char(0x2B61)},
    ["Le"] = {0x00, 0x00, "left", name = unicode.char(0x2B60)},
    ["Do"] = {0x00, 0x00, "down", name = unicode.char(0x2B63)},
    ["Ri"] = {0x00, 0x00, "right", name = unicode.char(0x2B62)},
}

local keys_obj = {}
local special_objs = {}
local special_status = {
    caps = false, shift = false, ctrl = false, alt = false,
}
local width, height = 1, 1
do
    local x, y, w = 1, 1, 0
    local current = nil
    local has_space = false
    for i=1, #keys do
        local key = keys:sub(i, i)
        if key == " " then
            w = w + 1
            has_space = true
        end
        if key == "\n" then
            w = w + 1
            has_space = true
        end
        if current and has_space and key ~= " " then
            local obj = specials[current]
            or {current:sub(1, 1):byte(), current:sub(2, 2):byte(),
                current:sub(1, 1)}
            local normal, shift, code, special = table.unpack(obj)
            local object = {
                x = x, y = y, w = w,
                normal = normal, shift = shift,
                code = keyboard.keys[code], special = special,
                name = obj.name,
                shift_influence = normal ~= shift,
                caps_influence = normal ~= shift and 0x61 <= normal and normal <= 0x7A,
            }
            if special then
                special_objs[special] = special_objs[special] or {}
                table.insert(special_objs[special], object)
            end
            table.insert(keys_obj, object)
            x = x + w
            width = math.max(width, x - 2)
            height = math.max(height, y)
            w = 0
            current = nil
            has_space = false
        end
        if key == "\n" then
            x = 1
            y = y + 1
        end
        if key == " " or key == "\n" then
            goto continue
        end
        w = w + 1
        if current == nil then
            current = key
            goto continue
        else
            current = current .. key
        end
        ::continue::
    end
end

local function key_char(obj)
    local normal, shift, shift_influence, caps_influence
        = obj.normal, obj.shift, obj.shift_influence, obj.caps_influence
    if 0x40 <= shift and shift <= 0x5F and special_status.ctrl then
        return shift - 0x40
    end
    local toggle_1 = (shift_influence and special_status.shift)
    local toggle_2 = (caps_influence and special_status.caps)
    return toggle_1 ~= toggle_2 and shift or normal
end
local function redraw(gpu, object)
    local x, y, w = object.x, object.y, object.w
    local special = object.special
    local name = object.name
    local status = special_status[special]
    local fg, bg = colors.text, colors.key_background
    if status ~= nil and status then
        fg, bg = colors.key_background, colors.text
    end
    if name == nil then
        name = unicode.char(key_char(object))
    end
    gpu.setBackground(bg)
    gpu.setForeground(fg)
    gpu.fill(x, y, w - 1, 1, " ")
    gpu.set(x, y, name)
end

local function redraw_special(gpu, special)
    local objects = special_objs[special]
    for _, object in ipairs(objects) do
        redraw(gpu, object)
    end
end
local function redraw_shift_influence(gpu)
    for _, object in ipairs(keys_obj) do
        if object.shift_influence then
            redraw(gpu, object)
        end
    end
end
local function redraw_caps_influence(gpu)
    for _, object in ipairs(keys_obj) do
        if object.caps_influence then
            redraw(gpu, object)
        end
    end
end
local function redraw_all(gpu)
    for _, object in ipairs(keys_obj) do
        redraw(gpu, object)
    end
end

local function interact(gpu, key, operator)
    if key.special then
        local status = special_status[key.special]
        if status then
            main.handle_signal("$key_up", "virtual", key_char(key), key.code, operator)
        else
            main.handle_signal("$key_down", "virtual", key_char(key), key.code, operator)
        end
        special_status[key.special] = not status
        redraw_special(gpu, key.special)
        if key.special == "shift" then
            redraw_shift_influence(gpu)
        elseif key.special == "caps" then
            redraw_caps_influence(gpu)
        end
        return
    end
    main.handle_signal("$key_down", "virtual", key_char(key), key.code, operator)
    main.handle_signal("$key_up", "virtual", key_char(key), key.code, operator)
    if special_status.shift and key.shift_influence then
        special_status.shift = false
        redraw_special(gpu, "shift")
        redraw_shift_influence(gpu)
    end
end

local function keyboard_main()
    local component = require("component")
    local event = require("event")

    local gpu = component.gpu
    local w, h = gpu.getResolution()
    gpu.setForeground(colors.text)
    gpu.setBackground(colors.background)
    gpu.fill(1, 1, w, h, " ")
    redraw_all(gpu)

    while true do
        local signal, source, x, y, mask, operator = event.pull()
        if signal == "touch" then
            local key = nil
            for _, object in ipairs(keys_obj) do
                if object.x <= x and x <= object.x + object.w - 2 and
                    object.y <= y and y <= object.y + 1 then
                        key = object
                end
            end
            if key then
                interact(gpu, key, operator)
            end
        end
    end
end

graphics.gpu.setActiveBuffer(0)
local w, h = graphics.gpu.getResolution()

local keyboard_window = nil
local function toggle_keyboard()
    if keyboard_window then
        keyboard_window:close()
        keyboard_window = nil
        return
    end
    local opt = {
        width = width, height = height,
        main = keyboard_main
    }
    local process = api.create_graphics_process(opt)
    local window = api.create_window({
        source = process,
        process = process.process,
        title = "Keyboard",
        event_handler = process,
        layer = 800,
        x = w - opt.width - 2, y = h - opt.height - 2,
        bind = true, no_focus = true,
        onclose = function()
            keyboard_window = nil
        end,
        resizable = false,
    })
    keyboard_window = window
end

local keyboard_block = graphics.Block:new({
    x = w - 1,
    y = h,
    source = {
        copy = function(col, row, x, y, w, h)
            graphics.gpu.setActiveBuffer(0)
            if keyboard_window then
                graphics.gpu.setBackground(desktop.colors.background)
                graphics.gpu.setForeground(desktop.colors.secondary)
            else
                graphics.gpu.setBackground(desktop.colors.background)
                graphics.gpu.setForeground(desktop.colors.text)
            end
            graphics.gpu.set(col, row, unicode.char(0x1F5AE))
        end,
        need_copy = function()
            return true
        end,
        size = function()
            return 2, 1
        end,
    },
    event_handler = function(signal)
        if signal == "touch" then
            toggle_keyboard()
        end
    end
})