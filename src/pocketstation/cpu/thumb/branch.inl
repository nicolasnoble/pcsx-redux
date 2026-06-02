#pragma once

void Thumb_B (u32 instruction) {
    auto offset = (instruction & 0x7FF) << 1;
    offset = Helpers::signExtend32 (offset, 12); // Sign extend the offset to 32 bits from 12

    registers[15] += offset + 4; // branch and fake pipeline
}

template <bool isSecondPart> // Thumb BL instructions are split into 2 parts
void Thumb_BL (u32 instruction) {
    if constexpr (!isSecondPart) {
        auto offset = instruction & 0x7FF; // get sign extended offset
        offset = Helpers::signExtend32 (offset, 11) << 12;
        registers[14] = registers[15] + offset; // add to PC and store it in LR
        registers[15] += 2; // fake pipeline
    }

    else {
        const auto offset = (instruction & 0x7FF) << 1;
        const auto pc = registers[15];
        registers[15] = registers[14] + offset; 
        registers[15] += 4; // fake pipeline

        registers[14] = (pc-2) | 1; // Set LR, toggle bit 0 on to indicate this is function call from thumb code 
    }
}

void Thumb_conditionalBranch (u32 instruction) {
    const auto condition = (instruction >> 8) & 0xF;
    if (isConditionTrue(condition)) {
        auto offset = (instruction & 0xFF) << 1;
        offset = Helpers::signExtend32 (offset, 9);

        registers[15] += offset;
        registers[15] += 4; // fake pipeline
    }

    else {
        if (condition == 0xF) { // Thumb mode SWI
            if (bus.comTrace) printf("[PSK] SWI %02Xh (thumb, PC=%08X)\n", instruction & 0xff, registers[15] - 2);

            const auto lr = registers[15] - 2;
            const auto newSPSR = cpsr.raw;

            setMode(CPUModes::SVC);
            registers[14] = lr;
            cpsr.irqDisable = 1;
            cpsr.thumb = 0; // Switch to ARM mode
            
            registers[15] = 0x08; // Jump to SWI vector
            spsr.raw = newSPSR;
            registers[15] += 8; // Fake pipeline
        } else {
            registers[15] += 2; // fake pipeline
        }
    }
}