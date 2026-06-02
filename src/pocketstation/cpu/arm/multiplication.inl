#pragma once

enum MultiplyLongOpcode {
    UMULL,
    UMLAL,
    SMULL,
    SMLAL
};

template <bool affectFlags, bool accumulate>
void ARM_Multiply (u32 instruction) {
    const auto rm = registers[instruction & 0xF];
    const auto rs = registers[(instruction >> 8) & 0xF];
    const auto rdIndex = (instruction >> 16) & 0xF;

    if (rdIndex == 15) Helpers::panic ("Multiply with rd == r15"); // This should never happen as it's unpredictable
    u32 res;

    if constexpr (accumulate) { // MLA
        const auto rn = registers[(instruction >> 12) & 0xF];
        res = (rm * rs) + rn;
    }

    else { // MUL
        res = rm * rs;
    }
        
    if constexpr (affectFlags)
        setNZ (res);

    registers[rdIndex] = res;
    registers[15] += 4; // fake pipeline
}

template <bool affectFlags, MultiplyLongOpcode opcode>
void ARM_MultiplyLong (u32 instruction) {
    const auto rm = registers[instruction & 0xF];
    const auto rs = registers[(instruction >> 8) & 0xF];

    const auto rdLoIndex = (instruction >> 12) & 0xF;
    const auto rdHiIndex = (instruction >> 16) & 0xF;

    if (rdLoIndex == 15) Helpers::panic ("Long multiplication with rd == 15");
    if (rdHiIndex == 15) Helpers::panic ("Long multiplication with rd == 15");

    switch (opcode) {
        case UMULL: ARM_UMULL <affectFlags> (rdLoIndex, rdHiIndex, rm, rs); break;
        case UMLAL: ARM_UMLAL <affectFlags> (rdLoIndex, rdHiIndex, rm, rs); break;
        case SMULL: ARM_SMULL <affectFlags> (rdLoIndex, rdHiIndex, rm, rs); break;
        case SMLAL: ARM_SMLAL <affectFlags> (rdLoIndex, rdHiIndex, rm, rs); break;
    }

    registers[15] += 4; // fake pipeline
}

template <bool affectFlags>
void ARM_UMULL (int rdLo, int rdHi, u32 rm, u32 rs) {
    const u64 res = (u64) rm * (u64) rs;
    
    if constexpr (affectFlags) {
        cpsr.zero = res == 0;
        cpsr.negative = res >> 63;
    }

    registers[rdLo] = (u32) res;
    registers[rdHi] = res >> 32;
}

template <bool affectFlags>
void ARM_UMLAL (int rdLo, int rdHi, u32 rm, u32 rs) {
    const u64 rd = (u64) registers[rdLo] | (((u64) registers[rdHi]) << 32); 
    const u64 res = (u64) rm * (u64) rs + rd;

    if constexpr (affectFlags) {
        cpsr.zero = res == 0;
        cpsr.negative = res >> 63;
    }

    registers[rdLo] = (u32) res;
    registers[rdHi] = res >> 32;
}

template <bool affectFlags>
void ARM_SMULL (int rdLo, int rdHi, u32 rm, u32 rs) {
    const u64 res = (s64) (s32) rm * (s64) (s32) rs;
    
    if constexpr (affectFlags) {
        cpsr.zero = res == 0;
        cpsr.negative = res >> 63;
    }

    registers[rdLo] = (u32) res;
    registers[rdHi] = res >> 32;
}

template <bool affectFlags>
void ARM_SMLAL (int rdLo, int rdHi, u32 rm, u32 rs) {
    const u64 rd = (u64) registers[rdLo] | (((u64) registers[rdHi]) << 32); 
    u64 res = (s64) (s32) rm * (s64) (s32) rs;
    res += rd;

    if constexpr (affectFlags) {
        cpsr.zero = res == 0;
        cpsr.negative = res >> 63;
    }

    registers[rdLo] = (u32) res;
    registers[rdHi] = res >> 32;
}