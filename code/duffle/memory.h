#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "dsl.h"
#endif

#define MEM_ALIGNMENT_DEFAULT  4

#define assert_bounds(point, start, end) for(;0;){ \
	assert((start) <= (point)); \
	assert((point) <= (end));   \
} while(0)

I_ U4 align_pow2(U4 x, U4 b) {
    assert(b != 0);
    assert((b & (b - 1)) == 0);  // Check power of 2
    return ((x + b - 1) & (~(b - 1)));
}

#define align_struct(type_width) ((U4)(((type_width) + 3) & ~3))

FI_ void mem_bump(U4 start, U4 cap, U4*R_ used, U4 amount) {
	assert(amount <= (cap - used[0])); 
	used[0] += amount; 
}

FI_ U4 mem_copy            (U4 dest, U4 src,   U4 len) { return (U4)(__builtin_memcpy ((void*)dest, (void const*)src,   len)); }
FI_ U4 mem_copy_overlapping(U4 dest, U4 src,   U4 len) { return (U4)(__builtin_memmove((void*)dest, (void const*)src,   len)); }
FI_ U4 mem_fill            (U4 dest, U4 value, U4 len) { return (U4)(__builtin_memset ((void*)dest, (int)        value, len)); }
FI_ B4 mem_zero            (U4 dest,           U4 len) { if(dest == 0){return false;} mem_fill(dest, 0, len); return true; }

#pragma region DAG

#define check_nil(nil, p) ((p) == 0 || (p) == nil)
#define set_nil(nil, p)   ((p) = nil)

#define sll_stack_push_n(f, n, next) do { (n)->next = (f); (f) = (n); } while(0)

#define sll_queue_push_nz(nil, f, l, n, next) \
(                           \
	check_nil(nil, f) ? (     \
		(f) = (l) = (n),        \
		set_nil(nil, (n)->next) \
	)                         \
	: (                       \
		(l)->next=(n),          \
		(l) = (n),              \
		set_nil(nil,(n)->next)  \
	)                         \
)
#define sll_queue_push_n(f, l, n, next) sll_queue_push_nz(0, f, l, n, next)

#pragma endregion DAG

#pragma region Slice

typedef unsigned char UTF8;
typedef Struct_(Str8)        { UTF8* ptr; U4 len; };
typedef Struct_(Slice_Str8)  { Str8* ptr; U4 len; };
#define slit(string_literal) (Str8){ (UTF8*) string_literal, S_(string_literal) - 1 }

typedef Struct_(Slice) { B1* ptr; U4 len; }; // Untyped Slice (byte-addressable; .len in elements)
FI_ Slice slice_ut_(U4 ptr, U4 len) { return (Slice){(B1*)ptr, len}; }

#define Slice_(type)       Struct_(tmpl(Slice,type)) { type* ptr; U4 len; }
typedef Slice_(B1);
#define slice_assert(s)    do { assert((s).ptr != 0); assert((s).len > 0); } while(0)
#define slice_end(slice)   ((slice).ptr + S_slice(slice) / S_(B1))  /* byte-ptr arithmetic; .len is in elements per slice convention */
#define S_slice(s)         ((s).len * S_((s).ptr[0]))

#define slice_ut(ptr,len)  slice_ut_(u4_(ptr),     u4_(len))
#define slice_ut_arr(a)    slice_ut_(u4_(a),       S_(a))
#define slice_to_ut(s)     slice_ut_(u4_((s).ptr), S_slice(s))

#define slice_iter(container, iter)     (T_((container).ptr) iter = (container).ptr; iter != slice_end(container); ++ iter)
#define slice_arg_from_array(type, ...) & (tmpl(Slice,type)) { .ptr = array_decl(type,__VA_ARGS__), .len = array_len( array_decl(type,__VA_ARGS__)) }
#define slice_from_array(type, array)     (tmpl(Slice,type)) { .ptr = array, .len = S_(array) / S_(type) }

FI_ void slice_zero_(Slice s) { slice_assert(s); mem_zero(u4_(s.ptr), s.len); }
#define  slice_zero(s)        slice_zero_(slice_to_ut(s))

FI_ void slice_copy_(Slice dest, Slice src) {
	assert(S_slice(dest) >= S_slice(src));
	slice_assert(dest);
	slice_assert(src);
	mem_copy(u4_(dest.ptr), u4_(src.ptr), S_slice(src));
}
#define slice_copy(dest, src) do {  \
	static_assert(T_same(dest, src)); \
	slice_copy_(slice_to_ut(dest), slice_to_ut(src)); \
} while(0)

typedef Slice_(U1);
typedef Slice_(U4);

#pragma endregion Slice

#pragma region FArena

typedef Opt_(farena)    { U4 alignment, type_width; };
typedef Struct_(FArena) { U4 start, capacity, used; };
FI_ void farena_init(FArena_R arena, Slice mem) {  assert(arena != nullptr);
	arena->start    = u4_(mem.ptr);
	arena->capacity = mem.len;
	arena->used     = 0;
}
FI_ FArena farena_make(Slice mem) { FArena a; farena_init(& a, mem); return a; }
I_  Slice  farena_push(FArena_R arena, U4 amount, Opt_farena o) {
	if (amount == 0) { return (Slice){}; }
	U4 desired   = amount * (o.type_width == 0 ? 1 : o.type_width);
	U4 to_commit = align_pow2(desired, o.alignment ?  o.alignment : MEM_ALIGNMENT_DEFAULT);
	U4 ptr       = arena->start + arena->used;
	mem_bump(arena->start, arena->capacity, & arena->used, to_commit);
	return (Slice){ (B1*)ptr, to_commit };
}
FI_ void farena_reset (FArena_R arena) { arena->used = 0; }
FI_ void farena_rewind(FArena_R arena, U4 save_point) {
	U4 end       = arena->start + arena->used; assert_bounds(save_point, arena->start, end);
	arena->used -= save_point - arena->start;
}
FI_ U4 farena_save(FArena arena)  { return arena.used; }
FI_ U4 farena_unused_start(FArena arena) { return arena.start + arena.used; }
#define farena_push_(arena, amount, ...)                                          farena_push((arena), (amount), opt_(farena, __VA_ARGS__))
#define farena_push_type(arena, type, ...)                              C_(type*, farena_push((arena), 1,        opt_(farena, .type_width=S_(type), __VA_ARGS__)).ptr)
#define farena_push_array(arena, type, amount, ...) (tmpl(Slice,type)){ C_(type*, farena_push((arena), (amount), opt_(farena, .type_width=S_(type), __VA_ARGS__)).ptr), (amount) }

#pragma endregion FArena
