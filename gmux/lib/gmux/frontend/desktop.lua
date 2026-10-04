local graphics = require("gmux/frontend/graphics")
local computer = require("computer")
local math = require("math")

local M = {}

local app_icon_width = 9
local app_icon_height = 5
local app_icon_width_mono = 3
local app_icon_height_mono = 1

local default_app_icon = ([[
/-------\
| -|... |
|- | ...|
\-------/
]]):sub(2, -2)

local colors_blackwhite = {
    background = 0x000000,

    primary = 0xffffff,
    secondary = 0xffffff,
    text = 0xffffff,
}
local colors_colorful = {
    background = 0x444444,

    primary = 0x44ffff,
    secondary = 0xff8844,
    text = 0xffffff,
}

local colors = colors_colorful

function M.init(apps)
    if graphics.gpu.getDepth() == 1 then
        colors = colors_blackwhite
    else
        colors = colors_colorful
    end
    M.colors = colors

    M.apps = apps

    M.background()
    if graphics.gpu.getDepth() == 1 then
        M.applications_mono()
    else
        M.applications()
    end
end

local background_copy = true
local applications_copy = true

function M.copy()
    background_copy = true
    applications_copy = true
end

function M.background()
    local computer = require("computer")
    local last_update = 0
    graphics.Block:new({
        x = 1,
        y = 1,
        source = {
            copy = function(col, row, x, y, w, h)
                graphics.gpu.setActiveBuffer(0)
                graphics.gpu.setBackground(colors.background)
                graphics.gpu.fill(col, row, w, h, ' ')
            end,
            need_copy = function()
                return background_copy or last_update < computer.uptime()
            end,
            size = function()
                graphics.gpu.setActiveBuffer(0)
                return graphics.gpu.getResolution()
            end,
            after_copy = function()
                background_copy = false
                last_update = computer.uptime() + 1
            end
        },
    })
end

local function draw_icon(app, gpu, colors, x, y)
    gpu.setBackground(colors.background)
    if app.draw_icon then
        app.draw_icon(gpu, colors, x, y)
        return
    end
    app.icon = app.icon or default_app_icon
    gpu.setBackground(colors.background)
    gpu.setForeground(colors.secondary)
    local x1, y1 = x, y
    for i = 1, #app.icon do
        local c = app.icon:sub(i, i)
        if c == '\n' then
            x1, y1 = x, y1 + 1
        else
            gpu.set(x1, y1, c)
            x1 = x1 + 1
        end
    end
    gpu.setForeground(colors.text)
    local x2 = x + (app_icon_width - #app.name) / 2
    gpu.set(x2, y + app_icon_height - 1, app.name)
end


function M.applications()
    local apps = M.apps
    if #apps == 0 then
        return
    end
    local w, h = graphics.gpu.getResolution()
    h = h - 2
    local apps_per_column = math.min(math.floor(h / (app_icon_height + 1)), #apps)
    local columns = math.ceil(#apps / apps_per_column)
    local width, height = (app_icon_width + 1) * columns, (app_icon_height + 1) * apps_per_column
    local buffer = graphics.gpu.allocateBuffer(width, height)
    local x = 1
    local y = 1
    graphics.gpu.setActiveBuffer(buffer)
    graphics.gpu.setBackground(colors.background)
    graphics.gpu.fill(1, 1, width, height, ' ')
    for _, app in ipairs(apps) do
        draw_icon(app, graphics.gpu, colors, x, y)
        y = y + app_icon_height + 1
        if y + app_icon_height > h then
            x = x + app_icon_width + 1
            y = 1
        end
    end
    local last_copy = 0
    local block = graphics.Block:new({
        x = 2,
        y = 2,
        source = {
            copy = function(dst_col, dst_row, src_col, src_row, w, h)
                graphics.gpu.bitblt(0, dst_col, dst_row, w, h, buffer, src_col, src_row)
            end,
            need_copy = function()
                return applications_copy or last_copy < computer.uptime()
            end,
            size = function()
                return graphics.gpu.getBufferSize(buffer)
            end,
            after_copy = function()
                applications_copy = false
                last_copy = computer.uptime() + 1
            end
        }
    })
    block.object = {
        touch_event = M.touch_event,
    }
    block.type = "apps"
end

function M.applications_mono()
    local apps = M.apps
    if #apps == 0 then
        return
    end
    local w, h = graphics.gpu.getResolution()
    h = h - 2
    local apps_per_column = math.min(math.floor(h / (app_icon_height_mono)), #apps)
    local columns = math.ceil(#apps / apps_per_column)
    local width, height = (app_icon_width_mono + 1) * columns, (app_icon_height_mono) * apps_per_column
    local buffer = graphics.gpu.allocateBuffer(width, height)
    local x = 1
    local y = 1
    graphics.gpu.setActiveBuffer(buffer)
    graphics.gpu.setBackground(colors.background)
    graphics.gpu.fill(1, 1, width, height, ' ')
    for _, app in ipairs(apps) do
        graphics.gpu.set(x, y, app.name)
        y = y + app_icon_height_mono
        if y + app_icon_height_mono > h then
            x = x + app_icon_width_mono + 1
            y = 1
        end
    end
    local block = graphics.Block:new({
        x = 2,
        y = 2,
        source = {
            copy = function(dst_col, dst_row, src_col, src_row, w, h)
                graphics.gpu.bitblt(0, dst_col, dst_row, w, h, buffer, src_col, src_row)
            end,
            need_copy = function()
                return applications_copy
            end,
            size = function()
                return graphics.gpu.getBufferSize(buffer)
            end,
            after_copy = function()
                applications_copy = false
            end
        }
    })
    block.object = {
        touch_event = M.touch_event,
    }
    block.type = "apps_mono"
end

local function run_app(app, x, y, modify)
    if app.run then
        app.run(x, y, modify)
        return
    end
    local api = require("gmux/frontend/api")
    if app.graphics_process then
        local gpu = graphics.gpu
        app.graphics_process.gpu = gpu
        local result = api.create_graphics_process(app.graphics_process)
        local window = api.create_window({
            source = result,
            process = result.process,
            title = app.name,
            event_handler = result,
            gpu = gpu, x = 2, y = 2,
            bind = true
        })
        if app.handle_window then
            app.handle_window(window)
        end
        return
    end
    api.show_error("No run function for app " .. app.name)
end

function M.touch_event(_, type, mode, _, x, y, modify, _)
    if type ~= "touch" then
        return
    end
    local apps = M.apps
    graphics.gpu.setActiveBuffer(0)
    local w, h = graphics.gpu.getResolution()
    h = h - 2
    local app_index = nil
    if mode == "apps" then
        local apps_per_column = math.min(math.floor(h / (app_icon_height + 1)), #apps)
        local app_x = math.floor((x - 1) / (app_icon_width + 1))
        local app_y = math.floor((y - 1) / (app_icon_height + 1))
        app_index = app_y + app_x * apps_per_column + 1
    elseif mode == "apps_mono" then
        local apps_per_column = math.min(math.floor(h / (app_icon_height_mono)), #apps)
        local app_x = math.floor((x - 1) / (app_icon_width_mono + 1))
        local app_y = math.floor((y - 1) / (app_icon_height_mono))
        app_index = app_y + app_x * apps_per_column + 1
    end
    if app_index < 1 or app_index > #apps then
        return
    end
    local app = apps[app_index]
    local ok, err = xpcall(function()
        run_app(app, x, y, modify)
    end, debug.traceback)
    if not ok then
        local api = require("gmux/frontend/api")
        api.show_error("Application failed to start: " .. err)
    end
end

return M