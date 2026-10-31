-- Recompresses every SLZ1/SLZ2 chunk on a Valkyrie Profile disc with the
-- schemas in slz.lua, then decodes each one with the game's OWN decompressor,
-- run inside the emulator with PCSX.callGuest. A chunk passes when the guest
-- output equals the original plaintext and the decoder wrote nothing outside
-- its destination buffer.
--
--   VP_DISC1=<disc.cue> pcsx-redux -cli -interpreter -bios <openbios.bin> \
--       -dofile examples/vp/recompress-test.lua
--
-- The recompressed streams need not match the disc bytes; they only have to
-- decode correctly in the game. Writes are checked two ways: the pages around
-- the destination are filled with a position-dependent pattern before each
-- call and must come back intact outside the destination, and every page the
-- call changed must lie inside that patterned span.
--
-- VP_DISC1 names the .cue; the .bin next to it is scanned. VP_LIMIT=<n> stops
-- after n chunks.

local here = debug.getinfo(1, 'S').source:match('^@(.*/)') or './'
Support.extra.dofile(here .. 'browser.lua')
local ffi = require 'ffi'

local function fail(msg)
    print('FAIL: ' .. msg)
    PCSX.quit(1)
end

-- Decoder entry points, read from the executable's disassembly. The first
-- argument is unused by both; SLZ1 stops on its terminator token and takes no
-- length, SLZ2 takes the output length in $a3.
local DECODERS = {
    ['SLUS_011.56'] = { [1] = 0x800123cc, [2] = 0x80012874 },
}

local SRC = 0x80040000
local DST = 0x800d0000
local STUB = 0x80180000
local GUARD = 0x1000
local PAGE = 0x10000
local TAIL = string.rep('\xff', 256)

local path = os.getenv('VP_DISC1')
local iso = PCSX.openIso(path)
local disc = VP.vfs.identify(iso)
if not disc then return fail('not identified as Valkyrie Profile: ' .. tostring(path)) end
local entries = DECODERS[disc.exe]
if not entries then return fail('no decoder addresses known for ' .. disc.exe) end
print(string.format('disc: %s %s disc %d', disc.exe, disc.region, disc.disc))

local mem = ffi.cast('uint8_t*', PCSX.getMemPtr())
local function ram(addr) return mem + (addr - 0x80000000) end

-- Load the executable's text where it runs.
local reader = iso:createReader()
local exeFile = reader:open(disc.exe .. ';1')
local exe = tostring(exeFile:read(exeFile:size()))
exeFile:close()
local function u32(s, off) return s:byte(off + 1) + s:byte(off + 2) * 256 + s:byte(off + 3) * 65536 + s:byte(off + 4) * 16777216 end
local textAddr, textSize = u32(exe, 0x18), u32(exe, 0x1c)
if #exe < 0x800 + textSize then return fail('executable shorter than its header says') end
if textAddr + textSize > SRC then return fail(string.format('text 0x%08x+0x%x runs into the staging area', textAddr, textSize)) end
ffi.copy(ram(textAddr), exe:sub(0x801, 0x800 + textSize), textSize)
print(string.format('text: 0x%08x, 0x%x bytes', textAddr, textSize))

-- A cold machine has the caches isolated, which drops every guest store. This
-- is the BIOS reset code's BIU write.
do
    local p = ffi.cast('uint32_t*', ram(STUB))
    for i, w in ipairs({ 0x3c080001, 0x3508e988, 0x3c01fffe, 0xac280130, 0x03e00008, 0x00000000 }) do p[i - 1] = w end
    local r = PCSX.callGuest { pc = STUB }
    if r.status ~= 'returned' or r.storesDropped then return fail('could not enable guest stores') end
end

-- The guard pattern, a function of the address so that a stray write of a
-- constant is unlikely to land on its own value.
local PATTERN_BASE = DST - PAGE
local PATTERN_END = STUB
local pattern
do
    local t = {}
    for a = PATTERN_BASE, PATTERN_END - 1 do t[#t + 1] = string.char(bit.band(bit.bxor(a, bit.rshift(a, 8)) * 0x9d + 0x5a, 0xff)) end
    pattern = table.concat(t)
end
local function patternAt(a, n) return pattern:sub(a - PATTERN_BASE + 1, a - PATTERN_BASE + n) end

local function floorPage(a) return a - a % PAGE end
local function ceilPage(a) return floorPage(a + PAGE - 1) end

-- Runs the game's decoder on one stream. Returns true, or false and a reason.
local function guestDecode(scheme, packed, plain)
    local sizeOut = #plain
    local span0, span1 = floorPage(DST - GUARD), ceilPage(DST + sizeOut + GUARD)
    if SRC + #packed + #TAIL > span0 or span1 > PATTERN_END then return nil, 'too large for the staging layout' end
    local r = PCSX.callGuest {
        pc = entries[scheme],
        args = { 0, SRC, DST, sizeOut },
        isolate = 'ram',
        cycles = 100 * sizeOut + 1000000,
        stage = { { addr = SRC, data = packed .. TAIL }, { addr = span0, data = patternAt(span0, span1 - span0) } },
        fetch = { { addr = span0, size = span1 - span0 } },
    }
    if r.status ~= 'returned' then return false, 'status ' .. r.status end
    if r.storesDropped then return false, 'stores dropped' end
    if r.nonRamAccesses ~= 0 then return false, r.nonRamAccesses .. ' non-RAM accesses' end
    local out = r.out[1]
    local before = DST - span0
    if out:sub(1, before) ~= patternAt(span0, before) then return false, 'wrote below the destination' end
    if out:sub(before + sizeOut + 1) ~= patternAt(DST + sizeOut, span1 - DST - sizeOut) then
        return false, 'wrote past the end of the destination'
    end
    for _, page in ipairs(r.dirty) do
        if page < span0 or page >= span1 then return false, string.format('wrote page 0x%08x', page) end
    end
    if out:sub(before + 1, before + sizeOut) ~= plain then return false, 'output differs' end
    return true
end

local limit = tonumber(os.getenv('VP_LIMIT') or '')
local stats = { total = 0, pass = 0, readerPass = 0, skip = 0, hostFail = 0, [1] = { n = 0, pass = 0, packed = 0, disc = 0 }, [2] = { n = 0, pass = 0, packed = 0, disc = 0 } }
local failures = {}
local redSamples = { [1] = {}, [2] = {} }

local function testChunk(chunk, where, plain)
    plain = plain or VP.slz.decode(chunk)
    if chunk.scheme ~= 1 and chunk.scheme ~= 2 then return plain end
    if limit and stats.total >= limit then return plain end
    local s = stats[chunk.scheme]
    stats.total = stats.total + 1
    s.n = s.n + 1
    -- The reader too: the game must decode the disc's own bytes to the same
    -- plaintext the schema produced from them.
    if guestDecode(chunk.scheme, chunk.data, plain) then stats.readerPass = stats.readerPass + 1 end
    local packed = VP.slz.encode(chunk.scheme, plain)
    s.packed = s.packed + #packed
    s.disc = s.disc + #chunk.data
    local schema = chunk.scheme == 1 and VP.slz.SLZ1 or VP.slz.SLZ2
    if schema:decode(packed, #plain) ~= plain then stats.hostFail = stats.hostFail + 1 end
    local ok, why = guestDecode(chunk.scheme, packed, plain)
    if ok == nil then
        stats.skip = stats.skip + 1
        failures[#failures + 1] = where .. ': skipped, ' .. why
    elseif ok then
        stats.pass = stats.pass + 1
        s.pass = s.pass + 1
        if #redSamples[chunk.scheme] < 25 and #packed > 32 then
            redSamples[chunk.scheme][#redSamples[chunk.scheme] + 1] = { packed = packed, plain = plain, where = where }
        end
    else
        failures[#failures + 1] = where .. ': ' .. why
    end
    if stats.total % 500 == 0 then
        print(string.format('progress: %d chunks, %d pass, %d fail', stats.total, stats.pass, #failures))
    end
    return plain
end

local function testContainer(file, where)
    for i, chunk in ipairs(VP.slz.chunks(file)) do
        local plain = testChunk(chunk, where .. '#' .. i)
        if #plain >= 4 and isSLZ(u32(plain, 0)) then
            local f = Support.File.buffer()
            f:writeAt(plain, 0)
            testContainer(f, where .. '#' .. i)
            f:close()
        end
    end
end

-- Every SLZ1/SLZ2 chunk on the disc. The game index only reaches top-level
-- files and most chunks sit inside archives, so read the data bytes of every
-- Form 1 sector in order and look for chunk headers instead. A header counts
-- as a chunk when its payload decodes to exactly sizeOut bytes without reading
-- past sizeIn. Chunks nested inside a decompressed chunk are tested too.
local bin = path:gsub('%.cue$', '.bin')
local raw = Support.File.open(bin)
if raw:failed() then return fail('cannot open ' .. bin) end
local stream = Support.File.buffer()
do
    local BLOCK = 64
    local nsec = math.floor(raw:size() / 2352)
    for s0 = 0, nsec - 1, BLOCK do
        local n = math.min(BLOCK, nsec - s0)
        raw:rSeek(s0 * 2352)
        local frames = tostring(raw:read(n * 2352))
        local parts = {}
        for i = 0, n - 1 do
            local base = i * 2352
            -- subheader submode byte; bit 5 set means Form 2
            if bit.band(frames:byte(base + 19), 0x20) == 0 then parts[#parts + 1] = frames:sub(base + 25, base + 2072) end
        end
        stream:write(table.concat(parts))
    end
end
raw:close()
local streamSize = stream:size()
print(string.format('Form 1 data: %d bytes', streamSize))

local candidates, rejected = 0, 0
local WINDOW = 8 * 1024 * 1024
for w0 = 0, streamSize - 1, WINDOW do
    stream:rSeek(w0)
    local win = tostring(stream:read(math.min(WINDOW + 3, streamSize - w0)))
    local at = 1
    while true do
        local hit = win:find('SLZ[\1\2]', at)
        if not hit or hit > WINDOW then break end
        at = hit + 1
        local o = w0 + hit - 1
        if o + 16 <= streamSize then
            candidates = candidates + 1
            local scheme = stream:readU8At(o + 3)
            local sizeIn, sizeOut = stream:readU32At(o + 4), stream:readU32At(o + 8)
            local ok = false
            if sizeIn > 0 and sizeOut > 0 and sizeIn <= 0x80000 and sizeOut <= 0x80000 and o + 16 + sizeIn <= streamSize then
                stream:rSeek(o + 16)
                local chunk = { scheme = scheme, sizeIn = sizeIn, sizeOut = sizeOut, data = tostring(stream:read(sizeIn)) }
                local schema = scheme == 1 and VP.slz.SLZ1 or VP.slz.SLZ2
                local good, plain, _, consumed = pcall(schema.decode, schema, chunk.data, sizeOut)
                if good and #plain == sizeOut and consumed <= sizeIn then
                    ok = true
                    local where = string.format('0x%08x', o)
                    testChunk(chunk, where, plain)
                    if #plain >= 4 and isSLZ(u32(plain, 0)) then
                        local f = Support.File.buffer()
                        f:writeAt(plain, 0)
                        testContainer(f, where)
                        f:close()
                    end
                end
            end
            if not ok then rejected = rejected + 1 end
        end
    end
end
stream:close()
print(string.format('headers found: %d, rejected as not a chunk: %d', candidates, rejected))

-- Red arms: the same oracle must reject a broken stream. A flipped byte in the
-- middle of a stream must decode wrong or misbehave, and an SLZ1 stream with
-- its terminator token cut off must be caught running past its destination
-- and nothing else
-- (the staged tail after the stream is 0xff, which is no terminator).
local red = { flipped = 0, flippedCaught = 0, cut = 0, cutCaught = 0 }
for scheme = 1, 2 do
    for _, smp in ipairs(redSamples[scheme]) do
        local p = smp.packed
        local mid = math.floor(#p / 2)
        local flipped = p:sub(1, mid) .. string.char(bit.bxor(p:byte(mid + 1), 0x5a)) .. p:sub(mid + 2)
        red.flipped = red.flipped + 1
        if not guestDecode(scheme, flipped, smp.plain) then red.flippedCaught = red.flippedCaught + 1 end
        if scheme == 1 then
            red.cut = red.cut + 1
            -- The terminator is the last two bytes of the stream. Without it the
            -- output itself is right; only the overrun gives it away.
            local ok, why = guestDecode(scheme, p:sub(1, #p - 2), smp.plain)
            if ok == false and (why:find('past the end') or why:find('wrote page') or why == 'status cycles') then
                red.cutCaught = red.cutCaught + 1
            end
            if red.cut <= 3 then print('red cut ' .. smp.where .. ': ' .. tostring(why)) end
        end
    end
end

for scheme = 1, 2 do
    local s = stats[scheme]
    print(string.format('SLZ%d: %d/%d PASS, recompressed %d bytes vs %d on disc (%.4f)', scheme, s.pass, s.n, s.packed,
                        s.disc, s.disc > 0 and s.packed / s.disc or 0))
end
print(string.format('host round trip failures: %d', stats.hostFail))
print(string.format('disc streams decoded by the game to the schema output: %d/%d', stats.readerPass, stats.total))
for i = 1, math.min(#failures, 30) do print('failure: ' .. failures[i]) end
print(string.format('red: flipped %d/%d caught, terminator cut %d/%d caught', red.flippedCaught, red.flipped,
                    red.cutCaught, red.cut))
local green = stats.total > 0 and stats.pass == stats.total and stats.hostFail == 0 and stats.readerPass == stats.total
local redOk = red.flipped > 0 and red.flippedCaught == red.flipped and red.cut > 0 and red.cutCaught == red.cut
print(string.format('RESULT: %d/%d chunks PASS, red arms %s', stats.pass, stats.total, redOk and 'all caught' or 'NOT all caught'))
PCSX.quit((green and redOk) and 0 or 1)
