-- SLZ containers: N chunks, each a 16-byte header (signature, sizeIn,
-- sizeOut, seekNext) followed by its payload, the last one with seekNext == 0.
--
-- SLZ1 and SLZ2 are LZSS variants, described here as grammars for
-- PCSX.Compression. The same schema object decodes and encodes, so the packer
-- and the reader cannot disagree about the format.
--
--   JJJJJJJJ LLLLJJJJ            match:     dist = b0 | (b1 & 0x0f) << 8, len = (b1 >> 4) + 3
--   VVVVVVVV 1111RRRR            fill:      len nibble == 0xF, val = b0, run = (b1 & 0x0f) + 3
--   RRRRRRRR 11110000 VVVVVVVV   long fill: len nibble == 0xF and run nibble == 0,
--                                           run = b0 + 19, val = b2
--
-- SLZ1 has no fill and runs until a zero-distance token, with no bound on its
-- destination: the game's decoder stops on that token and nothing else. So
-- the encoder has to emit it, and does, as an ordinary item taking a flag bit.
-- SLZ2 has both fills and stops on the output length, so it has no
-- terminator. A match reaching before the start of the output reads zeroes.

VP.slz = VP.slz or {}

local MATCH = {
    bytes = 2,
    match = { len = { at = { 1, 0xf0, -4 }, bias = 3 }, dist = { at = { { 0, 0xff, 0 }, { 1, 0x0f, 8 } } } },
}

local CONTROL = { unit = 1, perGroup = 8, lsbFirst = true, oneMeans = 'literal' }
local WINDOW = { base = 'relative', maxDist = 0x0fff, fillByte = 0, overlap = true }

-- The game's own compressor never reached further back than 4096 minus the
-- longest match. The decoders do not need that bound, but staying inside it
-- keeps the output inside what the original discs exercised.
VP.slz.SLZ1 = PCSX.Compression.schema {
    name = 'SLZ1',
    control = CONTROL,
    window = WINDOW,
    emit = { ringSize = 4096, terminator = true },
    productions = {
        { bytes = 2, guards = { { at = { { 0, 0xff, 0 }, { 1, 0x0f, 8 } }, eq = 0 } }, stop = true },
        MATCH,
    },
}

VP.slz.SLZ2 = PCSX.Compression.schema {
    name = 'SLZ2',
    control = CONTROL,
    window = WINDOW,
    emit = { ringSize = 4096 },
    productions = {
        {
            bytes = 3,
            guards = { { at = { 1, 0xf0, -4 }, eq = 0x0f }, { at = { 1, 0x0f }, eq = 0 } },
            fill = { run = { at = { 0, 0xff }, bias = 19 }, value = { at = { 2, 0xff } } },
        },
        {
            bytes = 2,
            guards = { { at = { 1, 0xf0, -4 }, eq = 0x0f } },
            fill = { run = { at = { 1, 0x0f }, bias = 3 }, value = { at = { 0, 0xff } } },
        },
        MATCH,
    },
}

VP.slz.signatures = {
    [0x005a4c53] = 0,
    [0x015a4c53] = 1,
    [0x025a4c53] = 2,
    [0x035a4c53] = 3,
}

function isSLZ(signature) return VP.slz.signatures[signature] ~= nil end

local function toBuffer(str)
    local f = Support.File.buffer()
    f:write(str)
    f:rSeek(0)
    local buf = f:read(#str)
    f:close()
    return buf
end

-- Returns the raw chunks of an SLZ container: { scheme, sizeIn, sizeOut, data },
-- with data the payload as a string.
function VP.slz.chunks(file)
    file:rSeek(0)
    local ret = {}
    while true do
        local tell = file:rTell()
        local signature = file:readU32()
        local scheme = VP.slz.signatures[signature]
        if not scheme then error 'Not an SLZ file' end
        local sizeIn = file:readU32()
        local sizeOut = file:readU32()
        local seekNext = file:readU32()
        ret[#ret + 1] = { scheme = scheme, sizeIn = sizeIn, sizeOut = sizeOut, data = tostring(file:read(sizeIn)) }
        if seekNext == 0 then break end
        file:rSeek(tell + seekNext)
    end
    return ret
end

-- Decodes one chunk to a string.
function VP.slz.decode(chunk)
    if chunk.scheme == 0 then return chunk.data end
    if chunk.scheme == 3 then
        -- SLZ3 wraps a raw UCL-NRV2E payload. The retail game has no decoder
        -- for it: the translation's patched executable adds one.
        local out = Support.NewLuaBuffer(chunk.sizeOut)
        PCSX.Misc.uclUnpack(chunk.data, chunk.sizeOut, out)
        return tostring(out)
    end
    local schema = chunk.scheme == 1 and VP.slz.SLZ1 or VP.slz.SLZ2
    local plain = schema:decode(chunk.data, chunk.sizeOut)
    if #plain ~= chunk.sizeOut then
        error(string.format('SLZ%d chunk decoded to %d bytes, expected %d', chunk.scheme, #plain, chunk.sizeOut))
    end
    return plain
end

-- Encodes plaintext under scheme 1 or 2.
function VP.slz.encode(scheme, plain)
    local schema = scheme == 1 and VP.slz.SLZ1 or VP.slz.SLZ2
    return schema:encode(plain)
end

-- Returns the decompressed chunks as LuaBuffers.
function slzDecompress(file)
    local ret = {}
    for i, chunk in ipairs(VP.slz.chunks(file)) do ret[i] = toBuffer(VP.slz.decode(chunk)) end
    return ret
end
