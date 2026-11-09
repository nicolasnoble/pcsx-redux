-- Glyph editing: the bitmaps of the font database as editable grids, and the
-- checks a glyph must pass before a translation database stores it.
--
-- A glyph is { width, height, data }: data is base64 of height rows of two
-- bytes, the second byte of a row holding the left eight columns, bit 7 being
-- the leftmost (the layout glyphs.lua draws). width is the ADVANCE: on retail
-- glyphs it is usually the bitmap's extent plus one blank column.
--
-- Edits and additions live in the translation database (VP.tdb, glyphs table),
-- per target language, and are overlaid on the retail font and the language's
-- letters by tdb:charset, which is what the fit check, the previews and the
-- in-game preview read. font-database.lua is never written.

VP.fontedit = VP.fontedit or {}
local F = VP.fontedit

F.HEIGHT = 12 -- room fonts, US and JP alike
F.COLUMNS = 16

-- Rows of a glyph as integers, bit 15 the leftmost column.
function F.rows(data, height)
    height = height or F.HEIGHT
    local bytes = base64.decode(data or '')
    local rows = {}
    for y = 0, height - 1 do
        rows[y + 1] = (bytes:byte(y * 2 + 2) or 0) * 256 + (bytes:byte(y * 2 + 1) or 0)
    end
    return rows
end

function F.encode(rows)
    local out = {}
    for y, r in ipairs(rows) do
        out[#out + 1] = string.char(bit.band(r, 255), bit.band(bit.rshift(r, 8), 255))
    end
    return base64.encode(table.concat(out))
end

function F.blank(height)
    local rows = {}
    for y = 1, height or F.HEIGHT do rows[y] = 0 end
    return rows
end

function F.get(rows, x, y) return bit.band(rows[y + 1] or 0, bit.lshift(1, 15 - x)) ~= 0 end

function F.set(rows, x, y, on)
    local m = bit.lshift(1, 15 - x)
    rows[y + 1] = on and bit.bor(rows[y + 1], m) or bit.band(rows[y + 1], bit.bnot(m))
end

-- Columns used by the bitmap: one past the rightmost lit pixel (0 when blank).
function F.extent(rows)
    local e = 0
    for _, r in ipairs(rows) do
        for x = F.COLUMNS - 1, 0, -1 do
            if bit.band(r, bit.lshift(1, 15 - x)) ~= 0 then
                if x + 1 > e then e = x + 1 end
                break
            end
        end
    end
    return e
end

-- The advance retail glyphs mostly have.
function F.suggestedWidth(rows) return math.min(F.extent(rows) + 1, F.COLUMNS) end

local codepoint = '^[\32-\126\194-\244][\128-\191]*$'

-- Checks a glyph a translator wants stored. Returns problems (any one refuses
-- the save) and notes (shown, not refused). charset is what the character
-- would otherwise be, to find bitmaps shared with another character.
function F.check(g, charset)
    local problems, notes = {}, {}
    if type(g.ch) ~= 'string' or not g.ch:match(codepoint) or #g.ch > 4 then
        problems[#problems + 1] = 'a glyph is one printable character'
    elseif g.ch == '{' or g.ch == '}' then
        notes[#notes + 1] = 'type ' .. g.ch .. g.ch .. ' in the editor to use this character'
    end
    if type(g.width) ~= 'number' or g.width ~= math.floor(g.width) or g.width < 1 or g.width > F.COLUMNS then
        problems[#problems + 1] = 'the advance is 1 to ' .. F.COLUMNS .. ' pixels'
    end
    if (g.height or F.HEIGHT) ~= F.HEIGHT then
        problems[#problems + 1] = 'room fonts are ' .. F.HEIGHT .. ' pixels high'
    end
    local bytes = type(g.data) == 'string' and base64.decode(g.data) or ''
    if #bytes ~= F.HEIGHT * 2 then
        problems[#problems + 1] = 'the bitmap is ' .. F.HEIGHT .. ' rows of 16 pixels'
    end
    if #problems > 0 then return problems, notes end
    local rows = F.rows(g.data)
    local e = F.extent(rows)
    if e == 0 and g.ch ~= ' ' then notes[#notes + 1] = 'the bitmap is blank' end
    if e > g.width then
        notes[#notes + 1] = string.format('the bitmap is %d pixels wide and the advance %d: the next character ' ..
            'overlaps it, and the previews clip it at the advance', e, g.width)
    end
    for other, o in pairs(charset or {}) do
        if other ~= g.ch and o.width == g.width and o.data == g.data then
            notes[#notes + 1] = 'same glyph as ' .. other .. ': in a room font both use one slot'
        end
    end
    table.sort(notes)
    return problems, notes
end

-- Where a character's glyph comes from in a charset built by tdb:charset:
-- 'retail', 'letter' (the target language's set), 'edited' (a database glyph
-- over one of those) or 'added'.
function F.origin(ch, lang, edited)
    local base = VP.languages.charset(lang)[ch]
    if edited then return base and 'edited' or 'added' end
    if VP.constants.retailFont[ch] then return 'retail' end
    return base and 'letter' or nil
end

-- Every character a database can edit, sorted by codepoint: { ch, glyph,
-- origin }. `edits` maps characters to the database's glyphs.
function F.entries(lang, edits)
    local list, seen = {}, {}
    local base = VP.languages.charset(lang)
    for ch, g in pairs(base) do
        seen[ch] = true
        list[#list + 1] = { ch = ch, glyph = edits[ch] or g, origin = F.origin(ch, lang, edits[ch] ~= nil) }
    end
    for ch, g in pairs(edits) do
        if not seen[ch] then list[#list + 1] = { ch = ch, glyph = g, origin = 'added' } end
    end
    local function cp(s)
        local c = s:byte(1)
        if c < 0x80 then return c end
        local n = c >= 0xf0 and 4 or c >= 0xe0 and 3 or 2
        local v = bit.band(c, bit.rshift(0xff, n + 1))
        for i = 2, #s do v = v * 64 + bit.band(s:byte(i), 0x3f) end
        return v
    end
    table.sort(list, function(a, b) return cp(a.ch) < cp(b.ch) end)
    return list
end

-- The Japanese font database names some characters several times with
-- different bitmaps, and a room font can use any of them. Returns every
-- bitmap listed for ch, in file order. That font is the JP pane's, read only:
-- a translation is drawn with the target language's glyphs.
function F.jpVariants(ch)
    local list = {}
    for _, v in ipairs(VP.constants.fontJPVariants or {}) do
        if v.char == ch then list[#list + 1] = v.glyph end
    end
    return list
end

-- Characters of the JP database with more than one bitmap, sorted.
function F.jpDuplicates()
    local count, list = {}, {}
    for _, v in ipairs(VP.constants.fontJPVariants or {}) do count[v.char] = (count[v.char] or 0) + 1 end
    for ch, n in pairs(count) do
        if n > 1 then list[#list + 1] = { ch = ch, count = n } end
    end
    table.sort(list, function(a, b) return a.ch < b.ch end)
    return list
end
