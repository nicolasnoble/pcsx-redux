function isSLZ(signature)
    if signature == 0x005a4c53 then return true end
    if signature == 0x015a4c53 then return true end
    if signature == 0x025a4c53 then return true end
    if signature == 0x035a4c53 then return true end
    return false
end

local function slz0Decompress(file, size)
    return file:read(size)
end

local function slz1Decompress(file, sizeIn, sizeOut)
    -- print('Decompressing ' .. sizeOut .. ' bytes using scheme 1')
    local out = Support.NewLuaBuffer(sizeOut)
    local pos = 0
    local bitmap = 0x100
    while pos < sizeOut do
        if bitmap == 0x100 then
            bitmap = file:readU8()
            -- print('Read bitmap 0x' .. bit.tohex(bitmap, 2))
            bitmap = bit.bor(bitmap, 0x10000)
        end
        local compressed = bit.band(bitmap, 1) == 0
        bitmap = bit.rshift(bitmap, 1)
        if compressed then
            local info = file:readU16()
            local jump = bit.band(info, 0xfff)
            local length = bit.rshift(info, 12) + 3
            local needlePos = pos - jump
            -- print('Got 0x' .. bit.tohex(info, 4) .. ' - copying ' .. length .. ' bytes from ' .. needlePos .. ' (' .. jump .. ')')
            for i = 1, length do
                local value
                if needlePos < 0 then
                    value = 0
                else
                    value = out[needlePos]
                end
                -- print('Copying 0x' .. bit.tohex(value, 2) .. ' to 0x' .. bit.tohex(pos) .. ' from 0x' .. bit.tohex(needlePos))
                out[pos] = value
                pos = pos + 1
                needlePos = needlePos + 1
            end
        else
            local b = file:readU8()
            -- print('Copying byte 0x' .. bit.tohex(b, 2) .. ' from source to 0x' .. bit.tohex(pos))
            out[pos] = b
            pos = pos + 1
        end
    end
    return out
end

local function slz2Decompress(file, sizeIn, sizeOut)
    -- print('Decompressing ' .. sizeOut .. ' bytes using scheme 2')
    local out = Support.NewLuaBuffer(sizeOut)
    local pos = 0
    local bitmap = 0x100
    while pos < sizeOut do
        if bitmap == 0x100 then
            bitmap = file:readU8()
            -- print('Read bitmap 0x' .. bit.tohex(bitmap, 2))
            bitmap = bit.bor(bitmap, 0x10000)
        end
        local compressed = bit.band(bitmap, 1) == 0
        bitmap = bit.rshift(bitmap, 1)
        if compressed then
            local info = file:readU16()
            local length = bit.rshift(info, 12) + 3
            if length == 18 then
                length = bit.band(bit.rshift(info, 8), 0x0f) + 3
                local value = bit.band(info, 0xff)
                -- print('Got 0x' .. bit.tohex(info, 4) .. ' - repeating ' .. length .. ' times 0x' .. bit.tohex(value, 2) .. ' to 0x' .. bit.tohex(pos))
                if length == 3 then
                    length = value + 19
                    value = file:readU8()
                    -- print('Extended RLE: new length = ' .. length .. ', and new value = 0x' .. bit.tohex(value, 2))
                end
                for i = 1, length do
                    out[pos] = value
                    pos = pos + 1
                end
            else
                local jump = bit.band(info, 0xfff)
                local needlePos = pos - jump
                -- print('Got 0x' .. bit.tohex(info, 4) .. ' - copying ' .. length .. ' bytes from ' .. needlePos .. ' (' .. jump .. ')')
                for i = 1, length do
                    local value
                    if needlePos < 0 then
                        value = 0
                    else
                        value = out[needlePos]
                    end
                    -- print('Copying 0x' .. bit.tohex(value, 2) .. ' to 0x' .. bit.tohex(pos) .. ' from 0x' .. bit.tohex(needlePos))
                    out[pos] = value
                    pos = pos + 1
                    needlePos = needlePos + 1
                end
            end
        else
            local b = file:readU8()
            -- print('Copying byte 0x' .. bit.tohex(b, 2) .. ' from source to 0x' .. bit.tohex(pos))
            out[pos] = b
            pos = pos + 1
        end
    end
    return out
end

local function slz3Decompress(file, sizeIn, sizeOut)
    local compressedData = file:read(sizeIn)
    local out = Support.NewLuaBuffer(sizeOut)
    error 'Unimplemented'
end

function slzDecompress(file)
    file:rSeek(0)
    local hasMore = true
    local ret = {}
    while hasMore do
        local tell = file:rTell()
        local signature = file:readU32()
        local sizeIn = file:readU32()
        local sizeOut = file:readU32()
        local seekNext = file:readU32()
        hasMore = seekNext ~= 0
        local out
        if signature == 0x005a4c53 then
            out = slz0Decompress(file, sizeIn)
        elseif signature == 0x015a4c53 then
            out = slz1Decompress(file, sizeIn, sizeOut)
        elseif signature == 0x025a4c53 then
            out = slz2Decompress(file, sizeIn, sizeOut)
        elseif signature == 0x035a4c53 then
            out = slz3Decompress(file, sizeIn, sizeOut)
        else
            error "Not an SLZ file"
        end
        ret[#ret + 1] = out
        file:rSeek(tell + seekNext)
    end
    return ret
end
