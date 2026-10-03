-- smux wire framing (SMX1): chunked string frames for GERTi transport.
--
-- Follows the same pattern as rshell/docs/spec.md section 3: every message is ONE string
-- (GERTi drops tables, has no fragmentation, receive buffer ~21 items per socket), with a
-- header line carrying type/seq/token-length/body-length and optional chunk position, then
-- token+body bytes after the newline. Chunk bodies are capped so each frame stays well under
-- 6000 chars (GERTi's practical message limit).
--
-- Auth model (same as rshell): there is NO separate session-id handshake - every frame carries
-- the shared server secret in its `token` field, compared constant-time by smux/session.lua.
-- AUTH is just a cheap "hello" whose body is empty and whose reply confirms connectivity; it
-- uses exactly the same credential as ATTACH/INPUT/etc.
--
-- Pure module: no os/io/computer/event/component; runs under plain lua5.3 and OpenComputers.

local M = {}
M.VERSION = "1.0.0"

-- Magic prefix distinguishes smux frames from other protocols on the same socket.
M.MAGIC = "SMX1"

-- Maximum body bytes per chunk frame (keeps total frame under ~6000 chars including header).
M.MAX_BODY = 5000

-- Frame types:
--   AUTH    token=secret, body=""              -> ACK (connectivity check) | DENY
--   ATTACH  token=secret, body=job_id          -> ACK | DENY (attach to a job's console)
--   INPUT   token=secret, body=text             -> ACK (feed input to the attached job)
--   DETACH  token=secret, body=""              -> ACK (detach from the job)
--   BYE     token=secret, body=""              -> ACK (end session; server forgets peer state)
--   OUTPUT  token="",     body=output chunk    (server -> client push of captured job output)
--   ACK     server reply: request accepted / connectivity confirmed (body empty)
--   DENY    server reply: bad secret, unknown job, or not-attached (body empty; no detail leaked)
M.TYPES = { AUTH = true, ATTACH = true, INPUT = true, DETACH = true, BYE = true, OUTPUT = true, ACK = true, DENY = true }

------------------------------------------------------------------- encode --

local function is_str(v) return type(v) == "string" end
local function is_int(v) return math.type(v) == "integer" and v >= 0 end

-- encode(type, seq, token, body, part, parts) -> string (one GERTi-safe frame)
--   type:    one of M.TYPES keys
--   seq:     integer >= 0 (client-chosen; echoed in ACK/DENY responses)
--   token:   the shared secret ("" for OUTPUT frames pushed by the server)
--   body:    payload string (may contain newlines/any byte; length is authoritative)
--   part/parts: 1-based chunk position and total count (both nil or both set)
function M.encode(type, seq, token, body, part, parts)
    if not M.TYPES[type] then error("framing: unknown type " .. tostring(type)) end
    if not is_int(seq) then error("framing: seq must be integer >= 0") end
    token = token or ""
    body = body or ""
    if not is_str(token) then error("framing: token must be string") end
    if not is_str(body) then error("framing: body must be string") end

    local header = M.MAGIC .. " " .. type .. " " .. seq .. " " .. #token .. " " .. #body
    if part ~= nil or parts ~= nil then
        if not (is_int(part) and is_int(parts) and part >= 1 and parts >= part) then
            error("framing: bad chunk position")
        end
        header = header .. " " .. part .. " " .. parts
    end

    return header .. "\n" .. token .. body
end

------------------------------------------------------------------- decode --

-- decode(frame_string) -> {type, seq, token, body, part, parts} | nil, errstring
-- Never raises; malformed input yields nil + reason.
function M.decode(s)
    if type(s) ~= "string" then return nil, "not a string" end

    -- Parse header: SMX1 <type> <seq> <tlen> <blen> [<part> <parts>]
    local ok = s:find(M.MAGIC .. " ", 1, true) == 1
    if not ok then return nil, "bad magic" end

    -- Extract the header line (up to first newline).
    local nl = s:find("\n")
    if not nl then return nil, "missing newline separator" end
    local header_line = s:sub(1, nl - 1)

    -- Tokenize header.
    local fields = {}
    for f in string.gmatch(header_line, "%S+") do
        table.insert(fields, f)
    end
    -- Minimum: MAGIC type seq tlen blen (5 fields). With chunking: +2 more (7 total).
    if #fields < 5 or #fields > 7 then return nil, "bad field count" end

    local typ = fields[2]
    if not M.TYPES[typ] then return nil, "unknown type " .. tostring(typ) end

    local seq = tonumber(fields[3])
    if math.type(seq) ~= "integer" or seq < 0 then return nil, "bad seq" end

    local tlen = tonumber(fields[4])
    if math.type(tlen) ~= "integer" or tlen < 0 then return nil, "bad token length" end

    local blen = tonumber(fields[5])
    if math.type(blen) ~= "integer" or blen < 0 then return nil, "bad body length" end

    local part, parts
    if #fields == 7 then
        part = tonumber(fields[6])
        parts = tonumber(fields[7])
        if not (math.type(part) == "integer" and math.type(parts) == "integer") then
            return nil, "bad chunk fields"
        end
        if part < 1 or parts < part then return nil, "bad chunk position" end
    end

    -- Payload starts right after the newline.
    local payload = s:sub(nl + 1)
    if #payload < tlen + blen then return nil, "truncated payload" end

    local token = payload:sub(1, tlen)
    local body = payload:sub(tlen + 1, tlen + blen)

    local frame = { type = typ, seq = seq, token = token, body = body }
    if part ~= nil then frame.part = part; frame.parts = parts end
    return frame
end

------------------------------------------------------------------- chunking --

-- split_body(body, max_chunk) -> list of strings (each <= max_chunk bytes)
function M.split_body(body, max_chunk)
    max_chunk = max_chunk or M.MAX_BODY
    if #body == 0 then return {} end
    local chunks = {}
    for i = 1, #body, max_chunk do
        table.insert(chunks, body:sub(i, i + max_chunk - 1))
    end
    return chunks
end

-- join_chunks(chunks) -> single string (inverse of split_body)
function M.join_chunks(chunks)
    return table.concat(chunks)
end

return M
