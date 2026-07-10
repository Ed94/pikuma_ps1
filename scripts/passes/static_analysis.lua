-- passes/static_analysis.lua
--
-- Per-atom static-analysis checks for the tape-atom build pipeline.
-- Currently ships Phase 1 checks (GTE pipeline-fill + mac_yield
-- uniformity). Phases 2/3 (ABI handoff discipline, GPU port-store
-- shape, per-atom cycle budget) extend this file.
--
-- Workspace boundary: same conventions as annotation.lua
--   - primitives from duffle.lua (read_parens, read_braces, scan_to_char, LineIndex)
--   - LPeg not needed: pure hand-rolled string scanning
--   - 5.3-compatible (no <close>, no continue keyword)
--   - no :match/:gmatch
--   - tab indent, EmmyLua @class/@param annotations
--
-- The orchestrator (ps1_meta.lua) wires this module in via the
-- PASSES table:
--   ["static-analysis"] = {
--       module = "passes.static_analysis",
--       kind   = "validation",      -- errors stop the build
--       deps   = {"word-counts", "components"},
--       out    = { { kind = "report",
--                    path_template = "<out_root>/<basename>.static_analysis.txt" } },
--   }

-- ════════════════════════════════════════════════════════════════════════════
-- Module-scope requires + package.path setup
-- ════════════════════════════════════════════════════════════════════════════

local script_path = arg and arg[0] or "?"
local last_sep = 0
for i = 1, #script_path do
	local c = script_path:sub(i, i)
	if c == "/" or c == "\\" then last_sep = i end
end
local script_dir = last_sep == 0 and "./" or script_path:sub(1, last_sep)
package.path   = script_dir .. "../?.lua;" .. script_dir .. "../?/init.lua;" .. script_dir .. "?.lua;" .. package.path

local duffle             = require("duffle")
local read_ident         = duffle.read_ident
local skip_ws_and_cmt    = duffle.skip_ws_and_cmt
local read_parens        = duffle.read_parens
local read_braces        = duffle.read_braces
local read_brackets      = duffle.read_brackets
local scan_to_char       = duffle.scan_to_char
local split_top_level_commas = duffle.split_top_level_commas
local trim               = duffle.trim
local ensure_dir         = duffle.ensure_dir
local write_file         = duffle.write_file
local basename_no_ext    = duffle.basename_no_ext

-- Latency table lives in duffle.lua (shared between this pass + future
-- per-atom cycle-budget pass). Lazily read on first use.
local GTE_PIPELINE_LATENCY = duffle.GTE_PIPELINE_LATENCY

-- GP0 domain tables (Phase 2 check #4). Same source as GTE_PIPELINE_LATENCY.
local GP0_CMD_SIZE       = duffle.GP0_CMD_SIZE
local GP0_CMD_BY_SHAPE   = duffle.GP0_CMD_BY_SHAPE
local GP0_MACRO_CONTRIB  = duffle.GP0_MACRO_CONTRIB

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
	local len      = #source_text
	local i        = 1
	while i <= len do
		i = skip_ws_and_cmt(source_text, i); if i > len then break end
		local ident, after = read_ident(source_text, i)
		if not ident then
			i = i + 1
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

			local open = skip_ws_and_cmt(source_text, after)
			if source_text:sub(open, open) ~= "(" then
				i = open + 1
			else
				local inner, after_paren = read_parens(source_text, open)

				if kind == "comp_proc" then
					-- MipsAtomComp_Proc_(sym, { body })
					-- The body is inside the LAST `{ ... }` in the args
					-- (the macro takes 2 args: sym name, then body in {}).
					-- Find the last `{` in `inner`, then the matching `}`.
					local last_open
					for k = #inner, 1, -1 do
						if inner:sub(k, k) == "{" then last_open = k; break end
					end
					if not last_open then
						i = open + 1
					else
						-- Walk forward to find matching `}` honoring balanced
						-- ()/[] and strings. We could call duffle.read_braces
						-- from last_open+1, but read_braces expects to start at
						-- the brace itself. Inline the walk for clarity.
						local depth = 1
						local j = last_open + 1
						while j <= #inner and depth > 0 do
							local c = inner:byte(j)
							if c == 123 then
								depth = depth + 1; j = j + 1
							elseif c == 125 then
								depth = depth - 1
								if depth == 0 then break end
								j = j + 1
							elseif c == 40 then
								local _, a = read_parens(inner, j); j = a
							elseif c == 91 then
								local _, a = read_brackets(inner, j); j = a
							elseif c == 34 or c == 39 then
								j = duffle.skip_str_or_cmt(inner, j) + 1
							else
								j = j + 1
							end
						end
						if depth ~= 0 then
							-- unmatched; bail
							i = open + 1
						else
							-- First ident in `inner` is the comp name.
							local name_match = inner:match("^%s*([%w_]+)")
							local name = name_match or "?"
							local body     = inner:sub(last_open + 1, j - 1)
							-- body_off in full source: position right after the
							-- LAST `{` in `inner`, which sits at `open+1+last_open`
							-- (open+1 = just inside the outer paren, +last_open
							-- = at the `{`).
							local body_off = open + 1 + last_open
							out[#out + 1] = {
								line     = line_of(i),
								name     = name,
								body     = body,
								body_off = body_off + 1,
								kind     = kind,
							}
							i = after_paren
						end
					end
				else
					-- MipsAtom_(sym) { body };  OR
					-- MipsAtomComp_(sym) { body };
					-- name is the first arg, body is the FIRST { ... } after
					-- the paren.
					local a = 1
					while a <= #inner and inner:sub(a, a):match("[%s]") do a = a + 1 end
					local b = a
					while b <= #inner and inner:sub(b, b):match("[%w_]") do b = b + 1 end
					local name = inner:sub(a, b - 1)
					if name == "" then
						i = open + 1
					else
						local brace = scan_to_char(source_text, "{", after_paren)
						if brace then
							local body, after_brace = read_braces(source_text, brace)
							local body_off = brace + 1
							out[#out + 1] = {
								line     = line_of(i),
								name     = name,
								body     = body,
								body_off = body_off,
								kind     = kind,
							}
							i = after_brace
						else
							i = open + 1
						end
					end
				end
			end
		else
			i = after
		end
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
	for i = 1, len do
		if i > 1 then
			index[i] = newline_count + 1   -- line of `i` relative to body
		end
		if body:byte(i) == 10 then        -- '\n'
			newline_count = newline_count + 1
		end
	end
	-- Offsets beyond the body still resolve to the final line
	index[len + 1] = newline_count + 1
	return index
end

--- Count of COP2-nop words contributed by a single top-level token.
--   `nop`                  -> 1
--   `nop2`                 -> 2 (i.e. `nop, nop` baked into one asm arg)
--   `nop,` / `nop2,`        -> same as above; strip trailing comma defensively
--   anything else          -> 0
--
-- (Branch-delay-slot nops like `branch_*(..., nop)` are tokenized
-- separately by split_top_level_commas: the branch arg ends before
-- the trailing comma, and `nop` becomes its own token. So no special
-- handling is needed here.)
local function nop_word_count(token)
	local s = trim(token)
	-- strip trailing comma(s) (defensive against raw text via, but our
	-- tokenize_body already strips them; this is a safety net)
	s = s:gsub(",$", "")
	s = trim(s)
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
		local ws_end = skip_ws_and_cmt(body, rel)
		if ws_end > rel then
			rel = ws_end
		end
		if rel > len then break end

		-- Find comma/newline/semicolon after this token. Read balanced
		-- groups so commas inside parens/braces/brackets aren't treated
		-- as separators. Comments / strings are skipped.
		local i = rel
		while i <= len do
			local c = body:byte(i)
			if c == 44 then break end               -- ','
			if c == 10 then break end               -- '\n'
			if c == 59 then break end               -- ';'
			if c == 40 then                         -- '('
				local _, a = read_parens(body, i); i = a
			elseif c == 123 then                     -- '{'
				local _, a = read_braces(body, i); i = a
			elseif c == 91 then                      -- '['
				local _, a = read_brackets(body, i); i = a
			elseif c == 34 or c == 39 then           -- '"' or '\''
				i = duffle.skip_str_or_cmt(body, i) + 1
			else
				i = i + 1
			end
		end
		-- Extract token [rel .. i-1]
		local tok = trim(body:sub(rel, i - 1))
		if tok ~= "" then
			out[#out + 1] = { tok = tok, rel = rel }
		end
		-- Move past the separator
		if i <= len then
			i = i + 1
			-- Also skip whitespace before next token
			local w = skip_ws_and_cmt(body, i)
			if w > i then i = w end
		end
		rel = i
	end
	return out
end

-- ════════════════════════════════════════════════════════════════════════════
-- Check #1: GTE pipeline-fill
-- ════════════════════════════════════════════════════════════════════════════

--- Walk the token list. Whenever we hit a `gte_cmdw_<X>` token, count
--- consecutive nop words starting at the next token. If count < the
--- minimum declared in `GTE_PIPELINE_LATENCY[X]`, record a finding.
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
	-- count < `GTE_PIPELINE_LATENCY[X]`, record a finding.
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
				local need = GTE_PIPELINE_LATENCY[cmdw_full]
				if need == nil then
					-- alias or new gte_cmdw_<X> not yet in latency table
					local line = a.line + line_in_body[tokens[ti].rel]
					findings[#findings + 1] = {
						atom  = a.name,
						line  = line,
						check = "gte_pipeline_fill",
						kind  = "warning",
						msg   = string.format(
							"%s at line %d uses `gte_cmdw_%s` but that macro is not in duffle.GTE_PIPELINE_LATENCY -- add a min_nops entry",
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
		for i, t in ipairs(tokens) do
			local tok = t.tok
			-- Match `mac_yield(...)` or just `mac_yield`. The bareword
			-- variant is rare in modern style but tolerated.
			if tok:match("^mac_yield%s*%(") or tok == "mac_yield" then
				count = count + 1
				last_idx = i
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
				for j = last_idx + 1, #tokens do
					local t = tokens[j].tok
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
	local len = #source_text
	local i   = 1
	while i <= len do
		i = skip_ws_and_cmt(source_text, i); if i > len then break end
		if source_text:sub(i, i) == "#" then
			local j = i
			while j <= len and source_text:byte(j) ~= 10 do j = j + 1 end
			i = j + 1
		else
			local ident, after = read_ident(source_text, i)
			if not ident then
				i = i + 1
			elseif ident == "typedef" then
				local j = skip_ws_and_cmt(source_text, after)
				local id2, after2 = read_ident(source_text, j)
				if id2 ~= "Struct_" then
					i = after2 or (j + 1)
				else
					local open = skip_ws_and_cmt(source_text, after2)
					if source_text:sub(open, open) ~= "(" then
						i = open + 1
					else
						local inner, after_paren = read_parens(source_text, open)
						local name = trim(inner)
						local brace = scan_to_char(source_text, "{", after_paren)
						if not brace then
							i = open + 1
						else
							local body, after_brace = read_braces(source_text, brace)
							local fields = {}
							local byte_off = 0
							local k = 1
							while k <= #body do
								k = skip_ws_and_cmt(body, k); if k > #body then break end
								local tid, tafter = read_ident(body, k)
								if not tid then
									k = k + 1
								elseif tid == "U4" then
									local fid, fafter = read_ident(body, skip_ws_and_cmt(body, tafter))
									if fid then
										fields[#fields + 1] = { name = fid, offset = byte_off }
										byte_off = byte_off + 4
									end
									k = fafter or (tafter + 1)
								else
									k = tafter + 1
								end
							end
							if name:sub(1, 6) == "Binds_" then
								out[#out + 1] = { line = line_of(i), name = name, fields = fields, bytes = byte_off }
							end
							i = after_brace
						end
					end
				end
			else
				i = after
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
	local len = #source_text
	local i   = 1
	while i <= len do
		i = skip_ws_and_cmt(source_text, i); if i > len then break end
		if source_text:sub(i, i) == "#" then
			local j = i
			while j <= len and source_text:byte(j) ~= 10 do j = j + 1 end
			i = j + 1
		else
			local ident, after = read_ident(source_text, i)
			if not ident then
				i = i + 1
			elseif ident == "MipsAtom_" then
				local open = skip_ws_and_cmt(source_text, after)
				if source_text:sub(open, open) ~= "(" then
					i = open + 1
				else
					local inner, after_paren = read_parens(source_text, open)
					local a = 1
					while a <= #inner and inner:sub(a, a):match("[%s]") do a = a + 1 end
					local b = a
					while b <= #inner and inner:sub(b, b):match("[%w_]") do b = b + 1 end
					local atom_name = inner:sub(a, b - 1)
					local lookahead = skip_ws_and_cmt(source_text, after_paren)
					local look_ident, look_after = read_ident(source_text, lookahead)
					if look_ident == "atom_info" then
						local info_open = skip_ws_and_cmt(source_text, look_after)
						if source_text:sub(info_open, info_open) == "(" then
							local info_inner, info_after = read_parens(source_text, info_open)
							local binds, reads, writes = nil, nil, nil
							local j = 1
							while j <= #info_inner do
								j = skip_ws_and_cmt(info_inner, j); if j > #info_inner then break end
								local sub_ident, sub_after = read_ident(info_inner, j)
								if not sub_ident then
									j = j + 1
								elseif sub_ident == "atom_bind" then
									local sub_open = skip_ws_and_cmt(info_inner, sub_after)
									if info_inner:sub(sub_open, sub_open) == "(" then
										local sub_inner, sub_after2 = read_parens(info_inner, sub_open)
										binds = trim(sub_inner)
										j = sub_after2
									else
										j = sub_open + 1
									end
								elseif sub_ident == "atom_reads" or sub_ident == "atom_writes" then
									local kind = sub_ident
									local sub_open = skip_ws_and_cmt(info_inner, sub_after)
									if info_inner:sub(sub_open, sub_open) == "(" then
										local sub_inner, sub_after2 = read_parens(info_inner, sub_open)
										local regs = {}
										local p = 1
										while p <= #sub_inner do
											p = skip_ws_and_cmt(sub_inner, p); if p > #sub_inner then break end
											local pid, pa = read_ident(sub_inner, p)
											if pid then
												regs[#regs + 1] = trim(pid)
												p = pa
											else
												p = p + 1
											end
											if p > #sub_inner then break end
											if sub_inner:sub(p, p) == "," then p = p + 1 end
										end
										if kind == "atom_reads" then reads = regs else writes = regs end
										j = sub_after2
									else
										j = sub_open + 1
									end
								else
									j = sub_after
								end
							end
							out[#out + 1] = {
								atom_name = atom_name, binds = binds,
								reads = reads or {}, writes = writes or {},
								info_line = line_of(lookahead),
							}
							i = info_after
						else
							i = info_open + 1
						end
					else
						i = after_paren
					end
				end
			else
				i = after
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
					for k = 1, #expected_field_seq do
						if found_field_seq[k] ~= expected_field_seq[k] then
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
--- Compare to GP0_CMD_SIZE[cmd_byte]. Mismatch = error.
---
--- Soft behavior (warnings):
---   - Atoms emitting a primitive via raw `store_word(R_PrimCursor, ...)`
---     (no `mac_format_X_color` call) emit a "manual packet assembly"
---     advisory. Cannot auto-validate.
---   - Atoms containing a `mac_<name>(...)` call whose name is not in
---     GP0_MACRO_CONTRIB emit a "new macro; update GP0_MACRO_CONTRIB"
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
				if shape and GP0_CMD_BY_SHAPE[shape] then
					if not cmd_byte then
						cmd_byte = GP0_CMD_BY_SHAPE[shape]
						cmd_line = a.line + line_in_body[t.rel]
					end
					saw_format = true
					local contrib_key = "mac_format_" .. shape .. "_color"
					local n = GP0_MACRO_CONTRIB[contrib_key]
					if n then contrib = contrib + n end
				end
				local gte_store = tok:match("^mac_gte_store_[%w_]+")
				if gte_store then
					local n = GP0_MACRO_CONTRIB[gte_store]
					if n then contrib = contrib + n end
				end
				local ot_tag = tok:match("^mac_insert_ot_tag_([%w_]+)")
				if ot_tag then
					local n = GP0_MACRO_CONTRIB["mac_insert_ot_tag_" .. ot_tag]
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
				local expected = GP0_CMD_SIZE[cmd_byte]
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

	-- Phase 3 (per-atom cycle budget) hooks go here when reactivated.
	-- emit per-atom cycle counts via INSTRUCTION_LATENCY table

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
	info[#info + 1] = {
		line = 0,
		msg  = string.format("scanned: %d atom bodies; %d findings", #atoms, #findings),
	}

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
	ensure_dir(ctx.out_root)

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

	write_file(out_path, table.concat(lines, "\n") .. "\n")
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

	for _, src in ipairs(ctx.sources) do
		local result = validate(ctx, src)
		local out_path = emit_static_analysis_txt(ctx, src, result)
		if out_path then
			table.insert(outputs, { static_analysis_txt = out_path })
		end
		for _, e in ipairs(result.errors) do
			errors[#errors + 1] = { line = e.line, msg = e.msg }
		end
		for _, w in ipairs(result.warnings) do
			warnings[#warnings + 1] = { line = w.line, msg = w.msg }
		end
	end

	return { outputs = outputs, errors = errors, warnings = warnings }
end

return M
