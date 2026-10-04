local component = require("component")
local _fs = require("filesystem")

return function(options)
    local id = options.id or "filesystem"
    while #id < 12 do id = id .. "0" end
    local filesystem = {
        type = "filesystem",
        address = "virtual0-"..id:sub(0, 4).."-"..id:sub(5, 8).."-"..id:sub(9, 12).."-component000",
    }
    local fs = options.filesystem or component.proxy(component.tmpAddress())
    local base_path = options.path or "/"
    local label = options.label or options.id or "filesystem"
    local readonly = options.readonly or fs.isReadOnly()

    if not fs.exists(base_path) then
        fs.makeDirectory(base_path)
    end

    local handles = {}

    function filesystem.spaceUsed()
        return fs.spaceUsed()
    end
    local function wrap(path)
        path = _fs.concat(base_path, path)
        path = _fs.canonical(path)
        if path:sub(1, #base_path) ~= base_path then
            return
        end
        return path
    end
    function filesystem.open(path, mode)
        if readonly and mode:match("w") then
            return
        end
        local handle, err = fs.open(wrap(path), mode)
        if not handle then
            return handle, err
        end
        handles[handle] = {
            path = path,
            mode = mode,
        }
        return handle
    end
    function filesystem.seek(handle, whence, offset)
        if not handles[handle] then
            return
        end
        return fs.seek(handle, whence, offset)
    end
    function filesystem.makeDirectory(path)
        if readonly then
            return
        end
        return fs.makeDirectory(wrap(path))
    end
    function filesystem.exists(path)
        return fs.exists(wrap(path))
    end
    function filesystem.isReadOnly()
        return readonly
    end
    function filesystem.write(handle, value)
        if not handles[handle] then
            return
        end
        if readonly then
            return
        end
        return fs.write(handle, value)
    end
    function filesystem.spaceTotal()
        return fs.spaceTotal()
    end
    function filesystem.isDirectory(path)
        return fs.isDirectory(wrap(path))
    end
    function filesystem.rename(from, to)
        if readonly then
            return
        end
        return fs.rename(wrap(from), wrap(to))
    end
    function filesystem.list(path)
        return fs.list(wrap(path))
    end
    function filesystem.lastModified(path)
        return fs.lastModified(wrap(path))
    end
    function filesystem.getLabel()
        return label
    end
    function filesystem.remove(path)
        if readonly then
            return
        end
        return fs.remove(wrap(path))
    end
    function filesystem.close(handle)
        if not handles[handle] then
            return
        end
        handles[handle] = nil
        return fs.close(handle)
    end
    function filesystem.size(path)
        return fs.size(wrap(path))
    end
    function filesystem.read(handle, count)
        if not handles[handle] then
            return
        end
        return fs.read(handle, count)
    end
    function filesystem.setLabel(value)
        label = value
    end

    function filesystem._remove()
        for handle, _ in pairs(handles) do
            fs.close(handle)
        end
        handles = {}
    end

    return filesystem
end
