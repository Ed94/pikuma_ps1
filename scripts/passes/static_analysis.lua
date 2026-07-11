--- passes/static_analysis.lua — Per-atom static-analysis checks.
---
--- The 5 checks currently shipped:
---   1. **GTE pipeline-fill** — every `gte_cmdw_*` invocation must be
---      preceded by the minimum number of `nop` words (per
---      `duffle.duffle.GTE_PIPELINE_LATENCY`) so the COP2 pipeline latency is
---      fully retired before the command issues.
---   2. **mac_yield uniformity** — every atom body must contain exactly
---      one `mac_yield()` call (control transfer pattern).
---   3. **ABI handoff** — every `atom_bind(Binds_X)` must reference a
---      `typedef Struct_(Binds_X) { ... }` declaration.
---   4. **GPU port-store shape** — per-shape (`f3`/`f4`/`g4`/etc.) the
---      sum of `mac_format_X_color` + `mac_gte_store_X_*` +
---      `mac_insert_ot_tag_X` words must equal the GP0 cmd's expected
---      packet size.
---   5. **per-atom cycle budget** — sum each atom body's instruction
---      latencies (per `duffle.duffle.INSTRUCTION_LATENCY`); report total.
---
--- The orchestrator (`ps1_meta.lua`) wires this module in via the
--- PASSES table:
---   `["static-analysis"] = { module = "passes.static_analysis",
---                            kind   = "validation",
---                            deps   = {"word-counts", "components"},
---                            out    = { { kind = "report",
---                                         path_template = "<out_root>/<basename>.static_analysis.txt" } } }`
---
--- **Conventions**: tabs (1/level), EmmyLua annotations, no regex,
--- Lua 5.3 compatible. See
--- `C:\projects\Pikuma\ps1-ai\conductor\code_styleguides\lua.md`.

-- ════════════════════════════════════════════════════════════════════════════
-- Module-scope requires + package.path setup
-- ════════════════════════════════════════════════════════════════════════════

-- `duffle.setup_package_path()` resolves `arg[0]` and prepends `scripts/`
-- (and `scripts/passes/`) to `package.path`, so `require("duffle")`
-- resolves regardless of CWD. See `duffle.lua` for the implementation.

-- Bootstrap: see `ps1_meta.lua` for the rationale.
-- Bootstrap: load `scripts/duffle_paths.lua` (sets package.path + package.cpath).
-- Uses `debug.getinfo` to find this file's own directory, so it works
-- both standalone and when require'd from the orchestrator.
local _src = debug.getinfo(1, "S").source:sub(2)
local _dir = _src:match("(.*[/\\])") or "./"
dofile(_dir .. "../duffle_paths.lua")
local duffle = require("duffle")

-- Domain tables (single source of truth in duffle.lua).






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
--- @field total_cycles integer   -- sum of token cycle costs (Phase 3)

-- ════════════════════════════════════════════════════════════════════════════
-- Source walkers
-- ════════════════════════════════════════════════════════════════════════════

--- Walk source-as-written, return a list of `{line, name, body,
--- body_off, kind}` for every:
---   `MipsAtom_(name) { body };`               -> kind = "atom"     (baked atom)
---   `MipsAtomComp_(name) { body };`           -> kind = "comp_bare" (static-array component)
---   `MipsAtomComp_Proc_(name, { body })`     -> kind = "comp_proc" (procedural component)
---
--- All three forms are recognized because the user explicitly uses
--- both bare components (e.g. `ac_gte_store_f3_post_rtpt`) and
--- procedural components (e.g. `ac_format_f3_color(r, g, b)`) inside
--- atom bodies. The two component forms generate macro equivalents
--- (in gen/duffle.macs.h) that atoms call via `mac_*` -- so the parent
--- atom body is what needs the GTE pipeline-fill + mac_yield checks.
--- The component bodies themselves don't need mac_yield (control
--- transfer is the parent atom's job) but they DO need pre-fill nops
--- before any gte_cmdw_X they contain.
---
--- Comments / strings inside `name` and `body` are tolerated; `body`
--- is the raw brace inner text (with surrounding whitespace, no
--- leading/trailing `{` `}`). `body_off` is the character offset of
--- `body[1]` in `source_text`, used to compute per-token line numbers
--- later.
local function find_atom_bodies(source_text)
	local line_of  = duffle.LineIndex(source_text)
	local out      = {}
	local src_len = #source_text
	local pos      = 1
	while pos <= src_len do
		pos = duffle.skip_ws_and_cmt(source_text, pos); if pos > src_len then break end
		-- Skip preprocessor directives (#define / #include / #pragma /
		-- etc). Otherwise the `#define MipsAtom_(sym) ...` definition
		-- in lottes_tape.h gets matched as an atom named "sym" and
		-- its `body` swallows the next real atom declaration via
		-- duffle.scan_to_char("{", ...).
		if source_text:sub(pos, pos) == "#" then
			local eol_pos = pos
			while eol_pos <= src_len and source_text:byte(eol_pos) ~= 10 do eol_pos = eol_pos + 1 end
			pos = eol_pos + 1
		else
			local ident, ident_end = duffle.read_ident(source_text, pos)
		if not ident then
			pos = pos + 1
		elseif ident == "MipsAtom_"
		    or ident == "MipsAtomComp_"
		    or ident == "MipsAtomComp_Proc_" then
			-- Determine the kind from the exact ident (3 distinct macros,
			-- each with its own kind).
			local kind
			if     ident == "MipsAtom_"             then kind = "atom"
			elseif ident == "MipsAtomComp_"         then kind = "comp_bare"
			else                                         kind = "comp_proc"
			end

			local open_paren = duffle.skip_ws_and_cmt(source_text, ident_end)
			if source_text:sub(open_paren, open_paren) ~= "(" then
				pos = open_paren + 1
			else
				local inner, after_paren = duffle.read_parens(source_text, open_paren)

				if kind == "comp_proc" then
					-- MipsAtomComp_Proc_(sym, { body })
					-- The body is inside the LAST `{ ... }` in the args
					-- (the macro takes 2 args: sym name, then body in {}).
					-- Find the last `{` in `inner`, then the matching `}`.
					local last_brace_pos
					for search_pos = #inner, 1, -1 do
						if inner:sub(search_pos, search_pos) == "{" then last_brace_pos = search_pos; break end
					end
					if not last_brace_pos then
						pos = open_paren + 1
					else
						-- Walk forward to find matching `}` honoring balanced
						-- ()/[] and strings. We could call duffle.read_braces
						-- from last_brace_pos+1, but read_braces expects to start at
						-- the brace itself. Inline the walk for clarity.
						local depth = 1
						local inner_pos = last_brace_pos + 1
						while inner_pos <= #inner and depth > 0 do
							local c = inner:byte(inner_pos)
							if c == 123 then
								depth = depth + 1; inner_pos = inner_pos + 1
							elseif c == 125 then
								depth = depth - 1
								if depth == 0 then break end
								inner_pos = inner_pos + 1
							elseif c == 40 then
								local _, a = duffle.read_parens(inner, inner_pos); inner_pos = a
							elseif c == 91 then
								local _, a = duffle.read_brackets(inner, inner_pos); inner_pos = a
							elseif c == 34 or c == 39 then
								inner_pos = duffle.duffle.skip_str_or_cmt(inner, inner_pos) + 1
							else
								inner_pos = inner_pos + 1
							end
						end
						if depth ~= 0 then
							-- unmatched; bail
							pos = open_paren + 1
						else
							-- First ident in `inner` is the comp name.
							local name_match = inner:match("^%s*([%w_]+)")
							local name = name_match or "?"
							local body     = inner:sub(last_brace_pos + 1, inner_pos - 1)
							-- body_off in full source: position right after the
							-- LAST `{` in `inner`, which sits at `open_paren+1+last_brace_pos`
							-- (open_paren+1 = just inside the outer paren,
							-- +last_brace_pos = at the `{`).
							local body_off = open_paren + 1 + last_brace_pos
							out[#out + 1] = {
								line     = line_of(pos),
								name     = name,
								body     = body,
								body_off = body_off + 1,
								kind     = kind,
							}
							pos = after_paren
						end
					end
				else
					-- MipsAtom_(sym) { body };  OR
					-- MipsAtomComp_(sym) { body };
					-- name is the first arg, body is the FIRST { ... } after
					-- the paren.
					local name_start = 1
					while name_start <= #inner and inner:sub(name_start, name_start):match("[%s]") do name_start = name_start + 1 end
					local name_end = name_start
					while name_end <= #inner and inner:sub(name_end, name_end):match("[%w_]") do name_end = name_end + 1 end
					local name = inner:sub(name_start, name_end - 1)
					if name == "" then
						pos = open_paren + 1
					else
						local brace = duffle.scan_to_char(source_text, "{", after_paren)
						if brace then
							local body, after_brace = duffle.read_braces(source_text, brace)
							local body_off = brace + 1
							out[#out + 1] = {
								line     = line_of(pos),
								name     = name,
								body     = body,
								body_off = body_off,
								kind     = kind,
							}
							pos = after_brace
						else
							pos = open_paren + 1
						end
					end
				end
			end
		else
			pos = ident_end
		end
		end  -- close the new preprocessor-skip else
	end
	return out
end

-- ════════════════════════════════════════════════════════════════════════════
-- Body tokenizer (top-level comma splitter + per-token classification)
-- ════════════════════════════════════════════════════════════════════════════

--- Build a map: `body_relative_char_offset` -> `body_relative_line`.
--- Used by the checks to convert per-token offsets in the body to line
--- numbers relative to the start of `body`. The atom's source-line of
--- the body-start is added by the caller.
---
--- Simple line-counting: count `\n` chars from offset 1 up to the
--- offset; that count + 1 is the line number (1-based).
local function build_body_line_index(body)
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
	return index
end

--- Count of COP2-nop words contributed by a single top-level token.
--   `nop`                  -> 1
--   `nop2`                 -> 2 (i.e. `nop, nop` baked into one asm word)
--   `nop,` / `nop2,`        -> same as above; strip trailing comma defensively
--   anything else          -> 0
--
-- (Branch-delay-slot nops like `branch_*(..., nop)` are tokenized
-- separately by split_top_level_commas: the branch arg ends before
-- the trailing comma, and `nop` becomes its own token. So no special
-- handling is needed here.)
local function nop_word_count(token)
	local s = duffle.trim(token)
	-- strip trailing comma(s) (defensive against raw text via, but our
	-- tokenize_body already strips them; this is a safety net)
	s = s:gsub(",$", "")
	s = duffle.trim(s)
	if s == "nop"  then return 1 end
	if s == "nop2" then return 2 end
	return 0
end

--- Tokenize the body inner-text into a flat list of `(token, body_rel_offset)`
--- pairs (nested parens/braces/brackets are honored; comments and strings
--- are skipped). `body_rel_offset` is the char offset within `body` of the
--- start of the token — callers add it to the atom's `body_off` to get
--- an absolute source position for line tracking.
local function tokenize_body(body)
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

		-- Find comma/newline/semicolon after this token. Read balanced
		-- groups so commas inside parens/braces/brackets aren't treated
		-- as separators. Comments / strings are skipped.
		local scan = rel
		while scan <= len do
			local c = body:byte(scan)
			if c == 44 then break end               -- ','
			if c == 10 then break end               -- '\n'
			if c == 59 then break end               -- ';'
			if c == 40 then                         -- '('
				local _, a = duffle.read_parens(body, scan); scan = a
			elseif c == 123 then                     -- '{'
				local _, a = duffle.read_braces(body, scan); scan = a
			elseif c == 91 then                      -- '['
				local _, a = duffle.read_brackets(body, scan); scan = a
			elseif c == 34 or c == 39 then           -- '"' or '\''
				scan = duffle.duffle.skip_str_or_cmt(body, scan) + 1
			else
				scan = scan + 1
			end
		end
		-- Extract token [rel .. scan-1]
		local tok = duffle.trim(body:sub(rel, scan - 1))
		if tok ~= "" then
			out[#out + 1] = { tok = tok, rel = rel }
		end
		-- Move past the separator
		if scan <= len then
			scan = scan + 1
			-- Also skip whitespace before next token
			local w = duffle.skip_ws_and_cmt(body, scan)
			if w > scan then scan = w end
		end
		rel = scan
	end
	return out
end

-- ════════════════════════════════════════════════════════════════════════════
-- Check #1: GTE pipeline-fill
-- ════════════════════════════════════════════════════════════════════════════

--- Walk the token list. Whenever we hit a `gte_cmdw_<X>` token, count
--- consecutive nop words starting at the next token. If count < the
--- minimum declared in `duffle.GTE_PIPELINE_LATENCY[X]`, record a finding.
---
--- Aliases (`gte_cmdw_rotate_translate_perspective_single` etc.) are
--- resolved against the lookup table directly; if a macro name is not
--- in the table, emit a soft warning (the user might have added a new
--- gte_cmdw_* but not updated duffle.lua).
local function check_gte_pipeline_fill(atoms, findings, line_of)
	-- Walk the token list. Whenever we hit a `gte_cmdw_<X>` token,
	-- count consecutive `nop` words IMMEDIATELY PRECEDING it (the
	-- source-level `nop2, gte_cmdw_X` idiom provides the pre-pipeline
	-- fill that gte.h's wrapper functions provide internally). If
	-- count < `duffle.GTE_PIPELINE_LATENCY[X]`, record a finding.
	--
	-- We count nops going backwards from the cmdw token, stopping at
	-- the first non-nop token. Tokens like `mem_share` or `port_write`
	-- (any non-nop) break the count. `gte_mv_to_data_r` (writes to
	-- C2_DR registers) are non-nops in this sense -- they count as
	-- "previous GTE state" but don't themselves count as pipeline
	-- fill.
	for _, a in ipairs(atoms) do
		local tokens = tokenize_body(a.body)
		local line_in_body = build_body_line_index(a.body)
		local tn = #tokens
		local ti = 1
		while ti <= tn do
			local tok = tokens[ti].tok
			local cmdw_full = tok:match("^(gte_cmdw_[%w_]+)%s*[,%)]")
			              or tok:match("^(gte_cmdw_[%w_]+)%s*$")
			if cmdw_full then
				local variant = cmdw_full:match("^gte_cmdw_(.+)$")
				local need = duffle.GTE_PIPELINE_LATENCY[cmdw_full]
				if need == nil then
					-- alias or new gte_cmdw_<X> not yet in latency table
					local line = a.line + line_in_body[tokens[ti].rel]
					findings[#findings + 1] = {
						atom  = a.name,
						line  = line,
						check = "gte_pipeline_fill",
						kind  = "warning",
						msg   = string.format(
							"%s at line %d uses `gte_cmdw_%s` but that macro is not in duffle.duffle.GTE_PIPELINE_LATENCY -- add a min_nops entry",
							a.name, line, variant),
					}
					ti = ti + 1
				elseif need > 0 then
					-- Count consecutive nops immediately BEFORE the cmdw
					-- token. We walk tokens[ti - n] backwards, accumulating
					-- nop_word_count, stopping at the first non-nop.
					local have = 0
					local where_ti = ti - 1
					while where_ti >= 1 do
						local n = nop_word_count(tokens[where_ti].tok)
						if n == 0 then break end
						have = have + n
						where_ti = where_ti - 1
					end
					if have < need then
						local line = a.line + line_in_body[tokens[ti].rel]
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
					ti = ti + 1
				else
					ti = ti + 1
				end
			else
				ti = ti + 1
			end
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Check #2: mac_yield uniformity
-- ════════════════════════════════════════════════════════════════════════════

--- Every atom body must contain exactly one `mac_yield()` call and it
--- must be the LAST top-level token in the body (so the tape runtime
--- can pick up cleanly at the next atom's bound registers).
---
--- Empty bodies are not currently flagged — runtime infrastructure
--- atoms like `MipsAtom_(yield) { mac_yield() }` and `MipsAtom_(tape_exit)
--- { jump_reg(rret_addr), nop }` are valid as-is; mac_yield at the end
--- is the contract.
local function check_mac_yield_uniformity(atoms, findings)
	-- Per-kind semantics:
	--   MipsAtom_          (baked atom): exactly 1 mac_yield at the end of
	--                          the body. Control transfer is the atom's job.
	--   MipsAtomComp_      (bare static-array component): ZERO mac_yield.
	--                          The component is invoked from inside an atom
	--                          body; the parent atom does the yield.
	--   MipsAtomComp_Proc_ (procedural component): ZERO mac_yield.
	--                          Same reasoning -- it's a function returning
	--                          a MipsAtom slice, invoked from a parent atom.
	--
	-- The GTE pipeline-fill check applies to all 3 kinds (see
	-- check_gte_pipeline_fill). Only the mac_yield rule branches on kind.
	for _, a in ipairs(atoms) do
		local tokens = tokenize_body(a.body)
		local line_in_body = build_body_line_index(a.body)

		local count = 0
		local last_idx = 0
		for tok_idx, t in ipairs(tokens) do
			local tok = t.tok
			-- Match `mac_yield(...)` or just `mac_yield`. The bareword
			-- variant is rare in modern style but tolerated.
			if tok:match("^mac_yield%s*%(") or tok == "mac_yield" then
				count = count + 1
				last_idx = tok_idx
			end
		end
		local function line_for(idx)
			return a.line + line_in_body[tokens[idx].rel]
		end

		if a.kind == "atom" then
			-- Baked atom: exactly 1 yield at the end.
			if count == 0 then
				findings[#findings + 1] = {
					atom  = a.name,
					line  = a.line,
					check = "mac_yield_uniformity",
					kind  = "warning",
					msg   = string.format(
						"%s at line %d has no `mac_yield()`; every atom must hand control to the next via mac_yield at end",
						a.name, a.line),
				}
			elseif count > 1 then
				findings[#findings + 1] = {
					atom  = a.name,
					line  = line_for(last_idx),
					check = "mac_yield_uniformity",
					kind  = "warning",
					msg   = string.format(
						"%s at line %d has %d `mac_yield()` calls; exactly 1 is allowed",
						a.name, line_for(last_idx), count),
				}
			elseif last_idx < #tokens then
				-- 1 call, but not the last token. We DON'T fail if the
				-- post-token is just `nop` or `nop2` or a branch with `, nop`
				-- delay slot -- it's the standard "yield, then BD nop" idiom.
				local post_non_nop = false
				for search_idx = last_idx + 1, #tokens do
					local t = tokens[search_idx].tok
					if t ~= "" and t ~= "nop" and t ~= "nop2"
					   and not t:match("%,%s*nop%)%s*$") then
						post_non_nop = true
						break
					end
				end
				if post_non_nop then
					findings[#findings + 1] = {
						atom  = a.name,
						line  = line_for(last_idx),
						check = "mac_yield_uniformity",
						kind  = "warning",
						msg   = string.format(
							"%s at line %d has `mac_yield()` at token %d/%d; the yield must be the LAST non-nop token in the body",
							a.name, line_for(last_idx), last_idx, #tokens),
					}
				end
			end
		else
			-- Component (comp_bare or comp_proc): ZERO yields. The parent
			-- atom does the yield. A yield inside a component would either
			-- be dead code (bare) or prematurely terminate the function
			-- (proc). Both are bugs.
			if count > 0 then
				findings[#findings + 1] = {
					atom  = a.name,
					line  = line_for(last_idx),
					check = "mac_yield_uniformity",
					kind  = "warning",
					msg   = string.format(
						"%s at line %d is a %s component but has %d `mac_yield()` call(s); components must not yield (the parent atom does)",
						a.name, line_for(last_idx), a.kind, count),
				}
			end
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Source walkers: Binds_* structs + per-atom atom_info
-- ════════════════════════════════════════════════════════════════════════════

--- Walk source-as-written, return a list of `{line, name, fields, bytes}`
--- for every `typedef Struct_(Binds_X) { ... };` declaration. Only U4
--- fields are tracked (Binds_* are always word arrays in this codebase --
--- pointers stored as U4, indices as U4, etc.). Mirrors annotation.lua ::
--- find_binds_structs but is independent (no shared cross-pass state for
--- static-analysis; each pass re-walks source).
local function find_binds_structs(source_text)
	local line_of = duffle.LineIndex(source_text)
	local out = {}
	local src_len = #source_text
	local pos      = 1
	while pos <= src_len do
		pos = duffle.skip_ws_and_cmt(source_text, pos); if pos > src_len then break end
		if source_text:sub(pos, pos) == "#" then
			local eol_pos = pos
			while eol_pos <= src_len and source_text:byte(eol_pos) ~= 10 do eol_pos = eol_pos + 1 end
			pos = eol_pos + 1
		else
			local ident, ident_end = duffle.read_ident(source_text, pos)
			if not ident then
				pos = pos + 1
			elseif ident == "typedef" then
				local after_typedef = duffle.skip_ws_and_cmt(source_text, ident_end)
				local id2, id2_end = duffle.read_ident(source_text, after_typedef)
				if id2 ~= "Struct_" then
					pos = id2_end or (after_typedef + 1)
				else
					local open_paren = duffle.skip_ws_and_cmt(source_text, id2_end)
					if source_text:sub(open_paren, open_paren) ~= "(" then
						pos = open_paren + 1
					else
						local inner, after_paren = duffle.read_parens(source_text, open_paren)
						local name = duffle.trim(inner)
						local brace = duffle.scan_to_char(source_text, "{", after_paren)
						if not brace then
							pos = open_paren + 1
						else
							local body, after_brace = duffle.read_braces(source_text, brace)
							local fields = {}
							local byte_off = 0
							local body_pos = 1
							while body_pos <= #body do
								body_pos = duffle.skip_ws_and_cmt(body, body_pos); if body_pos > #body then break end
								local type_ident, type_end = duffle.read_ident(body, body_pos)
								if not type_ident then
									body_pos = body_pos + 1
								elseif type_ident == "U4" then
									local field_ident, field_end = duffle.read_ident(body, duffle.skip_ws_and_cmt(body, type_end))
									if field_ident then
										fields[#fields + 1] = { name = field_ident, offset = byte_off }
										byte_off = byte_off + 4
									end
									body_pos = field_end or (type_end + 1)
								else
									body_pos = type_end + 1
								end
							end
							if name:sub(1, 6) == "Binds_" then
								out[#out + 1] = { line = line_of(pos), name = name, fields = fields, bytes = byte_off }
							end
							pos = after_brace
						end
					end
				end
			else
				pos = ident_end
			end
		end
	end
	return out
end

--- For every `MipsAtom_(name)` followed by `atom_info(...)`, parse the
--- atom_info's `atom_bind(Binds_X)`, `atom_reads(...)`, and
--- `atom_writes(...)` sub-calls. Returns a list of
--- `{atom_name, binds, reads, writes, info_line}` for use by
--- check_abi_handoff.
local function find_atom_info(source_text)
	local line_of = duffle.LineIndex(source_text)
	local out = {}
	local src_len = #source_text
	local pos      = 1
	while pos <= src_len do
		pos = duffle.skip_ws_and_cmt(source_text, pos); if pos > src_len then break end
		if source_text:sub(pos, pos) == "#" then
			local eol_pos = pos
			while eol_pos <= src_len and source_text:byte(eol_pos) ~= 10 do eol_pos = eol_pos + 1 end
			pos = eol_pos + 1
		else
			local ident, ident_end = duffle.read_ident(source_text, pos)
			if not ident then
				pos = pos + 1
			elseif ident == "MipsAtom_" then
				local open_paren = duffle.skip_ws_and_cmt(source_text, ident_end)
				if source_text:sub(open_paren, open_paren) ~= "(" then
					pos = open_paren + 1
				else
					local inner, after_paren = duffle.read_parens(source_text, open_paren)
					local name_start = 1
					while name_start <= #inner and inner:sub(name_start, name_start):match("[%s]") do name_start = name_start + 1 end
					local name_end = name_start
					while name_end <= #inner and inner:sub(name_end, name_end):match("[%w_]") do name_end = name_end + 1 end
					local atom_name = inner:sub(name_start, name_end - 1)
					local lookahead = duffle.skip_ws_and_cmt(source_text, after_paren)
					local look_ident, look_end = duffle.read_ident(source_text, lookahead)
					if look_ident == "atom_info" then
						local info_open = duffle.skip_ws_and_cmt(source_text, look_end)
						if source_text:sub(info_open, info_open) == "(" then
							local info_inner, info_after = duffle.read_parens(source_text, info_open)
							local binds, reads, writes = nil, nil, nil
							local sub_pos = 1
							while sub_pos <= #info_inner do
								sub_pos = duffle.skip_ws_and_cmt(info_inner, sub_pos); if sub_pos > #info_inner then break end
								local sub_ident, sub_end = duffle.read_ident(info_inner, sub_pos)
								if not sub_ident then
									sub_pos = sub_pos + 1
								elseif sub_ident == "atom_bind" then
									local sub_open = duffle.skip_ws_and_cmt(info_inner, sub_end)
									if info_inner:sub(sub_open, sub_open) == "(" then
										local sub_inner, sub_after2 = duffle.read_parens(info_inner, sub_open)
										binds = duffle.trim(sub_inner)
										sub_pos = sub_after2
									else
										sub_pos = sub_open + 1
									end
								elseif sub_ident == "atom_reads" or sub_ident == "atom_writes" then
									local kind = sub_ident
									local sub_open = duffle.skip_ws_and_cmt(info_inner, sub_end)
									if info_inner:sub(sub_open, sub_open) == "(" then
										local sub_inner, sub_after2 = duffle.read_parens(info_inner, sub_open)
										local regs = {}
										local sub_inner_pos = 1
										while sub_inner_pos <= #sub_inner do
											sub_inner_pos = duffle.skip_ws_and_cmt(sub_inner, sub_inner_pos); if sub_inner_pos > #sub_inner then break end
											local reg_ident, reg_end = duffle.read_ident(sub_inner, sub_inner_pos)
											if reg_ident then
												regs[#regs + 1] = duffle.trim(reg_ident)
												sub_inner_pos = reg_end
											else
												sub_inner_pos = sub_inner_pos + 1
											end
											if sub_inner_pos > #sub_inner then break end
											if sub_inner:sub(sub_inner_pos, sub_inner_pos) == "," then sub_inner_pos = sub_inner_pos + 1 end
										end
										if kind == "atom_reads" then reads = regs else writes = regs end
										sub_pos = sub_after2
									else
										sub_pos = sub_open + 1
									end
								else
									sub_pos = sub_end
								end
							end
							out[#out + 1] = {
								atom_name = atom_name, binds = binds,
								reads = reads or {}, writes = writes or {},
								info_line = line_of(lookahead),
							}
							pos = info_after
						else
							pos = info_open + 1
						end
					else
						pos = after_paren
					end
				end
			else
				pos = ident_end
			end
		end
	end
	return out
end

-- ════════════════════════════════════════════════════════════════════════════
-- Check #3: ABI handoff discipline
-- ════════════════════════════════════════════════════════════════════════════

--- For every atom with `atom_bind(Binds_X)`, verify the atom body loads
--- every field of `Binds_X` from R_TapePtr (in declaration order) and
--- advances R_TapePtr by S_(Binds_X) at the end. Mismatches are errors.
--- Rules:
---   1. Body MUST contain one `load_word(R_*, R_TapePtr, O_(Binds_X, field))`
---      per field of Binds_X. Missing field = error.
---   2. Body's load_words to R_TapePtr at O_(Binds_X, field) MUST appear
---      in the same order as the fields are declared in Binds_X.
---      Out-of-order load = error.
---   3. Body MUST contain an `add_ui_self(R_TapePtr, S_(Binds_X))` (or
---      equivalent advance by the struct's byte count). Missing = error.
---   4. atom_bind(Binds_X) where Binds_X doesn't exist = error.
local function check_abi_handoff(atoms, atom_infos, binds_index, findings)
	local info_by_atom = {}
	for _, info in ipairs(atom_infos) do
		info_by_atom[info.atom_name] = info
	end

	for _, a in ipairs(atoms) do
		local info = info_by_atom[a.name]
		if info and info.binds then
			local binds_name = info.binds
			local binds = binds_index[binds_name]
			if not binds then
				findings[#findings + 1] = {
					atom = a.name, line = a.line,
					check = "abi_handoff", kind = "error",
					msg = string.format("%s at line %d has `atom_bind(%s)` but no `typedef Struct_(%s)` declaration found in source",
						a.name, a.line, binds_name, binds_name),
				}
			else
				local tokens = tokenize_body(a.body)
				local line_in_body = build_body_line_index(a.body)
				local expected_field_seq = {}
				for _, f in ipairs(binds.fields) do expected_field_seq[#expected_field_seq + 1] = f.name end
				local found_field_seq = {}
				local found_field_set = {}
				local found_advance = false
				local bind_re = "O_%(" .. binds_name .. ",%s*([%w_]+)%s*%)"
				for _, t in ipairs(tokens) do
					local tok = t.tok
					if tok:match("^load_word%s*%(") then
						if tok:find("R_TapePtr", 1, true) and tok:find("O_(" .. binds_name .. ",", 1, true) then
							local field = tok:match(bind_re)
							if field then
								found_field_seq[#found_field_seq + 1] = field
								found_field_set[field] = true
							else
								local body_line = a.line + line_in_body[t.rel]
								findings[#findings + 1] = {
									atom = a.name, line = body_line,
									check = "abi_handoff", kind = "error",
									msg = string.format("%s at line %d has load_word(R_TapePtr, O_(%s, <non-ident>)); expected O_(%s, <field>)",
										a.name, body_line, binds_name, binds_name),
								}
							end
						end
					end
					if tok:find("R_TapePtr", 1, true)
					   and tok:find("S_(" .. binds_name .. ")", 1, true) then
						found_advance = true
					end
				end

				for _, fname in ipairs(expected_field_seq) do
					if not found_field_set[fname] then
						findings[#findings + 1] = {
							atom = a.name, line = a.line,
							check = "abi_handoff", kind = "error",
							msg = string.format("%s at line %d binds %s but never loads field `%s` from R_TapePtr (expected O_(%s, %s))",
								a.name, a.line, binds_name, fname, binds_name, fname),
						}
					end
				end

				if #found_field_seq == #expected_field_seq then
					for field_idx = 1, #expected_field_seq do
						if found_field_seq[field_idx] ~= expected_field_seq[field_idx] then
							findings[#findings + 1] = {
								atom = a.name, line = a.line,
								check = "abi_handoff", kind = "error",
								msg = string.format("%s at line %d loads fields in wrong order: got [%s], expected [%s]",
									a.name, a.line,
									table.concat(found_field_seq, ", "),
									table.concat(expected_field_seq, ", ")),
							}
							break
						end
					end
				end

				if not found_advance then
					findings[#findings + 1] = {
						atom = a.name, line = a.line,
						check = "abi_handoff", kind = "error",
						msg = string.format("%s at line %d binds %s but never advances R_TapePtr by S_(%s) (= %d bytes / %d words)",
							a.name, a.line, binds_name, binds_name, binds.bytes, binds.bytes / 4),
					}
				end
			end
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Check #4: GPU port-store shape
-- ════════════════════════════════════════════════════════════════════════════

--- For every baked atom body, detect which GP0 primitive it's emitting
--- (first `mac_format_<shape>_color` call). Sum contributions from
--- `mac_format_X_color` + `mac_gte_store_X_post_*` + `mac_insert_ot_tag_X`.
--- Compare to duffle.GP0_CMD_SIZE[cmd_byte]. Mismatch = error.
---
--- Soft behavior (warnings):
---   - Atoms emitting a primitive via raw `store_word(R_PrimCursor, ...)`
---     (no `mac_format_X_color` call) emit a "manual packet assembly"
---     advisory. Cannot auto-validate.
---   - Atoms containing a `mac_<name>(...)` call whose name is not in
---     duffle.GP0_MACRO_CONTRIB emit a "new macro; update duffle.GP0_MACRO_CONTRIB"
---     advisory.
---
--- Applies only to `kind = "atom"` (baked atoms). Components don't
--- emit full primitives.
local function check_gpu_portstore_shape(atoms, findings)
	for _, a in ipairs(atoms) do
		if a.kind == "atom" then
			local tokens = tokenize_body(a.body)
			local line_in_body = build_body_line_index(a.body)
			local cmd_byte = nil
			local cmd_line = nil
			local contrib = 0
			local saw_format = false
			local saw_prim_write = false
			for _, t in ipairs(tokens) do
				local tok = t.tok
				-- Match `mac_format_<shape>_color(...)` and strip `_color`
				-- to get the bare shape suffix (f3 / g4 / etc).
				local shape = tok:match("^mac_format_([%w_]+)_color%s*%(")
				            or tok:match("^mac_format_([%w_]+)_color%s*$")
				if shape and duffle.GP0_CMD_BY_SHAPE[shape] then
					if not cmd_byte then
						cmd_byte = duffle.GP0_CMD_BY_SHAPE[shape]
						cmd_line = a.line + line_in_body[t.rel]
					end
					saw_format = true
					local contrib_key = "mac_format_" .. shape .. "_color"
					local n = duffle.GP0_MACRO_CONTRIB[contrib_key]
					if n then contrib = contrib + n end
				end
				local gte_store = tok:match("^mac_gte_store_[%w_]+")
				if gte_store then
					local n = duffle.GP0_MACRO_CONTRIB[gte_store]
					if n then contrib = contrib + n end
				end
				local ot_tag = tok:match("^mac_insert_ot_tag_([%w_]+)")
				if ot_tag then
					local n = duffle.GP0_MACRO_CONTRIB["mac_insert_ot_tag_" .. ot_tag]
					if n then contrib = contrib + n end
				end
				if tok:match("^store_word%s*%(") and tok:find("R_PrimCursor", 1, true) then
					saw_prim_write = true
				end
			end

			if not cmd_byte then
				if saw_prim_write and not saw_format then
					findings[#findings + 1] = {
						atom = a.name, line = a.line,
						check = "gpu_portstore_shape", kind = "warning",
						msg = string.format("%s at line %d writes to R_PrimCursor via raw store_word(...) but uses no `mac_format_*_color`; the cmd byte + word count cannot be auto-validated. Consider migrating to `mac_format_X_color` + `mac_gte_store_X_post_*` + `mac_insert_ot_tag_X`.",
							a.name, a.line),
					}
				end
			else
				local expected = duffle.GP0_CMD_SIZE[cmd_byte]
				if contrib ~= expected then
					findings[#findings + 1] = {
						atom = a.name, line = cmd_line or a.line,
						check = "gpu_portstore_shape", kind = "error",
						msg = string.format("%s at line %d emits GP0 0x%02X with %d prim word(s); expected %d (cmd 0x%02X total = %d)",
							a.name, cmd_line or a.line, cmd_byte, contrib, expected, cmd_byte, expected),
					}
				end
			end
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Check #5: per-atom cycle budget (Phase 3)
-- ════════════════════════════════════════════════════════════════════════════

--- Compute the cycle cost of one token. The token is a string like
--- `add_ui(R_T0, R_T1, 4)` or `nop2` or `gte_cmdw_rtpt`. Returns:
---   cycles       - integer cycle cost (from duffle.INSTRUCTION_LATENCY, or
---                  duffle.UNKNOWN_INSTRUCTION_CYCLES if not in the table)
---   macro_name   - the bare ident (e.g. `add_ui`, `gte_cmdw_rtpt`,
---                  `nop2`, `mac_yield`)
---   unknown      - true iff the macro wasn't in duffle.INSTRUCTION_LATENCY
--- The function strips trailing `()` from function-call style macros
--- so `mac_yield()` and `mac_yield` resolve identically.
local function token_cycles(tok)
	-- Extract the leading ident. Tolerate `(...)` args.
	local ident = tok:match("^([%w_]+)")
	if not ident then return duffle.UNKNOWN_INSTRUCTION_CYCLES, "?", true end
	local cost = duffle.INSTRUCTION_LATENCY[ident]
	if cost == nil then
		return duffle.UNKNOWN_INSTRUCTION_CYCLES, ident, true
	end
	return cost, ident, false
end

--- Find every `atom_label(name)` token in the token list and return a
--- map `label_name -> token_idx`. Labels are 0-cost markers; the path
--- walker uses them as branch targets.
local function find_atom_labels(tokens)
	local labels = {}
	for tok_idx, t in ipairs(tokens) do
		local name = t.tok:match("^atom_label%s*%(%s*([%w_]+)%s*%)")
		if name then labels[name] = tok_idx end
	end
	return labels
end

--- Find every `branch_*(...)` token in the token list and return a map
--- `token_idx -> label_name|false`. If the branch's args contain an
--- `atom_offset(F, label)` call, the label name is recorded; otherwise
--- the branch's target is unknown (likely a literal offset) and we
--- record `false` as a sentinel. The CFG walker checks KEY PRESENCE
--- (via `is_branch(tok_idx)`) to decide whether a token is a branch; it
--- checks the value to decide whether the taken-path target is known.
--- (We can't use `nil` for the unknown-target case because `targets[tok_idx] = nil`
--- REMOVES the key from the Lua table, which would make `is_branch(tok_idx)`
--- return false for both "not a branch" and "branch with unknown target".)
local function find_branch_targets(tokens)
	local targets = {}
	for tok_idx, t in ipairs(tokens) do
		if t.tok:match("^branch_[%w_]+%s*%(") then
			-- branch_<cond>(rs, atom_offset(F, label))   or
			-- branch_<cond>(rs, rt, atom_offset(F, label))
			-- atom_offset's arg list is (flag, name); we want the name.
			local label = t.tok:match("atom_offset%s*%([^,]+,%s*([%w_]+)%s*%)")
			targets[tok_idx] = label or false  -- `false` = known branch, unknown target
		end
	end
	return targets
end

--- Walk all paths through an atom body and return per-path cycle sums.
--- Builds a tiny CFG: each token has a "next" pointer; branches have two
--- (fall-through + taken). The BD-slot nop after a branch is absorbed
--- into the branch's cost (MIPS-accurate: BD slot always runs), and is
--- SKIPPED when continuing down the fall-through path (otherwise we'd
--- double-count it).
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
---   cycles_full    - sum of ALL token costs (the previous "best case"
---                    value; included for backward-compat; double-counts
---                    the BD-slot nop relative to cycles_min/max)
local function analyze_atom_paths(atom)
	local tokens = tokenize_body(atom.body)
	local labels   = find_atom_labels(tokens)
	local branches = find_branch_targets(tokens)

	-- Pre-compute per-token cycle costs and identify terminators.
	local n        = #tokens
	local costs    = {}
	local unknown_set = {}
	for tok_idx, t in ipairs(tokens) do
		local c, _, unknown = token_cycles(t.tok)
		costs[tok_idx] = c
		if unknown then
			unknown_set[t.tok:match("^([%w_]+)") or "?"] = true
		end
	end

	-- A token is a terminator if it's `mac_yield` or `mac_yield(...)`.
	-- The yield transfers control; we don't count its cost (the next
	-- atom's prologue absorbs it).
	local function is_terminator(tok_idx)
		local tok = tokens[tok_idx].tok
		return tok == "mac_yield" or tok:match("^mac_yield%s*%(")
	end

	-- CFG successor function. Returns a list of next token indices for
	-- the given position. Branch tokens produce 2 successors (fall-through
	-- + taken); normal tokens produce 1 (next); terminators produce 0.
	-- BD-slot absorption: a branch at tok_idx skips tok_idx+1 (the BD slot) in its
	-- fall-through path; the BD slot's cost is added to the branch's
	-- own cost instead (so it's counted once).
	--
-- A token is a "branch" if its index is a KEY in the `branches`
-- map (regardless of whether the value is nil — a branch with
-- nil target means "literal offset, taken path is unknown").
-- We check key-presence via `branches[tok_idx] ~= nil` because
-- `branches[tok_idx]` returns nil for both "absent" AND "present with
-- nil value" — distinguishing them requires the key check.
	local function is_branch(tok_idx)
		local v = branches[tok_idx]
		if v == nil then return false end
		-- v is non-nil: either a string (atom_offset target) or false
		-- (literal offset, no target). Both indicate a branch.
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
			-- For literal-offset branches (label == false), the taken
			-- path would jump to a non-tracked address; conservatively
			-- omit. Return (succ, nil) -- the second value is the
			-- terminator marker (nil = not a terminator).
			return succ, nil
		end
		-- Normal token: just the next one
		if tok_idx + 1 <= n then
			return { tok_idx + 1 }, nil
		end
		return {}, nil
	end

	-- DFS through all paths. Track the current cycle sum, a visited set
	-- scoped to the current path (to detect loops), and a count of paths.
	-- Cap recursion at MAX_PATHS to prevent runaway exploration on
	-- pathological bodies.
	local MAX_PATHS = 64
	local cycles_min = math.huge
	local cycles_max = -1
	local path_count = 0
	local has_loops = false
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
		-- (and skip the BD slot in the successor list — already done in
		-- `successors` above for fall-through; for taken path the BD
		-- slot was at tok_idx+1 which is now skipped entirely).
		local cost = costs[tok_idx]
		if is_branch(tok_idx) and tok_idx + 1 <= n then
			cost = cost + costs[tok_idx + 1]
		end
		local new_acc = acc + cost

		local succ, term = successors(tok_idx)
		if term then
			-- Terminator: record the path's cycle sum. We do NOT add
			-- the terminator token to `visited` -- a path ends here, so
			-- a different path that ALSO reaches this terminator is a
			-- legitimate new path (not a loop). If we marked it
			-- visited, subsequent paths that reach the same terminator
			-- would be incorrectly flagged as loops.
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

	-- cycles_full: sum of every token's cost (the previous model; useful
	-- for comparing against the path-aware min/max).
	local cycles_full = 0
	for tok_idx = 1, n do cycles_full = cycles_full + costs[tok_idx] end

	-- If no paths were recorded (e.g. atom body is empty), cycles_min/max
	-- default to 0 (atom costs nothing). cycles_full is 0 too in that case.
	if cycles_min == math.huge then cycles_min = 0 end
	if cycles_max == -1 then cycles_max = 0 end

	local unknown_list = {}
	for macro_name in pairs(unknown_set) do unknown_list[#unknown_list + 1] = macro_name end
	table.sort(unknown_list)

	-- branch_count: number of `branch_*(...)` tokens. (More useful than
	-- `#branches` which is the size of the targets map and would be equal
	-- to #branches anyway, but the rename is clearer.)
	local branch_count = 0
	for _ in pairs(branches) do branch_count = branch_count + 1 end

	return {
		cycles_min     = cycles_min,
		cycles_max     = cycles_max,
		cycles_full    = cycles_full,
		branches       = branch_count,
		paths          = path_count,
		has_loops      = has_loops,
		unknown_macros = unknown_list,
	}
end

--- Backward-compat wrapper: returns total cycle count (the previous
--- "best case" value, which over-counts BD-slot nops) + unknown macro
--- list. New code should call `analyze_atom_paths(atom)` instead.
local function count_atom_cycles(atom)
	local tokens = tokenize_body(atom.body)
	local total  = 0
	local unknown_set = {}
	for _, t in ipairs(tokens) do
		local c, _, unknown = token_cycles(t.tok)
		total = total + c
		if unknown then
			unknown_set[t.tok:match("^([%w_]+)") or "?"] = true
		end
	end
	local unknown_list = {}
	for macro_name in pairs(unknown_set) do unknown_list[#unknown_list + 1] = macro_name end
	return total, unknown_list
end

--- Per-source check that emits one finding per unknown macro seen
--- (deduplicated across atoms so the warning section doesn't get
--- spammed with N copies of "macro X not in duffle.INSTRUCTION_LATENCY").
local function check_per_atom_cycle_budget(atoms, findings)
	local unknown_seen = {}
	for _, a in ipairs(atoms) do
		local _, unknown_macros = count_atom_cycles(a)
		for _, name in ipairs(unknown_macros) do
			if not unknown_seen[name] then
				unknown_seen[name] = a.line
				findings[#findings + 1] = {
					atom = a.name, line = a.line,
					check = "per_atom_cycle_budget", kind = "warning",
					msg = string.format("%s at line %d uses macro `%s` which is not in duffle.INSTRUCTION_LATENCY; cycle count will be +%d per call (best-case). Add an entry to duffle.M.duffle.INSTRUCTION_LATENCY.",
						a.name, a.line, name, duffle.UNKNOWN_INSTRUCTION_CYCLES),
				}
			end
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Per-source validation
-- ════════════════════════════════════════════════════════════════════════════

local function validate(ctx, src)
	local source = src.text
	local atoms  = find_atom_bodies(source)

	-- Build per-source Binds_* index + per-atom atom_info lookup. These
	-- are local to the validate() call; no cross-source sharing needed --
	-- every .c / .h file is validated standalone.
	local binds_index = {}
	for _, b in ipairs(find_binds_structs(source)) do
		binds_index[b.name] = b
	end
	local atom_infos = find_atom_info(source)

	local findings = {}
	check_gte_pipeline_fill(atoms, findings)
	check_mac_yield_uniformity(atoms, findings)
	check_abi_handoff(atoms, atom_infos, binds_index, findings)
	check_gpu_portstore_shape(atoms, findings)
	check_per_atom_cycle_budget(atoms, findings)

	-- Phase 3 cycle-budget output: attach per-path cycle data to each
	-- atom. Best-case (no-stall) cycle count with BD-slot absorbed; the
	-- `cycles_full` field is the legacy sum-of-all-tokens value (kept
	-- for backward compat; over-counts BD-slot nops).
	local cycles_by_atom = {}
	for _, a in ipairs(atoms) do
		local p = analyze_atom_paths(a)
		a.paths = p
		a.cycles = p.cycles_max     -- default for any code that reads .cycles
		a.cycles_min = p.cycles_min
		a.cycles_max = p.cycles_max
		a.cycles_full = p.cycles_full
		a.branch_count = p.branches
		a.unknown_macros = p.unknown_macros
		a.has_loops = p.has_loops
		cycles_by_atom[a.name] = p
	end

	local errors   = {}
	local warnings = {}
	local info     = {}
	for _, f in ipairs(findings) do
		-- Per-finding severity is set by the check via `f.kind`
		-- ("error" or "warning"). A `gte_pipeline_fill` finding can be
		-- either severity (errors for missing nops; warnings for unknown
		-- cmdw macros not in the latency table). Bin by `kind`, not by
		-- check name.
		if f.kind == "error" then
			errors[#errors + 1] = { line = f.line, msg = f.msg }
		else
			warnings[#warnings + 1] = { line = f.line, msg = f.msg }
		end
	end
	-- Per-source "scanned:" summary line. Includes the source basename
	-- for traceability (the old format was just "scanned: N atom
	-- bodies; M findings" which is unidentifiable when the module has
	-- multiple sources). Sources with 0 atoms (pure-header files like
	-- dsl.h, mips.h, etc.) are SKIPPED — the per-module header already
	-- lists them in the "Sources:" section, and emitting a noisy
	-- "0 atom bodies" line per header is just clutter.
	if #atoms > 0 or #findings > 0 then
		info[#info + 1] = {
			line = 0,
			msg  = string.format("scanned: %s: %d atom bodies; %d findings",
				src.basename, #atoms, #findings),
		}
	end

	-- Phase 3: cycle-budget summary line. Per-path min/max totals.
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
-- Per-source output: build/gen/<basename>.static_analysis.txt
-- ════════════════════════════════════════════════════════════════════════════

local function emit_static_analysis_txt(ctx, src, result)
	local out_path = ctx.out_root .. "/" .. src.basename .. ".static_analysis.txt"
	if ctx.dry_run then return out_path end
	duffle.ensure_dir(ctx.out_root)

	local lines = {}
	local function add(s) lines[#lines + 1] = s end

	add("========================================================")
	add("STATIC ANALYSIS PASS -- " .. src.path)
	add("========================================================")
	add("")
	-- Tally atoms by kind for the header summary
	local n_atoms, n_bare, n_proc = 0, 0, 0
	for _, a in ipairs(result.atoms) do
		n_atoms = n_atoms + 1
		if a.kind == "comp_bare" then n_bare = n_bare + 1
		elseif a.kind == "comp_proc" then n_proc = n_proc + 1
		end
	end
	local header_atoms = string.format("Atoms: %d", n_atoms)
	if n_bare > 0 or n_proc > 0 then
		header_atoms = header_atoms .. string.format("  (atoms: %d, comp_bare: %d, comp_proc: %d)",
			n_atoms - n_bare - n_proc, n_bare, n_proc)
	end
	add(string.format("%s   Findings: %d   Errors: %d   Warnings: %d",
		header_atoms, #result.findings, #result.errors, #result.warnings))
	add("")

	-- Group findings by atom for readability
	local by_atom = {}
	for _, f in ipairs(result.findings) do
		by_atom[f.atom] = by_atom[f.atom] or {}
		by_atom[f.atom][#by_atom[f.atom] + 1] = f
	end

		if next(by_atom) == nil then
			add("  (no findings -- every atom passed all checks)")
		else
		add("── Findings by atom ─────────────────────────────────────")
		for _, a in ipairs(result.atoms) do
			local fs = by_atom[a.name]
			if fs then
				add(string.format("  %s   line %d", a.name, a.line))
				for _, f in ipairs(fs) do
					add(string.format("      [%s] %s", f.check, f.msg))
				end
			end
		end
	end

	add("")
	add("── Errors ──────────────────────────────────────────────")
	if #result.errors == 0 then add("  (none)") end
	for _, e in ipairs(result.errors) do
		add(string.format("  X line %d  %s", e.line, e.msg))
	end

	add("")
	add("── Warnings ────────────────────────────────────────────")
	if #result.warnings == 0 then add("  (none)") end
	for _, w in ipairs(result.warnings) do
		add(string.format("  ! line %d  %s", w.line, w.msg))
	end

	add("")
	add("── Info ────────────────────────────────────────────────")
	for _, i_ in ipairs(result.info) do
		add(string.format("  %s", i_.msg))
	end

	duffle.write_file(out_path, table.concat(lines, "\n") .. "\n")
	return out_path
end

-- (Old per-source emit function above kept for backward compat but no
-- longer called from M.run; replaced by `emit_module_static_analysis_txt`
-- which aggregates by directory. Kept because some test harnesses may
-- still call it directly.)

--- Per-directory emit. Aggregates atoms + findings across every source
--- in `dir_sources` and writes a single report to
--- `<out_root>/<dir_basename>.static_analysis.txt`. Called only when
--- at least one atom was found (the caller in M.run handles the skip).
local function emit_module_static_analysis_txt(ctx, dir, dir_sources, atoms, findings, errors, warnings, info)
	-- Module basename = last component of `dir` ("code/duffle" -> "duffle").
	local dir_basename = dir:match("([^/\\]+)$") or dir
	local out_path = ctx.out_root .. "/" .. dir_basename .. ".static_analysis.txt"
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
		if a.kind == "comp_bare" then n_bare = n_bare + 1
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

	-- Per-atom cycle counts (Phase 3 path-aware). For each atom:
	--   min   = shortest path through the body (earliest exit)
	--   max   = longest path through the body (full fall-through)
	--   br    = number of branch instructions
	--   paths = number of distinct paths reached
	-- Both min and max are best-case (no stalls); BD-slot nops are
	-- absorbed into branch costs (MIPS semantics). The previous "best
	-- case" model counted every token separately, which double-counted
	-- BD-slot nops; the path-aware model is the MIPS-accurate value.
	add("")
	add("── Per-atom cycle counts (path-aware, best case, no stalls) ─")
	if #atoms == 0 then
		add("  (no atoms)")
	else
		-- Sort atoms by max cycles descending for quick scanning.
		local sorted = {}
		for _, a in ipairs(atoms) do sorted[#sorted + 1] = a end
		table.sort(sorted, function(x, y) return (x.cycles_max or 0) > (y.cycles_max or 0) end)
		for _, a in ipairs(sorted) do
			local p = a.paths or {}
			local br_count = p.branches or 0
			local path_count = p.paths or 0
			local loops_tag = p.has_loops and "  [loop!]" or ""
			local unknown_tag = ""
			if a.unknown_macros and #a.unknown_macros > 0 then
				unknown_tag = string.format("  [unknown: %s]",
					table.concat(a.unknown_macros, ", "))
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
	-- One line per source that contributed atoms. The line includes
	-- the source basename + per-source atom count + (if path-aware
	-- cycle data is present) the min..max cycle range. Sources with
	-- 0 atoms are skipped (they're just header files that declared
	-- no MipsAtom_ — they're already listed in the module's
	-- "Sources:" section above).
	--
	-- TODO: per-source finding attribution. Currently we can't tell
	-- which source a given error/warning came from (errors/warnings
	-- only carry atom-name + line, not source-path). The per-atom
	-- cycle section already shows which atoms are in which source
	-- via the `(file_basename)` suffix. Adding source attribution to
	-- error/warning would be a future enhancement.
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
		local mn, mx = math.huge, -1
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
	local total_errs = #errors
	local total_warns = #warnings
	add("")
	add(string.format("Module findings:  %d error(s), %d warning(s)", total_errs, total_warns))

	-- Per-source "scanned:" info lines (each line includes the source
	-- basename for traceability).
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

	-- Phase 3.7+: aggregate per-DIRECTORY (per-module). One
	-- static_analysis.txt per source-directory, emitted only if the
	-- directory contains at least one atom. Empty-source directories
	-- (e.g. duffle headers with no atoms) produce no report.
	--
	-- Group sources by `src.dir`. The first component of `dir` is the
	-- module name (e.g. "code/duffle" -> "duffle", "code/gte_hello" ->
	-- "gte_hello"). Output path is `<out_root>/<module_basename>.static_analysis.txt`.
	local by_dir = {}
	for _, src in ipairs(ctx.sources) do
		by_dir[src.dir] = by_dir[src.dir] or {}
		table.insert(by_dir[src.dir], src)
	end

	for dir, dir_sources in pairs(by_dir) do
		-- Run validate() against every source in this directory; accumulate
		-- atoms / findings / errors / warnings. The validate() function
		-- does its own per-source analysis (Binds indexing, atom
		-- discovery, all 5 checks) and attaches path-aware cycle data to
		-- each atom it finds.
		local all_atoms    = {}
		local all_findings = {}
		local dir_errors   = {}
		local dir_warnings = {}
		local all_info     = {}
		for _, src in ipairs(dir_sources) do
			local result = validate(ctx, src)
			-- Tag each atom with its source so the render step can prefix
			-- the atom line with "<filename>:" when atoms from multiple
			-- sources live in the same module (e.g. lottes_tape.h +
			-- atom_dsl.h both declaring atoms).
			for _, a in ipairs(result.atoms) do
				a.source_path = src.path
				all_atoms[#all_atoms + 1] = a
			end
			for _, f in ipairs(result.findings) do
				all_findings[#all_findings + 1] = f
			end
			for _, e in ipairs(result.errors) do
				dir_errors[#dir_errors + 1] = e
			end
			for _, w in ipairs(result.warnings) do
				dir_warnings[#dir_warnings + 1] = w
			end
			for _, i_ in ipairs(result.info) do
				all_info[#all_info + 1] = i_
			end
		end

		-- Skip directories with zero atoms. The previous behavior emitted
		-- a "<no atoms>" report per source; the new behavior emits nothing
		-- at all (a directory with only headers / no MipsAtom_ is
		-- "nothing to report").
		if #all_atoms == 0 then
			-- Still aggregate errors/warnings so orchestrator sees them,
			-- but don't write a file.
			for _, e in ipairs(dir_errors) do errors[#errors + 1] = e end
			for _, w in ipairs(dir_warnings) do warnings[#warnings + 1] = w end
		else
			local out_path = emit_module_static_analysis_txt(ctx, dir, dir_sources, all_atoms, all_findings, dir_errors, dir_warnings, all_info)
			if out_path then
				table.insert(outputs, { static_analysis_txt = out_path })
			end
			for _, e in ipairs(dir_errors) do errors[#errors + 1] = e end
			for _, w in ipairs(dir_warnings) do warnings[#warnings + 1] = w end
		end
	end

	return { outputs = outputs, errors = errors, warnings = warnings }
end

return M
