return {
    name = "Exit",
    icon = ([[
/-------\
|  \ /  |
|  / \  |
\-------/]]),
    run = function()
        local window;
        window = require("gmux/frontend/api").create_window_buffer({
            width = 30, height = 2,
            x = 10, y = 4,
            title = "Exit",
            event_handler = function(type, _, x, y, ...)
                if type ~= "touch" then
                    return
                end
                if y ~= 2 then
                    return
                end
                if x <= 8 then
                    require("gmux/backend/core").exit()
                elseif x >= 22 then
                    window:close()
                end
            end
        }, function (gpu)
            gpu.setBackground(0x000000)
            gpu.setForeground(0xffffff)
            gpu.fill(1, 1, 20, 2, " ")
            gpu.set(1, 1, "Are you sure you want to exit?")
            gpu.setBackground(0xffffff)
            gpu.setForeground(0x000000)
            gpu.set(1, 2, "Yes     ")
            gpu.set(22, 2, "No       ")
        end)
    end
}