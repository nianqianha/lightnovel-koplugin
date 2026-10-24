--[[--
MD5 helper for cache keys.

KOReader ships an MD5 implementation in PureCrypto, but requiring it pulls in
more of the crypto stack than this plugin needs, and the fallback keeps the
module usable in the offline test harness. A book key only needs a stable,
collision-resistant-enough name, so MD5 is adequate.
--]]--

local Digest = {}

-- Try KOReader's own MD5 first; it is the fastest path on device.
local function ko_md5(text)
    local ok, crypto = pcall(require, "crypto")
    if ok and crypto and type(crypto.md5) == "function" then
        local ok_sum, sum = pcall(crypto.md5, text)
        if ok_sum and sum then
            return sum
        end
    end
    return nil
end

--- Pure-Lua MD5. Only used when KOReader's crypto module is unavailable.
-- Returns a 32-character lowercase hex string.
local function pure_md5(text)
    -- Bitwise helpers (LuaJIT provides bit32 on KOReader).
    local bit = require("bit")
    local band, bxor, bnot, rshift, lshift, bor =
        bit.band, bit.bxor, bit.bnot, bit.rshift, bit.lshift, bit.bor

    local function to_bytes(str)
        local bytes = {}
        for i = 1, #str do
            bytes[i] = string.byte(str, i)
        end
        return bytes
    end

    local function add32(a, b)
        return (a + b) % 4294967296
    end

    local S = {
        7,12,17,22, 7,12,17,22, 7,12,17,22, 7,12,17,22,
        5, 9,14,20, 5, 9,14,20, 5, 9,14,20, 5, 9,14,20,
        4,11,16,23, 4,11,16,23, 4,11,16,23, 4,11,16,23,
        6,10,15,21, 6,10,15,21, 6,10,15,21, 6,10,15,21,
    }
    local K = {}
    for i = 0, 63 do
        -- math.abs, not a bare abs(): abs is a math-library function and is NOT
        -- a global. Calling it bare raised "attempt to call global 'abs' (a nil
        -- value)" from md5 -> Cache.book_key -> openBook, which killed the
        -- reader the first time any book was opened.
        K[i + 1] = math.floor(math.abs(math.sin(i + 1)) * 4294967296)
    end

    local a0, b0, c0, d0 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476

    local msg = to_bytes(text)
    local bitlen = #msg * 8
    msg[#msg + 1] = 0x80
    while (#msg % 64) ~= 56 do
        msg[#msg + 1] = 0
    end
    -- Append the original bit length little-endian.
    for i = 0, 7 do
        msg[#msg + 1] = math.floor(bitlen / (2 ^ (8 * i))) % 256
    end

    for chunk = 1, #msg, 64 do
        local M = {}
        for i = 0, 15 do
            local o = chunk + i * 4
            M[i] = msg[o] + msg[o + 1] * 256 + msg[o + 2] * 65536
                + msg[o + 3] * 16777216
        end
        local A, B, C, D = a0, b0, c0, d0
        for i = 0, 63 do
            local F, g
            if i < 16 then
                F = bor(band(B, C), band(bnot(B), D))
                g = i
            elseif i < 32 then
                F = bor(band(D, B), band(bnot(D), C))
                g = (5 * i + 1) % 16
            elseif i < 48 then
                F = bor(bxor(B, C), bxor(D, B))
                g = (3 * i + 5) % 16
            else
                F = bxor(C, bxor(D, B))
                g = (7 * i) % 16
            end
            F = (F + A + K[i + 1] + M[g]) % 4294967296
            A = D
            D = C
            C = B
            B = add32(B, lshift(F, S[i + 1]) + rshift(F, 32 - S[i + 1]))
        end
        a0 = add32(a0, A)
        b0 = add32(b0, B)
        c0 = add32(c0, C)
        d0 = add32(d0, D)
    end

    local function hex(n)
        return string.format("%08x", n % 4294967296)
    end
    return hex(a0) .. hex(b0) .. hex(c0) .. hex(d0)
end

function Digest.md5(text)
    text = tostring(text or "")
    local from_ko = ko_md5(text)
    if from_ko then
        return (tostring(from_ko):gsub("%s", "")):lower()
    end
    return pure_md5(text)
end

return Digest
