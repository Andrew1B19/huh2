local math = require("math")
local vgpu_callbacks = {}
return function(options)
    if options == nil then
        options = {}
    end
    local real = options.gpu
    real.setActiveBuffer(0)
    local real_width, real_height = real.getResolution()
    local keep = real_width * 1

    local width = options.width or 30
    local height = options.height or 19
    if width * height > real.freeMemory() then
        height = math.floor((real.freeMemory() - keep) / width)
    end
    local viewportWidth = width
    local viewportHeight = height
    local screenBuffer = real.allocateBuffer(width, height)
    local buffers = {}
    local activeBuffer = screenBuffer
    local background = 0x000000
    local foreground = 0xffffff
    local dirty = false

    local function freeBuffer(index)
        return real.freeBuffer(index)
    end
    local callback = function(index)
        if screenBuffer >= index then screenBuffer = screenBuffer - 1 end
        for i, a in ipairs(buffers) do 
            if a >= index then buffers[i] = a - 1 end
        end
    end
    vgpu_callbacks[#vgpu_callbacks+1] = callback

    local function applyState()
        real.setActiveBuffer(activeBuffer)
        real.setBackground(background)
        real.setForeground(foreground)
    end

    local gpu = {
        type = "gpu",
        address = options.address or "virtual0-gpu0-0000-0000-component000",
        on_set_resolution = {}
    }
    local vscreen = ""
    function gpu.bind(address)
        vscreen = address
    end
    function gpu.getScreen()
        return vscreen
    end
    function gpu.getBackground()
        return background, false
    end
    function gpu.setBackground(color)
        local last = background
        background = color
        return last, nil
    end
    function gpu.getForeground()
        return foreground, false
    end
    function gpu.setForeground(color)
        local last = foreground
        foreground = color
        return last, nil
    end
    gpu.getPaletteColor = real.getPaletteColor
    gpu.setPaletteColor = real.setPaletteColor
    gpu.maxDepth = real.maxDepth
    gpu.getDepth = real.getDepth
    function gpu.setDepth(depth)
        return real.setDepth(depth)
    end
    
    gpu.maxResolution = real.maxResolution
    function gpu.getResolution()
        return width, height
    end
    function gpu.setResolution(w, h)
        local oldBuffer = screenBuffer
        if w * h <= real.freeMemory() - keep then
            screenBuffer = real.allocateBuffer(w, h)
            real.bitblt(screenBuffer, 0, 0, math.min(width, w), math.min(height, h), oldBuffer, 0, 0)
            freeBuffer(oldBuffer)
        elseif w * h <= real.freeMemory() + width * height - keep then
            freeBuffer(oldBuffer)
            screenBuffer = real.allocateBuffer(w, h)
        else
            freeBuffer(oldBuffer)
            h = math.floor((real.freeMemory() - keep) / w)
            screenBuffer = real.allocateBuffer(w, h)
        end
        if activeBuffer == oldBuffer then activeBuffer = screenBuffer end
        width = w
        height = h
        viewportWidth = width
        viewportHeight = height
        for _, func in ipairs(gpu.on_set_resolution) do
            func(w, h)
        end
    end
    function gpu.getViewport()
        return viewportWidth, viewportHeight
    end
    function gpu.setViewport(w, h)
        if w > width or h > height then
            return false
        end
        viewportWidth = w
        viewportHeight = h
        return true
    end

    function gpu.get(x, y)
        real.setActiveBuffer(activeBuffer)
        return real.get(x, y)
    end
    function gpu.set(x, y, ...)
        applyState()
        real.set(x, y, ...)
        dirty = true
    end
    function gpu.copy(...)
        real.setActiveBuffer(activeBuffer)
        dirty = true
        return real.copy(...)
    end
    function gpu.fill(...)
        applyState()
        real.fill(...)
        dirty = true
    end

    function gpu.getActiveBuffer()
        if activeBuffer == screenBuffer then
            return 0
        end
        return activeBuffer
    end
    function gpu.setActiveBuffer(buffer)
        local old = gpu.getActiveBuffer()
        if buffer == 0 or buffer == nil then
            activeBuffer = screenBuffer
        else
            activeBuffer = buffer
        end
        local found = false
        for _, i in ipairs(buffers) do
            if i == activeBuffer then
                found = true
                break
            end
        end
        if not found then
            return old
        end
        real.setActiveBuffer(activeBuffer)
        return old
    end
    function gpu.buffers()
        return buffers
    end
    function gpu.allocateBuffer(w, h)
        local buffer = real.allocateBuffer(w, h)
        buffers[#buffers + 1] = buffer
        return buffer
    end
    function gpu.freeBuffer(buffer)
        if buffer == 0 then
            return
        end
        for i = #buffers, 1, -1 do
            if buffers[i] == buffer then
                table.remove(buffers, i)
                break
            end
        end
        return freeBuffer(buffer)
    end
    function gpu.freeAllBuffers()
        for _, buffer in ipairs(buffers) do
            freeBuffer(buffer)
        end
        buffers = {}
    end
    gpu.totalMemory = real.totalMemory
    gpu.freeMemory = real.freeMemory
    function gpu.getBufferSize(buffer)
        if buffer == 0 then buffer = screenBuffer end
        return real.getBufferSize(buffer)
    end
    function gpu.bitblt(dst, col, row, w, h, src, fromCol, fromRow)
        if dst == 0 then dst = screenBuffer end
        if src == 0 then src = screenBuffer end
        dirty = true
        return real.bitblt(dst, col, row, w, h, src, fromCol, fromRow)
    end

    function gpu._copy_to_screen(col, row, x, y, w, h)
        real.bitblt(0, col, row, w, h, screenBuffer, x, y)
        dirty = false
    end
    function gpu._is_dirty()
        return dirty
    end
    function gpu._remove()
        freeBuffer(screenBuffer)
        for _, buffer in ipairs(buffers) do
            freeBuffer(buffer)
        end
        for i, cb in ipairs(vgpu_callbacks) do
            if cb == gpu then
                table.remove(vgpu_callbacks, i)
                break
            end
        end
    end
    function gpu._active()
        if activeBuffer == nil then return end
        real.setActiveBuffer(activeBuffer)
    end

    function gpu.pushSignal(...) end
    return gpu
end
