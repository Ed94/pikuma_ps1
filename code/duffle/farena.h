#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "dsl.h"
#	include "memory.h"
#	include "strings.h"
#endif

typedef def_struct(Opts_farena) {
	Str8 type_name;
	U4   alignment;
};
typedef def_struct(FArena) {
	void* start;
	U4    capacity;
	U4    used;
};
FArena      farena_make  (Slice_B1 mem);
void        farena_init  (FArena* arena, Slice_B1 byte);
Slice_B1    farena__push (FArena* arena, U4 amount, U4 type_width, Opts_farena* opts);
void        farena_reset (FArena* arena);
void        farena_rewind(FArena* arena, AllocatorSP save_point);
AllocatorSP farena_save  (FArena  arena);

// void farena_allocator_proc(AllocatorProc_In in, AllocatorProc_Out* out);
// #define ainfo_farena(arena) (AllocatorInfo){ .proc = farena_allocator_proc, .data = & arena }

#define farena_push(arena, type, ...) \
cast(type*, farena__push(arena, size_of(type), 1, opt_args(Opts_farena_push, lit(stringify(type)), __VA_ARGS__))).ptr

#define farena_push_array(arena, type, amount, ...) \
(Slice ## type){ farena__push(arena, size_of(type), amount, opt_args(Opts_farena_push, lit(stringify(type)), __VA_ARGS__)).ptr, amount }
