local colors_colorful = {
    background = 0x666666,
    background_selected = 0x222222,
    primary_selected = 0x00ffff,
    primary = 0x00ffff,
    secondary_selected = 0xff8800,
    secondary = 0xff8800,
    energy = 0xffffff,
    energy_filled_background = 0x00ff00,
    energy_filled = 0x000000,
    cpu = 0xffffff,
    cpu_filled_background = 0x44cccc,
    cpu_filled = 0xffffff,
    memory = 0xffffff,
    memory_filled_background = 0xff44aa,
    memory_filled = 0xffffff,
    gpu_memory = 0xffffff,
    gpu_memory_filled_background = 0xffcc44,
    gpu_memory_filled = 0x000000,
    text = 0xffffff,
}
local black = 0x000000
local white = 0xffffff
local colors_blackwhite = {
    background = black,
    background_selected = white,
    primary_selected = black,
    primary = white,
    secondary_selected = black,
    secondary = white,
    energy = white,
    energy_filled_background = white,
    energy_filled = black,
    cpu = white,
    cpu_filled_background = white,
    cpu_filled = black,
    memory = white,
    memory_filled_background = white,
    memory_filled = black,
    gpu_memory = white,
    gpu_memory_filled_background = white,
    gpu_memory_filled = black,
    text = white
}

local function main()
    local component = require("component")
    local computer = require("computer")
    local event = require("event")
    local gpu = component.gpu
    local colors = colors_colorful
    if gpu.getDepth() == 1 then
        colors = colors_blackwhite
    end
    local api = component.gmuxapi
    local redraw;

    local selected_process = nil

    local function get_selected()
        local processes = api.get_processes()
        for _, process in ipairs(processes) do
            if process.id == selected_process then
                return process
            end
        end
        return nil
    end
    local function process_info(process)
        api.create_window_buffer({
            width = 30, height = 5,
            title = "Process Info",
            x = 5, y = 5,
        }, function (gpu)
            local y = 1
            local function line(str)
                gpu.set(1, y, str)
                y = y + 1
            end
            gpu.setBackground(colors.background)
            gpu.setForeground(colors.text)
            gpu.fill(1, 1, 40, 10, " ")
            line("ProcessID: " .. process.id)
            line("Status: " .. process.status)
            line("Name: " .. process.name)
            if process.parent then
                line("Parent: " .. process.parent.id)
            end
        end):focus()
    end
    local function process_kill(process)
        process:kill()
        redraw()
    end

    local process_menu = {
        { "Info", process_info },
        { "Kill", process_kill }
    }

    local function redraw_process()
        local w, h = gpu.getResolution()
        gpu.setBackground(colors.background_selected)
        gpu.setForeground(colors.secondary_selected)
        gpu.fill(1, 2, w, 1, " ")
        local x = 1
        local y = 2
        for _, menu_item in ipairs(process_menu) do
            gpu.set(x, y, menu_item[1])
            x = x + 6
        end
        y = y + 1
        gpu.setBackground(colors.background)
        gpu.setForeground(colors.primary)
        gpu.fill(1, 3, w, h - 2, " ")
        gpu.set(1, 3, "ProcessID")
        gpu.setForeground(colors.secondary)
        gpu.set(11, 3, "Status")
        gpu.set(21, 3, "Name")
        y = y + 1
        for _, process in ipairs(api.get_processes()) do
            local pid = tostring(process.id)
            if process.id == selected_process then
                gpu.setBackground(colors.background_selected)
            else
                gpu.setBackground(colors.background)
            end
            gpu.fill(1, y, w, 1, " ")
            if process.parent then
                pid = pid .. " [" .. process.parent.id .. "]"
            end
            if process.id == selected_process then
                gpu.setForeground(colors.primary_selected)
            else
                gpu.setForeground(colors.primary)
            end
            gpu.set(1, y, pid)
            if process.id == selected_process then
                gpu.setForeground(colors.secondary_selected)
            else
                gpu.setForeground(colors.secondary)
            end
            gpu.set(11, y, process.status .. (process.win and "*" or ""))
            gpu.set(21, y, process.name)
            y = y + 1
        end
    end
    local function input_process(x, y, mask)
        if y == 2 then
            local index = math.floor(x / 6) + 1
            if index < 1 or index > #process_menu then
                return
            end
            process_menu[index][2](get_selected())
            return
        end
        local index = y - 4
        local process = nil
        for _, p in ipairs(api.get_processes()) do
            if index == 0 then
                process = p
                break
            end
            index = index - 1
        end
        if not process then
            return
        end
        selected_process = process.id
        redraw()
    end

    local function draw_bar(y, value, max_value, label, filled_bg, filled_fg, empty_bg, empty_fg)
        local w, _ = gpu.getResolution()
        local percent = value / max_value
        local text = label .. ": " .. value .. "/" .. max_value .. " (" .. math.floor(percent * 100) .. "%)"
        local text_x = math.floor((w - #text) / 2)
        local bar_x = math.floor(percent * w + 0.5)
        for x = 1, w, 1 do
            local char = x >= text_x and x < text_x + #text and
                text:sub(x - text_x + 1, x - text_x + 1) or " "
            if x <= bar_x then
                gpu.setBackground(filled_bg)
                gpu.setForeground(filled_fg)
            else
                gpu.setBackground(empty_bg)
                gpu.setForeground(empty_fg)
            end
            gpu.set(x, y, char)
        end
    end

    local function redraw_resource()
        local w, h = gpu.getResolution()
        gpu.setBackground(colors.background)
        gpu.fill(1, 2, w, h - 1, " ")
        local energy = computer.energy()
        local energy_max = computer.maxEnergy()
        draw_bar(2,
            energy, energy_max, "Energy",
            colors.energy_filled_background, colors.energy_filled,
            colors.background, colors.energy
        )
        local backend = require("gmux/backend/core")
        draw_bar(3,
            math.floor(backend.cpu_usage * 100 + 0.5), 100, "CPU",
            colors.cpu_filled_background, colors.cpu_filled,
            colors.background, colors.cpu
        )
        local memory_max = computer.totalMemory()
        local memory = memory_max - computer.freeMemory()
        draw_bar(4,
            memory, memory_max, "Memory",
            colors.memory_filled_background, colors.memory_filled,
            colors.background, colors.memory
        )
        local gpu_memory_max = component.gpu.totalMemory()
        local gpu_memory = gpu_memory_max - component.gpu.freeMemory()
        draw_bar(5,
            gpu_memory, gpu_memory_max, "GPU Memory",
            colors.gpu_memory_filled_background, colors.gpu_memory_filled,
            colors.background, colors.gpu_memory
        )
    end
    local function redraw_component()
        local w, h = gpu.getResolution()
        gpu.setBackground(colors.background)
        gpu.fill(1, 2, w, h - 1, " ")
        local components = component._real_component().list()
        gpu.setForeground(colors.primary)
        gpu.set(1, 2, "Type")
        gpu.setForeground(colors.secondary)
        gpu.set(15, 2, "Address")
        local y = 3
        for address, type in pairs(components) do
            gpu.setForeground(colors.primary)
            if component._real_component().isPrimary(address) then
                type = type .. "*"
            end
            gpu.set(1, y, type)
            gpu.setForeground(colors.secondary)
            gpu.set(15, y, address)
            y = y + 1
        end
    end

    local function input_resource(x, y, mask)
    end
    local function input_component(x, y, mask)
    end

    local tabs = {
        { "Process", redraw_process },
        { "Resource", redraw_resource },
        { "Component", redraw_component }
    }
    local inputs = {
        Process = input_process,
        Resource = input_resource,
        Component = input_component
    }

    local current_tab = "Process"

    local function redraw_tabbar()
        local w, h = gpu.getResolution()
        gpu.setBackground(colors.background)
        gpu.fill(1, 1, w, 1, " ")
        local x = 1
        for _, tab in ipairs(tabs) do
            local name = tab[1]
            if name == current_tab then
                gpu.setBackground(colors.background_selected)
                gpu.setForeground(colors.primary_selected)
            else
                gpu.setBackground(colors.background)
                gpu.setForeground(colors.primary)
            end
            gpu.set(x, 1, name)
            x = x + 10
        end
    end

    redraw = function()
        redraw_tabbar()
        for _, tab in ipairs(tabs) do
            if tab[1] == current_tab then
                tab[2]()
            end
        end
    end
    redraw()

    event.listen("screen_resize", function(_, x, y)
        redraw()
    end, math.huge, math.huge)
    event.listen("touch", function(_, source, x, y, mask)
        if source ~= component.screen.address then
            return
        end
        if y == 1 then
            local index = math.floor(x / 10) + 1
            if index < 1 or index > #tabs then
                return
            end
            current_tab = tabs[index][1]
            redraw()
            return
        end
        inputs[current_tab](x, y, mask)
    end, math.huge, math.huge)

    while true do
        os.sleep(1)
        redraw()
    end
end

return {
    name = "Monitor",
    draw_icon = function(gpu, colors, x, y)
        gpu.setBackground(colors.background)
        gpu.setForeground(colors.primary)
        gpu.set(x  , y  , "==")
        gpu.set(x  , y+1, "==")
        gpu.set(x  , y+2, [[--\    /-]])
        gpu.set(x  , y+3, [[   \--/  ]])
        gpu.setForeground(colors.secondary)
        gpu.set(x+3, y  , "... ..")
        gpu.set(x+3, y+1, ".. ...")
        gpu.setBackground(colors.background)
        gpu.setForeground(colors.text)
        gpu.set(x+2, y+4, "Monitor")
    end,
    graphics_process = {
        width = 60, height = 14,
        main = main, name = "Monitor"
    },
}
