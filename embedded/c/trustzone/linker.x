/* Linker script for a dual-world TrustZone image.
 *
 * The mps2-an505 board has 4 MiB of SSRAM that can be reached through two
 * aliases: the Secure world sees it at 0x10000000, and the Non-secure world
 * sees the very same memory at 0x00000000. The core resets with its vector
 * table at the Secure alias, which is where the image is loaded.
 *
 * The two worlds are therefore just two addresses into one piece of memory,
 * and the Security Attribution Unit is what tells them apart: below, the
 * Non-secure world is given the region at the Non-secure alias, and the
 * Secure world keeps the rest.
 *
 * Which world a function ends up in is decided by the section it is
 * compiled into, not by this script. A function marked
 * __attribute__((section(".text.nonsecure"))) lands in .nonsecure_text,
 * which is what world_switch.s branches to with a BLXNS. Get that attribute
 * wrong and the function ends up in an ordinary .text, which matches
 * nothing here: the linker keeps it as an orphan section and quietly places
 * it alongside the Secure code, leaving the Non-secure world empty. The
 * ASSERTs at the end are there to make that a link error instead.
 */

ENTRY(Reset_Handler)

MEMORY
{
	/* where the core resets, and where the box loads the image */
	SECURE (rx) : ORIGIN = 0x10000000, LENGTH = 0x00100000

	/* the Non-secure alias of the same memory, further up */
	NONSECURE (rx) : ORIGIN = 0x00100000, LENGTH = 0x00100000
}

SECTIONS
{
	.secure_text : {
		KEEP(*(.vectors))
		__secure_text_start = .;
		*(.text.secure*)
		*(.rodata.secure*)
		. = ALIGN(4);
		__secure_text_end = .;
	} > SECURE

	.secure_data : {
		__secure_data_start = .;
		*(.data.secure*)
		. = ALIGN(4);
		__secure_data_end = .;
	} > SECURE

	.secure_bss (NOLOAD) : {
		__secure_bss_start = .;
		*(.bss.secure*)
		*(COMMON)
		. = ALIGN(4);
		__secure_bss_end = .;
	} > SECURE

	/*
	 * The Non-secure entry point. world_switch.s branches to
	 * __nonsecure_text_start with a BLXNS to leave the Secure state, so
	 * this is the one symbol the image cannot be linked without.
	 */
	.nonsecure_text : {
		__nonsecure_text_start = .;
		*(.text.nonsecure*)
		*(.rodata.nonsecure*)
		. = ALIGN(4);
		__nonsecure_text_end = .;
	} > NONSECURE

	.nonsecure_data : {
		__nonsecure_data_start = .;
		*(.data.nonsecure*)
		. = ALIGN(4);
		__nonsecure_data_end = .;
	} > NONSECURE

	.nonsecure_bss (NOLOAD) : {
		__nonsecure_bss_start = .;
		*(.bss.nonsecure*)
		. = ALIGN(4);
		__nonsecure_bss_end = .;
	} > NONSECURE
}

/*
 * Both worlds have to end up with code in them, and each function has to be
 * marked with the attribute that puts it there. Without this the image links
 * cleanly and simply has no Non-secure world to hand over to, which is a
 * miserable thing to debug from a running guest. These say what was
 * forgotten instead.
 */
ASSERT(__secure_text_end > __secure_text_start,
       "the Secure world has no code: mark it with the SECURE_FUNC attribute in main.c")
ASSERT(__nonsecure_text_end > __nonsecure_text_start,
       "the Non-secure world has no code: mark it with the NONSECURE_FUNC attribute in main.c")
