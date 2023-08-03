function process_arcroom(file, fileInfo)
    local nfiles = file:readU32()
    local offset = file:readU32()

    if nfiles * 8 + 8 ~= offset then
        error 'Bad archive format'
    end

    local index = {}
    for i = 1, nfiles do
        indexData = {}
        indexData.ftype = file:readU32()
        indexData.size = file:readU32()
        indexData.file = file:subFile(offset, indexData.size)
        info = deepCopy(fileInfo)
        info.dir = info.name
        info.name = info.dir .. '/' .. string.format('%04i-%02i-%08i', info.index, i, indexData.ftype)
        info.ext = 'out'
        offset = offset + indexData.size
        indexData.info = info
        index[i] = indexData
    end

    for i = 1, nfiles do
        local handler = nil
        local script = nil
        local font = nil
        if fileInfo.ext == 'arm' and index[i].ftype == 4 then
            local counter = 1
            handler = function(file, fileInfo)
                if counter == 1 then
                    script = file
                elseif counter == 2 then
                    font = file
                else
                    error 'Too many files...'
                end
                counter = counter + 1
            end
        end
        processOneFile(index[i].file, index[i].info, handler)
    end
end
