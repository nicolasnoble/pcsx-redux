-- In-game preview of translations, with no disc rebuild.
--
-- The field executable (file 2292) loads a room's script from the tag 4
-- member of the room archive, in its room-archive switch (case 4 at
-- 0x8006bdac): 0x8001226c mallocs the chunk's decompressed size, 0x800122c0
-- decompresses the script into it and the pointer is stored at 0x8007f1ac.
-- After the font chunk, the game derives the pointer table and the strings
-- base from the script's own header, so a script rebuilt with a different
-- layout is followed as long as its header is right.
--
-- Two breakpoints do the patching. At malloc's entry, when it is called by the
-- chunk allocator on behalf of case 4 chunk 0, the compressed chunk is decoded
-- here, its key looked up, the translated script rebuilt, and the allocation
-- grown to fit it. Once the chunk is decompressed, the rebuilt script is
-- written over it.
--
-- Breakpoints only fire with the debugger enabled.

VP.preview = VP.preview or {}
local preview = VP.preview
local ffi = require('ffi')

local MALLOC = 0x8001fd80
local ALLOC_RETURN = 0x800122b0 -- return address of the malloc call in 0x8001226c
local CASE4_SCRIPT_ALLOC = 0x8006bdc0 -- return address of case 4's chunk 0 allocation
local CASE4_SCRIPT_DONE = 0x8006bde0 -- after case 4's chunk 0 decompression
local SCRIPT_PTR = 0x8007f1ac
local HEADER_SIZE = 28
local DIGITS_SIZE = 0x33

-- Splits a room script (a string) into its parts.
function preview.parse(s)
    local u32 = function(o) return ffi.cast('uint32_t*', ffi.cast('const char*', s) + o)[0] end
    local sizeLogic, nPtrs, strLen = u32(0), u32(12), u32(16)
    local ptrBase = HEADER_SIZE + sizeLogic
    local strBase = ptrBase + 2 * nPtrs
    if strBase + strLen ~= #s then
        error(string.format('Not a room script: %d bytes, header says %d', #s, strBase + strLen))
    end
    local ptrs = {}
    for i = 1, nPtrs do ptrs[i] = s:byte(ptrBase + 2 * i - 1) + 256 * s:byte(ptrBase + 2 * i) end
    return {
        header = s:sub(1, HEADER_SIZE),
        logic = s:sub(HEADER_SIZE + 1, ptrBase),
        ptrs = ptrs,
        strings = s:sub(strBase + 1),
        nPtrs = nPtrs,
    }
end

local function stringAt(strings, offset)
    -- A two-byte value can end in a zero byte, so the decoder finds the end.
    local buf = Support.File.buffer()
    buf:write(strings)
    buf:rSeek(offset)
    VP.text.decodeTokens(buf, 'primary')
    local stop2 = tonumber(buf:rTell())
    buf:close()
    return strings:sub(offset + 1, stop2)
end

local function encode(tokens)
    local t = {}
    for i, tok in ipairs(tokens) do t[i] = tok end
    local body = VP.text.encodeTokens(t, 'primary')
    return body .. (tokens.terminated == 'wide' and '\128\0' or '\0')
end

local function patchWord(logic, site, value)
    local o = site.pc * 4
    local w = ffi.cast('uint32_t*', ffi.cast('const char*', logic) + o)[0]
    if site.kind == 'psh' then
        if value < 0 or value >= 0x800000 then error('value out of range: ' .. value) end
        w = bit.bor(bit.band(w, 0xff800000), value)
    elseif site.kind == 'lo' then
        if value < 0 or value > 0xffff then error('value out of range: ' .. value) end
        w = bit.bor(bit.band(w, 0xffff0000), value)
    else
        if value < 0 or value > 0xffff then error('value out of range: ' .. value) end
        w = bit.bor(bit.band(w, 0xffff), bit.lshift(value, 16))
    end
    local word = ffi.new('uint32_t[1]', w)
    return logic:sub(1, o) .. ffi.string(word, 4) .. logic:sub(o + 5)
end

-- Rebuilds a room script with translations. rows maps a pointer index to a
-- row ({ tokens, boxX, boxY, boxW, boxH }). Returns the new script and a list
-- of problems (box overrides that could not be applied); errors on anything
-- that would make the script unloadable.
function preview.rebuild(original, rows)
    local p = preview.parse(original)
    local problems = {}
    local logic = p.logic

    local boxFields = { { 'boxX', 'x' }, { 'boxY', 'y' }, { 'boxW', 'width' }, { 'boxH', 'height' } }
    local needBoxes = false
    for _, row in pairs(rows) do
        for _, f in ipairs(boxFields) do if row[f[1]] then needBoxes = true end end
    end
    if needBoxes then
        local buf = Support.File.buffer()
        buf:write(logic)
        local textboxes = VP.room.textboxes(buf, 3)
        buf:close()
        for idx, row in pairs(rows) do
            for _, f in ipairs(boxFields) do
                local value = row[f[1]]
                if value then
                    local tb = textboxes[idx]
                    local sites = tb and tb.sites or {}
                    if #sites == 0 then
                        problems[#problems + 1] = string.format('pointer %d: no textbox in the logic opens it, %s not applied', idx, f[2])
                    end
                    for _, site in ipairs(sites) do
                        if site[f[2]] then
                            logic = patchWord(logic, site[f[2]], value)
                        else
                            problems[#problems + 1] = string.format('pointer %d: %s is computed at run time, not applied', idx, f[2])
                        end
                    end
                end
            end
        end
    end

    -- Strings: the 0x33 digit table and the sentinel slots 1 and 2 stay as
    -- they are; every real string is re-laid out in pointer order.
    local strings = { p.strings:sub(1, DIGITS_SIZE) }
    local offset = DIGITS_SIZE
    local ptrs = { p.ptrs[1], p.ptrs[2] }
    for i = 3, p.nPtrs do
        local bytes
        if rows[i] and rows[i].tokens then
            bytes = encode(rows[i].tokens)
        else
            bytes = stringAt(p.strings, p.ptrs[i])
        end
        if offset > 0xffff then error(string.format('strings are %d bytes, past the 64 KiB a pointer reaches', offset)) end
        ptrs[i] = offset
        strings[#strings + 1] = bytes
        offset = offset + #bytes
    end
    local stringBytes = table.concat(strings)

    local header = ffi.new('uint32_t[7]')
    ffi.copy(header, p.header, HEADER_SIZE)
    -- Red arm for preview-test.lua: leave the strings length stale.
    if os.getenv('VP_PREVIEW_RED') ~= '1' then header[4] = #stringBytes end
    local ptrBytes = ffi.new('uint16_t[?]', p.nPtrs)
    for i = 1, p.nPtrs do ptrBytes[i - 1] = ptrs[i] end
    return ffi.string(header, HEADER_SIZE) .. logic .. ffi.string(ptrBytes, 2 * p.nPtrs) .. stringBytes, problems
end

-- The rows to apply for a script key: every non-deleted row with tokens.
-- The source hash is not checked here: the key already names the exact source.
function preview.rowsFor(db, key)
    local rows, n = {}, 0
    for row in db:query({ script = key }) do
        if not row.deletedAt and row.tokens and row.status ~= VP.tdb.status.untranslated then
            rows[row.idx] = row
            n = n + 1
        end
    end
    return rows, n
end

-- Rebuilt scripts by key, so a room entered twice is rebuilt once per change.
preview.cache = preview.cache or {}
preview.log = preview.log or {}

local function note(s)
    local log = preview.log
    log[#log + 1] = s
    if #log > 200 then table.remove(log, 1) end
end

function preview.invalidate(key)
    if key then preview.cache[key] = nil else preview.cache = {} end
end

-- Returns the rebuilt script for an original, or nil when nothing applies.
function preview.patched(original)
    local key = VP.text.fnv1a64(original)
    local cached = preview.cache[key]
    if cached then return cached.bytes, key, cached end
    local db = preview.db
    if not db then return nil, key end
    local rows, n = preview.rowsFor(db, key)
    local entry = { n = n }
    if n > 0 then
        local ok, bytes, problems = pcall(preview.rebuild, original, rows)
        if ok then
            entry.bytes, entry.problems = bytes, problems
        else
            entry.error = bytes
        end
    end
    preview.cache[key] = entry
    return entry.bytes, key, entry
end

local mem = PCSX.getMemPtr()
local function r32(a) return ffi.cast('uint32_t*', mem + bit.band(a, 0x1ffffc))[0] end

local pending

local function onMalloc()
    local regs = PCSX.getRegisters()
    if regs.GPR.n.ra ~= ALLOC_RETURN then return true end
    if r32(regs.GPR.n.sp + 24) ~= CASE4_SCRIPT_ALLOC then return true end
    pending = nil
    local chunkAddress = regs.GPR.n.a1
    local scheme = VP.slz.signatures[r32(chunkAddress)]
    if not scheme then
        note(string.format('script chunk at %08x has no SLZ signature', chunkAddress))
        return true
    end
    local sizeIn, sizeOut = r32(chunkAddress + 4), r32(chunkAddress + 8)
    local ok, original = pcall(VP.slz.decode, {
        scheme = scheme, sizeIn = sizeIn, sizeOut = sizeOut,
        data = ffi.string(mem + bit.band(chunkAddress + 16, 0x1fffff), sizeIn),
    })
    if not ok then
        note('decoding the script chunk failed: ' .. tostring(original))
        return true
    end
    local bytes, key, entry = preview.patched(original)
    if entry and entry.error then note('script ' .. key .. ': not patched, ' .. entry.error) end
    if not bytes then return true end
    pending = { key = key, bytes = bytes, size = sizeOut, original = original }
    -- Rounded up to a word, and never smaller than what the game would read.
    local want = math.max(sizeOut, bit.band(#bytes + 3, bit.bnot(3)))
    regs.GPR.n.a0 = want
    note(string.format('script %s: %d strings translated, buffer %d -> %d bytes', key, entry.n, sizeOut, want))
    return true
end

local function onScriptDone()
    if not pending then return true end
    local p = pending
    pending = nil
    local buf = r32(SCRIPT_PTR)
    if buf == 0 then
        note('script ' .. p.key .. ': the game got no buffer, not patched')
        return true
    end
    -- What the game just decompressed must be the script the rebuild came from.
    local got = ffi.string(mem + bit.band(buf, 0x1fffff), p.size)
    if got ~= p.original then
        note(string.format('script %s: buffer at %08x does not hold the decoded script, not patched', p.key, buf))
        return true
    end
    ffi.copy(mem + bit.band(buf, 0x1fffff), p.bytes, #p.bytes)
    preview.lastPatch = { key = p.key, address = buf, size = #p.bytes, cycle = PCSX.getCPUCycles() }
    note(string.format('script %s: patched at %08x, %d bytes', p.key, buf, #p.bytes))
    return true
end

-- db: a VP.tdb database. Arms the two breakpoints.
function preview.arm(db)
    preview.disarm()
    preview.db = db
    preview.invalidate()
    preview.breakpoints = {
        PCSX.addBreakpoint(MALLOC, 'Exec', 4, 'VP preview', onMalloc, 'script alloc'),
        PCSX.addBreakpoint(CASE4_SCRIPT_DONE, 'Exec', 4, 'VP preview', onScriptDone, 'script loaded'),
    }
end

function preview.disarm()
    if preview.breakpoints then
        for _, bp in ipairs(preview.breakpoints) do bp:remove() end
    end
    preview.breakpoints = nil
    pending = nil
end

function preview.armed() return preview.breakpoints ~= nil end
