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
-- Chunk 1 of the same member is the room's font, which holds only the glyphs
-- the room uses, so a translation can need glyphs added to it.
--
-- Three breakpoints do the patching. At malloc's entry, when it is called by
-- the chunk allocator on behalf of case 4 chunk 0, both compressed chunks are
-- decoded here, the script's key looked up, the font extended and the script
-- rebuilt, and the allocation grown to fit; the font's allocation is grown
-- the same way when its turn comes. Once each chunk is decompressed, the
-- rebuilt one is written over it, after checking the buffer holds exactly
-- what the rebuild started from.
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
local CASE4_FONT_ALLOC = 0x8006bdf4 -- return address of case 4's chunk 1 (font) allocation
local CASE4_FONT_DONE = 0x8006be14 -- after case 4's chunk 1 decompression
local FONT_PTR = 0x8007f1d8
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

-- A room's font (chunk 1 of the same member): u32 count, u32 height,
-- u8 widths[count], then count bitmaps of height u16 rows. Glyph index g in a
-- string is the g-th glyph of this font.
function preview.parseFont(s)
    local u32 = function(o) return ffi.cast('uint32_t*', ffi.cast('const char*', s) + o)[0] end
    local count, height = u32(0), u32(4)
    if 8 + count + count * height * 2 ~= #s then error('Not a room font: ' .. #s .. ' bytes') end
    local font = { height = height, widths = {}, bitmaps = {}, index = {} }
    for i = 1, count do
        font.widths[i] = s:byte(8 + i)
        font.bitmaps[i] = s:sub(9 + count + (i - 1) * height * 2, 8 + count + i * height * 2)
        local k = font.widths[i] .. '-' .. font.bitmaps[i]
        if font.widths[i] > 0 and not font.index[k] then font.index[k] = i end
    end
    return font
end

function preview.buildFont(font)
    local count = #font.widths
    local head = ffi.new('uint32_t[2]', count, font.height)
    local widths = {}
    for i = 1, count do widths[i] = string.char(font.widths[i]) end
    return ffi.string(head, 8) .. table.concat(widths) .. table.concat(font.bitmaps)
end

-- Turns the { ch } tokens of rows into { g } tokens of the room's font, adding
-- glyphs from charset that the room does not have. charset is the database's
-- target language (tdb:charset), the whole font database when nil. Returns the
-- new rows, the new font bytes (nil when unchanged) and the number of glyphs
-- added.
function preview.resolveChars(rows, fontBytes, charset)
    charset = charset or VP.constants.font
    local font = preview.parseFont(fontBytes)
    local added = 0
    local out = {}
    for idx, row in pairs(rows) do
        local r = {}
        for k, v in pairs(row) do r[k] = v end
        local toks = { terminated = row.tokens.terminated }
        for i, t in ipairs(row.tokens) do
            if t.ch then
                local g = charset[t.ch]
                if not g then error(string.format('pointer %d: no glyph for %s in the target language', idx, t.ch)) end
                if g.height ~= font.height then error('pointer ' .. idx .. ': glyph height does not match the room font') end
                local bitmap = base64.decode(g.data)
                local k = g.width .. '-' .. bitmap
                local n = font.index[k]
                if not n then
                    font.widths[#font.widths + 1] = g.width
                    font.bitmaps[#font.bitmaps + 1] = bitmap
                    n = #font.widths
                    font.index[k] = n
                    added = added + 1
                end
                toks[i] = { g = n }
            else
                toks[i] = t
            end
        end
        r.tokens = toks
        out[idx] = r
    end
    if added == 0 then return out, nil, 0 end
    -- The bitmaps follow the widths, so an odd count would misalign them.
    if #font.widths % 2 == 1 then
        font.widths[#font.widths + 1] = 0
        font.bitmaps[#font.bitmaps + 1] = string.rep('\0', font.height * 2)
    end
    return out, preview.buildFont(font), added
end

preview.log = preview.log or {}

local function note(s)
    local log = preview.log
    log[#log + 1] = s
    if #log > 200 then table.remove(log, 1) end
end

-- The patch for a room's original script and font, read from the database
-- every time the room loads, so a save shows the next time the room is entered:
-- { key, n, script, font, added, problems, error }, script nil when nothing applies.
function preview.patched(script, font)
    local key = VP.text.fnv1a64(script)
    local entry = { key = key, n = 0 }
    local db = preview.db
    if not db then return entry end
    local rows, n = preview.rowsFor(db, key)
    entry.n = n
    if n == 0 then return entry end
    local ok, err = pcall(function()
        local resolved, newFont, added = preview.resolveChars(rows, font, db.charset and db:charset())
        local bytes, problems = preview.rebuild(script, resolved)
        entry.script, entry.font, entry.added, entry.problems = bytes, newFont, added, problems
    end)
    if not ok then entry.error = tostring(err) end
    return entry
end

local mem = PCSX.getMemPtr()
local function r32(a) return ffi.cast('uint32_t*', mem + bit.band(a, 0x1ffffc))[0] end

local function decodeChunk(address)
    local scheme = VP.slz.signatures[r32(address)]
    if not scheme then error(string.format('chunk at %08x has no SLZ signature', address)) end
    local sizeIn, sizeOut = r32(address + 4), r32(address + 8)
    return VP.slz.decode({
        scheme = scheme, sizeIn = sizeIn, sizeOut = sizeOut,
        data = ffi.string(mem + bit.band(address + 16, 0x1fffff), sizeIn),
    }), sizeOut
end

local pending

local function grow(regs, size, bytes)
    -- Rounded up to a word, and never smaller than what the game decompresses.
    local want = math.max(size, bit.band(#bytes + 3, bit.bnot(3)))
    regs.GPR.n.a0 = want
    return want
end

local function onMalloc()
    local regs = PCSX.getRegisters()
    if regs.GPR.n.ra ~= ALLOC_RETURN then return true end
    local caller = r32(regs.GPR.n.sp + 24)
    if caller == CASE4_SCRIPT_ALLOC then
        pending = nil
        local chunk0 = regs.GPR.n.a1
        local ok, err = pcall(function()
            local script, size = decodeChunk(chunk0)
            local next = r32(chunk0 + 12)
            if next == 0 then error('the script chunk has no font chunk after it') end
            local font, fontSize = decodeChunk(chunk0 + next)
            local entry = preview.patched(script, font)
            if entry.error then note('script ' .. entry.key .. ': not patched, ' .. entry.error) end
            if not entry.script then return end
            pending = { entry = entry, script = script, size = size, font = font, fontSize = fontSize }
            local want = grow(regs, size, entry.script)
            note(string.format('script %s: %d strings, %d glyphs added, script %d -> %d bytes', entry.key,
                               entry.n, entry.added, size, want))
        end)
        if not ok then note('script load: ' .. tostring(err)) end
    elseif caller == CASE4_FONT_ALLOC and pending and pending.entry.font then
        grow(regs, pending.fontSize, pending.entry.font)
    end
    return true
end

-- Writes bytes over the buffer at *pointer when it holds original.
local function overwrite(pointer, original, bytes, what)
    local buf = r32(pointer)
    if buf == 0 then
        note(what .. ': the game got no buffer, not patched')
        return false
    end
    if ffi.string(mem + bit.band(buf, 0x1fffff), #original) ~= original then
        note(string.format('%s: buffer at %08x does not hold the decoded original, not patched', what, buf))
        return false
    end
    ffi.copy(mem + bit.band(buf, 0x1fffff), bytes, #bytes)
    return buf
end

local function onScriptDone()
    if not pending then return true end
    local p = pending
    local at = overwrite(SCRIPT_PTR, p.script, p.entry.script, 'script ' .. p.entry.key)
    if not at then
        pending = nil
        return true
    end
    p.scriptAt = at
    if not p.entry.font then
        pending = nil
        preview.lastPatch = { key = p.entry.key, address = at, size = #p.entry.script, cycle = PCSX.getCPUCycles() }
        note(string.format('script %s: patched at %08x', p.entry.key, at))
    end
    return true
end

local function onFontDone()
    if not pending or not pending.scriptAt then return true end
    local p = pending
    pending = nil
    local at = overwrite(FONT_PTR, p.font, p.entry.font, 'font of ' .. p.entry.key)
    if not at then
        -- The script names glyphs the font does not have: put the original back.
        ffi.copy(mem + bit.band(p.scriptAt, 0x1fffff), p.script, #p.script)
        note('script ' .. p.entry.key .. ': restored, its font could not be patched')
        return true
    end
    preview.lastPatch = { key = p.entry.key, address = p.scriptAt, size = #p.entry.script, font = at,
                          cycle = PCSX.getCPUCycles() }
    note(string.format('script %s: patched at %08x, font at %08x', p.entry.key, p.scriptAt, at))
    return true
end

-- db: a VP.tdb database. Arms the breakpoints.
function preview.arm(db)
    preview.disarm()
    preview.db = db
    preview.breakpoints = {
        PCSX.addBreakpoint(MALLOC, 'Exec', 4, 'VP preview', onMalloc, 'room script alloc'),
        PCSX.addBreakpoint(CASE4_SCRIPT_DONE, 'Exec', 4, 'VP preview', onScriptDone, 'room script loaded'),
        PCSX.addBreakpoint(CASE4_FONT_DONE, 'Exec', 4, 'VP preview', onFontDone, 'room font loaded'),
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
