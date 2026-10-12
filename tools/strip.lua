-- Strips a Lua source file down for shipping: comments and indentation
-- go, everything else stays -- including every line break, so an error
-- message's line number still points at the same line of the repo's
-- file. Strings (short and long) are kept exactly. A `--[[mxe` header
-- (an .mxe program's manifest, read as text) is kept too.
--
--   local strip = dofile("tools/strip.lua")
--   local shipped = strip(source)
--
-- It follows Lua's own lexer rules for where strings and comments
-- start and end, so it can't change what the code means; tools/build.lua
-- still checks that each stripped file compiles.

-- The level of a long bracket opening at `i` ("[[" is 0, "[==[" is 2),
-- or nil.
local function longBracket(src, i)
  local eq = src:match("^%[(=*)%[", i)
  return eq and #eq
end

-- Drops whitespace at the end of what's been written so far (never from
-- inside a string: a string's piece ends with its closing quote).
local function trim(out)
  while #out > 0 do
    local t = out[#out]:gsub("[ \t]+$", "")
    if t ~= "" or out[#out] == "" then out[#out] = t break end
    out[#out] = nil
  end
end

return function(src)
  local out = {}
  local i, n = 1, #src
  local lineStart = true
  while i <= n do
    local c = src:sub(i, i)
    if lineStart and (c == " " or c == "\t") then
      i = i + 1 -- indentation
    elseif c == "\n" then
      trim(out) -- trailing whitespace before a line break
      out[#out + 1] = "\n"
      lineStart = true
      i = i + 1
    elseif c == "-" and src:sub(i + 1, i + 1) == "-" then
      lineStart = false
      local level = longBracket(src, i + 2)
      if level then
        local close = "]" .. ("="):rep(level) .. "]"
        local e = src:find(close, i, true)
        local stop = e and (e + #close - 1) or n
        local text = src:sub(i, stop)
        if text:match("^%-%-%[%[mxe") then
          out[#out + 1] = text -- an .mxe manifest
        else
          out[#out + 1] = (text:gsub("[^\n]", "")) -- only its line breaks
        end
        i = stop + 1
      else
        local e = src:find("\n", i, true)
        i = e or (n + 1)
      end
    elseif c == "\"" or c == "'" then
      lineStart = false
      local j = i + 1
      while j <= n do
        local d = src:sub(j, j)
        if d == "\\" then
          j = j + 2
        elseif d == c or d == "\n" then
          break
        else
          j = j + 1
        end
      end
      out[#out + 1] = src:sub(i, j)
      i = j + 1
    elseif c == "[" and longBracket(src, i) then
      lineStart = false
      local close = "]" .. ("="):rep(longBracket(src, i)) .. "]"
      local e = src:find(close, i, true)
      local stop = e and (e + #close - 1) or n
      out[#out + 1] = src:sub(i, stop)
      i = stop + 1
    else
      lineStart = false
      -- Plain code up to the next character that might start something.
      local j = src:find("[\n\"'%-%[]", i + 1) or (n + 1)
      out[#out + 1] = src:sub(i, j - 1)
      i = j
    end
  end
  trim(out)
  return table.concat(out)
end
