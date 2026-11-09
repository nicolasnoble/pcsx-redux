-- Glyph atlas and script preview.
--
-- Every glyph of the font database (the US font and the JP one) goes into a
-- single texture, so any script can be drawn with the game's own glyphs and
-- widths. Drawing follows the old script editor: each glyph advances by its
-- width, lines are 14 pixels apart, <new/> starts a new page, <st rep="N"/>X<rrep/>
-- repeats X N times, and every other tag is dropped.

VP.glyphs = VP.glyphs or {}

local CELL_W, CELL_H, COLS = 16, 12, 64
-- Every cell is surrounded by a transparent gutter. ImGui's OpenGL backend binds
-- its own sampler, which filters linearly whatever the texture asks for, so a
-- glyph drawn at a fractional scale would otherwise pick up the edge of the
-- cell next to it in the atlas.
local GUTTER = 1
local STRIDE_W, STRIDE_H = CELL_W + 2 * GUTTER, CELL_H + 2 * GUTTER
local PAGE_W, PAGE_H, LINE_H = 320, 240, 14

-- Solid cells after the glyphs, used to draw the page and the window frame.
local solids = {
    page = 0xffffffff,
    outer = 0xff084058, -- 88, 64, 8
    inner = 0xff60d8f8, -- 248, 216, 96
}

local atlas
-- Glyphs drawn from a charset table (a translation database's, VP.tdb
-- charset) that are not in the font databases: edited and added glyphs. Each
-- new one rebuilds the atlas.
local extraGlyphs, extraSeen = {}, {}

local function buildAtlas()
    local entries = {}
    for _, set in ipairs({ { key = 'US', font = VP.constants.font }, { key = 'JP', font = VP.constants.fontJP } }) do
        for text, g in pairs(set.font) do
            entries[#entries + 1] = { set = set.key, text = text, glyph = g }
        end
    end
    for _, g in ipairs(extraGlyphs) do entries[#entries + 1] = { glyph = g } end
    local solidNames = { 'page', 'outer', 'inner' }
    local count = #entries + #solidNames
    local rows = math.ceil(count / COLS)
    local w, h = COLS * STRIDE_W, rows * STRIDE_H
    local pix = ffi.new('uint32_t[?]', w * h)
    local maps = { US = {}, JP = {} }
    local byGlyph = {}

    local function cellOrigin(i)
        return (i % COLS) * STRIDE_W + GUTTER, math.floor(i / COLS) * STRIDE_H + GUTTER
    end

    for i, e in ipairs(entries) do
        local g = e.glyph
        local cx, cy = cellOrigin(i - 1)
        local bytes = base64.decode(g.data)
        for y = 0, g.height - 1 do
            local lo, hi = bytes:byte(y * 2 + 1) or 0, bytes:byte(y * 2 + 2) or 0
            local bits = hi * 256 + lo
            for x = 0, math.min(g.width, CELL_W) - 1 do
                if bit.band(bits, bit.lshift(1, 15 - x)) ~= 0 then
                    pix[(cy + y) * w + cx + x] = 0xff000000
                end
            end
        end
        local uv = {
            width = g.width,
            height = g.height,
            u0 = cx / w, v0 = cy / h,
            u1 = (cx + math.min(g.width, CELL_W)) / w, v1 = (cy + g.height) / h,
        }
        if e.set then maps[e.set][e.text] = uv end
        byGlyph[g] = uv
    end

    local solidUV = {}
    for j, name in ipairs(solidNames) do
        local cx, cy = cellOrigin(#entries + j - 1)
        for y = 0, CELL_H - 1 do
            for x = 0, CELL_W - 1 do pix[(cy + y) * w + cx + x] = solids[name] end
        end
        -- Sample the middle of the cell so filtering never reaches a neighbour.
        local u, v = (cx + CELL_W / 2) / w, (cy + CELL_H / 2) / h
        solidUV[name] = { u, v, u, v }
    end

    local id = ffi.new('GLuint[1]')
    gl.glGenTextures(1, id)
    gl.glBindTexture(gl.GL_TEXTURE_2D, id[0])
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST)
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_NEAREST)
    gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA, w, h, 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, pix)

    atlas = { texture = tonumber(id[0]), maps = maps, byGlyph = byGlyph, solids = solidUV, width = w, height = h,
        glyphs = #entries }
    return atlas
end

-- Must be called with a GL context current, i.e. from DrawImguiFrame.
function VP.glyphs.atlas()
    return atlas or buildAtlas()
end

-- The atlas map of a charset table: every glyph it holds, added to the atlas
-- first when it is not there yet. Checked once per table; a database builds a
-- new table whenever its glyphs change.
local charsetMaps = setmetatable({}, { __mode = 'k' })
local function atlasMap(set)
    local a = VP.glyphs.atlas()
    local m = charsetMaps[set]
    if m and m.atlas == a then return a, m.map end
    local grew = false
    for _, g in pairs(set) do
        if not a.byGlyph[g] and not extraSeen[g] then
            extraSeen[g] = true
            extraGlyphs[#extraGlyphs + 1] = g
            grew = true
        end
    end
    if grew then
        gl.glDeleteTextures(1, ffi.new('GLuint[1]', a.texture))
        atlas = nil
        a = buildAtlas()
    end
    local map = {}
    for ch, g in pairs(set) do map[ch] = a.byGlyph[g] end
    charsetMaps[set] = { atlas = a, map = map }
    return a, map
end

-- Screen rectangle of the text area described by a <window .../> line, or nil.
-- A fixed window is the one the 0x0090 helper opens. With placement="helper",
-- small x and y values are the 0x033C helper's placement codes. Values only
-- known at runtime come back in `unknown`, and a default position is used.
function VP.glyphs.windowGeometry(head)
    if head:match('type="fixed"') then return { x = 64, y = 32, width = 192, height = 14, unknown = {} } end
    local function attr(name) return head:match(name .. '="([^"]*)"') end
    local w, h = tonumber(attr('width')), tonumber(attr('height'))
    if not w or not h then return nil end
    local x, y = tonumber(attr('x')), tonumber(attr('y'))
    local window = { width = w, height = h, unknown = {} }
    if head:match('placement="helper"') then
        if x == 0 or x == 2 then
            x = 24
        elseif x == 1 or x == 3 then
            x = 296 - w
        elseif x == 4 then
            x = 160 - math.floor(w / 2)
        elseif x and x >= 8 and x < 16 then
            window.unknown[#window.unknown + 1] = 'side of actor ' .. x
            x = 24
        end
        if y == 2 then
            y = 16
        elseif y == 3 then
            y = 192 - h
        elseif y == 4 then
            y = 120 - math.floor(h / 2)
        end
    end
    if not x then
        window.unknown[#window.unknown + 1] = 'x'
        x = 24
    end
    if not y then
        window.unknown[#window.unknown + 1] = 'y'
        y = 16
    end
    window.x, window.y = x, y
    return window
end

-- Splits one pointer's text into its window geometry and its pages, each page
-- being a list of lines with the tags already resolved.
function VP.glyphs.parse(ptr)
    local lines = {}
    for line in (ptr .. '\n'):gmatch('(.-)\n') do lines[#lines + 1] = line end
    local window
    if lines[1] and lines[1]:match('^<window') or lines[1] == '<nowindowdetected/>' then
        window = VP.glyphs.windowGeometry(table.remove(lines, 1))
    end
    local pages, page = {}, {}
    for _, line in ipairs(lines) do
        if line == '<new/>' then
            pages[#pages + 1] = page
            page = {}
        else
            line = line:gsub('<st rep="(%d+)"/>(.-)<rrep/>', function(n, s)
                local first = s:match('^[%z\1-\127\194-\244][\128-\191]*') or ''
                return first:rep(tonumber(n))
            end)
            line = line:gsub('<[^>]*>', '')
            page[#page + 1] = line
        end
    end
    pages[#pages + 1] = page
    return window, pages
end

-- The advance rule shared by drawPage and measure: each character of a line
-- advances by its glyph's width, and a character with no glyph in `map` is
-- skipped. Calls fn(glyph, x) for each drawn glyph, x relative to the line's
-- start. Returns the line's width and the number of characters skipped.
-- `set` in the functions below is 'US' (the default) or 'JP', the font
-- database to measure with, or a charset table such as VP.languages.charset.
local function mapOf(set)
    if type(set) == 'table' then return set end
    return set == 'JP' and VP.constants.fontJP or VP.constants.font
end

local function layoutLine(line, map, fn)
    local x, missing = 0, 0
    for ch in line:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        local g = map[ch]
        if g then
            if fn then fn(g, x) end
            x = x + g.width
        else
            missing = missing + 1
        end
    end
    return x, missing
end

-- Pixel width of every line of every page of a token list, as drawPage would
-- lay it out. `font` is the script's font as extractFont returns it, which maps
-- glyph indices to characters; widths come from the font database of `set`
-- ('US' by default, or 'JP'). `style` is the script style of the tokens.
-- Returns { { line widths of page 1 }, { page 2 }, ... } and the number of
-- characters with no glyph. Laid out from the tokens, not from the rendered
-- text, so a literal < or > glyph is not mistaken for a tag.
function VP.glyphs.measure(tokens, font, set, style)
    return VP.glyphs.measureTokens(tokens, font and resolveFont(font), style, set)
end

-- Pages of a token list, each a list of line strings, laid out the way parse
-- lays out the rendered text: code 0 ends a line, code 1 ends a page, and in the
-- primary style <st rep="N"/>X<rrep/> on one line becomes the first character
-- of X repeated N times. Other codes draw nothing. Tokens are either { g = n },
-- resolved through lookup (the script font, glyph index -> character), or
-- { ch = c }, a character of the font database, as in a translation.
function VP.glyphs.pagesFromTokens(tokens, lookup, style)
    local primary = (style or 'primary') == 'primary'
    local pages, page, line = {}, {}, {}
    local repStart, repCount
    local function endLine()
        page[#page + 1] = table.concat(line)
        line, repStart = {}, nil
    end
    for _, t in ipairs(tokens) do
        if t.ch then
            line[#line + 1] = t.ch
        elseif t.g then
            local ch = lookup and lookup[t.g]
            if ch and ch ~= '<??>' then line[#line + 1] = ch end
        elseif t.c == 0 then
            endLine()
        elseif t.c == 1 then
            endLine()
            pages[#pages + 1] = page
            page = {}
        elseif primary and t.c == 7 then
            if t.args[1] ~= 1 then
                repStart, repCount = #line + 1, t.args[1]
            elseif repStart then
                local first = line[repStart] or ''
                for i = #line, repStart, -1 do line[i] = nil end
                line[repStart] = first:rep(repCount)
                repStart = nil
            end
        end
    end
    endLine()
    pages[#pages + 1] = page
    return pages
end

-- Pixel width of every line of every page of a token list (see
-- pagesFromTokens), with the widths of the font database of `set` ('US' by
-- default). Returns { { line widths of page 1 }, ... } and the number of
-- characters with no glyph in that database.
-- Breaks a line the way the game's textbox does: a line wider than the box
-- wraps at the last space that keeps it within width, and the spaces at the
-- break are dropped. Measured in game on retail strings (the 3615 and 3622
-- samples on Board#1975). Returns the wrapped lines and whether some word is
-- wider than the box on its own. width nil returns the line unchanged.
function VP.glyphs.wrapLine(line, width, set)
    if type(width) ~= 'number' then return { line }, false end
    local map = mapOf(set)
    local out, cur, tooWide = {}, line:match('^ *'), false
    local hasWord = false
    for word, spaces in line:gmatch('([^ ]+)( *)') do
        local w = layoutLine(word, map)
        if w > width then tooWide = true end
        if hasWord and layoutLine(cur .. word, map) > width then
            out[#out + 1] = (cur:gsub(' +$', ''))
            cur = word .. spaces
        else
            cur = cur .. word .. spaces
        end
        hasWord = true
    end
    out[#out + 1] = (cur:gsub(' +$', ''))
    return out, tooWide
end

-- pagesFromTokens with every line wrapped to width.
function VP.glyphs.wrapPages(pages, width, set)
    local out, tooWide = {}, false
    for p, lines in ipairs(pages) do
        out[p] = {}
        for _, line in ipairs(lines) do
            local wrapped, wide = VP.glyphs.wrapLine(line, width, set)
            if wide then tooWide = true end
            for _, l in ipairs(wrapped) do out[p][#out[p] + 1] = l end
        end
    end
    return out, tooWide
end

-- What the box shows once a page has typed out: a page with more lines than
-- the box holds (14 pixels a line) has scrolled to its last lines. height nil
-- returns the pages unchanged.
function VP.glyphs.scrollPages(pages, height)
    if type(height) ~= 'number' then return pages end
    local keep = math.max(1, math.floor((height + 2) / 14))
    local out = {}
    for p, lines in ipairs(pages) do
        out[p] = {}
        for l = math.max(1, #lines - keep + 1), #lines do out[p][#out[p] + 1] = lines[l] end
    end
    return out
end

function VP.glyphs.measureTokens(tokens, lookup, style, set)
    local map = mapOf(set)
    local widths, missing = {}, 0
    for p, lines in ipairs(VP.glyphs.pagesFromTokens(tokens, lookup, style)) do
        widths[p] = {}
        for l, line in ipairs(lines) do
            local w, m = layoutLine(line, map)
            widths[p][l] = w
            missing = missing + m
        end
    end
    return widths, missing
end

local function drawSolid(a, name, ox, oy, x, y, w, h, scale)
    if w <= 0 or h <= 0 then return end
    local uv = a.solids[name]
    imgui.SetCursorPos(ox + x * scale, oy + y * scale)
    imgui.Image(a.texture, w * scale, h * scale, uv[1], uv[2], uv[3], uv[4])
end

-- Lays out one page the way the game draws it: solid(name, x, y, w, h) for
-- the page and the window frame, then glyph(g, x, y) for every glyph that
-- starts on the page, in page pixels. map gives each character's glyph (its
-- width is the advance). Returns the number of characters with no glyph.
local function layoutPage(window, lines, map, solid, glyph)
    solid('page', 0, 0, PAGE_W, PAGE_H)
    local xBase, yCurr = 10, 10
    if window then
        xBase, yCurr = window.x, window.y
        local w, h = window.width, window.height
        solid('outer', xBase - 8, yCurr, 1, h)
        solid('inner', xBase - 7, yCurr, 2, h)
        solid('outer', xBase - 2, yCurr - 7, w + 5, 1)
        solid('inner', xBase - 2, yCurr - 6, w + 5, 2)
        solid('outer', xBase + w + 9, yCurr, 1, h)
        solid('inner', xBase + w + 7, yCurr, 2, h)
        solid('outer', xBase - 2, yCurr + h + 6, w + 5, 1)
        solid('inner', xBase - 2, yCurr + h + 4, w + 5, 2)
    end
    local missing = 0
    for _, line in ipairs(lines) do
        local _, m = layoutLine(line, map, function(g, dx)
            local x = xBase + dx
            if x < PAGE_W and yCurr < PAGE_H then glyph(g, x, yCurr) end
        end)
        missing = missing + m
        yCurr = yCurr + LINE_H
    end
    return missing
end

-- Draws one page at the current cursor position and moves the cursor below it.
-- font is 'US' (the default), 'JP', or a charset table (VP.tdb charset), whose
-- edited and added glyphs are put in the atlas.
-- Returns the number of characters that had no glyph.
function VP.glyphs.drawPage(window, lines, font, scale)
    local a, map
    if type(font) == 'table' then
        a, map = atlasMap(font)
    else
        a = VP.glyphs.atlas()
        map = a.maps[font or 'US']
    end
    scale = scale or 2
    local ox, oy = imgui.GetCursorPos()
    local missing = layoutPage(window, lines, map, function(name, x, y, w, h)
        drawSolid(a, name, ox, oy, x, y, w, h, scale)
    end, function(g, x, y)
        imgui.SetCursorPos(ox + x * scale, oy + y * scale)
        imgui.Image(a.texture, g.width * scale, g.height * scale, g.u0, g.v0, g.u1, g.v1)
    end)
    imgui.SetCursorPos(ox, oy + PAGE_H * scale)
    imgui.Dummy(PAGE_W * scale, 4)
    return missing
end

-- The same page as drawPage, as a 320x240 PNG (palette: page, ink, and the
-- two frame colours), for views with no GL context. Returns the PNG bytes and
-- the number of characters that had no glyph.
local palette = { 'page', 'ink', 'outer', 'inner' }
local colorOf = { ink = 0xff000000 }
for k, v in pairs(solids) do colorOf[k] = v end
local indexOf = {}
for i, name in ipairs(palette) do indexOf[name] = i - 1 end
local bitmapCache = setmetatable({}, { __mode = 'k' })

local crcTable
local function crc32(s)
    if not crcTable then
        crcTable = {}
        for n = 0, 255 do
            local c = n
            for _ = 1, 8 do c = bit.band(c, 1) ~= 0 and bit.bxor(0xedb88320, bit.rshift(c, 1)) or bit.rshift(c, 1) end
            crcTable[n] = c
        end
    end
    local c = 0xffffffff
    for i = 1, #s do c = bit.bxor(crcTable[bit.band(bit.bxor(c, s:byte(i)), 0xff)], bit.rshift(c, 8)) end
    return bit.bxor(c, 0xffffffff)
end

local function be32(n)
    return string.char(bit.band(bit.rshift(n, 24), 255), bit.band(bit.rshift(n, 16), 255),
        bit.band(bit.rshift(n, 8), 255), bit.band(n, 255))
end

local function chunk(kind, data) return be32(#data) .. kind .. data .. be32(crc32(kind .. data)) end

-- zlib stream of stored (uncompressed) deflate blocks.
local function zstore(data)
    local out, a, b = { '\120\1' }, 1, 0
    for i = 1, #data do
        a = (a + data:byte(i)) % 65521
        b = (b + a) % 65521
    end
    local pos = 1
    repeat
        local n = math.min(65535, #data - pos + 1)
        local final = pos + n > #data and 1 or 0
        out[#out + 1] = string.char(final, bit.band(n, 255), bit.rshift(n, 8), bit.band(bit.bnot(n), 255),
            bit.band(bit.rshift(bit.bnot(n), 8), 255))
        out[#out + 1] = data:sub(pos, pos + n - 1)
        pos = pos + n
    until pos > #data
    out[#out + 1] = be32(b * 65536 + a)
    return table.concat(out)
end

function VP.glyphs.pagePng(window, lines, font)
    local db = type(font) == 'table' and font or font == 'JP' and VP.constants.fontJP or VP.constants.font
    local pix = ffi.new('uint8_t[?]', PAGE_W * PAGE_H)
    local function fill(x0, y0, w, h, v)
        for y = math.max(0, y0), math.min(PAGE_H, y0 + h) - 1 do
            for x = math.max(0, x0), math.min(PAGE_W, x0 + w) - 1 do pix[y * PAGE_W + x] = v end
        end
    end
    local missing = layoutPage(window, lines, db, function(name, x, y, w, h)
        fill(x, y, w, h, indexOf[name])
    end, function(g, x0, y0)
        local bytes = bitmapCache[g]
        if not bytes then
            bytes = base64.decode(g.data)
            bitmapCache[g] = bytes
        end
        for y = 0, g.height - 1 do
            local bits = (bytes:byte(y * 2 + 2) or 0) * 256 + (bytes:byte(y * 2 + 1) or 0)
            for x = 0, math.min(g.width, CELL_W) - 1 do
                local px, py = x0 + x, y0 + y
                if bit.band(bits, bit.lshift(1, 15 - x)) ~= 0 and px < PAGE_W and py < PAGE_H then
                    pix[py * PAGE_W + px] = indexOf.ink
                end
            end
        end
    end)
    local rows = {}
    for y = 0, PAGE_H - 1 do rows[#rows + 1] = '\0' .. ffi.string(pix + y * PAGE_W, PAGE_W) end
    local plte = {}
    for _, name in ipairs(palette) do
        local c = colorOf[name]
        plte[#plte + 1] = string.char(bit.band(c, 255), bit.band(bit.rshift(c, 8), 255), bit.band(bit.rshift(c, 16), 255))
    end
    local png = '\137PNG\r\n\26\n' ..
        chunk('IHDR', be32(PAGE_W) .. be32(PAGE_H) .. '\8\3\0\0\0') ..
        chunk('PLTE', table.concat(plte)) ..
        chunk('IDAT', zstore(table.concat(rows))) ..
        chunk('IEND', '')
    return png, missing
end
