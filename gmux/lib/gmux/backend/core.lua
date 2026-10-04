local process = require("gmux/backend/process")
local patch = require("gmux/backend/patch")
local computer = require("computer")
local config = require("gmux/backend/config")

local M = {}
local exited = false

function M.load()
    patch.patch_coroutine()
    patch.inject_package_patchs()
    exited = false
end

function M.finish()
    patch.undo()
end

function M.exit()
    exited = true
end

M.cpu_usage = 0
function M.loop(update)
    local last_yield = computer.uptime()
    local last_check = computer.uptime()
    local do_break = false
    while not do_break or exited do
        if process.is_empty() or exited then
            break
        end
        if last_yield + config.loop_yield_timeout < computer.uptime() or process.all_waiting() then
            local data = table.pack(pcall(computer.pullSignal, 0))
            if data[1] then
                process.push_signal(table.unpack(data, 2))
            end
            last_yield = computer.uptime()
        end
        if update then update(function() do_break = true end) end
        local ok, err = xpcall(process.next, debug.traceback)
        if not ok then
            process.error_handler(0, err)
        end
        if process.is_begin() then
            local deltat = computer.uptime() - last_check
            last_check = computer.uptime()
            M.cpu_usage = deltat / config.loop_yield_timeout
        end
    end
    -- 按照parent关系进行kill，先杀子进程再杀父进程
    local killed = {}
    local function kill_with_children(proc)
        if killed[proc] then return end
        -- 先杀所有子进程
        for _, child in pairs(process.processes) do
            if child.parent == proc then
                kill_with_children(child)
            end
        end
        -- 再杀自己
        proc:kill()
        proc:remove()
        killed[proc] = true
    end
    for _, proc in pairs(process.processes) do
        kill_with_children(proc)
    end
end

M.process = process
M.virtual_components = {
    gpu = require("gmux/backend/virtual_components/gpu"),
    keyboard = require("gmux/backend/virtual_components/keyboard"),
    screen = require("gmux/backend/virtual_components/screen"),
    api = require("gmux/backend/virtual_components/api"),
    eeprom = require("gmux/backend/virtual_components/eeprom"),
    filesystem = require("gmux/backend/virtual_components/filesystem"),
}

return M
