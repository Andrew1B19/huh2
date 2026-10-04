local package = require("package")

-- for k in pairs(package.loaded) do
--     if type(k) == "string" and (k:sub(1, 5) == "gmux/" or k:sub(1, #"/usr/share/gmux") == "/usr/share/gmux") then
--         package.loaded[k] = nil
--     end
-- end

io.write("Load backend...\n")
local backend = require("gmux/backend/core")
local component = require("component")
io.write("Load frontend...\n")
local main = require("gmux/frontend/main")

local gpu = component.gpu
local error_happened = false

backend.load()
local function error_handler(process, error)
    gpu.setActiveBuffer(0)
    gpu.setBackground(0x000000)
    gpu.setForeground(0xff0000)
    local w, h = gpu.getResolution()
    gpu.fill(1, 1, w, h, " ")
    gpu.set(1, 1, "---Error---")
    gpu.setForeground(0xffffff)
    local str = string.format("An error occurred in process %d:\n%s", process.id, error)
    local x, y = 1, 3
    for i = 1, #str, 1 do
        local char = str:sub(i, i)
        if char == "\n" or x > w then
            x = 1
            y = y + 1
        end
        if char ~= "\n" then
            gpu.set(x, y, char)
            x = x + 1
        end
    end
    gpu.set(1, y + 1, "Press any key to continue...")
    error_happened = true
end
backend.process.create_process({
    main = main.main,
    name = "GmuxFrontend",
    components = component.list(),
    components_auto_add = true,
    args = {backend},
    error_handler = error_handler
})

backend.loop(function()
end)

backend.finish()
gpu.freeAllBuffers()
if error_happened then
    io.stdin:read()
end
gpu.setBackground(0x000000)
gpu.setForeground(0xffffff)
local w, h = gpu.getResolution()
gpu.fill(1, 1, w, h, " ")
os.execute("clear")
