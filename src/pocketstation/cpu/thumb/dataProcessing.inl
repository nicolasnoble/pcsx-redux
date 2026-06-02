#pragma once

void Thumb_LSL (u32 instruction) {
    const auto offset = (instruction >> 6) & 0x1F; 
    const auto rsIndex = (instruction >> 3) & 0x7;
    const auto rdIndex = instruction & 0x7;
    const auto rs = registers[rsIndex];

    const auto res = LSL <true> (rs, offset);
    setNZ (res);
    registers[rdIndex] = res;

    registers[15] += 2; // Fake pipeline
}

template <int opcode>
void Thumb_DataProcessingImmediate (u32 instruction) {
    const auto immediate = instruction & 0xFF;
    const auto rdIndex = (instruction >> 8) & 7;

    switch (opcode) {
        case 0: // movs
            registers[rdIndex] = immediate;
            cpsr.negative = 0; // an 8-bit immediate can't humanly have bit 31 set
            cpsr.zero = immediate == 0;
            break;
        
        case 1: // cmp
            _SUB <true> (registers[rdIndex], immediate); // subtract with flags and discard result
            break;

        case 2: // adds
            registers[rdIndex] = _ADD <true> (registers[rdIndex], immediate);
            break;
        
        case 3: // subs
            registers[rdIndex] = _SUB <true> (registers[rdIndex], immediate);
            break; 
    }

    registers[15] += 2; // fake pipeline
}

template <bool isASR>
void Thumb_shiftRight (u32 instruction) {
    const auto rsIndex = (instruction >> 3) & 0x7;
    const auto rdIndex = instruction & 0x7;
    auto offset = (instruction >> 6) & 0x1F;

    if (!offset) offset = 32; // edge case: If the shift amount is 0, it's treated as if it were 32 instead
    const auto rs = registers[rsIndex];
    
    u32 res;
    if constexpr (isASR) res = ASR <true> (rs, offset);
    else res = LSR <true> (rs, offset);

    setNZ (res);
    registers[rdIndex] = res;
    registers[15] += 2; // fake pipeline
}

template <int opcode>
void Thumb_highRegisterOperation (u32 instruction) {
    const auto rdIndex = (instruction & 0x7) | ((instruction >> 4) & 0x8);
    const auto rsIndex = (instruction >> 3) & 0xF;

    const auto rd = registers[rdIndex];
    const auto rs = registers[rsIndex];

    switch (opcode) {
        case 0: registers[rdIndex] = _ADD <false> (rs, rd); break; // ADD
        case 1: _SUB <true> (rd, rs); break; // CMP
        case 2: registers[rdIndex] = rs; break; // MOV
        case 3: // BX
            cpsr.thumb = rs & 1; 
            if (cpsr.thumb) 
                registers[15] = (rs & ~1) + 4; // fake pipeline
            else
                registers[15] = (rs & ~3) + 8; // fake pipeline
    }

    if constexpr (opcode == 0 || opcode == 2) { // fake pipeline for ADD/MOV and handle writing to r15
        if (rdIndex == 15) registers[15] = (registers[15] + 4) & ~1; // fake pipeline and align PC
        else registers[15] += 2;
    }

    else if constexpr (opcode == 1) registers[15] += 2; // fake pipeline for CMP
}

void Thumb_handleALU (u32 instruction) {
    const auto rdIndex = instruction & 0x7;
    const auto rsIndex = (instruction >> 3) & 0x7;
    const auto opcode = (instruction >> 6) & 0xF;

    const auto rs = registers[rsIndex];
    const auto rd = registers[rdIndex];

    switch (opcode) {
        case 0: registers[rdIndex] = _AND <true> (rd, rs); break; // ANDS
        case 1: registers[rdIndex] = _EOR <true> (rd, rs); break; // EORS
        case 2: { // LSLS
            const auto res = LSL <true> (rd, rs);
            setNZ (res);
            registers[rdIndex] = res;
            break;
        }

        case 3: { // LSRS
            const auto res = LSR <true> (rd, rs);
            setNZ (res);
            registers[rdIndex] = res;
            break;
        }

        case 4: { // ASRS
            const auto res = ASR <true> (rd, rs);
            setNZ (res);
            registers[rdIndex] = res;
            break;
        }

        case 5: registers[rdIndex] = _ADC <true> (rd, rs, cpsr.carry); break; // ADCS
        case 6: registers[rdIndex] = _SBC <true> (rd, rs, cpsr.carry); break; // SBCS

        case 7: { // ROR
            const auto res = ROR <true> (rd, rs);
            setNZ (res);
            registers[rdIndex] = res;
            break;
        }

        case 8: _AND <true> (rd, rs); break; // TST
        case 9: registers[rdIndex] =  _SUB <true> (0, rs); break; // NEG
        case 10: _SUB <true> (rd, rs); break; // CMP
        case 11: _ADD <true> (rd, rs); break; // CMN
        case 12: registers[rdIndex] = _ORR <true> (rd, rs); break; // ORRS
        
        case 13: { // MULS
            const auto res = rd * rs;
            setNZ (res);
            registers[rdIndex] = res;
            break;
        }
        
        case 14: registers[rdIndex] = _BIC <true> (rd, rs); break; // BICS
        
        case 15: { // MVNS
            const auto res = ~rs;
            setNZ (res);
            registers[rdIndex] = res;
            break;
        }
    }

    registers[15] += 2; // fake pipeline
}

template <bool isSub> 
void Thumb_addSubReg (u32 instruction) {
    const auto rdIndex = instruction & 7;
    const auto rsIndex = (instruction >> 3) & 7;
    const auto rnIndex = (instruction >> 6) & 7;

    const auto rs = registers[rsIndex];
    const auto rn = registers[rnIndex];
    u32 result;

    if constexpr (isSub) result = _SUB <true> (rs, rn);
    else result = _ADD <true> (rs, rn);

    registers[rdIndex] = result;
    registers[15] += 2; // fake pipeline
}

template <bool isSub>
void Thumb_addSubOffset (u32 instruction) {
    const auto rdIndex = instruction & 7;
    const auto rsIndex = (instruction >> 3) & 7;
    const auto offset = (instruction >> 6) & 7;
    const auto rs = registers[rsIndex];

    if constexpr (isSub) registers[rdIndex] = _SUB <true> (rs, offset);
    else registers[rdIndex] = _ADD <true> (rs, offset);

    registers[15] += 2; // fake pipeline
}

template <bool isSPRelative>
void Thumb_loadAddress (u32 instruction) {
    const auto rdIndex = (instruction >> 8) & 0x7;
    const auto offset = (instruction & 0xFF) << 2;
    auto address = offset;

    if constexpr (isSPRelative)
        address += registers[13];
    else // if it's not SP relative, it's PC relative
        address += registers[15] & ~3;

    registers[rdIndex] = address;
    registers[15] += 2; // fake pipeline
}

void Thumb_addToSP(u32 instruction) {
    const u32 imm = (instruction & 0x7F) << 2;
    const bool sub = (instruction & 0x80) != 0;

    registers[13] = sub ? registers[13] - imm : registers[13] + imm;
    registers[15] += 2; // fake pipeline
}