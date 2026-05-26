-- Text decoder for Valkyrie Profile's variable-width glyph stream.
--
-- A "character" in the encoded script is either a single byte glyph index (< 0x80)
-- or a two-byte sequence: idx = (b0 - 0x80) + (b1 * 128). Indices >= 0x4000 are
-- "special codes" used for inline directives (newline, pause, color, delay, etc.).
-- A 0x0000 character terminates a string.

function getNextChar(script)
    local c = script:readU8()
    if c >= 0x80 then c = (c - 0x80) + (script:readU8() * 128) end
    return c
end

-- Walk a UTF-8 string one codepoint at a time. Returns the raw bytes of the next
-- codepoint and the remainder of the string.
function getNextUtf8(str)
    local n = str:sub(1, 1)
    local b = n:byte()
    if b <= 0x7f then return n, str:sub(2) end
    if b >= 0x80 and b <= 0xc1 then error('Wrong UTF-8 sequence.') end

    local ret = n
    n = str:sub(2, 2)
    ret = ret .. n
    if b <= 0xdf then return ret, str:sub(3) end

    n = str:sub(3, 3)
    ret = ret .. n
    if b <= 0xef then return ret, str:sub(4) end

    n = str:sub(4, 4)
    ret = ret .. n
    if b <= 0xf4 then return ret, str:sub(5) end

    error('Wrong UTF-8 sequence.')
end

-- Decode a special code in the primary (room-script) style.
function dumpSpecial(script, code)
    if code == 0 then
        return '\n', '\n'
    elseif code == 1 then
        return '\n<new/>\n', '\n'
    elseif code == 2 then
        return '<pause>', ''
    elseif code == 3 then
        local speed = script:readU8()
        if speed == 255 then
            return '<rspd/>', ''
        else
            return '<st spd="' .. speed .. '"/>', ''
        end
    elseif code == 4 then
        return '<st clr="' .. script:readU8() .. '"/>', ''
    elseif code == 5 then
        return '<start/>', ''
    elseif code == 7 then
        local rep = script:readU8()
        if rep == 1 then
            return '<rrep/>', ''
        else
            return '<st rep="' .. rep .. '"/>', ''
        end
    elseif code == 8 then
        local siz = script:readU8()
        if siz == 1 then
            return '<rsiz/>', ''
        else
            return '<st siz="' .. siz .. '"/>', ''
        end
    elseif code == 14 then
        return '<var n="' .. script:readU8() .. '"/>', ''
    elseif code == 17 then
        local t = script:readU8()
        local u = script:readU8()
        if u == 0 then
            return '<delay0 t="' .. t .. '"/>', ''
        elseif u == 1 then
            return '<delay1 t="' .. t .. '"/>', ''
        else
            return '<delay t="' .. t .. '" u="' .. u .. '"/>', ''
        end
    elseif code == 18 then
        return '<ssync/>', ''
    elseif code == 19 then
        local arg1 = script:readU8()
        local arg2 = script:readU8()
        if arg1 == 255 and arg2 == 255 then
            return '<dport/>', ''
        else
            return '<port a1="' .. arg1 .. '" a2="' .. arg2 .. '"/>', ''
        end
    else
        if code == 6 or code == 12 then
            local a1 = script:readU8()
            local a2 = script:readU8()
            return '<u2 c="' .. code .. '" a1="' .. a1 .. '" a2="' .. a2 .. '"/>', ''
        else
            return '<uk c="' .. code .. '"/>', ''
        end
    end
end

-- Decode a special code in the secondary style (carc / older scripts).
function dumpSpecial2(script, code)
    if code == 0 then
        return '\n', '\n'
    elseif code == 1 then
        return '\n<new/>\n', '\n'
    elseif code == 2 then
        return '<pause>', ''
    else
        if code == 3 or code == 5 or code == 7 or code == 8 or code == 9 or
            code == 12 or code == 13 or code == 14 or code == 15 or code == 21 then
            local a1 = script:readU8()
            return '<u1 c="' .. code .. '" a="' .. a1 .. '"/>', ''
        elseif code == 20 then
            local a1 = script:readU8()
            local a2 = script:readU8()
            return '<u2 c="' .. code .. '" a1="' .. a1 .. '" a2="' .. a2 .. '"/>', ''
        else
            return '<uk c="' .. code .. '"/>', ''
        end
    end
end

-- Decode one character from the script stream. Returns (xml_fragment, raw_text)
-- where raw_text is the plain visible text only (used for textbox association),
-- and xml_fragment may include special-code tags. Returns nil if 0x0000 was read
-- (string terminator).
--
-- `lookup` is an integer-indexed table mapping glyph indices to character strings.
-- `style` is either 'primary' (room scripts, default) or 'secondary' (carc-style).
function extractChar(script, lookup, style)
    local c = getNextChar(script)
    if c == 0 then return nil end

    if c >= 0x4000 then
        local code = c - 0x4000
        if style == 'secondary' then
            return dumpSpecial2(script, code)
        else
            return dumpSpecial(script, code)
        end
    else
        local l = lookup[c]
        if not l then
            if VP.arguments.sloppyExtract then
                return '<failed value="' .. c .. '"/>', ''
            else
                error('Lookup failed for character ' .. c)
            end
        end
        return l, l
    end
end
