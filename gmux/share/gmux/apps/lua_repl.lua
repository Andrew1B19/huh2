return {
    name = "Lua REPL",
    draw_icon = function(gpu, colors, x, y)
        gpu.setBackground(colors.background)
        gpu.setForeground(colors.secondary)
        gpu.set(x  , y  , "|        ")
        gpu.set(x  , y+1, "|        ")
        gpu.set(x  , y+2, "|        ")
        gpu.set(x  , y+3, "|        ")
        gpu.setForeground(colors.primary)
        gpu.set(x+1, y  ,  "Lua REPL")
        gpu.set(x+1, y+1,  "lua>")
        gpu.setBackground(colors.text)
        gpu.set(x+6, y+1, " ")
        gpu.setBackground(colors.background)
        gpu.setForeground(colors.text)
        gpu.set(x+1, y+4, "Lua REPL")
    end,
    graphics_process = {
        width = 75, height = 22,
        main_path = "/bin/lua.lua",
        name = "Lua REPL"
    }
}