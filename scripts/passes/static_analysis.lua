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

-- ════════════════════════════════════════════════════════════════════════════
-- Source walkers
-- ════════════════════════════════════════════════════════════════════════════

--- Walk source-as-written, return a list of `{line, name, body, body_off}`
--- for every `MipsAtom_(name) { body }` declaration. Comments / strings
--- inside `name` and `body` are tolerated; `body` is the raw brace
--- inner text (with surrounding whitespace, no leading/trailing `{` `}`).
--- `body_off` is the character offset of `body[1]` in `source_text`,
--- used to compute per-token line numbers later.
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
		elseif ident == "MipsAtom_" then
			local open = skip_ws_and_cmt(source_text, after)
			if source_text:sub(open, open) ~= "(" then
				i = open + 1
			else
				local inner, after_paren = read_parens(source_text, open)
				local n = 1
				while n <= #inner and inner:sub(n, n):match("[%s]") do n = n + 1 end
				local m = n
				while m <= #inner and inner:sub(m, m):match("[%w_]") do m = m + 1 end
				local name = inner:sub(n, m - 1)
				if name ~= "" then
					local brace = scan_to_char(source_text, "{", after_paren)
					if brace then
						local body, after_brace = read_braces(source_text, brace)
						-- `body` starts at brace + 1 (the char after `{`).
						local body_off = brace + 1
						out[#out + 1] = {
							line     = line_of(i),
							name     = name,
							body     = body,
							body_off = body_off,
						}
						i = after_brace
					else
						i = open + 1
					end
				else
					i = open + 1
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
		if count == 0 then
			findings[#findings + 1] = {
				atom  = a.name,
				line  = a.line,
				check = "mac_yield_uniformity",
				msg   = string.format(
					"%s at line %d has no `mac_yield()`; every atom must hand control to the next via mac_yield at end",
					a.name, a.line),
			}
		elseif count > 1 then
			findings[#findings + 1] = {
				atom  = a.name,
				line  = line_for(last_idx),
				check = "mac_yield_uniformity",
				msg   = string.format(
					"%s at line %d has %d `mac_yield()` calls; exactly 1 is allowed",
					a.name, line_for(last_idx), count),
			}
		elseif last_idx < #tokens then
			-- 1 call, but not the last token. Check if there's anything
			-- AFTER mac_yield (compiler tolerance is `macro_yield, nop`).
			-- We DON'T fail if the post-token is just `nop` or `nop2` or
			-- a branch with `, nop` delay slot -- it's the standard
			-- "yield, then BD nop" idiom.
			local post_non_nop = false
			for j = last_idx + 1, #tokens do
				local t = tokens[j].tok
				if t ~= "" and t ~= "nop" and t ~= "nop2" and not t:match("%,%s*nop%)%s*$") then
					post_non_nop = true
					break
				end
			end
			if post_non_nop then
				findings[#findings + 1] = {
					atom  = a.name,
					line  = line_for(last_idx),
					check = "mac_yield_uniformity",
					msg   = string.format(
						"%s at line %d has `mac_yield()` at token %d/%d; the yield must be the LAST non-nop token in the body",
						a.name, line_for(last_idx), last_idx, #tokens),
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

	local findings = {}
	check_gte_pipeline_fill(atoms, findings)
	check_mac_yield_uniformity(atoms, findings)

	-- Phase 2 (ABI handoff / GPU port-store shape) and Phase 3 (cycle
	-- budget) hooks go here when those tracks are reactivated.
	-- check_abi_handoff(atoms, findings)
	-- check_gpu_portstore_shape(atoms, findings)
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
	add(string.format("Atoms: %d   Findings: %d   Errors: %d   Warnings: %d",
		#result.atoms, #result.findings, #result.errors, #result.warnings))
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
