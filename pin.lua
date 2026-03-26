local function pin_to_bcd(pin)
    local result, shift = 0, 0
    repeat
        result = result | ((pin % 10) << shift)
        shift  = shift + 4
        pin    = pin // 10
    until pin == 0
    return result
end

function derive_key(pin, mac_int)
    local bcd = pin_to_bcd(pin)
    local buf = string.char(
        (bcd    >> 24) & 0xFF,
        (bcd    >> 16) & 0xFF,
        (bcd    >>  8) & 0xFF,
         bcd           & 0xFF,
        0xAA,
         mac_int        & 0xFF,   -- MAC little-endian (LSB first)
        (mac_int >>  8) & 0xFF,
        (mac_int >> 16) & 0xFF,
        (mac_int >> 24) & 0xFF,
        (mac_int >> 32) & 0xFF,
        (mac_int >> 40) & 0xFF,
        0x55,
        (bcd    >> 24) & 0xFF,
        (bcd    >> 16) & 0xFF,
        (bcd    >>  8) & 0xFF,
         bcd           & 0xFF
    )
    return md5(buf)
end

function bytes_to_hex(s)
    return (s:gsub(".", function(c) return ("%02X"):format(c:byte()) end))
end

function hex_to_bytes(h)
    return (h:gsub("..", function(hh) return string.char(tonumber(hh, 16)) end))
end

function random_bytes(n)
    math.randomseed(os.time())

    local bytes = ""
    for i = 1, n do
        bytes = bytes .. string.char(math.random(0, 255))
    end
    return bytes
end

local ESC_SEQ = {
    [0x00] = "\xFE\x30",
    [0x0D] = "\xFE\x31",
    [0x0A] = "\xFE\x32",
    [0xFE] = "\xFE\xFE",
}

function escape(data, buff_len)
    local num2 = 0
    for i = 1, buff_len do
        num2 = num2 + (ESC_SEQ[data:byte(i)] and 2 or 1)
    end
    if num2 == buff_len then return data end

    local t = {}
    for i = 1, buff_len do
        t[#t+1] = ESC_SEQ[data:byte(i)] or string.char(data:byte(i))
    end
    t[#t+1] = "\x0A"
    return table.concat(t)
end

function unescape(data)
    local t, i = {}, 1
    while i <= #data do
        local b = data:byte(i)
        if b == 0xFE and i < #data then
            local code = data:byte(i + 1)
            if     code == 0x30 then t[#t+1] = "\x00"
            elseif code == 0x31 then t[#t+1] = "\x0D"
            elseif code == 0x32 then t[#t+1] = "\x0A"
            elseif code == 0xFE then t[#t+1] = "\xFE"
            else                     t[#t+1] = string.char(code)
            end
            i = i + 2
        else
            t[#t+1] = string.char(b)
            i = i + 1
        end
    end
    return table.concat(t)
end
