-- Walker for .carc compressed archives. Entries are packed u32 values where
-- the high 8 bits are a type tag (1=font, 2=script, 3=nested carc) and the
-- low 24 bits are the offset to that entry's data within the archive.
-- Paired script+font entries inside one carc are handed to the simple-script
-- extractor using the 'secondary' special-code dictionary.
function process_carc(file, fileInfo)
    if VP.arguments.dump then
        mkdir(fileInfo.dir .. '/' .. fileInfo.name)
    end

    local size = file:size()
    local nfiles = file:readU32()

    local index = {}
    for i = 1, nfiles do
        local packed = file:readU32()
        index[i] = {
            extra = bit.rshift(packed, 24),
            offset = bit.band(packed, 0xffffff),
        }
    end
    -- Sentinel terminator so the last entry's size is well-defined.
    index[nfiles + 1] = { extra = 0, offset = size }

    local script = nil
    local font = nil

    for i = 1, nfiles do
        local fsize = index[i + 1].offset - index[i].offset
        local subFile = file:subFile(index[i].offset, fsize)
        local info = deepCopy(fileInfo)
        info.dir = info.dir .. '/' .. info.name
        info.name = info.name .. string.format('-%04i-%08X', i, index[i].extra)
        info.ext = 'out'

        local handler = nil
        if index[i].extra == 3 then
            -- Nested carc - recurse with this entry as a top-level carc.
            handler = function(f, fi)
                process_carc(f, fi)
            end
        elseif index[i].extra == 2 then
            handler = function(f, _)
                if script then error "Can't have two scripts in a carc" end
                script = f:dup()
            end
        elseif index[i].extra == 1 then
            handler = function(f, _)
                if font then error "Can't have two fonts in a carc" end
                font = f:dup()
            end
        end

        processOneFile(subFile, info, handler)

        if script and font then
            extract_simple_script(
                fileInfo.dir .. '/' .. fileInfo.name .. string.format('/%04i', i),
                script, font, 'secondary')
            script:close()
            font:close()
            script = nil
            font = nil
        end
    end
end
