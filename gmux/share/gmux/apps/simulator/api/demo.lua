local computer = require("computer")
local M = {}

function M.beep()
    computer.beep(0.05)
end

return M