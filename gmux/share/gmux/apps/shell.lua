return {
    name = "Shell",
    draw_icon = function(gpu, colors, x, y)
        gpu.setBackground(colors.background)
        gpu.setForeground(colors.secondary)
        gpu.set(x  , y  , "|       |")
        gpu.set(x  , y+1, "|       |")
        gpu.set(x  , y+2, "|       |")
        gpu.set(x  , y+3, "|       |")
        gpu.setForeground(colors.primary)
        gpu.set(x+1, y  ,  "OpenOS")
        gpu.set(x+1, y+1,  "#")
        gpu.setBackground(colors.text)
        gpu.set(x+3, y+1, " ")
        gpu.setBackground(colors.background)
        gpu.setForeground(colors.text)
        gpu.set(x+2, y+4, "Shell")
    end,
    graphics_process = {
        width = 75, height = 22,
        main_path = "/bin/sh.lua",
        name = "Shell"
    }
}