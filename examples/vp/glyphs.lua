-- Glyph atlas and script preview.
--
-- Every glyph of the font database (the US font and the JP one) goes into a
-- single texture, so any script can be drawn with the game's own glyphs and
-- widths. Drawing follows the old script editor: each glyph advances by its
-- width, lines are 14 pixels apart, <new/> starts a new page, <st rep="N"/>X<rrep/>
-- repeats X N times, and every other tag is dropped.

VP.glyphs = VP.glyphs or {}

local CELL_W, CELL_H, COLS = 16, 12, 64
local PAGE_W, PAGE_H, LINE_H = 320, 240, 14

-- Solid cells after the glyphs, used to draw the page and the window frame.
local solids = {
    page = 0xffffffff,
    outer = 0xff084058, -- 88, 64, 8
    inner = 0xff60d8f8, -- 248, 216, 96
}

local atlas

local function buildAtlas()
    local entries = {}
    for _, set in ipairs({ { key = 'US', font = VP.constants.font }, { key = 'JP', font = VP.constants.fontJP } }) do
        for text, g in pairs(set.font) do
            entries[#entries + 1] = { set = set.key, text = text, glyph = g }
        end
    end
    local solidNames = { 'page', 'outer', 'inner' }
    local count = #entries + #solidNames
    local rows = math.ceil(count / COLS)
    local w, h = COLS * CELL_W, rows * CELL_H
    local pix = ffi.new('uint32_t[?]', w * h)
    local maps = { US = {}, JP = {} }

    local function cellOrigin(i)
        return (i % COLS) * CELL_W, math.floor(i / COLS) * CELL_H
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
        maps[e.set][e.text] = {
            width = g.width,
            height = g.height,
            u0 = cx / w, v0 = cy / h,
            u1 = (cx + g.width) / w, v1 = (cy + g.height) / h,
        }
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

    atlas = { texture = tonumber(id[0]), maps = maps, solids = solidUV, width = w, height = h, glyphs = #entries }
    return atlas
end

-- Must be called with a GL context current, i.e. from DrawImguiFrame.
function VP.glyphs.atlas()
    return atlas or buildAtlas()
end

-- Splits one pointer's text into its window geometry and its pages, each page
-- being a list of lines with the tags already resolved.
function VP.glyphs.parse(ptr)
    local lines = {}
    for line in (ptr .. '\n'):gmatch('(.-)\n') do lines[#lines + 1] = line end
    local window
    if lines[1] and lines[1]:match('^<window') or lines[1] == '<nowindowdetected/>' then
        local head = table.remove(lines, 1)
        local x, y, width, height = head:match('x="(%-?%d+)" y="(%-?%d+)" width="(%-?%d+)" height="(%-?%d+)"')
        if x then
            window = { x = tonumber(x), y = tonumber(y), width = tonumber(width), height = tonumber(height) }
        end
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

local function drawSolid(a, name, ox, oy, x, y, w, h, scale)
    if w <= 0 or h <= 0 then return end
    local uv = a.solids[name]
    imgui.SetCursorPos(ox + x * scale, oy + y * scale)
    imgui.Image(a.texture, w * scale, h * scale, uv[1], uv[2], uv[3], uv[4])
end

-- Draws one page at the current cursor position and moves the cursor below it.
-- Returns the number of characters that had no glyph.
function VP.glyphs.drawPage(window, lines, font, scale)
    local a = VP.glyphs.atlas()
    local map = a.maps[font or 'US']
    scale = scale or 2
    local ox, oy = imgui.GetCursorPos()
    drawSolid(a, 'page', ox, oy, 0, 0, PAGE_W, PAGE_H, scale)

    local xBase, yCurr = 10, 10
    if window then
        xBase, yCurr = window.x, window.y
        local w, h = window.width, window.height
        drawSolid(a, 'outer', ox, oy, xBase - 8, yCurr, 1, h, scale)
        drawSolid(a, 'inner', ox, oy, xBase - 7, yCurr, 2, h, scale)
        drawSolid(a, 'outer', ox, oy, xBase - 2, yCurr - 7, w + 5, 1, scale)
        drawSolid(a, 'inner', ox, oy, xBase - 2, yCurr - 6, w + 5, 2, scale)
        drawSolid(a, 'outer', ox, oy, xBase + w + 9, yCurr, 1, h, scale)
        drawSolid(a, 'inner', ox, oy, xBase + w + 7, yCurr, 2, h, scale)
        drawSolid(a, 'outer', ox, oy, xBase - 2, yCurr + h + 6, w + 5, 1, scale)
        drawSolid(a, 'inner', ox, oy, xBase - 2, yCurr + h + 4, w + 5, 2, scale)
    end

    local missing = 0
    for _, line in ipairs(lines) do
        local x = xBase
        for ch in line:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
            local g = map[ch]
            if g then
                if x < PAGE_W and yCurr < PAGE_H then
                    imgui.SetCursorPos(ox + x * scale, oy + yCurr * scale)
                    imgui.Image(a.texture, g.width * scale, g.height * scale, g.u0, g.v0, g.u1, g.v1)
                end
                x = x + g.width
            else
                missing = missing + 1
            end
        end
        yCurr = yCurr + LINE_H
    end

    imgui.SetCursorPos(ox, oy + PAGE_H * scale)
    imgui.Dummy(PAGE_W * scale, 4)
    return missing
end
