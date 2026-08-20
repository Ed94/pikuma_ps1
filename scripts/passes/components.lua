--- passes/components.lua — Component-macro header generator.
---
--- Ownership: `corpus.word_counts`, `corpus.components`, and `corpus.component_body_index`.
--- Scanner owns `declaration_comment` and `debug_skip` on each declaration record; this pass projects both forward.
---
--- Reads the pre-scanned SourceScan payload from `duffle.scan_source` for `MipsAtomComp_(ac_X)` and `MipsAtomComp_Proc_(ac_X, { body })` declarations (kind="comp_bare" / "comp_proc"),
--- then resolves the function-args string from the preceding `FI_ Slice_MipsCode ac_X(...)` declaration via a backward walk.
---
--- `MipsAtom_Proc_(X, ab, { body })` declarations (kind="atom_proc") are ATOMS, not components, and are deliberately excluded —
--- the ELF symbol is the C ident. Raw `MipsCode code_*` is leftover, not the atom rule.
---
--- Emits one `gen/macs.h` per *immediate source directory* with `#define mac_X(sig) \` macros plus `WORD_COUNT(mac_X, N)` entries for downstream offset computation.
--- All sources inside the same directory contribute to the same file (per-directory aggregation).
--- The directory itself is the namespace, so the filename does not repeat the module name.

-- ════════════════════════════════════════════════════════════════════════════
-- Module-scope requires + package.path setup
-- ════════════════════════════════════════════════════════════════════════════

-- Bootstrap: same as entry scripts. See `ps1_meta.lua` for the rationale.
-- Bootstrap: load `scripts/duffle_paths.lua` (sets package.path + package.cpath).
-- Uses `debug.getinfo` to find this file's own directory, so it works both standalone and when require'd from the orchestrator.
-- Bootstrap: load `duffle_paths.lua` via `debug.getinfo(1, "S").source` (works both standalone + when require'd).
-- duffle_paths.lua sets package.path then returns `require("duffle")` at the bottom, so the dofile value IS the duffle module.
local _bootstrap_dir  = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local duffle          = dofile(_bootstrap_dir .. "../duffle_paths.lua")

-- ════════════════════════════════════════════════════════════════════════════
-- Constants
-- ════════════════════════════════════════════════════════════════════════════

-- Atom component declaration identifiers.
local ATOM_COMP_PROC  = "MipsAtomComp_Proc_"
local MIPS_ATOM       = "Slice_MipsCode"  -- prefix on the function declaration that wraps an AtomComp_Proc_

-- Component-name prefixes.
local AC_PREFIX       = "ac_"  -- arg to MipsAtomComp_(ac_X); the X is the atom name
local AC_PREFIX_LEN   = 3
local MAC_PREFIX      = "mac_" -- prefix on generated macros; the rest is the atom name
local MAC_PREFIX_LEN  = 4

-- ASCII byte values used in tokenization.
local BYTE_NEWLINE    = 10
local BYTE_SLASH      = 47

-- Output gen subdirectory + filename (per-directory aggregation; the directory name is the namespace).
local GEN_SUBDIR      = "gen"
local MACS_FILENAME   = "macs.h"

-- ════════════════════════════════════════════════════════════════════════════
-- Type declarations
-- ════════════════════════════════════════════════════════════════════════════

--- @class SourceFile
--- @field path     string  -- Absolute path to the source file
--- @field text     string  -- Full source text
--- @field dir      string  -- Directory containing the source
--- @field basename string  -- Filename without extension
--- @field scan     table   -- Pre-scanned SourceScan payload (from duffle.scan_source)

--- @class PassCtx
--- @field sources            SourceFile[]           -- All source files in the build
--- @field metadata_path      string                 -- Path to word_count.metadata.h
--- @field shared             table                  -- Cross-pass shared state
--- @field out_root           string                 -- Output root (e.g. "build/gen")
--- @field project_root       string                 -- Project root (e.g. "code/")
--- @field upstream           table<string, table>   -- Per-pass upstream outputs
--- @field flags              table                  -- CLI flags
--- @field verbose            boolean                -- Log diagnostic info

--- @class PassResult
--- @field outputs  table[]  -- {kind=, path=} entries describing emit files
--- @field errors   table[]  -- {line=, msg=}  entries; build-stops
--- @field warnings table[]  -- {line=, msg=}  entries; build-succeeds

--- @class Component
--- @field name       string     -- Atom name (without `ac_` prefix)
--- @field body       string     -- Brace-delimited body (without the braces)
--- @field args       string|nil -- Function-args string (function form only)
--- @field line       integer    -- Source line of the declaration
--- @field comment    string|nil -- Scanner-owned `declaration_comment`; the components pass reads it from the scanner record
--- @field kind       string     -- "comp_bare" | "comp_proc"  (atom_proc is NOT a component — see `project_components`)
--- @field debug_skip boolean    -- Mirror of `a.debug_skip` (scanner-owned); true iff a bare `atom_dbg_skip` marker immediately preceded the declaration

-- ════════════════════════════════════════════════════════════════════════════
-- Local helpers (file I/O + path normalization)
-- ════════════════════════════════════════════════════════════════════════════

local M = {}

-- ════════════════════════════════════════════════════════════════════════════
-- Back-walk helpers (composed into the entry point below: find_function_args_for)
--
-- Only the function-args lookup for proc components occurs here.
-- The preceding-comment walk occur in `scan_source.lua` — `a.declaration_comment` carries the resolved comment,
-- so this file reads it forward rather than re-walking the source.
-- ════════════════════════════════════════════════════════════════════════════

--- Find the args of the function declaration that immediately precedes a `MipsAtomComp_Proc_` invocation.
--- Returns the args string (e.g., `"U4 off, U4 code, U1 r, U1 g, U1 b"`) or nil if no function declaration is found.
---
--- After the `sym` arg was dropped from MipsAtomComp_Proc_, the component name
--- and the args both come from the preceding `FI_ Slice_MipsCode ac_X(args)` declaration.
--- The shared `duffle.find_function_decl_for` helper does the backward walk; this function returns just the args.
---
--- @param source     string
--- @param name       string  (retained for signature stability; unused — the walk derives the name)
--- @param before_pos integer
--- @return string|nil
local function find_function_args_for(source, name, before_pos)
	local _, args_inner = duffle.find_function_decl_for(source, before_pos, #MIPS_ATOM)
	return args_inner
end

-- ════════════════════════════════════════════════════════════════════════════
-- Argument-name extraction
-- ════════════════════════════════════════════════════════════════════════════

--- Extract just the parameter NAMES from a function-args string (stripping type annotations). E.g.,
---   `"U4 off, U4 code, U1 r, U1 g, U1 b"`  ->  `{"off", "code", "r", "g", "b"}`
---   `"U4 *ptr"`                            ->  `{"ptr"}`
---   `""`                                   ->  nil
--- @param args_str string|nil
--- @return string[]|nil
local function extract_arg_names(args_str)
	if not args_str or args_str == "" then return nil end
	local names  = {}
	local tokens = duffle.split_top_level_commas(args_str)
	for _, tok in ipairs(tokens) do
		local trimmed = duffle.trim(tok)
		if trimmed ~= "" then
			-- Strip trailing block comment (/* ... */) from the token, if present.
			-- split_top_level_commas only skips block comments at TOP LEVEL (between commas),
			-- not block comments embedded WITHIN a token between a parameter and a trailing comma.
			-- Without this strip, the identifier-walk below stops at the `/` of `*/` and returns
			-- the wrong name (or nothing). See `test_extract_arg_names_handles_trailing_block_comments`.
			local trimmed_end = #trimmed
			if trimmed_end >= 2 and trimmed:sub(trimmed_end - 1, trimmed_end) == "*/" then
				-- Find the matching `/*` that opens the trailing comment.
				-- Walk back from the `*/` looking for `/*` (whitespace + `/*`).
				local close_pos = trimmed_end - 1   -- position of the second-to-last char
				-- Walk back: skip trailing whitespace, then look for the `/*` opener.
				while close_pos > 1 do
					local ch = trimmed:sub(close_pos, close_pos)
					if ch == " " or ch == "\t" or ch == "\n" or ch == "\r" then
						close_pos = close_pos - 1
					else
						break
					end
				end
				-- Now scan back from close_pos for the `/*` opener (slashes are at close_pos-1 and close_pos-2).
				local opener_pos = nil
				local scan = close_pos - 3
				while scan >= 1 do
					if trimmed:sub(scan, scan + 1) == "/*" then
						opener_pos = scan
						break
					end
					scan = scan - 1
				end
				if opener_pos then
					-- Truncate everything from opener_pos onwards.
					trimmed = duffle.trim(trimmed:sub(1, opener_pos - 1))
				end
			end
			if trimmed == "" then goto continue end
			-- Strip trailing array suffix `[N]` if present.
			-- Example: `Reg r_data[4]` → identifier is `r_data`, not `4`.
			trimmed_end = #trimmed
			if trimmed_end >= 4 and trimmed:sub(trimmed_end, trimmed_end) == "]" then
				-- Walk back: skip digits, expect `[`.
				local bracket_pos = trimmed_end - 1
				while bracket_pos > 1 do
					local ch = trimmed:sub(bracket_pos, bracket_pos)
					if ch >= "0" and ch <= "9" then
						bracket_pos = bracket_pos - 1
					else
						break
					end
				end
				if bracket_pos >= 1 and trimmed:sub(bracket_pos, bracket_pos) == "[" then
					trimmed = duffle.trim(trimmed:sub(1, bracket_pos - 1))
				end
			end
			if trimmed == "" then goto continue end
			-- Find the identifier at the end: walk back over trailers (whitespace + `*` + `[]`),
			-- then walk back over the identifier chars (alnum + `_`).
			local ident_end = #trimmed
			while ident_end > 0 do
				local ch = trimmed:sub(ident_end, ident_end)
				if ch == " " or ch == "\t" or ch == "*" or ch == "]" or ch == "[" then
					ident_end = ident_end - 1
				else
					break
				end
			end
			local ident_start = ident_end
			while ident_start > 0 do
				local ch = trimmed:sub(ident_start, ident_start)
				if duffle.is_alnum_byte(string.byte(ch)) or ch == "_" then
					ident_start = ident_start - 1
				else
					break
				end
			end
			ident_start = ident_start + 1
			local name = trimmed:sub(ident_start, ident_end)
			if name ~= "" then names[#names + 1] = name end
			::continue::
		end
	end
	if #names == 0 then return nil end
	return names
end

local function formal_arg_names(args_str)
	local names = extract_arg_names(args_str)
	if not names then return nil end
	if names[1] == "ab" then table.remove(names, 1) end
	if #names == 0 then return nil end
	return names
end

-- ════════════════════════════════════════════════════════════════════════════
-- Component projection (read from pre-scanned SourceScan)
-- ════════════════════════════════════════════════════════════════════════════

--- Project pre-scanned MipsAtomComp_ / MipsAtomComp_Proc_ entries into Component shape.
--- Reads the scanner-owned `declaration_comment` (resolved by scan_source.lua, skipping backward across an associated bare `atom_dbg_skip` marker when present).
--- Per-source backward lookups remain in place only for the function `args` of proc components.
--- That lookup is unique to components.lua and stays separate from the declaration-comment walk.
--- Carries `body_tokens` forward from scan-source so word_count_rec reads from the precomputed table instead of calling duffle.tokenize_body again.
--- Carries the scanner-owned `debug_skip` flag forward so the generated projection can emit `/* atom_dbg_skip */`
--- before the authored comment and so `update_canonical_components` can mirror the same field onto `corpus.components[name]`.
--- @param source string  -- the full source text (needed for backward lookups)
--- @param scan   table   -- SourceScan from duffle.scan_source
--- @return Component[]
local function project_components(source, scan)
	local out = {}
	for _, a in ipairs(scan.atoms) do
		-- Only `MipsAtomComp_(ac_X)` (kind="comp_bare") and `MipsAtomComp_Proc_(ac_X, ...)` (kind="comp_proc")
		-- are COMPONENTS — they get inlined via `mac_<name>` aliases inside atom bodies.
		-- `MipsAtom_Proc_` (kind="atom_proc") is an ATOM (ends with `mac_yield()`); it gets emitted via
		-- `tb_emit` of the C ident, NOT inlined as a macro. Including `atom_proc` here
		-- would incorrectly emit `mac_<name>` aliases for atoms, polluting `gen/macs.h`.
		-- See `docs/duffle_dsl_primer.md` §"mac_* aliases" for the contract.
		if a.kind == "comp_bare" or a.kind == "comp_proc" then
			-- Function-args lookup is meaningful for `MipsAtomComp_Proc_` components
			-- (the macro sits inside `FI_ Slice_MipsCode ac_X(...)`); the alias expansion
			-- discards the `ab` (atom-builder) arg the same way both forms do.
			local args = find_function_args_for(source, a.raw_name, a.ident_pos)
			-- Comment ownership: scan_source.lua stamps `declaration_comment` on the record by walking backward past any associated bare marker.
			-- The pass reads `declaration_comment` directly.
			local comment = a.declaration_comment or ""
			out[#out + 1] = {
				line        = a.line,
				name        = a.name,
				body        = a.body,
				body_off    = a.body_off,
				body_tokens = a.body_tokens,
				args        = args,
				arg_names   = formal_arg_names(args),
				comment     = comment,
				kind        = a.kind,  -- "comp_bare" | "comp_proc"; provenance emitter reads this.
				debug_skip  = a.debug_skip == true,
			}
		end
	end
	return out
end

-- ════════════════════════════════════════════════════════════════════════════
-- Line-comment → block-comment conversion
-- ════════════════════════════════════════════════════════════════════════════

-- Convert `//` line comments to `/* */` block comments in a token.
-- C macros use `\` line-continuations; a `//` comment before `\` would consume the continuation,
-- breaking the macro. We convert `//` to `/* */` so the multi-line macro structure is preserved.
--
-- Skips `//` sequences that are inside string or character literals
-- (a rough heuristic — sufficient for component bodies which don't have those constructs).
--- @param s string
--- @return string
local function convert_line_comments_to_block(s)
	local result = s
	local pos    = 1
	local len    = #result
	while pos <= len do
		local is_double_slash = result:byte(pos) == BYTE_SLASH
			and pos + 1 <= len and result:byte(pos + 1) == BYTE_SLASH
		if not is_double_slash then
			pos = pos + 1
		else
			-- Find end of line.
			local eol = pos
			while eol <= len and result:byte(eol) ~= BYTE_NEWLINE do
				eol = eol + 1
			end
			local before  = result:sub(1, pos - 1)
			local comment = result:sub(pos + 2, eol - 1)  -- skip the `//`
			local after
			if eol <= len and result:byte(eol) == BYTE_NEWLINE then
				after = " */" .. result:sub(eol)  -- keep the newline
			else
				after = " */"
			end
			result = before .. "/*" .. comment .. after
			pos = #before + 2 + #comment + 3  -- skip past converted comment
		end
	end
	return result
end

-- ════════════════════════════════════════════════════════════════════════════
-- Word-count computation (memoized recursive lookup)
-- ════════════════════════════════════════════════════════════════════════════

--- Strip the `mac_` prefix from a component-call ident so we can look it up against the components-by-name table. 
--- Returns the ident unchanged if it doesn't start with the prefix 
--- (so a non-component ident like `mask_upper` falls through to the wc-table branch).
--- @param ident string|nil
--- @return string|nil
local function strip_mac_prefix(ident)
	if not ident then return nil end
	if ident:sub(1, MAC_PREFIX_LEN) == MAC_PREFIX then
		return ident:sub(MAC_PREFIX_LEN + 1)
	end
	return ident
end

--- Strip a leading delay marker (`LdSlot_` / `BdSlot_` / `GteDelay_` / `DmaSlot_`)
--- plus following whitespace and block comments. Returns the remainder, or ""
--- when the token is only the marker.
--- `BdSlot_ nop` becomes `nop`. Bare `LdSlot_` becomes "".
--- @param tok string
--- @return string
local function strip_leading_delay_marker(tok)
	local  ident = duffle.read_ident(tok, 1)
	if not ident or not duffle.DELAY_MARKERS[ident] then return tok end
	local rest = tok:sub(#ident + 1):match("^%s*(.*)$") or ""
	while rest:sub(1, 2) == "/*" do
		local  close = rest:find("*/", 3, true)
		if not close then return "" end
		rest = rest:sub(close + 2):match("^%s*(.*)$") or ""
	end
	return rest
end

--- (internal) Recursive word-count lookup. `cache` is the memoization table shared across all components
--- in a single source's `count_all_components` pass; the in-progress -1 sentinel detects cycles (A -> B -> A).
--- @param name         string -- the component name (without `mac_`)
--- @param comp_by_name table<string, Component>
--- @param wc           table<string, integer>
--- @param cache        table<string, integer>
--- @return integer
local function word_count_rec(name, comp_by_name, wc, cache)
	if cache[name] ~= nil then return cache[name] end
	cache[name] = -1  -- mark in-progress (cycle detection)
	local cc = comp_by_name[name]
	local n
	if cc then
		n = 0
		local tokens = cc.body_tokens
		for _, t in ipairs(tokens) do
			local trimmed = t.tok
			if trimmed ~= "" then
				local work = trimmed
				while true do
					local marker = duffle.read_ident(work, 1)
					if marker and duffle.DELAY_MARKERS[marker] then
						work = strip_leading_delay_marker(work)
						if work == "" then break end
					else
						break
					end
				end
				if work ~= "" then
					local lookup = strip_mac_prefix(duffle.read_ident(work, 1))
					if lookup == "atom_label" or lookup == "atom_offset" then
						-- Pure metaprogram anchors; emit zero words.
					elseif lookup and comp_by_name[lookup] then
						-- It's a `mac_X(...)` call. Recurse.
						n = n + word_count_rec(lookup, comp_by_name, wc, cache)
					elseif lookup and wc and wc[lookup] then
						-- Encoding macro or pseudo-instruction (e.g. mask_upper = 2, nop2 = 2).
						n = n + wc[lookup]
					else
						-- Unrecognized token. Fall back to 1 word.
						n = n + 1
					end
				end
			end
		end
	else
		-- Not a known component: assume 1 word (regular instruction).
		n = 1
	end
	cache[name] = n
	return n
end

--- Compute word counts for every component in `components` in a single pass.
--- The name-lookup table + memoization cache are built ONCE (per source) instead of per-component,
--- so the cache survives across siblings and a component's recursive `mac_Y(...)` 
--- references hit memoized values instead of re-walking the body.
--- Cycle detection (A -> B -> A) is preserved via the in-progress `-1` sentinel in `cache`.
--- @param components Component[]
--- @param wc         table<string, integer>
--- @return table<string, integer>  -- map of component name (without `mac_`) -> word count
local function count_all_components(components, wc)
	local comp_by_name = {}
	for _, cc in ipairs(components) do comp_by_name[cc.name] = cc end
	local cache        = {}
	local counts       = {}
	for _, c in ipairs(components) do
		counts[c.name] = word_count_rec(c.name, comp_by_name, wc, cache)
	end
	return counts
end

-- ═══════════════════════════════════════════
-- Per-component metadata derivation (replaces the hardcoded `M.GP0_MACRO_CONTRIB` + `M.INSTRUCTION_LATENCY[mac_*]` tables that previously lived in `duffle.lua`).
--
-- Each `MipsAtomComp_(ac_X) { body }` definition in `code/duffle/lottes_tape.h` is the canonical source.
-- The `mac_X(...)` macros are GENERATED from these definitions by `emit_component_macros_h` for tape-side composition;
-- the metaprogram must NEVER walk the generated variants to derive metadata.
-- Always walk the original `MipsAtomComp_` body via `cc.body_tokens`.
-- ═══════════════════════════════════════════

--- (internal) One walk of a component body that fills both `cycle_cost` and `gp0_contrib`.
--- Cycle: sum `isa.cycles` / `gte.cycles` / `latency[ident]` / 1 per leaf, recurse `mac_*`.
--- `mac_yield` cycle_cost is 0 (runtime cost lands in the next atom's prologue); its gp0 still comes from the token walk.
--- GP0: count `gte_sw` and `store_word` / `store_half` / `store_byte` that target `R_PrimCursor` / `O_(Poly_` / `r_prim_cursor` / `r_primitive_cursor` / `r_base`.
--- `insert_ot_tag*` gp0_contrib is 0; cycle still comes from the body walk.
--- Missing component: cycle 1, gp0 0.
--- @param name         string  -- component bare name (e.g. "yield", "pack_color_word")
--- @param comp_by_name table<string, Component>
--- @param latency      table<string, integer>
--- @param cache        table<string, {cycle_cost=integer, gp0_contrib=integer}>
--- @return {cycle_cost=integer, gp0_contrib=integer}
local function component_meta_rec(name, comp_by_name, latency, cache)
	if cache[name] ~= nil then return cache[name] end
	cache[name] = { cycle_cost = -1, gp0_contrib = -1 }
	local cc = comp_by_name[name]
	local cycle_cost
	local gp0_contrib
	if cc then
		local skip_cycle = (name == "yield")
		local skip_gp0   = name:match("^insert_ot_tag") ~= nil
		cycle_cost  = 0
		gp0_contrib = 0
		if not skip_cycle or not skip_gp0 then
			local tokens = cc.body_tokens
			for _, t in ipairs(tokens) do
				local trimmed = t.tok
				if trimmed ~= "" then
					local ident = duffle.read_ident(trimmed, 1)
					if    ident and ident:sub(1, MAC_PREFIX_LEN) == MAC_PREFIX then
						local nested = ident:sub(MAC_PREFIX_LEN + 1)
						local nested_meta = component_meta_rec(nested, comp_by_name, latency, cache)
						if not skip_cycle then
							cycle_cost = cycle_cost + nested_meta.cycle_cost
						end
						if not skip_gp0 then
							gp0_contrib = gp0_contrib + nested_meta.gp0_contrib
						end
					else
						if not skip_cycle then
							local isa = duffle.instr(ident)
							local gte = duffle.gte(ident)
							cycle_cost = cycle_cost + ((isa and isa.cycles) or (gte and gte.cycles) or latency[ident] or 1)
						end
						if not skip_gp0 then
							if ident == "gte_sw" then
								gp0_contrib = gp0_contrib + 1
							elseif ident == "store_word" or ident == "store_half" or ident == "store_byte" then
								if trimmed:find("R_PrimCursor", 1, true)
									or trimmed:find("O_(Poly_", 1, true)
									or trimmed:find("r_prim_cursor", 1, true)
									or trimmed:find("r_primitive_cursor", 1, true)
									or trimmed:find("r_base", 1, true)
								then
									gp0_contrib = gp0_contrib + 1
								end
							end
						end
					end
				end
			end
		end
	else
		cycle_cost  = 1
		gp0_contrib = 0
	end
	cache[name] = { cycle_cost = cycle_cost, gp0_contrib = gp0_contrib }
	return cache[name]
end

--- Compute `cycle_cost` + `gp0_contrib` for every component in `components` in a single pass.
--- One memoization cache; a nested `mac_Y` inside a `mac_X` body computes both fields once.
--- @param components Component[]
--- @param latency    table<string, integer>
--- @return table<string, {cycle_cost=integer, gp0_contrib=integer}>
local function compute_components_metadata(components, latency)
	local comp_by_name = {}
	for _, cc in ipairs(components) do comp_by_name[cc.name] = cc end
	local cache = {}
	local out   = {}
	for _, c in ipairs(components) do
		out[c.name] = component_meta_rec(c.name, comp_by_name, latency, cache)
	end
	return out
end

-- ════════════════════════════════════════════════════════════════════════════
-- Per-component emit logic
-- ════════════════════════════════════════════════════════════════════════════

--- Split a (possibly multi-line) comment into per-line entries.
--- Hand-rolled (no regex patterns used).
--- @param s string
--- @return string[]
local function split_comment_lines(s)
	local out   = {}
	local pos   = 1
	local s_len = #s
	while pos <= s_len do
		local nl = s:find("\n", pos, true)
		if not nl then
			out[#out + 1] = s:sub(pos)
			break
		end
		out[#out + 1] = s:sub(pos, nl - 1)
		pos = nl + 1
	end
	return out
end

--- Determine the macro signature: function-args list (function form) or variadic-ignored (bare form).
--- For `MipsAtomComp_Proc_` components, the leading `ab` (atom-builder) arg is dropped:
--- the generated `mac_<name>` macros are inline-expansion aliases for baked atoms; their bodies don't reference `ab`
--- (the builder is only consumed by the procedural `atombuilder_unroll` line that `MipsAtomComp_Proc_` appends after the body).
--- Inline callers therefore don't need to thread a builder context.
--- @param args_str string|nil
--- @return string
local function signature_from_args(args_str)
	local names = formal_arg_names(args_str)
	if names then
		return table.concat(names, ", ")
	end
	return "..."
end

--- Strip the trailing `" \"` (space + backslash) line continuation from the last body line.
--- The last 2 chars are always that pair.
local function strip_trailing_continuation(lines)
	local last = lines[#lines]
	if    last:sub(-2) == " \\" then
		lines[#lines] = last:sub(1, -3)
	end
end

--- Classify a token as a "pure delay marker token" (a delay-marker identifier with no following instruction — only whitespace and/or block comments).
--- Examples that match:
---   * `GteDelay_`                               → marker alone
---   * `GteDelay_  /* RT diagonal: D1 = a.x... */` → marker + block comment
---   * `GteDelay_  /* RT diagonal: ... */\n\t`    → marker + comment + trailing whitespace
--- Examples that DO NOT match (these contain a real instruction after the marker and must be preserved verbatim so the instruction still gets emitted):
---   * `GteDelay_ nop2`
---   * `GteDelay_ add_si(r.dst_ptr, r.scratch, dst_offset)`
---
--- Why this classification matters: the metaprogram emits tokens separated by `,` and joins them with `\<newline>` line continuations. After C preprocessor
--- phase 2 (line splicing), the macro body collapses to a single logical line.
--- Each delay-marker identifier expands to empty (its definition `#define GteDelay_ // ...` consumes the `//` line comment during preprocessing
--- of the definition itself, leaving an empty replacement list). 
--- When a token is purely a delay marker with only a trailing comment, the `,` the metaprogram normally adds before 
--- each token-after-the-first brackets empty content and produces the syntax error `,,` (`expected expression before ',' token`) at C compile.
--- The metaprogram therefore emits such tokens WITHOUT the leading `,` (see `token_skips_leading_comma`) —
--- but the marker + trailing comment are still emitted verbatim so the annotation is preserved in `gen/macs.h`.
--- @param tok string  -- a single token from split_top_level_commas (already trimmed at the start, may contain trailing whitespace + block comment)
--- @return boolean
local function is_pure_delay_marker_token(tok)
	local markers = duffle.DELAY_MARKERS
	if type(markers) ~= "table" then return false end

	-- Identify a leading delay-marker identifier (e.g. `GteDelay_`).
	local ident_end = 1
	while ident_end <= #tok do
		local ch = tok:sub(ident_end, ident_end)
		if ch:match("[%w_]") then
			ident_end = ident_end + 1
		else
			break
		end
	end
	local ident = tok:sub(1, ident_end - 1)
	if not markers[ident] then return false end

	-- Walk the remainder: only whitespace and block comments are allowed.
	local scan = ident_end
	while scan <= #tok do
		local ch = tok:sub(scan, scan)
		if    ch:match("%s") then
			scan = scan + 1
		elseif ch == "/" and tok:sub(scan + 1, scan + 1) == "*" then
			local close = tok:find("*/", scan + 2, true)
			if not close then return false end
			scan = close + 2
		else
			-- Non-whitespace, non-block-comment content: a real instruction
			-- follows the marker (e.g. `GteDelay_ nop2`); keep this token intact.
			return false
		end
	end
	return true
end

--- Classify a token's "leading comma requirement".
--- Pure delay-marker tokens (`GteDelay_` / `LdSlot_` / `BdSlot_` / `DmaSlot_`
--- followed by whitespace + optional block comment and NOTHING ELSE) expand
--- to empty at C preprocessor time. Emitting them WITHOUT the leading `,`
--- separator that the metaprogram normally adds before each token after the
--- first keeps exactly one `,` between the surrounding real expressions in the spliced macro body:
---   * before this rule:  `<tok1> ,\t<gdelay> ,\t<tok3>` → after expansion
---                        `<tok1> ,  /* comment */ , <tok3>` → `,,` syntax error.
---   * after  this rule:  `<tok1> \t<gdelay> ,\t<tok3>` → after expansion
---                        `<tok1>  /* comment */ , <tok3>` → `<tok1>, <tok3>` — valid.
---
--- Tokens like `GteDelay_ nop2` keep the leading `,`
--- (the marker is followed by a real instruction, so the marker + instruction together need the separator on the LEFT to land between two real expressions).
--- @param tok string
--- @return boolean  -- true if the token needs NO leading `,` separator.
local function token_skips_leading_comma(tok)
	return is_pure_delay_marker_token(tok)
end

--- Emit the `#define mac_X(sig) \<newline>\t<tok1> \<newline>,\t<tok2> ...` block.
--- Converts `//` line comments to `/* */` block comments in each token so they don't break the C macro `\` line continuations.
---
--- Pure delay-marker tokens (`GteDelay_` / `LdSlot_` / `BdSlot_` / `DmaSlot_` with only a trailing block comment, no real instruction) are emitted WITHOUT a leading `,` separator;
--- the annotation IS preserved in the generated header
--- (so the comment + marker remain visible to anyone reading `gen/macs.h`), but the C preprocessor expands the marker to empty, so leaving the `,`
--- separator out is what stops the `,,` syntax error. See `token_skips_leading_comma` for the contract.
local function emit_macro_body(lines, c, sig, tokens)
	for tok_idx = 1, #tokens do
		tokens[tok_idx] = convert_line_comments_to_block(tokens[tok_idx])
	end
	if #tokens == 0 then return end
	lines[#lines + 1] = "#define mac_" .. c.name .. "(" .. sig .. ") \\"
	lines[#lines + 1] = "\t" .. tokens[1] .. " \\"
	for tok_idx = 2, #tokens do
		local sep = token_skips_leading_comma(tokens[tok_idx]) and "\t" or ",\t"
		lines[#lines + 1] = sep .. tokens[tok_idx] .. " \\"
	end
	strip_trailing_continuation(lines)
end

--- Build the list of lines for one component
--- (signature comment, `#define mac_X(...)` line with backslash-continued tokens, then `WORD_COUNT(mac_X, N)` entry).
--- For skipped components, a `/* atom_dbg_skip */` marker comment is emitted immediately before the authored comment block.
--- The marker is a single line, the comment comes next, and the `#define` line follows. The `debug_skip` stamp is scanner-owned
--- (`a.debug_skip == true` on the declaration record); the components pass projects it directly.
--- @param c          Component
--- @param components Component[]
--- @param wc         table<string, integer>
--- @return string[]  -- list of lines for this component
local function build_component_lines(c, counts)
	local lines = {}

	-- Marker comment: emitted once for every skipped component.
	-- The marker is scanner-owned (declared by `atom_dbg_skip` immediately before the declaration in the source);
	-- This pass projects `c.debug_skip` and emits the marker as a generated comment.
	if c.debug_skip then
		lines[#lines + 1] = "/* atom_dbg_skip */"
	end

	if c.comment and c.comment ~= "" then
		for _, line in ipairs(split_comment_lines(c.comment)) do
			lines[#lines + 1] = line
		end
	end

	local tokens = duffle.split_top_level_commas(c.body)
	for i = 1, #tokens do tokens[i] = duffle.trim(tokens[i]) end
	local sig = signature_from_args(c.args)
	-- Direct lookup against the per-source precomputed `counts` table (built once by count_all_components).
	local n   = counts[c.name]

	if n > 0 then
		emit_macro_body(lines, c, sig, tokens)
	end

	-- Emit the WORD_COUNT(mac_<X>, N) entry.
	lines[#lines + 1] = "WORD_COUNT(mac_" .. c.name .. ", " .. n .. ")"
	lines[#lines + 1] = ""

	return lines
end

-- ════════════════════════════════════════════════════════════════════════════
-- Per-source emit logic
-- ════════════════════════════════════════════════════════════════════════════

--- Build the boilerplate header lines (the `#ifdef INTELLISENSE_DIRECTIVES` block,
--- the `// Auto-generated` comment, the `// Source:` line, and the self-contained `WORD_COUNT` macro definition).
--- @param dir     string       -- Absolute source directory
--- @param sources SourceFile[] -- Sources contributing to this directory (for the header comment)
--- @return string[]
local function header_boilerplate(dir, sources)
	local source_lines = { "// Directory: " .. duffle.to_absolute_path(dir) .. "/" }
	for _, src in ipairs(sources) do
		source_lines[#source_lines + 1] = "//   source: " .. duffle.to_absolute_path(src.path)
	end
	local source_blob = table.concat(source_lines, "\n")
	return {
		-- #pragma once wrapped in #ifdef INTELLISENSE_DIRECTIVES, matching the convention in lottes_tape.h.
		-- The build does manual unity includes (the user controls include order), so the pragma is only active for IDE/tooling.
		"#ifdef INTELLISENSE_DIRECTIVES",
		"#pragma once",
		"#endif",
		"// Auto-generated by ps1_meta.lua — DO NOT EDIT",
		source_blob,
		"// Component atoms (MipsAtomComp_(ac_*)) -> macro variants (mac_*)",
		"",
		-- Self-contained: define WORD_COUNT if not already defined.
		-- We use the same definition here so the auto-generated entries below expand
		-- to compile-time constants whether the metadata file is included first or not.
		"#ifndef WORD_COUNT",
		"#define WORD_COUNT(name, count)  enum { words_##name = (count) };",
		"#endif",
		"",
	}
end

--- Compute the per-directory output path for `.macs.h`.
---  e.g. any source in `code/duffle/` produces `code/duffle/gen/macs.h` regardless of source filename.
--- The directory name is the namespace; the filename does not repeat it.
--- @param dir string  -- Absolute source directory
--- @return string  -- Output directory
--- @return string  -- Full output path
local function compute_macs_h_path(dir)
	local  out_dir  = dir .. "/" .. GEN_SUBDIR
	local  out_path = out_dir .. "/" .. MACS_FILENAME
	return out_dir, out_path
end

--- Emit a per-directory `.macs.h` header with the aggregated `mac_X` macros + `WORD_COUNT` entries.
--- Writes in BINARY mode so LF line endings are preserved (the git blob is LF; Windows text-mode would emit CRLF and break the byte-identical diff).
--- @param ctx        PassCtx
--- @param dir        string                  -- Absolute source directory
--- @param sources    SourceFile[]            -- Sources contributing to this directory (for the header comment)
--- @param components Component[]             -- Aggregated components from all sources in this directory
--- @param counts     table<string, integer>  -- Precomputed word counts (from count_all_components)
--- @return string|nil -- Path to the written file (nil if no components)
local function emit_component_macros_h(ctx, dir, sources, components, counts)
	if #components == 0 then return nil end
	local out_dir, out_path = compute_macs_h_path(dir)
	local lines             = header_boilerplate(dir, sources)

	for _, c in ipairs(components) do
		for _, l in ipairs(build_component_lines(c, counts)) do
			lines[#lines + 1] = l
		end
	end

	local content = table.concat(lines, "\n") .. "\n"
	duffle.ensure_dir(out_dir)
	duffle.write_file_lf(out_path, content)
	print(string.format("  -> %s", out_path))
	return out_path
end

-- ════════════════════════════════════════════════════════════════════════════
-- Pass entry
-- ════════════════════════════════════════════════════════════════════════════

--- (internal) Extend `corpus.word_counts` with this source's component macros so offsets sees them without re-reading the file.
--- First declaration wins: a later caller's count is dropped (the existing entry from the first source is preserved).
--- @param corpus     table  -- the corpus
--- @param components Component[]
--- @param counts     table<string, integer>  -- precomputed word counts (from count_all_components)
local function update_canonical_word_counts(corpus, components, counts)
	local wc = corpus.word_counts
	for _, c in ipairs(components) do
		local key = "mac_" .. c.name
		if wc[key] == nil then
			wc[key] = counts[c.name]
		end
	end
end

--- @class ComponentDef
--- @field name       string  -- Bare name (without ac_/mac_ prefix)
--- @field line       integer -- Definition source line (line of `MipsAtomComp_(ac_X)` / `MipsAtomComp_Proc_(ac_X, ...)`)
--- @field path       string  -- Absolute source path of the definition
--- @field kind       string  -- "comp_bare" | "comp_proc"  (atom_proc is NOT a component)
--- @field debug_skip boolean -- Mirror of the scanner-owned `a.debug_skip`; consumers read this directly

--- (internal) Populate `corpus.components` with this source's components-by-name map.
--- First declaration wins; later declarations of the same bare name are dropped and recorded as a collision via `corpus.collisions` (kind = "component").
--- The pass does NOT write to `ctx.shared.components`.
--- No parallel skip map is built here; consumers that need the per-component skip state read `corpus.components[name].debug_skip` directly.
--- The `cycle_cost` + `gp0_contrib` fields are populated from `metadata[c.name]` (computed by `compute_components_metadata` against the original `MipsAtomComp_` body).
--- @param corpus     table   -- the corpus
--- @param src        SourceFile
--- @param components Component[]
--- @param metadata    table<string, {cycle_cost=integer, gp0_contrib=integer}>
local function update_canonical_components(corpus, src, components, metadata)
	local rel_path = src.path:gsub("\\", "/")
	for _, c in ipairs(components) do
		-- Keyed by bare name (e.g. `yield`, `load_tri_indices`).
		-- The atoms_source_map pass looks up components by bare name from the corpus;
		-- `mac_` prefix lives at the call-site identifier and is stripped before lookup.
		local m = metadata and metadata[c.name] or nil
		if corpus.components[c.name] == nil then
			corpus.components[c.name] = {
				name        = c.name,
				line        = c.line,
				path        = rel_path,
				kind        = c.kind or "comp_bare",
				debug_skip  = c.debug_skip == true,
				cycle_cost  = m and m.cycle_cost  or nil,
				gp0_contrib = m and m.gp0_contrib or nil,
			}
		else
			-- A second declaration of the same bare name: record a typed collision so static-analysis + the report can surface it.
			-- Identical-shape declarations (same path + line) reuse the first-wins entry without a collision record.
			local existing = corpus.components[c.name]
			if existing.path ~= rel_path or existing.line ~= c.line then
				local kind       = c.kind or "comp_bare"
				local first_kind = existing.kind or "comp_bare"
				corpus.collisions[#corpus.collisions + 1] = {
					kind              = "component",
					name              = c.name,
					first_site        = { path = existing.path, line = existing.line },
					conflicting_site  = { path = rel_path,       line = c.line },
					first_shape       = "kind=" .. first_kind,
					conflicting_shape = "kind=" .. kind,
				}
			end
		end
	end
end

--- (internal) Populate `corpus.component_body_index` with this source's body index entries.
--- First declaration wins; later declarations are dropped (no separate collision record: the components collision is already surfaced by `update_canonical_components`).
--- The pass writes to `corpus.component_body_index` only (the corpus owns this projection).
--- @param corpus     table  -- the corpus
--- @param src        SourceFile
--- @param components Component[]
--- @param scan       table  -- the SourceScan payload (for line_of)
local function update_canonical_component_body_index(corpus, src, components, scan)
	local line_of = scan and scan.line_of
	for _, c in ipairs(components) do
		if corpus.component_body_index[c.name] == nil then
			corpus.component_body_index[c.name] = {
				body_tokens = c.body_tokens,
				body_off    = c.body_off,
				line_of     = line_of,
				source      = src.path,
				declaration = c.line,
				kind        = c.kind,
				arg_names   = c.arg_names,
			}
		end
	end
end

--- @param ctx PassCtx
--- @return PassResult
function M.run(ctx)
	local outputs  = {}
	local errors   = {}
	local warnings = {}

	-- Corpus ownership gate.
	local corpus = ctx.shared and ctx.shared.corpus
	if type(corpus) ~= "table" then
		error("components.run requires ctx.shared.corpus.", 0)
	end
	if type(corpus.source_order) ~= "table" then
		error("components.run requires ctx.shared.corpus.source_order.", 0)
	end
	if type(corpus.word_counts) ~= "table" then
		error("components.run requires ctx.shared.corpus.word_counts; "
			.. "word_count_eval.run must run before components.run "
			.. "(see PASSES deps).", 0)
	end

	-- Projection ownership:
	--   * `corpus.word_counts["mac_"..name]` — current component count
	--   * `corpus.components[name]`         — bare-name component definition
	--   * `corpus.component_body_index[name]` — body / line_of / source index
	-- The pass writes to the corpus only; consumers read from the corpus directly.

	-- Per-directory aggregation: every source in the same directory contributes to one `gen/macs.h`.
	-- The directory itself is the namespace. `corpus.sources_by_dir` preserves source-order within each bucket (matches `corpus.source_order`).
	local sources_by_dir = corpus.sources_by_dir or duffle.group_sources_by_dir(corpus.source_order)
	for dir, sources in pairs(sources_by_dir) do
		-- Aggregate components from every source in this directory.
		-- `project_components` returns nil for sources with no `MipsAtomComp_` declarations; we skip those.
		local aggregated_components = {}
		local metadata_per_source   = {}
		for _, src in ipairs(sources) do
			local per_source = project_components(src.text, src.scan) or {}
			for _, c in ipairs(per_source) do
				aggregated_components[#aggregated_components + 1] = c
			end
			if #per_source > 0 then
				metadata_per_source[src] = compute_components_metadata(per_source, {})
			end
		end
		if #aggregated_components > 0 then
			-- Compute word counts across the aggregated set. `corpus.word_counts` carries the
			-- same-source + prior-directory entries so the recursive lookup sees both.
			local counts    = count_all_components(aggregated_components, corpus.word_counts)
			local macs_path = emit_component_macros_h(ctx, dir, sources, aggregated_components, counts)
			if macs_path then
				outputs[#outputs + 1] = { macs_h = macs_path }
				-- Populate the projections AFTER disk emission (byte-identical `.macs.h` contract).
				update_canonical_word_counts(corpus, aggregated_components, counts)
				for _, src in ipairs(sources) do
					local per_source = project_components(src.text, src.scan) or {}
					if #per_source > 0 then
						update_canonical_components(corpus, src, per_source, metadata_per_source[src])
						update_canonical_component_body_index(corpus, src, per_source, src.scan)
					end
				end
			end
		end
	end

	return { outputs = outputs, errors = errors, warnings = warnings }
end

return M
