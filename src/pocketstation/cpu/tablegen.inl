
// Thanks to Fleroviux (https://github.com/fleroviux) for helping me achieve template nirvana
// And also for helping me on countless other stuff

template <u32 index>
constexpr ARMInstrTypes ARM_getInstructionType() { // get the type of an instruction based on its 12-bit hash. Used to fill the ARM LUT
    if constexpr ((index & 0xF01) == 0xE00) // coprocessor data operations
        return ARMInstrTypes::UndefinedInstruction;

    else if constexpr ((index & 0xF01) == 0xE01) // coprocessor register transfers
        return ARMInstrTypes::UndefinedInstruction;

    else if constexpr ((index >> 9) == 0b110) // coprocessor data transfer
        return ARMInstrTypes::UndefinedInstruction;

    else if constexpr (index == 0b000101100001) // CLZ (v5+)
        return ARMInstrTypes::UndefinedInstruction;

    else if constexpr (index == 0b000100000101) // QADD (v5+)
        return ARMInstrTypes::UndefinedInstruction;

    else if constexpr ((index & 0xF00) == 0xF00) // SWI
        return ARMInstrTypes::SWI;
    
    else if constexpr ((index >> 7) == 0b00010 && (index & 0xF) == 0 && !Helpers::isBitSet(index, 4) || ((index >> 7) == 0b00110 && !Helpers::isBitSet(index, 4))) // PSR transfer
        return ARMInstrTypes::PSRTransfer;

    else if constexpr ((index & 0xF8F) == 0x89) // multiply long
        return ARMInstrTypes::MultiplyLong;

    else if constexpr ((index & 0xFCF) == 9) // multiply
        return ARMInstrTypes::Multiply;

    else if constexpr ((index & 0xFBF) == 0x109) // swap
        return ARMInstrTypes::Swap;
    
    else if constexpr (index == 0b000100100001 || index == 0b000100100011)
        return ARMInstrTypes::BX;
    
    else if constexpr ((index >> 9) == 0b101)
        return ARMInstrTypes::Branch;

    else if constexpr ((index >> 10) == 1)
        return ARMInstrTypes::LoadStoreWord;

    else if constexpr ((index & 0b1001) == 0b1001 && (index >> 9) == 0)
        return ARMInstrTypes::LoadStoreMisc;

    else if constexpr ((index >> 9) == 0b100)
        return ARMInstrTypes::LoadStoreMultiple;
    
    else if constexpr ((index >> 9) == 0b001 || (index >> 9) == 0)
        return ARMInstrTypes::DataProcessing;
    
    return ARMInstrTypes::UndefinedInstruction;
}

template <u32 index>
constexpr InstructionCallback ARM_getInstructionHandler() { // returns the function pointer that corresponds to the instruction's 12 bit hash. Used to fill the ARM LUT
    const auto type = ARM_getInstructionType<index>();
    switch (type) {
        case ARMInstrTypes::Branch: {
            constexpr bool link = Helpers::isBitSet (index, 8);
            return &CPU::ARM_Branch<link>;
        }

        case ARMInstrTypes::DataProcessing: {
            constexpr bool affectFlags = Helpers::isBitSet (index, 4); // will this operation affect flags?
            constexpr auto opcode = (DataProcessingOpcode) ((index >> 5) & 0xF); // The opcode. AND, EOR, SUB, ADD...
            constexpr int shiftType = (index >> 1) & 0x3; // The kind of shift: LSL/LSR/ASR/ROR/RRX

            if constexpr ((index >> 9) == 0b001)
                return &CPU::ARM_DataProcessing<affectFlags, opcode, Immediate, shiftType>;
            else if constexpr ((index & 1) == 0)
                return &CPU::ARM_DataProcessing<affectFlags, opcode, ImmediateShift, shiftType>;
            else
                return &CPU::ARM_DataProcessing<affectFlags, opcode, RegisterShift, shiftType>;            
        }

        case ARMInstrTypes::LoadStoreWord: {
            constexpr int shiftType = (index >> 1) & 0x3; // The kind of shift: LSL/LSR/ASR/ROR/RRX
            constexpr bool isLoad = Helpers::isBitSet (index, 4);
            constexpr bool writeback = Helpers::isBitSet (index, 5);
            constexpr bool isByte = Helpers::isBitSet (index, 6);
            constexpr bool addToBase = Helpers::isBitSet (index, 7);
            constexpr bool preIndexing = Helpers::isBitSet (index, 8);
            
            if constexpr ((index >> 9) & 1)
                return &CPU::ARM_handleLoadStore<RegisterOffset, isLoad, writeback, isByte, addToBase, preIndexing, shiftType>;
            else
                return &CPU::ARM_handleLoadStore<ImmediateOffset, isLoad, writeback, isByte, addToBase, preIndexing, shiftType>;
        }

        case ARMInstrTypes::LoadStoreMisc: {
            const bool isHalfword = Helpers::isBitSet (index, 1);
            const bool signExtend = Helpers::isBitSet (index, 2);
            const bool isLoad = Helpers::isBitSet (index, 4);
            constexpr bool writeback = Helpers::isBitSet (index, 5);
            constexpr bool addToBase = Helpers::isBitSet (index, 7);
            constexpr bool preIndexing = Helpers::isBitSet (index, 8);

            if constexpr (Helpers::isBitSet(index, 6))
                return &CPU::ARM_handleLoadStoreMisc<ImmediateOffset, isHalfword, signExtend, isLoad, writeback, addToBase, preIndexing>;
            else 
                return &CPU::ARM_handleLoadStoreMisc<RegisterOffset, isHalfword, signExtend, isLoad, writeback, addToBase, preIndexing>;
        }

        case ARMInstrTypes::LoadStoreMultiple: {
            constexpr auto addrMode = (LoadStoreMultipleAddrMode) ((index >> 7) & 3);
            constexpr bool writeback = Helpers::isBitSet (index, 5);
            constexpr bool switchToUser = Helpers::isBitSet (index, 6);

            if constexpr (Helpers::isBitSet(index, 4))
                return &CPU::ARM_handleLDM<addrMode, writeback, switchToUser>;
            else
                return &CPU::ARM_handleSTM<addrMode, writeback, switchToUser>;
        }

        case ARMInstrTypes::BX: {
            if constexpr (index == 0b000100100001) return &CPU::ARM_BX<false>; // BX
            else return &CPU::ARM_BX<true>; // BLX
        }

        case ARMInstrTypes::Multiply: {
            constexpr bool affectFlags = Helpers::isBitSet (index, 4); // Should this operation affect flags?
            constexpr bool accumulate  = Helpers::isBitSet (index, 5); // if 1, this operation is MLA, else MUL

            return &CPU::ARM_Multiply<affectFlags, accumulate>; 
        }

        case ARMInstrTypes::MultiplyLong: {
            constexpr bool affectFlags = Helpers::isBitSet (index, 4); // Should this operation affect flags?
            constexpr auto opcode  = (MultiplyLongOpcode) ((index >> 5) & 3);

            return &CPU::ARM_MultiplyLong<affectFlags, opcode>; 
        }
        
        case ARMInstrTypes::Swap: {
            constexpr bool isByte = Helpers::isBitSet (index, 6);

            return &CPU::ARM_Swap<isByte>;
        }

        case ARMInstrTypes::PSRTransfer: {
            const bool isMSR = Helpers::isBitSet (index, 5);
            const bool isImmediate = Helpers::isBitSet (index, 9);

            return &CPU::psrTransfer<isMSR, isImmediate>;
        }
        
        case ARMInstrTypes::SWI: return &CPU::ARM_SWI;

        default: return &CPU::handleUndefined;
    }
}

template <u32 index>
constexpr InstructionCallback Thumb_getInstructionHandler() {
    if constexpr ((index >> 5) == 1) { // movs/cmp/adds/subs rd, #imm
        constexpr int opcode = (index >> 3) & 3;
        return &CPU::Thumb_DataProcessingImmediate<opcode>;
    }

    else if constexpr ((index >> 4) == 0xF)  { // Thumb BL
        constexpr bool part = (index >> 3) & 1; // Thumb BL instructions are split into 2 parts 
        return &CPU::Thumb_BL<part>;
    }

    else if constexpr ((index >> 3) == 0b11000) { // stmia rb! {rlist}
        return &CPU::Thumb_STMIA;
    }

    else if constexpr ((index >> 3) == 0b11001) { // ldmia rb! {rlist}
        return &CPU::Thumb_LDMIA;
    }

    else if constexpr ((index >> 1) == 0b1011010) { // Thumb PUSH
        constexpr bool pushLR = index & 1;
        return &CPU::Thumb_PUSH<pushLR>;
    }

    else if constexpr ((index >> 1) == 0b1011110) { // Thumb POP
        constexpr bool popPC = index & 1;
        return &CPU::Thumb_POP<popPC>;
    }

    else if constexpr ((index >> 3) == 0b1001) { // PC relative load
        return &CPU::Thumb_PCRelativeLoad;
    }

    else if constexpr ((index >> 4) == 0x8) { // Halfword load/store with imm
        constexpr bool isLoad = (index >> 3) & 1;
        return &CPU::Thumb_HalfwordTransferImm<isLoad>;
    }

    else if constexpr ((index >> 2) ==  0b010110) { // Load halfword/word with reg
        constexpr bool isHalfword = (index >> 1) & 1;
        return &CPU::Thumb_loadWithReg<isHalfword>;
    }

    else if constexpr ((index >> 3) == 1) return &CPU::Thumb_shiftRight<false>; // LSRS
    else if constexpr ((index >> 3) == 2) return &CPU::Thumb_shiftRight<true>; // ASRS
    else if constexpr ((index >> 4) == 0b1101) return &CPU::Thumb_conditionalBranch; // bcond

    else if constexpr ((index >> 2) == 0b010001) {
        constexpr int opcode = index & 3;
        return &CPU::Thumb_highRegisterOperation<opcode>;
    }

    else if constexpr ((index >> 4) == 0b0110) {
        constexpr bool isLoad = (index >> 3) & 1;
        return &CPU::Thumb_WordTransferImm<isLoad>;
    }

    else if constexpr ((index >> 3) == 0) 
        return &CPU::Thumb_LSL;

    else if constexpr ((index >> 2) == 0b010000)
        return &CPU::Thumb_handleALU;

    else if constexpr ((index >> 2) == 0b000110) { // ADDS/SUBS rd, rn, rs
        constexpr bool isSub = (index >> 1) & 1;
        return &CPU::Thumb_addSubReg<isSub>;
    }

    else if constexpr ((index >> 1) == 0b0101110) return &CPU::Thumb_ByteTransferReg<true>; // LDRB reg
    else if constexpr ((index >> 1) == 0b0101010) return &CPU::Thumb_ByteTransferReg<false>; // STRB reg
    else if constexpr ((index >> 4) == 0b0111) { // LDRB/STRB imm
        constexpr bool isLoad = (index >> 3) & 1;
        return &CPU::Thumb_ByteTransferImm<isLoad>; 
    }

    else if constexpr ((index >> 2) == 0b000111) {
        constexpr bool isSub = (index >> 1) & 1;
        return &CPU::Thumb_addSubOffset<isSub>;
    }

    else if constexpr ((index >> 3) == 0b11100) return &CPU::Thumb_B; // Branch instruction
    else if constexpr ((index >> 4) == 0b1010) {
        constexpr bool isSPRelative = (index >> 3) & 1;
        return &CPU::Thumb_loadAddress<isSPRelative>; // adr
    }

    else if constexpr (index == 0xB0) return &CPU::Thumb_addToSP;
    else if constexpr ((index >> 1) == 0b0101000) { return &CPU::Thumb_storeWordWithReg; }
    else if constexpr ((index >> 1) == 0b0101011) { return &CPU::Thumb_LDRSB; }
    else if constexpr ((index >> 1) == 0b0101111) { return &CPU::Thumb_LDRSH; }
    else if constexpr ((index >> 3) == 0b10010) return &CPU::Thumb_SPRelativeStore;
    else if constexpr ((index >> 3) == 0b10011) return &CPU::Thumb_SPRelativeLoad;

    else return &CPU::handleUndefined;
}

void populateARMTable() {
    Helpers::static_for<std::size_t, 0, 4096>([&](auto i) {
      ARM_LUT[i] = ARM_getInstructionHandler<i>();
    });
}

void populateThumbTable() {
    Helpers::static_for<std::size_t, 0, 256>([&](auto i) {
        Thumb_LUT[i] = Thumb_getInstructionHandler<i>();
    });
}