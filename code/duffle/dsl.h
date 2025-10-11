#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "assert.h"
#endif

#define align_(value)     __attribute__((aligned (value)))             // for easy alignment
#define expect_(x, y)     __builtin_expect(x, y)                       // so compiler knows the common path
#define finline           static inline __attribute__((always_inline)) // force inline
#define no_inline         static        __attribute__((noinline))      // force no inline [used in thread api]
#define R_                __restrict                                   // pointers are either restricted or volatile and nothing else 
#define V_                volatile                                     // pointers are either restricted or volatile and nothing else

#define glue_impl(A, B)          A ## B
#define glue(A, B)               glue_impl(A, B)
#define stringify_impl(S)        #S
#define stringify(S)             stringify_impl(S)
#define tmpl(prefix, type)       prefix ## _ ## type

#define local_persist            static
#define internal                 static
#define global
#define gknown

#define offset_of(type, member)  cast(SSIZE, & (((type*) 0)->member))
#define static_assert            _Static_assert
#define typeof                   __typeof__
#define typeof_ptr(ptr)          typeof((ptr)[0])
#define typeof_same(a, b)        _Generic((a), typeof((b)): 1, default: 0)

#define def_R_(type)             type*restrict type ## _R
#define def_V_(type)             type*volatile type ## _V
#define def_ptr_set(type)        def_R_(type); typedef def_V_(type)
#define def_tset(type)           type; typedef def_ptr_set(type)

typedef __UINT8_TYPE__  def_tset(U1); typedef __UINT16_TYPE__ def_tset(U2); typedef __UINT32_TYPE__ def_tset(U4);
typedef __INT8_TYPE__   def_tset(S1); typedef __INT16_TYPE__  def_tset(S2); typedef __INT32_TYPE__  def_tset(S4);
typedef unsigned char   def_tset(B1); typedef __UINT16_TYPE__ def_tset(B2); typedef __UINT32_TYPE__ def_tset(B4);
enum { false = 0, true  = 1, true_overflow, };

#define u1_r(value) cast(U1_R, value)
#define u2_r(value) cast(U2_R, value)
#define u4_r(value) cast(U4_R, value)
#define u1_v(value) cast(U1_V, value)
#define u2_v(value) cast(U2_V, value)
#define u4_v(value) cast(U4_V, value)

#define u1_(value)  cast(U1, value)
#define u2_(value)  cast(U2, value)
#define u4_(value)  cast(U4, value)
#define s1_(value)  cast(S1, value)
#define s2_(value)  cast(S2, value)
#define s4_(value)  cast(S4, value)

#define farray_len(array)                   (SSIZE)sizeof(array) / size_of( typeof((array)[0]))
#define farray_init(type, ...)              (type[]){__VA_ARGS__}
#define def_farray_sym(_type, _len)         A ## _len ## _ ## _type
#define def_farray_impl(_type, _len)        _type def_farray_sym(_type, _len)[_len]; typedef def_ptr_set(def_farray_sym(_type, _len))
#define def_farray(type, len)               def_farray_impl(type, len)
#define def_enum(underlying_type, symbol)   underlying_type def_tset(symbol); enum   symbol
#define def_struct(symbol)                  struct symbol   def_tset(symbol); struct symbol
#define def_union(symbol)                   union  symbol   def_tset(symbol); union  symbol
#define def_proc(symbol)                    symbol
#define opt_args(symbol, ...)               &(symbol){__VA_ARGS__}
#define ret_type(type)                      type

#define o_(field)                           offset_of(typeof_ptr(& field), filed))

#define alignas                             _Alignas
#define alignof                             _Alignof
#define byte_pad(amount, ...)               B1 glue(_PAD_, __VA_ARGS__) [amount]
#define cast(type, data)                    ((type)(data))
#define pcast(type, data)                   * cast(type*, & (data))
#define nullptr                             cast(void*, 0)
#define size_of(data)                       cast(U4, sizeof(data))

#define r_(ptr)                             cast(typeof_ptr(ptr)*R_, ptr)
#define v_(ptr)                             cast(typeof_ptr(ptr)*V_, ptr)

#define kilo(n)                             (cast(U4, n) << 10)
#define mega(n)                             (cast(U4, n) << 20)
#define giga(n)                             (cast(U4, n) << 30)
#define tera(n)                             (cast(U4, n) << 40)

#define dbg_args(...)                      __VA_ARGS__

#define sop_1(op, a, b) cast(U1, s1_(a) op s1_(b))
#define sop_2(op, a, b) cast(U2, s2_(a) op s2_(b))
#define sop_4(op, a, b) cast(U4, s4_(a) op s4_(b))

#define def_signed_op(id, op, width) finline U ## width id ## _s ## width(U ## width a, U ## width b) {return sop_ ## width(op, a, b); }
#define def_signed_ops(id, op)       def_signed_op(id, op, 1) def_signed_op(id, op, 2) def_signed_op(id, op, 4)
def_signed_ops(add, +) def_signed_ops(sub, -)
def_signed_ops(mut, *) def_signed_ops(div, /)
def_signed_ops(gt,  >) def_signed_ops(lt,  <) 
def_signed_ops(ge, >=) def_signed_ops(le, <=)

#define def_generic_sop(op, a, ...) _Generic((a), U1:  op ## _s1, U2: op ## _s2, U4: op ## _s4) (a, __VA_ARGS__)
#define add_s(a,b) def_generic_sop(add,a,b)
#define sub_s(a,b) def_generic_sop(sub,a,b)
#define mut_s(a,b) def_generic_sop(mut,a,b)
#define gt_s(a,b)  def_generic_sop(gt, a,b)
#define lt_s(a,b)  def_generic_sop(lt, a,b)
#define ge_s(a,b)  def_generic_sop(ge, a,b)
#define le_s(a,b)  def_generic_sop(le, a,b)

#define span_iter(type, iter, m_begin, op, m_end)  \
	tmpl(Iter_Span,type) iter = { \
		.r = {(m_begin), (m_end)},  \
		.cursor = (m_begin) };      \
	iter.cursor op iter.r.end;    \
	++ iter.cursor

#define def_span(type)                                                \
	        def_struct(tmpl(     Span,type)) { type begin; type end; }; \
	typedef def_struct(tmpl(Iter_Span,type)) { tmpl(Span,type) r; type cursor; }

typedef def_span(S4);
typedef def_span(U4);

typedef void def_proc(VoidFn) (void);

typedef unsigned char def_tset(UTF8);
typedef def_struct(Str8)       { UTF8* ptr; U4 len; }; typedef Str8 def_tset(Slice_UTF8);
typedef def_struct(Slice_Str8) { Str8* ptr; U4 len; };
#define txt(string_literal)    (Str8){ (UTF8*) string_literal, size_of(string_literal) - 1 }

#define def_Slice(type)           def_struct(tmpl(Slice,type)) { type* ptr; U4 len; }
#define slice_assert(slice)       do { assert((slice).ptr != nullptr); assert((slice).len > 0); } while(0)
#define slice_end(slice)          ((slice).ptr + (slice).len)
#define size_of_slice_type(slice) size_of( * (slice).ptr )

typedef def_Slice(void);
typedef def_Slice(B1);
#define slice_byte(slice) ((Slice_B1){cast(B1*, (slice).ptr), (slice).len * size_of_slice_type(slice)})
#define slice_fmem(mem)   ((Slice_B1){ mem, size_of(mem) })

void slice__copy(Slice_B1 dest, U4 dest_typewidth, Slice_B1 src, U4 src_typewidth);
void slice__zero(Slice_B1 mem, U4 typewidth);
#define slice_copy(dest, src) do {       \
	static_assert(typeof_same(dest, src)); \
	slice__copy(slice_byte(dest),  size_of_slice_type(dest), slice_byte(src), size_of_slice_type(src)); \
} while (0)
#define slice_zero(slice) slice__zero(slice_byte(slice), size_of_slice_type(slice))

#define slice_iter(container, iter)               \
	typeof((container).ptr) iter = (container).ptr; \
	iter != slice_end(container);                   \
	++ iter
#define slice_from_farray(type, ...) & (tmpl(Slice,type)) { \
	.ptr = farray_init(type, __VA_ARGS__),             \
	.len = farray_len( farray_init(type, __VA_ARGS__)) \
}
