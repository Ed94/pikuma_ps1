#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
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
#define byte_pad(amount, ...)               Byte glue(_PAD_, __VA_ARGS__) [amount]
#define farray_len(array)                   (SSIZE)sizeof(array) / size_of( typeof((array)[0]))
#define farray_init(type, ...)              (type[]){__VA_ARGS__}
#define def_farray(type, len)               type A ## len ## _ ## type[len]
#define def_enum(underlying_type, symbol)   underlying_type symbol; enum   symbol
#define def_struct(symbol)                  struct symbol symbol;   struct symbol
#define def_union(symbol)                   union  symbol symbol;   union  symbol
#define fn(symbol)                          symbol
#define opt_args(symbol, ...)               &(symbol){__VA_ARGS__}
#define ret_type(type)                      type
#define local_persist                       static
#define global                              static
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

#define range_iter(type, iter, m_begin, op, m_end)  \
	tmpl(Iter_Range,type) iter = { \
		.r = {(m_begin), (m_end)},   \
		.cursor = (m_begin) };       \
	iter.cursor op iter.r.end;     \
	++ iter.cursor

#define def_range(type)                                                \
	        def_struct(tmpl(     Range,type)) { type begin; type end; }; \
	typedef def_struct(tmpl(Iter_Range,type)) { tmpl(Range,type) r; type cursor; }

typedef def_range(S32);
typedef def_range(U32);
typedef def_range(SSIZE);

typedef void fn(VoidFn) (void);
