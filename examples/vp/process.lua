function processOneFile(file, fileInfo, handler)
    mkdir(fileInfo.dir)
    local signature = file:readU32At(0)
    local isTIM = signature == 0x00000010
    if isTIM then fileInfo.ext = 'tim' end
    if isSLZ(signature) then
        print('Decompressing and processing ' .. fileInfo.name)
        local dest = Support.File.open(fileInfo.name .. '.slz', 'TRUNCATE')
        dumpFile(file, dest)
        dest:close()
        local files = slzDecompress(file)
        for k, v in pairs(files) do
            print('  Processing subfile ' .. k)
            signature = v[0] + v[1] * 256 + v[2] * 65536 + v[3] * 16777216
            local info = {}
            info.dir = fileInfo.name
            info.name = info.dir .. '/' .. string.format('%04i', fileInfo.index) .. '-' .. string.format('%02i', k)
            info.ext = signature == 0x00000010 and 'tim' or 'out'
            mkdir(info.dir)
            local dest = Support.File.open(info.name .. '.' .. info.ext, 'TRUNCATE')
            dumpFile(v, dest)
            dest:close()
            if handler then
                local file = Support.File.buffer()
                file:writeAt(v, 0)
                handler(file, info)
                file:close()
            end
        end
    else
        print('Processing file ' .. fileInfo.name)
        local dest = Support.File.open(fileInfo.name .. '.' .. fileInfo.ext, 'TRUNCATE')
        dumpFile(file, dest)
        dest:close()
        if handler then
            handler(file, fileInfo)
        end
    end
end

function processAllFiles()
    local count = VP.constants.indexCount - 1
    for i = 1, count - 1 do
        local fileIndex = VP.globals.index.entries[i]
        if fileIndex then
            local fileInfo = VP.globals.filemap[i]
            if not fileInfo then fileInfo = {} end
            if not fileInfo.ext then fileInfo.ext = 'out' end
            if not fileInfo.dir then fileInfo.dir = 'UNKNOWN' end
            fileInfo.dir = 'DUMP/' .. fileInfo.dir
            fileInfo.name = fileInfo.dir .. '/' .. string.format('%04i', i)
            local fileType = fileInfo.ftype
            local handler = nil
            if fileType then
                handler = _G['process_' .. fileType]
            end
            local mode = nil
            local sectorSize = 2048
            if fileInfo.mode then
                mode = fileInfo.mode
            end
            if fileInfo.sectorSize then
                sectorSize = fileInfo.sectorSize
            end
            fileInfo.index = i
            local file = fileIndex.iso:open(fileIndex.lba, fileIndex.size * sectorSize, mode)
            processOneFile(file, fileInfo, handler)
        end
    end
end
