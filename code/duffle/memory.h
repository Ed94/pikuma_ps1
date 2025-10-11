#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "dsl.h"
#endif

inline U4 align_pow2(U4 x, U4 b) {
    assert(b != 0);
    assert((b & (b - 1)) == 0);  // Check power of 2
    return ((x + b - 1) & (~(b - 1)));
}

#define align_struct(type_width) ((U4)(((type_width) + 3) & ~3))

#define assert_bounds(point, start, end) do { \
	U4 pos_point = cast(U4, point); \
	U4 pos_start = cast(U4, start); \
	U4 pos_end   = cast(U4, end);   \
	assert(pos_start <= pos_point); \
	assert(pos_point <= pos_end);   \
} while(0)

void* memory_copy            (void* restrict dest, void const* restrict src, U4 length) __asm__("memcpy");
void* memory_copy_overlapping(void* restrict dest, void const* restrict src, U4 length);
B4    memory_zero            (void* dest, U4 length);

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

#pragma region Allocator Interface
typedef def_enum(U4, AllocatorOp) {
	AllocatorOp_Alloc_NoZero = 0, // If Alloc exist, so must No_Zero
	AllocatorOp_Alloc,
	AllocatorOp_Free,
	AllocatorOp_Reset,
	AllocatorOp_Grow_NoZero,
	AllocatorOp_Grow,
	AllocatorOp_Shrink,
	AllocatorOp_Rewind,
	AllocatorOp_SavePoint,
	AllocatorOp_Query, // Must always be implemented
};
typedef def_enum(U4, AllocatorQueryFlags) {
	AllocatorQuery_Alloc        = (1 << 0),
	AllocatorQuery_Free         = (1 << 1),
	// Wipe the allocator's state
	AllocatorQuery_Reset        = (1 << 2),
	// Supports both grow and shrink
	AllocatorQuery_Shrink       = (1 << 4),
	AllocatorQuery_Grow         = (1 << 5),
	AllocatorQuery_Resize       = AllocatorQuery_Grow | AllocatorQuery_Shrink,
	// Ability to rewind to a save point (ex: arenas, stack), must also be able to save such a point
	AllocatorQuery_Rewind       = (1 << 6),
};
typedef struct AllocatorProc_In  AllocatorProc_In;
typedef struct AllocatorProc_Out AllocatorProc_Out;
typedef void def_proc(AllocatorProc) (AllocatorProc_In In, AllocatorProc_Out* Out);
typedef def_struct(AllocatorSP) {
	AllocatorProc* type_sig;
	U4             slot;
};
struct AllocatorProc_In {
	void*          data;
	U4             requested_size;
	U4             alignment;
	union {
		Slice_B1     old_allocation;
		AllocatorSP  save_point;
	};
	AllocatorOp    op;
	byte_pad(4);
};
struct AllocatorProc_Out {
	union {
		Slice_B1    allocation;
		AllocatorSP save_point;
	};
	AllocatorQueryFlags features;
	U4                  left; // Contiguous memory left
	U4                  max_alloc;
	U4                  min_alloc;
	B4                  continuity_break; // Whether this allocation broke continuity with the previous (address space wise)
	byte_pad(4);
};
typedef def_struct(AllocatorInfo) {
	AllocatorProc* proc;
	void*          data;
};
static_assert(size_of(AllocatorSP) <= size_of(Slice_B1));
typedef def_struct(AllocatorQueryInfo) {
	AllocatorSP         save_point;
	AllocatorQueryFlags features;
	U4                  left; // Contiguous memory left
	U4                  max_alloc;
	U4                  min_alloc;
	B4                  continuity_break; // Whether this allocation broke continuity with the previous (address space wise)
	byte_pad(4);
};
static_assert(size_of(AllocatorProc_Out) == size_of(AllocatorQueryInfo));

#define MEMORY_ALIGNMENT_DEFAULT (2 * size_of(void*))

AllocatorQueryInfo allocator_query(AllocatorInfo ainfo);

void        mem_free      (AllocatorInfo ainfo, Slice_B1 mem);
void        mem_reset     (AllocatorInfo ainfo);
void        mem_rewind    (AllocatorInfo ainfo, AllocatorSP save_point);
AllocatorSP mem_save_point(AllocatorInfo ainfo);

typedef def_struct(Opts_mem_alloc)  { U4 alignment; B4 no_zero; byte_pad(4); };
typedef def_struct(Opts_mem_grow)   { U4 alignment; B4 no_zero; byte_pad(4); };
typedef def_struct(Opts_mem_shrink) { U4 alignment; };
typedef def_struct(Opts_mem_resize) { U4 alignment; B4 no_zero; byte_pad(4); };

Slice_B1 mem__alloc (AllocatorInfo ainfo,               U4 size, Opts_mem_alloc*  opts);
Slice_B1 mem__grow  (AllocatorInfo ainfo, Slice_B1 mem, U4 size, Opts_mem_grow*   opts);
Slice_B1 mem__resize(AllocatorInfo ainfo, Slice_B1 mem, U4 size, Opts_mem_resize* opts);
Slice_B1 mem__shrink(AllocatorInfo ainfo, Slice_B1 mem, U4 size, Opts_mem_shrink* opts);

#define mem_alloc(ainfo, size, ...)       mem__alloc (ainfo,      size, opt_args(Opts_mem_alloc,  __VA_ARGS__))
#define mem_grow(ainfo,   mem, size, ...) mem__grow  (ainfo, mem, size, opt_args(Opts_mem_grow,   __VA_ARGS__))
#define mem_resize(ainfo, mem, size, ...) mem__resize(ainfo, mem, size, opt_args(Opts_mem_resize, __VA_ARGS__))
#define mem_shrink(ainfo, mem, size, ...) mem__shrink(ainfo, mem, size, opt_args(Opts_mem_shrink, __VA_ARGS__))

#define alloc_type(ainfo, type, ...)       (type*)             mem__alloc(ainfo, size_of(type),        opt_args(Opts_mem_alloc, __VA_ARGS__)).ptr
#define alloc_slice(ainfo, type, num, ...) (tmpl(Slice,type)){ mem__alloc(ainfo, size_of(type) * num,  opt_args(Opts_mem_alloc, __VA_ARGS__)).ptr, num }
#pragma endregion Allocator Interface
