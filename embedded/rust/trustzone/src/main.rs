//! The two worlds of the TrustZone image.
//!
//! The Secure world is entered first, on reset. It is the only one that may
//! program the Security Attribution Unit, and it is where keys and other
//! secrets belong. When it is done, it hands the core over to the Non-secure
//! world, which is where an application would normally run.
//!
//! The handover itself is assembly, because it needs `BLXNS` — the only
//! instruction that can leave the Secure state. Everything else is ordinary
//! Rust.
//!
//! This is the skeleton the box builds: the plumbing is here, and the two
//! functions below are where your code goes.

#![no_std]
#![no_main]

use core::arch::asm;

/// There is no operating system to panic into, so a panic just spins.
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {
        unsafe { asm!("wfi"); }
    }
}

/// Programs the Security Attribution Unit.
///
/// Region 0 of the SAU is given to the Non-secure world: the 2 MiB at the
/// Non-secure alias, `0x0010_0000` through `0x001F_FFFF`. The rest stays
/// Secure. The `NSC` bit makes the region callable from the Non-secure world.
fn configure_sau() {
    unsafe {
        // region 0 of the SAU is the Non-secure one
        core::ptr::write_volatile(0xE000_EDD8 as *mut u32, 0);
        // it covers the Non-secure alias the image was linked at
        core::ptr::write_volatile(0xE000_EDDC as *mut u32, 0x0010_0000);
        core::ptr::write_volatile(0xE000_EDE0 as *mut u32, 0x001F_FFFF | 0x03);
        // and turn the SAU on
        core::ptr::write_volatile(0xE000_EDD0 as *mut u32, 1);
    }
}

/// The Non-secure world's entry point.
///
/// Held in a `#[used]` static so that the linker keeps it: nothing else
/// references it, and without this it would be discarded.
#[used]
static NONSECURE: unsafe extern "C" fn() -> ! = nonsecure_main;

/// Hands the core over to the Non-secure world.
///
/// The branch has to be a `BLXNS`, which is the only instruction that can
/// leave the Secure state; an ordinary call would fault.
///
/// Kept compiled either way, so that it is still type checked and the image
/// still carries a Non-secure world even on a normal boot that never reaches
/// it. Without the handover feature nothing calls it, hence the attribute.
#[cfg_attr(not(feature = "handover"), allow(dead_code))]
fn switch_to_nonsecure() -> ! {
    // Bit 0 of the target says which instruction set to branch into, and
    // ARMv8-M has only Thumb. Branching to the bare address, with bit 0
    // clear, is a branch into ARM state, which ARMv8-M does not have, so the
    // core takes a SecureFault with SFSR.INVEP and the whole vm lockups.
    // Under a debugger the fault can look like a handover that half worked,
    // which is worse than not working at all.
    let entry = NONSECURE as usize | 1;
    unsafe { asm!("blxns {}", in(reg) entry as u32); }
    // not expected to come back; spin if it does
    loop {
        unsafe { asm!("wfi"); }
    }
}

// The vector table the core reads on reset: the initial stack pointer, and
// the address of the Secure entry point. The address is filled in by the
// linker, which also sets the Thumb bit on it, so it is written as assembly
// rather than as data the compiler would have to evaluate.
core::arch::global_asm!(
	".section .vector_table",
	".word 0x10100000",
	".word Reset_Handler",
);

/// The Secure world. Runs first, with the whole of memory at its disposal.
///
/// Whether it then hands the core over is a build setting rather than a
/// run-time one, so that a normal boot is just a normal boot: the Secure
/// world starts, does its work, and stays there. The handover is what makes
/// this a dual-world image, and it is opt-in, so that the world switch is
/// something you ask for rather than something the firmware always does to
/// you.
#[no_mangle]
pub extern "C" fn Reset_Handler() -> ! {
    // your secure-world code here: keys, secrets, the trusted part

    configure_sau();

    #[cfg(feature = "handover")]
    switch_to_nonsecure();

    // Without the handover, stay in the Secure world.
    #[cfg(not(feature = "handover"))]
    loop {
        unsafe { asm!("wfi"); }
    }
}

/// The Non-secure world. Runs after the handover, and can only reach the
/// region the SAU was told about.
#[no_mangle]
#[link_section = ".text.nonsecure"]
pub extern "C" fn nonsecure_main() -> ! {
    // your non-secure-world code here: the application

    loop {
        unsafe { asm!("wfi"); }
    }
}
