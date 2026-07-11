--- passes/offsets.lua — Branch-offset generator.
---
--- Reads the pre-scanned SourceScan payload (produced once upstream by `duffle.scan_source`)
--- for `MipsAtom_(name)` and `MipsCode code_<name>` declarations, computes the word offset
--- from each `atom_offset(F, T)` marker to its target `atom_label(T)` declaration, and emits
--- `<dir_basename>.offsets.h` with one `#define _atom_offset_F_T = N` per branch.
---
--- The offset is `target_word - branch_word - 1` (the standard MIPS branch-immediate encoding: branch_offset = relative_pc_in_words - 1).
---
--- **Conventions**: tabs (1/level), EmmyLua annotations, no regex,
--- Lua 5.3 compatible.

-- ════════════════════════════════════════════════════════════════════════════
-- Module-scope requires + package.path setup
-- ════════════════════════════════════════════════════════════════════════════

-- Bootstrap: same as entry scripts. See `ps1_meta.lua` for the rationale.
-- Bootstrap: load `scripts/duffle_paths.lua` (sets package.path + package.cpath).
-- Uses `debug.getinfo` to find this file's own directory, so it works
-- both standalone and when require'd from the orchestrator.
-- Bootstrap: load `duffle_paths.lua` via `debug.getinfo(1, "S").source` (works both standalone + when require'd).
-- duffle_paths.lua sets package.path then returns `require("duffle")` at the bottom, so the dofile value IS the duffle module.
local _bootstrap_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local duffle        = dofile(_bootstrap_dir .. "../duffle_paths.lua")
local word_count_eval = require("word_count_eval")
local count_token_words = word_count_eval.count_token_words

-- ════════════════════════════════════════════════════════════════════════════
-- Constants
-- ════════════════════════════════════════════════════════════════════════════

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
--- @field scan     table   -- pre-scanned SourceScan payload (from duffle.scan_source)

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
--- @field verbose            boolean                -- log diagnostic info

--- @class PassResult
--- @field outputs  table[]  -- {kind=, path=} entries describing emit files
--- @field errors   table[]  -- {line=, msg=} entries; build-stops
--- @field warnings table[]  -- {line=, msg=} entries; build-succeeds

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
-- Per-token marker-call helpers (atom_label / atom_offset inside bodies)
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

-- MARKER_TO_HANDLER — data-driven marker dispatch (the plex pattern).
-- Maps the marker ident to its recorder function. Each handler takes (out_table, args, at_pos).
-- Adding a new marker type = 1 row + 1 recorder function.
local MARKER_TO_HANDLER = {
	[LABEL_MARKER]  = record_label_marker,
	[OFFSET_MARKER] = record_offset_marker,
}

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
			local handler = MARKER_TO_HANDLER[ident]
			if handler then
				local args, after_paren = extract_ident_args(token, after)
				-- Marker found — dispatch to its recorder. markers share labels and branches as
				-- out-tables; the recorder picks which one(s) to write to based on its semantics.
				-- (record_label_marker writes to labels; record_offset_marker writes to branches.)
				handler(ident == LABEL_MARKER and labels or branches, args, at_pos)
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

-- (internal) Count words emitted by the rest of `tok` after a marker call
-- (the marker call itself emits 0 words, but the source pattern may bundle the marker with the next instruction on the same line,
-- separated by no top-level comma).
-- Returns the word count contributed by that rest.
-- @param tok string
-- @param word_counts table
-- @return integer
local function count_marker_rest(tok, word_counts)
	-- duffle.find_marker_call_end returns the position PAST the closing `)` of the marker call
	-- (or nil if `tok` isn't a marker call). Canonical impl in duffle.lua is faster than the
	-- file-local copy that used to live here (byte-indexed, no `tok:sub` per char).
	local marker_end = duffle.find_marker_call_end(tok)
	if not marker_end or marker_end >= #tok then return 0 end
	local rest = duffle.trim(tok:sub(marker_end))
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
-- scan_atom_body: walk pre-tokenized body for atom_label/atom_offset markers + word counts.
-- Uses `atom.body_tokens` from the SourceScan payload (pre-tokenized by scan-source pass).
-- @param body_tokens table[]  -- {{tok=string, rel=integer}, ...} from duffle.tokenize_body
-- @param word_counts table
-- @return table, table, integer  -- labels, branches, total_words
local function scan_atom_body(body_tokens, word_counts)
	local pos      = 0
	local labels   = {}
	local branches = {}
	for _, t in ipairs(body_tokens) do
		local tok = t.tok
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

-- Right-pad `s` with spaces to width `w`. If `s` is already `w` or wider, no padding is added.
-- @param s string
-- @param w integer
-- @return string
local function pad_right(s, w)
	return s .. string.rep(" ", math.max(0, w - #s))
end

-- (internal) Build a constant-table entry `{macro_name, enum_name, value}` from a BranchOffset.
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

-- Project the pre-scanned SourceScan entries into the {name, body, body_tokens} shape this pass needs.
-- MipsAtom_ entries have kind="atom"; MipsCode code_<name> entries have kind="raw_atom".
-- `body_tokens` is set by scan-source on every `scan.atoms[i]` / `scan.raw_atoms[i]`; we carry it forward
-- so `scan_atom_body` reads from the precomputed table directly (no per-atom tokenize_body fallback).
-- @param scan table  -- SourceScan from duffle.scan_source
-- @return table[]  -- list of {name=, body=, body_tokens=}
local function project_atoms(scan)
	local out = {}
	for _, a in ipairs(scan.atoms) do
		out[#out + 1] = { name = a.raw_name, body = a.body, body_tokens = a.body_tokens }
	end
	for _, a in ipairs(scan.raw_atoms) do
		out[#out + 1] = { name = a.name, body = a.body, body_tokens = a.body_tokens }
	end
	return out
end

-- (internal) Process one source: project atoms from scan, scan bodies, write header.
-- Returns the offsets_h path if a header was written, or nil.
-- @param ctx PassCtx
-- @param src SourceFile
-- @return string|nil  -- the offsets_h path
local function process_source(ctx, src)
	local atoms = project_atoms(src.scan)
	if #atoms == 0 then return nil end

	local atoms_data = {}
	for _, atom in ipairs(atoms) do
		local labels, branches, total = scan_atom_body(atom.body_tokens, ctx.shared.word_counts)
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
--- For each source, emits a per-module `<dir_basename>.offsets.h` containing `#define _atom_offset_F_T = N` constants 
--- for every `atom_offset(F, T)` reference in the source's atoms.
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
