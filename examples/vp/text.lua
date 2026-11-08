-- Text codec for Valkyrie Profile's variable-width glyph stream.
--
-- A "character" in the encoded script is either a single byte value (< 0x80)
-- or a two-byte sequence: value = (b0 - 0x80) + (b1 * 128). Values >= 0x4000
-- are "special codes" used for inline directives (newline, pause, color, delay,
-- etc.), some of which are followed by argument bytes. A value of 0 terminates
-- a string.
--
-- A decoded string is a list of tokens:
--   { g = glyphIndex }                  a glyph of the script's font
--   { c = code, args = { a1, ... } }    a special code and its argument bytes
--   { z = true }                        a 0 inside a simple-script range, which
--                                       is not the end of that range
-- A glyph or a 0 written in the two-byte form although it is below 0x80 carries
-- wide = true, so that encodeTokens gives back the same bytes. The list's
-- `terminated` field is true when the string ended on a 0 (or 'wide' when that
-- 0 was two bytes long), false when it ran to the end of its range without one.

VP.text = VP.text or {}

-- Number of argument bytes each special code reads, per script style. Codes not
-- listed read none. 'primary' is the room-script dictionary, 'secondary' the
-- carc one.
VP.text.argBytes = {
    primary = { [3] = 1, [4] = 1, [6] = 2, [7] = 1, [8] = 1, [12] = 2, [14] = 1, [17] = 2, [19] = 2 },
    secondary = {
        [3] = 1, [5] = 1, [7] = 1, [8] = 1, [9] = 1, [12] = 1, [13] = 1, [14] = 1, [15] = 1, [21] = 1,
        [20] = 2,
    },
}

local function argCount(style, code)
    return VP.text.argBytes[style or 'primary'][code] or 0
end

-- Reads one value. Returns it, and whether it used the two-byte form for a
-- value below 0x80.
local function readValue(script)
    local b0 = script:readU8()
    if b0 < 0x80 then return b0, false end
    local v = (b0 - 0x80) + script:readU8() * 128
    return v, v < 0x80
end

-- Reads one token. Returns nil and the terminator's form ('wide' or true) when
-- a 0 was read.
function VP.text.readToken(script, style)
    local v, wide = readValue(script)
    if v == 0 then return nil, wide and 'wide' or true end
    if v >= 0x4000 then
        local code = v - 0x4000
        local args = {}
        for i = 1, argCount(style, code) do args[i] = script:readU8() end
        return { c = code, args = args }
    end
    if wide then return { g = v, wide = true } end
    return { g = v }
end

-- Decodes one string from the script's current position. Without endPos it
-- stops at the first 0 (room scripts). With endPos it reads up to that position,
-- and a 0 before it becomes a { z = true } token (simple scripts).
function VP.text.decodeTokens(script, style, endPos)
    local tokens = { terminated = false }
    while true do
        if endPos then
            local pos = tonumber(script:rTell())
            if pos == endPos then break end
            if pos > endPos then
                error(string.format('String ran past the end of its range: at %d, range ends at %d', pos, endPos))
            end
        end
        local tok, term = VP.text.readToken(script, style)
        if tok then
            tokens[#tokens + 1] = tok
        elseif endPos and tonumber(script:rTell()) ~= endPos then
            tokens[#tokens + 1] = { z = true, wide = term == 'wide' or nil }
        else
            tokens.terminated = term
            break
        end
    end
    return tokens
end

-- The exact inverse of decodeTokens: the bytes the tokens were read from.
function VP.text.encodeTokens(tokens, style)
    local out = {}
    local function emit(v, wide)
        if v < 0 or v > 0x7fff then error('Value out of range: ' .. v) end
        if v < 0x80 and not wide then
            out[#out + 1] = string.char(v)
        else
            out[#out + 1] = string.char(0x80 + v % 128, math.floor(v / 128))
        end
    end
    for i, tok in ipairs(tokens) do
        if tok.g then
            if tok.g <= 0 or tok.g >= 0x4000 then error('Glyph index out of range at token ' .. i .. ': ' .. tok.g) end
            emit(tok.g, tok.wide)
        elseif tok.c then
            local args = tok.args or {}
            local n = argCount(style, tok.c)
            if #args ~= n then
                error(string.format('Special code %d takes %d argument bytes, token %d has %d', tok.c, n, i, #args))
            end
            emit(0x4000 + tok.c)
            for _, a in ipairs(args) do out[#out + 1] = string.char(a) end
        elseif tok.z then
            emit(0, tok.wide)
        else
            error('Unknown token at ' .. i)
        end
    end
    if tokens.terminated then emit(0, tokens.terminated == 'wide') end
    return table.concat(out)
end

-- XML-ish rendering of a special code in the primary (room-script) style.
-- Returns the fragment and the visible text it stands for.
local function renderSpecial(code, a)
    if code == 0 then
        return '\n', '\n'
    elseif code == 1 then
        return '\n<new/>\n', '\n'
    elseif code == 2 then
        return '<pause>', ''
    elseif code == 3 then
        if a[1] == 255 then return '<rspd/>', '' end
        return '<st spd="' .. a[1] .. '"/>', ''
    elseif code == 4 then
        return '<st clr="' .. a[1] .. '"/>', ''
    elseif code == 5 then
        return '<start/>', ''
    elseif code == 7 then
        if a[1] == 1 then return '<rrep/>', '' end
        return '<st rep="' .. a[1] .. '"/>', ''
    elseif code == 8 then
        if a[1] == 1 then return '<rsiz/>', '' end
        return '<st siz="' .. a[1] .. '"/>', ''
    elseif code == 14 then
        return '<var n="' .. a[1] .. '"/>', ''
    elseif code == 17 then
        if a[2] == 0 then return '<delay0 t="' .. a[1] .. '"/>', '' end
        if a[2] == 1 then return '<delay1 t="' .. a[1] .. '"/>', '' end
        return '<delay t="' .. a[1] .. '" u="' .. a[2] .. '"/>', ''
    elseif code == 18 then
        return '<ssync/>', ''
    elseif code == 19 then
        if a[1] == 255 and a[2] == 255 then return '<dport/>', '' end
        return '<port a1="' .. a[1] .. '" a2="' .. a[2] .. '"/>', ''
    elseif code == 6 or code == 12 then
        return '<u2 c="' .. code .. '" a1="' .. a[1] .. '" a2="' .. a[2] .. '"/>', ''
    end
    return '<uk c="' .. code .. '"/>', ''
end

-- Same, in the secondary style (carc / older scripts).
local function renderSpecial2(code, a)
    if code == 0 then
        return '\n', '\n'
    elseif code == 1 then
        return '\n<new/>\n', '\n'
    elseif code == 2 then
        return '<pause>', ''
    end
    local n = argCount('secondary', code)
    if n == 1 then return '<u1 c="' .. code .. '" a="' .. a[1] .. '"/>', '' end
    if n == 2 then return '<u2 c="' .. code .. '" a1="' .. a[1] .. '" a2="' .. a[2] .. '"/>', '' end
    return '<uk c="' .. code .. '"/>', ''
end

-- Renders one token. Returns (xml_fragment, raw_text) where raw_text is the
-- plain visible text only (used for textbox association), and xml_fragment may
-- include special-code tags.
--
-- `lookup` is an integer-indexed table mapping glyph indices to character strings.
-- `style` is either 'primary' (room scripts, default) or 'secondary' (carc-style).
function VP.text.renderToken(tok, lookup, style)
    if tok.z then return '<ZERO>', '' end
    if tok.c then
        if style == 'secondary' then return renderSpecial2(tok.c, tok.args) end
        return renderSpecial(tok.c, tok.args)
    end
    local l = lookup[tok.g]
    if not l then
        if VP.arguments.sloppyExtract then return '<failed value="' .. tok.g .. '"/>', '' end
        error('Lookup failed for character ' .. tok.g)
    end
    return l, l
end

-- Renders a whole token list. Returns the XML-ish text and the visible text.
function VP.text.renderTokens(tokens, lookup, style)
    local xml, raw = {}, {}
    for i, tok in ipairs(tokens) do
        xml[i], raw[i] = VP.text.renderToken(tok, lookup, style)
    end
    return table.concat(xml), table.concat(raw)
end

-- 64-bit FNV-1a over a byte string, as 16 lowercase hex digits.
function VP.text.fnv1a64(s)
    local h = 0xcbf29ce484222325ULL
    for i = 1, #s do
        h = bit.bxor(h, s:byte(i)) * 0x100000001b3ULL
    end
    return bit.tohex(h, 16)
end

-- Key of a room script: FNV-1a 64 over its raw bytes (logic, pointers and
-- strings), as decompressed from the retail disc. Rooms sharing a script share
-- the key.
function VP.text.scriptKey(script)
    return VP.text.fnv1a64(tostring(script:readAt(script:size(), 0)))
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
