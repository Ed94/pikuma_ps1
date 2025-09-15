#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "assert.h"
#endif

typedef unsigned char  U8;
typedef signed   char  S8;
typedef unsigned short U16;
typedef signed   short S16;
typedef unsigned int   U32;
typedef signed   int   S32;
typedef unsigned char  BYTE;
typedef unsigned int   USIZE;
typedef signed   int   SSIZE;
typedef S8             B8;
typedef S16            B16;
typedef S32            B32;
enum {
	false = 0,
	true  = 1,
	true_overflow,
};
#define glue_impl(A, B)                     A ## B
#define glue(A, B)                          glue_impl(A, B)
#define stringify_impl(S)                   #S
#define stringify(S)                        stringify_impl(S)
#define tmpl(prefix, type)                  prefix ## _ ## type

#define alignas                             _Alignas
#define alignof                             _Alignof
#define byte_pad(amount, ...)               BYTE glue(_PAD_, __VA_ARGS__) [amount]
#define farray_len(array)                   (SSIZE)sizeof(array) / size_of( typeof((array)[0]))
#define farray_init(type, ...)              (type[]){__VA_ARGS__}
#define def_farray(type, len)               type A ## len ## _ ## type[len]
#define def_enum(underlying_type, symbol)   underlying_type symbol; enum   symbol
#define def_struct(symbol)                  struct symbol symbol;   struct symbol
#define def_union(symbol)                   union  symbol symbol;   union  symbol
#define def_proc(symbol)                    symbol
#define opt_args(symbol, ...)               &(symbol){__VA_ARGS__}
#define ret_type(type)                      type
#define local_persist                       static
#define internal                            static
#define global
#define gknown
#define ct_lit
#define offset_of(type, member)             cast(SSIZE, & (((type*) 0)->member))
#define static_assert                       _Static_assert
#define typeof                              __typeof__
#define typeof_ptr(ptr)                     typeof(ptr[0])
#define typeof_same(a, b)                   _Generic((a), typeof((b)): 1, default: 0)

#define cast(type, data)                    ((type)(data))
#define pcast(type, data)                   * cast(type*, & (data))
#define nullptr                             cast(void*, 0)
#define size_of(data)                       cast(SSIZE, sizeof(data))
#define kilo(n)                             (cast(SSIZE, n) << 10)
#define mega(n)                             (cast(SSIZE, n) << 20)
#define giga(n)                             (cast(SSIZE, n) << 30)
#define tera(n)                             (cast(SSIZE, n) << 40)

#define span_iter(type, iter, m_begin, op, m_end)  \
	tmpl(Iter_Span,type) iter = { \
		.r = {(m_begin), (m_end)},  \
		.cursor = (m_begin) };      \
	iter.cursor op iter.r.end;    \
	++ iter.cursor

#define def_span(type)                                                \
	        def_struct(tmpl(     Span,type)) { type begin; type end; }; \
	typedef def_struct(tmpl(Iter_Span,type)) { tmpl(Span,type) r; type cursor; }

typedef def_span(S32);
typedef def_span(U32);
typedef def_span(SSIZE);

typedef void def_proc(VoidFn) (void);

#define def_Slice(type)        \
def_struct(tmpl(Slice,type)) { \
	type* ptr; \
	SSIZE len; \
}
#define slice_assert(slice)       do { assert((slice).ptr != nullptr); assert((slice).len > 0); } while(0)
#define slice_end(slice)          ((slice).ptr + (slice).len)
#define size_of_slice_type(slice) size_of( * (slice).ptr )

typedef def_Slice(void);
typedef def_Slice(BYTE);
#define slice_byte(slice) ((Slice_BYTE){cast(Byte*, (slice).ptr), (slice).len * size_of_slice_type(slice)})
#define slice_fmem(mem)   ((Slice_BYTE){ mem, size_of(mem) })

void slice__copy(Slice_BYTE dest, SSIZE dest_typewidth, Slice_BYTE src, SSIZE src_typewidth);
void slice__zero(Slice_BYTE mem, SSIZE typewidth);
#define slice_copy(dest, src) do {       \
	static_assert(typeof_same(dest, src)); \
	slice__copy(slice_byte(dest),  size_of_slice_type(dest), slice_byte(src), size_of_slice_type(src)); \
} while (0)
#define slice_zero(slice) slice__zero(slice_byte(slice), size_of_slice_type(slice))

#define slice_iter(container, iter)               \
	typeof((container).ptr) iter = (container).ptr; \
	iter != slice_end(container);                   \
	++ iter
#define slice_arg_from_array(type, ...) & (tmpl(Slice,type)) {  \
	.ptr = farray_init(type, __VA_ARGS__),             \
	.len = farray_len( farray_init(type, __VA_ARGS__)) \
}

typedef unsigned char UTF8;
typedef def_Slice(UTF8);
typedef Slice_UTF8 Str8;
typedef def_Slice(Str8);
#define txt(string_literal) (Str8){ (UTF8*) string_literal, size_of(string_literal) - 1 }
