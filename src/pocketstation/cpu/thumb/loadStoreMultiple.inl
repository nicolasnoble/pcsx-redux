#pragma once

void Thumb_STMIA(u32 instruction) {
    const auto rb = (instruction >> 8) & 7;
    u32 sp = registers[rb];

    if ((instruction & 0xff) == 0) Helpers::panic("Thumb stmia rb! { rlist } with empty rlist");
    if (instruction & (1 << rb)) Helpers::panic("Thumb stmia rb! { rlist } with rb in rlist");

    for (int i = 0; i < 8; i++) {
        if (instruction & (1 << i)) {
            write32(sp, registers[i]);
            sp += 4;
        }
    }

    registers[rb] = sp; // Writeback sp
    registers[15] += 2; // Fake pipeline
}

void Thumb_LDMIA(u32 instruction) {
    const auto rb = (instruction >> 8) & 7;
    u32 sp = registers[rb];

    if ((instruction & 0xff) == 0) Helpers::panic("Thumb ldmia rb! { rlist } with empty rlist");
    if (instruction & (1 << rb)) Helpers::panic("Thumb ldmia rb! { rlist } with rb in rlist");

    for (int i = 0; i < 8; i++) {
        if (instruction & (1 << i)) {
            registers[i] = read32(sp);
            sp += 4;
        }
    }

    registers[rb] = sp; // Writeback sp
    registers[15] += 2; // Fake pipeline
}

template <bool pushLR>
void Thumb_PUSH(u32 instruction) {
    const auto rlist = instruction & 0xFF;
    auto sp = registers[13];

    if constexpr (pushLR) {
        sp -= 4;
        write32 (sp, registers[14]);
    }

    else if (rlist == 0) // rlist == 0 without pushing LR is an edge case
        Helpers::panic ("Thumb PUSH with empty rlist");

    for (int i = 7; i >= 0; i--) {
        if (instruction & (1 << i)) { // push every register in rlist
            sp -= 4;
            write32 (sp, registers[i]);
        }
    }   

    registers[13] = sp; // write back SP
    registers[15] += 2; // fake pipeline
}

template <bool popPC>
void Thumb_POP(u32 instruction) {
    const auto rlist = instruction & 0xFF;
    auto sp = registers[13];

    for (auto i = 0; i < 8; i++) {
        if (instruction & (1 << i)) {
            registers[i] = read32 (sp);
            sp += 4;
        }
    }

    if constexpr (popPC) {
        const auto pc = read32 (sp);
        sp += 4;
        registers[15] = (pc & ~1) + 4; // fake pipeline for the ARM7
    }

    else if (rlist == 0) // rlist == 0 without pushing LR is an edge case
        Helpers::panic ("Thumb PUSH with empty rlist");

    else registers[15] += 2; // fake pipeline

    registers[13] = sp; // write back SP
}