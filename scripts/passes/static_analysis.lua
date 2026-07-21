--- passes/static_analysis.lua — Per-atom static-analysis checks.
---
--- The 9 checks currently shipped:
---   Per-atom rules:
---     1. **GTE pipeline-fill** — every `gte_cmdw_*` invocation must be preceded by the minimum number of `nop` words
---        (per `duffle.GTE_PIPELINE_LATENCY`) so the COP2 pipeline latency is fully retired before the command issues.
---     2. **mac_yield uniformity** — every atom body must contain exactly one `mac_yield()` call (control transfer pattern).
---     3. **ABI handoff** — every `atom_bind(Binds_X)` must reference a `typedef Struct_(Binds_X) { ... }` declaration.
---     4. **GPU port-store shape** — per-shape (`f3`/`f4`/`g4`/etc.) the sum of `mac_format_X_color` + `mac_gte_store_X_*` +
---        `mac_insert_ot_tag_X` words must equal the GP0 cmd's expected packet size.
---     5. **per-atom cycle budget** — sum each atom body's instruction latencies (per `duffle.INSTRUCTION_LATENCY`); report total.
---   Per-source rules (registry-driven, added 2026-07-16):
---     6. **enum_alias_membership** — every `R_X` referenced from `atom_dbg_reg_default`, `atom_reg_types`,
---        `atom_type(...)`, `atom_reads`, or `atom_writes` must be in `scan.register_alias_registry`. Missing -> warning.
---     7. **atom_type_consistency** — every `reg_type_overrides[R_X].type_name` must resolve in `scan.type_name_registry`. Missing -> error.
---     8. **binds_no_substruct_deref** — every `load_word(R_A, R_B, O_(Type, Field))` and `store_word(...)` in every atom body
---        must reference a leaf scalar (pointer-to-struct counts as leaf; nested struct members do NOT). Missing -> warning (build continues).
---     9. **reads_writes_alias_membership** — distinct check name duplicating #6's reads/writes coverage so the report can
---        attribute failures to a precedence class. Missing -> warning (build continues).
---
--- The orchestrator (`ps1_meta.lua`) wires this module in via the PASSES table:
---   `["static-analysis"] = { module = "passes.static_analysis", kind = "validation", deps = {"word-counts", "components"},
---     out = { { kind = "report", path_template = "<out_root>/<basename>.static_analysis.txt" } } }`
---
--- **Conventions**: tabs (1/level), EmmyLua annotations, no regex, Lua 5.3 compatible.

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
--- @field path     string  -- absolute path to the source file
--- @field text     string  -- the full source text
--- @field dir      string  -- the directory containing the source
--- @field basename string  -- filename without extension

--- @class PassCtx
--- @field sources            SourceFile[]
--- @field metadata_path      string
--- @field shared             table
--- @field shared.word_counts table<string, integer>
--- @field out_root           string
--- @field project_root       string
--- @field upstream           table<string, table>
--- @field flags              table
--- @field dry_run            boolean
--- @field verbose            boolean

--- @class PassResult
--- @field outputs  table[]
--- @field errors   table[]
--- @field warnings table[]

--- @alias AtomName    string  -- lower_snake_case atom nameMacroName   string  -- lower_snake_case macro identifier
--- @alias CheckName   string  -- "gte_pipeline_fill" | "mac_yield_uniformity" | "abi_handoff" | "gpu_port_store_shape" | "per_atom_cycle_budget"

--- @class AtomBody
--- @field line     integer  -- source line of the atom declaration
--- @field name     AtomName -- atom name (e.g. "cube_g4_face")
--- @field body     string   -- the brace-delimited body (without the braces)
--- @field body_off integer  -- char offset of body[1] in source
--- @field kind     string   -- "atom" | "comp_bare" | "comp_proc"

--- @class Token
--- @field tok      string     -- the raw token text (trimmed)
--- @field line     integer    -- source line of the token's start
--- @field ident    string|nil -- the leading ident of the token (if any)
--- @field kind     string     -- "n_words" | "mac_yield" | "gte_cmdw" | "mac_format" | "mac_gte_store" | "mac_insert_ot_tag" | "atom_label" | "atom_offset" | "other"

--- @class Finding 
--- @field line     integer   -- source line of the finding
--- @field atom     AtomName  -- the atom this finding is for (or "")
--- @field check    CheckName -- the check identifier
--- @field kind     string    -- "error" | "warning" | "info"
--- @field msg      string    -- the finding message

--- @class AtomAnalysis
--- @field atom       AtomBody
--- @field tokens     Token[]   -- the tokens in the atom body, annotated
--- @field findings   Finding[] -- findings for this atom
--- @field total_cycles integer -- sum of token cycle costs

-- ════════════════════════════════════════════════════════════════════════════
-- classify_tokens — per-token classification (the plex's pre-computed data layer)
-- ════════════════════════════════════════════════════════════════════════════

-- ONE forward pass over the token list produces a flat table of per-token classifications. 
-- Every check + analyze_atom_paths reads from this table instead of re-scanning the token strings. 
--
-- The classification is stored on `atom.paths.tok_class` as an array indexed by token index (1..#tokens). 
-- Each entry has:
--   ident         — the leading identifier (e.g. "load_word", "gte_cmdw_rtpt", "nop", "mac_yield")
--   nop_words     — 0 / 1 / 2 (for "nop" / "nop2" / anything else)
--   nop_prefix    — consecutive nop words ending just BEFORE this token (forward-pass pre-compute;
--                   replaces the backward walk in count_preceding_nops — O(N) instead of O(N²))
--   is_yield      — true if this token is `mac_yield` or `mac_yield(...)`
--   is_atom_label — true if this token is `atom_label(name)`; label_name has the name
--   is_branch     — true if this token is `branch_*(...)`; branch_label has the label or false
--   is_load_word  — true if this token starts with `load_word(`
--   is_store_word — true if this token starts with `store_word(`
--
-- Checks that need the leading ident use `tok_class.ident` instead of re-matching the token string.
-- Checks that need "how many nops before token i" use `tok_class.nop_prefix` instead of walking backwards.

--- @class TokClass
--- @field ident              string          -- leading identifier
--- @field nop_words          integer         -- 0/1/2
--- @field nop_prefix         integer         -- consecutive nop words before this token
--- @field is_yield           boolean
--- @field is_atom_label      boolean
--- @field label_name         string|nil      -- for atom_label(name)
--- @field is_branch          boolean
--- @field branch_label       string|false|nil -- for branch_*(..., atom_offset(F, label))
--- @field is_load_word       boolean
--- @field is_store_word      boolean
--- @field mac_format_shape   string|nil      -- "f3" / "g4" etc. for mac_format_X_color; nil otherwise
--- @field is_gte_store       boolean         -- ident matches `mac_gte_store_<shape>`
--- @field is_ot_tag          boolean         -- ident matches `mac_insert_ot_tag_<shape>`
--- @field writes_r_prim_cursor boolean       -- store_word targeting R_PrimCursor
--- @field reads_r_tape_ptr   boolean         -- any token referencing R_TapePtr
--- @field o_arg1             string|nil      -- first arg of O_(<a>, <b>) captures; nil for non-O_ tokens
--- @field o_arg2             string|nil      -- second arg of O_(<a>, <b>) captures
--- @field s_arg1             string|nil      -- arg of S_(<a>) captures; nil for non-S_ tokens

-- Patterns for O_(<arg1>, <arg2>) and S_(<arg>) captures.
-- UNANCHORED, the substring can appea anywhere in the token (e.g., `load_word(R_T0, R_TapePtr, O_(Binds_X, field))` matches at position ~24).
-- The binds_name match is deferred to check_abi_handoff (which compares tc.o_arg1 == atom.info.binds).
local O_PATTERN = "O_%(([%w_]+),%s*([%w_]+)%s*%)"
local S_PATTERN = "S_%(([%w_]+)%s*%)"

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

		local is_yield      = ident == "mac_yield"
		local is_atom_label = false
		local label_name    = nil
		local is_branch     = false
		local branch_label  = nil
		local is_load_word  = ident == "load_word"
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
		elseif tok:match("^branch_[%w_]+%s*%(") then
			is_branch    = true
			branch_label = tok:match("atom_offset%s*%([^,]+,%s*([%w_]+)%s*%)") or false
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
			ident                = ident,
			nop_words            = nop_words,
			nop_prefix           = nop_run,
			is_yield             = is_yield,
			is_atom_label        = is_atom_label,
			label_name           = label_name,
			is_branch            = is_branch,
			branch_label         = branch_label,
			is_load_word         = is_load_word,
			is_store_word        = is_store_word,
			mac_format_shape     = mac_format_shape,
			is_gte_store         = is_gte_store,
			is_ot_tag            = is_ot_tag,
			writes_r_prim_cursor = writes_r_prim_cursor,
			reads_r_tape_ptr     = reads_r_tape_ptr,
			o_arg1               = o_arg1,
			o_arg2               = o_arg2,
			s_arg1               = s_arg1,
		}
		-- Advance the nop run for the NEXT token.
		if nop_words > 0 then nop_run = nop_run + nop_words
		else                  nop_run = 0
		end
	end
	return tc
end

-- ════════════════════════════════════════════════════════════════════════════
-- Check #1: GTE pipeline-fill
-- ════════════════════════════════════════════════════════════════════════════

-- Check a single gte_cmdw_* token for pipeline-fill compliance.
-- Uses the pre-computed `tok_class` entry (nop_prefix replaces the backward walk; ident replaces the per-token match).
local function check_one_gte_cmdw(atom, tc_entry, ti, line_in_body, findings)
	local ident = tc_entry.ident
	if not ident:match("^gte_cmdw_") then return end

	local variant = ident:match("^gte_cmdw_(.+)$")
	local need    = duffle.GTE_PIPELINE_LATENCY[ident]
	local line    = atom.line + line_in_body[atom.paths.tokens[ti].rel]

	if need == nil then
		findings[#findings + 1] = {
			atom  = atom.name,
			line  = line,
			check = "gte_pipeline_fill",
			kind  = "warning",
			msg   = string.format(
				"%s at line %d uses `gte_cmdw_%s` but that macro is not in duffle.GTE_PIPELINE_LATENCY -- add a min_nops entry",
				atom.name, line, variant),
		}
	elseif  need > 0 then
		local have = tc_entry.nop_prefix
		if    have < need then
			findings[#findings + 1] = {
				atom  = atom.name,
				line  = line,
				check = "gte_pipeline_fill",
				kind  = "error",
				msg   = string.format(
					"%s at line %d needs %d nop word%s immediately BEFORE `gte_cmdw_%s`; only %d found",
					atom.name, line, need, need == 1 and "" or "s", variant, have),
			}
		end
	end
end

--- Per-atom: check every `gte_cmdw_*` for pipeline-fill compliance.
--- Uses the pre-computed `atom.paths.tok_class` — nop_prefix (forward-pass pre-compute)
--- replaces the old backward walk; ident replaces the per-token `tok:match` classification.
local function check_gte_pipeline_fill(atom, pipe_ctx, findings)
	local tc           = atom.paths.tok_class
	local line_in_body = atom.paths.line_in_body
	local tn           = #atom.paths.tokens
	for ti = 1, tn do
		check_one_gte_cmdw(atom, tc[ti], ti, line_in_body, findings)
	end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Check #2: mac_yield uniformity
-- ════════════════════════════════════════════════════════════════════════════

--- Every atom body must contain exactly one `mac_yield()` call and it must be the LAST top-level token in the body 
--- (so the tape runtime can pick up cleanly at the next atom's bound registers).
---
--- Empty bodies are not currently flagged — runtime infrastructure atoms like `MipsAtom_(yield) { mac_yield() }` 
--- and `MipsAtom_(tape_exit) { jump_reg(rret_addr), nop }` are valid as-is; mac_yield at the end is the contract.
--- Stage 2: signature uniformized to `(atom, pipe_ctx, findings)` — pipe_ctx is ignored here.
local function check_mac_yield_uniformity(atom, pipe_ctx, findings)
	-- Per-kind semantics:
	--   MipsAtom_          (baked atom): exactly 1 mac_yield at the end of the body. Control transfer is the atom's job.
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

	if atom.kind == "atom" then
		-- Baked atom: exactly 1 yield at the end.
		if count == 0 then
			findings[#findings + 1] = {
				atom  = atom.name,
				line  = atom.line,
				check = "mac_yield_uniformity",
				kind  = "warning",
				msg   = string.format(
					"%s at line %d has no `mac_yield()`; every atom must hand control to the next via mac_yield at end",
					atom.name, atom.line),
			}
		elseif count > 1 then
			findings[#findings + 1] = {
				atom  = atom.name,
				line  = line_for(last_idx),
				check = "mac_yield_uniformity",
				kind  = "warning",
				msg   = string.format(
					"%s at line %d has %d `mac_yield()` calls; exactly 1 is allowed",
					atom.name, line_for(last_idx), count),
			}
		elseif last_idx < n then
			-- 1 call, but not the last token. We DON'T fail if the post-token is just `nop` or `nop2` or a branch with `, nop` delay slot.
			-- It's the standard "yield, then BD nop" idiom.
			local post_non_nop = false
			for search_idx = last_idx + 1, n do
				if tc[search_idx].nop_words == 0
				   and tokens[search_idx].tok ~= "" then
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
					msg   = string.format(
						"%s at line %d has `mac_yield()` at token %d/%d; the yield must be the LAST non-nop token in the body",
						atom.name, line_for(last_idx), last_idx, #tokens),
				}
			end
		end
	else
		-- Component (comp_bare or comp_proc): ZERO yields.
		-- The parent atom does the yield.
		-- A yield inside a component would either be dead code (bare) or prematurely terminate the function (proc).
		-- Both are bugs.
		if count > 0 then
			findings[#findings + 1] = {
				atom  = atom.name,
				line  = line_for(last_idx),
				check = "mac_yield_uniformity",
				kind  = "warning",
				msg   = string.format(
					"%s at line %d is a %s component but has %d `mac_yield()` call(s); components must not yield (the parent atom does)",
					atom.name, line_for(last_idx), atom.kind, count),
			}
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Check #3: ABI handoff discipline
-- ════════════════════════════════════════════════════════════════════════════

--- For every atom with `atom_bind(Binds_X)`, verify the atom body reads every field of `Binds_X` from R_TapePtr (in any order) 
--- and advances R_TapePtr by S_(Binds_X) at the end. Mismatches are errors.
---
--- This is the "job boundary sanity check": Binds_X is the atom's input payload (like a C function's argument struct). 
--- The body must read each input field and advance the input cursor past the payload. 
--- The order of reads doesn't matter — each field is at a different offset in the struct, and the advance at the end is what keeps the tape pointer in sync.
---
--- Rules:
---   1. Body MUST contain one `load_word(R_*, R_TapePtr, O_(Binds_X, field))` per field of Binds_X. Missing field = error.
---   2. Body MUST contain an `add_ui_self(R_TapePtr, S_(Binds_X))` (or equivalent advance by the struct's byte count). Missing = error.
---   3. atom_bind(Binds_X) where Binds_X doesn't exist = error.
--- Per-atom: verify the atom body reads every field of its `Binds_X` from R_TapePtr and advances R_TapePtr by S_(Binds_X).
--- Signature changed in Stage 1B: takes `(atom, pipe_ctx, findings)` where `pipe_ctx` carries the cross-atom
--- `info_by_atom` + `binds_index` tables (built once by validate() before the per-atom loop).
--- Per-atom iteration now lives in validate(); this is a per-atom predicate.
local function check_abi_handoff(atom, pipe_ctx, findings)
	local info = pipe_ctx.info_by_atom[atom.name]
	if not info or not info.binds then return end
	local binds_name = info.binds
	local binds      = pipe_ctx.binds_index[binds_name]
	if not binds then
		findings[#findings + 1] = {
			atom  = atom.name, line = atom.line,
			check = "abi_handoff", kind = "error",
			msg   = string.format("%s at line %d has `atom_bind(%s)` but no `typedef Struct_(%s)` declaration found in source",
				atom.name, atom.line, binds_name, binds_name),
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
		if tc_entry.is_load_word and tc_entry.reads_r_tape_ptr and tc_entry.o_arg1 == binds_name then
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
				msg   = string.format("%s at line %d binds %s but never loads field `%s` from R_TapePtr (expected O_(%s, %s))",
					atom.name, atom.line, binds_name, f.name, binds_name, f.name),
			}
		end
	end

	if not found_advance then
		findings[#findings + 1] = {
			atom  = atom.name, line = atom.line,
			check = "abi_handoff", kind = "error",
			msg   = string.format("%s at line %d binds %s but never advances R_TapePtr by S_(%s) (= %d bytes / %d words)",
				atom.name, atom.line, binds_name, binds_name, binds.bytes, binds.bytes / 0x04),
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
---   - Atoms containing a `mac_<name>(...)` call whose name is not in duffle.GP0_MACRO_CONTRIB emit a "new macro; update duffle.GP0_MACRO_CONTRIB" advisory.
---
--- Applies only to `kind = "atom"` (baked atoms). Components don't emit full primitives.
local function check_gpu_portstore_shape(atom, pipe_ctx, findings)
	if atom.kind ~= "atom" then return end
	local tokens = atom.paths.tokens
	local line_in_body = atom.paths.line_in_body
	local tc = atom.paths.tok_class
	local cmd_byte = nil
	local cmd_line = nil
	local contrib = 0
	local saw_format = false
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
			local n = duffle.GP0_MACRO_CONTRIB["mac_format_" .. shape .. "_color"]
			if    n then contrib = contrib + n end
		end
		if tc_entry.is_gte_store then
			local n = duffle.GP0_MACRO_CONTRIB[tc_entry.ident]
			if    n then contrib = contrib + n end
		end
		if tc_entry.is_ot_tag then
			local n = duffle.GP0_MACRO_CONTRIB[tc_entry.ident]
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
					.. " Consider migrating to `mac_format_X_color` + `mac_gte_store_X_post_*` + `mac_insert_ot_tag_X`.",
					atom.name, atom.line),
			}
		end
	else
		local expected = duffle.GP0_CMD_SIZE[cmd_byte]
		if contrib ~= expected then
			findings[#findings + 1] = {
				atom  = atom.name, line = cmd_line or atom.line,
				check = "gpu_portstore_shape", kind = "error",
				msg   = string.format("%s at line %d emits GP0 0x%02X with %d prim word(s); expected %d (cmd 0x%02X total = %d)",
					atom.name, cmd_line or atom.line, cmd_byte, contrib, expected, cmd_byte, expected),
			}
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Check #5: per-atom cycle budget (uses analyze_atom_paths's unknown_macros)
-- ════════════════════════════════════════════════════════════════════════════

--- Walk all paths through an atom body and return per-path cycle sums.
--- Builds a tiny CFG: each token has a "next" pointer; branches have two (fall-through + taken).
--- The BD-slot nop after a branch is absorbed into the branch's cost (MIPS-accurate: BD slot always runs), 
--- and is SKIPPED when continuing down the fall-through path (otherwise we'd double-count it).
---
--- Returns:
---   cycles_min     - shortest path through the body (sum of token costs)
---   cycles_max     - longest path through the body
---   branches       - number of branches in the body
---   paths          - number of distinct paths reached (terminated at
---                    mac_yield or end-of-body)
---   has_loops      - true iff a path re-entered a token it had visited
---                    (warning; loop bodies aren't supported)
---   unknown_macros - list of unique macro names not in duffle.INSTRUCTION_LATENCY
local function analyze_atom_paths(atom)
	local tokens   = atom.paths.tokens or duffle.tokenize_body(atom.body)
	local tc       = atom.paths.tok_class or classify_tokens(tokens)
	local n        = #tokens

	-- Build label + branch maps from the pre-computed classification (no re-scan).
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
	local costs       = {}
	local unknown_set = {}
	for tok_idx = 1, n do
		local c      = tc[tok_idx]
		local cost   = duffle.INSTRUCTION_LATENCY[c.ident]
		if cost == nil then
			cost = duffle.UNKNOWN_INSTRUCTION_CYCLES
			unknown_set[c.ident] = true
		end
		costs[tok_idx] = cost
	end

	-- A token is a terminator if it's `mac_yield`.
	local function is_terminator(tok_idx) return tc[tok_idx].is_yield end

	-- A token is a "branch" if the classification says so.
	local function is_branch(tok_idx) return tc[tok_idx].is_branch end
	local function successors(tok_idx)
		local tok = tokens[tok_idx].tok
		if is_terminator(tok_idx) then
			return {}, tok_idx  -- empty list; term = tok_idx signals "path ends here"
		end
		if is_branch(tok_idx) then
			local label = branches[tok_idx]  -- may be false for literal-offset branches
			local succ  = {}
			-- Fall-through: skip the BD slot (tok_idx+1). Use tok_idx+2.
			if tok_idx + 2 <= n then
				succ[#succ + 1] = tok_idx + 2
			end
			-- Taken: only if the branch has a known atom_offset target.
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
		-- Normal token: just the next one
		if tok_idx + 1 <= n then return { tok_idx + 1 }, nil end
		return {}, nil
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
				io.stderr:write(string.format("  -> LOOP at tok_idx=%d (tok=%s) acc=%d\n",
					tok_idx, tokens[tok_idx].tok, acc))
			end
			return
		end

		-- Add this token's cost. For a branch, ADD the BD-slot cost too
		-- (and skip the BD slot in the successor list — already done in `successors` above for fall-through; 
		-- for taken path the BD slot was at tok_idx+1 which is now skipped entirely).
		local cost = costs[tok_idx]
		if is_branch(tok_idx) and tok_idx + 1 <= n then
			cost = cost + costs[tok_idx + 1]
		end
		local new_acc = acc + cost

		local succ, term = successors(tok_idx)
		if term then
			-- Terminator: record the path's cycle sum. 
			-- We do NOT add the terminator token to `visited` a path ends here, so a different path that 
			-- ALSO reaches this terminator is a legitimate new path (not a loop). 
			-- If we marked it visited, subsequent paths that reach the same terminator would be incorrectly flagged as loops.
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

	-- branch_count: number of `branch_*(...)` tokens.
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
--- (deduplicated across atoms so the warning section doesn't get spammed with N copies of "macro X not in duffle.INSTRUCTION_LATENCY").
--- Per-atom: emit one finding per unknown macro seen, deduplicated across atoms 
--- (so the warning section doesn't get spammed with N copies of "macro X not in duffle.INSTRUCTION_LATENCY").
--- Reuses `analyze_atom_paths`'s per-atom unknown_macros discovery (it's the canonical place that walks tokens and computes per-token cycle costs).
local function check_per_atom_cycle_budget(atom, pipe_ctx, findings)
	local p = atom.paths or {}
	for _, name in ipairs(p.unknown_macros or {}) do
		if not pipe_ctx.unknown_seen[name] then
			pipe_ctx.unknown_seen[name] = atom.line
			findings[#findings + 1] = {
				atom  = atom.name, line = atom.line,
				check = "per_atom_cycle_budget", kind = "warning",
				msg   = string.format("%s at line %d uses macro `%s` which is not in duffle.INSTRUCTION_LATENCY; "
					.. "cycle count will be +%d per call (best-case). Add an entry to duffle.INSTRUCTION_LATENCY.",
					atom.name, atom.line, name, duffle.UNKNOWN_INSTRUCTION_CYCLES),
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
-- sources use R_* aliases in atom_reads / atom_writes that may not yet be opted in via the 
-- bare `atom_reg` marker. R_TapePtr / R_AtomJmp / R_PrimCursor / R_FaceCursor / R_VertBase / R_OtBase ARE opted in (lottes_tape.h Task 21).
-- Raw C-ABI aliases like R_T0..R_T3 are intentionally NOT auto-included (per the prototype principle:
-- no auto-include of wave-context; explicit opt-in only). Warnings keep the build green
-- and surface the migration gap so users see which atoms still need opt-in registration.
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
				msg   = string.format(
					"atom_dbg_reg_default at line %d references unknown register %q (not in register_alias_registry)",
					def.source_line or 0, reg),
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
						msg   = string.format(
							"atom '%s' at line %d has reg_type_overrides for %q; the alias is not in register_alias_registry",
							atom_name, info_line, reg),
					}
				end
			end
		end
		for _, reg in ipairs(ai.reads or {}) do
			if not reg_registry[reg] then
				findings[#findings + 1] = {
					atom  = atom_name, line = info_line,
					check = "enum_alias_membership", kind = "warning",
					msg   = string.format(
						"atom '%s' at line %d has atom_reads for %q; the alias is not in register_alias_registry",
						atom_name, info_line, reg),
				}
			end
		end
		for _, reg in ipairs(ai.writes or {}) do
			if not reg_registry[reg] then
				findings[#findings + 1] = {
					atom  = atom_name, line = info_line,
					check = "enum_alias_membership", kind = "warning",
					msg   = string.format(
						"atom '%s' at line %d has atom_writes for %q; the alias is not in register_alias_registry",
						atom_name, info_line, reg),
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
						msg   = string.format(
							"atom '%s' at line %d reg_type_overrides[%q] uses unknown type %q (not in type_name_registry)",
							atom_name, info_line, reg, tostring(ov.type_name)),
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
-- A nested struct member (pointer_depth == 0 AND type_name resolves to a `kind = "struct"` registry entry) is NOT a leaf scalar and is flagged.
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
-- Extracted to keep check_binds_no_substruct_deref's nesting depth <= 5 (the project convention; this is the 5th nesting level:
-- function -> for-atom -> for-token -> if-load/store -> if-type-resolves -> [helper]).
local function find_field_by_name(type_entry, field_name)
	for _, f in ipairs(type_entry.fields or {}) do
		if f.name == field_name then return f end
	end
	return nil
end

-- True iff a (field, type_registry) pair is a leaf scalar (safe to dereference as a tape-payload field).
-- Pointer-to-X is always leaf; non-pointer struct members are NOT leaf.
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
			if (tc_entry.is_load_word or tc_entry.is_store_word)
				and tc_entry.o_arg1 and tc_entry.o_arg2 then
				local type_name  = tc_entry.o_arg1
				local field_name = tc_entry.o_arg2
				local body_line  = a.line + (line_in_body[tokens[ti].rel] or 0)

				local type_entry = type_registry[type_name]
				if not type_entry or not type_entry.fields then
					findings[#findings + 1] = {
						atom  = a.name, line = body_line,
						check = "binds_no_substruct_deref", kind = "warning",
						msg   = string.format(
							"atom '%s' at line %d O_(%s, %s) refers to type %q which has no fields table in type_name_registry",
							a.name, body_line, type_name, field_name, type_name),
					}
				else
					local field = find_field_by_name(type_entry, field_name)
					if not field then
						findings[#findings + 1] = {
							atom  = a.name, line = body_line,
							check = "binds_no_substruct_deref", kind = "warning",
							msg   = string.format(
								"atom '%s' at line %d O_(%s, %s) does not resolve to a field of %s",
								a.name, body_line, type_name, field_name, type_name),
						}
					elseif not is_field_leaf(field, type_registry) then
						findings[#findings + 1] = {
							atom  = a.name, line = body_line,
							check = "binds_no_substruct_deref", kind = "warning",
							msg   = string.format(
								"atom '%s' at line %d O_(%s, %s) dereferences a non-pointer struct field of type %q; nested struct members are forbidden",
								a.name, body_line, type_name, field_name, field.type_name),
						}
					end
				end
			end
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Check #9: reads_writes_alias_membership
-- ════════════════════════════════════════════════════════════════════════════

-- For every `atom_reads(R_X)` and `atom_writes(R_X)` entry in every `atom_infos` entry, the `R_X` MUST be present in `pipe_ctx.register_alias_registry`.
-- This DUPLICATES `enum_alias_membership`'s coverage of the reads/writes arrays;
-- the distinct check name is intentional so the report can attribute the failure to a precedence-class (warnings vs errors) — the production reads/writes
-- paths are intentionally permissive at the warning level even when the registry-driven check is strict at the error level.
-- Per-source rule. Severity: warning (build continues).
local function check_reads_writes_alias_membership(_src, pipe_ctx, findings)
	local reg_registry = pipe_ctx.register_alias_registry or {}
	for _, ai in ipairs(pipe_ctx.atom_infos_list or {}) do
		local info_line = ai.info_line or 0
		local atom_name = ai.atom_name or ""
		for _, reg in ipairs(ai.reads or {}) do
			if not reg_registry[reg] then
				findings[#findings + 1] = {
					atom  = atom_name, line = info_line,
					check = "reads_writes_alias_membership", kind = "warning",
					msg   = string.format(
						"atom '%s' at line %d atom_reads for %q; the alias is not in register_alias_registry",
						atom_name, info_line, reg),
				}
			end
		end
		for _, reg in ipairs(ai.writes or {}) do
			if not reg_registry[reg] then
				findings[#findings + 1] = {
					atom  = atom_name, line = info_line,
					check = "reads_writes_alias_membership", kind = "warning",
					msg   = string.format(
						"atom '%s' at line %d atom_writes for %q; the alias is not in register_alias_registry",
						atom_name, info_line, reg),
				}
			end
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
-- CHECK_RULES — data-driven check dispatch (Muratori: data over control flow)
-- ════════════════════════════════════════════════════════════════════════════

-- Each rule is a table entry: { name, <dispatch> }.
-- Dispatch shapes:
--   per_atom(atom, pipe_ctx, findings)          — runs once per atom inside validate()'s single loop
--   post(pipe_ctx, findings)                    — runs once after all per-atom calls complete
--   per_macro(macro, wc, findings)              — runs once per TAPE_WORDS / _Pragma macro declaration
--   per_skip_marker(marker, pipe_ctx, findings) — runs once per src.scan.skip_over.markers entry
--   per_source(src, pipe_ctx, findings)         — runs once per source AFTER the per-atom loop completes
--                                                 (added for the registry-driven rule set; same CHECK_RULES table — no parallel dispatch)
-- Adding a new check = 1 row here + 1 check_* function. validate() is updated only to invoke the per_source dispatch loop (the per_atom dispatch loop never changes).
-- This is the plex pattern: the iteration is in ONE place (validate), the variation is in DATA (this table).

local CHECK_RULES = {
	{ name = "gte_pipeline_fill",            per_atom   = check_gte_pipeline_fill            },
	{ name = "mac_yield_uniformity",         per_atom   = check_mac_yield_uniformity         },
	{ name = "abi_handoff",                  per_atom   = check_abi_handoff                  },
	{ name = "gpu_portstore_shape",          per_atom   = check_gpu_portstore_shape          },
	{ name = "per_atom_cycle_budget",        per_atom   = check_per_atom_cycle_budget        },
	{ name = "enum_alias_membership",        per_source = check_enum_alias_membership        },
	{ name = "atom_type_consistency",        per_source = check_atom_type_consistency        },
	{ name = "binds_no_substruct_deref",     per_source = check_binds_no_substruct_deref     },
	{ name = "reads_writes_alias_membership",per_source = check_reads_writes_alias_membership},
}

-- ════════════════════════════════════════════════════════════════════════════
-- Per-source validation
-- ════════════════════════════════════════════════════════════════════════════

local function validate(ctx, src)
	local scan = src.scan

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
	-- Replaces the per-check local tables that used to live inside each check_* function body.
	--   info_by_atom             — atom_name -> atom_info (built once; check_abi_handoff reads it)
	--   binds_index              — Binds_X -> binds struct (built once; check_abi_handoff reads it)
	--   unknown_seen             — macro_name -> first atom line (accumulated across atoms; check_per_atom_cycle_budget dedups)
	--   atoms                    — full atom list (used by check_binds_no_substruct_deref's per-source body walk)
	--   types                    — R_X -> default-type info from atom_dbg_reg_default (check_enum_alias_membership source a)
	--   atom_infos_list          — flat list of atom_info entries (checks #6/#7/#9 iterate it)
	--   register_alias_registry  — R_X -> {name, code, has_atom_reg, source_line} from parse_enum_aliases
	--   type_name_registry       — T -> {name, kind, fields, ...} from parse_typedef_binds
	-- All registry fields are READ from src.scan (the dep-closed scan-source payload); this pass never re-parses.
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
		register_alias_registry = scan.register_alias_registry or {},
		type_name_registry      = scan.type_name_registry or {},
	}

	-- THE per-atom pipeline. ONE iteration of atoms; the 5 check_* functions + analyze_atom_paths
	-- all run here, sharing a single tokenize_body + build_body_line_index per body.
	-- Plex move: every piece of state derived from an atom body lives on `atom.paths` (the per-atom mega-struct);
	-- readers (analyze_atom_paths, the 5 checks, the renderers) all consume `atom.paths`, not the raw `atoms` list.
	-- Stage 1B: each check_* now takes `(atom, ...)` instead of `(atoms, findings)` — no more single-atom `{a}` shim.
	-- Per-source rules run once after this loop completes (no parallel dispatch table).
	local findings = {}
	for _, a in ipairs(atoms) do
		a.paths                  = a.paths or {}
		a.paths.tokens           = a.body_tokens
		a.paths.line_in_body     = duffle.build_body_line_index(a.body)
		a.paths.tok_class        = classify_tokens(a.paths.tokens)

		-- analyze_atom_paths fills the *cycles / branches / has_loops / unknown_macros* fields of a.paths.
		analyze_atom_paths(a)

		-- Run all per-atom checks on this one atom via the CHECK_RULES data table (Muratori: data over control flow).
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

	local errors   = {}
	local warnings = {}
	local info     = {}
	for _, f in ipairs(findings) do
		-- Per-finding severity is set by the check via `f.kind` ("error" or "warning"). 
		-- A `gte_pipeline_fill` finding can be either severity (errors for missing nops; warnings for unknown cmdw macros not in the latency table).
		-- Bin by `kind`, not by check name.
		if f.kind == "error" then errors  [#errors   + 1] = { line = f.line, msg = f.msg }
		else                      warnings[#warnings + 1] = { line = f.line, msg = f.msg }
		end
	end
	-- Per-source "scanned:" summary line. 
	-- Includes the source basename for traceability 
	-- (the old format was just "scanned: N atom bodies; M findings" which is unidentifiable when the module has multiple sources).
	-- Sources with 0 atoms (pure-header files like dsl.h, mips.h, etc.) are SKIPPED. 
	-- The per-module header already lists them in the "Sources:" section, and emitting a noisy "0 atom bodies" line per header is just clutter.
	if #atoms > 0 or #findings > 0 then
		info[#info + 1] = {
			line = 0,
			msg  = string.format("scanned: %s: %d atom bodies; %d findings",
				src.basename, #atoms, #findings),
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
		info[#info + 1] = {
			line = 0,
			msg  = string.format("cycles: path-aware min=%d max=%d across %d atoms; worst atom=%s (%d); best-case, no stalls; BD-slot nops absorbed into branch costs",
				total_min, total_max, #atoms, max_atom_name or "?", max_atom_cyc),
		}
	end

	return {
		atoms    = atoms,
		findings = findings,
		errors   = errors,
		warnings = warnings,
		info     = info,
	}
end

-- ════════════════════════════════════════════════════════════════════════════
-- Per-directory output: build/gen/<dir_basename>.static_analysis.txt
-- ════════════════════════════════════════════════════════════════════════════

--- Per-directory emit. Aggregates atoms + findings across every source in `dir_sources` 
--- and writes a single report to `<out_root>/<dir_basename>.static_analysis.txt`. 
--- Called only when at least one atom was found (the caller in M.run handles the skip).
local function emit_module_static_analysis_txt(ctx, dir, dir_sources, atoms, findings, errors, warnings, info)
	-- Module basename = last component of `dir` ("code/duffle" -> "duffle").
	local dir_basename = dir:match("([^/\\]+)$") or dir
	local out_path     = ctx.out_root .. "/" .. dir_basename .. ".static_analysis.txt"
	if ctx.dry_run then return out_path end
	duffle.ensure_dir(ctx.out_root)

	local lines = {}
	local function add(s) lines[#lines + 1] = s end

	add("========================================================")
	add("STATIC ANALYSIS PASS -- module " .. dir_basename)
	add("========================================================")
	add(string.format("Sources: %d", #dir_sources))
	for _, s in ipairs(dir_sources) do
		add("  " .. s.path)
	end
	add("")

	-- Tally atoms by kind for the header summary
	local n_atoms, n_bare, n_proc = 0, 0, 0
	for _, a in ipairs(atoms) do
		n_atoms = n_atoms + 1
		if     a.kind == "comp_bare" then n_bare = n_bare + 1
		elseif a.kind == "comp_proc" then n_proc = n_proc + 1
		end
	end
	local header_atoms = string.format("Atoms: %d", n_atoms)
	if n_bare > 0 or n_proc > 0 then
		header_atoms = header_atoms .. string.format("  (atoms: %d, comp_bare: %d, comp_proc: %d)",
			n_atoms - n_bare - n_proc, n_bare, n_proc)
	end
	add(string.format("%s   Findings: %d   Errors: %d   Warnings: %d",
		header_atoms, #findings, #errors, #warnings))
	add("")

	-- Group findings by atom (with source prefix when multi-source module)
	local multi_source = #dir_sources > 1
	local by_atom      = {}
	for _, f in ipairs(findings) do
		by_atom[f.atom] = by_atom[f.atom] or {}
		by_atom[f.atom][#by_atom[f.atom] + 1] = f
	end

	if next(by_atom) == nil then
		add("  (no findings -- every atom passed all checks)")
	else
		add("── Findings by atom ─────────────────────────────────────")
		for _, a in ipairs(atoms) do
			local fs = by_atom[a.name]
			if fs then
				local label = a.name
				if multi_source and a.source_path then
					label = string.format("%s  (%s)", a.name, a.source_path:match("([^/\\]+)$") or a.source_path)
				end
				add(string.format("  %s   line %d", label, a.line))
				for _, f in ipairs(fs) do
					add(string.format("      [%s] %s", f.check, f.msg))
				end
			end
		end
	end

	add("")
	add("── Errors ──────────────────────────────────────────────")
	if #errors == 0 then add("  (none)") end
	for _, e in ipairs(errors) do
		add(string.format("  X line %d  %s", e.line, e.msg))
	end

	add("")
	add("── Warnings ────────────────────────────────────────────")
	if #warnings == 0 then add("  (none)") end
	for _, w in ipairs(warnings) do
		add(string.format("  ! line %d  %s", w.line, w.msg))
	end

	-- Per-atom cycle counts (path-aware). For each atom:
	--   min   = shortest path through the body (earliest exit)
	--   max   = longest path through the body (full fall-through)
	--   br    = number of branch instructions
	--   paths = number of distinct paths reached
	-- Both min and max are best-case (no stalls); BD-slot nops are absorbed into branch costs (MIPS semantics).
	add("")
	add("── Per-atom cycle counts (path-aware, best case, no stalls) ─")
	if #atoms == 0 then
		add("  (no atoms)")
	else
		-- Sort atoms by max cycles descending for quick scanning.
		local sorted = {}
		for _, a in ipairs(atoms) do sorted[#sorted + 1] = a end
		table.sort(sorted, function(x, y) return ((x.paths or {}).cycles_max or 0) > ((y.paths or {}).cycles_max or 0) end)
		for _, a in ipairs(sorted) do
			local p           = a.paths or {}
			local br_count    = p.branches or 0
			local path_count  = p.paths or 0
			local loops_tag   = p.has_loops and "  [loop!]" or ""
			local unknown_tag = ""
			if p.unknown_macros and #p.unknown_macros > 0 then
				unknown_tag = string.format("  [unknown: %s]",
					table.concat(p.unknown_macros, ", "))
			end
			local name_label = a.name
			if multi_source and a.source_path then
				name_label = string.format("%s  (%s)", a.name, a.source_path:match("([^/\\]+)$") or a.source_path)
			end
			if br_count > 0 then
				add(string.format("  %-44s  min=%4d  max=%4d  br=%d  paths=%d  (line %d)%s%s",
					name_label, p.cycles_min or 0, p.cycles_max or 0, br_count, path_count,
					a.line, loops_tag, unknown_tag))
			else
				add(string.format("  %-44s  %4d cycles  (line %d, no branches)%s%s",
					name_label, p.cycles_min or 0, a.line, loops_tag, unknown_tag))
			end
		end
	end

	add("")
	add("── Per-source scan summary ──────────────────────────────")
	-- One line per source that contributed atoms.
	-- The line includes the source basename + per-source atom count + (if path-aware cycle data is present) the min..max cycle range.
	-- Sources with 0 atoms are skipped (they're just header files that declared no MipsAtom_ — they're already listed in the module's "Sources:" section above).
	for _, src in ipairs(dir_sources) do
		local src_atoms = {}
		for _, a in ipairs(atoms) do
			if a.source_path == src.path then
				src_atoms[#src_atoms + 1] = a
			end
		end
		if #src_atoms == 0 then
			goto continue
		end
		local atom_count = #src_atoms
		local mn, mx     = math.huge, -1
		for _, a in ipairs(src_atoms) do
			local p = a.paths or {}
			if (p.cycles_min or 0) < mn then mn = p.cycles_min or 0 end
			if (p.cycles_max or 0) > mx then mx = p.cycles_max or 0 end
		end
		local path_str
		if mx > 0 then
			path_str = string.format("  cycles=%d..%d", mn, mx)
		else
			path_str = string.format("  %d cycles", mn)
		end
		add(string.format("  %-30s  %d atom%s%s",
			src.basename, atom_count,
			atom_count == 1 and "" or "s",
			path_str))
		::continue::
	end

	-- Module-level findings summary (across all sources).
	local total_errs  = #errors
	local total_warns = #warnings
	add("")
	add(string.format("Module findings:  %d error(s), %d warning(s)", total_errs, total_warns))

	-- Per-source "scanned:" info lines (each line includes the source basename for traceability).
	if #info > 0 then
		add("")
		for _, i_ in ipairs(info) do
			add(string.format("  %s", i_.msg))
		end
	end

	duffle.write_file(out_path, table.concat(lines, "\n") .. "\n")
	return out_path
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

	-- Aggregate per-DIRECTORY (per-module).
	-- One static_analysis.txt per source-directory, emitted only if the directory contains at least one atom. 
	-- Empty-source directories (e.g. duffle headers with no atoms) produce no report.
	-- Group sources by `src.dir`. The first component of `dir` is the module name (e.g. "code/duffle" -> "duffle", "code/gte_hello" -> "gte_hello").
	-- Output path is `<out_root>/<module_basename>.static_analysis.txt`.
	local by_dir = ctx.by_dir or duffle.group_sources_by_dir(ctx.sources)

	for dir, dir_sources in pairs(by_dir) do
		-- Run validate() against every source in this directory; accumulate atoms / findings / errors / warnings. 
		-- The validate() function does its own per-source analysis (Binds indexing, atom discovery, all 5 checks) 
		-- and attaches path-aware cycle data to each atom it finds.
		local all_atoms    = {}
		local all_findings = {}
		local dir_errors   = {}
		local dir_warnings = {}
		local all_info     = {}
		for _, src in ipairs(dir_sources) do
			local result = validate(ctx, src)
			-- Tag each atom with its source so the render step can prefix the atom line with "<filename>:" 
			-- when atoms from multiple sources live in the same module (e.g. lottes_tape.h + atom_dsl.h both declaring atoms).
			for _, a in ipairs(result.atoms) do
				a.source_path = src.path
				all_atoms[#all_atoms + 1] = a
			end
			for _, f  in ipairs(result.findings) do all_findings[#all_findings + 1] = f  end
			for _, e  in ipairs(result.errors)   do dir_errors  [#dir_errors   + 1] = e  end
			for _, w  in ipairs(result.warnings) do dir_warnings[#dir_warnings + 1] = w  end
			for _, i_ in ipairs(result.info)     do all_info    [#all_info     + 1] = i_ end
		end

		-- Skip directories with zero atoms. A directory with only headers / no MipsAtom_ is "nothing to report".
		if #all_atoms == 0 then
			-- Still aggregate errors/warnings so orchestrator sees them, but don't write a file.
			for _, e in ipairs(dir_errors)   do errors  [#errors   + 1] = e end
			for _, w in ipairs(dir_warnings) do warnings[#warnings + 1] = w end
		else
			local out_path = emit_module_static_analysis_txt(ctx, dir, dir_sources, all_atoms, all_findings, dir_errors, dir_warnings, all_info)
			if out_path then
				table.insert(outputs, { static_analysis_txt = out_path })
			end
			for _, e in ipairs(dir_errors)   do errors  [#errors   + 1] = e end
			for _, w in ipairs(dir_warnings) do warnings[#warnings + 1] = w end
		end
	end

	return { outputs = outputs, errors = errors, warnings = warnings }
end

return M
