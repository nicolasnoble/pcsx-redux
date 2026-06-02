#pragma once

template <bool link>
void ARM_Branch (u32 instruction) {
    if constexpr (link)
        registers [14] = registers[15] - 4;

    registers[15] += Helpers::signExtend32 (instruction & 0xFFFFFF, 24) << 2; // add sign extended offset to PC
    registers[15] += 8; // fake pipeline
}

template <bool link>
void ARM_BX (u32 instruction) {
    if constexpr (link)
        registers[14] = registers[15] - 4;
    
    const auto rm = registers[instruction & 0xF];
    if (rm & 1) { // this is ugly but gotta get that speed
        cpsr.thumb = true;
        registers[15] = (rm & ~1) + 4; // fake pipeline
    }

    else 
        registers[15] = (rm & ~3) + 8; // fake pipeline
}

void ARM_SWI (u32 instruction) {
    //printf("SWI %d\n", instruction & 0xff);

    const auto lr = registers[15] - 4;
    const auto newSPSR = cpsr.raw;

    setMode(CPUModes::SVC);
    registers[14] = lr;
    cpsr.irqDisable = 1;
    
    registers[15] = 0x08; // Jump to SWI vector
    spsr.raw = newSPSR;
    registers[15] += 8; // Fake pipeline
}