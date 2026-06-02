#pragma once

void Thumb_PCRelativeLoad (u32 instruction) {
    const auto rdIndex = (instruction >> 8) & 0x7;
    const auto imm = (instruction & 0xFF) << 2;
    const auto addr = (registers[15] & ~2) + imm;

    const auto val = read32 (addr & ~3); // handle alignment
    registers[rdIndex] = ROR <false> (val, addr & 3);
    registers[15] += 2; // fake pipeline
}

template <bool isLoad>
void Thumb_HalfwordTransferImm (u32 instruction) {
    const auto rdIndex = instruction & 7;
    const auto rb = registers[(instruction >> 3) & 7];
    const auto offset = ((instruction >> 6) & 0x1F) << 1;
    const auto addr = rb + offset;
    if (addr & 1) Helpers::panic ("Unaligned Thumb halfword transfer");

    if constexpr (isLoad) 
        registers[rdIndex] = read16 (addr);
    else
        write16 (addr, registers[rdIndex] & 0xFFFF);

    registers[15] += 2; // fake pipeline
}

template <bool isLoad>
void Thumb_WordTransferImm (u32 instruction) {
    const auto rdIndex = instruction & 7;
    const auto rb = registers[(instruction >> 3) & 7];
    const auto offset = ((instruction >> 6) & 0x1F) << 2;
    const auto addr = rb + offset;

    if constexpr (isLoad) {
        auto val = read32 (addr & ~3);
        registers[rdIndex] = ROR <false> (val, (addr & 3) * 8);
    }

    else
        write32 (addr, registers[rdIndex]);
    registers[15] += 2; // fake pipeline
}

template <bool isLoad>
void Thumb_ByteTransferReg (u32 instruction) {
    const auto rdIndex = instruction & 7;
    const auto rb = registers[(instruction >> 3) & 7];
    const auto ro = registers[(instruction >> 6) & 7];
    const auto address = rb + ro;

    if constexpr (isLoad)
        registers[rdIndex] = read8 (address);
    else
        write8 (address, (uint8_t) registers[rdIndex]);
    registers[15] += 2; // fake pipeline
}

template <bool isLoad>
void Thumb_ByteTransferImm (u32 instruction) {
    const auto rdIndex = instruction & 7;
    const auto rb = registers[(instruction >> 3) & 7];
    const auto offset = (instruction >> 6) & 0x1F;
    const auto address = rb + offset;

    if constexpr (isLoad)
        registers[rdIndex] = read8 (address);
    else
        write8 (address, (uint8_t) registers[rdIndex]);

    registers[15] += 2; // fake pipeline
}

template <bool isHalfword>
void Thumb_loadWithReg (u32 instruction) {
    const auto rdIndex = instruction & 7;
    const auto rb = registers[(instruction >> 3) & 7];
    const auto ro = registers[(instruction >> 6) & 7];

    const auto address = rb + ro;

    if constexpr (isHalfword) {
        registers[rdIndex] = read16 (address); // TODO: Unaligned accesses
    }

    else {
        auto val = read32 (address & ~3);
        val = ROR <false> (val, (address & 3) * 8);
        registers[rdIndex] = val;
    }
    
    registers[15] += 2; // fake pipeline
}

void Thumb_SPRelativeLoad(u32 instruction) {
    const u32 imm = (instruction & 0xFF) << 2;
    const u32 sp = registers[13];
    const u32 rd = (instruction >> 8) & 0x7;
    registers[rd] = read32(sp + imm);

    registers[15] += 2; // fake pipeline
}

void Thumb_SPRelativeStore(u32 instruction) {
    const u32 imm = (instruction & 0xFF) << 2;
    const u32 sp = registers[13];
    const u32 rd = registers[(instruction >> 8) & 0x7];

    write32(sp + imm, rd);
    registers[15] += 2; // fake pipeline
}

void Thumb_storeWordWithReg(u32 instruction) {
    const auto rdIndex = instruction & 7;
    const auto rb = registers[(instruction >> 3) & 7];
    const auto ro = registers[(instruction >> 6) & 7];
    const auto addr = ro + rb;

    write32(addr, registers[rdIndex]);
    registers[15] += 2; // fake pipeline
}

void Thumb_LDRSB(u32 instruction) {
    const auto rdIndex = instruction & 7;
    const auto rb = registers[(instruction >> 3) & 7];
    const auto ro = registers[(instruction >> 6) & 7];
    const auto addr = ro + rb;

    registers[rdIndex] = (u32)(s8) read8(addr);
    registers[15] += 2; // fake pipeline
}

void Thumb_LDRSH(u32 instruction) {
    const auto rdIndex = instruction & 7;
    const auto rb = registers[(instruction >> 3) & 7];
    const auto ro = registers[(instruction >> 6) & 7];
    const auto addr = ro + rb;

    registers[rdIndex] = (u32)(s16) read16(addr);
    registers[15] += 2; // fake pipeline
}