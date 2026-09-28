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
 * The Non-secure world is whatever the code has put in a .text.nonsecure
 * section, and the Secure world is everything else. The Non-secure sections
 * are listed first on purpose: the Secure world's .text* pattern would
 * otherwise match .text.nonsecure as well, and the two would end up in the
 * same place.
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
	.nonsecure_text : {
		*(.text.nonsecure*)
		*(.rodata.nonsecure*)
	} > NONSECURE

	.nonsecure_data : {
		*(.data.nonsecure*)
	} > NONSECURE

	.nonsecure_bss (NOLOAD) : {
		__nonsecure_bss_start = .;
		*(.bss.nonsecure*)
		. = ALIGN(4);
		__nonsecure_bss_end = .;
	} > NONSECURE

	.secure_text : {
		KEEP(*(.vector_table))
		*(.text*)
		*(.rodata*)
	} > SECURE

	.secure_data : {
		*(.data*)
	} > SECURE

	.secure_bss (NOLOAD) : {
		__secure_bss_start = .;
		*(.bss*)
		*(COMMON)
		. = ALIGN(4);
		__secure_bss_end = .;
	} > SECURE
}
