-- Disassembler for Valkyrie Profile's room-script bytecode VM.
--
-- Instructions are 32-bit words: high 8 bits = opcode, low 24 bits = immediate +
-- flags. Flag bits 0x800000 = is_local, 0x100000 = from_stack. Each opcode has a
-- declared self-encoded-value type, a declared per-instruction immediate count,
-- a parameter count, and a known/unknown flag.
--
-- The dispatcher walks the bytecode and emits a textual disassembly, calling
-- registered hooks at specific opcode values for callers that need to inspect
-- the operand stream (e.g. textbox-geometry extraction during room dumps).

VP.disasm = {}

VP.disasm.opcodeNames = {
    [0x01] = 'SETV',  [0x02] = 'SETV',
    [0x08] = 'MULG0', [0x09] = 'ADDG0', [0x0a] = 'PSH',   [0x0d] = 'PSH1?',
    [0x12] = 'PSH2?', [0x13] = 'PSHI',  [0x14] = 'CALL',  [0x15] = 'JMP',
    [0x16] = 'JMPZ',  [0x17] = 'RET',   [0x18] = 'SETD',  [0x19] = 'PSH3?',
    [0x80] = 'STTRG', [0x8c] = 'SSTOP',
    [0x92] = 'TBOX',  [0x93] = 'TBOX2', [0x98] = 'TBOX3',
    [0x9e] = 'SETRM', [0x9f] = 'CHGRM',
}

-- opcode -> number of u32 immediates following the instruction word
VP.disasm.opcodeImms = {
       [0x01] = 0, [0x02] = 0, [0x03] = 0, [0x04] = 0, [0x05] = 0, [0x06] = 0, [0x07] = 0,
    [0x08] = 0, [0x09] = 0, [0x0a] = 0, [0x0b] = 0, [0x0c] = 0, [0x0d] = 0, [0x0e] = 0,
    [0x10] = 0, [0x11] = 0, [0x12] = 0, [0x13] = 1, [0x14] = 0, [0x15] = 0, [0x16] = 0, [0x17] = 0,
    [0x18] = 1, [0x19] = 1, [0x1a] = 1, [0x1b] = 0, [0x1c] = 0, [0x1d] = 0, [0x1e] = 0, [0x1f] = 0,
    [0x20] = 0, [0x21] = 1, [0x22] = 0, [0x23] = 1, [0x24] = 0, [0x25] = 1, [0x26] = 0, [0x27] = 1,
    [0x28] = 0, [0x29] = 1, [0x2a] = 0,
    [0x3d] = 1, [0x3f] = 1,
    [0x41] = 1, [0x43] = 1, [0x45] = 1,
    [0x71] = 2, [0x72] = 1, [0x73] = 2, [0x75] = 1,
    [0x80] = 3, [0x82] = 1, [0x83] = 2, [0x85] = 4, [0x86] = 1, [0x87] = 1, [0x88] = 1, [0x8a] = 2, [0x8c] = 1, [0x8f] = 2,
    [0x92] = 3, [0x93] = 3, [0x94] = 3, [0x98] = 3, [0x9d] = 1, [0x9e] = 1, [0x9f] = 2,
    [0xa0] = 2, [0xa1] = 2, [0xa2] = 1, [0xa3] = 2, [0xa8] = 1,
    [0xbb] = 1,
    [0xc0] = 2, [0xc2] = 1, [0xc9] = 1,
    [0xd9] = 2,
    [0xe6] = 1, [0xeb] = 1,
}

-- Encoding of the self-immediate value embedded in the opcode word
-- 0 = nothing, 1 = low8, 2 = low16, 3 = low23, 4 = high8, 5 = var_idx,
-- 6 = var_idx2, 7 = low8 + high8
VP.disasm.opcodeSelfVals = {
       [0x01] = 5, [0x02] = 5,
    [0x08] = 3, [0x09] = 3, [0x0a] = 5,
    [0x0d] = 2,
    [0x12] = 3, [0x14] = 3, [0x15] = 3, [0x16] = 3,
    [0x18] = 6,
    [0x80] = 2, [0x81] = 2, [0x82] = 2,
    [0x85] = 2, [0x86] = 2,
    [0x88] = 2,
    [0x8d] = 2, [0x8e] = 1,
    [0x92] = 2, [0x93] = 2, [0x94] = 2,
    [0x98] = 2,
    [0x9d] = 7, [0x9e] = 2,
    [0xa1] = 2,
    [0xa8] = 2, [0xab] = 2,
    [0xb2] = 7, [0xbb] = 2,
    [0xc2] = 2,
    [0xe6] = 2,
}

-- opcode -> number of total parameters (immediate + stack pops + self val)
VP.disasm.opcodeNParams = {
       [0x01] = 2, [0x02] = 2,
    [0x08] = 2, [0x09] = 2, [0x0a] = 1,
    [0x0d] = 1,
    [0x12] = 1, [0x13] = 1, [0x14] = 1, [0x15] = 1, [0x16] = 2,
    [0x18] = 2, [0x19] = 1, [0x1a] = 1,
    [0x21] = 1, [0x23] = 1, [0x25] = 1, [0x26] = 1, [0x27] = 1, [0x28] = 1, [0x29] = 1, [0x2a] = 1,
    [0x2e] = 1,
    [0x3d] = 1, [0x3f] = 1,
    [0x41] = 1, [0x42] = 1, [0x43] = 1, [0x45] = 1,
    [0x72] = 1, [0x73] = 3, [0x75] = 1, [0x76] = 1,
    [0x7e] = 1,
    [0x80] = 4, [0x81] = 1, [0x82] = 2, [0x83] = 4, [0x85] = 5, [0x86] = 2, [0x87] = 2, [0x88] = 2,
    [0x8a] = 3, [0x8c] = 1, [0x8d] = 1, [0x8e] = 1, [0x8f] = 5,
    [0x92] = 7, [0x93] = 7, [0x94] = 6,
    [0x98] = 7, [0x9d] = 3, [0x9e] = 2, [0x9f] = 4,
    [0xa0] = 6, [0xa1] = 2, [0xa2] = 2, [0xa3] = 6,
    [0xa8] = 2, [0xa9] = 1, [0xab] = 1,
    [0xb2] = 2,
    [0xb8] = 1,
    [0xbb] = 2,
    [0xc0] = 2,
    [0xc2] = 3,
    [0xc9] = 2,
    [0xd9] = 5, [0xda] = 1,
    [0xdd] = 1,
    [0xe0] = 1,
    [0xe6] = 2,
    [0xeb] = 1,
}

VP.disasm.opcodeKnown = {
       [0x01] = true, [0x02] = true,
    [0x08] = true, [0x09] = true, [0x0a] = true,
    [0x0d] = true,
    [0x12] = true, [0x13] = true, [0x14] = true, [0x15] = true, [0x16] = true, [0x17] = true, [0x18] = true, [0x19] = true, [0x1a] = true,
    [0x21] = true, [0x22] = true, [0x23] = true, [0x24] = true, [0x25] = true, [0x26] = true, [0x27] = true, [0x28] = true, [0x29] = true, [0x2a] = true,
    [0x2e] = true,
    [0x3d] = true, [0x3f] = true,
    [0x41] = true, [0x42] = true, [0x43] = true,
    [0x49] = true,
    [0x70] = true, [0x71] = true, [0x72] = true, [0x73] = true, [0x74] = true, [0x75] = true, [0x76] = true, [0x78] = true,
    [0x7b] = true, [0x7c] = true, [0x7e] = true,
    [0x80] = true, [0x81] = true, [0x82] = true, [0x83] = true, [0x85] = true, [0x86] = true, [0x87] = true, [0x88] = true,
    [0x8a] = true,
    [0x8c] = true, [0x8d] = true, [0x8e] = true, [0x8f] = true,
    [0x91] = true, [0x92] = true, [0x93] = true, [0x94] = true,
    [0x98] = true,
    [0x9d] = true, [0x9e] = true, [0x9f] = true,
    [0xa0] = true, [0xa1] = true, [0xa2] = true, [0xa3] = true,
    [0xa8] = true, [0xa9] = true,
    [0xab] = true,
    [0xb0] = true,
    [0xb2] = true,
    [0xb8] = true,
    [0xbb] = true,
    [0xbe] = true,
    [0xc0] = true,
    [0xc2] = true,
    [0xc9] = true,
    [0xd9] = true, [0xda] = true,
    [0xdd] = true, [0xde] = true,
    [0xe0] = true,
    [0xe6] = true,
    [0xeb] = true,
}

-- Opcodes whose 'from_stack' flag indicates the operand list comes off the stack
-- (PSH precedents) rather than being inline. Used so the disassembler knows how
-- to render parameters - POP() vs literal.
VP.disasm.opcodeFromStack = {
       [0x71] = true, [0x72] = true, [0x73] = true, [0x75] = true,
    [0x80] = true, [0x81] = true, [0x82] = true, [0x83] = true,
    [0x85] = true, [0x86] = true, [0x87] = true, [0x88] = true,
    [0x8a] = true, [0x8c] = true, [0x8e] = true, [0x8f] = true,
    [0x92] = true, [0x93] = true, [0x94] = true,
    [0x98] = true, [0x9d] = true, [0x9e] = true, [0x9f] = true,
    [0xa0] = true, [0xa1] = true, [0xa2] = true, [0xa3] = true,
    [0xa8] = true, [0xa9] = true, [0xab] = true,
    [0xb2] = true, [0xbb] = true,
    [0xc0] = true, [0xc2] = true,
    [0xc9] = true,
    [0xd9] = true, [0xda] = true,
    [0xdd] = true,
    [0xe6] = true,
    [0xeb] = true,
}

-- Disassemble one instruction from `logic` (a File). Returns the new PC. If `out`
-- is non-nil, writes a textual disassembly line to it. Hooks is a table keyed by
-- opcode with callback(pc) functions; if the hook exists for the current opcode,
-- it's invoked after the instruction text is emitted, giving the caller a chance
-- to inspect operands by re-reading specific PCs via the closure-captured logic.
function VP.disasm.step(state)
    state.oPC = state.PC
    state.opcode = state.rdn()
    state.code = bit.rshift(state.opcode, 24)
    state.imm8 = bit.band(state.opcode, 0xff)
    state.imm16 = bit.band(state.opcode, 0xffff)
    state.imm23 = bit.band(state.opcode, 0x7fffff)
    state.high8 = bit.band(bit.rshift(state.opcode, 8), 0xff)
    state.idx2 = bit.rshift(bit.lshift(state.opcode, 9), 12)
    state.isLocal = bit.band(state.opcode, 0x800000) ~= 0
    state.fromStack = bit.band(state.opcode, 0x100000) ~= 0

    local out = state.out
    if out then out:write(string.format('%08X %08X  ', state.oPC, state.opcode)) end

    if state.code == 0 then
        if out then out:write('OPCODE00?!') end
        if state.hooks and state.hooks[0] then state.hooks[0](state.oPC) end
        return
    end

    local name = VP.disasm.opcodeNames[state.code]
    if out then
        if name then
            out:write(string.format('%-8s', name))
        elseif VP.disasm.opcodeKnown[state.code] then
            out:write(string.format('OP_%02X   ', state.code))
        else
            out:write(string.format('UNK%02X   ', state.code))
        end
    end

    local nargs = VP.disasm.opcodeNParams[state.code] or 0
    local sv = VP.disasm.opcodeSelfVals[state.code] or 0
    local imms = VP.disasm.opcodeImms[state.code] or 0
    local fromStackOp = VP.disasm.opcodeFromStack[state.code]

    if state.fromStack and fromStackOp then
        if out then
            for i = 1, nargs do
                out:write('POP()')
                if i ~= nargs then out:write(', ') end
            end
        end
    else
        if out then
            if sv == 1 then
                out:write(string.format('%02X', state.imm8))
                nargs = nargs - 1
            elseif sv == 2 then
                out:write(string.format('%04X', state.imm16))
                nargs = nargs - 1
            elseif sv == 3 then
                out:write(string.format('%08X', state.imm23))
                nargs = nargs - 1
            elseif sv == 4 then
                out:write(string.format('%02X', state.high8))
                nargs = nargs - 1
            elseif sv == 5 then
                out:write(string.format('%s[%04X]', state.isLocal and 'locl' or 'glbl', state.imm16))
                nargs = nargs - 1
            elseif sv == 6 then
                out:write(string.format('%s[%04X]', state.isLocal and 'locl' or 'glbl', state.idx2))
                nargs = nargs - 1
            elseif sv == 7 then
                out:write(string.format('%02X, %02X', state.imm8, state.high8))
                nargs = nargs - 2
            end
            if sv ~= 0 and nargs ~= 0 then out:write(', ') end
        end

        for i = 1, imms do
            local v = state.rdn()
            if out then
                out:write(string.format('%08X', v))
                if i ~= imms then out:write(', ') end
            end
            nargs = nargs - 1
        end

        if out and not fromStackOp then
            for i = 1, nargs do
                out:write('POP()')
                if i ~= nargs then out:write(', ') end
            end
        end
    end

    if state.hooks and state.hooks[state.code] then state.hooks[state.code](state.oPC) end
end

-- Disassemble a logic blob to `out` (a File or nil). `hooks` is an optional table
-- of opcode -> callback(PC) invoked at each matching opcode site.
function VP.disasm.run(logic, out, hooks)
    local state = {
        logic = logic,
        out = out,
        hooks = hooks,
        PC = 0,
        EPC = math.floor(logic:size() / 4),
    }
    state.rd = function(addr)
        state.logic:rSeek(addr * 4)
        return state.logic:readU32()
    end
    state.rdn = function()
        local r = state.rd(state.PC)
        state.PC = state.PC + 1
        return r
    end

    while state.PC ~= state.EPC do
        VP.disasm.step(state)
        if out then
            out:write('\n')
            for padPC = state.oPC + 1, state.PC - 1 do
                out:write(string.format('         %08X\n', state.rd(padPC)))
            end
        end
    end
end
