#pragma once

enum DataProcessingAddressingMode {
    Immediate,
    ImmediateShift,
    RegisterShift
};

enum DataProcessingOpcode {
    AND = 0,
    EOR,
    SUB,
    RSB,
    ADD,
    ADC,
    SBC,
    RSC,
    TST,
    TEQ,
    CMP,
    CMN,
    ORR,
    MOV, 
    BIC, 
    MVN
};

template <bool affectFlags, DataProcessingOpcode opcode, DataProcessingAddressingMode addrMode, int shiftType>
void ARM_DataProcessing (u32 instruction) {
    u32 operand1;
    u32 operand2;

    const int rdIndex = (instruction >> 12) & 0xF; 
    const int rnIndex = (instruction >> 16) & 0xF;
    const int rmIndex = instruction & 0xF;   
    const auto oldCarry = cpsr.carry; // cache carry for ADC/SBC/RSC

    constexpr bool calculateCarryForShifts = affectFlags && (opcode != ADD && opcode != SUB && opcode != ADC && opcode != SBC && opcode != RSB && opcode != RSC &&
                                                             opcode != CMP && opcode != CMN
                                                            ); // these instruction override the carry flag from the barrel shifter so there's no point in calculating it

    if constexpr (addrMode == RegisterShift) {
        const int rsIndex = (instruction >> 8) & 0xF;
        const auto shiftAmount = registers[rsIndex] & 0xFF; // Only the low byte of rs is taken into account
        registers[15] += 4; // Edge case: When the addressing mode is shift by register, the PC is 12 steps ahead (aside for when r15 is rs)
    
        operand1 = registers [rnIndex];
        operand2 = registers [rmIndex];

        switch (shiftType) {
            case 0: operand2 = LSL <calculateCarryForShifts> (operand2, shiftAmount); break;
            case 1: operand2 = LSR <calculateCarryForShifts> (operand2, shiftAmount); break;
            case 2: operand2 = ASR <calculateCarryForShifts> (operand2, shiftAmount); break;
            case 3: operand2 = ROR <calculateCarryForShifts> (operand2, shiftAmount); break;
        }

        registers[15] -= 4; // undo the hack
    }

    else if constexpr (addrMode == Immediate) {
        const auto immediate = instruction & 0xFF;
        const auto rotateAmount = (instruction >> 8) & 0xF;
        operand1 = registers [rnIndex];
        operand2 = ROR <affectFlags> (immediate, rotateAmount * 2);
    }

    else if constexpr (addrMode == ImmediateShift) {
        auto shiftAmount = (instruction >> 7) & 31;
        operand1 = registers [rnIndex];
        operand2 = registers [rmIndex];

        switch (shiftType) {
            case 0: operand2 = LSL <calculateCarryForShifts> (operand2, shiftAmount); break;
            case 1: 
                if (!shiftAmount) shiftAmount = 32;
                operand2 = LSR <calculateCarryForShifts> (operand2, shiftAmount);
                break;

            case 2:
                if (!shiftAmount) shiftAmount = 32;
                operand2 = ASR <calculateCarryForShifts> (operand2, shiftAmount);
                break;

            case 3:
                if (!shiftAmount)
                    operand2 = RRX <calculateCarryForShifts> (operand2);
                else
                    operand2 = ROR <calculateCarryForShifts> (operand2, shiftAmount);
                break;
        }
    }

    switch (opcode) {
        case ADD: registers[rdIndex] = _ADD <affectFlags> (operand1, operand2); break; // ADD
        case ADC: registers[rdIndex] = _ADC <affectFlags> (operand1, operand2, oldCarry); break; // ADC
        case SUB: registers[rdIndex] = _SUB <affectFlags> (operand1, operand2); break; // SUB
        case RSB: registers[rdIndex] = _SUB <affectFlags> (operand2, operand1); break; // RSB
        case SBC: registers[rdIndex] = _SBC <affectFlags> (operand1, operand2, oldCarry); break; // SBC
        case RSC: registers[rdIndex] = _SBC <affectFlags> (operand2, operand1, oldCarry); break; // RSC
        case BIC: registers[rdIndex] = _BIC <affectFlags> (operand1, operand2); break; // BIC
        case AND: registers[rdIndex] = _AND <affectFlags> (operand1, operand2); break; // AND
        case ORR: registers[rdIndex] = _ORR <affectFlags> (operand1, operand2); break; // ORR
        case EOR: registers[rdIndex] = _EOR <affectFlags> (operand1, operand2); break; // ORR
        case MOV: ARM_MOV <affectFlags> (rdIndex, operand2); break; // MOV
        case MVN: ARM_MOV <affectFlags> (rdIndex, ~operand2); break; // MVN
        case TST: _AND <true> (operand1, operand2); break; // TST
        case TEQ: _EOR <true> (operand1, operand2); break; // TEQ
        case CMN: _ADD <true> (operand1, operand2); break; // CMN
        case CMP: _SUB <true> (operand1, operand2); break; // CMP
        default: Helpers::panic ("Unimplemented DP opcode: %d\n", opcode);
    }
    
    registers[15] += 4;

    if (rdIndex == 15) {
        // Don't do anything special if the instruction doesn't actually write to r15
        if constexpr (opcode == TEQ || opcode == CMP || opcode == TST || opcode == CMN) return;
        registers[15] += 4; // fake pipeline
        registers[15] &= ~3; // force align address
        if constexpr (affectFlags) Helpers::panic ("DP instruction with rd==r15 and S bit set");
    }
}

template <bool affectFlags>
void ARM_MOV (int rdIndex, u32 operand2) {
    if constexpr (affectFlags)
        setNZ (operand2);
    registers [rdIndex] = operand2;
}