-- Walker for .agx graphics archives. Each entry carries an 'extra' u32 whose
-- high 24 bits identify a sub-type; 0x00300900 = script, 0x00300800 = font.
-- A paired (script, font) inside one .agx archive is handed off to the simple-
-- script extractor.
function process_arcgfx(file, fileInfo)
    local nfiles = file:readU32()
    local extra = file:readU32()  -- archive-level extra field; preserved verbatim

    if VP.arguments.dump then
        mkdir(fileInfo.dir .. '/' .. fileInfo.name)
    end

    local index = {}
    for i = 1, nfiles do
        index[i] = {}
        index[i].extra = file:readU32()
        index[i].size = file:readU32()
    end

    -- Subfile content begins right after the entry table: 8 (header) + 8*nfiles.
    local offset = 8 + nfiles * 8

    local script = nil
    local font = nil

    for i = 1, nfiles do
        local subFile = file:subFile(offset, index[i].size)
        local info = deepCopy(fileInfo)
        info.dir = info.dir .. '/' .. info.name
        info.name = info.name .. string.format('-%04i-%08X', i, index[i].extra)
        info.ext = 'out'

        local f1 = bit.band(index[i].extra, 0xffffff00)
        local handler = nil
        if f1 == 0x00300900 then
            handler = function(f, _)
                if script then error "Can't have two scripts in an arcgfx" end
                script = f:dup()
            end
        elseif f1 == 0x00300800 then
            handler = function(f, _)
                if font then error "Can't have two fonts in an arcgfx" end
                font = f:dup()
            end
        end

        processOneFile(subFile, info, handler)
        offset = offset + index[i].size

        if script and font then
            extract_simple_script(
                fileInfo.dir .. '/' .. fileInfo.name .. string.format('/%04i', i),
                script, font, 'primary')
            script:close()
            font:close()
            script = nil
            font = nil
        end
    end
end
