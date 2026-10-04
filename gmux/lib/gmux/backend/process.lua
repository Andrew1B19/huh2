local patch = require("gmux/backend/patch")
local coroutine = require("coroutine")
local computer = require("computer")
local process = require("process")
local M = {}

M.current_process = nil
M.processes = {}

local component = require("component")
local ocelot = component.isAvailable("ocelot") and component.ocelot or nil
local function ocelot_log(msg)
    if ocelot then
        ocelot.log(msg)
    end
end

M.error_handler = function(process, error)
    if type(process) ~= "table" then
        process = { id = tostring(process) }
    end
    ocelot_log("An error occurred in process " .. tostring(process.id) .. ":\n" .. tostring(error))
    io.stderr:write("\n\n\n")
    io.stderr:write("An error occurred in process " .. tostring(process.id) .. ":\n")
    io.stderr:write(error)
    io.stderr:flush()
end

M.Process = {}
local Process = M.Process
local process_inc_id = 1

function Process:new(options)
    local obj = {
        status = "running",
        pull_timeout = 0,
        error = nil,
        id = process_inc_id,
        instances = patch.create_patch_instances(options),
        parent = M.current_process,
        main = nil,
        name = options.name or ("Process#" .. process_inc_id),
        error_handler = options.error_handler or M.error_handler,
    }
    local function main()
        local status, trace = xpcall(function(...)
                if obj.instances.event then
                    while obj.instances.computer._signal_queue_has_element() do
                        obj.instances.event.pull(0)
                    end
                    obj.instances.component._push_primaries()
                    while obj.instances.computer._signal_queue_has_element() do
                        obj.instances.event.pull(0)
                    end
                end
                if options.init then
                    options.main(options.init(self, ...))
                    return
                end
                options.main(...)
            end,
            debug.traceback,
            table.unpack(options.args or {}))
        if not status then
            obj.status = "error"
            obj.error = trace
            error()
        end
    end
    obj.main = process.load(main, nil, nil, obj.name)
    process_inc_id = process_inc_id + 1
    setmetatable(obj, self)
    self.__index = self

    table.insert(M.processes, obj)
    if obj.instances.event then
        obj.instances.component._push_components()
    end
    return obj
end

local resume = coroutine.resume
local uptime = computer.uptime
function Process:update()
    if self.status == "error" then
        return
    end
    for _, comp in pairs(self.instances.component._get_components()) do
        if type(comp) == "table" and comp._active then
            comp:_active()
        end
    end
    if coroutine.status(self.main) ~= "dead" then
        if self.pull_timeout < uptime() or self.instances.computer._signal_queue_has_element() then
            self.pull_timeout = 0
            self.status = "running"
            M.current_process = self
            for _, f in ipairs(self.instances.loads.load) do f(self) end
            local result = table.pack(xpcall(resume, debug.traceback, self.main))
            for _, f in ipairs(self.instances.loads.unload) do f(self) end
            M.current_process = nil
            if self.status == "dead" then
                return
            end
            if not table.remove(result, 1) then
                self.status = "error"
                self.error = "Resume error: " .. result[1]
            else
                local r, _, code, timeout = table.unpack(result)
                if not r and self.status == "running" then
                    self.status = "error"
                    self.error = "Coroutine error: " .. tostring(code)
                else
                    if code == "queue_empty" then
                        self.pull_timeout = timeout + uptime()
                        self.status = "waiting"
                    end
                end
            end
        end
    else
        if not self.instances.thread then
            self.status = "dead"
        elseif not self.instances.thread._has_alive() then
            self.status = "dead"
            self.instances.thread._kill_threads()
        end
    end
    self.instances.computer._reset_last_yield()
    if self.status == "error" then
        self.error_handler(self, self.error)
    end
end

function Process:kill()
    self.status = "dead"
    if self.instances.thread then
        self.instances.thread._kill_threads()
    end
end

function Process:remove()
    for i, process in ipairs(M.processes) do
        if process == self then
            table.remove(M.processes, i)
            break
        end
    end
    if self.status ~= "dead" and self.status ~= "error" then
        self:kill()
    end
    for _, comp in pairs(self.instances.component._get_components()) do
        if type(comp) == "table" and comp._remove then
            comp:_remove()
        end
    end
    if process.findProcess(self.main) then
        process.internal.close(self.main, 0)
    end
end

function Process:push_signal(name, source, ...)
    self.instances.component._handle_component_signal_1(name, source, ...)
    if self.instances.component._has_component(source) then
        self.instances.computer.pushSignal(name, source, ...)
    end
    self.instances.component._handle_component_signal_2(name, source, ...)
end

function M.create_process(options)
    return Process:new(options)
end

local process_index = 1
function M.next()
    if process_index > #M.processes then
        process_index = 1
    end
    local current_index = process_index
    process_index = process_index + 1
    local process = M.processes[current_index]
    if process.status == "dead" or process.status == "error" then
        process:remove()
    else
        process:update()
    end
end
function M.is_begin()
    return process_index == #M.processes
end

function M.push_signal(name, source, ...)
    if name == nil then return end
    for _, process in ipairs(M.processes) do
        process:push_signal(name, source, ...)
    end
end
function M.all_waiting()
    for _, process in ipairs(M.processes) do
        if process.status == "running" then
            return false
        end
    end
    return true
end
function M.is_empty()
    for _, process in ipairs(M.processes) do
        if process.status ~= "error" and process.status ~= "dead" then
            return false
        end
    end
    return true
end

patch.set_process(M)
return M
