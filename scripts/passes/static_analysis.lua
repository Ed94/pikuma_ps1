--- passes/static_analysis.lua — Per-atom static-analysis checks.
--- Ownership: `ctx.shared.corpus` canonical merged registry; per-source fallback synthesis is rejected.
--- `atom.paths` supplies the emitted and analysis projections consumed by this pass.
---
--- Per-atom rules:
---   1. transfer_hazards: A single forward walker (`analyze_hardware_relations`) reads `atom.paths.word_events` once per atom.
---      For each emitted word event it (a) inspects pending CPU / COP0 / COP2 / GTE relations against the event as CONSUMER 
---      (recording a hazard on `atom.paths.hazards` when the producer→consumer gap is below the required retire-slot count), 
---      (b) Applies the event's GPR value effects (`duffle.INSTRUCTION_GPR_EFFECTS`) to `atom.paths.forward_state.gpr_values`, 
---      applies bounded constant propagation, and stages matching relation rows as PRODUCERS (with `destination_match` filters, e.g. for the IRGB fan-out).
---      The `transfer_hazards` CHECK_RULES reader projects `atom.paths.hazards` into per-atom findings.
---      The reader does NOT re-walk source. The walker runs once per atom before the per-atom dispatch; the reader runs inside the same dispatch.
---   2. control_transfer_delay_slot_use: For every emitted branch/jump/call encoder in `duffle.CONTROL_TRANSFER_DELAY_SLOT_POLICIES` 
---      (the six `branch_*` encoders plus `jump` / `jump_reg` / `jump_link` / `call_reg` / `call_addr`), inspect the next emitted event in `atom.paths.word_events`.
---      Emit an `info`-severity finding when the successor is `nop` or absent (the next emitted word IS the hardware delay slot).
---      `jump_reg(R_AtomJmp)` is suppressed by policy (the fixed `mac_yield()` handshake).
---      `nop2` needs no special case: emission-model emits two `nop` events for it, so the first expansion is the hardware delay slot.
---      `atom_label` also needs no special case (zero events).
---   3. mac_yield uniformity: Every atom body must contain exactly one `mac_yield()` call (control transfer pattern).
---   4. Binding handoff: Every `atom_bind(Binds_X)` must reference a `typedef Struct_(Binds_X) { ... }` declaration.
---   5. GPU Port-Store Shape: Per-shape (`f3`/`f4`/`g4`/etc.) the sum of `mac_format_X_color` + `mac_gte_store_X_*` + `mac_insert_ot_tag_X` words
---      must equal the GP0 cmd's expected packet size.
---   6. Per-Atom Cycle Budget: Sum each atom body's instruction latencies — non-`mac_*` tokens look up `duffle.INSTRUCTION_LATENCY[ident]`; 
---      `mac_*` tokens look up `pipe_ctx.components_by_name[bare_name].cycle_cost` (auto-derived from the original `MipsAtomComp_` body by `passes/components.lua::compute_components_metadata`).
---      Report total.
---
--- Per-source rules (registry-driven):
---   8. enum_alias_membership: Every `R_X` referenced from `atom_dbg_reg_default`, `atom_reg_types`, `atom_type(...)`, `atom_reads`, or `atom_writes`
---      must be in `corpus.register_alias_registry`.
---   9. atom_type_consistency: Every `reg_type_overrides[R_X].type_name` must resolve in `corpus.type_name_registry`.
---  10. binds_no_substruct_deref: Every `load_word(R_A, R_B, O_(Type, Field))` and `store_word(...)` in every atom body must reference a leaf scalar
---      (pointer-to-struct counts as leaf; nested struct members fail the leaf test).
---
---
--- Findings carry an explicit `kind` ("error" / "warning" / "info").
--- The renderer maintains three independent severity collections; `info` is never folded into warnings.
--- Scan/cycle summary rows are kept in a separate `summaries` collection (rendered as trailing summary lines, not findings).
--- The report header includes `Info: N` alongside Findings / Errors / Warnings, and a dedicated
--- `── Info` section renders finding-level info between `── Warnings` and the per-atom cycle counts.
---
--- The structural handshake checks (`mac_yield_uniformity`, `hazard_nop_use`, `control_transfer_delay_slot_use`) skip atoms/components with `debug_skip == true`.
--- `atom_dbg_skip` marker designates runtime-helper declarations whose structure is fixed by the tape runtime (e.g. `tape_exit`, `ac_yield`).
--- Flagging them as "missing mac_yield" or "BD slot is redundant".
--- Other checks (transfer_hazards, gpu_portstore_shape, abi_handoff, enum_alias_membership, …) still apply to debug_skip declarations because real hazards / typos can still surface in them.
---
--- The orchestrator (`ps1_meta.lua`) wires this module in via the PASSES table:
---   `["static-analysis"] = {
---       module = "passes.static_analysis",
---       kind   = "diagnostic",
---       deps   = {"word-counts", "components"},
---     }
--- `kind = "diagnostic"` keeps every finding visible in the projection; the orchestrator does not exit non-zero on static-analysis errors.
--- Annotation and header-output validation remain build-stopping.

-- ════════════════════════════════════════════════════════════════════════════
-- Module-scope requires + package.path setup
-- ════════════════════════════════════════════════════════════════════════════

-- Bootstrap: load `scripts/duffle_paths.lua` (sets package.path + package.cpath).
-- Uses `debug.getinfo` to find this file's own directory, so it works both standalone and when require'd from the orchestrator.
-- Bootstrap: load `duffle_paths.lua` via `debug.getinfo(1, "S").source` (works both standalone + when require'd).
-- duffle_paths.lua sets package.path then returns `require("duffle")` at the bottom, so the dofile value IS the duffle module.
local _bootstrap_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local duffle         = dofile(_bootstrap_dir .. "../duffle_paths.lua")

-- ════════════════════════════════════════════════════════════════════════════
-- Constants
-- ════════════════════════════════════════════════════════════════════════════

-- Atom declaration + component declaration identifiers.
local ATOM_DECL        = "MipsAtom_"
local ATOM_COMP        = "MipsAtomComp_"
local ATOM_COMP_PROC   = "MipsAtomComp_Proc_"

-- Marker-call identifiers inside atom bodies.
local ATOM_LABEL        = "atom_label"
local ATOM_OFFSET       = "atom_offset"
local ATOM_INFO         = "atom_info"
local ATOM_BIND         = "atom_bind"
local ATOM_READS        = "atom_reads"
local ATOM_WRITES       = "atom_writes"
local ATOM_YIELD        = "mac_yield"
local WORD_COUNT_PRAGMA = "WORD_COUNT("

-- ASCII byte values used in tokenization.
local BYTE_NEWLINE    = 10
local BYTE_HASH       = 35   -- '#'
local BYTE_OPEN_PAREN = 40
local BYTE_OPEN_BRACE = 123
local BYTE_OPEN_BRACK = 91
local BYTE_SEMI       = 59

-- Per-check output paths (relative to ctx.out_root).
local OUTPUT_EXTENSION = ".static_analysis.txt"

-- ════════════════════════════════════════════════════════════════════════════
-- Type declarations
-- ════════════════════════════════════════════════════════════════════════════

--- @class SourceFile
--- @field path     string  -- Absolute path to the source file
--- @field text     string  -- Full source text
--- @field dir      string  -- Directory containing the source
--- @field basename string  -- Filename without extension

--- @class PassCtx
--- @field sources            SourceFile[]
--- @field metadata_path      string
--- @field shared             table
--- @field shared.word_counts table<string, integer>
--- @field out_root           string
--- @field project_root       string
--- @field upstream           table<string, table>
--- @field flags              table
--- @field verbose            boolean

--- @class PassResult
--- @field outputs  table[]
--- @field errors   table[]
--- @field warnings table[]
--- @field info     table[]   -- Finding-level info (kind == "info"); distinct from per-source scanned/cycles summary rows

--- @alias AtomName    string  -- lower_snake_case atom nameMacroName   string  -- lower_snake_case macro identifier
--- @alias CheckName   string  -- "transfer_hazards" | "control_transfer_delay_slot_use" | "mac_yield_uniformity" | "yield_load_tail_pairing" | "abi_handoff" | "gpu_portstore_shape" | "per_atom_cycle_budget" | "enum_alias_membership" | "atom_type_consistency" | "binds_no_substruct_deref"

--- @class AtomBody
--- @field line     integer  -- Source line of the atom declaration
--- @field name     AtomName -- Atom name (e.g. "cube_g4_face")
--- @field body     string   -- Brace-delimited body (without the braces)
--- @field body_off integer  -- char offset of body[1] in source
--- @field kind     string   -- "atom" | "comp_bare" | "comp_proc"

--- @class Token
--- @field tok      string     -- Raw token text (trimmed)
--- @field line     integer    -- Source line of the token's start
--- @field ident    string|nil -- Leading ident of the token (if any)
--- @field kind     string     -- "n_words" | "mac_yield" | "gte_cmdw" | "mac_format" | "mac_gte_store" | "mac_insert_ot_tag" | "atom_label" | "atom_offset" | "other"

--- @class Finding 
--- @field line     integer   -- Source line of the finding
--- @field atom     AtomName  -- Atom this finding is for (or "")
--- @field check    CheckName -- Check identifier
--- @field kind     string    -- "error" | "warning" | "info"
--- @field msg      string    -- Finding message

--- @class AtomAnalysis
--- @field atom       AtomBody
--- @field tokens     Token[]   -- Tokens in the atom body, annotated
--- @field findings   Finding[] -- Findings for this atom
--- @field total_cycles integer -- Sum of token cycle costs

-- ════════════════════════════════════════════════════════════════════════════
-- Per-word-event helpers
-- ════════════════════════════════════════════════════════════════════════════

-- Pick the source-line field that best represents "where in the user's source file is this word?".
-- `word_events` (populated by `passes/emission_model.lua::stamp_root_provenance`) carry four line fields:
--   * `call_line`  — physical line in the ROOT atom's source (the line of the `mac_X(...)` call site that triggered this emission, or `body_line` for direct words in the atom body)
--   * `body_line`  — physical line in the body containing the emitted word (the atom body for direct words; the component body for words expanded inside `mac_X(...)`)
--   * `def_line`   — line of the COMPONENT's declaration in its source file (only meaningful for words emitted inside a component expansion)
--   * `line`       — body-relative line in the source text (not a physical source line; rarely useful in rendered findings)
--
-- For component-expanded words (e.g. the BD-slot nop of `jump_reg(R_AtomJmp)` inside `mac_yield()`),
-- `body_line` points into the COMPONENT's source file (e.g. `lottes_tape.h:110` for `ac_yield`'s body).
-- The user editing their atom body expects the line to point at THEIR source — i.e. the line where `mac_yield()`
-- was called (e.g. `hello_gte_tape.c:35`). That line is `call_line`.
--
-- For direct words in the atom body (no invocation wrapping them), `call_line == body_line` already, so `call_line` works for both cases.
local function line_for_word_event(ev)
    if ev == nil then return 0 end
    return ev.call_line or ev.body_line or ev.line or ev.def_line or 0
end

-- True iff the given atom/component declaration has the bare `atom_dbg_skip` marker.
-- Used by the structural handshake checks (`mac_yield_uniformity`, `hazard_nop_use`,
-- `control_transfer_delay_slot_use`) to exempt runtime-helper declarations (`tape_exit`, `ac_yield`,
-- and the `ac_*` macro components) from findings whose contract they intentionally don't satisfy.
local function is_runtime_helper(atom)
    return atom and atom.debug_skip == true
end

-- ════════════════════════════════════════════════════════════════════════════
-- classify_tokens — per-token classification
-- ════════════════════════════════════════════════════════════════════════════

-- ONE forward pass over the token list produces a flat table of per-token classifications. 
-- Every check + analyze_atom_paths reads from this table instead of re-scanning the token strings. 
--
-- The classification is stored on `atom.paths.tok_class` as an array indexed by token index (1..#tokens). 
-- Each entry has:
--   ident                 — the leading identifier (e.g. "load_word", "gte_cmdw_rtpt", "nop", "mac_yield")
--   nop_words             — 0 / 1 / 2 (for "nop" / "nop2" / anything else)
--   nop_prefix            — consecutive nop words ending just BEFORE this token (forward-pass pre-compute; makes preceding-nop lookup O(N))
--   is_yield              — true if this token is `mac_yield` or `mac_yield(...)`
--   is_atom_label         — true if this token is `atom_label(name)`; label_name has the name
--   is_branch             — true if this token is `branch_*(...)` OR an unconditional-jump-with-offset (`jump(off)` / `call_addr(off)`); branch_label has the target label or false
--   is_unconditional_jump — true if this token is `jump` or `call_addr` (BD slot + single successor — taken only; no fall-through).
--                           Mutually exclusive with the conditional-branch semantics; combined with `is_branch` above.
--   is_terminal_jump      — true if this token is `jump_reg` / `call_reg` / `jump_link` (transfers control OUT of the current atom; the `mac_yield()` handshake ends in `jump_reg(R_AtomJmp), nop`). 
--                           No offset field — `atom_offset` is invalid here. Terminates the current path in the CFG.
--   is_load               — true if this token starts with any of: load_word, load_half, load_half_u, load_byte,
--                           load_byte_u, gte_lw, gte_lwc2. These all have MIPS load-delay semantics (the destination register is volatile for 1 word after the load).
--   is_store_word         — true if this token starts with `store_word(`
--
-- Checks that need the leading ident use `tok_class.ident` instead of re-matching the token string.
-- Checks that need "how many nops before token i" use `tok_class.nop_prefix` instead of walking backwards.

--- @class TokClass
--- @field ident              string           -- lLading identifier
--- @field nop_words          integer          -- 0 / 1 / 2
--- @field nop_prefix         integer          -- Consecutive nop words before this token
--- @field is_yield           boolean
--- @field is_atom_label      boolean
--- @field label_name         string|nil       -- For atom_label(name)
--- @field is_branch          boolean          -- Conditional branch OR unconditional-jump-with-offset
--- @field is_unconditional_jump boolean       -- `jump` / `call_addr` only
--- @field is_terminal_jump   boolean          -- `jump_reg` / `call_reg` / `jump_link` only
--- @field branch_label       string|false|nil -- For branch_*(..., atom_offset(F, label)) OR jump/call_addr
--- @field is_load            boolean          -- load_word | load_half | load_half_u | load_byte | load_byte_u | gte_lw | gte_lwc2
--- @field is_store_word      boolean
--- @field mac_format_shape   string|nil       -- "f3" / "g4" etc. for mac_format_X_color; nil otherwise
--- @field is_gte_store       boolean          -- Ident matches `mac_gte_store_<shape>`
--- @field is_ot_tag          boolean          -- Ident matches `mac_insert_ot_tag_<shape>`
--- @field writes_r_prim_cursor boolean        -- store_word targeting R_PrimCursor
--- @field reads_r_tape_ptr   boolean          -- Any token referencing R_TapePtr
--- @field o_arg1             string|nil       -- First arg of O_(<a>, <b>) captures; nil for non-O_ tokens
--- @field o_arg2             string|nil       -- Second arg of O_(<a>, <b>) captures
--- @field s_arg1             string|nil       -- Arg of S_(<a>) captures; nil for non-S_ tokens

-- The set of MIPS instruction idents that have a load-delay slot.
-- Per MIPS I R3000A: `lw`, `lh`, `lhu`, `lb`, `lbu`, `lwc2` (gte_lw).
-- Note: `lui` (load_upper_i) does NOT have a load delay on MIPS I — it's an ALU op, not a load.
-- The `load_imm_*` macros are lui + ori sequences with no per-component load delay either.
local LOAD_INSTRUCTION_IDENTS = {
	load_word   = true,
	load_half   = true,
	load_half_u = true,
	load_byte   = true,
	load_byte_u = true,
	gte_lw      = true,
	gte_lwc2    = true,
}

-- Patterns for O_(<arg1>, <arg2>) and S_(<arg>) captures.
-- UNANCHORED, the substring can appea anywhere in the token (e.g., `load_word(R_T0, R_TapePtr, O_(Binds_X, field))` matches at position ~24).
-- The binds_name match is deferred to check_abi_handoff (which compares tc.o_arg1 == atom.info.binds).
local O_PATTERN = "O_%(([%w_]+),%s*([%w_]+)%s*%)"
local S_PATTERN = "S_%(([%w_]+)%s*%)"

-- Ident patterns for control-transfer instruction kinds:
--   * `branch_*` (conditional): `branch_equal`, `branch_ne`, `branch_lt_zero`, `branch_ge_zero`, `branch_le_zero`, `branch_gt_zero`.
--   * `jump` / `call_addr` (unconditional absolute): one immediate offset field; can carry `atom_offset(F, T)`.
--   * `jump_reg` / `call_reg` / `jump_link` (register-form): no offset field; `atom_offset` is invalid; transfers OUT of the current atom.
local BRANCH_PATTERN          = "^branch_[%w_]+%s*%("
-- `jump_rel(off)` is an ergonomic alias for `branch_equal(R_0, R_0, off)` (the within-atom-safe unconditional jump — see `code/duffle/mips.h`).
-- The C preprocessor expands it BEFORE the metaprogram sees the source, but for source-level metadata consistency we still match it here and classify it as a branch_equal.
-- This keeps `consuming_encoder` canonical for any downstream tooling that consults the metadata field.
local JUMP_REL_PATTERN      = "^jump_rel%s*%("
local UNCOND_JUMP_PATTERNS = {
    "^%f[%w]jump%f[%W]",
    "^%f[%w]call_addr%f[%W]",
}
local TERMINAL_JUMP_PATTERNS = {
    "^%f[%w]jump_reg%f[%W]",
    "^%f[%w]call_reg%f[%W]",
    "^%f[%w]jump_link%f[%W]",
}
local function matches_any(tok, patterns)
    for i = 1, #patterns do
        if tok:match(patterns[i]) then return true end
    end
    return false
end

local function classify_tokens(tokens)
	local n       = #tokens
	local tc      = {}
	local nop_run = 0  -- running count of consecutive nop words (forward pass)
	for tok_idx, t in ipairs(tokens) do
		local tok   = t.tok
		local ident = tok:match("^([%w_]+)") or "?"
		local nop_words = 0
		if     ident == "nop"  then nop_words = 1
		elseif ident == "nop2" then nop_words = 2 end

		-- `mac_yield_tail` is the canonical end-of-atom terminator when paired with `mac_yield_load`
		-- in a preceding branch's BD-slot. It runs `addiu_self R_TapePtr; jr R_AtomJmp; nop` — the
		-- "tail" half of the lego split. Treat it as a yield for the `mac_yield_uniformity` check.
		local is_yield      = ident == "mac_yield" or ident == "mac_yield_tail"
		local is_atom_label = false
		local label_name    = nil
		local is_branch     = false
		local is_unconditional_jump = false
		local is_terminal_jump   = false
		local branch_label  = nil
		local is_load       = LOAD_INSTRUCTION_IDENTS[ident] == true
		local is_store_word = ident == "store_word"

		-- Per-check pre-computes (R3 lift).
		-- Each pre-compute eliminates one per-token regex/string-find call from check_abi_handoff / check_gpu_portstore_shape.
		local mac_format_shape     = nil
		local is_gte_store         = false
		local is_ot_tag            = false
		local writes_r_prim_cursor = false
		local reads_r_tape_ptr     = false
		local o_arg1, o_arg2       = nil, nil
		local s_arg1               = nil

		if ident == "atom_label" then
			is_atom_label = true
			label_name    = tok:match("^atom_label%s*%(%s*([%w_]+)%s*%)")
		elseif tok:match(BRANCH_PATTERN) or tok:match(JUMP_REL_PATTERN) then
			-- Conditional branch OR `jump_rel` (the within-atom-safe unconditional jump alias).
			-- Both encode a 16-bit signed relative word offset.
			is_branch    = true
			branch_label = tok:match("atom_offset%s*%([^,]+,%s*([%w_]+)%s*%)") or false
		elseif matches_any(tok, UNCOND_JUMP_PATTERNS) then
			-- Unconditional absolute jump / call: `jump(off)` / `call_addr(off)`.
			-- One immediate offset field; can carry an `atom_offset(F, T)` marker (the offsets pass dispatches on `consuming_encoder` — see `passes/offsets.lua::compute_offsets`).
			is_branch              = true
			is_unconditional_jump = true
			branch_label           = tok:match("atom_offset%s*%([^,]+,%s*([%w_]+)%s*%)") or false
		elseif matches_any(tok, TERMINAL_JUMP_PATTERNS) then
			-- Register-form jump / call: no offset field; `atom_offset` is invalid here (the offsets pass will error if one is supplied).
			-- Transfers control OUT of the current atom — the CFG treats this as a path terminator.
			is_terminal_jump = true
		end

		-- mac_format_X_color / mac_gte_store_<shape> / mac_insert_ot_tag_<shape> (used by check_gpu_portstore_shape).
		local shape = ident:match("^mac_format_([%w_]+)_color$")
		if shape then mac_format_shape = shape end
		if ident:match("^mac_gte_store_[%w_]+$")  then is_gte_store = true end
		if ident:match("^mac_insert_ot_tag_[%w_]+$") then is_ot_tag    = true end

		-- O_(<arg1>, <arg2>) / S_(<arg>) captures (used by check_abi_handoff).
		-- Cheap pattern match — anchored, fails fast on non-matching tokens.
		o_arg1, o_arg2 = tok:match(O_PATTERN)
		if not o_arg1 then s_arg1 = tok:match(S_PATTERN) end

		-- R_TapePtr + R_PrimCursor references (used by check_abi_handoff / check_gpu_portstore_shape).
		if tok:find("R_TapePtr", 1, true) then reads_r_tape_ptr = true end
		if is_store_word and tok:find("R_PrimCursor", 1, true) then writes_r_prim_cursor = true end

		tc[tok_idx] = {
			ident                  = ident,
			nop_words              = nop_words,
			nop_prefix             = nop_run,
			is_yield               = is_yield,
			is_atom_label          = is_atom_label,
			label_name             = label_name,
			is_branch              = is_branch,
			is_unconditional_jump  = is_unconditional_jump,
			is_terminal_jump       = is_terminal_jump,
			branch_label           = branch_label,
			is_load                = is_load,
			is_store_word          = is_store_word,
			mac_format_shape       = mac_format_shape,
			is_gte_store           = is_gte_store,
			is_ot_tag              = is_ot_tag,
			writes_r_prim_cursor   = writes_r_prim_cursor,
			reads_r_tape_ptr       = reads_r_tape_ptr,
			o_arg1                 = o_arg1,
			o_arg2                 = o_arg2,
			s_arg1                 = s_arg1,
		}
		-- Advance the nop run for the NEXT token.
		if nop_words > 0 then nop_run = nop_run + nop_words
		else                  nop_run = 0
		end
	end
	return tc
end

-- ════════════════════════════════════════════════════════════════════════════
-- Check #1: transfer-hazard analysis (forward walker + reader).
--
-- Single typed CPU/COP0/COP2/GTE relation analysis via the forward walker (`analyze_hardware_relations`).
-- Hazards are projected into findings by the `transfer_hazards` CHECK_RULES reader (`check_transfer_hazards`).
--
-- The forward walker (`analyze_hardware_relations`) reads `atom.paths.word_events` once per atom.
-- For every emitted word event it:
--   1. Inspects current pending relations against the event as CONSUMER.
--      A producer's destination is "consumed" by: 
--        * a `gte_cmdw_*` whose command input set contains the destination (or any fan-out destination of an IRGB write); OR
--        * any encoder whose `OPERAND_READ_POSITIONS` includes the GPR destination of an MFC2/CFC2/MFC0 relation.
--      The consumer check computes `gap = consumer.word - producer.word - 1` and records a hazard on `atom.paths.hazards` when `gap < required`.
--   2. Applies the event's GPR value effects (`duffle.INSTRUCTION_GPR_EFFECTS`) to `atom.paths.forward_state.gpr_values`.
--      Unknown writers invalidate the destination GPR's lattice value to `{kind="unknown"}`.
--      The lattice is closed: `{kind="unknown"}` and `{kind="constant", value=<U4>}`. 
--      Bounded constant propagation handles load_upper_i / add_ui / or_i / and_i / xor_i + their self variants) on top of the same forward walker;
--      The writer invalidation is the conservative default.
--   3. Stages any relation rows whose `token` matches the event as PRODUCERS.
--      The destination operand is `event.args[relation.writes.arg]`. 
--      Rows with a `destination_match` filter are only staged when the destination operand equals the filter (e.g. C2_IRGB for the IRGB fan-out row).
--      The MTC2 ordinary row and the MTC2-IRGB row are both inspected.
--      Only the matching row stages (the non-matching row is ignored for that event).
--
-- After the walker runs, the `transfer_hazards` CHECK_RULES reader (`check_transfer_hazards`) copies every entry on `atom.paths.hazards` into the per-atom findings list.
-- The first `transfer_hazards` reader comment above records the projection contract.
--
-- The walker is called once before the CHECK_RULES per-atom dispatch (see `validate()`);
-- The reader runs as part of the same CHECK_RULES dispatch so its findings land in `findings` alongside the other checks.
--
-- The producer's own emitted word does NOT retire the relation (per the PSX-SPX rule in `docs/psx-spx/docs/cpuspecifications.md:407-419`):
-- "Store delays are counted in numbers of clock cycles (not in numbers of opcodes).
-- For 3 cycle delay, one must usually insert 3 cached opcodes (or one uncached opcode)." `gap = consumer.word - producer.word - 1`
-- therefore counts ONLY words strictly between the producer and the consumer.
-- ─────────────────────────────────────────────────────────────────────────

-- True iff `consumer_event` is a GTE command (gte_cmdw_* or one of the human-readable aliases mapped in `duffle.GTE_COMMAND_ALIASES`).
-- Used by the LWC2 retirement-regime dispatch in the forward walker: a GTE-command consumer can read the LWC2 result in the very next slot
-- (the GTE pipeline latches the LWC2 data); any other consumer must observe the standard MIPS load delay (gap >= 1).
local function is_gte_command(consumer_event)
	local tok = consumer_event.encoder or consumer_event.ident or ""
	if tok:sub(1, 9) == "gte_cmdw_" then return true end
	local  aliases = duffle.GTE_COMMAND_ALIASES or {}
	return aliases[tok] ~= nil
end

-- True iff `consumer_word` falls inside the COP2 command's input set OR inside the producer's `fanout_to` set (for IRGB writes).
-- Used by the consumer-match step of the forward walker.
local function is_cop2_consumer_of(consumer_event, destination, producer_rel)
	local consumer_token = consumer_event.encoder or consumer_event.ident
	-- Direct match: the consumer's argument is the destination.
	-- (Reserved for future relations where the consumer literally reads the destination register;
	-- not used by MTC2/CTC2 today because the "consumer" is a GTE command and its reads are not operand positions.)
	local args = consumer_event.args or {}
	for _, pos in ipairs(args) do
		if   pos == destination then return true end
	end
	-- Match via the command's input set: the consumer encoder resolves to a `gte_cmdw_*`
	-- short form whose `duffle.GTE_COMMAND_INPUTS` entry includes the destination (or a fan-out target).
	local aliases   = duffle.GTE_COMMAND_ALIASES or {}
	local canonical = aliases[consumer_token] or consumer_token
	if canonical:sub(1, 9) == "gte_cmdw_" or aliases[consumer_token] then
		local inputs     = duffle.GTE_COMMAND_INPUTS or {}
		local cmd_inputs = inputs[canonical]
		if cmd_inputs then
			-- Direct hit.
			for _, in_reg in ipairs(cmd_inputs) do
				if in_reg == destination then return true end
			end
			-- Fan-out hit (IRGB writes fan out to C2_IR1/C2_IR2/C2_IR3).
			for _, fanout in ipairs(producer_rel.fanout_to or {}) do
				for _, in_reg in ipairs(cmd_inputs) do
					if in_reg == fanout then return true end
				end
			end
		end
	end
	return false
end

local function gpr_identity(event, pos)
	local keys = event and event.gpr_keys
	if keys and keys[pos] then return keys[pos] end
	local arg = event and event.args and event.args[pos]
	if type(arg) == "string" and arg:sub(1, 2) == "R_" then return arg end
	return nil
end

-- True iff `consumer_event` reads the GPR operand at any position the destination register occupies.
-- read_pos lookup consults `duffle.OPERAND_READ_POSITIONS` for the consumer's encoder and walks each `args[pos]` to find an operand-equal match.
local function is_gpr_consumer_of(consumer_event, destination)
	local consumer_token = consumer_event.encoder or consumer_event.ident
	local read_pos       = duffle.OPERAND_READ_POSITIONS or {}
	local positions      = read_pos[consumer_token]
	if not positions then return false end
	for _, pos in ipairs(positions) do
		if gpr_identity(consumer_event, pos) == destination then return true end
	end
	return false
end

-- Bounded U4 arithmetic for the GPR-value lattice. LuaJIT supplies the `bit` module;
-- the arithmetic fallback keeps this pass Lua 5.3-compatible without adding a dependency to the metaprogram.
local bit_ok, bit = pcall(require, "bit")
if not bit_ok then bit = nil end

local U4_MODULUS = 0x100000000

local function wrap_u4(value)
	if type(value) ~= "number" then return nil end
	value = value % U4_MODULUS
	if value < 0 then value = value + U4_MODULUS end
	return value
end

local function bit_binary(left, right, operation)
	left  = wrap_u4(left)
	right = wrap_u4(right)
	if left == nil or right == nil then return nil end
	if bit then
		local value
		if     operation == "or"  then value = bit.bor( left, right)
		elseif operation == "and" then value = bit.band(left, right)
		else                           value = bit.bxor(left, right)
		end
		return wrap_u4(value)
	end

	local result = 0
	local place  = 1
	for _ = 1, 32 do
		local left_bit  = left % 2
		local right_bit = right % 2
		local take
		if     operation == "or"  then take = left_bit == 1 or right_bit == 1
		elseif operation == "and" then take = left_bit == 1 and right_bit == 1
		else                           take = left_bit ~= right_bit
		end
		if take then result = result + place end
		left  = (left  - left_bit)  / 2
		right = (right - right_bit) / 2
		place = place * 2
	end
	return result
end

local function shift_left_u4(value, amount)
	value  = wrap_u4(value)
	amount = tonumber(amount)
	if value == nil or amount == nil then return nil end
	amount = math.floor(amount) % 32
	if bit then return wrap_u4(bit.lshift(value, amount)) end
	return wrap_u4(value * (2 ^ amount))
end

-- Resolve only a standalone integer literal.
-- Compound C expressions remain unknown by design; the analyzer must not pretend to be a C evaluator.
local function parse_integer_literal(raw)
	if type(raw) ~= "string" then return nil end
	raw = duffle.trim(raw)
	while raw:sub(1, 1) == "(" and raw:sub(-1) == ")" do
		raw = duffle.trim(raw:sub(2, -2))
	end
	local sign = 1
	if     raw:sub(1, 1) == "-" then sign = -1; raw = raw:sub(2)
	elseif raw:sub(1, 1) == "+" then            raw = raw:sub(2)
	end
	raw = raw:gsub("[uUlL]+$", "")
	local value
	if     raw:match("^0[xX][%da-fA-F]+$") then value = tonumber(raw:sub(3), 16)
	elseif raw:match("^%d+$")              then value = tonumber(raw, 10)
	else
		return nil
	end
	if value == nil then return nil end
	return wrap_u4(sign * value)
end

local function sign_extend_i16(value)
	value = value % 0x10000
	if value >= 0x8000 then return value - 0x10000 end
	return value
end

local function is_gpr_operand(operand)
	return type(operand) == "string" and operand:sub(1, 2) == "R_"
end

local function is_tracked_gpr(operand)
	return is_gpr_operand(operand)
		or (type(operand) == "string" and operand:sub(1, 7) == "reguse:")
end

local function constant_for_operand(gpr_values, operand)
	if operand == "R_0" then return 0 end
	local slot = is_gpr_operand(operand) and gpr_values[operand] or nil
	if slot and slot.kind == "constant" then return wrap_u4(slot.value) end
	return nil
end

local function invalidate_gpr(gpr_values, operand)
	if is_tracked_gpr(operand) and operand ~= "R_0" then
		gpr_values[operand] = { kind = "unknown" }
	end
end

local function store_gpr_constant(gpr_values, operand, value)
	if not is_tracked_gpr(operand) or operand == "R_0" then return end
	if value == nil then gpr_values[operand] = { kind = "unknown" }
	else                 gpr_values[operand] = { kind = "constant", value = wrap_u4(value) }
	end
end

local function evaluate_gpr_value_rule(rule, ev_args, gpr_values)
	local operation = rule.op
	if operation == "load_upper_i" then
		local immediate = parse_integer_literal(ev_args[rule.immediate])
		if    immediate == nil then return nil end
		return shift_left_u4(immediate % 0x10000, 16)
	end

	-- Encoders that take `R_0` implicitly (e.g. `li_s(rt, imm)` which is `add_ui(rt, R_0, imm)`) have a non-GPR operand at the source position.
	-- Fall back to R_0 = 0.
	-- The implicit-R_0 macros also use a different immediate position (e.g. `li_s`'s `add_ui` rule has source = 2 / immediate = 3
	-- but the macro takes 2 args); when the configured immediate position is out of bounds.
	-- Fall back instead to scanning the macro's args for the first integer literal and use that as the immediate.
	local source = 0
	if rule.source then
		if is_gpr_operand(ev_args[rule.source]) then
			source = constant_for_operand(gpr_values, ev_args[rule.source])
			if source == nil then return nil end
		end
		-- Non-GPR at source position = implicit R_0; source stays 0.
	end
	local immediate = nil
	if rule.immediate and ev_args[rule.immediate] ~= nil then
		immediate = parse_integer_literal(ev_args[rule.immediate])
		if immediate == nil then return nil end
	elseif rule.immediate then
		-- Immediate position out of bounds: scan for the first integer literal in the args.
		for _, arg in ipairs(ev_args) do
			immediate = parse_integer_literal(arg)
			if immediate ~= nil then break end
		end
		if immediate == nil then return nil end
	end
	if     operation == "add_ui"      then return wrap_u4(      source + sign_extend_i16(immediate))
	elseif operation == "or_i"        then return bit_binary(   source, immediate % 0x10000, "or")
	elseif operation == "and_i"       then return bit_binary(   source, immediate % 0x10000, "and")
	elseif operation == "xor_i"       then return bit_binary(   source, immediate % 0x10000, "xor")
	elseif operation == "shift_lleft" then return shift_left_u4(source, immediate)
	end

	if rule.sources then
		local values = {}
		for index, position in ipairs(rule.sources) do
			values[index] = constant_for_operand(gpr_values, ev_args[position])
			if values[index] == nil then return nil end
		end
		if     operation == "add_u" then return wrap_u4(values[1] + values[2])
		elseif operation == "or_u"  then return bit_binary(values[1], values[2], "or")
		end
	end
	return nil
end

-- Apply the GPR read/write effects of one emitted event to the forward_state GPR-value lattice.
-- Encoders without an explicit effect row conservatively invalidate every R_-prefixed operand.
-- Recognized value rules are evaluated before their destination is invalidated.
-- A failed/unknown evaluation writes `{kind = "unknown"}` instead.
local function apply_gpr_effects(ev, forward_state)
	local ev_ident   = ev.encoder or ev.ident
	local ev_args    = ev.args or {}
	local gpr_values = forward_state.gpr_values
	local effects    = duffle.INSTRUCTION_GPR_EFFECTS or {}
	local row        = effects[ev_ident]
	if row == nil then
		for pos, operand in ipairs(ev_args) do
			local key = gpr_identity(ev, pos) or operand
			if type(key) == "string" and (key:sub(1, 2) == "R_" or key:sub(1, 7) == "reguse:") then
				if key ~= "R_0" then gpr_values[key] = { kind = "unknown" } end
			end
		end
		return
	end

	local value_rule = (duffle.GPR_VALUE_RULES or {})[ev_ident]
	local value      = value_rule and evaluate_gpr_value_rule(value_rule, ev_args, gpr_values) or nil
	for _, position in ipairs(row.writes or {}) do
		local destination = gpr_identity(ev, position)
		if destination then
			if value_rule and position == value_rule.dest and value ~= nil then
				store_gpr_constant(gpr_values, destination, value)
			else
				if destination ~= "R_0" then gpr_values[destination] = { kind = "unknown" } end
			end
		end
	end
end

-- Look up the alias of a GTE command ident.
-- Defaults to the input ident so unknown idents surface rather than silently inheriting a 0-cycle command input set.
local function canonical_command(ident)
	local aliases = duffle.GTE_COMMAND_ALIASES or {}
	return aliases[ident] or ident
end

-- True for a COP2/GTE use that can make a pending SR.CU2 transition observable.
-- Atom entry intentionally starts at `unobserved`; this helper never creates a finding without a preceding Status write.
local function is_cop2_use(ident)
	local canonical = canonical_command(ident)
	return canonical:sub(1, 9) == "gte_cmdw_" or ident:sub(1, 4) == "gte_"
end

local function append_cu2_finding(atom, event, forward, transition,
	gap, kind, confidence, message)
	local event_ident = event.encoder or event.ident or "?"
	local policy      = duffle.CU2_TRANSITION_POLICY or {}
	local evidence    = policy.evidence or {}
	local event_line  = line_for_word_event(event)
	atom.paths.hazards[#atom.paths.hazards + 1] = {
		check                = "transfer_hazards",
		kind                 = kind,
		atom                 = atom.name,
		line                 = event_line,
		source               = event.def_path or event.source or "",
		relation_id          = "mtc0_cu2_visibility",
		semantic             = "MTC0",
		direction            = "gpr_to_cop0_status",
		producer_destination = "SR.CU2",
		producer_word        = transition.producer_word,
		producer_line        = transition.producer_line,
		producer_source      = transition.producer_source,
		consumer_word        = event.i or event.word or 0,
		consumer_token       = event_ident,
		gap                  = gap,
		required             = transition.required,
		evidence_confidence  = confidence,
		evidence_source      = evidence.source or transition.evidence_source or "",
		target_state         = transition.target_state,
		status_register      = transition.status_register,
		status_value         = transition.status_value,
		msg                  = message,
	}
end

-- Read `sys_mov_to_cop0(source, 12)` before applying any writes from the current event.
-- A known source stages a target transition; an unknown source stages an ambiguity that is reported only if a later COP2 use reaches it.
local function stage_cu2_transition(ev_ident, ev_args, ev_word, ev_line,
	ev_source, forward)
	if ev_ident ~= "sys_mov_to_cop0" then return end
	local  policy = duffle.CU2_TRANSITION_POLICY
	if not policy then return end
	local status_register = parse_integer_literal(ev_args[2])
	if    status_register ~= policy.status_register then return end

	local status_value   = constant_for_operand(forward.gpr_values, ev_args[1])
	local target_state   = "unknown"
	local target_enabled = nil
	if status_value ~= nil then
		target_enabled = bit_binary(status_value, policy.enable_bit, "and") ~= 0
		target_state   = target_enabled and "enabled" or "disabled"
	end
	forward.cu2_transition = {
		producer_word   = ev_word,
		producer_line   = ev_line,
		producer_source = ev_source,
		status_register = status_register,
		status_value    = status_value,
		target_enabled  = target_enabled,
		target_state    = target_state,
		required        = policy.required,
		evidence_source = policy.evidence and policy.evidence.source or "",
	}
	forward.cu2_state = "pending"
end

-- Consume a pending Status/CU2 transition at the first relevant COP2 event.
-- The producer and consumer endpoints are excluded from the strict gap.
-- A conservative early transition emits once and then settles to its target;
-- Unknown Status emits one info edge and clears. A settled disable emits the exact COP2-unavailable finding required by the contract.
local function consume_cu2_transition(atom, event, ev_word, forward)
	if not is_cop2_use(event.encoder or event.ident or "") then return end
	local transition = forward.cu2_transition
	if not transition then return end

	local gap        = ev_word - transition.producer_word - 1
	local target     = transition.target_state
	local event_line = line_for_word_event(event)
	if target == "unknown" then
		append_cu2_finding(atom, event, forward, transition, gap, "info", "unknown",
			string.format("%s at line %d uses COP2 after an MTC0 Status write whose CU2 value is unknown (gap=%d, configured boundary=%d)"
				, atom.name, event_line
				, gap, transition.required
			)
		)
		forward.cu2_state      = "unknown"
		forward.cu2_transition = nil
		return
	end

	if gap < transition.required then
		local verb = target == "enabled" and "enable" or "disable"
		append_cu2_finding(atom, event, forward, transition, gap, "warning", "conservative",
			string.format("%s at line %d uses COP2 before the SR.CU2 %s transition has settled (gap=%d, required=%d; timing is conservative)"
				, atom.name, event_line
				, verb, gap, transition.required
			)
		)
		forward.cu2_state      = target
		forward.cu2_transition = nil
		return
	end

	forward.cu2_transition = nil
	if target == "enabled" then
		forward.cu2_state = "enabled"
	else
		append_cu2_finding(atom, event, forward, transition, gap,
			"error", "exact",
			string.format("%s at line %d: COP2 unavailable after SR.CU2 was disabled"
				.. " (gap=%d, required=%d)",
				atom.name, event_line,
				gap, transition.required))
		forward.cu2_state = "disabled"
	end
end

-- The forward walker. Populates `atom.paths.forward_state`, `.relations`, and `.hazards`.
-- Called once per atom before the per-atom CHECK_RULES dispatch loop.
local function analyze_hardware_relations(atom)
	local events      = atom.paths and atom.paths.word_events or {}
	local prior_state = atom.paths.forward_state
	local seed_values = {}
	if prior_state and not prior_state._analysis_complete then
		for register, slot in pairs(prior_state.gpr_values or {}) do
			if type(slot) == "table" and slot.kind == "constant" then
				seed_values[register] = {
					kind  = "constant",
					value = wrap_u4(slot.value),
				}
			elseif type(slot) == "table" and slot.kind == "unknown" then
				seed_values[register] = { kind = "unknown" }
			end
		end
	end

	local forward = {
		gpr_values         = seed_values,
		pending            = {},
		cu2_state          = "unobserved",
		cu2_transition     = nil,
		_analysis_complete = false,
	}
	-- The architectural zero register is always a known U4 zero and cannot be invalidated by an emitted writer.
	forward.gpr_values.R_0 = { kind = "constant", value = 0 }
	atom.paths.forward_state = forward
	atom.paths.relations     = {}
	atom.paths.hazards       = {}

	local hazards   = atom.paths.hazards
	local relations = atom.paths.relations
	local pending   = forward.pending

	local relations_table = duffle.HARDWARE_RELATIONS or {}
	-- Build a token-indexed lookup once per walker pass.
	local rows_by_token = {}
	for _, row in ipairs(relations_table) do
		local token = row.token
		if token then
			rows_by_token[token] = rows_by_token[token] or {}
			rows_by_token[token][#rows_by_token[token] + 1] = row
		end
	end

	for _, ev in ipairs(events) do
		local ev_ident  = ev.encoder   or ev.ident  or "?"
		local ev_line   = line_for_word_event(ev)
		local ev_source = ev.def_path  or ev.source or ""
		local ev_args   = ev.args      or {}
		-- `word_events` use `i` as the 0-based word index across the entire expansion.
		-- Default to 0 if the field is absent (the producer's own word).
		local ev_word   = ev.i or 0

		-- Read a Status source, then apply current-event GPR writes, then consume a pending CU2 transition at the first relevant COP2 use.
		-- Both operations are part of this one event walk.
		stage_cu2_transition(ev_ident, ev_args, ev_word, ev_line, ev_source, forward)
		consume_cu2_transition(atom, ev, ev_word, forward)

		-- ── 1. Inspect pending relations against the event as CONSUMER. ──
		-- Walk pending in REVERSE so `table.remove` doesn't shift indexes still to be inspected.
		for pending_idx = #pending, 1, -1 do
			local prod     = pending[pending_idx]
			local relation = prod.relation
			local semantic = relation.semantic
			local is_match = false
			if semantic == "MTC2" or semantic == "CTC2" or semantic == "LWC2_to_GTE" or semantic == "LWC2_to_other" then
				-- Consumer is a GTE command whose input set contains the producer's COP2 destination (or a fan-out target).
				-- LWC2_to_GTE   — GTE-command consumer: gap = 0 OK (the pipeline latches the LWC2 result).
				-- LWC2_to_other — non-GTE consumer:     standard load delay applies.
				if relation.id == "lwc2_to_gte_command" then
					is_match = is_gte_command(ev) and is_cop2_consumer_of(ev, prod.destination, relation)
				elseif relation.id == "lwc2_to_other_consumer" then
					is_match = (not is_gte_command(ev)) and is_cop2_consumer_of(ev, prod.destination, relation)
				else
					is_match = is_cop2_consumer_of(ev, prod.destination, relation)
				end
			elseif semantic == "MFC2" or semantic == "CFC2" or semantic == "MFC0" then
				-- Consumer is any encoder that reads the producer's GPR destination as an operand.
				is_match = is_gpr_consumer_of(ev, prod.destination)
			elseif semantic == "command_latch" then
				-- Consumer is a subsequent MTC2/CTC2 overwrite of the same C2 destination.
				-- The semantic is the post-command latch direction (command -> register);
				-- This is intentionally separate from the preceding MTC2 -> command relation.
				is_match = (ev_ident == "gte_mv_to_data_r" or ev_ident == "gte_mv_to_ctrl_r")
					and ev_args[1] ~= nil
					and ev_args[2] == prod.destination
			end
			if is_match then
				local gap                = ev_word - prod.word - 1
				local unknown_visibility = relation.visibility and relation.visibility.kind == "unknown_consumer"
				if unknown_visibility then
					hazards[#hazards + 1] = {
						check                = "transfer_hazards",
						kind                 = "info",
						atom                 = atom.name,
						line                 = ev_line,
						source               = ev_source,
						relation_id          = relation.id,
						semantic             = relation.semantic,
						direction            = relation.direction,
						producer_destination = prod.destination,
						producer_word        = prod.word,
						producer_line        = prod.line,
						producer_source      = prod.source_path,
						consumer_word        = ev_word,
						consumer_token       = ev_ident,
						gap                  = gap,
						required             = nil,
						evidence_confidence  = relation.evidence and relation.evidence.confidence or "unknown",
						evidence_source      = relation.evidence and relation.evidence.source or "",
						msg = string.format("%s at line %d: %s relation %s has an unknown memory-side visibility (producer %s at word %d, consumer at word %d, gap=%d) [%s]"
							, atom.name, ev_line, relation.semantic, relation.id
							, prod.destination, prod.word, ev_word, gap
							, (relation.evidence and relation.evidence.confidence or "unknown")
						),
					}
				elseif prod.required ~= nil and gap < prod.required then
					local payload = {
						check                = "transfer_hazards",
						kind                 = prod.violation_kind or "error",
						atom                 = atom.name,
						line                 = ev_line,
						source               = ev_source,
						relation_id          = relation.id,
						semantic             = relation.semantic,
						direction            = relation.direction,
						producer_destination = prod.destination,
						producer_word        = prod.word,
						producer_line        = prod.line,
						producer_source      = prod.source_path,
						consumer_word        = ev_word,
						consumer_token       = ev_ident,
						gap                  = gap,
						required             = prod.required,
						evidence_confidence  = relation.evidence and relation.evidence.confidence or "unknown",
						evidence_source      = relation.evidence and relation.evidence.source or "",
						msg = string.format("%s at line %d: %s relation %s (producer %s at word %d, %s:%d) violated: consumer at word %d (gap=%d, required=%d) [%s]"
							, atom.name, ev_line, relation.semantic, relation.id
							, prod.destination, prod.word, prod.source_path, prod.line
							, ev_word, gap, prod.required
							, (relation.evidence and relation.evidence.confidence or "unknown")
						),
					}
					-- Surface producer_command on the payload (post-command latch relations store it on the relation row.
					-- Copy it to the top-level payload for the renderer).
					if relation.producer_command then
						payload.producer_command = relation.producer_command
					end
					hazards[#hazards + 1] = payload
				end
				local satisfied = nil
				if not unknown_visibility then satisfied = gap >= prod.required end
				-- Record the relation touch on `paths.relations` even when the gap is satisfied.
				-- Unknown relations are informational, not numeric pass/fail measurements.
				relations[#relations + 1] = {
					relation_id   = relation.id,
					semantic      = relation.semantic,
					producer_word = prod.word,
					consumer_word = ev_word,
					gap           = gap,
					required      = prod.required,
					satisfied     = satisfied,
				}
				table.remove(pending, pending_idx)
			end
		end

		-- ── 2. Apply GPR value effects. ──
		apply_gpr_effects(ev, forward)

		-- ── 3. Stage producers created by this event. ──
		local rows = rows_by_token[ev_ident]
		if rows then
			for _, row in ipairs(rows) do
				-- `stage = false` rows document a direction but do not create a later command-input producer (SWC2 and ordinary MTC0).
				if row.stage ~= false then
					local dest_arg    = row.writes and row.writes.arg
					local destination = dest_arg and (gpr_identity(ev, dest_arg) or ev_args[dest_arg]) or nil
					if destination then
						-- Apply the destination_match filter when present.
						if row.destination_match and row.destination_match ~= destination then
							goto continue_stage
						end
						-- A later write supersedes an unknown LWC2 edge for the same C2 destination before any command consumes it.
						for prior_idx = #pending, 1, -1 do
							local prior = pending[prior_idx]
							if prior.relation.semantic == "LWC2"
								and prior.destination == destination then
								table.remove(pending, prior_idx)
							end
						end
						local required = row.visibility and row.visibility.required
						if required == nil
							and not (row.visibility and row.visibility.kind == "unknown_consumer") then
							required = 1
						end
						pending[#pending + 1] = {
							relation       = row,
							destination    = destination,
							word           = ev_word,
							required       = required,
							source_path    = ev_source,
							line           = ev_line,
							violation_kind = row.violation_kind or "error",
						}
					end
				end
				::continue_stage::
			end
		end

		-- ── 4. Update semantic role state and stage post-command latch relations. ──
		-- A GTE command emits outputs with semantic roles (latest_screen_xy, otz, latest_color, etc.) per `duffle.GTE_COMMAND_OUTPUTS`.
		-- The walker records these on `forward_state.post_command_roles[<register>]` so the `gte_role_mismatch` reader can later detect a reader that picks the wrong register.
		--
		-- The walker also stages POST-COMMAND LATCH relations (kind = "command_latch_input"): a subsequent MTC2/CTC2 overwrite of a latched output before the measured boundary is a hazard.
		-- The relation kind is intentionally separate from the preceding MTC2 → command relation (`MTC2` / `CTC2` / `LWC2`).
		-- They describe different directions of the same memory subsystem and would otherwise be conflated.
		if canonical_command(ev_ident) ~= ev_ident then
			-- Not a GTE command; skip.
		else
			local canonical = canonical_command(ev_ident)
			if canonical:sub(1, 9) == "gte_cmdw_" then
				-- Update the post-command role state.
				local outputs = duffle.GTE_COMMAND_OUTPUTS or {}
				local cmd_outputs = outputs[canonical]
				if cmd_outputs then
					for _, out in ipairs(cmd_outputs) do
						if out.register then
							forward.post_command_roles = forward.post_command_roles or {}
							forward.post_command_roles[out.register] = {
								role             = out.role,
								command          = canonical,
								command_register = out.register,
								producer_word    = ev_word,
								producer_line    = ev_line,
							}
						end
					end
				end
				-- Stage post-command latch relations for every measured output.
				local latch_table = duffle.GTE_COMMAND_LATCH_WINDOWS or {}
				local cmd_latches = latch_table[canonical]
				if cmd_latches then
					for _, latch in ipairs(cmd_latches) do
						if latch.register and latch.required then
							-- A later MTC2/CTC2 overwrite of the same register before the measured boundary is the consumer of this relation.
							pending[#pending + 1] = {
								relation = {
									id        = "command_latch_input",
									semantic  = "command_latch",
									direction = "gte_command_to_cop2_register",
									token     = canonical,
									evidence  = {
										confidence = "conservative",
										source     = "gtepipelinetimings.md",
									},
									violation_kind    = "warning",
									producer_command  = canonical,
									producer_register = latch.register,
								},
								destination    = latch.register,
								word           = ev_word,
								required       = latch.required,
								source_path    = ev_source,
								line           = ev_line,
								violation_kind = "warning",
							}
						end
					end
				end
			end
		end
	end
	forward._analysis_complete = true
end

-- ─────────────────────────────────────────────────────────────────────────
-- Check #1b: transfer_hazards (READER for analyze_hardware_relations output).
--
-- The single forward walker `analyze_hardware_relations` (defined above) has already populated `atom.paths.hazards`.
-- This check copies every entry on that list into the per-atom `findings` table.
-- The first `transfer_hazards` reader comment above records the projection contract.
--
-- The walker also populates `atom.paths.relations` (one entry per satisfied-or-violated relation touch) and `atom.paths.forward_state` (the GPR-value lattice).
-- Neither of those is rendered as a finding here; bounded-value rules and LWC2 unknown edges share on top of the same forward walker and adds additional readers.
--
-- Static-analysis pass kind remains non-stopping (diagnostic):
-- The transfer-hazards findings appear in `result.errors` / `result.warnings` (according to the row's `violation_kind`) without changing the build exit status.
-- This preserves the documented PASSES["static-analysis"] policy in `ps1_meta.lua`.
-- ─────────────────────────────────────────────────────────────────────────

local function check_transfer_hazards(atom, _pipe_ctx, findings)
	local  hazards = atom.paths and atom.paths.hazards or {}
	for _, hazard in ipairs(hazards) do
		findings[#findings + 1] = hazard
	end
end

-- ─────────────────────────────────────────────────────────────────────────
-- Check #1d: gte_input_latch (READER for analyze_hardware_relations output).
--
-- The forward walker stages post-command latch relations on `atom.paths.hazards` with `relation_id = "command_latch_input"`.
-- This reader filters those entries and re-emits them under the `gte_input_latch` check name so the test contract can target them independently of the transfer_hazards check.
-- The first `transfer_hazards` reader comment above records the projection contract.
-- ─────────────────────────────────────────────────────────────────────────

local function check_gte_input_latch(atom, _pipe_ctx, findings)
	local hazards = atom.paths and atom.paths.hazards or {}
	for _, hazard in ipairs(hazards) do
		if hazard.relation_id == "command_latch_input" then
			local payload = {}
			for k, v in pairs(hazard) do payload[k] = v end
			payload.check = "gte_input_latch"
			-- Surface `producer_command` on the emitted payload:
			-- The hazard relation record carries it under `relation.producer_command` (since it lives on the relation row);
			-- copy it to the top-level payload for the renderer and the focused tests.
			if payload.producer_command == nil and payload.relation and payload.relation.producer_command then
				payload.producer_command = payload.relation.producer_command
			end
			findings[#findings + 1] = payload
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────
-- Check #1e: gte_role_mismatch (READER for forward_state semantic roles).
--
-- A GTE command emits outputs with semantic roles (latest_screen_xy, otz, latest_color, etc.) per `duffle.GTE_COMMAND_OUTPUTS`.
-- The forward walker records `forward_state.post_command_roles[<register>]` after each command.
--
-- A subsequent MFC2 (or any encoder that reads a C2 register) that picks the WRONG register for the active role emits a `result_role_mismatch` warning.
-- For example, reading `C2_SXY0` after RTPS is wrong: the `latest_screen_xy` role is `C2_SXY2`.
--
-- Note: the OLD `gte_result_position` check also emitted table-gap info findings for `_post_<cmd>` components missing a row in `duffle.GTE_COMPONENT_RESULT_CONTRACTS`.
-- That table-gap check was based on the `_post_<cmd>` NAMING convention rather than hardware truth, and was removed
-- (the user did not want naming to encode ordering semantics; A proper `atom_info` directive for ordering semantics is a future TODO).
--
-- The first `transfer_hazards` reader comment above records the projection contract.
-- ─────────────────────────────────────────────────────────────────────────

local function check_gte_role_mismatch(atom, _pipe_ctx, findings)
	local  forward = atom.paths and atom.paths.forward_state
	if not forward or not forward.post_command_roles then return end
	local events = atom.paths.word_events or {}

	-- For each word event whose encoder is `gte_mv_from_data_r`, look up the register being read in `forward_state.post_command_roles`.
	-- If a role is set, the reader's register must match the role's register (the registered "latest_<role>" target).
	for _, ev in ipairs(events) do
		local ev_ident = ev.encoder
		if ev_ident == "gte_mv_from_data_r" then
			local args = ev.args or {}
			local reg  = args[2]
			-- Find any post-command `latest_screen_xy` role entry recorded by a prior command.
			-- The newest projected screen coordinate is recorded under the command name.
			-- Reading from C2_SXY0 (the older projection slot) when a `latest_screen_xy` role was set to C2_SXY2 by RTPS / RTPT is a semantic mismatch.
			local latest_screen_xy_entry = nil
			for r, e in pairs(forward.post_command_roles or {}) do
				if e.role == "latest_screen_xy" then
					latest_screen_xy_entry = e
					break
				end
			end
			if reg and latest_screen_xy_entry then
				-- The reader picked C2_SXY0 but the latest_screen_xy role was set to C2_SXY2 by the prior command.
				-- This is a semantic mismatch.
				if reg ~= latest_screen_xy_entry.command_register
					and (reg == "C2_SXY0" or reg == "C2_SXY1") then
					local ev_line = line_for_word_event(ev)
					findings[#findings + 1] = {
						check       = "gte_role_mismatch",
						kind        = "warning",
						atom        = atom.name,
						line        = ev_line,
						source      = ev.def_path or ev.source or "",
						relation_id = "result_role_mismatch",
						semantic    = "result_position",
						command     = latest_screen_xy_entry.command,
						role        = latest_screen_xy_entry.role,
						actual_register   = reg,
						expected_register = "C2_SXY2",
						producer_word = latest_screen_xy_entry.producer_word,
						producer_line = latest_screen_xy_entry.producer_line,
						msg = string.format("%s at line %d: reading %s after %s but the %s role is C2_SXY2 (not %s)"
							, atom.name, ev_line
							, reg, latest_screen_xy_entry.command
							, latest_screen_xy_entry.role
							, reg),
					}
				end
			end
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────
-- Check #1f: hazard_nop_use (READER for forward_state NOP classification).
--
-- Each emitted `nop` word event is classified by inspecting the forward-state immediately before the word:
--   * `modeled-required`: a pending modeled relation exists that the nop retires
--     (the nop is needed to retire the relation, even if it can be replaced by independent useful work).
--   * `modeled-redundant`: no modeled relation is pending immediately before the nop (the nop is a redundant hazard).
--
-- Branch/jump delay-slot NOPs belong to `control_transfer_delay_slot_use`, so this check leaves them unclassified.
-- The fixed `mac_yield()` handshake (`jump_reg(R_AtomJmp), nop`) is preserved as suppressed.
--
-- Both classifications emit at `info` severity: `modeled-required` documents the model boundary and `modeled-redundant`
-- is a soft observation ("you have a redundant nop; consider replacing it").
-- Neither is a logic failure, so neither rises to `warning`.
--
-- `atom_dbg_skip` runtime helpers (`tape_exit`, `ac_yield`, the `ac_*` macro components) are exempt:
-- their structural nops are part of the fixed handshake and not author choices.
--
-- The first `transfer_hazards` reader comment above records the projection contract.
-- ─────────────────────────────────────────────────────────────────────────

local function check_hazard_nop_use(atom, _pipe_ctx, findings)
	local forward = atom.paths and atom.paths.forward_state
	local events  = atom.paths.word_events or {}
	-- GPR effects table used to resolve load destinations when classifying load-delay-slot nops.
	local gpr_effects = duffle.INSTRUCTION_GPR_EFFECTS or {}
	if not events or #events == 0 then return end
	-- Runtime-helper atoms / components (e.g. tape_exit, ac_yield) carry `debug_skip = true` from the bare
	-- `atom_dbg_skip` marker; their structural nops are part of the fixed handshake and not author choices.
	if is_runtime_helper(atom) then return end

	-- The walker does not currently snapshot the pending state per event; we replay the same forward walk cheaply here.
	-- The replay is observation-only (no staging); the only output is one finding per non-BD-slot nop with its classification.
	local pending_snapshot = {}
	local prev_ev = nil
	for event_idx, ev in ipairs(events) do
		local ev_ident = ev.encoder or ""
		local ev_args  = ev.args or {}
		local ev_word  = ev.i or 0
		local ev_line  = line_for_word_event(ev)

		-- Classify the nop BEFORE its event is applied to the pending state.
		if ev_ident == "nop" and prev_ev ~= nil then
			-- Skip BD-slot nops that are exclusively owned by control_transfer_delay_slot_use
			-- (the nop after a branch/jump — covered by that check separately).
			-- Every BD-slot nop is structural; this check never reports on it.
			-- (The earlier `if not suppressed then is_bd_slot = true end` form inverted the suppression - the `mac_yield()` handshake's `jump_reg(R_AtomJmp)` was incorrectly flagged.)
			local prev_ident   = prev_ev.encoder or ""
			local bd_policies  = duffle.CONTROL_TRANSFER_DELAY_SLOT_POLICIES or {}
			local is_bd_slot   = bd_policies[prev_ident] ~= nil
			if not is_bd_slot then
				-- Find a pending modeled relation that this nop would retire.
				local retired = nil
				for _, prod in ipairs(pending_snapshot) do
					if prod.required and (prod.word + prod.required + 1) > ev_word then
						retired = prod
						break
					end
				end
				if retired then
					-- Look ahead for the would-be consumer (the next emitted command or read after the nop that the relation would retire).
					-- For an MTC2 -> command relation, the consumer is the next GTE command after the nop.
					local would_be_consumer = nil
					for _, future_ev in ipairs(events) do
						local f_word = future_ev.i or future_ev.word or 0
						if f_word > ev_word then
							local f_ident   = future_ev.encoder or future_ev.ident or ""
							local f_args    = future_ev.args or {}
							local aliases   = duffle.GTE_COMMAND_ALIASES or {}
							local canonical = aliases[f_ident] or f_ident
							if canonical:sub(1, 9) == "gte_cmdw_" then
								local inputs     = duffle.GTE_COMMAND_INPUTS or {}
								local cmd_inputs = inputs[canonical]
								if cmd_inputs then
									for _, in_reg in ipairs(cmd_inputs) do
										if in_reg == retired.destination then
											would_be_consumer = f_ident
											break
										end
									end
								end
							elseif f_ident == "gte_mv_to_data_r" or f_ident == "gte_mv_to_ctrl_r" then
								if f_args[2] == retired.destination then
									would_be_consumer = f_ident
								end
							end
							if would_be_consumer then break end
						end
					end
					findings[#findings + 1] = {
						check                = "hazard_nop_use",
						kind                 = "info",
						atom                 = atom.name,
						line                 = ev_line,
						source               = ev.def_path or ev.source or "",
						nop_classification   = "modeled-required",
						nop_word_index       = ev_word,
						retired_relation     = retired.relation.id,
						producer_destination = retired.destination,
						consumer_token       = would_be_consumer or "<would-be-consumer>",
						msg = string.format("%s at line %d: nop at word %d is modeled-required (retires %s for %s)"
							, atom.name, ev_line, ev_word, retired.relation.id, retired.destination
						),
					}
				else
					-- Track the slot_kind so the BD-separation case can assert the mac_yield handshake is still suppressed.
					local slot_kind = "plain"
					-- MIPS load-delay slot: a `load_*` wrote a register in the previous slot, and the result is unavailable for 1 cycle.
					-- This `nop` is structurally required; classifying it as `modeled-required` is the correct signal
					-- (removing it would make the following instruction read the OLD value of the loaded register, a load-use hazard).
					-- The `load_delay_violations` check (Concern 3) catches the actual read-side error; here we suppress the `modeled-redundant` misclassification.
					-- The set of load instructions mirrors the LOAD_INSTRUCTION_IDENTS in `check_load_delay_slots`.
					local load_idents = {
						 load_word   = true,
						 load_half   = true,
						 load_half_u = true,
					   load_byte   = true,
						 load_byte_u = true,
						 gte_lw      = true,
						 gte_lwc2    = true 
					}
					local is_load_delay = load_idents[prev_ident] == true
					if    is_load_delay then
						-- Determine the destination register from the load's `writes` field.
						local prev_writes = gpr_effects[prev_ident] and gpr_effects[prev_ident].writes or {}
						local dest_pos    = prev_writes[1]
						local load_dest   = dest_pos and (gpr_identity(prev_ev, dest_pos) or (prev_ev.args or {})[dest_pos]) or "<load-destination>"
						local authored    = dest_pos and (prev_ev.args or {})[dest_pos] or load_dest
						local shown      = authored
						if type(load_dest) == "string" and load_dest:sub(1, 7) == "reguse:" then
							local slot = load_dest:match("([^:]+)$")
							if slot then shown = authored .. " (slot " .. slot .. ")" end
						end
						findings[#findings + 1] = {
							check                = "hazard_nop_use",
							kind                 = "info",
							atom                 = atom.name,
							line                 = ev_line,
							source               = ev.def_path or ev.source or "",
							nop_classification   = "modeled-required",
							nop_word_index       = ev_word,
							retired_relation     = "load_delay_slot",
							producer_destination = load_dest,
							consumer_token       = "<would-be-consumer>",
							msg = string.format("%s at line %d: nop at word %d is modeled-required (load-delay slot for %s)"
								, atom.name, ev_line, ev_word, shown
							),
						}
					else
						findings[#findings + 1] = {
							check              = "hazard_nop_use",
							kind               = "info",
							atom               = atom.name,
							line               = ev_line,
							source             = ev.def_path or ev.source or "",
							nop_classification = "modeled-redundant",
							nop_word_index     = ev_word,
							retired_relation   = nil,
							slot_kind          = slot_kind,
							msg = string.format("%s at line %d: nop at word %d is modeled-redundant (no pending modeled relation)"
								, atom.name, ev_line, ev_word
							),
						}
					end
				end
			end
		end

		-- Update the pending snapshot for the next iteration.
		-- The replay is observation-only; we mirror the walker's staging
		-- behavior for MTC2 / CTC2 / LWC2 / MFC2 / CFC2 / MFC0 / command_latch.
		local aliases   = duffle.GTE_COMMAND_ALIASES or {}
		local canonical = aliases[ev_ident] or ev_ident
		if ev_ident == "gte_mv_to_data_r" or ev_ident == "gte_mv_to_ctrl_r" then
			local relations_table = duffle.HARDWARE_RELATIONS or {}
			for _, row in ipairs(relations_table) do
				if row.token == ev_ident and row.stage ~= false then
					local dest_arg    = row.writes and row.writes.arg
					local destination = dest_arg and (gpr_identity(ev, dest_arg) or ev_args[dest_arg]) or nil
					if destination and (not row.destination_match or row.destination_match == destination) then
						local required = row.visibility and row.visibility.required
						if    required == nil and not (row.visibility and row.visibility.kind == "unknown_consumer") then
							required = 1
						end
						pending_snapshot[#pending_snapshot + 1] = {
							relation    = row,
							destination = destination,
							word        = ev_word,
							required    = required,
						}
					end
				end
			end
		elseif canonical:sub(1, 9) == "gte_cmdw_" then
			-- Command: stage post-command latch relations (same as the walker).
			local latch_table = duffle.GTE_COMMAND_LATCH_WINDOWS or {}
			local cmd_latches = latch_table[canonical]
			if cmd_latches then
				for _, latch in ipairs(cmd_latches) do
					if latch.register and latch.required then
						pending_snapshot[#pending_snapshot + 1] = {
							relation    = {
								id    = "command_latch_input",
								semantic = "command_latch",
							},
							destination = latch.register,
							word        = ev_word,
							required    = latch.required,
						}
					end
				end
			end
		end

		prev_ev = ev
	end
end

-- ─────────────────────────────────────────────────────────────────────────
-- Check #1c: control-transfer delay-slot use.
--
-- Reads `atom.paths.word_events` (the semantic emitted-word stream from `passes/emission_model.lua`).
-- For each event whose `encoder` is in `duffle.CONTROL_TRANSFER_DELAY_SLOT_POLICIES`, inspect the next emitted event in the SAME `events` array.
-- The next event is the hardware delay-slot word (the duffle pipeline already absorbs the BD-slot into the branch's cost in `analyze_atom_paths`.
-- This check observes, it does not reschedule.
--
-- Emit one `info`-severity finding when:
--   * the successor event is absent (no following emitted word); `slot_ident` is reported as `<missing>`; OR
--   * the successor event's `ident == "nop"` (the first emitted word of `nop2` is also `nop`).
--
-- Suppress the finding when `policy.suppress_arg1[first_arg]` is non-nil.
-- The only current suppression is `jump_reg(R_AtomJmp)`, the fixed `mac_yield()` handshake.
--
-- `atom_dbg_skip` runtime helpers (`tape_exit`, `ac_yield`, the `ac_*` macro components) are exempt:
-- their BD slots are part of the fixed handshake (`jump_reg(rret_addr), nop` for tape_exit, `jump_reg(R_AtomJmp), nop` for ac_yield).
--
-- `pipe_ctx` is unused; the uniform `(atom, pipe_ctx, findings)` signature is preserved so the check plugs into
-- the existing CHECK_RULES dispatch without modifying the per-atom loop or analyze_atom_paths.
-- `passes/emission_model` already normalizes `nop2` to two `nop` events and `atom_label` to zero events, so no special-case branching is needed for either.
-- ─────────────────────────────────────────────────────────────────────────

local function check_control_transfer_delay_slot_use(atom, pipe_ctx, findings)
	local  events = atom.paths.word_events or {}
	if not events or #events == 0 then return end
	-- Runtime-helper atoms / components (e.g. tape_exit, ac_yield) carry `debug_skip = true` from the bare
	-- `atom_dbg_skip` marker; their structural BD slots are part of the fixed handshake.
	if is_runtime_helper(atom) then return end
	local policies = duffle.CONTROL_TRANSFER_DELAY_SLOT_POLICIES or {}
	for event_idx, event in ipairs(events) do
		-- Canonical word_events use `encoder` as the leading identifier of the emitting token).
		-- Focused inputs may supply `ident` when constructing isolated events.
		local event_ident      = event.encoder or event.ident
		local slot_ident_field = event.encoder and "encoder" or "ident"
		local policy           = policies[event_ident]
		if policy then
			local arg1       = event.args and event.args[1] or nil
			local suppressed = policy.suppress_arg1 and policy.suppress_arg1[arg1] or nil
			if not suppressed then
				local slot       = events[event_idx + 1]
				local slot_ident = slot and (slot.encoder or slot.ident) or "<missing>"
				if slot == nil or (slot.encoder or slot.ident) == "nop" then
					-- Prefer `call_line` (the line of the `mac_X(...)` call site in the atom body) so the rendered
					-- finding points at the user's source, not at the vendored component body.
					local ev_line = line_for_word_event(event)
					findings[#findings + 1] = {
						atom  = atom.name,
						line  = ev_line,
						check = "control_transfer_delay_slot_use",
						kind  = "info",
						msg   = string.format("%s at line %d has `%s` whose emitted delay-slot word is `%s`; useful work may replace that no-op if its dependencies are valid on both paths"
							, atom.name, ev_line, event_ident, slot_ident),
					}
				end
			end
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Check #1d: load-delay slot violations (per-atom)
-- �═══════════════════════════════════════════════════════════════════════════

--- Walk every emitted word event of one atom. For each `is_load` event (lw / lh / lhu / lb / lbu / lwc2),
--- mark the destination register as "volatile through" the NEXT emitted slot — MIPS I R3000A load-delay
--- semantics. If any subsequent event in that 1-slot window reads the volatile register, emit a `load_delay_violation`
--- finding (severity: error — the load result is unavailable in the delay slot).
---
--- The register becomes non-volatile again at word N+2 (the load has retired), OR sooner if a non-load instruction overwrites the register
--- (the overwriter's write is the fresh producer; the load's value is shadowed and never observed by any reader).
---
--- Runtime-helper atoms / components (`debug_skip == true`) are exempt from some checks, but load-delay
--- safety applies to their emitted instructions as well.
---
--- The walker reads `duffle.OPERAND_READ_POSITIONS[event.encoder]` to determine which args are read-source
--- (the destination of a load is in `writes`, not `reads` — see `duffle.INSTRUCTION_GPR_EFFECTS`).
--- The check is purely structural; it does not consult the GPR-value lattice
--- (no constant propagation needed for load-delay detection — the volatility window is unconditional).
local function check_load_delay_slots(atom, pipe_ctx, findings)
	-- The load-delay check applies to every atom and component body, including debug-skipped components (`ac_*` and `atom_dbg_skip MipsAtom_(...)`).
	-- The `atom_dbg_skip` marker controls debugger stepping, not instruction safety.
	-- `atom_proc` atoms have full bodies with loads that need delay slots, so the check applies to them too.
	local p = atom.paths or {}
	if atom.kind ~= "atom" and atom.kind ~= "atom_proc" then return end
	local events = p.word_events or {}
	if   #events == 0 then return end

	local gpr_effects = duffle.INSTRUCTION_GPR_EFFECTS or {}
	local read_positions = duffle.OPERAND_READ_POSITIONS or {}
	-- volatile_until[reg] = 1-based word_events index; the slot AFTER which the register is safe.
	-- `nil` means "not currently volatile".
	local volatile_until = {}

	-- Compute the "net reads" of an event: read-positions MINUS write-positions.
	-- A position that is BOTH read and written (e.g. `add_ui rt, rs, imm` where the duffle table lists position 1 as both.
	-- See `duffle.OPERAND_READ_POSITIONS["add_ui"] = {1, 2}` and `INSTRUCTION_GPR_EFFECTS["add_ui"].writes = {1}` — 
	-- and for genuine RMW ops like `add rt, rs, rt` where position 1 IS both read+written) is not a "read" for load-delay purposes:
	-- The write shadows whatever value the register previously held. Only positions that are reads WITHOUT a co-occurring write to the same register count as net reads.
	local function net_reads(event_ident, args)
		local effect = gpr_effects[event_ident]
		local positions = read_positions[event_ident]
		if not positions then return {} end
		local writes_set = {}
		if effect and effect.writes then
			for _, pos in ipairs(effect.writes) do writes_set[pos] = true end
		end
		local net = {}
		for _, pos in ipairs(positions) do
			if not writes_set[pos] then net[#net + 1] = pos end
		end
		return net
	end

	for event_idx, event in ipairs(events) do
		local event_ident = event.encoder or event.ident
		local args        = event.args or {}
		local is_load     = LOAD_INSTRUCTION_IDENTS[event_ident] == true

		-- (1) Is this event reading a register that's still volatile from a previous load?
		-- Skip the load instruction itself (the load's own argument list may "read" its destination via `OPERAND_READ_POSITIONS`:
		-- e.g. `addiu rt, rs, imm` lists position 1 (rt) as a "read", but rt is the destination; the within-load argument list is not a separate consumer).
		-- Use `net_reads` to ignore RMW positions (write shadows read within the same instruction).
		if not is_load then
			for _, pos in ipairs(net_reads(event_ident, args)) do
				local reg = gpr_identity(event, pos)
				if reg then
					local until_idx = volatile_until[reg]
					if until_idx and event_idx <= until_idx then
						local ev_line = line_for_word_event(event)
						local authored = args[pos] or reg
						findings[#findings + 1] = {
							atom  = atom.name,
							line  = ev_line,
							check = "load_delay_violation",
							kind  = "error",
							msg   = string.format("%s at line %d reads %s at word %d, but a prior load's "
								.. "delay slot is not over until word %d; insert a `nop` between the "
								.. "load and this instruction.",
								atom.name, ev_line, authored, event_idx, until_idx),
						}
					end
				end
			end
		end

		-- (2) Update the volatile set based on what this event writes.
		local effect = gpr_effects[event_ident]
		if effect and effect.writes then
			for _, pos in ipairs(effect.writes) do
				local reg = gpr_identity(event, pos)
				if reg then
					if is_load then
						-- Load: destination volatile for exactly 1 slot (the delay slot).
						volatile_until[reg] = event_idx + 1
					else
						-- Non-load write to this register: overwrites shadow the load; the volatile state ends.
						-- If another reader comes later, it sees the overwriter's value (or unknown), not the stale load value.
						volatile_until[reg] = nil
					end
				end
			end
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Check #2: mac_yield uniformity
-- ════════════════════════════════════════════════════════════════════════════

--- Every atom body must contain exactly one `mac_yield()` call and it must be the LAST top-level token in the body 
--- (so the tape runtime can pick up cleanly at the next atom's bound registers).
---
--- Empty bodies are not currently flagged — runtime infrastructure atoms like 
--- `MipsAtom_(yield) { mac_yield() }` and `MipsAtom_(tape_exit) { jump_reg(rret_addr), nop }` 
--- are valid as-is; mac_yield at the end is the contract.
---
--- Runtime helpers carrying the bare `atom_dbg_skip` marker (`tape_exit`, `ac_yield`, the `ac_*` macro components) are exempt:
--- they intentionally do not follow the standard "1 yield at the end" contract. `tape_exit` performs its own `jump_reg(rret_addr),
--- nop` to return from the tape runner; `ac_yield` IS the `mac_yield()` implementation.
--- Flagging them as "missing mac_yield" is signal noise, not a logic failure.
---
--- Uses the standard `(atom, pipe_ctx, findings)` signature; `pipe_ctx` is unused.
local function check_mac_yield_uniformity(atom, pipe_ctx, findings)
	-- Runtime-helper atoms / components (e.g. tape_exit, ac_yield) carry `debug_skip = true` from the bare
	-- `atom_dbg_skip` marker; they intentionally break the "1 yield at the end" contract.
	if is_runtime_helper(atom) then return end
	-- Per-kind semantics:
	--   MipsAtom_          (baked atom): exactly 1 mac_yield at the end of the body. Control transfer is the atom's job.
	--   MipsAtom_Proc_     (runtime-proc atom): exactly 1 mac_yield at the end of the body. Same as baked atom;
	--                      the proc IS the atom; the runtime call to `atombuilder_unroll` doesn't introduce a parent atom.
	--   MipsAtomComp_      (bare static-array component): ZERO mac_yield.
	--                      The component is invoked from inside an atom body; the parent atom does the yield.
	--   MipsAtomComp_Proc_ (procedural component): ZERO mac_yield.
	--                      Same reasoning -- it's a function returning a MipsAtom slice, invoked from a parent atom.
	--
	-- The GTE pipeline-fill check applies to all 3 kinds (see check_gte_pipeline_fill). Only the mac_yield rule branches on kind.
	local tokens       = atom.paths.tokens
	local line_in_body = atom.paths.line_in_body
	local tc           = atom.paths.tok_class
	local n            = #tokens

	local count    = 0
	local last_idx = 0
	for tok_idx = 1, n do
		if tc[tok_idx].is_yield then
			count    = count + 1
			last_idx = tok_idx
		end
	end
	local function line_for(idx)
		return atom.line + line_in_body[tokens[idx].rel]
	end

	if atom.kind == "atom" or atom.kind == "atom_proc" then
		-- Baked atom: exactly 1 yield at the end.
		if count == 0 then
			findings[#findings + 1] = {
				atom  = atom.name,
				line  = atom.line,
				check = "mac_yield_uniformity",
				kind  = "warning",
				msg   = string.format("%s at line %d has no `mac_yield()`; every atom must hand control to the next via mac_yield at end"
					, atom.name, atom.line),
			}
		elseif count > 1 then
			findings[#findings + 1] = {
				atom  = atom.name,
				line  = line_for(last_idx),
				check = "mac_yield_uniformity",
				kind  = "warning",
				msg   = string.format("%s at line %d has %d `mac_yield()` calls; exactly 1 is allowed", atom.name, line_for(last_idx), count),
			}
		elseif last_idx < n then
			-- 1 call, but not the last token. We DON'T fail if the post-token is just `nop` or `nop2` or a branch with `, nop` delay slot.
			-- It's the standard "yield, then BD nop" idiom.
			local post_non_nop = false
			for search_idx = last_idx + 1, n do
				if tc[search_idx].nop_words == 0 and tokens[search_idx].tok ~= "" then
					post_non_nop = true
					break
				end
			end
			if post_non_nop then
				findings[#findings + 1] = {
					atom  = atom.name,
					line  = line_for(last_idx),
					check = "mac_yield_uniformity",
					kind  = "warning",
					msg   = string.format("%s at line %d has `mac_yield()` at token %d/%d; the yield must be the LAST non-nop token in the body"
						, atom.name, line_for(last_idx), last_idx, #tokens),
				}
			end
		end
	else
		-- Component (comp_bare or comp_proc): ZERO yields.
		-- The parent atom does the yield.
		-- A yield inside a component would either be dead code (bare) or prematurely terminate the function (proc).
		-- Both are bugs.
		-- `atom_proc` atoms are NOT components; they're runtime-proc atoms that own their own yield (handled in the `if` branch above).
		if count > 0 then
			findings[#findings + 1] = {
				atom  = atom.name,
				line  = line_for(last_idx),
				check = "mac_yield_uniformity",
				kind  = "warning",
				msg   = string.format("%s at line %d is a %s component but has %d `mac_yield()` call(s); components must not yield (the parent atom does)"
					, atom.name, line_for(last_idx), atom.kind, count),
			}
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Check #3: mac_yield_load / mac_yield_tail pairing (the lego split)
-- ════════════════════════════════════════════════════════════════════════════

--- The lego split — `mac_yield_load()` in a branch BD-slot + `mac_yield_tail()` at the branch's target
--- label — must be used as a pair. Otherwise `R_AtomJmp` is not loaded for the tail's `jr R_AtomJmp`,
--- and the tape runtime would jump to garbage.
---
--- Rules:
---   1. Every `mac_yield_load()` must be in a branch BD-slot (the immediately preceding token must be a branch).
---   2. Every `mac_yield_tail()` must be the first instruction after an `atom_label()`, AND
---      at least one branch targeting that label must have `mac_yield_load()` in its BD-slot.
---   3. `mac_yield_tail()` as the atom-end terminator (last token) is a WARNING, not an error
---      (the safe default for atom-endings is `mac_yield()` which re-loads `R_AtomJmp`).
---
--- Per-atom. Runtime-helper atoms (`debug_skip`) are exempt.
--- Takes `(atom, pipe_ctx, findings)`; `pipe_ctx` is unused.
local function check_yield_load_tail_pairing(atom, _pipe_ctx, findings)
	if atom.kind ~= "atom" and atom.kind ~= "atom_proc" then return end
	if is_runtime_helper(atom) then return end

	local tokens       = atom.paths.tokens
	local line_in_body = atom.paths.line_in_body
	local tc           = atom.paths.tok_class
	local n            = #tokens

	local function line_for(idx)
		return atom.line + line_in_body[tokens[idx].rel]
	end

	-- ── Rule 1: every `mac_yield_load()` must be in a branch BD-slot, OR sit between two `atom_label`s (natural fall-through load pattern).
	-- When the pattern is satisfied, the check stays silent; only violations emit findings.
	for tok_idx = 1, n do
		local c = tc[tok_idx]
		if c.ident == "mac_yield_load" then
			local prev_tc = (tok_idx >= 2) and tc[tok_idx - 1] or nil
			-- Look for the next `atom_label()` token (skip `atom_offset` markers; check immediately-adjacent first).
			local next_label_tc = (tok_idx + 1 <= n) and tc[tok_idx + 1] or nil
			if    next_label_tc and next_label_tc.ident ~= "atom_label" then
				next_label_tc = nil
				for j = tok_idx + 1, n do
					local t = tc[j]
					if t.ident == "atom_label" then
						next_label_tc = t
						break
					end
				end
			end
			local  natural_fallthrough = prev_tc and prev_tc.is_atom_label and next_label_tc ~= nil
			if not natural_fallthrough then
				if tok_idx < 2 or not prev_tc.is_branch then
					local prev_ident = prev_tc and (prev_tc.ident or "?") or "<none>"
					local next_ident = next_label_tc and (next_label_tc.ident .. "(" .. (next_label_tc.label_name or "?") .. ")") or "<no following label>"
					findings[#findings + 1] = {
						atom  = atom.name,
						line  = tok_idx >= 2 and line_for(tok_idx) or atom.line,
						check = "yield_load_tail_pairing",
						kind  = "error",
						msg   = string.format(
							"%s at line %d has `mac_yield_load()` at word %d but the previous token is `%s`, not a branch — and the next `atom_label()` token is `%s` — `mac_yield_load()` must fill a branch BD-slot or sit between two `atom_label`s for the natural fall-through load."
							, atom.name, tok_idx >= 2 and line_for(tok_idx) or atom.line, tok_idx, prev_ident, next_ident),
					}
				end
			end
		end
	end

	-- ── Rule 2: every `mac_yield_tail()` must be at a labeled target whose branch BD-slot is `mac_yield_load()`.
	for tok_idx = 1, n do
		local c = tc[tok_idx]
		if c.ident ~= "mac_yield_tail" then goto continue end

		-- The immediately preceding token must be an `atom_label()` (no instructions between them).
		local prev_idx = tok_idx - 1
		if prev_idx < 1 or not tc[prev_idx].is_atom_label then
			if tok_idx == n then
				-- Atom-ending case: last token is `mac_yield_tail()` without a preceding label. WARNING.
				findings[#findings + 1] = {
					atom  = atom.name,
					line  = line_for(tok_idx),
					check = "yield_load_tail_pairing",
					kind  = "warning",
					msg   = string.format(
						"%s at line %d has `mac_yield_tail()` as the atom-end terminator. The safe default for atom-endings is `mac_yield()` (which re-loads R_AtomJmp). The split is for BD-slot fill, not atom-endings."
						, atom.name, line_for(tok_idx)),
				}
			else
				findings[#findings + 1] = {
					atom  = atom.name,
					line  = line_for(tok_idx),
					check = "yield_load_tail_pairing",
					kind  = "error",
					msg   = string.format(
						"%s at line %d has `mac_yield_tail()` at word %d but it's not the first instruction after an `atom_label()` — `mac_yield_tail()` must be the first token of its target label's body."
						, atom.name, line_for(tok_idx), tok_idx),
				}
			end
			goto continue
		end

		local label_name = tc[prev_idx].label_name
		-- Find at least one branch targeting `label_name` whose BD-slot is `mac_yield_load()`.
		local found_pairing = false
		for branch_idx = 1, n do
			local bt = tc[branch_idx]
			if bt.is_branch and bt.branch_label == label_name then
				local bd_idx   = branch_idx + 1
				local bd_tc   = bd_idx <= n and tc[bd_idx] or nil
				if bd_tc and bd_tc.ident == "mac_yield_load" then
					found_pairing = true
				else
					findings[#findings + 1] = {
						atom  = atom.name,
						line  = line_for(branch_idx),
						check = "yield_load_tail_pairing",
						kind  = "error",
						msg   = string.format(
							"%s at line %d has `mac_yield_tail()` at label `%s` (word %d) but the branch targeting it (at word %d) has BD-slot `%s` instead of `mac_yield_load()`."
							, atom.name, line_for(branch_idx), label_name, tok_idx, branch_idx, bd_tc and bd_tc.ident or "?"),
					}
				end
			end
		end
		if not found_pairing then
			findings[#findings + 1] = {
				atom  = atom.name,
				line  = line_for(tok_idx),
				check = "yield_load_tail_pairing",
				kind  = "error",
				msg   = string.format(
					"%s at line %d has `mac_yield_tail()` at label `%s` but no branch in the body targets this label with `mac_yield_load()` in its BD-slot — R_AtomJmp would not be loaded."
					, atom.name, line_for(tok_idx), label_name),
			}
		end
		::continue::
	end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Check #4: Binding handoff discipline
-- ════════════════════════════════════════════════════════════════════════════

--- For every atom with `atom_bind(Binds_X)`, verify the atom body reads every field of `Binds_X` from R_TapePtr (in any order) 
--- and advances R_TapePtr by S_(Binds_X) at the end. Mismatches are errors.
---
--- Binds_X is the atom phase's input payload (like a C function's argument struct).
--- The body must read each input field and advance the input cursor past the payload. The order of reads doesn't matter.
--- Each field is at a different offset in the struct, and the advance at the end is what keeps the tape pointer in sync.
---
--- Rules:
---   1. Body MUST contain one `load_word(R_*, R_TapePtr, O_(Binds_X, field))` per field of Binds_X. Missing field = error.
---   2. Body MUST contain an `add_ui_self(R_TapePtr, S_(Binds_X))` (or equivalent advance by the struct's byte count). Missing = error.
---   3. atom_bind(Binds_X) where Binds_X doesn't exist = error.
--- Per-atom: Verify the atom body reads every field of its `Binds_X` from R_TapePtr and advances R_TapePtr by S_(Binds_X).
--- Takes `(atom, pipe_ctx, findings)`; `pipe_ctx` carries the cross-atom `info_by_atom` + `binds_index` tables
--- (built once by validate() before the per-atom loop).
--- `validate()` owns per-atom iteration; this function evaluates one atom.
local function check_abi_handoff(atom, pipe_ctx, findings)
	local  info = pipe_ctx.info_by_atom[atom.name]
	if not info or not info.binds then return end
	local binds_name = info.binds
	local binds      = pipe_ctx.binds_index[binds_name]
	if not binds then
		findings[#findings + 1] = {
			atom  = atom.name, line = atom.line,
			check = "abi_handoff", kind = "error",
			msg   = string.format("%s at line %d has `atom_bind(%s)` but no `typedef Struct_(%s)` declaration found in source"
				, atom.name, atom.line, binds_name, binds_name),
		}
		return
	end
	local tokens         = atom.paths.tokens
	local line_in_body   = atom.paths.line_in_body
	local tc             = atom.paths.tok_class
	local found_field_set = {}
	local found_advance   = false

	-- Reads from tc_entry fields pre-computed by classify_tokens (R3 lift). 
	-- Eliminates 3 per-token string-find/match calls (R_TapePtr + O_(binds_name,...) + bind_re) → 3 O(1) field reads.
	for tok_idx = 1, #tokens do
		local tc_entry = tc[tok_idx]
		-- scan: load_word(R_*, R_TapePtr, O_(<Binds_X>, <field>))
		if tc_entry.is_load and tc_entry.reads_r_tape_ptr and tc_entry.o_arg1 == binds_name then
			local field = tc_entry.o_arg2
			if field then
				found_field_set[field] = true
			else
				local body_line = atom.line + line_in_body[tokens[tok_idx].rel]
				findings[#findings + 1] = {
					atom  = atom.name, line = body_line,
					check = "abi_handoff", kind = "error",
					msg   = string.format("%s at line %d has load_word(R_TapePtr, O_(%s, <non-ident>)); expected O_(%s, <field>)",
						atom.name, body_line, binds_name, binds_name),
				}
			end
		end
		-- scan: add_ui_self(R_TapePtr, S_(<Binds_X>))
		if tc_entry.reads_r_tape_ptr and tc_entry.s_arg1 == binds_name then
			found_advance = true
		end
	end

	for _, f in ipairs(binds.fields) do
		if not found_field_set[f.name] then
			findings[#findings + 1] = {
				atom  = atom.name, line = atom.line,
				check = "abi_handoff", kind = "error",
				msg   = string.format("%s at line %d binds %s but never loads field `%s` from R_TapePtr (expected O_(%s, %s))"
					, atom.name, atom.line, binds_name, f.name, binds_name, f.name),
			}
		end
	end

	if not found_advance then
		findings[#findings + 1] = {
			atom  = atom.name, line = atom.line,
			check = "abi_handoff", kind = "error",
			msg   = string.format("%s at line %d binds %s but never advances R_TapePtr by S_(%s) (= %d bytes / %d words)"
				, atom.name, atom.line, binds_name, binds_name, binds.bytes, binds.bytes / 0x04),
		}
	end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Check #4: GPU port-store shape
-- ════════════════════════════════════════════════════════════════════════════

--- For every baked atom body, detect which GP0 primitive it's emitting
--- (first `mac_format_<shape>_color` call). Sum contributions from `mac_format_X_color` + `mac_gte_store_X_post_*` + `mac_insert_ot_tag_X`.
--- Compare to duffle.GP0_CMD_SIZE[cmd_byte]. Mismatch = error.
---
--- Soft behavior (warnings):
---   - Atoms emitting a primitive via raw `store_word(R_PrimCursor, ...)` (no `mac_format_X_color` call) emit a "manual packet assembly" advisory.
---     Cannot auto-validate.
---   - Atoms containing a `mac_<name>(...)` call whose `name` is not registered in `pipe_ctx.components_by_name` emit a "new macro;
---     Not in corpus.components" advisory — the auto-derivation returned nil for that name.
---
--- Applies only to `kind = "atom"` or `kind = "atom_proc"` (full-atom bodies). Components don't emit full primitives.
local function check_gpu_portstore_shape(atom, pipe_ctx, findings)
	if atom.kind ~= "atom" and atom.kind ~= "atom_proc" then return end
	local tokens         = atom.paths.tokens
	local line_in_body   = atom.paths.line_in_body
	local tc             = atom.paths.tok_class
	local cmd_byte       = nil
	local cmd_line       = nil
	local contrib        = 0
	local saw_format     = false
	local saw_prim_write = false

	-- Reads from tc_entry fields pre-computed by classify_tokens (R3 lift).
	-- Eliminates 4 per-token string matches (mac_format_X_color + mac_gte_store_<shape> + mac_insert_ot_tag_<shape> + R_PrimCursor)
	for tok_idx = 1, #tokens do
		local tc_entry = tc[tok_idx]
		local shape    = tc_entry.mac_format_shape
		if shape and duffle.GP0_CMD_BY_SHAPE[shape] then
			if not cmd_byte then
				cmd_byte = duffle.GP0_CMD_BY_SHAPE[shape]
				cmd_line = atom.line + line_in_body[tokens[tok_idx].rel]
			end
			saw_format = true
			-- gp0_contrib is auto-derived from the original `MipsAtomComp_(ac_format_<shape>_color) { body }` body
			-- in `passes/components.lua::compute_components_metadata` and stored on `corpus.components`.
			local comp = pipe_ctx.components_by_name["format_" .. shape .. "_color"]
			local n    = comp and comp.gp0_contrib
			if    n then contrib = contrib + n end
		end
		if tc_entry.is_gte_store then
			-- `tc_entry.ident` is the macro-variant form (`mac_gte_store_f3`); strip the `mac_` prefix for the bare-name corpus lookup.
			local bare    = tc_entry.ident:sub(#"mac_" + 1)
			local comp    = pipe_ctx.components_by_name[bare]
			local n       = comp and comp.gp0_contrib
			if    n then contrib = contrib + n end
		end
		if tc_entry.is_ot_tag then
			local bare    = tc_entry.ident:sub(#"mac_" + 1)
			local comp    = pipe_ctx.components_by_name[bare]
			local n       = comp and comp.gp0_contrib
			if    n then contrib = contrib + n end
		end
		if tc_entry.writes_r_prim_cursor then
			saw_prim_write = true
		end
	end

	if not cmd_byte then
		if saw_prim_write and not saw_format then
			findings[#findings + 1] = {
				atom  = atom.name, line = atom.line,
				check = "gpu_portstore_shape", kind = "warning",
				msg   = string.format("%s at line %d writes to R_PrimCursor via raw store_word(...)"
					.. " but uses no `mac_format_*_color`; the cmd byte + word count cannot be auto-validated."
					.. " Consider migrating to `mac_format_X_color` + `mac_gte_store_X_post_*` + `mac_insert_ot_tag_X`."
					, atom.name, atom.line),
			}
		end
	else
		local expected = duffle.GP0_CMD_SIZE[cmd_byte]
		if contrib ~= expected then
			findings[#findings + 1] = {
				atom  = atom.name, line = cmd_line or atom.line,
				check = "gpu_portstore_shape", kind = "error",
				msg   = string.format("%s at line %d emits GP0 0x%02X with %d prim word(s); expected %d (cmd 0x%02X total = %d)"
					, atom.name, cmd_line or atom.line, cmd_byte, contrib, expected, cmd_byte, expected),
			}
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Check #5: per-atom cycle budget (uses analyze_atom_paths's unknown_macros)
-- ════════════════════════════════════════════════════════════════════════════

--- Walk all paths through an atom body and return per-path cycle sums.
--- Builds a tiny CFG: each token has a "next" pointer. Three control-transfer kinds are recognized (set by `classify_tokens`):
---   * `branch_*` (conditional): 2 successors — fall-through (BD slot absorbed) + taken (if `atom_offset` target known).
---   * `jump` / `call_addr` (unconditional absolute): 1 successor — taken only (BD slot absorbed into the cost).
---   * `jump_reg` / `call_reg` / `jump_link` (register-form): terminator — transfers control OUT of the current atom (e.g. `mac_yield()` ends in `jump_reg(R_AtomJmp), nop`).
---
--- The BD-slot nop after ANY of these (conditional branch, unconditional jump, terminal jump) is absorbed into the control-transfer's cost
--- (MIPS-accurate: the BD slot always runs) and is SKIPPED in the successor list (otherwise we'd double-count it).
---
--- Returns:
---   cycles_min     - shortest path through the body (sum of token costs)
---   cycles_max     - longest path through the body
---   branches       - number of branches in the body (conditional + unconditional-with-offset)
---   paths          - number of distinct paths reached (terminated at mac_yield / terminal_jump / end-of-body)
---   has_loops      - true iff a path re-entered a token it had visited (warning; loop bodies aren't supported)
---   unknown_macros - list of unique ident names with no cost lookup: non-`mac_*` idents not in `duffle.INSTRUCTION_LATENCY`,
---                    plus `mac_*` idents whose bare name is missing from `pipe_ctx.components_by_name` (i.e. no `MipsAtomComp_` for it).
local function analyze_atom_paths(atom, pipe_ctx)
	local tokens = atom.paths.tokens or duffle.tokenize_body(atom.body)
	local tc     = atom.paths.tok_class or classify_tokens(tokens)
	local n      = #tokens

	-- Build label + branch maps from the pre-computed classification (no re-scan).
	-- `branches` keys both `branch_*` (conditional) and `jump`/`call_addr` (unconditional absolute);
	-- The latter resolve via `tc[tok_idx].branch_label` the same way (the offsets pass produces a valid relative offset for both).
	local labels   = {}
	local branches = {}
	for tok_idx = 1, n do
		local c = tc[tok_idx]
		if c.is_atom_label and c.label_name then
			labels[c.label_name] = tok_idx
		end
		if c.is_branch then
			branches[tok_idx] = c.branch_label
		end
	end

	-- Pre-compute per-token cycle costs from the pre-computed ident (no re-match).
	-- For non-`mac_*` tokens: lookup `duffle.INSTRUCTION_LATENCY[c.ident]` directly.
	-- For `mac_*` tokens: lookup `pipe_ctx.components_by_name[bare_name].cycle_cost`, which `passes/components.lua::compute_components_metadata` derived from the originals
	-- `MipsAtomComp_(ac_X) { body }` definition (sum of `INSTRUCTION_LATENCY` per emitted instruction,
	-- recursing through nested `mac_*` calls). `mac_yield` is special-cased to 0 by `compute_components_metadata` (the runtime cost lands in the next atom's prologue).
	local costs       = {}
	local unknown_set = {}
	for tok_idx = 1, n do
		local c      = tc[tok_idx]
		local ident  = c.ident
		local cost
		if ident:sub(1, #"mac_") == "mac_" then
			-- `mac_*` token: lookup corpus.components[bare_name].cycle_cost.
			local bare = ident:sub(#"mac_" + 1)
			local comp = pipe_ctx.components_by_name and pipe_ctx.components_by_name[bare]
			if comp and comp.cycle_cost ~= nil then
				cost = comp.cycle_cost
			else
				cost = duffle.UNKNOWN_INSTRUCTION_CYCLES
				unknown_set[ident] = true
			end
		else
			cost = duffle.INSTRUCTION_LATENCY[ident]
			if cost == nil then
				cost = duffle.UNKNOWN_INSTRUCTION_CYCLES
				unknown_set[ident] = true
			end
		end
		costs[tok_idx] = cost
	end

	-- Three control-transfer predicates (set by `classify_tokens`):
	--   is_terminator — path ends here (`mac_yield` or register-form jump); empty successors.
	--   is_branch — has an immediate offset (`branch_*`, `jump`, `call_addr`); 1-2 successors depending on unconditional_jump.
	--   is_unconditional_jump — when is_branch is also true: skip fall-through (target only).
	local function is_terminator(tok_idx)
		local c = tc[tok_idx]
		return c.is_yield or c.is_terminal_jump
	end
	local function is_branch(tok_idx) return tc[tok_idx].is_branch end
	local function is_unconditional_jump(tok_idx) return tc[tok_idx].is_unconditional_jump end
	local function successors(tok_idx)
		local tok = tokens[tok_idx].tok
		if is_terminator(tok_idx) then
			return {}, tok_idx  -- empty list; term = tok_idx signals "path ends here"
		end
		if is_branch(tok_idx) then
			local label = branches[tok_idx]  -- may be false for literal-offset branches
			local succ  = {}
			if is_unconditional_jump(tok_idx) then
				-- Unconditional absolute jump / call: BD slot absorbed; single successor — the taken path.
				-- The instruction word after the BD slot is unreachable in this atom's execution.
				if label then
					local label_pos = labels[label]
					if label_pos and label_pos + 1 <= n then
						succ[#succ + 1] = label_pos + 1
					end
				end
				-- For literal-offset jumps (label == false), control transfers out unconditionally.
				-- Treat as a terminator so the path is recorded (NOT as a silent fall-through to the next token, which is unreachable in this atom's execution).
				return {}, tok_idx
			end
			-- Conditional branch: BD slot absorbed; two successors — fall-through (tok_idx+2) + taken (if known).
			if tok_idx + 2 <= n then
				succ[#succ + 1] = tok_idx + 2
			end
			if label then
				local label_pos = labels[label]
				if label_pos and label_pos + 1 <= n then
					succ[#succ + 1] = label_pos + 1
				end
			end
			-- For literal-offset branches (label == false), the taken path would jump to a non-tracked address; conservatively omit.
			-- Return (succ, nil), the second value is the terminator marker (nil = not a terminator).
			return succ, nil
		end
		-- Normal token: just the next one.
		-- The final ordinary word of the body has no successor and terminates the path;
		-- record it as an implicit endpoint so the cycle budget for non-yield components is not silently zeroed.
		if tok_idx + 1 <= n then return { tok_idx + 1 }, nil end
		return {}, tok_idx
	end

	-- DFS through all paths. Track the current cycle sum, a visited set scoped to the current path (to detect loops), and a count of paths.
	-- Cap recursion at MAX_PATHS to prevent runaway exploration on pathological bodies.
	local MAX_PATHS  = 64
	local cycles_min = math.huge
	local cycles_max = -1
	local path_count = 0
	local has_loops  = false
	local function dfs(tok_idx, acc, visited)
		if path_count >= MAX_PATHS then return end
		if _G._DEBUG_DFS then
			io.stderr:write(string.format("dfs(tok_idx=%d, acc=%d)\n", tok_idx, acc))
		end
		if visited[tok_idx] then
			has_loops = true
			if _G._DEBUG_DFS_LOOP then
				io.stderr:write(string.format("  -> LOOP at tok_idx=%d (tok=%s) acc=%d\n", tok_idx, tokens[tok_idx].tok, acc))
			end
			return
		end

		-- Add this token's cost. For ANY control-transfer (conditional branch, unconditional jump, terminal jump),
		-- ADD the BD-slot cost too — MIPS-accurate: the BD slot always runs. Skip the BD slot in the successor list (already done in `successors` above;
		-- for the taken path the BD slot was at tok_idx+1 which is now skipped entirely).
		local cost = costs[tok_idx]
		if (is_branch(tok_idx) or is_terminator(tok_idx)) and tok_idx + 1 <= n then
			cost = cost + costs[tok_idx + 1]
		end
		local new_acc = acc + cost

		local succ, term = successors(tok_idx)
		if term then
			-- Terminator: record the path's cycle sum.
			-- The terminator token stays out of `visited`, so another path reaching the same terminator remains a distinct path.
			-- Marking it visited would flag those legitimate paths as loops.
			path_count = path_count + 1
			if new_acc < cycles_min then cycles_min = new_acc end
			if new_acc > cycles_max then cycles_max = new_acc end
			return
		end
		visited[tok_idx] = true
		for _, next_tok_idx in ipairs(succ) do
			dfs(next_tok_idx, new_acc, visited)
		end
		visited[tok_idx] = nil
	end
	if n >= 1 then dfs(1, 0, {}) end

	-- If no paths were recorded (e.g. atom body is empty), cycles_min/max default to 0 (atom costs nothing).
	if cycles_min == math.huge then cycles_min = 0 end
	if cycles_max == -1        then cycles_max = 0 end

	local unknown_list = {}
	for macro_name in pairs(unknown_set) do unknown_list[#unknown_list + 1] = macro_name end
	table.sort(unknown_list)

	-- branch_count: number of control-transfer tokens with an immediate offset (`branch_*` + `jump` + `call_addr`).
	local branch_count = 0
	for _ in pairs(branches) do branch_count = branch_count + 1 end

	-- Mutate the pre-allocated `atom.paths` slot in place (caller owns the table).
	-- Mega-struct move: a single source of truth for all per-atom path-analysis data,
	-- instead of returning a fresh table that would just get copied onto 5 atom fields.
	local p = atom.paths or {}
	p.cycles_min     = cycles_min
	p.cycles_max     = cycles_max
	p.branches       = branch_count
	p.paths          = path_count
	p.has_loops      = has_loops
	p.unknown_macros = unknown_list
	atom.paths       = p
end

--- Per-source check that emits one finding per unknown macro seen
--- (deduplicated across atoms so the warning section doesn't get spammed with N copies of the same diagnostic).
--- Per-atom: emit one finding per unknown macro seen, deduplicated across atoms
--- (so the warning section doesn't get spammed with N copies of the same diagnostic).
--- Reuses `analyze_atom_paths`'s per-atom unknown_macros discovery, which walks tokens and computes per-token cycle costs.
local function check_per_atom_cycle_budget(atom, pipe_ctx, findings)
	local p = atom.paths or {}
	for _, name in ipairs(p.unknown_macros or {}) do
		if not pipe_ctx.unknown_seen[name] then
			pipe_ctx.unknown_seen[name] = atom.line
			findings[#findings + 1] = {
				atom  = atom.name, line = atom.line,
				check = "per_atom_cycle_budget", kind = "warning",
				msg   = string.format("%s at line %d uses macro `%s` with no cycle_cost lookup; "
					.. "cycle count will be +%d per call (best-case). For `mac_*` idents, ensure the "
					.. "corresponding `MipsAtomComp_(ac_X)` is in scope of the build so "
					.. "`passes/components.lua::compute_components_metadata` can derive its cost; "
					.. "for non-`mac_*` idents, add an entry to `duffle.INSTRUCTION_LATENCY`."
					, atom.name, atom.line, name, duffle.UNKNOWN_INSTRUCTION_CYCLES),
			}
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Check #6: enum_alias_membership
-- ════════════════════════════════════════════════════════════════════════════

-- Every R_X referenced from a debug-visible surface — atom_dbg_reg_default, atom_reg_types, atom_type sub-entries, atom_reads, atom_writes;
-- MUST be present in `pipe_ctx.register_alias_registry`.
-- The registry is the source-derived answer to "is this R_X a real, opt-in alias?"
-- (populated by scan_source's `parse_enum_aliases` from `enum { R_X = N atom_reg }` declarations).
-- Per-source rule (called once per source via the CHECK_RULES dispatch).
-- Signature matches the per_source shape established by check_semantic_reg_defaults.
--
-- Severity: WARNING (build continues).
-- The rule is intentionally permissive because the production `code/duffle/` and `code/gte_hello/`
-- sources use R_* aliases in atom_reads / atom_writes that may not yet be opted in via the bare `atom_reg` marker.
-- R_TapePtr / R_AtomJmp / R_PrimCursor / R_FaceCursor / R_VertBase / R_OtBase ARE opted in.
-- Raw C-ABI aliases like R_T0..R_T3 require explicit opt-in; the prototype keeps wave-context registration explicit.
-- no auto-include of wave-context; explicit opt-in only). 
-- Warnings keep the build green and report aliases that need explicit registration.
local function check_enum_alias_membership(_src, pipe_ctx, findings)
	local reg_registry = pipe_ctx.register_alias_registry or {}

	-- (a) atom_dbg_reg_default(R_X, T) -- pipe_ctx.types.
	--     source_line is on every entry; emit the diagnostic against the default declaration's own line so the report's 
	--     "Findings by atom" section can attribute the failure to the marker location.
	for reg, def in pairs(pipe_ctx.types or {}) do
		if not reg_registry[reg] then
			findings[#findings + 1] = {
				atom  = "", line = def.source_line or 0,
				check = "enum_alias_membership", kind = "warning",
				msg   = string.format("atom_dbg_reg_default at line %d references unknown register %q (not in register_alias_registry)"
					, def.source_line or 0, reg),
			}
		end
	end

	-- (b) atom_reg_types(R_X, T) + (c) atom_type(R_X, T) sub-entries both populate `ai.reg_type_overrides`.
	--     (d) atom_reads(R_X) + (e) atom_writes(R_X) populate the reads/writes arrays.
	--     All four are checked against the same registry; the per-rule dispatch iterates `ai` once and covers all three locations
	--     so we don't re-walk atom_infos for each sub-check.
	for _, ai in ipairs(pipe_ctx.atom_infos_list or {}) do
		local info_line = ai.info_line or 0
		local atom_name = ai.atom_name or ""
		if ai.reg_type_overrides then
			for reg in pairs(ai.reg_type_overrides) do
				if not reg_registry[reg] then
					findings[#findings + 1] = {
						atom  = atom_name, line = info_line,
						check = "enum_alias_membership", kind = "warning",
						msg   = string.format("atom '%s' at line %d has reg_type_overrides for %q; the alias is not in register_alias_registry"
							, atom_name, info_line, reg),
					}
				end
			end
		end
		for _, reg in ipairs(ai.reads or {}) do
			if not reg_registry[reg] then
				findings[#findings + 1] = {
					atom  = atom_name, line = info_line,
					check = "enum_alias_membership", kind = "warning",
					msg   = string.format("atom '%s' at line %d has atom_reads for %q; the alias is not in register_alias_registry"
						, atom_name, info_line, reg),
				}
			end
		end
		for _, reg in ipairs(ai.writes or {}) do
			if not reg_registry[reg] then
				findings[#findings + 1] = {
					atom  = atom_name, line = info_line,
					check = "enum_alias_membership", kind = "warning",
					msg   = string.format("atom '%s' at line %d has atom_writes for %q; the alias is not in register_alias_registry"
						, atom_name, info_line, reg),
				}
			end
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Check #7: atom_type_consistency
-- ════════════════════════════════════════════════════════════════════════════

-- Every `reg_type_overrides[R_X].type_name` (populated by BOTH `atom_reg_types(R_X, <type>)`
-- and `atom_type(R_X, <type>)` sub-entries inside atom_reads/atom_writes) MUST resolve to a `type_name_registry` entry.
-- The registry is the source-derived answer to "is this type name declared in this translation unit?"
-- (populated by `typedef Struct_(...)`, `typedef Enum_(...)`, `typedef ... TSet_(...)` declarations).
-- Missing type names are errors (the build stops) so the user adds the typedef before re-running.
-- Per-source rule.
local function check_atom_type_consistency(_src, pipe_ctx, findings)
	local type_registry = pipe_ctx.type_name_registry or {}
	for _, ai in ipairs(pipe_ctx.atom_infos_list or {}) do
		local info_line = ai.info_line or 0
		local atom_name = ai.atom_name or ""
		if ai.reg_type_overrides then
			for reg, ov in pairs(ai.reg_type_overrides) do
				if not ov.type_name or not type_registry[ov.type_name] then
					findings[#findings + 1] = {
						atom  = atom_name, line = info_line,
						check = "atom_type_consistency", kind = "error",
						msg   = string.format("atom '%s' at line %d reg_type_overrides[%q] uses unknown type %q (not in type_name_registry)"
							, atom_name, info_line, reg, tostring(ov.type_name)),
					}
				end
			end
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Check #8: binds_no_substruct_deref
-- ════════════════════════════════════════════════════════════════════════════

-- For every `load_word(R_A, R_B, O_(<Type>, <Field>))` and matching `store_word(...)` call in every atom body,
-- the `<Field>` MUST resolve to a leaf scalar of `<Type>`. A "leaf scalar" is:
--   * a non-struct field with `pointer_depth >= 1` (pointer-to-struct IS a leaf — the field is a pointer; the pointee is unrelated), OR
--   * a non-struct field whose type_name resolves to a typedef / enum / builtin in `type_name_registry`.
-- A nested struct member (pointer_depth == 0 and type_name resolves to a `kind = "struct"` registry entry) fails the leaf-scalar test.
-- The check also flags fields whose Type has no `fields` table (typedefs and enums don't have fields — any Field reference against them is bogus)
-- and fields whose name doesn't appear in the resolved Type's fields array.
--
-- Walks every atom's pre-computed `paths.tok_class`
-- (set by `classify_tokens` once per atom in validate()) and uses the `o_arg1` / `o_arg2` captures instead of re-matching the token string.
-- Resolution consults `pipe_ctx.type_name_registry`
-- (Binds_* structs are registered there by scan_source's `register_struct_type`, so a unified lookup works for both Binds_* and non-Binds structs).
--
-- Severity: warning (build continues) — this catches a category of bugs
-- (passing a struct by value through the tape payload) where the symptom is runtime corruption, not a compile error.
-- Look up a field by name in a type's `fields` array. Returns the matching field entry, or nil if not found.
-- Helper extracted to keep the caller's nesting depth <= 5 (project convention; this is the 5th nesting level:
--   function -> for-atom -> for-token -> if-load/store -> if-type-resolves).
local function find_field_by_name(type_entry, field_name)
	for _, f in ipairs(type_entry.fields or {}) do
		if f.name == field_name then return f end
	end
	return nil
end

-- True iff a (field, type_registry) pair is a leaf scalar (safe to dereference as a tape-payload field).
-- Pointer-to-X is always a leaf; non-pointer struct members fail the leaf test.
local function is_field_leaf(field, type_registry)
	if field.pointer_depth and field.pointer_depth > 0 then
		return true
	end
	local ftype_entry = type_registry[field.type_name]
	if ftype_entry and ftype_entry.kind == "struct" then
		return false
	end
	return true
end

local function check_binds_no_substruct_deref(_src, pipe_ctx, findings)
	local type_registry = pipe_ctx.type_name_registry or {}
	for _, a in ipairs(pipe_ctx.atoms or {}) do
		local tc           = a.paths and a.paths.tok_class or {}
		local tokens       = a.paths and a.paths.tokens or {}
		local line_in_body = a.paths and a.paths.line_in_body or {}
		for ti = 1, #tokens do
			local tc_entry = tc[ti]
			if (tc_entry.is_load or tc_entry.is_store_word)
				and tc_entry.o_arg1 and tc_entry.o_arg2 then
				local type_name  = tc_entry.o_arg1
				local field_name = tc_entry.o_arg2
				local body_line  = a.line + (line_in_body[tokens[ti].rel] or 0)

				local type_entry = type_registry[type_name]
				if not type_entry or not type_entry.fields then
					findings[#findings + 1] = {
						atom  = a.name, line = body_line,
						check = "binds_no_substruct_deref", kind = "warning",
						msg   = string.format("atom '%s' at line %d O_(%s, %s) refers to type %q which has no fields table in type_name_registry"
							, a.name, body_line, type_name, field_name, type_name),
					}
				else
					local field = find_field_by_name(type_entry, field_name)
					if not field then
						findings[#findings + 1] = {
							atom  = a.name, line = body_line,
							check = "binds_no_substruct_deref", kind = "warning",
							msg   = string.format("atom '%s' at line %d O_(%s, %s) does not resolve to a field of %s"
								, a.name, body_line, type_name, field_name, type_name),
						}
					elseif not is_field_leaf(field, type_registry) then
						findings[#findings + 1] = {
							atom  = a.name, line = body_line,
							check = "binds_no_substruct_deref", kind = "warning",
							msg   = string.format("atom '%s' at line %d O_(%s, %s) dereferences a non-pointer struct field of type %q; nested struct members are forbidden"
								, a.name, body_line, type_name, field_name, field.type_name),
						}
					end
				end
			end
		end
	end
end


-- ════════════════════════════════════════════════════════════════════════════
-- ════════════════════════════════════════════════════════════════════════════
-- GTE control-register alias + RT-diagonal + TR-naming helpers and checks
-- ════════════════════════════════════════════════════════════════════════════

--- Resolve a `gte_cr_<Alias>` ident to its alias-group entry, or nil if the alias
--- is in a distinct-slot group (or the alias name is not a known C2 control-register alias).
--- Reads `M.GTE_CR_ALIAS_GROUPS` from `duffle.lua`.
local function find_alias_pair_for(alias_name, duffle)
	local groups = (duffle and duffle.GTE_CR_ALIAS_GROUPS) or {}
	for _, group in ipairs(groups) do
		for _, name in ipairs(group[2] or {}) do
			if name == alias_name then return group end
		end
	end
	return nil
end

-- True iff `c` (a TokClass entry) is a CPU→COP2 control-register transfer
-- (`gte_mv_to_ctrl_r` / `gte_mv_from_ctrl_r`).
local function is_ctrl_r_transfer(c)
	if c == nil then return false end
	return c.ident == "gte_mv_to_ctrl_r" or c.ident == "gte_mv_from_ctrl_r"
end

-- Resolve a token's source line. The per-token `line` is the body-relative
-- line; `atom.line` is the source line of the atom declaration; `line_in_body`
-- (atom.paths) maps a body-relative line to its source line. The arithmetic
-- `atom.line + line_in_body[tok.rel] - 1` matches the convention used by
-- check_abi_handoff and check_control_transfer_delay_slot_use elsewhere.
local function atom_body_token_source_line(atom, token, line_in_body)
	if line_in_body == nil or token == nil or token.rel == nil then
		return atom.line or 0
	end
	local body_line = line_in_body[token.rel]
	if body_line == nil then return atom.line or 0 end
	return (atom.line or 0) + body_line - 1
end

-- Check #N: gte_cr_alias_writes
-- Fires one warning per atom per alias-group when the atom body touches two
-- distinct aliases from the same group. Aliases within a group write to the
-- same C2 control-register slot on real silicon; cross-alias writes inside
-- one atom body silently clobber each other.
--
-- Severity: warning. Build continues. The libgte outer-product convention
-- uses only RT-row aliases (which are NOT in `M.GTE_CR_ALIAS_GROUPS`), so
-- the canonical convention does not trigger this check.
local function check_gte_cr_alias_writes(atom, pipe_ctx, findings)
	local groups = pipe_ctx.gte_cr_alias_groups or {}
	if not next(groups) then return end

	local tokens = atom.paths and atom.paths.tokens or {}
	local tc     = atom.paths and atom.paths.tok_class or {}
	local line_in_body = atom.paths and atom.paths.line_in_body
	if not next(tokens) then return end

	-- Build a per-group set of (alias, source_line) pairs touched in this atom body.
	-- Walks every token; when the token is a ctrl-r transfer, the alias is at
	-- position tok_idx + 2 (rt, alias, [imm-or-arg]). The pre-classified
	-- `tc` table tells us whether the token is a ctrl-r transfer and what its
	-- source line is.
	local touched = {}
	for tok_idx, token in ipairs(tokens) do
		local c = tc[tok_idx]
		if is_ctrl_r_transfer(c) and tokens[tok_idx + 2] then
			local alias = tokens[tok_idx + 2].tok
			local group = find_alias_pair_for(alias, pipe_ctx.duffle)
			if group then
				touched[group[1]] = touched[group[1]] or {}
				touched[group[1]][#touched[group[1]] + 1] = {
					alias = alias,
					line  = atom_body_token_source_line(atom, token, line_in_body),
				}
			end
		end
	end

	-- Fire one warning per group touched with 2+ distinct aliases.
	for slot, hits in pairs(touched) do
		local seen = {}
		local distinct = {}
		for _, h in ipairs(hits) do
			if not seen[h.alias] then
				seen[h.alias] = true
				distinct[#distinct + 1] = h
			end
		end
		if #distinct >= 2 then
			local aliases = {}
			for _, d in ipairs(distinct) do aliases[#aliases + 1] = d.alias end
			findings[#findings + 1] = {
				atom  = atom.name or "",
				line  = distinct[1].line,
				check = "gte_cr_alias_writes",
				kind  = "warning",
				msg   = string.format(
					"atom '%s' touches %d aliases that share C2[%d]: %s; verify the intent"
					, atom.name or "", #distinct, slot, table.concat(aliases, ", ")),
			}
		end
	end
end

-- Check #N+1: rtdiagonal_completeness
-- Fires one info per atom body when the bare `gte_cmdw_mvmva` macro is used.
-- The bare macro encodes only the cmd field; the canonical libgte-2-pass
-- shape uses `gte_cmdw_mvmva_c11_pass2_exact = 0x4A49E012` (gte.h:430).
--
-- Severity: info by default. Escalates to warning when
-- `GTE_RT_DIAGONAL_STRICT=1` env var is set (CI / production builds).
--
-- The bare macro IS the right call for the canonical libgte outer-product
-- convention, so this is an opt-out hint rather than a hard warning.
local function check_rtdiagonal_completeness(atom, _pipe_ctx, findings)
	local tokens = atom.paths and atom.paths.tokens or {}
	local tc     = atom.paths and atom.paths.tok_class or {}
	local line_in_body = atom.paths and atom.paths.line_in_body
	if not next(tokens) then return end
	local strict = os.getenv("GTE_RT_DIAGONAL_STRICT") == "1"
	for tok_idx, token in ipairs(tokens) do
		local c = tc[tok_idx]
		if c and c.ident == "gte_cmdw_mvmva" then
			findings[#findings + 1] = {
				atom  = atom.name or "",
				line  = atom_body_token_source_line(atom, token, line_in_body),
				check = "rtdiagonal_completeness",
				kind  = strict and "warning" or "info",
				msg   = string.format(
					"atom '%s' uses the bare gte_cmdw_mvmva macro; "
					.. "the canonical libgte-2-pass shape is gte_cmdw_mvmva_c11_pass2_exact = 0x4A49E012 "
					.. "(gte.h:430). The bare macro does not encode RT23/RT31/RT32/RT33; "
					.. "for a full 3x3 matrix, use the dedicated literal or hand-build via enc_gte_*()."
					, atom.name or ""),
			}
		end
	end
end

-- Check #N+2: gte_cr_TR_naming
-- Fires one info per atom body when a `gte_cr_TR[XYZ]` alias is used.
-- Translation-vector registers are the only 3-letter-suffix C2 aliases
-- (`TRX/TRY/TRZ`); an agent who reads `TRX` might typo it as `RT_X` or
-- `RTX0` and either get a compile error (best case) or a build that
-- links but routes the `ctc2` write to the wrong C2 slot.
--
-- Severity: info. The convention is correct; this is a documentation-pointer check.
local function check_gte_cr_TR_naming(atom, _pipe_ctx, findings)
	local tokens = atom.paths and atom.paths.tokens or {}
	local tc     = atom.paths and atom.paths.tok_class or {}
	local line_in_body = atom.paths and atom.paths.line_in_body
	if not next(tokens) then return end
	local touched = false
	local first_line = 0
	for tok_idx, token in ipairs(tokens) do
		local c = tc[tok_idx]
		if c and c.ident and c.ident:match("^gte_cr_TR[XYZ]$") then
			touched = true
			if first_line == 0 then
				first_line = atom_body_token_source_line(atom, token, line_in_body)
			end
		end
	end
	if touched then
		findings[#findings + 1] = {
			atom  = atom.name or "",
			line  = first_line,
			check = "gte_cr_TR_naming",
			kind  = "info",
			msg   = string.format(
				"atom '%s' uses gte_cr_TR[XYZ]; translation-vector registers are the only "
				.. "3-letter-suffix C2 aliases (TRX/TRY/TRZ). See docs/gte_reference.md §"
				.. "\"The `gte_cmdw_mvmva_c11_pass2_exact` literal\" for the libgte outer-product "
				.. "convention that uses these names."
				, atom.name or ""),
		}
	end
end

-- check_immediate_field_width — flags integer literals passed to instruction
-- macros that exceed the immediate field width. Reads `IMMEDIATE_FIELD_WIDTHS`
-- from duffle.lua. Only fires on parseable integer literals; register names,
-- O_(...) offsets, atom_offset(...) markers, and enum tokens are skipped.
local function check_immediate_field_width(atom, pipe_ctx, findings)
	local widths = duffle.IMMEDIATE_FIELD_WIDTHS or {}
	local events = atom.paths and atom.paths.word_events or {}
	local line_for_word_event = pipe_ctx.line_for_word_event
	for _, ev in ipairs(events) do
		local ev_ident = ev.encoder or ev.ident or "?"
		local rules = widths[ev_ident]
		if rules then
			local ev_args = ev.args or {}
			local ev_line = line_for_word_event and line_for_word_event(ev) or atom.line
			for _, rule in ipairs(rules) do
				local arg_str = ev_args[rule.arg]
				if arg_str then
					local value = parse_integer_literal(arg_str)
					if value then
						local width = rule.width
						local is_signed = rule.signed == true
						-- parse_integer_literal returns a U4-wrapped value in [0, 2^32).
						-- For signed fields, re-interpret the high bit as the sign.
						local signed_value = value
						if is_signed and value >= 0x80000000 then
							signed_value = value - 0x100000000
						end
						local lo, hi
						if is_signed then
							lo = -(bit.lshift(1, width - 1))
							hi =  bit.lshift(1, width - 1) - 1
						else
							lo = 0
							hi = bit.lshift(1, width) - 1
						end
						-- For unsigned fields, a negative C literal (high bit set in U4)
						-- is valid if the low `width` bits fit — IMM_MASK truncates it.
						-- Flag as a warning (code smell), not an error.
						local check_value = is_signed and signed_value or value
						local field_max = bit.lshift(1, width) - 1
						local low_bits_fit = (value % (bit.lshift(1, width))) == value or (is_signed and signed_value >= lo and signed_value <= hi)
						if is_signed then
							if signed_value < lo or signed_value > hi then
								findings[#findings + 1] = {
									check = "immediate_field_width",
									kind  = "error",
									atom  = atom.name,
									line  = ev_line,
									msg   = string.format(
										"%s: immediate %d at arg %d overflows %d-bit %s field (valid %d..%d)",
										ev_ident, signed_value, rule.arg, width,
										"signed", lo, hi),
								}
							end
						else
							-- Unsigned field: check if the low `width` bits exceed the field.
							-- A negative C literal (U4 >= 0x80000000) whose low bits fit is
							-- valid but a code smell — warn, don't error.
							local low_bits = value % (bit.lshift(1, width))
							if value > field_max then
								if value >= 0x80000000 and low_bits <= field_max then
									findings[#findings + 1] = {
										check = "immediate_field_width",
										kind  = "warning",
										atom  = atom.name,
										line  = ev_line,
										msg   = string.format(
											"%s: negative immediate %d at arg %d on unsigned %d-bit field (truncated to %d by IMM_MASK)",
											ev_ident, signed_value, rule.arg, width, low_bits),
									}
								else
									findings[#findings + 1] = {
										check = "immediate_field_width",
										kind  = "error",
										atom  = atom.name,
										line  = ev_line,
										msg   = string.format(
											"%s: immediate %d at arg %d overflows %d-bit unsigned field (valid 0..%d)",
											ev_ident, value, rule.arg, width, field_max),
									}
								end
							end
						end
					end
				end
			end
		end
	end
end

-- CHECK_RULES — data-driven check dispatch (Muratori: data over control flow)
-- ════════════════════════════════════════════════════════════════════════════

-- Each rule is a table entry: { name, <dispatch> }.
-- Dispatch shapes:
--   per_atom(atom, pipe_ctx, findings)          — runs once per atom inside validate()'s single loop
--   post(pipe_ctx, findings)                    — runs once after all per-atom calls complete
--   per_macro(macro, wc, findings)              — runs once per TAPE_WORDS / _Pragma macro declaration
--   per_skip_marker(marker, pipe_ctx, findings) — runs once per src.scan.debug_skip_markers entry
--   per_source(src, pipe_ctx, findings)         — runs once per source AFTER the per-atom loop completes
--                                                 (registry-driven rule; same CHECK_RULES table)
-- Each check is one table row and one `check_*` function.
-- This is the plex pattern: the iteration is in ONE place (validate), the variation is in DATA (this table).

local CHECK_RULES = {
	{ name = "transfer_hazards",                per_atom   = check_transfer_hazards                },
	{ name = "gte_input_latch",                 per_atom   = check_gte_input_latch                 },
	{ name = "gte_role_mismatch",               per_atom   = check_gte_role_mismatch               },
	{ name = "hazard_nop_use",                  per_atom   = check_hazard_nop_use                  },
	{ name = "control_transfer_delay_slot_use", per_atom   = check_control_transfer_delay_slot_use },
	{ name = "load_delay_violation",            per_atom   = check_load_delay_slots                },
	{ name = "mac_yield_uniformity",            per_atom   = check_mac_yield_uniformity            },
	{ name = "yield_load_tail_pairing",         per_atom   = check_yield_load_tail_pairing         },
	{ name = "abi_handoff",                     per_atom   = check_abi_handoff                     },
	{ name = "gpu_portstore_shape",             per_atom   = check_gpu_portstore_shape             },
	{ name = "per_atom_cycle_budget",           per_atom   = check_per_atom_cycle_budget           },
	{ name = "gte_cr_alias_writes",             per_atom   = check_gte_cr_alias_writes             },
	{ name = "rtdiagonal_completeness",         per_atom   = check_rtdiagonal_completeness         },
	{ name = "gte_cr_TR_naming",                per_atom   = check_gte_cr_TR_naming                },
	{ name = "immediate_field_width",           per_atom   = check_immediate_field_width           },
	{ name = "enum_alias_membership",           per_source = check_enum_alias_membership           },
	{ name = "atom_type_consistency",           per_source = check_atom_type_consistency           },
	{ name = "binds_no_substruct_deref",        per_source = check_binds_no_substruct_deref        },
}

-- ════════════════════════════════════════════════════════════════════════════
-- Per-source validation
-- ════════════════════════════════════════════════════════════════════════════

--- Build the corpus-wide pipe_ctx ONCE per pass run.
--- Reads the merged `corpus.*` registries and the corpus-wide `atom_infos` list (preserving source order + duplicates).
--- The corpus supplies shared registries; `src.scan` and per-source projections retain body and declaration ownership.
---
--- A context without `ctx.shared.corpus` is rejected with an explicit corpus message.
--- Callers construct the context through `build_ctx`.
--- @param ctx PassCtx
--- @return PipeCtx
local function build_corpus_pipe_ctx(ctx)
	local corpus = ctx.shared and ctx.shared.corpus
	if not corpus then
		error("static_analysis requires ctx.shared.corpus "
			.. "(the canonical corpus is the source of truth; "
			.. "no per-source fallback is supported)", 0)
	end
	-- The pipe_ctx views REFERENCE the corpus tables directly (no copies).
	-- Every consumer observes mutations through the corpus tables directly.
	return {
		-- Cross-source lookup tables.
		register_alias_registry = corpus.register_alias_registry or {},
		type_name_registry      = corpus.type_name_registry      or {},
		atom_views              = corpus.atom_views              or {},
		atom_ctxs               = corpus.atom_ctxs               or {},
		atom_phases             = corpus.atom_phases             or {},
		binds_by_name           = corpus.binds_by_name           or {},
		atoms_by_name           = corpus.atoms_by_name           or {},
		-- Per-component metadata (cycle_cost + gp0_contrib) auto-derived from the original
		-- `MipsAtomComp_` body by `passes/components.lua::compute_components_metadata`.
		-- Keyed by bare name (e.g. `format_f3_color`, `gte_store_f3`); the `mac_` prefix at call sites is stripped before lookup.
		components_by_name      = corpus.components              or {},
		-- Corpus-wide ordered list of atom_info records (source-order + duplicates).
		atom_infos_list         = corpus.atom_infos              or {},
		-- Corpus-wide collisions (recorded by scan_source.merge_corpus_registries).
		collisions              = corpus.collisions              or {},
		-- GTE control-register alias groups (from `duffle.GTE_CR_ALIAS_GROUPS`).
		-- The three new per_atom checks (gte_cr_alias_writes, rtdiagonal_completeness,
		-- gte_cr_TR_naming) read from this view. `duffle` is exposed alongside so
		-- `find_alias_pair_for` can resolve alias → group without a separate registry.
		gte_cr_alias_groups     = duffle.GTE_CR_ALIAS_GROUPS or {},
	}
end

local function validate(ctx, src, corpus_pipe_ctx)
	local scan = src.scan
	-- Read the corpus word_counts for the per-atom pipeline
	-- (`atom.paths.word_events` is the emitted projection).

	local corpus = (ctx.shared and ctx.shared.corpus) or {}

	-- Read atoms + binds + atom_infos from the pre-scanned SourceScan payload.
	-- The scan was done once upstream by duffle.scan_source(); this pass is pure.
	local atoms = scan.atoms
	local atom_infos = scan.atom_infos

	-- Build per-source Binds_* index. Local to validate() — no cross-source sharing.
	local binds_index = {}
	for _, b in ipairs(scan.binds) do
		binds_index[b.name] = b
	end

	-- pipe_ctx: the cross-atom shared state for the per-atom pipeline (Fleury "expose structure").
	-- Pre-allocated here, mutated by each per-atom check call below.
	-- Cross-source lookup tables come from `corpus_pipe_ctx` (built once per pass);
	-- source-local body / declaration ownership comes from `src.scan`.
	--   info_by_atom             — atom_name -> atom_info (built once; check_abi_handoff reads it)
	--   binds_index              — Binds_X -> binds struct (built once; check_abi_handoff reads it)
	--   unknown_seen             — macro_name -> first atom line (accumulated across atoms; check_per_atom_cycle_budget dedups)
	--   atoms                    — full atom list (used by check_binds_no_substruct_deref's per-source body walk)
	--   types                    — R_X -> default-type info from atom_dbg_reg_default (check_enum_alias_membership source a)
	--   atom_infos_list          — per-source flat list of atom_info entries (checks #6/#7 iterate it)
	--   register_alias_registry  — R_X -> {name, code, has_atom_reg, source_line} from corpus-wide merge
	--   type_name_registry       — T -> {name, kind, fields, ...} from corpus-wide merge
	-- All registry fields are READ from the corpus (the dep-closed scan-source merge); this pass never re-parses.
	local info_by_atom = {}
	for _, info in ipairs(atom_infos) do
		info_by_atom[info.atom_name] = info
	end
	local pipe_ctx = {
		info_by_atom            = info_by_atom,
		binds_index             = binds_index,
		unknown_seen            = {},
		atoms                   = atoms,
		types                   = scan.types or {},
		atom_infos_list         = atom_infos or {},
		register_alias_registry = corpus_pipe_ctx.register_alias_registry,
		type_name_registry      = corpus_pipe_ctx.type_name_registry,
		-- Per-component metadata (cycle_cost + gp0_contrib) auto-derived from the original `MipsAtomComp_` body by `passes/components.lua::compute_components_metadata`.
		components_by_name      = corpus_pipe_ctx.components_by_name,
	}
	-- Shared cross-source component-body index is owned by the corpus (`corpus.component_body_index`, populated by `passes/components.lua`).
	-- Per-atom checks consume the corpus-owned index directly.
	pipe_ctx.component_body_index = (corpus and corpus.component_body_index) or {}

	--- Per-atom pipeline. ONE iteration of atoms; the 5 check_* functions + analyze_atom_paths all run here, sharing a single tokenize_body + build_body_line_index per body.
	--- Every piece of state derived from an atom body lives on `atom.paths` (per-atom mega-struct);
	--- readers (analyze_atom_paths, the 5 checks, the renderers) all consume `atom.paths`.
	--- Each `check_*` function accepts one atom and its shared context.
	--- Per-source rules run once after this loop completes (no parallel dispatch table).
	---
	--- Body, token, and emission projections come from here (`paths.tokens = body_tokens`, `paths.line_in_body = build_body_line_index` `paths.word_events`
	--- and related fields are owned by `passes/emission_model.lua` pass (per-atom emission projection).
	--- This pass reads: `paths.tokens`, `paths.line_in_body`, `paths.items`, `paths.word_events` from the emitted projection,
	--- then computes `paths.tok_class`, `paths.cycles_min/max`, `paths.branches`, `paths.paths`, `paths.has_loops`, `paths.unknown_macros` via `classify_tokens` + `analyze_atom_paths`.
	--- No re-walk of body text or body_tokens happens here.
	---
	--- Canonical contract: `atom.paths` and `atom.paths.word_events` MUST be populated by `passes/emission_model.run(ctx)` before this pass runs.
	--- The `atom.paths.word_events` projection is owned by the emission-model pass; static-analysis reads it directly.
	local findings = {}
	for _, a in ipairs(atoms) do
		if a.paths == nil then
			error("static_analysis: a.paths is nil; emit emission-model first")
		end
		if a.paths.word_events == nil then
			error("static_analysis: a.paths.word_events is nil; emit emission-model first")
		end
		-- `paths.tokens` / `paths.line_in_body` / `paths.items` / `paths.word_events` are populated by `passes/emission_model.lua`.
		-- Supply tokens when no emission projection is present.
		if a.paths.tokens == nil then a.paths.tokens = a.body_tokens end
		a.paths.tok_class = classify_tokens(a.paths.tokens)

		-- analyze_atom_paths fills the *cycles / branches / has_loops / unknown_macros* fields of a.paths.
		analyze_atom_paths(a, pipe_ctx)

		-- Run the single forward walker for transfer-hazard policy.
		-- Runs once per atom BEFORE the CHECK_RULES per-atom dispatch so the `transfer_hazards` reader (`check_transfer_hazards`) can
		-- project `atom.paths.hazards` into `findings` without re-walking source.
		-- The walker owns `atom.paths.{forward_state, relations, hazards}`; readers never re-iterate events or re-classify tokens.
		analyze_hardware_relations(a)

	-- Run all per-atom checks on this one atom via the CHECK_RULES data table.
	-- Adding a new check = 1 row in CHECK_RULES; this loop never needs editing.
		for _, rule in ipairs(CHECK_RULES) do
			if rule.per_atom then rule.per_atom(a, pipe_ctx, findings) end
		end
	end

	-- Per-source dispatch. Run once per source AFTER the per-atom loop;
	-- consults pipe_ctx's cross-atom registries (register_alias_registry, type_name_registry).
	-- Same CHECK_RULES table; no parallel dispatch table.
	for _, rule in ipairs(CHECK_RULES) do
		if rule.per_source then rule.per_source(src, pipe_ctx, findings) end
	end

	-- Three-way severity binning: per-finding severity is set by the check via `f.kind`.
	-- "error" / "warning" / "info" are all distinct; info findings are NEVER folded into warnings.
	-- Keep error, warning, and info findings in distinct buckets so the control-transfer delay-slot check remains distinct from warnings.)
	-- The `info` list returned here is finding-level only; scan/cycle summary lines go into `summaries`.
	-- An invalid/missing kind is a hard error (no silent fallback to info); this prevents typos like
	-- kind="warn" or omitted kind fields from being misclassified as info in the rendered report.
	local errors   = {}
	local warnings = {}
	local info     = {}
	for _, f in ipairs(findings) do
		-- Preserve the diagnostic context so focused tests + the renderer can route by the originating check or relation id.
		-- Hazard readers (transfer_hazards) populate `f.check`, `f.relation_id`, `f.semantic`, `f.direction`, `f.producer_destination`, `f.gap`, `f.required`, `f.evidence_confidence`, etc.;
		-- Copying them through keeps the per-severity bucket schema compatible with the renderer while making the diagnostic payload queryable.
		local payload = {
			line                 = f.line,
			msg                  = f.msg,
			check                = f.check,
			atom                 = f.atom,
			source               = f.source,
			relation_id          = f.relation_id,
			semantic             = f.semantic,
			direction            = f.direction,
			producer_destination = f.producer_destination,
			producer_word        = f.producer_word,
			producer_line        = f.producer_line,
			producer_source      = f.producer_source,
			consumer_word        = f.consumer_word,
			consumer_token       = f.consumer_token,
			gap                  = f.gap,
			required             = f.required,
			evidence_confidence  = f.evidence_confidence,
			evidence_source      = f.evidence_source,
		}
		-- Preserve relation fields such as target_state and status_register status_value,
		-- and future policy metadata) without making the binner another semantic walker.
		for key, value in pairs(f) do
			if payload[key] == nil then payload[key] = value end
		end
		if     f.kind == "error"   then errors  [#errors   + 1] = payload
		elseif f.kind == "warning" then warnings[#warnings + 1] = payload
		elseif f.kind == "info"    then info    [#info     + 1] = payload
		else
			error(string.format("invalid finding kind %s for check %q (atom=%s, line=%d); expected one of \"error\", \"warning\", \"info\""
				, tostring(f.kind), tostring(f.check), tostring(f.atom), f.line or 0), 0)
		end
	end

	-- Per-source "scanned:" / "cycles:" summary lines. These are SCANNER / BUDGET rollups, not findings; They belong in their own collection so the report can render them
	-- AS summary rows (after Module findings) rather than mixed into the Info finding section.
	local summaries = {}
	-- Per-source "scanned:" summary line.
	-- Includes the source basename for traceability
	-- Include the source basename so multi-source module summaries remain identifiable.
	-- Sources with 0 atoms (pure-header files like dsl.h, mips.h, etc.) are SKIPPED.
	-- The per-module header already lists them in the "Sources:" section, and emitting a noisy "0 atom bodies" line per header is just clutter.
	if #atoms > 0 or #findings > 0 then
		summaries[#summaries + 1] = {
			line = 0,
			msg  = string.format("scanned: %s: %d atom bodies; %d findings", src.basename, #atoms, #findings),
		}
	end

	-- Path-aware cycle-budget summary line. Per-path min/max totals.
	if #atoms > 0 then
		local total_min     = 0
		local total_max     = 0
		local max_atom_cyc  = 0
		local max_atom_name = nil
		for _, a in ipairs(atoms) do
			local p = a.paths or {}
			total_min = total_min + (p.cycles_min or 0)
			total_max = total_max + (p.cycles_max or 0)
			if (p.cycles_max or 0) > max_atom_cyc then
				max_atom_cyc  = p.cycles_max
				max_atom_name = a.name
			end
		end
		summaries[#summaries + 1] = {
			line = 0,
			msg  = string.format("cycles: path-aware min=%d max=%d across %d atoms; worst atom=%s (%d); best-case, no stalls; BD-slot nops absorbed into branch costs",
				total_min, total_max, #atoms, max_atom_name or "?", max_atom_cyc),
		}
	end

	return {
		atoms     = atoms,
		findings  = findings,
		errors    = errors,
		warnings  = warnings,
		info      = info,
		summaries = summaries,
	}
end

-- ════════════════════════════════════════════════════════════════════════════
-- M.run — orchestrator entry
-- ════════════════════════════════════════════════════════════════════════════

--- @class M

local M = {}

--- @param ctx PassCtx
--- @return PassResult
function M.run(ctx)
	local outputs  = {}
	local errors   = {}
	local warnings = {}
	-- `info` aggregates finding-level info across every source (the per-source validate() also
	-- returns a `summaries` collection for scan/cycle rollups;
	-- those are summary rows and never enter `info`).
	local info     = {}

	-- Build the corpus-wide pipe_ctx ONCE per pass run.
	-- The pipe_ctx is shared across every validate() invocation in this M.run so cross-source visibility is constant.
	local corpus_pipe_ctx = build_corpus_pipe_ctx(ctx)
	local corpus          = ctx.shared.corpus

	-- Aggregate per-DIRECTORY (per-module).
	-- One static_analysis.txt per source-directory, emitted only if the directory contains at least one atom.
	-- Empty-source directories (e.g. duffle headers with no atoms) produce no report.
	-- Group sources by `src.dir` through the corpus-owned `sources_by_dir`.
	local by_dir = (corpus and corpus.sources_by_dir) or {}

	for dir, dir_sources in pairs(by_dir) do
		-- Run validate() against every source in this directory; accumulate atoms / findings / errors / warnings.
		-- The validate() function does its own per-source analysis (Binds indexing, atom discovery, all checks)
		-- and attaches path-aware cycle data to each atom it finds.
		local all_atoms    = {}
		local all_findings = {}
		local dir_errors   = {}
		local dir_warnings = {}
		local dir_info     = {}
		local dir_summaries = {}
		for _, src in ipairs(dir_sources) do
			local result = validate(ctx, src, corpus_pipe_ctx)
			-- Tag each atom with its source so the render step can prefix the atom line with "<filename>:"
			-- when atoms from multiple sources live in the same module (e.g. lottes_tape.h + atom_dsl.h both declaring atoms).
			for _, a in ipairs(result.atoms) do
				a.source_path = src.path
				all_atoms[#all_atoms + 1] = a
			end
			for _, f  in ipairs(result.findings) do all_findings[#all_findings + 1] = f  end
			for _, e  in ipairs(result.errors)    do dir_errors    [#dir_errors    + 1] = e  end
			for _, w  in ipairs(result.warnings)  do dir_warnings  [#dir_warnings  + 1] = w  end
			for _, i_ in ipairs(result.info)      do dir_info      [#dir_info      + 1] = i_ end
			for _, s  in ipairs(result.summaries or {}) do dir_summaries[#dir_summaries + 1] = s end
		end

		-- Stash per-module results on the corpus for `report.lua` to consume.
		-- Avoids re-running validate() in the report pass + avoids rebuilding corpus_pipe_ctx.
		-- Pattern matches `corpus.atoms_by_name` / `corpus.word_counts` / `corpus.components`
		-- (one writer: `static_analysis.lua`; one reader: `report.lua`).
		-- Module basename = last component of `dir` ("code/duffle" -> "duffle").
		local dir_basename = dir:match("([^/\\]+)$") or dir
		corpus.static_analysis_results = corpus.static_analysis_results or {}
		corpus.static_analysis_results[dir_basename] = {
			atoms     = all_atoms,
			findings  = all_findings,
			errors    = dir_errors,
			warnings  = dir_warnings,
			info      = dir_info,
			summaries = dir_summaries,
			sources   = dir_sources,
		}

		-- Aggregate per-dir errors/warnings/info into the orchestrator totals.
		-- Hoisted out of any per-dir file-emit so `report.lua` can drop the on-disk file emitter without losing the cross-module rollup.
		for _, e  in ipairs(dir_errors)   do errors  [#errors   + 1] = e end
		for _, w  in ipairs(dir_warnings) do warnings[#warnings + 1] = w end
		for _, i_ in ipairs(dir_info)     do info    [#info     + 1] = i_ end
		-- (No per-dir emit: per-module findings are stashed on `corpus.static_analysis_results` above. 
		-- `report.lua` reads that projection to render `<module>.atom_meta_report.md` without re-running validate().)
	end

	-- Result exposes at least {outputs, errors, warnings, info}.
	-- Summaries are internal to the renderer; callers (orchestrator, focused tests) consume the four severity-typed collections.
	return { outputs = outputs, errors = errors, warnings = warnings, info = info }
end

return M
