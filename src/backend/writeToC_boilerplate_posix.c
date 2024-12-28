#include <math.h> // for e.g. 'sin'
#include <stddef.h> // for NULL
#include <stdint.h>
typedef uint32_t char32_t;

// This should match 'makeSwitchFiberFunction' in 'jit.d'
static void __attribute__((naked, noinline)) switch_fiber(uint64_t** from, uint64_t* to) {
	__asm(
		// 'from' is %rdi, 'to' is %rsi

		// Save callee-saved register to the stack.
		// TODO: In a newer GCC, this could use 'no_callee_saved_registers' instead.
		// https://gcc.gnu.org/onlinedocs/gcc/x86-Function-Attributes.html
		"push %rbx\n"
		"push %rbp\n"
		"push %r12\n"
		"push %r13\n"
		"push %r14\n"
		"push %r15\n"
		// Write the stack pointer to the first argument.
		"movq %rsp, (%rdi)\n"

		// Get the new stack pointer from the second argument
		"movq %rsi, %rsp\n"
		// Load the registers it had saved
		"pop %r15\n"
		"pop %r14\n"
		"pop %r13\n"
		"pop %r12\n"
		"pop %rbp\n"
		"pop %rbx\n"
		// The return address also comes from 'to' since we switched to its stack pointer.
		"ret\n"
	);
}

struct s_fiber;
// This should match 'makeSwitchFiberInitialFunction' in 'jit.d'
static void __attribute__((naked, noinline)) switch_fiber_initial(
	struct s_fiber* fiber,
	uint64_t** from,
	uint64_t* stack_high,
	void (*func)(struct s_fiber*)
) {
	__asm(
		// fiber = %rdi, from = %rsi, stack_high = %rdx, func = %rcx
		// Note: We just leave 'fiber' alone, since it is the first argument to 'func'
		// TODO: In a newer GCC, this could use 'no_callee_saved_registers' instead.
		"push %rbx\n"
		"push %rbp\n"
		"push %r12\n"
		"push %r13\n"
		"push %r14\n"
		"push %r15\n"
		"movq %rsp, (%rsi)\n"

		"movq %rdx, %rsp\n"
		// Set it up so we'll return to 'func'
		"subq $8, %rsp\n" // For alignment (since stack should be 16-byte aligned, but push %rcx is only 8 bytes)
		"push %rcx\n"
		"ret\n"
	);
}

// Catch point size is 0x40. See 'getBuiltinStructSize' in the compiler.

// This should match 'makeSetupCatchFunction' in 'jit.d'
static _Bool __attribute__((naked, noinline, returns_twice)) setup_catch(void* catch_point) {
	__asm(
		// TODO: In a newer GCC, this could use 'no_callee_saved_registers' instead.
		"movq %rbx, (%rdi)\n"
		"movq %rbp, 0x08(%rdi)\n"
		"movq %r12, 0x10(%rdi)\n"
		"movq %r13, 0x18(%rdi)\n"
		"movq %r14, 0x20(%rdi)\n"
		"movq %r15, 0x28(%rdi)\n"
		"movq %rsp, 0x30(%rdi)\n"
		// Also write the return address
		"movq (%rsp), %rax\n"
		"movq %rax, 0x38(%rdi)\n"
		"xor %al, %al\n"
		"ret\n"
	);
}

// This should match 'makeJumpToCatchFunction' in 'jit.d'
static void __attribute__((naked, noinline, noreturn)) jump_to_catch(void* catch_point) {
	__asm(
		"movq (%rdi), %rbx\n"
		"movq 0x08(%rdi), %rbp\n"
		"movq 0x10(%rdi), %r12\n"
		"movq 0x18(%rdi), %r13\n"
		"movq 0x20(%rdi), %r14\n"
		"movq 0x28(%rdi), %r15\n"
		"movq 0x30(%rdi), %rsp\n"
		"movq 0x38(%rdi), %rax\n"
		// Overwrite the return address
		"movq %rax, (%rsp)\n"
		"mov $1, %al\n"
		"ret\n"
	);
}

struct ThreadLocals;
_Thread_local struct ThreadLocals* __threadLocals;
static struct ThreadLocals* threadLocals() {
	return __threadLocals;
}
extern void *alloca(size_t size);
