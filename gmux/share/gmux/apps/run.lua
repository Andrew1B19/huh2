local colors_colorful = {
    background = 0x000000,
    prompt = 0x00ffff,
    text = 0xffffff
}
local colors_blackwhite = {
    background = 0xffffff,
    prompt = 0x000000,
    text = 0x000000
}

local function main()
    local component = require("component")
    local gpu = component.gpu
    local colors = colors_blackwhite
    if gpu.getDepth() ~= 1 then
        colors = colors_colorful
    end
    local api = component.gmuxapi

    api.get_process().win.resizable = false

    local w, h = gpu.getResolution()
    gpu.setForeground(colors.prompt)
    gpu.setBackground(colors.background)
    gpu.fill(1, 1, w, h, " ")
    io.write("Path: \n> ")
    gpu.setBackground(colors.background)
    gpu.setForeground(colors.text)
    gpu.fill(3, 2, w - 6, 1, " ")
    local line = io.stdin:readLine(false)
    local resolved = require("text").trim(line)
    local result = api.create_graphics_process({
        width = 60, height = 20,
        main_path = resolved
    })
    local window = api.create_window({
        source = result,
        process = result.process,
        title = resolved,
        event_handler = result,
        x = 2, y = 2
    })

    api.get_process().win:close()
end

return {
    name = "Run...",
    draw_icon = function(gpu, colors, x, y)
        gpu.setBackground(colors.background)
        gpu.setForeground(colors.secondary)
        gpu.set(x  , y  , "---------")
        gpu.setForeground(colors.primary)
        gpu.set(x  , y+1, "Run:")
        gpu.set(x  , y+2, ">")
        gpu.setForeground(colors.secondary)
        gpu.set(x  , y+3, "---------")
        gpu.setBackground(colors.text)
        gpu.set(x+2, y+2, " ")
        gpu.setBackground(colors.background)
        gpu.setForeground(colors.text)
        gpu.set(x+3, y+4, "Run")
    end,
    graphics_process = {
        width = 50, height = 2,
        main = main, name = "Run"
    },
}
