#pragma once

template <bool isMSR, bool isImmediate>
void psrTransfer (u32 instruction) {  
    const bool isSPSR = Helpers::isBitSet (instruction, 22); // should this instruction operate on CPSR or SPSR?
    
    if constexpr (isMSR) { // MSR
        const bool isPrivileged = cpsr.mode != User;
        u32 operand = 0;
        u32 mask = 0;

        if constexpr (isImmediate) {
            const auto imm = instruction & 0xFF;
            const auto rotate_imm = (instruction >> 8) & 0xF;
            operand = ROR <false> (imm, rotate_imm * 2);
        }    

        else
            operand = registers[instruction & 0xF];

        if (Helpers::isBitSet(instruction, 16) && isPrivileged) mask |= 0xFF;
        if (Helpers::isBitSet(instruction, 17) && isPrivileged) mask |= 0xFF00;
        if (Helpers::isBitSet(instruction, 18) && isPrivileged) mask |= 0xFF'0000;
        if (Helpers::isBitSet(instruction, 19)) {
            if (isPrivileged) mask |= 0xFF00'0000;
            else mask |= 0xF000'0000;
        }

        operand &= mask;
        if (isSPSR) {
            if (cpsr.mode == User || cpsr.mode == System) Helpers::panic ("Accessed SPSR in invalid mode");
            spsr.raw =  (spsr.raw & ~mask) | operand;
        }

        else 
            setCPSR ((cpsr.raw & ~mask) | operand);
    }

    else { // MRS
        const auto rdIndex = (instruction >> 12) & 0xF;
        if (rdIndex == 15) Helpers::panic ("MRS with rd == r15");
        
        if (isSPSR) registers[rdIndex] = spsr.raw;
        else registers[rdIndex] = cpsr.raw;
    }

    registers[15] += 4; // fake pipeline
}