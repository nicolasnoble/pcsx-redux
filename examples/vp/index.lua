VP.globals.index = { seeds = {}, keys = {}, entries = {} }

local function readIndexForIso(iso)
    local clocs = iso:open(VP.constants.indexSector, VP.constants.indexCount * 4)
    local csize = iso:open(VP.constants.indexSector + VP.constants.indexCount * 4 / 2048, VP.constants.indexCount)
    clocs:rSeek(-VP.constants.indexLocsKeySize, 'SEEK_END')
    csize:rSeek(-VP.constants.indexSizeKeySize, 'SEEK_END')
    VP.globals.index.keys.locs = clocs:read(VP.constants.indexLocsKeySize)
    VP.globals.index.keys.size = csize:read(VP.constants.indexSizeKeySize)

    local pos = 1
    VP.globals.index.seeds.locs = clocs:readU32At(0)
    VP.globals.index.seeds.size = csize:readU8At(0)
    local count = VP.constants.indexCount - 1
    for i = 1, count do
        local k = {}
        k[1] = VP.globals.index.keys.locs[(pos * 4 + 0) % VP.constants.indexLocsKeySize]
        k[2] = VP.globals.index.keys.locs[(pos * 4 + 1) % VP.constants.indexLocsKeySize]
        k[3] = VP.globals.index.keys.locs[(pos * 4 + 2) % VP.constants.indexLocsKeySize]
        k[4] = VP.globals.index.keys.locs[(pos * 4 + 3) % VP.constants.indexLocsKeySize]
        k[5] = VP.globals.index.keys.size[pos % VP.constants.indexSizeKeySize]
        local b = {}
        b[1] = bit.bxor(k[1], clocs:readU8At(pos * 4 + 0))
        b[2] = bit.bxor(k[2], clocs:readU8At(pos * 4 + 1))
        b[3] = bit.bxor(k[3], clocs:readU8At(pos * 4 + 2))
        b[4] = bit.bxor(k[4], clocs:readU8At(pos * 4 + 3))
        b[5] = bit.bxor(k[5], csize:readU8At(pos))
        local lba = PCSX.isoTools.fromMSF(b[1], b[2], b[3])
        local size = b[4] * 256 + b[5]
        if lba >= 0 then
            VP.globals.index.entries[pos] = {
                lba = lba,
                size = size,
                iso = iso,
            }
        end
        pos = pos + 1
    end
end

function readIndex()
    if VP.globals.isos.US.CD1 then
        readIndexForIso(VP.globals.isos.US.CD1.iso)
    end
    if VP.globals.isos.US.CD2 then
        readIndexForIso(VP.globals.isos.US.CD2.iso)
    end
end
