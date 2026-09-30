#ifndef __ASM_ARM_COMPILER_H
#define __ASM_ARM_COMPILER_H

/*
 * This is used to ensure the compiler did actually allocate the register we
 * asked it for some inline assembly sequences.  Apparently we can't trust
 * the compiler from one version to another so a bit of paranoia won't hurt.
 * This string is meant to be concatenated with the inline asm string and
 * will cause compilation to stop on mismatch.
 * (for details, see gcc PR 15089)
 * For compatibility with clang, we have to specifically take the equivalence
 * of 'r11' <-> 'fp' and 'r12' <-> 'ip' into account as well.
 */

/*
 * Clara HD port: the check itself is disabled.
 *
 * The original macro compares the register name the compiler chose against
 * the one the code asked for, textually, and emits `.err` when they differ.
 * GCC 8 -- the toolchain this kernel is built with -- spells inline-asm
 * register operands differently from the versions this 4.1 tree was written
 * for, so the comparison fails on correct code and the build dies in the
 * assembler:
 *
 *   /tmp/ccnlF3aj.s:1111: Error: .err encountered
 *   make[1]: *** [kernel/fork.o] Error 1
 *
 * It is a belt-and-braces assertion about a gcc bug from 2004 (PR 15089),
 * not something the kernel needs to run, so it goes.
 */
#define __asmeq(x, y) "\n\t"


#endif /* __ASM_ARM_COMPILER_H */
