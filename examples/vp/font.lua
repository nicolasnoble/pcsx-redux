function decodeFonts()
    VP.constants.fontByData = {}
    for k, v in pairs(VP.constants.font) do
        v.text = k
        VP.constants.fontByData[v.data] = deepCopy(v)
    end
    VP.constants.fontJPByData = {}
    for k, v in pairs(VP.constants.fontJP) do
        v.text = k
        VP.constants.fontJPByData[v.data] = deepCopy(v)
    end
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
        local fontData = VP.constants.fontByData[glyph]
        if not fontData then error('Could not find glyph ' .. glyph .. ' in the database...') end
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
