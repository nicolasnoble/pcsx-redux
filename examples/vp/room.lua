-- Per-room digit-glyph translation header. The first 0x33 bytes of each room
-- script are a fixed table that maps internal damage-number glyph indices to
-- their displayed form. We validate against this on extraction.
VP.scriptTypes = {
    room = {
        header = {
            0x01, 0x02, 0x00, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
            0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
            0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f,
            0x30, 0x31, 0x00
        },
        translated = { '-', '-', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '!',
                       'O', '１', '２', '３', '４', '５', '６', '７', '８', '９', '－', '！',
                       '⓪', '①', '②', '③', '④', '⑤', '⑥', '⑦', '⑧', '⑨', 'ǃ',
                       'O', '１', '２', '３', '４', '５', '６', '７', '８', '９', '－', '！', ' ' },
        size = 0x33,
    },
}

-- Sanity-check anchor: known instruction words at fixed PCs in the room logic.
-- A mismatch indicates we're processing the wrong kind of file or the format
-- has shifted, and is treated as an error to avoid silently producing garbage.
VP.roomLogicCheck = {
    [0x0090] = { 0x18000000, 0x00000008 }, [0x009B] = { 0x98100000, 0x17000000 },
    [0x033C] = { 0x18000000, 0x0000002C }, [0x03BC] = { 0x92100000, 0x150003E1 },
    [0x03C7] = { 0x94100000, 0x150003E1 }, [0x03D3] = { 0x93100000, 0x150003E1 },
    [0x03DF] = { 0x92100000, 0x150003E1 },
    [0x03E2] = { 0x18000000, 0x00000018 }, [0x03F0] = { 0x1400033C, 0x7E000000 },
    [0x03F5] = { 0x18000000, 0x00000018 }, [0x0403] = { 0x1400033C, 0x7E000000 },
    [0x0408] = { 0x18000000, 0x00000018 }, [0x0416] = { 0x1400033C, 0x7E000000 },
}

local function checkRoomLogic(logic)
    for offset, expected in pairs(VP.roomLogicCheck) do
        local pc = offset - 1
        for suboffset, supposed in ipairs(expected) do
            logic:rSeek((pc + suboffset) * 4)
            local r = logic:readU32()
            if r ~= supposed then
                error(string.format(
                    "Room logic check failed: opcode at PC %04X is %08X but %08X expected",
                    pc + suboffset, r, supposed))
            end
        end
    end
end

-- Walk the room logic bytecode, identify textbox setup blocks (six PSH
-- precedents to a TBOX* opcode, or a CALL into one of the textbox dispatcher
-- subroutines), and associate each textbox with the text-pointer it references.
-- Returns a table mapping pointer_index -> { x, y, width, height } or
-- { typ = 'fixed' } / { typ = 'auto' } / nil.
local function extractTextboxes(logic, ptrStart)
    local textboxes = {}

    local function rdOp(pc)
        logic:rSeek(pc * 4)
        return logic:readU32()
    end

    local function addTextbox(txtptr, tb)
        if txtptr < 0 then return end
        if textboxes[txtptr + ptrStart] then
            -- Already recorded; later hits get marked but the first stays.
            return
        end
        textboxes[txtptr + ptrStart] = tb
    end

    local function txtProcess(pc)
        local opcode = rdOp(pc)
        local txtptr, x, y, width, height
        if bit.band(opcode, 0x00100000) ~= 0 then
            -- Operand list came off the stack: walk back six PSH instructions.
            local psh = {}
            for i = 1, 6 do psh[i] = rdOp(pc - i) end
            for i = 1, 6 do
                if bit.band(psh[i], 0xff000000) ~= 0x12000000 then return end
            end
            local arg = {}
            for i = 1, 6 do arg[i] = bit.band(psh[i], 0x7fffff) end
            txtptr = arg[6] + 1 - ptrStart
            x = arg[5]; y = arg[4]; width = arg[3]; height = arg[2]
        else
            txtptr = bit.band(opcode, 0xff) + 1 - ptrStart
            local arg1 = rdOp(pc + 1)
            local arg2 = rdOp(pc + 2)
            x = bit.band(arg1, 0xffff)
            y = bit.rshift(arg1, 16)
            width = bit.band(arg2, 0xffff)
            height = bit.rshift(arg2, 16)
        end
        addTextbox(txtptr, { x = x, y = y, width = width, height = height })
    end

    local function processSubtxt(pc)
        local psh = {}
        for i = 1, 6 do psh[i] = rdOp(pc - i) end
        -- psh[1] may be 0x12 or 0x0B; psh[2] must be 0x12 (text pointer arg);
        -- psh[3..6] may be 0x12 or 0x0B.
        if bit.band(psh[1], 0xff000000) ~= 0x12000000 and bit.band(psh[1], 0xff000000) ~= 0x0B000000 then return end
        if bit.band(psh[2], 0xff000000) ~= 0x12000000 then return end
        for i = 3, 6 do
            local op = bit.band(psh[i], 0xff000000)
            if op ~= 0x12000000 and op ~= 0x0B000000 then return end
        end
        local arg = {}
        for i = 1, 6 do
            if bit.band(psh[i], 0xff000000) == 0x0B000000 then
                arg[i] = nil  -- variable, not a literal
            else
                arg[i] = bit.band(psh[i], 0x7fffff)
            end
        end
        local txtptr = arg[2] + 1 - ptrStart
        addTextbox(txtptr, {
            x = arg[6] or 'var', y = arg[5] or 'var',
            width = arg[4] or 'var', height = arg[3] or 'var',
        })
    end

    local function processSubtxt2(pc)
        local psh = {}
        for i = 1, 5 do psh[i] = rdOp(pc - i) end
        if bit.band(psh[1], 0xff000000) ~= 0x12000000 then return end
        if bit.band(psh[2], 0xff000000) ~= 0x0B000000 then return end
        if bit.band(psh[3], 0xff000000) ~= 0x22000000 then return end
        if bit.band(psh[4], 0xff000000) ~= 0x0B000000 then return end
        if bit.band(psh[5], 0xff000000) ~= 0xCB000000 then return end
        local txtptr = bit.band(psh[5], 0xff) + 1 - ptrStart
        addTextbox(txtptr, { typ = 'fixed' })
    end

    local function callProcess(pc)
        local opcode = rdOp(pc)
        if opcode == 0x1400033C or opcode == 0x140003E2 or opcode == 0x140003F5 or opcode == 0x14000408 then
            processSubtxt(pc)
        end
        if opcode == 0x14000090 then
            processSubtxt2(pc)
        end
    end

    VP.disasm.run(logic, nil, {
        [0x92] = txtProcess,
        [0x93] = txtProcess,
        [0x94] = txtProcess,
        [0x98] = txtProcess,
        [0x14] = callProcess,
    })

    return textboxes
end

-- Extract a full room script: read header, validate via checkRoomLogic, decode
-- per-pointer text via the font/glyph lookup, run a disassembly pass to extract
-- textbox geometry per pointer, then write the consolidated <ptr/> + <window/>
-- + decoded-text XML to <fname>-script.txt. Also appends to the rooms-lookup
-- output if one is registered.
function extract_room_script(fname, script, font, fileInfo)
    print('Processing room script ' .. fname)
    if VP.arguments.dump then
        mkdir(fname)
        mkdir(fname .. '/EXTRA')
    end

    local fontData = extractFont(font, { dir = fname .. '/FONT', name = 'font' })
    local lookup = resolveFont(fontData)

    script:rSeek(0)
    local sizeLogic = script:readU32()
    local logicOffset = script:readU32()
    local u1 = script:readU32()
    local nPtrs = script:readU32()
    local u3 = script:readU32()
    local u4 = script:readU32()
    local u5 = script:readU32()

    if logicOffset ~= 0 then
        error('Unhandled logic offset ' .. logicOffset)
    end

    -- Copy the logic bytecode into a buffer so the disasm pass can seek freely
    -- without disturbing our linear walk through the strings. rTell returns an
    -- int64 cdata; tonumber() it so we can do arithmetic without surprises and
    -- so it works as the position argument to the LuaBuffer-returning readAt.
    local logic = Support.File.buffer()
    local logicStart = tonumber(script:rTell())
    logic:writeAt(script:readAt(sizeLogic, logicStart), 0)
    script:rSeek(logicStart + sizeLogic)

    local ptrs = {}
    for i = 1, nPtrs do
        ptrs[i] = script:readU16()
    end

    local ptrsContents, ptrsRaws = {}, {}
    local strBase = tonumber(script:rTell())

    -- The first two pointer slots are sentinels; real text starts at index 3.
    ptrsContents[1] = ''
    ptrsContents[2] = ''
    ptrsRaws[1] = ''
    ptrsRaws[2] = ''
    local ptrStart = 3

    -- Validate the fixed 0x33-byte digit translation header.
    local hdr = VP.scriptTypes.room.header
    for i = 1, VP.scriptTypes.room.size do
        local b = script:readU8()
        if b ~= hdr[i] then
            error(string.format("Room script header mismatch at byte %d: got 0x%02x, expected 0x%02x",
                i, b, hdr[i]))
        end
    end

    for i = ptrStart, nPtrs do
        ptrsContents[i] = ''
        ptrsRaws[i] = ''
        local expectedPos = strBase + ptrs[i]
        local actual = tonumber(script:rTell())
        if expectedPos ~= actual then
            error(string.format("Script consistency failure for pointer %d: at %d, expected %d",
                i, actual, expectedPos))
        end
        while true do
            local r, rr = extractChar(script, lookup, 'primary')
            if not r then break end
            ptrsContents[i] = ptrsContents[i] .. r
            ptrsRaws[i] = ptrsRaws[i] .. rr
        end
    end

    -- Run the disasm pass to extract textbox geometry per pointer.
    local disasmOut = nil
    if VP.arguments.dump then
        disasmOut = Support.File.open(fname .. '/EXTRA/logic.txt', 'TRUNCATE')
    end
    checkRoomLogic(logic)
    local textboxes = extractTextboxes(logic, ptrStart)
    if disasmOut then
        VP.disasm.run(logic, disasmOut, { [0x17] = function() disasmOut:write('\n--\n') end })
        disasmOut:close()
    end

    -- Prepend textbox info to each pointer's content.
    for i = ptrStart, nPtrs do
        local tb = textboxes[i]
        if tb then
            if tb.typ == 'fixed' then
                ptrsContents[i] = '<window type="fixed"/>\n' .. ptrsContents[i]
            elseif tb.typ == 'auto' then
                ptrsContents[i] = '<window type="auto"/>\n' .. ptrsContents[i]
            else
                ptrsContents[i] = string.format(
                    '<window x="%s" y="%s" width="%s" height="%s"/>\n',
                    tostring(tb.x), tostring(tb.y), tostring(tb.width), tostring(tb.height))
                    .. ptrsContents[i]
            end
        else
            ptrsContents[i] = '<nowindowdetected/>\n' .. ptrsContents[i]
        end
    end

    -- String-content-keyed dedup: identical text across rooms collapses to the
    -- same index in VP.globals.allTexts. The rooms_lookup output maps each
    -- room's pointer indices to their dedup index, so the rebuilder can stitch
    -- translated text back to the right slots.
    if not VP.globals.allTexts then VP.globals.allTexts = {} end
    if not VP.globals.textIndex then VP.globals.textIndex = {} end
    local ptrIdx = {}
    for i = ptrStart, nPtrs do
        local content = ptrsContents[i]
        local idx = VP.globals.textIndex[content]
        if not idx then
            idx = #VP.globals.allTexts + 1
            VP.globals.allTexts[idx] = content
            VP.globals.textIndex[content] = idx
        end
        ptrIdx[i] = idx
    end

    if VP.arguments.dump then
        local o = Support.File.open(fname .. '-script.txt', 'TRUNCATE')
        o:write('template:room\n')
        for i = ptrStart, nPtrs do
            o:write(ptrIdx[i] .. '\n')
        end
        o:close()

        if VP.globals.lookupRooms and fileInfo and fileInfo.index then
            -- room index is the file index minus the GAME/ROOMS span start +
            -- the fixed pre-header offset (3604 spans start at 6 internal slots).
            local roomIdx = fileInfo.index - 3610
            VP.globals.lookupRooms:write('    [' .. roomIdx .. '] = { ')
            for i = ptrStart, nPtrs do
                VP.globals.lookupRooms:write(ptrIdx[i] .. ', ')
            end
            VP.globals.lookupRooms:write('},\n')
        end
    end
end

-- Walker for arcroom/sarc archives. .arm carries paired (script, font) at
-- ftype == 4; .sarc has script at ftype == 4 and font at ftype == 7.
function process_arcroom(file, fileInfo)
    local nfiles = file:readU32()
    local offset = file:readU32()

    if nfiles * 8 + 8 ~= offset then
        error 'Bad archive format'
    end

    local index = {}
    for i = 1, nfiles do
        local indexData = {}
        indexData.ftype = file:readU32()
        indexData.size = file:readU32()
        indexData.file = file:subFile(offset, indexData.size)
        local info = deepCopy(fileInfo)
        info.dir = info.dir .. '/' .. info.name
        info.name = info.name .. string.format('-%02i-%08i', i, indexData.ftype)
        info.ext = 'out'
        offset = offset + indexData.size
        indexData.info = info
        index[i] = indexData
    end

    local script = nil
    local font = nil
    local scriptFontStyle = nil  -- 'arm' (room scripts) or 'sarc' (simple scripts)

    for i = 1, nfiles do
        local handler = nil
        if fileInfo.ext == 'arm' and index[i].ftype == 4 then
            scriptFontStyle = 'arm'
            local counter = 1
            handler = function(file, _)
                if counter == 1 then
                    script = file:dup()
                elseif counter == 2 then
                    font = file:dup()
                else
                    error 'Too many files...'
                end
                counter = counter + 1
            end
        elseif fileInfo.ext == 'sarc' and index[i].ftype == 4 then
            -- In .sarc, ftype=4 is the script+font pair packed as two SLZ
            -- sub-chunks of one archive entry: chunk 1 = script, chunk 2 = font.
            scriptFontStyle = 'sarc'
            local counter = 1
            handler = function(file, _)
                if counter == 1 then
                    if script then error "Can't have two scripts in a sarc" end
                    script = file:dup()
                elseif counter == 2 then
                    if font then error "Can't have two fonts in a sarc" end
                    font = file:dup()
                else
                    error 'Too many sub-chunks in sarc ftype=4'
                end
                counter = counter + 1
            end
        elseif fileInfo.ext == 'sarc' and index[i].ftype == 7 then
            -- Standalone font entry occasionally seen in .sarc archives.
            handler = function(file, _)
                if font then error "Can't have two fonts in a sarc" end
                font = file:dup()
            end
        end
        processOneFile(index[i].file, index[i].info, handler)

        if script and font then
            if scriptFontStyle == 'arm' then
                extract_room_script(fileInfo.dir .. '/' .. fileInfo.name .. string.format('/%04i', i),
                    script, font, fileInfo)
            else
                extract_simple_script(fileInfo.dir .. '/' .. fileInfo.name .. string.format('/%04i', i),
                    script, font, 'primary')
            end
            script:close()
            font:close()
            script = nil
            font = nil
        end
    end
end
