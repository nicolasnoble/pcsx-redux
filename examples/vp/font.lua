-- Glyphs are looked up by width and bitmap together: some bitmaps appear twice
-- in a database with different widths (the US font has the space at 4 pixels
-- and the ideographic space at 8, both blank), and the width tells them apart.
local function glyphKey(width, data)
    return width .. '-' .. data
end

function decodeFonts()
    VP.constants.fontByData = {}
    for k, v in pairs(VP.constants.font) do
        v.text = k
        VP.constants.fontByData[glyphKey(v.width, v.data)] = deepCopy(v)
    end
    VP.constants.fontJPByData = {}
    for _, e in ipairs(VP.constants.fontJPVariants) do
        local v = deepCopy(e.glyph)
        v.text = e.char
        VP.constants.fontJPByData[glyphKey(v.width, v.data)] = v
    end
    for k, v in pairs(VP.constants.fontJP) do v.text = k end
end

function extractFont(file, fileInfo)
    file:rSeek(0)
    local numGlyphs = file:readU32()
    local height = file:readU32()
    local widths = {}

    for i = 1, numGlyphs do
        widths[i] = file:readU8()
    end

    local ret = {}

    local dir = fileInfo.dir .. '/glyphs'
    if VP.arguments.dumpGlyphs then mkdir(dir) end

    print('Processing ' .. numGlyphs .. ' glyphs.')

    for i = 1, numGlyphs do
        local glyph = base64.encode(tostring(file:read(height * 2)))
        -- A glyph is looked up in its own disc's database first, then in the
        -- other one: the two share bitmaps under different characters (the
        -- US middle dot is the JP katakana middle dot).
        local key = glyphKey(widths[i], glyph)
        local fontData
        if fileInfo.region == 'JP' then
            fontData = VP.constants.fontJPByData[key] or VP.constants.fontByData[key]
        else
            fontData = VP.constants.fontByData[key] or VP.constants.fontJPByData[key]
        end
        -- Fonts are padded with blank glyphs of width 0, which stand for no
        -- character.
        if not fontData and widths[i] == 0 and not glyph:find('[^A=]') then
            fontData = { width = 0, height = height, data = glyph, padding = true }
        end
        if not fontData then
            error('Could not find glyph ' .. glyph .. ' of width ' .. widths[i] .. ' in the database...')
        end
        ret[i] = deepCopy(fontData)
        if VP.arguments.dumpGlyphs then
            local dest = Support.File.open(dir .. string.format("/%03i-%02i.raw", i, widths[i]), 'TRUNCATE')
            dest:write(glyph)
            dest:close()
            file:rSeek(-height * 2, 'SEEK_CUR')
            dest = Support.File.open(dir .. string.format("/%03i-%02i.txt", i, widths[i]), 'TRUNCATE')
            for j = 1, height do
                local bits = file:readU16()
                for k = 1, height do -- should be widths[i]
                    bits = bit.lshift(bits, 1)
                    local bit = bit.band(bits, 65536) ~= 0
                    dest:write(bit and '#' or '.')
                end
                dest:write '\n'
            end
            dest:close()
        end
    end

    return ret
end
