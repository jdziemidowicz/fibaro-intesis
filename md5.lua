function md5(msg)
    local msglen = #msg
    local bitlen = msglen * 8

    -- Padding: append 0x80, then zeros until length ≡ 56 (mod 64)
    msg = msg .. "\x80"
    while #msg % 64 ~= 56 do msg = msg .. "\x00" end
    -- Append original bit-length as 64-bit little-endian
    for i = 0, 7 do msg = msg .. string.char((bitlen >> (8 * i)) & 0xFF) end

    local h0 = 0x67452301
    local h1 = 0xEFCDAB89
    local h2 = 0x98BADCFE
    local h3 = 0x10325476

    -- Per-round left-rotate amounts
    local s = {
         7, 12, 17, 22,  7, 12, 17, 22,  7, 12, 17, 22,  7, 12, 17, 22,
         5,  9, 14, 20,  5,  9, 14, 20,  5,  9, 14, 20,  5,  9, 14, 20,
         4, 11, 16, 23,  4, 11, 16, 23,  4, 11, 16, 23,  4, 11, 16, 23,
         6, 10, 15, 21,  6, 10, 15, 21,  6, 10, 15, 21,  6, 10, 15, 21,
    }

    -- T[i] = floor(2^32 * |sin(i)|), i = 1..64
    local T = {
        0xD76AA478, 0xE8C7B756, 0x242070DB, 0xC1BDCEEE,
        0xF57C0FAF, 0x4787C62A, 0xA8304613, 0xFD469501,
        0x698098D8, 0x8B44F7AF, 0xFFFF5BB1, 0x895CD7BE,
        0x6B901122, 0xFD987193, 0xA679438E, 0x49B40821,
        0xF61E2562, 0xC040B340, 0x265E5A51, 0xE9B6C7AA,
        0xD62F105D, 0x02441453, 0xD8A1E681, 0xE7D3FBC8,
        0x21E1CDE6, 0xC33707D6, 0xF4D50D87, 0x455A14ED,
        0xA9E3E905, 0xFCEFA3F8, 0x676F02D9, 0x8D2A4C8A,
        0xFFFA3942, 0x8771F681, 0x6D9D6122, 0xFDE5380C,
        0xA4BEEA44, 0x4BDECFA9, 0xF6BB4B60, 0xBEBFBC70,
        0x289B7EC6, 0xEAA127FA, 0xD4EF3085, 0x04881D05,
        0xD9D4D039, 0xE6DB99E5, 0x1FA27CF8, 0xC4AC5665,
        0xF4292244, 0x432AFF97, 0xAB9423A7, 0xFC93A039,
        0x655B59C3, 0x8F0CCC92, 0xFFEFF47D, 0x85845DD1,
        0x6FA87E4F, 0xFE2CE6E0, 0xA3014314, 0x4E0811A1,
        0xF7537E82, 0xBD3AF235, 0x2AD7D2BB, 0xEB86D391,
    }

    -- 32-bit NOT (Lua integers are 64-bit signed)
    local function bnot32(x) return (~x) & 0xFFFFFFFF end

    for blk = 1, #msg, 64 do
        local M = {}
        for j = 0, 15 do
            local p = blk + j * 4
            M[j] = msg:byte(p)
                 | (msg:byte(p + 1) << 8)
                 | (msg:byte(p + 2) << 16)
                 | (msg:byte(p + 3) << 24)
        end

        local A, B, C, D = h0, h1, h2, h3

        for i = 1, 64 do
            local F, g
            if i <= 16 then
                F = (B & C) | (bnot32(B) & D)
                g = i - 1
            elseif i <= 32 then
                F = (D & B) | (bnot32(D) & C)
                g = (5 * (i - 1) + 1) % 16
            elseif i <= 48 then
                F = B ~ C ~ D
                g = (3 * (i - 1) + 5) % 16
            else
                F = C ~ (B | bnot32(D))
                g = (7 * (i - 1)) % 16
            end

            F = (F + A + T[i] + M[g]) & 0xFFFFFFFF
            A = D
            D = C
            C = B
            local sh = s[i]
            B = (B + (((F << sh) & 0xFFFFFFFF) | (F >> (32 - sh)))) & 0xFFFFFFFF
        end

        h0 = (h0 + A) & 0xFFFFFFFF
        h1 = (h1 + B) & 0xFFFFFFFF
        h2 = (h2 + C) & 0xFFFFFFFF
        h3 = (h3 + D) & 0xFFFFFFFF
    end

    local function le32(v)
        return string.char(v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF)
    end
    return le32(h0) .. le32(h1) .. le32(h2) .. le32(h3)
end
