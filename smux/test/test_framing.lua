-- Tests for smux/framing.lua (SMX1 wire codec). Run: cd smux && lua5.3 test/test_framing.lua
package.path = "./?.lua;../nodelib/?.lua;../hmi/?.lua;" .. package.path

local framing = require("smux/framing")

local passed = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error("FAIL " .. name .. ": " .. tostring(err), 0) end
    passed = passed + 1
    print("PASS " .. name)
end

test("encode/decode round-trips a simple AUTH frame", function()
    local f = framing.encode("AUTH", 7, "secret", "")
    local d = framing.decode(f)
    assert(d.type == "AUTH")
    assert(d.seq == 7)
    assert(d.token == "secret")
    assert(d.body == "")
end)

test("encode/decode round-trips a body containing newlines and spaces", function()
    local body = "line1\nline2 with spaces\tand tabs"
    local f = framing.encode("INPUT", 3, "tok", body)
    local d = framing.decode(f)
    assert(d.body == body, "body mismatch: got [" .. tostring(d.body) .. "]")
end)

test("decode rejects bad magic", function()
    local _, err = framing.decode("RSH1 AUTH 0 0 0\n")
    assert(err ~= nil)
end)

test("decode rejects unknown type", function()
    local _, err = framing.decode("SMX1 FOO 0 0 0\n")
    assert(err ~= nil)
end)

test("decode rejects truncated payload", function()
    -- Header claims tlen=5, blen=3 but only provides 2 bytes after newline.
    local _, err = framing.decode("SMX1 AUTH 0 5 3\nab")
    assert(err ~= nil)
end)

test("decode rejects non-integer seq", function()
    local _, err = framing.decode("SMX1 AUTH x 0 0\n")
    assert(err ~= nil)
end)

test("chunked encode/decode round-trips with part/parts", function()
    local f = framing.encode("OUTPUT", 0, "", "hello", 2, 3)
    local d = framing.decode(f)
    assert(d.part == 2 and d.parts == 3)
end)

test("split_body splits a long body into MAX_BODY-sized chunks", function()
    local body = string.rep("a", 12000)
    local chunks = framing.split_body(body, 5000)
    assert(#chunks == 3)
    assert(#chunks[1] == 5000)
    assert(#chunks[2] == 5000)
    assert(#chunks[3] == 2000)
    -- Reassembly is lossless.
    assert(framing.join_chunks(chunks) == body)
end)

test("split_body of empty string returns empty list", function()
    local chunks = framing.split_body("")
    assert(#chunks == 0)
end)

print(string.format("ALL %d FRAMING TESTS PASSED", passed))
