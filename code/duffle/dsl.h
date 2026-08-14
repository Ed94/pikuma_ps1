#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "assert.h"
#endif

#define offset_of(type, member)  cast(U8,__builtin_offsetof(type,member)) // Compiler builtin version of O_
#define static_assert            _Static_assert
#define typeof                   __typeof__
#define typeof_ptr(ptr)          typeof((ptr)[0])
#define typeof_same(a, b)        _Generic((a), typeof((b)): 1, default: 0)

#define m_expand(...)      __VA_ARGS__
#define glue_impl(A, B)    A ## B
#define glue(A, B)         glue_impl(A, B)
#define tmpl(prefix, type) prefix ## _ ## type

#define stringify_impl(S)        #S
#define stringify(S)             stringify_impl(S)

#define VA_Sel_1( _1, ... ) _1 // <-- Of all th args passed pick _1.
#define VA_Sel_2( _1, _2, ... ) _2 // <-- Of all the args passed pick _2.
#define VA_Sel_3( _1, _2, _3, ... ) _3 // etc..

#define global static // Mark global data
#define gknown        // Mark global data used in procedure

#define LP_      static // static data within procedure scope
#define internal static // internal

#define asm           __asm__

#define A_(data)      (& data)
#define align_(value) __attribute__((aligned (value)))             // for easy alignment
#define align_(value) __attribute__((aligned (value)))             // for easy alignment
#define C_(type,data) ((type)(data))                               // for enforced precedence
#define expect_(x, y) __builtin_expect(x, y)                       // so compiler knows the common path
#define cexpr_        __builtin_constant_p
#define I_            internal inline
#define FI_           inline   __attribute__((always_inline))      // inline always
#define NI_           internal __attribute__((noinline))           // inline never
#define RO_           __attribute__((section(".rodata")))          // Read only data allocation
#define T_            typeof                                       // 
#define T_same(a,b)   _Generic((a), typeof((b)): 1, default: 0)

#define R_    restrict 
#define V_    volatile 

#pragma region Fictional //, used for intiution

#define EUB_  restrict // Execute Unit Bound:    Data is siloed in the ALU Register File. The Load/Store Unit is bypassed. (Route to Execution Unit.  Keep in registers)
#define ISO_  restrict // Isolated Provenance:   Alternative to Exu_. Guarantees electrical memory isolation, 
                       //                        unlocking the compiler’s ability to safely pack data across multiple parallel SIMD lanes (vectorization).
#define LSU_  volatile // Load/Store Unit Bound: The compiler is forbidden from caching in registers. Forces physical L1 Cache matrix sampling.
#define LIVE_ volatile // Live External Data:    Alternative to Lsu_ emphasizing the memory is tapped by an external electrical actor.

#define latch_store  /* ~: atomic_store*/         // Blasts voltages from the Store Buffer into the L1 SRAM, physically flipping the cross-coupled inverters to lock the state.
#define pulse_rfo    /* ~: atomic_xchg*/          // Broadcasts an electrical RFO (Request For Ownership) pulse across the CPU mesh network to invalidate other L1 caches.
#define tact_acquire /* ~: memory_order_acquire*/ // Clamp. Sends a voltage signal to the instruction decoder to halt the Out-of-Order engine until the load resolves.
#define tact_release /* ~: memory_order_release*/ // Drain. Forces the Store Buffer flip-flops to completely empty into the L1 cache before proceeding.

// -----------------------------------------------------------------------------
// Out-of-Order (OoO) Pipeline Modifiers
// -----------------------------------------------------------------------------
#define ooo_drift_  __ATOMIC_RELAXED // OoO engine allowed to drift
#define ooo_anchor_ __ATOMIC_ACQUIRE // Anchor the Load Queue (halt spec lookahead)
#define ooo_drain_  __ATOMIC_RELEASE // Drain the Store Buffer (force writeback)
#define ooo_weld_   __ATOMIC_SEQ_CST // Weld pipeline (total order bus lock)

// Latch operations with physical queue modifiers
#define latch_load_anchor(ptr)       //__atomic_load_n(ptr, ooo_anchor_)
#define latch_store_drain(ptr, val)  //__atomic_store_n(ptr, val, ooo_drain_)
#define pulse_xchg_weld(ptr, val)    //__atomic_exchange_n(ptr, val, ooo_weld_)

#pragma endreigon Fictional


// R_ (restrict) establishes an "Eigen" or "Proprius" mapping.
// Unlike volatile (V_), which assumes the memory can be changed by anything, 
// R_ tells the compiler that this pointer holds the *sole*, private (idios) 
// ownership of the memory slice. Writes to this memory are exclusively bound 
// to this single symbolic mapping for the duration of the scope, guaranteeing 
// zero aliasing.

#define r_(ptr)        C_(T_(ptr[0])*R_, ptr) // Constrain pointer to restrict
#define v_(ptr)        C_(T_(ptr[0])V_*, ptr) // 
#define tr_(type, ptr) C_(type *R_, ptr)
#define tv_(type, ptr) C_(type V_*, ptr)

#define TypeR_(type)   type *R_ type ## _R  // type *restrict type_R
#define TypeV_(type)   type V_* type ## _V  // type volatile* type_V
#define PtrSet_(type)  TypeR_(type); typedef TypeV_(type)
#define TSet_(type)    type; typedef PtrSet_(type)

#define Array_len(a)                   (U4)(sizeof(a) / sizeof(typeof((a)[0])))
#define Array_decl(type, ...)          (type[]){__VA_ARGS__}
#define Array_sym(type,len)            A ## len ## _ ## type
#define Array_expand(type,len)         type Array_sym(type, len)[len]; typedef PtrSet_(Array_sym(type, len))
#define Array_(type,len)               Array_expand(type,len)
#define Bit_(id,b)                     id = (1 << b), tmpl(id,pos) = b
#define Bitmask_(b)                    (1u << b)
#define Enum_(underlying_type, symbol) underlying_type TSet_(symbol); enum   symbol
#define Proc_(symbol)                  symbol
#define Relative_(symbol)              // Does nothing but annotate that a symbol is associated with another.
#define Struct_(symbol)                struct symbol   TSet_(symbol); struct symbol
#define Union_(symbol)                 union  symbol   TSet_(symbol); union  symbol

#define Opt_(proc)                     Struct_(tmpl(Opt,proc))
#define opt_(symbol, ...)              (tmpl(Opt,symbol)){__VA_ARGS__}
#define Ret_(proc)                     Struct_(tmpl(Ret,proc))
#define ret_(proc)                     tmpl(Ret,proc) proc

// Using Byte-Width convention for the fundamental types.
typedef __UINT8_TYPE__  TSet_(U1); 
typedef __UINT16_TYPE__ TSet_(U2);
typedef __UINT32_TYPE__ TSet_(U4);
typedef __INT8_TYPE__   TSet_(S1); 
typedef __INT16_TYPE__  TSet_(S2); 
typedef __INT32_TYPE__  TSet_(S4);
typedef unsigned char   TSet_(B1); 
typedef __UINT16_TYPE__ TSet_(B2); 
typedef __UINT32_TYPE__ TSet_(B4);

#define u1_(value)  C_(U1, value)
#define u2_(value)  C_(U2, value)
#define u4_(value)  C_(U4, value)
#define s1_(value)  C_(S1, value)
#define s2_(value)  C_(S2, value)
#define s4_(value)  C_(S4, value)

#define u1_r(value) C_(U1 *R_, value)
#define u2_r(value) C_(U2 *R_, value)
#define u4_r(value) C_(U4 *R_, value)
#define u1_v(value) C_(U1 V_*, value)
#define u2_v(value) C_(U2 V_*, value)
#define u4_v(value) C_(U4 V_*, value)
enum { false = 0, true  = 1, true_overflow, };

#define u4_lo(value) (u4_(value) & 0xFFFFU)
#define u4_hi(value) (u4_(value) >> (S_(U2) * 8))

typedef void Proc_(VoidFn) (void);

#define Kilo_(n)                (C_(U4, n) << 10)
#define Mega_(n)                (C_(U4, n) << 20)
#define Giga_(n)                (C_(U4, n) << 30)
#define Tera_(n)                (C_(U4, n) << 40)

#define null                    C_(U4,    0)
#define nullptr                 C_(void*, 0)
#define O_(type, field)         C_(U4, & C_(type*,0)->field)
#define OT_(field)              O_(typeof_ptr(& field), field))
#define S_(data)                C_(U4, sizeof(data))

#define sop_1(op,a,b) C_(U1, s1_(a) op s1_(b))
#define sop_2(op,a,b) C_(U2, s2_(a) op s2_(b))
#define sop_4(op,a,b) C_(U4, s4_(a) op s4_(b))

#undef def_signed_op
#define def_signed_op(id,op,width) FI_ U ## width id ## _s ## width(U ## width a, U ## width b) {return sop_ ## width(op, a, b); }
#define def_signed_ops(id,op)      def_signed_op(id, op, 1) def_signed_op(id, op, 2) def_signed_op(id, op, 4)
def_signed_ops(add, +)
def_signed_ops(sub, -)
def_signed_ops(mut, *)
def_signed_ops(div, /)
def_signed_ops(gt,  >)
def_signed_ops(lt,  <) 
def_signed_ops(ge, >=)
def_signed_ops(le, <=)
#undef def_signed_ops
#undef def_signed_op

// Unused, we arent' doing any C-like asm since we have the asm dsl. We'll keep the non-generics if we somehow do.
#if 0
#define def_generic_sop(op, a, ...) _Generic((a), U1:  op ## _s1, U2: op ## _s2, U4: op ## _s4) (a, __VA_ARGS__)
#define add_s(a,b) def_generic_sop(add,a,b)
#define sub_s(a,b) def_generic_sop(sub,a,b)
#define mut_s(a,b) def_generic_sop(mut,a,b)
#define gt_s(a,b)  def_generic_sop(gt, a,b)
#define lt_s(a,b)  def_generic_sop(lt, a,b)
#define ge_s(a,b)  def_generic_sop(ge, a,b)
#define le_s(a,b)  def_generic_sop(le, a,b)
#undef def_generic_sop
#endif

#define alignas                             _Alignas
#define alignof                             _Alignof
#define byte_pad(amount, ...)               B1 glue(_PAD_, __VA_ARGS__) [amount]
#define C_ptr(type, data)                   (C_(type*, & (data)) [0])

#define dbg_args(...)                      __VA_ARGS__

#pragma region Control Flow & Iteration
#define each_iter(type, iter, end)             (type iter = 0; iter < end; ++ iter)
#define index_iter(type, iter, begin, op, end) (type iter = begin; iter op end; (begin < end ? ++ iter : -- iter))
#define range_iter(iter,op,range)              (T_((range).p0) iter = (range).p0; iter op (range).p1; ((range).p0 < (range).p1 ? ++ iter : -- iter))

#define defer(expr)                for(U4         once= 1;                  once!=1;++     once,(expr))    // Basic do something after body
#define scope(begin,end)           for(U4         once=(1,(begin));         once!=1;++     once,(end ))    // Do things before or after a scope
#define defer_rewind(cursor)       for(T_(cursor) sp=cursor,once=0;         once!=1;++     once,cursor=sp) // Used with arenas/stacks
#define defer_info(type,expr, ...) for(type       info= {__VA_ARGS__}; info.once!=1;++info.once,(expr))    // Defer with tracked state

#define do_while(cond) for (U8 once=0; once!=1 || (cond); ++once)

#define Jmp_nZero_(cond,label) if (cond) goto label;
#pragma endregion Control Flow & Iteration

#define span_iter(type, iter, m_begin, op, m_end) ( \
	tmpl(Iter_Span,type) iter = {     \
		.r      = {(m_begin), (m_end)}, \
		.cursor = (m_begin) };          \
	iter.cursor op iter.r.end;        \
	++ iter.cursor                    \
)
#define Span_(type)                                                \
	        Struct_(tmpl(     Span,type)) { type begin; type end; }; \
	typedef Struct_(tmpl(Iter_Span,type)) { tmpl(Span,type) r; type cursor; }

typedef Span_(S4);
typedef Span_(U4);

#if 0
#pragma region Debug
#define debug_trap() __builtin_debugtrap()
#if BUILD_DEBUG
IA_ void assert(U8 cond) { if(cond){return;} else{debug_trap(); ms_exit_process(1);} }
#else
#define assert(cond)
#endif
#pragma endregion Debug
#endif

#define GCC_OPTIMIZATION_DISABLE _Pragma("GCC push_options") _Pragma("GCC optimize(\"O0\")")
#define GCC_OPTIMIZATION_ENABLE  _Pragma("GCC pop_options")
