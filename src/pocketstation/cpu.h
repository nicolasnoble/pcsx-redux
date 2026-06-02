#pragma once
#include <array>
#include <cassert>
#include "types.h"
#include "bus.h"

enum CPUModes {
    User = 0x10,
    FIQ  = 0x11,
    IRQ  = 0x12,
    SVC  = 0x13,
    ABT  = 0x17,
    UND  = 0x1B,
    System  = 0x1F
};

enum ARMInstrTypes {
    DataProcessing,
    Branch,
    BX, // Stupid instructions that don't want to fit in with the rest
    SWI,
    Multiply,
    MultiplyLong,
    PSRTransfer,
    Swap,
    LoadStoreWord, // load store byte/word
    LoadStoreMisc, // load store halfword/doubleword/sign extended value
    LoadStoreMultiple,
    UndefinedInstruction
};

union PSR {
    u32 raw;
    struct {
        unsigned mode: 5; // Current CPU mode
        unsigned thumb: 1; // is in thumb mode?
        unsigned fiqDisable: 1; // are FIQs disabled?
        unsigned irqDisable: 1; // are IRQs disabled?
        unsigned reserved: 19;

        unsigned saturation: 1; // saturation flag (Does not exist on v5)
        unsigned overflow: 1;   // overflow flag
        unsigned carry: 1;      // carry flag
        unsigned zero: 1;       // zero flag
        unsigned negative: 1;   // negative flag
    };
};
static_assert(sizeof(PSR) == 4);

class CPU {
    typedef void (CPU::*InstructionCallback) (u32 instruction); // function pointer type for instructions
    std::array <u32, 16> registers;
    PSR cpsr;
    PSR spsr;
    Bus& bus;

    std::array<u32, 2> r8_banks;
    std::array<u32, 2> r9_banks;
    std::array<u32, 2> r10_banks;
    std::array<u32, 2> r11_banks;
    std::array<u32, 2> r12_banks;
    std::array<u32, 6> r13_banks;
    std::array<u32, 6> r14_banks;
    std::array<PSR, 5> spsr_banks;

    std::array<u32, 3> pipeline; // ARM pipeline

    static constexpr u32 pageSize = 1 << 11;
    
    // Page tables used for software fastmem. These are copies of Bus::readTable and Bus::writeTable
    uintptr_t *readTable, *writeTable;

    /// The CPU core uses function pointer tables instead of fully decoding instructions on the fly
    std::array<InstructionCallback, 4096> ARM_LUT;
    std::array<InstructionCallback, 256> Thumb_LUT;
    
    static constexpr std::array <u16, 16> COND_TABLE = { // table of masks used for evaluating instruction codes
        0xF0F0, // EQ (z)
        0x0F0F, // NE (!z)
        0xCCCC, // CS (c)
        0x3333, // CC (!c)
        0xFF00, // MI (n)
        0x00FF, // PL (!n)
        0xAAAA, // VS (v)
        0x5555, // VC (!v)
        0x0C0C, // HI (c && !z)
        0xF3F3, // LS (!c || z)
        0xAA55, // GE (n == v)
        0x55AA, // LT (n != v)
        0x0A05, // GT (!z && n == v)
        0xF5FA, // LE (z || n != v)
        0xFFFF, // AL (always)
        0x0000, // NV (never, used for special instructions in v5+)
    };

    void refillPipeline();
    void advancePipeline();

    void executeARM();
    void executeThumb();
    bool isConditionTrue(int cond);
    void setCPSR(u32 val);
    void setMode(CPUModes mode);
    void setNZ(u32 number);

    // inline files for instruction handlers (these get thrown into inline files)
    #include "cpu/helpers.inl"
    #include "cpu/arm/branch.inl"
    #include "cpu/arm/dataProcessing.inl"
    #include "cpu/arm/loadsStores.inl"
    #include "cpu/arm/loadStoreMultiple.inl"
    #include "cpu/arm/multiplication.inl"
    #include "cpu/arm/psrTransfers.inl"

    #include "cpu/thumb/dataProcessing.inl"
    #include "cpu/thumb/branch.inl"
    #include "cpu/thumb/loadStoreMultiple.inl"
    #include "cpu/thumb/loadsStores.inl"

    // code for table generation here
    #include "cpu/tablegen.inl" 

    void handleUndefined(u32 instruction);
    void pollInterrupts();

public:
    void log() {
        printf("PC: %08X\n", registers[15]);
    }
    void reset() {
        readTable = bus.readTable.data();
        writeTable = bus.writeTable.data();

        registers[15] = 0;
        cpsr.raw = 0x5F;
        spsr.raw = 0x5F;

        // On reset, the BIOS is mapped over RAM until the BIOS writes 3 to F_CTRL
        readTable[0] = (uintptr_t)&bus.bios[0];
        u32 page = 0x4000000 / pageSize;

        // Map the 16 KiB (8 pages) of BIOS memory as read-only
        for (u32 i = 0; i < 8; i++) {
            const auto pointer = (uintptr_t)&bus.bios[i * pageSize];
            readTable[page++] = pointer;
        }

        page = 0x8000000 / pageSize;
        // Map the 128 KiB (64 pages) of FLASH memory as readable
        for (u32 i = 0; i < 64; i++) {
            const auto pointer = (uintptr_t)&bus.flash.data[i * pageSize];
            writeTable[page] = pointer;
            readTable[page++] = pointer;
        }

        setCPSR(0x5F); // initialize CPSR/SPSR
        refillPipeline();
    }

    CPU(Bus& bus) : bus(bus) {
        // initialize the instruction LUTs
        populateARMTable();
        populateThumbTable();
        bus.readTable.resize(0x200000, 0);
        bus.writeTable.resize(0x200000, 0);
    }

    void write8(u32 addr, u8 val);
    void write16(u32 addr, u16 val);
    void write32(u32 addr, u32 val);
    u8 read8(u32 addr);
    u16 read16(u32 addr);
    u32 read32(u32 addr);

    void step();
};