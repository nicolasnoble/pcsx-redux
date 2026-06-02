#pragma once

enum LoadStoreAddrModes {
    ImmediateOffset,
    RegisterOffset
};

template <LoadStoreAddrModes addressingMode, bool isLoad, bool writeback, bool isByte, bool addToBase, bool preIndexing, int shiftType>
void ARM_handleLoadStore (u32 instruction) {
    constexpr auto isUser = writeback && !preIndexing;  
    const int rdIndex = (instruction >> 12) & 0xF;
    const int rnIndex = (instruction >> 16) & 0xF;
    
    u32 rn = registers [rnIndex];
    u32 address = rn;
    u32 offset = 0;

    if constexpr (addressingMode == ImmediateOffset)
        offset = instruction & 0xFFF;
    else {
        const auto rm = registers [instruction & 0xF];
        auto shiftAmount = (instruction >> 7) & 31;

        switch (shiftType) {
            case 0: offset = LSL <false> (rm, shiftAmount); break;
            case 1: 
                if (!shiftAmount) shiftAmount = 32;
                offset = LSR <false> (rm, shiftAmount);
                break;

            case 2:
                if (!shiftAmount) shiftAmount = 32;
                offset = ASR <false> (rm, shiftAmount);
                break;

            case 3:
                if (!shiftAmount)
                    offset = RRX <false> (rm);
                else
                    offset = ROR <false> (rm, shiftAmount);
                break;
        }
    }

    if constexpr (addToBase) rn += offset;
    else rn -= offset;
        
    if constexpr (preIndexing) address = rn; // if pre-indexing, set address to rn, else keep it the same

    if constexpr (isLoad) { // find out the instruction type
        if constexpr (isByte) {
            if constexpr (isUser) Helpers::panic ("LDRBT");
            else ARM_LDRB <false> (rdIndex, address);
        }

        else {
            if constexpr (isUser) Helpers::panic ("LDRT");
            else ARM_LDR (rdIndex, address);
        }
    }

    else {
        if constexpr (isByte) {
            if constexpr (isUser) Helpers::panic ("STRBT");
            else ARM_STRB (rdIndex, address);
        }

        else {
            if constexpr (isUser) Helpers::panic ("STRT");
            else ARM_STR (rdIndex, address);
        }
    }

    if constexpr (!(preIndexing && !writeback)) { // apply writeback
        if constexpr (!isLoad) 
             registers [rnIndex] = rn;
        else {
            if (rnIndex != rdIndex) 
                registers [rnIndex] = rn; // Don't apply writeback on loads with rn==rd
        }
    }
}

template <LoadStoreAddrModes addressingMode, bool isHalfword, bool signExtend, bool isLoad, bool writeback, bool addToBase, bool preIndexing>
void ARM_handleLoadStoreMisc (u32 instruction) {
    const int rdIndex = (instruction >> 12) & 0xF;
    const int rnIndex = (instruction >> 16) & 0xF;
    
    auto rn = registers [rnIndex];
    auto address = rn;
    u32 offset;

    if constexpr (addressingMode == ImmediateOffset)
        offset = (instruction & 0xF) | ((instruction >> 4) & 0xF0);
    else 
        offset = registers [instruction & 0xF];

    if constexpr (addToBase)
        rn += offset;
    else 
        rn -= offset;

    if constexpr (preIndexing) address = rn;

    if constexpr (isLoad) { // find out the instruction type
        if constexpr (isHalfword) {
            if constexpr (signExtend) ARM_LDRH <true> (rdIndex, address);
            else ARM_LDRH <false> (rdIndex, address);
        }

        else {
            if constexpr (signExtend) ARM_LDRB <true> (rdIndex, address);
            else Helpers::panic ("Invalid load/store instruction");
        }
    }

    else {
        if constexpr (isHalfword) {
            if constexpr (signExtend) Helpers::panic ("STRD (ARMv5+)");
            else ARM_STRH (rdIndex, address);
        }

        else {
            if constexpr (signExtend) Helpers::panic ("LDRD (ARMv5+)");
            else Helpers::panic ("Invalid load/store instruction");
        }
    }
    
    if constexpr (!(preIndexing && !writeback)) { // apply writeback (post indexed accesses always have writeback)
        if constexpr (!isLoad) 
             registers [rnIndex] = rn;
        else {
            if (rnIndex != rdIndex) 
                registers [rnIndex] = rn; // Don't apply writeback on loads with rn==rd
        }
    }
}

void ARM_STR (int rdIndex, u32 address) {
    auto src = registers [rdIndex];
    if (rdIndex == 15) 
        src += 4; // When storing r15, it's 3 steps ahead instead of 2
    write32 (address, src);

    registers[15] += 4; // fake pipeline
}

template <bool signExtend>
void ARM_LDRB (int rdIndex, u32 address) {
    auto src = read8 (address);
    if (rdIndex == 15) Helpers::panic ("LDRH with r15 == rd\n");
    
    if constexpr (!signExtend) registers [rdIndex] = src;
    else registers [rdIndex] = Helpers::signExtend32 (src, 8);

    registers[15] += 4; // fake pipeline
}

template <bool signExtend>
void ARM_LDRH (int rdIndex, u32 address) {
    auto src = read16 (address);
    if (rdIndex == 15) Helpers::panic ("LDRH with r15 == rd\n");
    
    if constexpr (!signExtend) registers [rdIndex] = src;
    else registers [rdIndex] = Helpers::signExtend32 (src, 16);

    registers[15] += 4; // fake pipeline
}

void ARM_LDR (int rdIndex, u32 address) {
    const auto val = ROR <false> (read32 (address & ~3), (address & 3) * 8); // The ROR handles unaligned addresses
    registers [rdIndex] = val;

    if (rdIndex == 15) {
        registers[15] = (val & ~3) + 8; // fake pipeline
    }

    else registers[15] += 4; // fake pipeline
}

void ARM_STRB (int rdIndex, u32 address) {
    auto src = registers [rdIndex];
    if (rdIndex == 15) Helpers::panic ("STRB with r15 == rd\n");
    write8 (address, (u8) src);

    registers[15] += 4; // fake pipeline
}

void ARM_STRH (int rdIndex, u32 address) {
    auto src = registers [rdIndex];
    if (rdIndex == 15) Helpers::panic ("STRH with r15 == rd\n");
    write16 (address, (u16) src);

    registers[15] += 4; // fake pipeline
}

template <bool isByte>
void ARM_Swap (u32 instruction) {
    const auto rm = registers [instruction & 0xF];
    const auto rn = registers [(instruction >> 16) & 0xF];

    const auto rdIndex = (instruction >> 12) & 0xF;
    if (rdIndex == 15) Helpers::panic ("rd == r15 in swap");

    if constexpr (isByte) { // SWPB
        registers[rdIndex] = read8 (rn);
        write8 (rn, (u8) rm);
    }

    else { // SWP
        auto loadedVal = read32 (rn & ~3); // handle alignment in a similar fashion to LDR
        loadedVal = ROR <false> (loadedVal, 8 * (rn & 3)); 

        registers[rdIndex] = loadedVal;
        write32 (rn & ~3, rm);// force align the address for the store        
    }

    registers[15] += 4; // fake pipeline
}