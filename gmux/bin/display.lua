local component = require("component")

local gpus = component.list("gpu")
local screens = component.list("screen")

io.stdout:write("GPUs: \n")
local gpus_index = 1
local gpus_indexed = {}
-- 按 address 排序显示
local gpu_addresses = {}
for address in gpus do
    table.insert(gpu_addresses, address)
end
table.sort(gpu_addresses)
for _, address in ipairs(gpu_addresses) do
    local screen = component.invoke(address, "getScreen") or "nil"
    local address_disp = address:sub(1, 8)
    if component.isPrimary(address) then
        address_disp = address_disp .. "*"
    end
    local screen_disp = screen:sub(1, 8)
    if component.isPrimary(screen) then
        screen_disp = screen_disp .. "*"
    end
    io.stdout:write(gpus_index .. ": " .. address_disp .. " -> " .. screen_disp .. "\n")
    gpus_indexed[gpus_index] = address
    gpus_index = gpus_index + 1
end

io.stdout:write("Screens: \n")
local screens_index = 1
local screens_indexed = {}
-- 按 address 排序显示
local screen_addresses = {}
for address in screens do
    table.insert(screen_addresses, address)
end
table.sort(screen_addresses)
for _, address in ipairs(screen_addresses) do
    local address_disp = address:sub(1, 8)
    if component.isPrimary(address) then
        address_disp = address_disp .. "*"
    end
    io.stdout:write(screens_index .. ": " .. address_disp .. "\n")
    screens_indexed[screens_index] = address
    screens_index = screens_index + 1
end

io.stdout:write("[gpu_number][ rebind_screen_number]\n")
local line = io.read()
-- 解析用户输入，gpu_number 和 rebind_screen_number 都是可选的
local gpu_number, rebind_screen_number
if line then
    -- 去除前后空白
    line = line:match("^%s*(.-)%s*$")
    -- 按空格或制表符分割
    local parts = {}
    for part in line:gmatch("%S+") do
        table.insert(parts, part)
    end
    gpu_number = parts[1]
    rebind_screen_number = parts[2]
end

if not gpu_number then
    return
end

local gpu = gpus_indexed[tonumber(gpu_number)]
local screen = component.invoke(gpu, "getScreen")
if rebind_screen_number then
    screen = screens_indexed[tonumber(rebind_screen_number)]
    if not screen then
        io.stdout:write("Invalid screen number\n")
        return
    end
    component.invoke(gpu, "bind", screen)
end

component.gpu.setForeground(0xffffff)
component.gpu.setBackground(0x000000)
component.gpu.set(1, 1, "Moved away.    ")

component.setPrimary("gpu", gpu)
component.setPrimary("screen", screen)
for _, keyboard in pairs(component.proxy(screen).getKeyboards()) do
    component.setPrimary("keyboard", keyboard)
    break
end

local w, h = component.invoke(gpu, "maxResolution")
component.invoke(gpu, "setResolution", w, h)

if component.isAvailable("gmuxapi") then
    component.gmuxapi.get_process().win:set_size(15, 2)
    component.gmuxapi.get_process().win:minimize(true)
end
