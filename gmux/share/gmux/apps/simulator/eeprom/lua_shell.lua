---@diagnostic disable: undefined-global
local gpu = component.proxy(component.list("gpu")())
local screen = component.list("screen")()

gpu.bind(screen)

local w, h = gpu.getResolution()
gpu.setForeground(0xffffff)
gpu.setBackground(0x000000)
gpu.fill(1, 1, w, h, " ")

local cursor_x, cursor_y = 1, 1
local function write(str)
    for i = 1, #str, 1 do
        local char = str:sub(i, i)
        if char == "\n" or cursor_x > w then
            cursor_x = 1
            cursor_y = cursor_y + 1
            if cursor_y > h then
                gpu.copy(1, 2, w, h - 1, 1, 1)
                gpu.fill(1, h, w, 1, " ")
                cursor_y = h
            end
        end
        if char ~= "\n" then
            gpu.set(cursor_x, cursor_y, char)
            cursor_x = cursor_x + 1
        end
    end
end

write("Lua Shell: " .. _VERSION .. "\n")

local function read()
    local line = ""
    local cursor = 1
    local cursor_begin_x = cursor_x - 1
    local cursor_begin_y = cursor_y
    local function show_cursor(clear)
        local old_char = gpu.get(cursor_x, cursor_y)
        gpu.set(cursor_x, cursor_y, old_char)
        if clear then
            return
        end
        cursor_x = (cursor_begin_x + cursor - 1) % w + 1
        cursor_y = cursor_begin_y + math.floor((cursor_begin_x + cursor - 1) / w)
        if cursor_y > h then
            gpu.copy(1, 2, w, h - 1, 1, 1)
            gpu.fill(1, h, w, 1, " ")
            cursor_y = h
            cursor_begin_y = cursor_begin_y - 1
        end
        gpu.setBackground(0xffffff)
        gpu.setForeground(0x000000)
        local char = line:sub(cursor, cursor)
        if char == "" then char = " " end
        gpu.set(cursor_x, cursor_y, char)
        gpu.setBackground(0x000000)
        gpu.setForeground(0xffffff)
    end
    local function show_line()
        for i = 1, #line, 1 do
            local char = line:sub(i, i)
            local x = (cursor_begin_x + i - 1) % w + 1
            local y = cursor_begin_y + math.floor((cursor_begin_x + i - 1) / w)
            gpu.set(x, y, char)
            if x + 1 <= w then
                gpu.set(x + 1, y, " ")
            end
        end
    end
    while true do
        show_line()
        show_cursor()
        local type, _, key, code = computer.pullSignal()
        if type == "key_down" then
            if code == 14 then -- backspace
                if cursor > 1 then
                    line = line:sub(1, cursor - 2) .. line:sub(cursor, #line)
                    cursor = cursor - 1
                end
            elseif code == 28 then -- enter
                show_cursor(true)
                write("\n")
                return line
            elseif code == 203 then -- left
                if cursor > 1 then
                    cursor = cursor - 1
                end
            elseif code == 205 then -- right
                if cursor <= #line then
                    cursor = cursor + 1
                end
            elseif key ~= 0 then
                key = unicode.char(key)
                line = line:sub(1, cursor - 1) .. key .. line:sub(cursor, #line)
                cursor = cursor + 1
            end
        end
    end
end

_G.lua_shell = {
    read = read,
    write = write,
}

while true do
    write("lua> ")
    local line = read()
    local eval = line:sub(1, 1) == "="
    if eval then
        line = "return " .. line:sub(2)
    end
    local func, err = load(line, "=stdin", "t", _G)
    if err then
        write(err .. "\n")
    else
        local ok, result = xpcall(func, debug.traceback)
        if not ok then
            write(result + "\n")
        end
        if eval then
            write(tostring(result) .. "\n")
        end
    end
end