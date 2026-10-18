-- munix line editor: the console's command line. One editor per
-- console (a session's terminal gets its own), so it keeps no state of
-- its own outside the object new() returns.
--
-- Keys, by OpenComputers key code:
--   Left/Right        move the cursor one character
--   Home/End, ^A/^E   to the start/end of the line
--   Up/Down           step through history (the line being typed is
--                     kept, and comes back past the newest entry)
--   Backspace/Delete  delete before/under the cursor
--   ^U / ^K           delete everything before/after the cursor
--   ^W                delete the word before the cursor
-- Pasting (OpenComputers' "clipboard" signal) inserts text at the
-- cursor; the console turns each newline in it into an Enter.
--
-- The line is kept as an array of characters (UTF-8 strings), so the
-- cursor counts characters, never bytes.
local KEY = {LEFT = 0xCB, RIGHT = 0xCD, UP = 0xC8, DOWN = 0xD0, HOME = 0xC7, END = 0xCF,
  BACK = 0x0E, DELETE = 0xD3, ENTER = 0x1C}
local CTRL = {A = 1, E = 5, K = 11, U = 21, W = 23}
local HISTORY_MAX = 100

local function chars(text)
  local out = {}
  if utf8.len(text) then
    for _, c in utf8.codes(text) do out[#out + 1] = utf8.char(c) end
  else
    for i = 1, #text do out[i] = text:sub(i, i) end
  end
  return out
end

local Editor = {}
Editor.__index = Editor

-- The line as a string.
function Editor:text() return table.concat(self.line) end

-- Characters before the cursor (0 = at the start).
function Editor:cursor() return self.pos end

function Editor:set(text)
  self.line = chars(text)
  self.pos = #self.line
end

-- Inserts text (no newlines) at the cursor.
function Editor:insert(text)
  for _, c in ipairs(chars(text)) do
    table.insert(self.line, self.pos + 1, c)
    self.pos = self.pos + 1
  end
end

local function cut(self, from, to) -- deletes characters from..to (1-based, inclusive)
  for _ = from, to do table.remove(self.line, from) end
  if self.pos >= to then
    self.pos = self.pos - (to - from + 1)
  elseif self.pos >= from then
    self.pos = from - 1
  end
end

local function recall(self, index)
  if index == #self.history + 1 then
    self:set(self.draft or "")
    self.draft = nil
  else
    if self.browse == #self.history + 1 then self.draft = self:text() end
    self:set(self.history[index])
  end
  self.browse = index
end

-- Handles one key. Returns the finished line on Enter (and adds it to
-- the history), true if the line or cursor changed, or nil if the key
-- means nothing to the editor.
function Editor:key(char, code)
  local n = #self.line
  if code == KEY.ENTER then
    local line = self:text()
    if line:find("%S") and self.history[#self.history] ~= line then
      self.history[#self.history + 1] = line
      if #self.history > HISTORY_MAX then table.remove(self.history, 1) end
    end
    self.line, self.pos, self.draft = {}, 0, nil
    self.browse = #self.history + 1
    return line
  elseif code == KEY.LEFT then
    if self.pos == 0 then return nil end
    self.pos = self.pos - 1
  elseif code == KEY.RIGHT then
    if self.pos == n then return nil end
    self.pos = self.pos + 1
  elseif code == KEY.HOME or char == CTRL.A then
    self.pos = 0
  elseif code == KEY.END or char == CTRL.E then
    self.pos = n
  elseif code == KEY.UP then
    if self.browse <= 1 then return nil end
    recall(self, self.browse - 1)
  elseif code == KEY.DOWN then
    if self.browse > #self.history then return nil end
    recall(self, self.browse + 1)
  elseif code == KEY.BACK then
    if self.pos == 0 then return nil end
    cut(self, self.pos, self.pos)
  elseif code == KEY.DELETE then
    if self.pos == n then return nil end
    cut(self, self.pos + 1, self.pos + 1)
  elseif char == CTRL.U then
    if self.pos == 0 then return nil end
    cut(self, 1, self.pos)
  elseif char == CTRL.K then
    if self.pos == n then return nil end
    cut(self, self.pos + 1, n)
  elseif char == CTRL.W then
    local from = self.pos
    while from > 0 and self.line[from]:find("^%s$") do from = from - 1 end
    while from > 0 and not self.line[from]:find("^%s$") do from = from - 1 end
    if from == self.pos then return nil end
    cut(self, from + 1, self.pos)
  elseif char and char >= 32 then
    local ok, c = pcall(utf8.char, char)
    if not ok then return nil end
    self:insert(c)
  else
    return nil
  end
  return true
end

return {
  new = function()
    return setmetatable({line = {}, pos = 0, history = {}, browse = 1}, Editor)
  end,
  KEY = KEY,
}
