-- passes/offsets.lua
--
-- Generate <module>/gen/<basename>.offsets.h with branch offset
-- immediates for every atom_offset(F, T) reference in atom bodies.
--
-- The branch offset regression we just fixed in commit 98e27c2 must
-- NOT return. The fix was in duffle.lua's split_top_level_commas +
-- tape_atom_annotation_pass.lua's compute_component_word_count.
-- word_count_eval.count_token_words preserves the fix.
--
-- THIS MODULE ALSO REQUIRES the recent fix to duffle.lua's
-- split_top_level_commas (the second-half of the 98e27c2 fix):
-- top-level comments must be appended to the previous token, not
-- stripped, so the emit path preserves `// trailing comment` text
-- for convert_line_comments_to_block to convert to `/* */`.
--
-- Coding standard: tabs (1/level), EmmyLua annotations, no regex.

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

local duffle              = require("duffle")
local trim                = duffle.trim
local read_ident          = duffle.read_ident
local is_space            = duffle.is_space
local is_alpha            = duffle.is_alpha
local is_alnum            = duffle.is_alnum
local skip_ws_and_cmt     = duffle.skip_ws_and_cmt
local skip_str_or_cmt     = duffle.skip_str_or_cmt
local split_top_level_commas = duffle.split_top_level_commas
local read_parens         = duffle.read_parens
local read_braces         = duffle.read_braces
local write_file          = duffle.write_file
local dirname             = duffle.dirname
local basename_no_ext     = duffle.basename_no_ext
local ensure_dir          = duffle.ensure_dir

local word_count_eval     = require("word_count_eval")
local count_token_words   = word_count_eval.count_token_words

-- ════════════════════════════════════════════════════════════════════════════
-- Local helpers (ported from offset_gen.meta.lua lines 67-93)
-- ════════════════════════════════════════════════════════════════════════════

local function starts_with(s, prefix)
	if #s < #prefix then return false end
	for i = 1, #prefix do
		if s:sub(i, i) ~= prefix:sub(i, i) then return false end
	end
	return true
end

local function to_upper(s) return s:upper() end

local function to_alnum_underscore(s)
	local out = ""
	for i = 1, #s do
		local c = s:sub(i, i)
		if is_alnum(c) then out = out .. c
		else out = out .. "_" end
	end
	return out
end

local function pad_right(s, w) return s .. string.rep(" ", w - #s) end

-- ════════════════════════════════════════════════════════════════════════════
-- Marker-call helpers (ported from offset_gen.meta.lua lines 148-205)
-- ════════════════════════════════════════════════════════════════════════════

--- Extract comma-separated identifier args from a parenthesized group
--- after a function-like macro call.
local function extract_ident_args(token, after_ident)
	local arg_start = skip_ws_and_cmt(token, after_ident)
	if token:sub(arg_start, arg_start) ~= "(" then return {}, nil end
	local inner, after_paren = read_parens(token, arg_start)

	local args = {}
	local n    = 1
	local len  = #inner
	while n <= len do
		n = skip_ws_and_cmt(inner, n)
		if n > len then break end
		local ident, after = read_ident(inner, n)
		if ident and ident ~= "" then
			table.insert(args, ident)
			n = after
		else
			n = n + 1
		end
		n = skip_ws_and_cmt(inner, n)
		if n <= len and inner:sub(n, n) == "," then n = n + 1 end
	end

	return args, after_paren
end

--- Scan a single token for atom_label/atom_offset markers, walking through
--- balanced groups transparently (so nested calls are found).
local function scan_for_atom_markers(token, at_pos, labels, branches)
	local i   = 1
	local len = #token
	while i <= len do
		i = skip_ws_and_cmt(token, i)
		if i > len then break end
		local c = token:sub(i, i)
		if is_alpha(c) then
			local ident, after = read_ident(token, i)
			if ident == "atom_label" then
				local args, after_paren = extract_ident_args(token, after)
				if #args >= 1 then labels[args[1]] = at_pos end
				if after_paren then i = after_paren else i = after end
			elseif ident == "atom_offset" then
				local args, after_paren = extract_ident_args(token, after)
				if #args >= 2 then table.insert(branches, {pos = at_pos, target = args[2], tag = args[1]}) end
				if after_paren then i = after_paren else i = after end
			else
				i = after
			end
		else
			local nx = skip_str_or_cmt(token, i)
			if nx > i then i = nx else i = i + 1 end
		end
	end
end

--- Find the end position (just past the closing ')') of the first
--- atom_label/atom_offset call in `tok`. Returns 0 if no such call.
local function find_marker_call_end(tok)
	local i   = 1
	local len = #tok
	while i <= len do
		i = skip_ws_and_cmt(tok, i)
		if i > len then break end
		local c = tok:sub(i, i)
		if is_space(c) then
			i = i + 1
		elseif c == "/" then
			-- comment — skip past it (delegated to duffle.skip_str_or_cmt)
			local nx = skip_str_or_cmt(tok, i)
			if nx > i then i = nx else i = i + 1 end
		else
			local ident, after = read_ident(tok, i)
			if ident == "atom_label" or ident == "atom_offset" then
				local j = skip_ws_and_cmt(tok, after)
				if tok:sub(j, j) == "(" then
					local _, end_paren = read_parens(tok, j)
					return end_paren - 1
				end
				return 0
			end
			i = after or (i + 1)
		end
	end
	return 0
end

-- ════════════════════════════════════════════════════════════════════════════
-- Atom scanner (ported from offset_gen.meta.lua lines 245-321)
-- ════════════════════════════════════════════════════════════════════════════

--- Skip C qualifier keywords (static, const, etc.) and return the position
--- past the last qualifier.
local function skip_qualifiers(source, i)
	local keywords = {
		["static"]  = true, ["const"]    = true, ["volatile"] = true,
		["extern"]  = true, ["register"] = true, ["auto"]     = true,
		["inline"]  = true, ["typedef"]  = true,
		["internal"]= true, ["LP_"]      = true, ["global"]   = true, ["gkknown"] = true,
	}
	while true do
		i = skip_ws_and_cmt(source, i)
		local ident, after = read_ident(source, i)
		if not ident       then                return i end
		if keywords[ident] then i = after else return i end
	end
end

--- Find every MipsAtom_(name) { ... } in a source.
local function find_atoms(source_text)
	local atoms = {}
	local len   = #source_text
	local i     = 1

	local function try_wrapped(after_pos)
		local paren_pos = skip_ws_and_cmt(source_text, after_pos)
		if source_text:sub(paren_pos, paren_pos) ~= "(" then return nil end
		local inner, after_paren = read_parens(source_text, paren_pos)
		local n = 1
		while n <= #inner and is_space(inner:sub(n, n)) do n = n + 1 end
		local ns = n
		while n <= #inner and is_alnum(inner:sub(n, n)) do n = n + 1 end
		local name = inner:sub(ns, n - 1)
		if name == "" then return nil end
		-- Find the brace after the parens.
		local brace_pos = duffle.scan_to_char(source_text, "{", after_paren)
		if not brace_pos then return nil end
		local body, after_brace = read_braces(source_text, brace_pos)
		return {name = name, body = body, after_brace = after_brace}
	end

	local function try_raw(after_pos)
		local next_pos = skip_ws_and_cmt(source_text, after_pos)
		local next_ident, next_after = read_ident(source_text, next_pos)
		if not next_ident then return nil end
		if not starts_with(next_ident, "code_") then return nil end
		if #next_ident <= 5 then return nil end
		local atom_name = next_ident:sub(6)
		local brace_pos = duffle.scan_to_char(source_text, "{", next_after)
		if not brace_pos then return nil end
		local body, after_brace = read_braces(source_text, brace_pos)
		return {name = atom_name, body = body, after_brace = after_brace}
	end

	while i <= len do
		i = skip_ws_and_cmt(source_text, i); if i > len then break end
		i = skip_qualifiers(source_text, i); if i > len then break end
		local ident, after = read_ident(source_text, i)
		if not ident then
			i = i + 1
		elseif ident == "MipsAtom_" then
			local atom = try_wrapped(after)
			if atom then
				table.insert(atoms, {name = atom.name, body = atom.body})
				i = atom.after_brace
			else
				i = i + 1
			end
		elseif ident == "MipsCode" then
			local atom = try_raw(after)
			if atom then
				table.insert(atoms, {name = atom.name, body = atom.body})
				i = atom.after_brace
			else
				i = after
			end
		else
			i = after
		end
	end
	return atoms
end

-- ════════════════════════════════════════════════════════════════════════════
-- Per-atom body scan (ported from offset_gen.meta.lua lines 207-239)
-- ════════════════════════════════════════════════════════════════════════════

--- Scan an atom body for labels + branches, count total words.
--- Returns (labels, branches, total_words).
local function scan_atom_body(body, word_counts)
	local pos      = 0
	local labels   = {}
	local branches = {}
	for _, tok in ipairs(split_top_level_commas(body)) do
		local k    = 1
		local tlen = #tok
		while k <= tlen and is_space(tok:sub(k, k)) do k = k + 1 end
		local leading_ident = read_ident(tok, k)
		if leading_ident == "atom_label" or leading_ident == "atom_offset" then
			-- Marker call: record at the current pos, do NOT advance pos.
			-- But the source pattern may bundle the marker with the next
			-- instruction on a new line (no top-level comma between them).
			-- In that case, the rest of `tok` after the marker call is
			-- a real instruction that must still be counted.
			scan_for_atom_markers(tok, pos, labels, branches)
			local marker_end = find_marker_call_end(tok)
			if marker_end > 0 and marker_end < #tok then
				local rest = trim(tok:sub(marker_end + 1))
				if rest ~= "" then
					local rest_words = count_token_words(rest, word_counts)
					pos = pos + rest_words
				end
			end
		else
			local words = count_token_words(tok, word_counts)
			scan_for_atom_markers(tok, pos, labels, branches)
			pos = pos + words
		end
	end
	return labels, branches, pos
end

-- ════════════════════════════════════════════════════════════════════════════
-- Offset computation + header generation (ported lines 327-383)
-- ════════════════════════════════════════════════════════════════════════════

--- Compute branch offsets as (target_word - branch_word - 1).
local function compute_offsets(labels, branches)
	local results = {}
	for _, br in ipairs(branches) do
		local target = labels[br.target]
		if not target then
			error("Branch target '" .. br.target .. "' has no atom_label (at word " .. br.pos .. ")")
		end
		table.insert(results, {target = br.target, tag = br.tag, offset = target - br.pos - 1})
	end
	return results
end

--- Generate the per-source .offsets.h header.
local function generate_header(source_path, atoms_data)
	local basename = basename_no_ext(source_path)

	local lines = {}
	local function add(s) table.insert(lines, s) end

	add("// Auto-generated by ps1_meta.lua (passes/offsets.lua) — DO NOT EDIT")
	add("// Source: " .. source_path)
	add("#pragma once")
	add("")
	add("#pragma region " .. basename)
	add("")
	add("")
	for _, atom in ipairs(atoms_data) do
		if #atom.offsets > 0 then
			add("// --- atom: " .. atom.name .. " (" .. atom.total_words .. " words) ---")
			add("")
			local consts = {}
			for _, r in ipairs(atom.offsets) do
				table.insert(consts, {
					macro_name = "_atom_offset_" .. r.tag .. "_" .. r.target,
					enum_name  = "atom_offset_"  .. r.tag .. "_" .. r.target,
					value      = r.offset,
				})
			end
			for _, c in ipairs(consts) do
				add("#define " .. pad_right(c.macro_name, 44) .. "  " .. c.value)
			end
			add("")
			add("enum {")
			for _, c in ipairs(consts) do
				add("    " .. c.enum_name .. " = " .. c.macro_name .. ",")
			end
			add("};")
			add("")
		end
	end
	add("#pragma endregion " .. basename)
	add("")
	return table.concat(lines, "\n") .. "\n"
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
		local atoms = find_atoms(src.text)
		if #atoms > 0 then
			local atoms_data = {}
			for _, atom in ipairs(atoms) do
				local labels, branches, total = scan_atom_body(atom.body, ctx.shared.word_counts)
				local offsets = compute_offsets(labels, branches)
				table.insert(atoms_data, {
					name        = atom.name,
					total_words = total,
					offsets     = offsets,
				})
			end

			local out_path = src.dir .. "/gen/" .. basename_no_ext(src.dir) .. ".offsets.h"
			if not ctx.dry_run then
				ensure_dir(dirname(out_path))
				write_file(out_path, generate_header(src.path, atoms_data))
			end
			table.insert(outputs, { offsets_h = out_path })
		end
	end

	return { outputs = outputs, errors = errors, warnings = warnings }
end

return M
