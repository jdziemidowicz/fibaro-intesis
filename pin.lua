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

function random_bytes(n)
    local bytes = ""
    for i = 1, n do
        bytes = bytes .. string.char(math.random(0, 255))
    end
    return bytes
end
