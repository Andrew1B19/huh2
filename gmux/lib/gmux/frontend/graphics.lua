local math = require("math")

local M = {}

M.gpu = nil

local debug = false
local debug_screen = false

M.blocks = {} -- top -------> bottom

-- 检测两个矩形是否重叠
local function rectangles_overlap(rect1, rect2)
    return not (rect1.x >= rect2.x + rect2.w or
                rect1.x + rect1.w <= rect2.x or
                rect1.y >= rect2.y + rect2.h or
                rect1.y + rect1.h <= rect2.y)
end

-- 矩形减法：从rect中减去blocker重叠部分，返回切割后的矩形数组
local function subtract_rectangle(rect, blocker)
    if not rectangles_overlap(rect, blocker) then
        return {rect}  -- 无重叠，返回原矩形
    end
    
    local result = {}
    
    -- 左侧矩形 (如果存在)
    if rect.x < blocker.x then
        local left = {
            x = rect.x,
            y = rect.y,
            w = blocker.x - rect.x,
            h = rect.h
        }
        if left.w > 0 then
            result[#result + 1] = left
        end
    end
    
    -- 右侧矩形 (如果存在)
    if rect.x + rect.w > blocker.x + blocker.w then
        local right = {
            x = blocker.x + blocker.w,
            y = rect.y,
            w = rect.x + rect.w - (blocker.x + blocker.w),
            h = rect.h
        }
        if right.w > 0 then
            result[#result + 1] = right
        end
    end
    
    -- 上侧矩形 (如果存在)
    if rect.y < blocker.y then
        local overlap_left = math.max(rect.x, blocker.x)
        local overlap_right = math.min(rect.x + rect.w, blocker.x + blocker.w)
        if overlap_right > overlap_left then
            local top = {
                x = overlap_left,
                y = rect.y,
                w = overlap_right - overlap_left,
                h = blocker.y - rect.y
            }
            if top.h > 0 then
                result[#result + 1] = top
            end
        end
    end
    
    -- 下侧矩形 (如果存在)
    if rect.y + rect.h > blocker.y + blocker.h then
        local overlap_left = math.max(rect.x, blocker.x)
        local overlap_right = math.min(rect.x + rect.w, blocker.x + blocker.w)
        if overlap_right > overlap_left then
            local bottom = {
                x = overlap_left,
                y = blocker.y + blocker.h,
                w = overlap_right - overlap_left,
                h = rect.y + rect.h - (blocker.y + blocker.h)
            }
            if bottom.h > 0 then
                result[#result + 1] = bottom
            end
        end
    end
    
    return result
end

--[[
    Source:\
        copy(dst_col, dst_row, src_col, src_row, w, h)
        need_copy()
        size(): {w, h}
        set_size?(w, h)
]]

function M.buffer_source(gpu, buffer, once_copy)
    local copied = false
    return {
        copy = function(dst_col, dst_row, src_col, src_row, w, h)
            gpu.bitblt(0, dst_col, dst_row, w, h, buffer, src_col, src_row)
        end,
        need_copy = function()
            if once_copy then
                return not copied
            end
            return true
        end,
        size = function()
            return gpu.getBufferSize(buffer)
        end,
        after_copy = function()
            copied = true
        end
    }
end
function M.vgpu_source(vgpu, vscreen)
    local source = {
        copy = function(dst_col, dst_row, src_col, src_row, w, h)
            vgpu._copy_to_screen(dst_col, dst_row, src_col, src_row, w, h)
        end,
        need_copy = function()
            return vgpu._is_dirty()
        end,
        size = function()
            return vgpu.getViewport()
        end,
        set_size = function(w, h)
            vgpu.setResolution(w, h)
            vscreen.pushSignal("screen_resized", w, h)
        end
    }
    table.insert(vgpu.on_set_resolution, function(w, h)
        if source.on_set_size then
            source.on_set_size()
        end
    end)
    return source
end
function M.empty_source()
    return {
        copy = function() end,
        need_copy = function() return false end,
        size = function() return 20, 10 end,
    }
end

local function layer_begin(layer)
    for i = 1, #M.blocks do
        if M.blocks[i].layer <= layer then
            return i
        end
    end
    return #M.blocks + 1
end

local Block = {}
function Block:new(options)
    local obj = {
        x = options.x or 1,
        y = options.y or 1,
        shown = true,
        source = options.source,
        block_changed = false,
        layer = options.layer or 0,
        find_block = options.find_block == nil or options.find_block,
        event_handler = options.event_handler or nil,
    }
    setmetatable(obj, self)
    self.__index = self
    table.insert(M.blocks, layer_begin(obj.layer), obj)
    return obj
end

function Block:index()
    for i = 1, #M.blocks do
        if M.blocks[i] == self then
            return i
        end
    end
    return nil
end

function Block:as_top()
    local index = self:index()
    if index then
        table.remove(M.blocks, index)
        table.insert(M.blocks, layer_begin(self.layer), self)
    end
    self.block_changed = true
end

function Block:set_position(x, y)
    self.x = x
    self.y = y
    self.block_changed = true
end
function Block:set_size(w, h)
    self.source.set_size(w, h)
    self.block_changed = true
end

function Block:position()
    return self.x, self.y
end
function Block:size()
    local w, h = self.source.size()
    return w or 1, h or 1
end
function Block:contains(x, y)
    local bx, by = self:position()
    local bw, bh = self:size()
    return x >= bx and x < bx + bw and y >= by and y < by + bh
end

function Block:get_boxes()
    local w, h = self.source.size()
    local current = {
        {x = self.x, y = self.y, w = w, h = h},
    }
    
    -- 遍历所有在当前块之上的块（层级更高的块）
    for i = 1, self:index() - 1 do
        if not M.blocks[i].shown then
            goto continue
        end
        local block = M.blocks[i]
        local bx, by = block:position()
        local bw, bh = block:size()
        local blocker = {x = bx, y = by, w = bw, h = bh}
        
        local new_current = {}
        -- 对当前所有可见矩形应用遮挡块的切割
        for _, box in ipairs(current) do
            local cut_boxes = subtract_rectangle(box, blocker)
            for _, cut_box in ipairs(cut_boxes) do
                new_current[#new_current + 1] = cut_box
            end
        end
        current = new_current
        ::continue::
    end
    
    return current
end
function Block:show(shown)
    self.shown = (shown == nil and not self.shown) or shown
    self.block_changed = true
end
function Block:draw()
    if not self.shown then
        return
    end
    local boxes = nil;
    if self.source.need_copy() or self.block_changed then
        boxes = self:get_boxes()
        for i, box in ipairs(boxes) do
            self.source.copy(box.x, box.y, box.x - self.x + 1, box.y - self.y + 1, box.w, box.h)
        end
        if self.source.after_copy then
            self.source.after_copy()
        end
        self.block_changed = false
    end
    boxes = boxes or debug and self:get_boxes() or nil
    if debug and boxes then
        for i, box in ipairs(boxes) do
            M.gpu.setActiveBuffer(0)
            M.gpu.setBackground(0xffffff)
            M.gpu.setForeground(0x000000)
            M.gpu.set(box.x+1, box.y, ("-"):rep(box.w-2))
            M.gpu.set(box.x+1, box.y+box.h-1, ("-"):rep(box.w-2))
            M.gpu.set(box.x, box.y+1, ("|"):rep(box.h-2), true)
            M.gpu.set(box.x+box.w-1, box.y+1, ("|"):rep(box.h-2), true)
            M.gpu.set(box.x, box.y, "x")
            M.gpu.set(box.x+2, box.y, string.format("Block[%d] Box[%d]: x=%d y=%d w=%d h=%d", self:index(), i, box.x, box.y, box.w, box.h))
            M.gpu.set(box.x + box.w - 1, box.y, "x")
            M.gpu.set(box.x, box.y + box.h - 1, "x")
            M.gpu.set(box.x + box.w - 1, box.y + box.h - 1, "x")
        end
    end
end

function Block:remove()
    table.remove(M.blocks, self:index())
end

function M.find_block(x, y)
    for _, block in ipairs(M.blocks) do
        if block.shown and block.find_block and block:contains(x, y) then
            return block
        end
    end
end

M.Block = Block

function M.draw()
    local gpu = M.gpu
    if debug_screen then
        -- 显示调试信息
        gpu.setActiveBuffer(0)
        local w, h = gpu.getResolution()
        gpu.setBackground(0x444400)
        gpu.fill(1, 1, w, h, ' ')
        gpu.setBackground(0x000000)
        gpu.setForeground(0xffffff)
        gpu.set(1, 1, "Graphics Debug")
        local y = 2
        gpu.set(1, y, "Blocks: " .. tostring(#M.blocks))
        y = y + 1
        for i, block in ipairs(M.blocks) do
            local bx, by = block:position()
            local bw, bh = block:size()
            local info = string.format("Block[%d]: x=%d y=%d w=%d h=%d shown=%s need_copy=%s", i, bx, by, bw, bh,
                tostring(block.shown), tostring(block.source.need_copy()))
            gpu.set(1, y, info)
            y = y + 1
            -- 显示每个 block 的 boxes 信息
            if block.get_boxes then
                local boxes = block:get_boxes()
                for j, box in ipairs(boxes) do
                    local box_info = string.format(
                        "  Box[%d]: x=%d y=%d local_x=%d local_y=%d w=%d h=%d",
                        j, box.x, box.y, box.x - block.x + 1, box.y - block.y + 1, box.w, box.h
                    )
                    gpu.set(1, y, box_info)
                    y = y + 1
                end
            end
        end
    end
    for _, block in ipairs(M.blocks) do
        block:draw()
    end
end

function M.clear()
    for _, block in ipairs(M.blocks) do
        block:remove()
    end
end

return M