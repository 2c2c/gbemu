//! DMG boot ROM (the 256-byte program mapped over $0000-$00FF at power-on).
//!
//! `dmg_boot.bin` is SameBoy's open-source, MIT-licensed reimplementation of the
//! original Game Boy boot ROM (https://github.com/LIJI32/SameBoy, BootROMs/).
//! It is NOT Nintendo's copyrighted boot ROM — it is a clean reimplementation
//! that produces a hardware-compatible boot sequence and post-boot state, which
//! is what the mooneye `boot_*` acceptance tests verify.
//!
//!   SHA1(dmg_boot.bin) = 1db57a1e8b6e4096f811587f9eab0c6675fd9755
//!
//! At power-on the CPU starts at PC=$0000 executing this ROM; it clears VRAM,
//! initialises the audio/PPU registers, scrolls the Nintendo logo, verifies the
//! cartridge header logo + checksum, then writes $01 to $FF50 to unmap itself and
//! hands control to the cartridge entrypoint at $0100.

/// The DMG boot ROM image, exactly 256 bytes.
pub const dmg: *const [0x100]u8 = @embedFile("dmg_boot.bin");

comptime {
    if (dmg.len != 0x100) @compileError("dmg_boot.bin must be exactly 256 bytes");
}
