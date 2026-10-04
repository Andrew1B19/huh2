---@diagnostic disable: undefined-global, undefined-field
local computer = _G.computer
local component = _G.component
local gpu = component.list("gpu")()
local screen = component.list("screen")()
if gpu and screen then
    gpu = component.proxy(gpu)
    gpu.bind(screen)
    local w, h = gpu.getResolution()
    gpu.setForeground(0xffffff)
    gpu.setBackground(0x000000)
    gpu.fill(1, 1, w, h, " ")
    gpu.set(1, 1, "EEPROM Loading...")
end

local ok, err = false, "EEPROM not found"

local eeprom = component.list("eeprom")()
if eeprom then
    eeprom = component.invoke(eeprom, "get")
    err = "EEPROM is empty"
    if eeprom == "" then
        eeprom = nil
    else
        local err1;
        eeprom, err1 = load(eeprom, "bios.lua", "t", _G)
        if err1 then
            err = err1
        end
    end
end

if eeprom then
---@diagnostic disable-next-line: undefined-field
    ok, err = xpcall(eeprom, debug.traceback)
end

if gpu and screen then
    local w, h = gpu.getResolution()
    gpu.setForeground(0xffffff)
    gpu.setBackground(gpu.getDepth() ~= 1 and 0x000044 or 0x000000)
    gpu.fill(1, 1, w, h, " ")
    gpu.setForeground(gpu.getDepth() ~= 1 and 0x00ffff or 0xffffff)
    gpu.set(2, 1, "Unrecoverable error")
    gpu.setForeground(0xffffff)

    local y = 2
    local function write(lines)
        if lines:find("\n") then
            for line in lines:gmatch("(.-)\n") do
                write(line:gsub("\t", "    "))
            end
            return
        end
        for i = 1, #lines, w - 2 do
            gpu.set(2, y, lines:sub(i, i + w - 3))
            y = y + 1
        end
    end
    if not ok then
        write(tostring(err))
    else
        write("Computer halted")
    end
end
while true do
    computer.pullSignal(1000)
end