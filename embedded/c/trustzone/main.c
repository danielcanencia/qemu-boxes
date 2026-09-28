/*
 * The two worlds of the TrustZone image.
 *
 * The Secure world is entered first, on reset. It is the only one that may
 * program the Security Attribution Unit, and it is where keys and other
 * secrets belong. When it is done, it hands the core over to the Non-secure
 * world, which is where an application would normally run.
 *
 * The handover itself is assembly, in world_switch.s, because it needs an
 * instruction that can change the security state of the core. Everything
 * else is ordinary C.
 *
 * This is the skeleton the box builds: the plumbing is here, and the two
 * functions below are where your code goes.
 */

#include <stdint.h>

/* The assembly routine that leaves the Secure state. */
extern void switch_to_nonsecure(void);

/*
 * Which world a function belongs to.
 *
 * This is what puts the two worlds in two places. The linker script gives
 * .text.secure the Secure region and .text.nonsecure the Non-secure one, so
 * a function has to be told which of the two to go in. Without this, GCC
 * puts everything in an ordinary .text, which matches no rule in the
 * script: the linker then keeps it as an orphan section and quietly places
 * it next to the Secure code, so the Non-secure world ends up empty and
 * the handover branches into nothing. The ASSERTs in linker.x turn that
 * mistake into a link error rather than a guest that misbehaves.
 */
#define SECURE_FUNC    __attribute__((section(".text.secure")))
#define NONSECURE_FUNC __attribute__((section(".text.nonsecure")))

/*
 * The Secure world. Runs first, with the whole of memory at its disposal.
 *
 * Whether it then hands the core over is a build setting rather than a
 * runtime one, so that a normal boot is just a normal boot: the Secure world
 * starts, does its work, and stays there. The handover is what makes this a
 * dual-world image, and it is opt-in, so that the world switch is something
 * you ask for rather than something the firmware always does to you.
 */
SECURE_FUNC void secure_main(void)
{
	/* your secure-world code here: keys, secrets, the trusted part */

#if WITH_HANDOVER
	/* hand the core over to the Non-secure world */
	switch_to_nonsecure();
#else
	/* stay in the Secure world, which is what a normal boot does */
	for (;;) {
		__asm__ volatile("wfi");
	}
#endif
}

/*
 * The Non-secure world. Runs after the handover, and can only reach the
 * region the SAU was told about.
 */
NONSECURE_FUNC void nonsecure_main(void)
{
	/* your non-secure-world code here: the application */

	for (;;) {
		__asm__ volatile("wfi");
	}
}
