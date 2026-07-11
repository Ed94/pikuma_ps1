--- passes/static_analysis.lua — Per-atom static-analysis checks.
---
--- The 5 checks currently shipped:
---   1. **GTE pipeline-fill** — every `gte_cmdw_*` invocation must be preceded by the minimum number of `nop` words
---      (per `duffle.GTE_PIPELINE_LATENCY`) so the COP2 pipeline latency is fully retired before the command issues.
---   2. **mac_yield uniformity** — every atom body must contain exactly one `mac_yield()` call (control transfer pattern).
---   3. **ABI handoff** — every `atom_bind(Binds_X)` must reference a `typedef Struct_(Binds_X) { ... }` declaration.
---   4. **GPU port-store shape** — per-shape (`f3`/`f4`/`g4`/etc.) the sum of `mac_format_X_color` + `mac_gte_store_X_*` +
---      `mac_insert_ot_tag_X` words must equal the GP0 cmd's expected packet size.
---   5. **per-atom cycle budget** — sum each atom body's instruction latencies (per `duffle.INSTRUCTION_LATENCY`); report total.
---
--- The orchestrator (`ps1_meta.lua`) wires this module in via the
--- PASSES table:
---   `["static-analysis"] = { module = "passes.static_analysis", kind = "validation", deps = {"word-counts", "components"},
---     out = { { kind = "report", path_template = "<out_root>/<basename>.static_analysis.txt" } } }`
---
--- **Conventions**: tabs (1/level), EmmyLua annotations, no regex, Lua 5.3 compatible. See `lua.md` in the ps1-ai styleguides.

-- ════════════════════════════════════════════════════════════════════════════
-- Module-scope requires + package.path setup
-- ════════════════════════════════════════════════════════════════════════════

-- Bootstrap: load `scripts/duffle_paths.lua` (sets package.path + package.cpath).
-- Uses `debug.getinfo` to find this file's own directory, so it works both standalone and when require'd from the orchestrator.
-- Bootstrap: load `duffle_paths.lua` via `debug.getinfo(1, "S").source` (works both standalone + when require'd).
-- duffle_paths.lua sets package.path then returns `require("duffle")` at the bottom, so the dofile value IS the duffle module.
local _bootstrap_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local duffle        = dofile(_bootstrap_dir .. "../duffle_paths.lua")

-- ════════════════════════════════════════════════════════════════════════════
-- Constants
-- ════════════════════════════════════════════════════════════════════════════

-- Atom declaration + component declaration identifiers.
local ATOM_DECL        = "MipsAtom_"
local ATOM_COMP        = "MipsAtomComp_"
local ATOM_COMP_PROC   = "MipsAtomComp_Proc_"

-- Marker-call identifiers inside atom bodies.
local ATOM_LABEL       = "atom_label"
local ATOM_OFFSET      = "atom_offset"
local ATOM_INFO        = "atom_info"
local ATOM_BIND        = "atom_bind"
local ATOM_READS       = "atom_reads"
local ATOM_WRITES      = "atom_writes"
local ATOM_YIELD       = "mac_yield"
local WORD_COUNT_PRAGMA = "WORD_COUNT("

-- ASCII byte values used in tokenization.
local BYTE_NEWLINE      = 10
local BYTE_HASH         = 35   -- '#'
local BYTE_OPEN_PAREN   = 40
local BYTE_OPEN_BRACE   = 123
local BYTE_OPEN_BRACK   = 91
local BYTE_SEMI         = 59

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

--- @alias AtomName    string  -- lower_snake_case atom name
--- @alias MacroName   string  -- lower_snake_case macro identifier
--- @alias CheckName   string  -- "gte_pipeline_fill" | "mac_yield_uniformity" | "abi_handoff" | "gpu_port_store_shape" | "per_atom_cycle_budget"

--- @class AtomBody
--- @field line     integer  -- source line of the atom declaration
--- @field name     AtomName -- atom name (e.g. "cube_g4_face")
--- @field body     string   -- the brace-delimited body (without the braces)
--- @field body_off integer  -- char offset of body[1] in source
--- @field kind     string   -- "atom" | "comp_bare" | "comp_proc"

--- @class Token
--- @field tok      string  -- the raw token text (trimmed)
--- @field line     integer -- source line of the token's start
--- @field ident    string|nil -- the leading ident of the token (if any)
--- @field kind     string  -- "n_words" | "mac_yield" | "gte_cmdw" | "mac_format" | "mac_gte_store" | "mac_insert_ot_tag" | "atom_label" | "atom_offset" | "other"

--- @class Finding
--- @field line     integer  -- source line of the finding
--- @field atom     AtomName -- the atom this finding is for (or "")
--- @field check    CheckName -- the check identifier
--- @field kind     string   -- "error" | "warning" | "info"
--- @field msg      string   -- the finding message

--- @class AtomAnalysis
--- @field atom       AtomBody
--- @field tokens     Token[]     -- the tokens in the atom body, annotated
--- @field findings   Finding[]   -- findings for this atom
--- @field total_cycles integer   -- sum of token cycle costs

-- ════════════════════════════════════════════════════════════════════════════
-- Source scanning — delegated to duffle.scan_source (ps1_meta.lua pre-scans)
-- ════════════════════════════════════════════════════════════════════════════
--
-- The orchestrator calls duffle.scan_source once per source and stashes the fat SourceScan in src.scan.
-- validate() below reads from src.scan — no source walking in this pass.

-- ════════════════════════════════════════════════════════════════════════════
-- Body tokenizer (top-level comma splitter + per-token classification)
-- ════════════════════════════════════════════════════════════════════════════

--- Build a map: `body_relative_char_offset` -> `body_relative_line`.
--- Used by the checks to convert per-token offsets in the body to lina numbers relative to the start of `body`. 
--- The atom's source-line of the body-start is added by the caller.
---
-- Memoization cache for build_body_line_index / tokenize_body.
-- Atom bodies are immutable for the duration of a validate() pass (they come from src.scan which is set once by scan-source),
-- so the same body string is safe to use as a cache key. Each call site (5 check_* functions + analyze_atom_paths)
-- was re-running the full O(body_len) scan on the SAME body. After memoization, the first call pays the O(body_len) cost,
-- every subsequent call on the same body returns the cached table in O(1).
--
-- (Future-proofing: if a caller ever mutates the returned tokens / line-index tables, the cache aliasing means those
-- mutations would leak across atoms. Current callers all read-only; safe today.)
local _body_line_index_cache = {}
local _tokenize_body_cache    = {}

--- Simple line-counting: count `\n` chars from offset 1 up to the offset; that count + 1 is the line number (1-based).
local function build_body_line_index(body)
	if _body_line_index_cache[body] ~= nil then return _body_line_index_cache[body] end
	local index = {}
	local len = #body
	local newline_count = 0
	for pos = 1, len do
		if pos > 1 then
			index[pos] = newline_count + 1   -- line of `pos` relative to body
		end
		if body:byte(pos) == 10 then        -- '\n'
			newline_count = newline_count + 1
		end
	end
	-- Offsets beyond the body still resolve to the final line
	index[len + 1] = newline_count + 1
	_body_line_index_cache[body] = index
	return index
end

--- Count of COP2-nop words contributed by a single top-level token.
--   `nop`            -> 1
--   `nop2`           -> 2 (i.e. `nop, nop` baked into one asm word)
--   `nop,` / `nop2,` -> same as above; strip trailing comma defensively
--   anything else    -> 0
--
-- (Branch-delay-slot nops like `branch_*(..., nop)` are tokenized separately by split_top_level_commas: 
-- The branch arg ends before the trailing comma, and `nop` becomes its own token. 
-- So no special handling is needed here.)
local function nop_word_count(token)
	local s = duffle.trim(token)
	-- Strip trailing comma(s) (defensive against raw text via, but our tokenize_body already strips them; this is a safety net)
	s = s:gsub(",$", "")
	s = duffle.trim(s)
	if s == "nop"  then return 1 end
	if s == "nop2" then return 2 end
	return 0
end

--- Tokenize the body inner-text into a flat list of `(token, body_rel_offset)`
--- pairs (nested parens/braces/brackets are honored; comments and strings are skipped). 
--- `body_rel_offset` is the char offset within `body` of the start of the token. 
--- Callers add it to the atom's `body_off` to get an absolute source position for line tracking.
local function tokenize_body(body)
	if _tokenize_body_cache[body] ~= nil then return _tokenize_body_cache[body] end
	local out = {}
	local len     = #body
	local rel     = 1
	while rel <= len do
		-- Find next non-whitespace, non-comment start
		local ws_end = duffle.skip_ws_and_cmt(body, rel)
		if ws_end > rel then
			rel = ws_end
		end
		if rel > len then break end

		-- Find comma/newline/semicolon after this token.
		-- Read balanced groups so commas inside parens/braces/brackets aren't treated as separators.
		-- Comments / strings are skipped.
		local scan = rel
		while scan <= len do
			local c = body:byte(scan)
			if     c == 44            then break end               -- ','
			if     c == 10            then break end               -- '\n'
			if     c == 59            then break end               -- ';'
			if     c == 40            then local _, a = duffle.read_parens    (body, scan); scan = a -- '('
			elseif c == 123           then local _, a = duffle.read_braces    (body, scan); scan = a -- '{'
			elseif c == 91            then local _, a = duffle.read_brackets  (body, scan); scan = a -- '['
			elseif c == 34 or c == 39 then scan       = duffle.skip_str_or_cmt(body, scan) + 1       -- '"' or '\''
			else
				scan = scan + 1
			end
		end
		-- Extract token [rel .. scan-1]
		local tok = duffle.trim(body:sub(rel, scan - 1))
		if    tok ~= "" then
			out[#out + 1] = { tok = tok, rel = rel }
		end
		-- Move past the separator
		if scan <= len then
			 scan = scan + 1
			-- Also skip whitespace before next token
			local w = duffle.skip_ws_and_cmt(body, scan)
			if    w > scan then scan = w end
		end
		rel = scan
	end
	_tokenize_body_cache[body] = out
	return out
end

-- ════════════════════════════════════════════════════════════════════════════
-- Check #1: GTE pipeline-fill
-- ════════════════════════════════════════════════════════════════════════════

-- Count consecutive nop words immediately BEFORE token index `ti` in the token list.
-- Walks backwards from ti-1, accumulating nop_word_count, stopping at the first non-nop.
-- scan: nop, nop, <non-nop> -> have = count of nop words before ti
local function count_preceding_nops(tokens, ti)
	local have = 0
	local where_ti = ti - 1
	while where_ti >= 1 do
		local n = nop_word_count(tokens[where_ti].tok)
		if n == 0 then break end
		have = have + n
		where_ti = where_ti - 1
	end
	return have
end

-- Check a single gte_cmdw_* token for pipeline-fill compliance. 
-- Emits a finding if the preceding nops are insufficient (error) or the macro isn't in the latency table (warning).
-- scan: <nop>... <gte_cmdw_X> -> validate nop count vs GTE_PIPELINE_LATENCY[X]
local function check_one_gte_cmdw(a, tok, tokens, ti, line_in_body, findings)
	local cmdw_full = tok:match("^(gte_cmdw_[%w_]+)%s*[,%)]") or tok:match("^(gte_cmdw_[%w_]+)%s*$")
	if not cmdw_full then return end

	local variant = cmdw_full:match("^gte_cmdw_(.+)$")
	local need    = duffle.GTE_PIPELINE_LATENCY[cmdw_full]
	local line    = a.line + line_in_body[tokens[ti].rel]

	if need == nil then
		-- alias or new gte_cmdw_<X> not yet in latency table
		findings[#findings + 1] = {
			atom  = a.name,
			line  = line,
			check = "gte_pipeline_fill",
			kind  = "warning",
			msg   = string.format(
				"%s at line %d uses `gte_cmdw_%s` but that macro is not in duffle.GTE_PIPELINE_LATENCY -- add a min_nops entry",
				a.name, line, variant),
		}
	elseif need > 0 then
		local have = count_preceding_nops(tokens, ti)
		if have < need then
			findings[#findings + 1] = {
				atom  = a.name,
				line  = line,
				check = "gte_pipeline_fill",
				kind  = "error",
				msg   = string.format(
					"%s at line %d needs %d nop word%s immediately BEFORE `gte_cmdw_%s`; only %d found",
					a.name, line, need, need == 1 and "" or "s", variant, have),
			}
		end
	end
end

--- Walk the token list. Whenever we hit a `gte_cmdw_<X>` token, count consecutive nop words immediately preceding it.
--- If count < the minimum declared in `duffle.GTE_PIPELINE_LATENCY[X]`, record a finding.
--- Aliases are resolved against the lookup table directly; if a macro name is not in the table, emit a soft warning 
--- (the user might have added a new gte_cmdw_* but not updated duffle.lua).
--- Per-atom: walk this atom's tokens, check every `gte_cmdw_*` for pipeline-fill compliance.
--- Signature changed from `(atoms, findings)` to `(atom, findings)` in Stage 1B of the plex move:
--- the per-atom iteration now lives in validate()'s single loop; each check is a per-atom predicate.
local function check_gte_pipeline_fill(atom, findings)
	local tokens       = tokenize_body(atom.body)
	local line_in_body = build_body_line_index(atom.body)
	local tn = #tokens
	local ti = 1
	while ti <= tn do
		check_one_gte_cmdw(atom, tokens[ti].tok, tokens, ti, line_in_body, findings)
		ti = ti + 1
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
local function check_mac_yield_uniformity(atom, findings)
	-- Per-kind semantics:
	--   MipsAtom_          (baked atom): exactly 1 mac_yield at the end of the body. Control transfer is the atom's job.
	--   MipsAtomComp_      (bare static-array component): ZERO mac_yield.
	--                      The component is invoked from inside an atom body; the parent atom does the yield.
	--   MipsAtomComp_Proc_ (procedural component): ZERO mac_yield.
	--                      Same reasoning -- it's a function returning a MipsAtom slice, invoked from a parent atom.
	--
	-- The GTE pipeline-fill check applies to all 3 kinds (see check_gte_pipeline_fill). Only the mac_yield rule branches on kind.
	local tokens = tokenize_body(atom.body)
	local line_in_body = build_body_line_index(atom.body)

	local count    = 0
	local last_idx = 0
	for tok_idx, t in ipairs(tokens) do
		local tok = t.tok
		-- Match `mac_yield(...)` or just `mac_yield`. The bareword
		-- variant is rare in modern style but tolerated.
		if tok:match("^mac_yield%s*%(") or tok == "mac_yield" then
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
		elseif last_idx < #tokens then
			-- 1 call, but not the last token. We DON'T fail if the post-token is just `nop` or `nop2` or a branch with `, nop` delay slot.
			-- It's the standard "yield, then BD nop" idiom.
			local post_non_nop = false
			for search_idx = last_idx + 1, #tokens do
				local t = tokens[search_idx].tok
				if    t ~= "" and t ~= "nop" and t ~= "nop2"
				   and not t:match("%,%s*nop%)%s*$") then
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
	local tokens             = tokenize_body(atom.body)
	local line_in_body       = build_body_line_index(atom.body)
	local found_field_set = {}
	local found_advance   = false
	local bind_re         = "O_%(" .. binds_name .. ",%s*([%w_]+)%s*%)"
	for _, t in ipairs(tokens) do
		local tok = t.tok
		if tok:match("^load_word%s*%(") then
			if tok:find("R_TapePtr", 1, true) and tok:find("O_(" .. binds_name .. ",", 1, true) then
				local field = tok:match(bind_re)
				-- scan: load_word(R_*, R_TapePtr, O_(<Binds_X>, <field>))
				if field then
					found_field_set[field] = true
				else
					local body_line = atom.line + line_in_body[t.rel]
					findings[#findings + 1] = {
						atom  = atom.name, line = body_line,
						check = "abi_handoff", kind = "error",
						msg   = string.format("%s at line %d has load_word(R_TapePtr, O_(%s, <non-ident>)); expected O_(%s, <field>)",
							atom.name, body_line, binds_name, binds_name),
					}
				end
			end
		end
		if tok:find("R_TapePtr", 1, true)
		   and tok:find("S_(" .. binds_name .. ")", 1, true) then
			-- scan: add_ui_self(R_TapePtr, S_(<Binds_X>))
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
				atom.name, atom.line, binds_name, binds_name, binds.bytes, binds.bytes / 4),
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
--- Per-atom: detect which GP0 primitive the atom is emitting, sum the macro contributions,
--- compare to the expected packet size. Signature changed in Stage 1B: `(atom, findings)`.
local function check_gpu_portstore_shape(atom, findings)
	if atom.kind ~= "atom" then return end
	local tokens = tokenize_body(atom.body)
	local line_in_body = build_body_line_index(atom.body)
	local cmd_byte = nil
	local cmd_line = nil
	local contrib = 0
	local saw_format = false
	local saw_prim_write = false
	for _, t in ipairs(tokens) do
		local tok = t.tok
		-- Match `mac_format_<shape>_color(...)` and strip `_color`
		-- to get the bare shape suffix (f3 / g4 / etc).
		local shape = tok:match("^mac_format_([%w_]+)_color%s*%(") or tok:match("^mac_format_([%w_]+)_color%s*$")
		if shape and duffle.GP0_CMD_BY_SHAPE[shape] then
			if not cmd_byte then
				cmd_byte = duffle.GP0_CMD_BY_SHAPE[shape]
				cmd_line = atom.line + line_in_body[t.rel]
			end
			saw_format = true
			local contrib_key = "mac_format_" .. shape .. "_color"
			local n = duffle.GP0_MACRO_CONTRIB[contrib_key]
			if    n then contrib = contrib + n end
		end
		local gte_store = tok:match("^mac_gte_store_[%w_]+")
		if gte_store then
			local n = duffle.GP0_MACRO_CONTRIB[gte_store]
			if    n then contrib = contrib + n end
		end
		local ot_tag = tok:match("^mac_insert_ot_tag_([%w_]+)")
		if ot_tag then
			local n = duffle.GP0_MACRO_CONTRIB["mac_insert_ot_tag_" .. ot_tag]
			if    n then contrib = contrib + n end
		end
		if tok:match("^store_word%s*%(") and tok:find("R_PrimCursor", 1, true) then
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
-- Check #5: per-atom cycle budget
-- ════════════════════════════════════════════════════════════════════════════

--- Compute the cycle cost of one token. The token is a string like
--- `add_ui(R_T0, R_T1, 4)` or `nop2` or `gte_cmdw_rtpt`. Returns:
---   cycles       - integer cycle cost (from duffle.INSTRUCTION_LATENCY, or duffle.UNKNOWN_INSTRUCTION_CYCLES if not in the table)
---   macro_name   - the bare ident (e.g. `add_ui`, `gte_cmdw_rtpt`, `nop2`, `mac_yield`)
---   unknown      - true iff the macro wasn't in duffle.INSTRUCTION_LATENCY. 
--- The function strips trailing `()` from function-call style macros so `mac_yield()` and `mac_yield` resolve identically.
local function token_cycles(tok)
	-- Extract the leading ident. Tolerate `(...)` args.
	local ident = tok:match("^([%w_]+)")
	if not ident then return duffle.UNKNOWN_INSTRUCTION_CYCLES, "?", true end
	local cost = duffle.INSTRUCTION_LATENCY[ident]
	if    cost == nil then
		return duffle.UNKNOWN_INSTRUCTION_CYCLES, ident, true
	end
	return cost, ident, false
end

--- Find every `atom_label(name)` token in the token list and return a map `label_name -> token_idx`. Labels are 0-cost markers; 
--- the path walker uses them as branch targets.
local function find_atom_labels(tokens)
	local labels = {}
	for tok_idx, t in ipairs(tokens) do
		local name = t.tok:match("^atom_label%s*%(%s*([%w_]+)%s*%)")
		if name then labels[name] = tok_idx end
	end
	return labels
end

--- Find every `branch_*(...)` token in the token list and return a map `token_idx -> label_name|false`. 
--- If the branch's args contain an `atom_offset(F, label)` call, the label name is recorded; otherwise the branch's target is unknown
--- (likely a literal offset) and we record `false` as a sentinel. 
--- The CFG walker checks KEY PRESENCE (via `is_branch(tok_idx)`) to decide whether a token is a branch; it checks the value
--- to decide whether the taken-path target is known. 
--- (We can't use `nil` for the unknown-target case because `targets[tok_idx] = nil` REMOVES the key from the Lua table, 
--- which would make `is_branch(tok_idx)` return false for both "not a branch" and "branch with unknown target".)
local function find_branch_targets(tokens)
	local targets = {}
	for tok_idx, t in ipairs(tokens) do
		if t.tok:match("^branch_[%w_]+%s*%(") then
			-- branch_<cond>(rs, atom_offset(F, label))   or
			-- branch_<cond>(rs, rt, atom_offset(F, label))
			-- atom_offset's arg list is (flag, name); we want the name.
			local label      = t.tok:match("atom_offset%s*%([^,]+,%s*([%w_]+)%s*%)")
			targets[tok_idx] = label or false  -- `false` = known branch, unknown target
		end
	end
	return targets
end

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
	local tokens   = tokenize_body(atom.body)
	local labels   = find_atom_labels(tokens)
	local branches = find_branch_targets(tokens)

	-- Pre-compute per-token cycle costs and identify terminators.
	local n           = #tokens
	local costs       = {}
	local unknown_set = {}
	for tok_idx, t in ipairs(tokens) do
		local c, _, unknown = token_cycles(t.tok)
		costs[tok_idx] = c
		if unknown then
			unknown_set[t.tok:match("^([%w_]+)") or "?"] = true
		end
	end

	-- A token is a terminator if it's `mac_yield` or `mac_yield(...)`. 
	-- The yield transfers control; we don't count its cost (the next atom's prologue absorbs it).
	local function is_terminator(tok_idx)
		local  tok = tokens[tok_idx].tok
		return tok == "mac_yield" or tok:match("^mac_yield%s*%(")
	end

	-- CFG successor function. Returns a list of next token indices for the given position. 
	-- Branch tokens produce 2 successors (fall-through + taken); normal tokens produce 1 (next); terminators produce 0.
	-- BD-slot absorption: a branch at tok_idx skips tok_idx+1 (the BD slot) in its fall-through path; 
	-- the BD slot's cost is added to the branch's own cost instead (so it's counted once).
	--
-- A token is a "branch" if its index is a KEY in the `branches` map 
-- (regardless of whether the value is nil — a branch with nil target means "literal offset, taken path is unknown").
-- We check key-presence via `branches[tok_idx] ~= nil` because `branches[tok_idx]` returns nil for both "absent" AND "present with nil value".
-- Distinguishing them requires the key check.
	local function is_branch(tok_idx)
		local v = branches[tok_idx]
		if    v == nil then return false end
		-- v is non-nil: either a string (atom_offset target) or false (literal offset, no target). Both indicate a branch.
		return true
	end
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
			-- Return (succ, nil) -- the second value is the terminator marker (nil = not a terminator).
			return succ, nil
		end
		-- Normal token: just the next one
		if tok_idx + 1 <= n then
			return { tok_idx + 1 }, nil
		end
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
	if cycles_max == -1 then cycles_max = 0 end

	local unknown_list = {}
	for macro_name in pairs(unknown_set) do unknown_list[#unknown_list + 1] = macro_name end
	table.sort(unknown_list)

	-- branch_count: number of `branch_*(...)` tokens.
	local branch_count = 0
	for _ in pairs(branches) do branch_count = branch_count + 1 end

	-- Mutate the pre-allocated `atom.paths` slot in place (caller owns the table).
	-- Mega-struct move: a single source of truth for all per-atom path-analysis data,
	-- instead of returning a fresh table that would just get copied onto 5 atom fields.
	-- If a caller ever DIDN'T pre-allocate (legacy code path), fall back to a fresh slot.
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
--- Reuses `analyze_atom_paths`'s per-atom unknown_macros discovery (it's the canonical place that walks tokens
--- and computes per-token cycle costs). We just sort + emit.
--- Per-atom: emit one finding per unknown macro seen, deduplicated across atoms (so the warning
--- section doesn't get spammed with N copies of "macro X not in duffle.INSTRUCTION_LATENCY").
--- Reuses `analyze_atom_paths`'s per-atom unknown_macros discovery (it's the canonical place that walks tokens
--- and computes per-token cycle costs). We just sort + emit.
--- Signature changed in Stage 1B: `(atom, pipe_ctx, findings)` — the `unknown_seen` dedup table lives on
--- `pipe_ctx` so it persists across the per-atom loop in validate().
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
	-- Pre-allocated here, mutated by each per-atom check call below. Replaces the per-check
	-- local tables that used to live inside each check_* function body.
	--   info_by_atom  — atom_name -> atom_info (built once; check_abi_handoff reads it)
	--   binds_index   — Binds_X -> binds struct (built once; check_abi_handoff reads it)
	--   unknown_seen  — macro_name -> first atom line (accumulated across atoms; check_per_atom_cycle_budget dedups)
	local info_by_atom = {}
	for _, info in ipairs(atom_infos) do
		info_by_atom[info.atom_name] = info
	end
	local pipe_ctx = {
		info_by_atom  = info_by_atom,
		binds_index   = binds_index,
		unknown_seen  = {},
	}

	-- THE per-atom pipeline. ONE iteration of atoms; the 5 check_* functions + analyze_atom_paths
	-- all run here, sharing a single tokenize_body + build_body_line_index per body.
	-- Plex move: every piece of state derived from an atom body lives on `atom.paths` (the per-atom mega-struct);
	-- readers (analyze_atom_paths, the 5 checks, the renderers) all consume `atom.paths`, not the raw `atoms` list.
	-- Stage 1B: each check_* now takes `(atom, ...)` instead of `(atoms, findings)` — no more single-atom `{a}` shim.
	local findings = {}
	for _, a in ipairs(atoms) do
		a.paths                  = a.paths or {}
		a.paths.tokens           = tokenize_body(a.body)
		a.paths.line_in_body     = build_body_line_index(a.body)

		-- analyze_atom_paths fills the *cycles / branches / has_loops / unknown_macros* fields of a.paths.
		analyze_atom_paths(a)

		-- Run all 5 checks on this one atom. Each is now a per-atom predicate.
		check_gte_pipeline_fill(a, findings)
		check_mac_yield_uniformity(a, findings)
		check_abi_handoff(a, pipe_ctx, findings)
		check_gpu_portstore_shape(a, findings)
		check_per_atom_cycle_budget(a, pipe_ctx, findings)
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
	local by_atom = {}
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

	-- Aggregate per-DIRECTORY (per-module). One static_analysis.txt per source-directory, emitted only if the directory contains at least one atom. 
	-- Empty-source directories (e.g. duffle headers with no atoms) produce no report.
	--
	-- Group sources by `src.dir`. The first component of `dir` is the module name (e.g. "code/duffle" -> "duffle", "code/gte_hello" -> "gte_hello").
	-- Output path is `<out_root>/<module_basename>.static_analysis.txt`.
	local by_dir = duffle.group_sources_by_dir(ctx.sources)

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
