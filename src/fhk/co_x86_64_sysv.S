.text

/* fhk_status fhk_continue(fhk_co *co) */
.globl fhk_continue
fhk_continue:
	push %r12
	push %r13
	push %r14
	push %r15
	push %rbx
	push %rbp

	mov %rsp, 0x40(%rdi) // co->co_rsp = rsp
	mov 0x00(%rdi), %rax
	mov 0x08(%rdi), %rsp
	mov 0x10(%rdi), %r12
	mov 0x18(%rdi), %r13
	mov 0x20(%rdi), %r14
	mov 0x28(%rdi), %r15
	mov 0x30(%rdi), %rbx
	mov 0x38(%rdi), %rbp

	// jump to where fhk_yield was called from
	jmp *%rax

/* void fhkJ_yield(fhk_co *co, fhk_status s) */
.global fhkJ_yield
fhkJ_yield:
	pop %rax
	mov %rax, 0x00(%rdi)
	mov %rsp, 0x08(%rdi)
	mov 0x40(%rdi), %rsp
	mov %r12, 0x10(%rdi)
	mov %r13, 0x18(%rdi)
	mov %r14, 0x20(%rdi)
	mov %r15, 0x28(%rdi)
	mov %rbx, 0x30(%rdi)
	mov %rbp, 0x38(%rdi)

	mov %rsi, %rax

	pop %rbp
	pop %rbx
	pop %r15
	pop %r14
	pop %r13
	pop %r12

	// return to where fhk_continue was called from
	ret
