--- passes/offsets.lua — Branch-offset generator.
---
--- Scans every source for `MipsAtom_(name) { ... }` (and the raw `MipsCode code_<name> { ... }` form) declarations, 
--- computes the word offset from each `atom_offset(F, T)` marker to its target `atom_label(T)` declaration, 
--- and emits `<dir_basename>.offsets.h` with one `#define _atom_offset_F_T = N` per branch.
---
--- The offset is `target_word - branch_word - 1` (the standard MIPS branch-immediate encoding: branch_offset = relative_pc_in_words - 1).
---
--- **Conventions**: tabs (1/level), EmmyLua annotations, no regex,
--- Lua 5.3 compatible.

-- ════════════════════════════════════════════════════════════════════════════
-- Module-scope requires + package.path setup
-- ════════════════════════════════════════════════════════════════════════════

-- Resolve `arg[0]` to an absolute-ish script directory so that `require("duffle")` resolves against `scripts/` regardless of CWD.
-- Bootstrap: see `ps1_meta.lua` for the rationale.
-- Bootstrap: load `scripts/duffle_paths.lua` (sets package.path + package.cpath).
-- Uses `debug.getinfo` to find this file's own directory, so it works
-- both standalone and when require'd from the orchestrator.
local _src = debug.getinfo(1, "S").source:sub(2)
local _dir = _src:match("(.*[/\\])") or "./"
dofile(_dir .. "../duffle_paths.lua")
local duffle = require("duffle")
local word_count_eval = require("word_count_eval")
local count_token_words = word_count_eval.count_token_words

-- ════════════════════════════════════════════════════════════════════════════
-- Constants
-- ════════════════════════════════════════════════════════════════════════════

-- C qualifier keywords that may precede a `MipsAtom_` declaration
-- (and should be skipped by `skip_qualifiers`).
local QUALIFIER_KEYWORDS = {
	["static"]   = true, ["const"]    = true, ["volatile"] = true,
	["extern"]   = true, ["register"] = true, ["auto"]     = true,
	["inline"]   = true, ["typedef"]  = true,
	["internal"] = true, ["LP_"]      = true, ["global"]   = true, ["gkknown"] = true,
}

-- Atom declaration identifiers.
local ATOM_PREFIX       = "MipsAtom_"
local CODE_DECL         = "MipsCode"
local CODE_RAW_PREFIX   = "code_"   -- raw atom form: `MipsCode code_<name> { ... }`
local CODE_RAW_PREFIX_LEN = 5       -- = #CODE_RAW_PREFIX

-- Marker-call identifiers inside atom bodies.
local LABEL_MARKER    = "atom_label"
local OFFSET_MARKER   = "atom_offset"

-- Offset macro/enum naming prefixes (the emitted header uses these).
local OFFSET_MACRO_PREFIX = "_atom_offset_"
local OFFSET_ENUM_PREFIX  = "atom_offset_"

-- Column width for the `#define _atom_offset_F_T = N` alignment.
local OFFSET_MACRO_COL = 44

-- ════════════════════════════════════════════════════════════════════════════
-- Type declarations
-- ════════════════════════════════════════════════════════════════════════════

--- @class SourceFile
--- @field path     string  -- absolute path to the source file
--- @field text     string  -- the full source text
--- @field dir      string  -- the directory containing the source
--- @field basename string  -- filename without extension

--- @class PassCtx
--- @field sources            SourceFile[]           -- all source files in the build
--- @field metadata_path      string                 -- path to word_count.metadata.h
--- @field shared             table                  -- cross-pass shared state
--- @field shared.word_counts table                  -- macro name -> word count
--- @field out_root           string                 -- output root (e.g. "build/gen")
--- @field project_root       string                 -- project root (e.g. "code/")
--- @field upstream           table<string, table>   -- per-pass upstream outputs
--- @field flags              table                  -- CLI flags
--- @field dry_run            boolean                -- if true, compute but don't write
--- @field verbose            boolean                -- if true, log diagnostic info

--- @class PassResult
--- @field outputs  table[]  -- {kind=, path=} entries describing emit files
--- @field errors   table[]  -- {line=, msg=} entries; build-stops
--- @field warnings table[]  -- {line=, msg=} entries; build-succeeds

--- @class Atom
--- @field name string  -- atom name (e.g. "cube_g4_face")
--- @field body string  -- the brace-delimited body (without the braces)

--- @class BranchOffset
--- @field tag    string   -- the marker tag (e.g. "F" in `atom_offset(F, T)`)
--- @field target string   -- the target label name (e.g. "T" in `atom_offset(F, T)`)
--- @field pos    integer  -- the branch's word position within the atom body
--- @field offset integer  -- computed `target_word - branch_word - 1`

--- @class AtomData
--- @field name        string         -- atom name
--- @field total_words integer        -- total word count of the atom body
--- @field offsets     BranchOffset[] -- per-branch offset list

-- ════════════════════════════════════════════════════════════════════════════
-- Local helpers
-- ════════════════════════════════════════════════════════════════════════════

-- Returns true if `s` starts with `prefix`.
-- @param s string
-- @param prefix string
-- @return boolean
local function starts_with(s, prefix)
	if #s < #prefix then return false end
	for pos = 1, #prefix do
		if s:sub(pos, pos) ~= prefix:sub(pos, pos) then return false end
	end
	return true
end

-- Replace every non-alphanumeric char in `s` with underscore.
-- @param s string
-- @return string
local function to_alnum_underscore(s)
	local out = ""
	for pos = 1, #s do
		local ch = s:sub(pos, pos)
		if duffle.is_alnum(ch) then out = out .. ch else out = out .. "_" end
	end
	return out
end

-- Right-pad `s` with spaces to width `w`. If `s` is already `w` or
-- wider, no padding is added.
-- @param s string
-- @param w integer
-- @return string
local function pad_right(s, w)
	return s .. string.rep(" ", math.max(0, w - #s))
end

-- ════════════════════════════════════════════════════════════════════════════
-- Marker-call helpers
-- ════════════════════════════════════════════════════════════════════════════

-- Extract comma-separated identifier args from a parenthesized group after a function-like macro call.
-- Returns (args, after_paren) where `after_paren` is the position just past the closing `)`, or nil if `token` did not start with `(`.
-- @param token string
-- @param after_ident integer
-- @return string[], integer|nil
local function extract_ident_args(token, after_ident)
	local arg_start = duffle.skip_ws_and_cmt(token, after_ident)
	if token:sub(arg_start, arg_start) ~= "(" then return {}, nil end
	local inner, after_paren = duffle.read_parens(token, arg_start)
	-- scan: <marker>(<args>)

	local args      = {}
	local pos       = 1
	local inner_len = #inner
	while pos <= inner_len do
		pos = duffle.skip_ws_and_cmt(inner, pos)
		if pos > inner_len then break end
		local ident, after = duffle.read_ident(inner, pos)
		if ident and ident ~= "" then
			table.insert(args, ident)
			pos = after
		else
			pos = pos + 1
		end
		pos = duffle.skip_ws_and_cmt(inner, pos)
		if pos <= inner_len and inner:sub(pos, pos) == "," then pos = pos + 1 end
	end

	return args, after_paren
end

-- (internal) Record a `atom_label(name)` marker — `at_pos` is the branch-free word position within the atom body.
-- @param labels table<string, integer>
-- @param args string[]
-- @param at_pos integer
local function record_label_marker(labels, args, at_pos)
	if #args >= 1 then labels[args[1]] = at_pos end
end

-- (internal) Record a `atom_offset(tag, target)` marker.
-- @param branches table[]  -- list of {pos=, target=, tag=}
-- @param args string[]
-- @param at_pos integer
local function record_offset_marker(branches, args, at_pos)
	if #args >= 2 then
		table.insert(branches, { pos = at_pos, target = args[2], tag = args[1] })
	end
end

--- Scan a single token for atom_label/atom_offset markers, walking through balanced groups transparently (so nested calls are found).
--- @param token string
--- @param at_pos integer    -- the branch-free word position of this token in the body
--- @param labels table<string, integer>
--- @param branches table[]
local function scan_for_atom_markers(token, at_pos, labels, branches)
	local pos     = 1
	local tok_len = #token
	while pos <= tok_len do
		pos = duffle.skip_ws_and_cmt(token, pos)
		if pos > tok_len then break end
		local ch = token:sub(pos, pos)
		if duffle.is_alpha(ch) then
			local ident, after = duffle.read_ident(token, pos)
			if ident == LABEL_MARKER then
				local args, after_paren = extract_ident_args(token, after)
				record_label_marker(labels, args, at_pos)
				pos = after_paren or after
			elseif ident == OFFSET_MARKER then
				local args, after_paren = extract_ident_args(token, after)
				record_offset_marker(branches, args, at_pos)
				pos = after_paren or after
			else
				pos = after
			end
		else
			local nx = duffle.skip_str_or_cmt(token, pos)
			pos = (nx > pos) and nx or (pos + 1)
		end
	end
end

--- Find the end position (just past the closing ')') of the first atom_label/atom_offset call in `tok`. Returns 0 if no such call.
--- @param tok string
--- @return integer  -- 0 if no marker call found; otherwise end-1 (just past ')')
local function find_marker_call_end(tok)
	local pos     = 1
	local tok_len = #tok
	while pos <= tok_len do
		pos = duffle.skip_ws_and_cmt(tok, pos)
		if pos > tok_len then break end
		local ch = tok:sub(pos, pos)
		if duffle.is_space(ch) then
			pos = pos + 1
		elseif ch == "/" then
			-- comment — skip past it (delegated to duffle.skip_str_or_cmt)
			local nx = duffle.skip_str_or_cmt(tok, pos)
			pos = (nx > pos) and nx or (pos + 1)
		else
			local ident, after_ident = duffle.read_ident(tok, pos)
			-- scan: <ident>
			if ident == LABEL_MARKER or ident == OFFSET_MARKER then
				-- scan: atom_label(<name>)  OR  atom_offset(<tag>, <target>)
				local open_paren = duffle.skip_ws_and_cmt(tok, after_ident)
				if tok:sub(open_paren, open_paren) == "(" then
					local _, end_paren = duffle.read_parens(tok, open_paren)
					return end_paren - 1
				end
				return 0
			end
			pos = after_ident or (pos + 1)
		end
	end
	return 0
end

-- ════════════════════════════════════════════════════════════════════════════
-- Atom scanner
-- ════════════════════════════════════════════════════════════════════════════

--- Skip C qualifier keywords (`static`, `const`, etc.) and return the position past the last qualifier.
--- @param source string
--- @param pos integer
--- @return integer
local function skip_qualifiers(source, pos)
	while true do
		pos = duffle.skip_ws_and_cmt(source, pos)
		local ident, after = duffle.read_ident(source, pos)
		if not ident           then return pos end
		if QUALIFIER_KEYWORDS[ident] then pos = after else return pos end
	end
end

-- (internal) Try to parse the wrapped atom form: `MipsAtom_(<name>) { ... }`.
-- Returns the parsed Atom (name + body + position past body), or nil if the form didn't match.
-- @param source_text string
-- @param after_pos integer   -- position just past `MipsAtom_`
-- @return Atom|nil
local function try_wrapped_atom(source_text, after_pos)
	local paren_pos = duffle.skip_ws_and_cmt(source_text, after_pos)
	if source_text:sub(paren_pos, paren_pos) ~= "(" then return nil end
	local inner, after_paren = duffle.read_parens(source_text, paren_pos)
	-- scan: MipsAtom_(<name>)

	local name_start = 1
	while name_start <= #inner and duffle.is_space(inner:sub(name_start, name_start)) do
		name_start = name_start + 1
	end
	local name_end = name_start
	while name_end <= #inner and duffle.is_alnum(inner:sub(name_end, name_end)) do
		name_end = name_end + 1
	end
	local name = inner:sub(name_start, name_end - 1)
	if    name == "" then return nil end

	local  brace_pos = duffle.scan_to_char(source_text, "{", after_paren)
	-- scan: MipsAtom_(<name>) {
	if not brace_pos then return nil end
	local body, after_brace = duffle.read_braces(source_text, brace_pos)
	-- scan: MipsAtom_(<name>) { <body> }
	return { name = name, body = body, after_brace = after_brace }
end

-- (internal) Try to parse the raw atom form: `MipsCode code_<name> { ... }`.
-- @param source_text string
-- @param after_pos integer   -- position just past `MipsCode`
-- @return Atom|nil
local function try_raw_atom(source_text, after_pos)
	local next_pos = duffle.skip_ws_and_cmt(source_text, after_pos)
	local next_ident, next_after = duffle.read_ident(source_text, next_pos)
	-- scan: MipsCode <next_ident>
	if not next_ident then return nil end
	if not starts_with(next_ident, CODE_RAW_PREFIX) then return nil end
	if #next_ident <= CODE_RAW_PREFIX_LEN then return nil end
	local atom_name = next_ident:sub(CODE_RAW_PREFIX_LEN + 1)
	-- scan: MipsCode code_<name>
	local brace_pos = duffle.scan_to_char(source_text, "{", next_after)
	-- scan: MipsCode code_<name> {
	if not brace_pos then return nil end
	local body, after_brace = duffle.read_braces(source_text, brace_pos)
	-- scan: MipsCode code_<name> { <body> }
	return { name = atom_name, body = body, after_brace = after_brace }
end

--- Find every `MipsAtom_(name) { ... }` (or raw `MipsCode code_<name> { ... }`) declaration in a source.
--- @param source_text string
--- @return Atom[]
local function find_atoms(source_text)
	local atoms   = {}
	local pos     = 1
	local src_len = #source_text

	while pos <= src_len do
		pos = duffle.skip_ws_and_cmt(source_text, pos); if pos > src_len then break end
		pos = skip_qualifiers(source_text, pos);        if pos > src_len then break end

		local ident, after = duffle.read_ident(source_text, pos)
		-- scan: <ident>
		if not ident then
			pos = pos + 1
		elseif ident == ATOM_PREFIX then
			-- scan: MipsAtom_(<name>) { <body> }
			local atom = try_wrapped_atom(source_text, after)
			if atom then
				atoms[#atoms + 1] = { name = atom.name, body = atom.body }
				pos = atom.after_brace
			else
				pos = pos + 1
			end
		elseif ident == CODE_DECL then
			-- scan: MipsCode code_<name> { <body> }
			local atom = try_raw_atom(source_text, after)
			if atom then
				atoms[#atoms + 1] = { name = atom.name, body = atom.body }
				pos = atom.after_brace
			else
				pos = after
			end
		else
			pos = after
		end
	end
	return atoms
end

-- ════════════════════════════════════════════════════════════════════════════
-- Per-atom body scan
-- ════════════════════════════════════════════════════════════════════════════

-- (internal) Count words emitted by the rest of `tok` after a marker call 
-- (the marker call itself emits 0 words, but the source pattern may bundle the marker with the next instruction on the same line, 
-- separated by no top-level comma). 
-- Returns the word count contributed by that rest.
-- @param tok string
-- @param word_counts table
-- @return integer
local function count_marker_rest(tok, word_counts)
	local marker_end = find_marker_call_end(tok)
	if marker_end <= 0 or marker_end >= #tok then return 0 end
	local rest = duffle.trim(tok:sub(marker_end + 1))
	if rest == "" then return 0 end
	return count_token_words(rest, word_counts)
end

-- (internal) Is this token a marker call (`atom_label` or `atom_offset`)?
-- @param tok string
-- @return boolean
local function is_marker_token(tok)
	local leading_ident = duffle.read_ident(tok, 1)
	return leading_ident == LABEL_MARKER or leading_ident == OFFSET_MARKER
end

--- Scan an atom body for labels + branches, count total words.
--- Returns (labels, branches, total_words).
--- @param body string
--- @param word_counts table
--- @return table<string, integer>, table[], integer
local function scan_atom_body(body, word_counts)
	local pos      = 0
	local labels   = {}
	local branches = {}
	for _, tok in ipairs(duffle.split_top_level_commas(body)) do
		if is_marker_token(tok) then
			-- Marker call: record at the current pos, do NOT advance pos.
			scan_for_atom_markers(tok, pos, labels, branches)
			pos = pos + count_marker_rest(tok, word_counts)
		else
			local words = count_token_words(tok, word_counts)
			scan_for_atom_markers(tok, pos, labels, branches)
			pos = pos + words
		end
	end
	return labels, branches, pos
end

-- ════════════════════════════════════════════════════════════════════════════
-- Offset computation + header generation
-- ════════════════════════════════════════════════════════════════════════════

-- Compute branch offsets as `target_word - branch_word - 1`
-- (the standard MIPS branch-immediate encoding).
-- @param labels table<string, integer>
-- @param branches table[]
-- @return BranchOffset[]
local function compute_offsets(labels, branches)
	local results = {}
	for _, br in ipairs(branches) do
		local target = labels[br.target]
		if not target then
			error("Branch target '" .. br.target .. "' has no atom_label (at word " .. br.pos .. ")")
		end
		results[#results + 1] = { target = br.target, tag = br.tag, offset = target - br.pos - 1 }
	end
	return results
end

-- (internal) Build a constant-table entry `{macro_name, enum_name, value}`
-- from a BranchOffset.
-- @param r BranchOffset
-- @return table
local function make_offset_const(r)
	return {
		macro_name = OFFSET_MACRO_PREFIX .. r.tag .. "_" .. r.target,
		enum_name  = OFFSET_ENUM_PREFIX  .. r.tag .. "_" .. r.target,
		value      = r.offset,
	}
end

-- (internal) Emit one atom's offset constants + enum into the lines buffer.
-- @param add fun(s: string)
-- @param atom AtomData
local function emit_atom_offsets(add, atom)
	if #atom.offsets == 0 then return end
	add("// --- atom: " .. atom.name .. " (" .. atom.total_words .. " words) ---")
	add("")
	local consts = {}
	for _, r in ipairs(atom.offsets) do
		consts[#consts + 1] = make_offset_const(r)
	end
	for _, c in ipairs(consts) do
		add("#define " .. pad_right(c.macro_name, OFFSET_MACRO_COL) .. "  " .. c.value)
	end
	add("")
	add("enum {")
	for _, c in ipairs(consts) do
		add("    " .. c.enum_name .. " = " .. c.macro_name .. ",")
	end
	add("};")
	add("")
end

-- Generate the per-source .offsets.h header.
-- @param source_path string
-- @param atoms_data AtomData[]
-- @return string
local function generate_header(source_path, atoms_data)
	local basename = duffle.basename_no_ext(source_path)

	local lines = {}
	local function add(s) lines[#lines + 1] = s end

	add("// Auto-generated by ps1_meta.lua (passes/offsets.lua) — DO NOT EDIT")
	add("// Source: " .. source_path)
	add("#pragma once")
	add("")
	add("#pragma region " .. basename)
	add("")
	add("")
	for _, atom in ipairs(atoms_data) do
		emit_atom_offsets(add, atom)
	end
	add("#pragma endregion " .. basename)
	add("")
	return table.concat(lines, "\n") .. "\n"
end

-- ════════════════════════════════════════════════════════════════════════════
-- M — module exports
-- ════════════════════════════════════════════════════════════════════════════

local M = {}

-- (internal) Process one source: find atoms, scan bodies, write header.
-- Returns the offsets_h path if a header was written, or nil.
-- @param ctx PassCtx
-- @param src SourceFile
-- @return string|nil  -- the offsets_h path
local function process_source(ctx, src)
	local atoms = find_atoms(src.text)
	if #atoms == 0 then return nil end

	local atoms_data = {}
	for _, atom in ipairs(atoms) do
		local labels, branches, total = scan_atom_body(atom.body, ctx.shared.word_counts)
		atoms_data[#atoms_data + 1] = {
			name        = atom.name,
			total_words = total,
			offsets     = compute_offsets(labels, branches),
		}
	end

	local out_path = src.dir .. "/gen/" .. duffle.basename_no_ext(src.dir) .. ".offsets.h"
	if not ctx.dry_run then
		duffle.ensure_dir(duffle.dirname(out_path))
		duffle.write_file(out_path, generate_header(src.path, atoms_data))
	end
	return out_path
end

--- Run the offsets pass. 
--- For each source, emits a per-module `<dir_basename>.offsets.h` containing `#define _atom_offset_F_T = N` constants for every `atom_offset(F, T)` reference
--- in the source's atoms.
--- @param ctx PassCtx
--- @return PassResult
function M.run(ctx)
	local outputs  = {}
	local errors   = {}
	local warnings = {}

	for _, src in ipairs(ctx.sources) do
		local out_path = process_source(ctx, src)
		if out_path then
			outputs[#outputs + 1] = { offsets_h = out_path }
		end
	end

	return { outputs = outputs, errors = errors, warnings = warnings }
end

return M
