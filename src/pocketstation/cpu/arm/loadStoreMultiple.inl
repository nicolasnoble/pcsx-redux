#pragma once

enum LoadStoreMultipleAddrMode {
    DA,
    IA,
    DB,
    IB
};

template <LoadStoreMultipleAddrMode addrMode, bool writeback, bool switchToUser>
void ARM_handleSTM (u32 instruction) {
    const auto currentMode = (CPUModes) cpsr.mode;
    if constexpr (switchToUser) {
        Helpers::panic("User mode STM");
        setMode (User);
    }

    const auto rlist = instruction & 0xFFFF; 
    const auto rbIndex = (instruction >> 16) & 0xF;
    auto sp = registers[rbIndex];
    const auto startingSP = sp;
    
    if (!rlist) Helpers::panic ("STM with empty rlist");
    if (rbIndex == 15) Helpers::panic ("STM with r15 as rb");
    if ((1 << rbIndex) & instruction) Helpers::warn ("rb in rlist");

    if constexpr (addrMode == IA || addrMode == IB) {
        for (auto i = 0; i < 16; i++) {
            if ((1 << i) & instruction) { // if register is in rlist
                if constexpr (addrMode == IB) sp += 4;
                write32 (sp, registers[i]);
                if constexpr (addrMode == IA) sp += 4;
            }
        }
    }

    else {
        for (int i = 15; i >= 0; i--) {
            if ((1 << i) & instruction) { // if register is in rlist
                if constexpr (addrMode == DB) sp -= 4;
                write32 (sp, registers[i]);
                if constexpr (addrMode == DA) sp -= 4;
            }
        }
    }

    if constexpr (writeback) {
        registers[rbIndex] = sp;
    }

    if constexpr (switchToUser) {
        if ((1 << 15) & instruction) Helpers::panic ("User mode STM with r15 in rlist");
        setMode ((CPUModes) currentMode);
    }

    registers [15] += 4; // fake pipeline   
}

template <LoadStoreMultipleAddrMode addrMode, bool writeback, bool switchToUser>
void ARM_handleLDM (u32 instruction) {
    const auto currentMode = (CPUModes) cpsr.mode;

    const auto rlist = instruction & 0xFFFF; 
    const auto rbIndex = (instruction >> 16) & 0xF;
    auto sp = registers[rbIndex];
    const auto startingSP = sp;

    bool switchMode = switchToUser && (((1 << 15) & rlist) == 0);

    if (switchMode) {
        Helpers::panic("User mode LDM");
        setMode(User);
    }
    
    if (!rlist) Helpers::panic ("LDM with empty rlist");
    if (rbIndex == 15) Helpers::panic ("LDM with r15 as rb");

    if constexpr (addrMode == IA || addrMode == IB) {
        for (auto i = 0; i < 16; i++) {
            if ((1 << i) & instruction) { // if register is in rlist
                if constexpr (addrMode == IB) sp += 4;
                registers[i] = read32 (sp);
                if constexpr (addrMode == IA) sp += 4;
            }
        }
    }

    else {
        for (int i = 15; i >= 0; i--) {
            if ((1 << i) & instruction) { // if register is in rlist
                if constexpr (addrMode == DB) sp -= 4;
                registers[i] = read32 (sp);
                if constexpr (addrMode == DA) sp -= 4;
            }
        }
    }

    if (switchMode) {
        setMode ((CPUModes) currentMode);
    }

    if constexpr (writeback) {
        if (!((1 << rbIndex) & instruction)) { // Writeback only if rb is not in rlist
            registers[rbIndex] = sp;
        }
    }

    if ((1 << 15) & instruction) {
        if constexpr (switchToUser) { // LDM with user mode enabled and r15 in rlist restores SPSR
            setCPSR(spsr.raw);
        }

        registers[15] += (cpsr.thumb) ? 4 : 8; // fake pipeline
    } else {
        registers [15] += 4; // fake pipeline  
    }
}
