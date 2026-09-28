/*
 * The switch from the Secure to the Non-secure world.
 *
 * This is the one part of a TrustZone image that cannot be written in C: the
 * exchange has to happen in assembly, because it needs an instruction that
 * can change the security state of the core. Everything the two worlds do
 * afterwards is ordinary C.
 *
 * Two things live here:
 *
 *   - the vector table the core reads on reset, which points at the Secure
 *     entry point;
 *   - the two assembly routines the C code calls: one to program the Security
 *     Attribution Unit, and one to hand the core over to the Non-secure
 *     world.
 */

	.syntax unified
	.cpu cortex-m33
	.fpu fpv5-sp-d16
	.thumb

	.section .text.secure, "ax"

	.global Reset_Handler
	.type Reset_Handler, %function

	.global switch_to_nonsecure
	.type switch_to_nonsecure, %function

/* Registers of the Security Attribution Unit, in the System Control Space. */
.equiv SAU_CTRL, 0xE000EDD0
.equiv SAU_RNR,  0xE000EDD8
.equiv SAU_RBAR, 0xE000EDDC
.equiv SAU_RLAR, 0xE000EDE0

/* The Non-secure entry point, as the linker script placed it. */
.extern __nonsecure_text_start

/*
 * Where the core starts. Programs the SAU, then hands over to the C code of
 * the Secure world.
 */
Reset_Handler:
	/* region 0 of the SAU is the Non-secure one */
	ldr   r0, =SAU_RNR
	movs  r1, #0
	str   r1, [r0]

	/* it covers the Non-secure alias the image was linked at */
	ldr   r0, =SAU_RBAR
	ldr   r1, =0x00100000
	str   r1, [r0]
	ldr   r0, =SAU_RLAR
	ldr   r1, =0x001FFFFF
	orrs  r1, #0x03          /* ENABLE | NSC: reachable, and callable */
	str   r1, [r0]

	/* and turn the SAU on */
	ldr   r0, =SAU_CTRL
	movs  r1, #1             /* ENABLE */
	str   r1, [r0]

	/* the Secure world runs in C from here */
	ldr   r0, =secure_main
	bx    r0

	.size Reset_Handler, . - Reset_Handler

/*
 * Hands the core over to the Non-secure world. The branch has to be a BLXNS,
 * which is the only instruction that can leave the Secure state; an ordinary
 * call would fault.
 */
switch_to_nonsecure:
	ldr   r0, =__nonsecure_text_start

	/*
	 * Bit 0 of the target says which instruction set to branch into, and
	 * ARMv8-M has only Thumb. Branching to the bare address, with bit 0
	 * clear, is a branch into ARM state, which ARMv8-M does not have, so
	 * the core takes a SecureFault with SFSR.INVEP and the whole vm
	 * lockups. Under a debugger the fault can look like a handover that
	 * half worked, which is worse than not working at all.
	 */
	adds  r0, r0, #1

	blxns r0

	/* not expected to come back; spin if it does */
1:	b     1b

	.size switch_to_nonsecure, . - switch_to_nonsecure

/*
 * The vector table the core reads on reset: the initial stack pointer, and
 * the address of the Secure entry point.
 */
	.section .vectors, "a"
	.word 0x10100000
	.word Reset_Handler
