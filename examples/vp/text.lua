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

-- Editable text form of a token list, for the translation editor. Characters
-- are written as themselves, with { and } doubled. Code 0 is a newline, code 1
-- is {new} followed by a newline, and every other code is a {tag}: the named
-- ones below, {cN a b ...} for the rest. A glyph with no character in the font
-- is {g N}, and the 0 inside a simple-script range {zero}.
local tagNames = {
    primary = {
        [2] = 'pause', [3] = 'spd', [4] = 'clr', [5] = 'start', [7] = 'rep', [8] = 'siz', [14] = 'var',
        [17] = 'delay', [18] = 'ssync', [19] = 'port',
    },
    secondary = { [2] = 'pause' },
}
-- Tags that stand for a code with fixed arguments.
local tagAliases = {
    primary = { rspd = { 3, { 255 } }, rrep = { 7, { 1 } }, rsiz = { 8, { 1 } }, dport = { 19, { 255, 255 } } },
    secondary = {},
}

local function tagFor(tok, style)
    for name, a in pairs(tagAliases[style]) do
        if a[1] == tok.c then
            local same = #a[2] == #tok.args
            for i, v in ipairs(a[2]) do same = same and tok.args[i] == v end
            if same then return name end
        end
    end
    local name = tagNames[style][tok.c] or ('c' .. tok.c)
    if #tok.args == 0 then return name end
    return name .. ' ' .. table.concat(tok.args, ' ')
end

-- tokens: { g } (resolved through lookup, the script font's glyph -> character
-- map) or { ch } tokens, and codes.
function VP.text.toEditable(tokens, lookup, style)
    style = style or 'primary'
    local out = {}
    for _, t in ipairs(tokens) do
        local s
        if t.z then
            s = '{zero}'
        elseif t.c == 0 then
            s = '\n'
        elseif t.c == 1 then
            s = '{new}\n'
        elseif t.c then
            s = '{' .. tagFor(t, style) .. '}'
        else
            local ch = t.ch or (lookup and lookup[t.g])
            if not ch or ch == '<??>' then
                s = '{g ' .. t.g .. '}'
            else
                s = ch:gsub('[{}]', '%0%0')
            end
        end
        out[#out + 1] = s
    end
    return table.concat(out)
end

-- Parses the editable form back to tokens. Characters become { ch } tokens and
-- must exist in charset (the font database, VP.constants.font by default).
-- Returns the tokens, or nil, a message, and the byte position of the problem.
function VP.text.fromEditable(text, style, charset)
    style = style or 'primary'
    charset = charset or VP.constants.font
    local tokens = {}
    local codes = {}
    for code, name in pairs(tagNames[style]) do codes[name] = code end
    local pos = 1
    while pos <= #text do
        local c = text:sub(pos, pos)
        if c == '\n' then
            tokens[#tokens + 1] = { c = 0, args = {} }
            pos = pos + 1
        elseif c == '{' and text:sub(pos + 1, pos + 1) == '{' then
            if not charset['{'] then return nil, 'No glyph for {', pos end
            tokens[#tokens + 1] = { ch = '{' }
            pos = pos + 2
        elseif c == '}' and text:sub(pos + 1, pos + 1) == '}' then
            if not charset['}'] then return nil, 'No glyph for }', pos end
            tokens[#tokens + 1] = { ch = '}' }
            pos = pos + 2
        elseif c == '}' then
            return nil, 'A lone } (write }} for the character)', pos
        elseif c == '{' then
            local close = text:find('}', pos, true)
            if not close then return nil, 'Unclosed {', pos end
            local words = {}
            for w in text:sub(pos + 1, close - 1):gmatch('%S+') do words[#words + 1] = w end
            local name = table.remove(words, 1)
            if not name then return nil, 'Empty {}', pos end
            local args = {}
            for i, w in ipairs(words) do
                local n = tonumber(w)
                if not n or n % 1 ~= 0 or n < 0 or n > 255 then
                    return nil, 'Argument ' .. i .. ' of {' .. name .. '} must be a byte value, 0 to 255', pos
                end
                args[i] = n
            end
            local tok
            if name == 'new' then
                tok = { c = 1, args = {} }
            elseif name == 'zero' then
                tok = { z = true }
            elseif name == 'g' then
                if #args ~= 1 or args[1] == 0 then return nil, '{g N} needs one glyph index', pos end
                tok = { g = args[1] }
            elseif tagAliases[style][name] then
                local a = tagAliases[style][name]
                if #args > 0 then return nil, '{' .. name .. '} takes no arguments', pos end
                tok = { c = a[1], args = { unpack(a[2]) } }
            else
                local code = codes[name] or tonumber(name:match('^c(%d+)$'))
                if not code or code >= 0x4000 - 1 then return nil, 'Unknown tag {' .. name .. '}', pos end
                local want = VP.text.argBytes[style][code] or 0
                if #args ~= want then
                    return nil, string.format('{%s} takes %d arguments, got %d', name, want, #args), pos
                end
                tok = { c = code, args = args }
            end
            tokens[#tokens + 1] = tok
            pos = close + 1
            -- The newline written after {new} belongs to it.
            if tok.c == 1 and text:sub(pos, pos) == '\n' then pos = pos + 1 end
        else
            local ch = text:match('^[%z\1-\127\194-\244][\128-\191]*', pos)
            if not ch then return nil, 'Invalid UTF-8', pos end
            if not charset[ch] then return nil, 'No glyph for ' .. ch, pos end
            tokens[#tokens + 1] = { ch = ch }
            pos = pos + #ch
        end
    end
    return tokens
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
