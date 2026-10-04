local graphics = require("gmux/frontend/graphics")
local unicode = require("unicode")
local desktop = require("gmux/frontend/desktop")
local component = require("component")

local M = {}

local current_touch = nil

local colors_blackwhite = {
    background = 0x000000,
    title_bar_background = 0xffffff,
    title_bar_text = 0x000000,
    title_bar_text_active = 0x000000,
    title_bar_text_button = 0x000000,
}
local colors_colorful = {
    background = 0x444444,
    title_bar_background = 0xffffff,
    title_bar_text = 0x888888,
    title_bar_text_active = 0x000000,
    title_bar_text_button = 0x4488ff,
}

local colors = colors_blackwhite

M.focused_window = nil
M.windows = {}

local Window = {}
function Window:new(options)
    if options.resizable == nil then
        options.resizable = options.source.set_size ~= nil
    end
    local obj = {
        x = options.x or 1,
        y = options.y or 1,
        process = options.process or nil,
        title = options.title or "Window",
        source = options.source or nil,
        layer = options.layer,
        event_handler = options.event_handler or function (...) end,
        title_bar = true,
        minimized = false,
        maximized = false,
        resizable = options.resizable,
        title_bar_dirty = true,
        onclose = options.onclose or function () end,
        no_focus = options.no_focus or false,

        title_bar_block = nil,
        body_block = nil,
        
        title_bar_buffer = nil,
    }
    setmetatable(obj, self)
    self.__index = self
    obj:init_title_bar()
    obj:init_block()
    if not options.no_focus then
        M.focused_window = obj
    end
    table.insert(M.windows, 1, obj)
    if options.bind then
        options.process.win = obj
    else
        obj.process = nil
    end
    return obj
end
function Window:set_title(title)
    self.title = title
    self.title_bar_dirty = true
end
function Window:set_title_bar(title_bar)
    self.title_bar = title_bar
    self.title_bar_dirty = true
    if title_bar then
        self:init_title_bar()
    else
        self:remove_title_bar()
    end
    desktop.copy()
end
function Window:focus(focus)
    if focus or focus == nil then
        M.focused_window = self
        self:as_top()
        desktop.copy()
        M.copy()
    else
        M.focused_window = nil
    end
end
function Window:as_top()
    if self.body_block then
        self.body_block:as_top()
    end
    if self.title_bar_block then
        self.title_bar_block:as_top()
    end
end
function Window:maximize(maximize)
    if self.minimized then
        self:minimize()
    end
    if maximize == nil then
        maximize = not self.maximized
    end
    self.maximized = maximize
    self.title_bar_dirty = true
    if maximize then
        local sw, sh = self:size()
        self.data = {self.x, self.y, sw, sh}
        self:set_position(1, 1)
        graphics.gpu.setActiveBuffer(0)
        local w, h = graphics.gpu.getResolution()
        self:set_size(w, h)
    else
        self:set_position(self.data[1], self.data[2])
        self:set_size(self.data[3], self.data[4])
    end
    self:as_top()
end
function Window:minimize(minimize)
    if self.maximized then
        self:maximize()
    end
    if minimize == nil then
        minimize = not self.minimized
    end
    self.minimized = minimize
    self.body_block:show(not minimize)
    self.title_bar_dirty = true
    desktop.copy()
end
function Window:position()
    return self.x, self.y
end
function Window:size()
    local w, h = self.source.size()
    if self.minimized then
        return w, (self.title_bar and 1 or 0)
    end
    return w, h + (self.title_bar and 1 or 0)
end

function Window:set_position(x, y)
    self.x = x
    self.y = y
    if self.title_bar_block then
        self.title_bar_block:set_position(x, y)
    end
    if self.body_block then
        self.body_block:set_position(x, y + (self.title_bar and 1 or 0))
    end
    desktop.copy()
    M.copy()
end
function Window:set_size(w, h)
    self.source.set_size(w, h - (self.title_bar and 1 or 0))
    desktop.copy()
    M.copy()
end

function Window:init_title_bar()
    if self.title_bar_buffer then
        graphics.gpu.freeBuffer(self.title_bar_buffer)
    end
    local w, h = self:size()
    self.title_bar_buffer = graphics.gpu.allocateBuffer(math.min(w, graphics.gpu.freeMemory() - 4), 1)
    if self.title_bar_block then
        return
    end
    self.title_bar_block = graphics.Block:new({
        x = self.x,
        y = self.y,
        layer = self.layer,
        source = {
            copy = function(col, row, x, y, w, h)
                self:update_title_bar()
                graphics.gpu.bitblt(0, col, row, w, h, self.title_bar_buffer, x, y)
            end,
            need_copy = function()
                return self.title_bar_dirty
            end,
            after_copy = function()
                self.title_bar_dirty = false
            end,
            size = function()
                return graphics.gpu.getBufferSize(self.title_bar_buffer)
            end
        }
    })
    self.title_bar_block.object = self
    self.title_bar_block.type = "title_bar"
    self.title_bar_dirty = true
end
function Window:update_title_bar()
    graphics.gpu.setActiveBuffer(self.title_bar_buffer)
    local w, h = self:size()
    graphics.gpu.setBackground(colors.title_bar_background)
    if M.focused_window == self then
        graphics.gpu.setForeground(colors.title_bar_text_active)
    else
        graphics.gpu.setForeground(colors.title_bar_text)
    end
    graphics.gpu.fill(1, 1, w, 1, ' ')
    self.title_text = self:process_prefix() .. self.title
    graphics.gpu.set(1, 1, self.title_text)
    graphics.gpu.setForeground(colors.title_bar_text_button)
    local char = not self.minimized and unicode.char(0x1F783) or unicode.char(0x20DF)
    graphics.gpu.set(w - 5, 1, char)
    char = self.resizable and (
        not self.maximized and unicode.char(0x2BC5) or unicode.char(0x20DF)
    ) or ' '
    graphics.gpu.set(w - 3, 1, char)
    char = unicode.char(0x2716)
    graphics.gpu.set(w - 1, 1, char)
end
function Window:remove_title_bar()
    if self.title_bar_buffer then
        graphics.gpu.freeBuffer(self.title_bar_buffer)
    end
    if self.title_bar_block then
        self.title_bar_block:remove()
    end
end

function Window:init_block()
    self.body_block = graphics.Block:new({
        x = self.x,
        y = self.y + (self.title_bar and 1 or 0),
        layer = self.layer,
        source = {
            copy = function(col, row, x, y, w, h)
                self.source.copy(col, row, x, y, w, h)
                if not self.source.set_size or not self.resizable then
                    return
                end
                local sw, sh = self.source.size()
                if x + w > sw and y + h > sh then
                    graphics.gpu.setActiveBuffer(0)
                    local tx, ty = self.x + sw - 1, self.y + sh
                    local rx, ry = graphics.gpu.getResolution()
                    if tx < 1 or ty < 1 or tx > rx or ty > ry then
                        return
                    end
                    local char, fg, bg = graphics.gpu.get(tx, ty)
                    graphics.gpu.setBackground(bg)
                    graphics.gpu.setForeground(fg)
                    if char == " " then
                        graphics.gpu.set(tx, ty, unicode.char(0x2518))
                    end
                end
            end,
            need_copy = function()
                return self.source.need_copy()
            end,
            size = function()
                return self.source.size()
            end,
            after_copy = self.source.after_copy
        }
    })
    self.source.on_set_size = function()
        if self.title_bar_block then
            self:init_title_bar()
        end
    end
    self.body_block.object = self
    self.body_block.type = "body"
end

function Window:close()
    for i, win in ipairs(M.windows) do
        if win == self then
            table.remove(M.windows, i)
            break
        end
    end
    if self.body_block then
        self.body_block:remove()
    end
    self:remove_title_bar()
    if self.process then
        self.process:kill()
    end
    if self.onclose then
        self.onclose()
    end
end

function Window:_process_prefix()
    if not self.process then
        return ""
    end
    if self.process.status == "waiting" then
        return ""
    elseif self.process.status == "dead" then
        return unicode.char(0x23F9) .. " - "
    elseif self.process.status == "error" then
        return unicode.char(0x274C) .. " - "
    end
    return ""
end

function Window:process_prefix()
    if graphics.gpu.getDepth() == 1 and M.focused_window == self then
        return unicode.char(0x1F5AE) .. " " .. self:_process_prefix()
    end
    return self:_process_prefix()
end

function Window:touch_event(signal, type, source, x, y, modify, ...)
    if not self.no_focus then
        self:focus()
    end
    if type == "title_bar" then
        if signal ~= "touch" then
            return
        end
        local w, h = self:size()
        if x == w - 5 or x == w - 4 then
            self:minimize()
            return
        end
        if (x == w - 3 or x == w - 2) and self.resizable then
            self:maximize()
            return
        end
        if x == w - 1 or x == w then
            self:close()
            return
        end
        current_touch = {
            object = self, type = "move",
            x = x - 1, y = y - 1
        }
    end
    if type == "body" then
        local w, h = self:size()
        h = h - (self.title_bar and 1 or 0)
        if x ~= w or h ~= h or not self.resizable then
            self.event_handler(signal, source, x, y, modify, ...)
            return
        end
        if signal ~= "touch" then
            self.event_handler(signal, source, x, y, modify, ...)
            return
        end
        current_touch = {
            object = self, type = "resize",
        }
    end
    if current_touch and type == "move" then
        if signal == "drop" then
            current_touch = nil
            return
        end
        local dx, dy = x - current_touch.x, y - current_touch.y
        self:set_position(dx, dy)
        if signal == "touch" then
            current_touch = nil
            return
        end
    end
    if current_touch and type == "resize" then
        if signal == "drop" then
            current_touch = nil
            return
        end
        local wx, wy = self:position()
        self:set_size(x - wx + 1, y - wy + 1)
        if signal == "touch" then
            current_touch = nil
            return
        end
    end
end

function Window:update()
    if self.title_text ~= self:process_prefix() .. self.title then
        self.title_bar_dirty = true
    end
end

local touch_events = {
    touch = 1, drag = 1, drop = 1, scroll = 1, walk = 1
}
local input_events = {
    touch = 1, drag = 1, drop = 1,
    screen_resized = 1, scroll = 1, walk = 1,
    key_down = 1, key_up = 1, clipboard = 1
}
function M.set_current_touch(object)
    current_touch = object
end

M.signal_filters = {} -- (signal, ...) -> bool(handled)

function M.handle_signal(signal, ...)
    if signal == nil then
        return
    end
    local function trigger_event_handler(func, ...)
        local ok, err = xpcall(function(...)
            func(...)
        end, debug.traceback, ...)
        if not ok then
            local api = require("gmux/frontend/api")
            api.show_error("An error occurred in the event handler: \n" .. err)
            return false
        else
            return err
        end
    end
    for _, filter in ipairs(M.signal_filters) do
        if filter(signal, ...) then
            return
        end
    end
    if input_events[signal] ~= nil then
        local source = ...
        if not component.isPrimary(source) then
            return
        end
    end
    if signal:sub(1, 1) == "$" then
        signal = signal:sub(2)
    end
    if touch_events[signal] == nil then
        if M.focused_window then
            trigger_event_handler(M.focused_window.event_handler, signal, ...)
        end
        return
    end
    local source, x, y, modify, name = ...
    if current_touch then
        trigger_event_handler(current_touch.object.touch_event, current_touch.object, signal, current_touch.type, source, x, y, modify, ...)
        return
    end
    local block = graphics.find_block(x, y)
    if not block then
        return
    end
    if block.event_handler then
        trigger_event_handler(block.event_handler, signal, source, x, y, modify, name)
        return
    end
    if not block.object then
        return
    end
    x = x - block.x + 1
    y = y - block.y + 1
    trigger_event_handler(block.object.touch_event, block.object, signal, block.type, source, x, y, modify, name)
end

function M.create_window(options)
    return Window:new(options)
end

function M.copy()
    for _, win in ipairs(M.windows) do
        win.title_bar_dirty = true
    end
end

function M.init()
    if graphics.gpu.getDepth() == 1 then
        colors = colors_blackwhite
    else
        colors = colors_colorful
    end
end

function M.tick()
    for i, win in ipairs(M.windows) do
        win:update()
    end
end

return M