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
local duffle = dofile(_bootstrap_dir .. "../duffle_paths.lua")

-- ════════════════════════════════════════════════════════════════════════════
-- Constants
-- ════════════════════════════════════════════════════════════════════════════

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
--- @field shared             table                  -- cross-pass shared state
--- @field shared.corpus      table                  -- canonical corpus projection
--- @field shared.word_counts table                  -- compatibility alias to corpus.word_counts
--- @field out_root           string                 -- output root (e.g. "build/gen")
--- @field dry_run            boolean                -- if true, compute but don't write

--- @class PassResult
--- @field outputs  table[]  -- {kind=, path=} entries describing emit files
--- @field errors   table[]  -- {line=, msg=} entries; build-stops
--- @field warnings table[]  -- {line=, msg=} entries; build-succeeds

--- @class BranchOffset
--- @field tag         string   -- the marker tag (e.g. "F" in `atom_offset(F, T)`)
--- @field target      string   -- the target label name (e.g. "T" in `atom_offset(F, T)`)
--- @field branch_word integer  -- branch word position within the atom body
--- @field offset      integer  -- computed `target_word - branch_word - 1`

--- @class AtomData
--- @field name        string         -- atom name
--- @field total_words integer        -- total word count of the atom body
--- @field offsets     BranchOffset[] -- per-branch offset list

-- ════════════════════════════════════════════════════════════════════════════
-- Canonical marker projection
-- ════════════════════════════════════════════════════════════════════════════

-- MARKER_PROJECTORS is the marker-kind data table.
-- The emission-model pass already records marker word positions;
-- this pass only projects those records into the label/branch lookup shape needed by offset computation.
local MARKER_PROJECTORS = {
	label = function(state, marker)
		state.labels[marker.name] = marker.word_index
	end,
	offset = function(state, marker)
		state.branches[#state.branches + 1] = {
			tag         = marker.name,
			target      = marker.target,
			branch_word = marker.word_index,
		}
	end,
}

--- Project canonical marker records into the two lookup tables used by the offset renderer.
--- No source text, body text, or body token is inspected.
--- @param markers table[] -- atom.paths.markers
--- @return table<string, integer>, table[]
local function project_markers(markers)
	local state = { labels = {}, branches = {} }
	for _, marker in ipairs(markers or {}) do
		local project = MARKER_PROJECTORS[marker.kind]
		if project then project(state, marker) end
	end
	return state.labels, state.branches
end

-- ════════════════════════════════════════════════════════════════════════════
-- Offset computation + header generation
-- ════════════════════════════════════════════════════════════════════════════

--- Compute branch offsets as `target_word - branch_word - 1` (the standard MIPS branch-immediate encoding).
--- @param labels table<string, integer>
--- @param branches table[]
--- @return BranchOffset[]
local function compute_offsets(labels, branches)
	local results = {}
	for _, br in ipairs(branches) do
		local target = labels[br.target]
		if not target then
			error("Branch target '" .. br.target .. "' has no atom_label (at word " .. br.branch_word .. ")")
		end
		results[#results + 1] = {
			target      = br.target,
			tag         = br.tag,
			branch_word = br.branch_word,
			offset      = target - br.branch_word - 1,
		}
	end
	return results
end

--- Right-pad `s` with spaces to width `w`. If `s` is already `w` or wider, no padding is added.
--- @param s string
--- @param w integer
--- @return string
local function pad_right(s, w)
	return s .. string.rep(" ", math.max(0, w - #s))
end

--- (internal) Build a constant-table entry `{macro_name, enum_name, value}` from a BranchOffset.
--- @param bo BranchOffset
--- @return table
local function make_offset_const(bo)
	return {
		macro_name = OFFSET_MACRO_PREFIX .. bo.tag .. "_" .. bo.target,
		enum_name  = OFFSET_ENUM_PREFIX  .. bo.tag .. "_" .. bo.target,
		value      = bo.offset,
	}
end

--- (internal) Emit one atom's offset constants + enum into the lines buffer.
--- @param add  fun(s: string)
--- @param atom AtomData
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

--- Generate the per-source .offsets.h header.
--- @param source_path string
--- @param atoms_data  AtomData[]
--- @return string
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

local M = {}

--- (internal) Process one source: render offsets from canonical atom paths.
--- Returns the offsets_h path if a header was written, or nil.
--- @param ctx PassCtx
--- @param src SourceFile
--- @return string|nil  -- the offsets_h path
local function process_source(ctx, src)
	local atoms_data = {}
	local scan = src.scan or {}

	local function append_atom(atom)
		local paths = atom and atom.paths
		if not paths then return end
		local labels, branches = project_markers(paths.markers)
		atoms_data[#atoms_data + 1] = {
			name        = atom.raw_name or atom.name,
			total_words = #(paths.word_events or {}),
			offsets     = compute_offsets(labels, branches),
		}
	end

	for _, atom in ipairs(scan.atoms or {}) do append_atom(atom) end
	for _, atom in ipairs(scan.raw_atoms or {}) do append_atom(atom) end
	if #atoms_data == 0 then return nil end

	local out_path = src.dir .. "/gen/" .. duffle.basename_no_ext(src.dir) .. ".offsets.h"
	if not ctx.dry_run then
		duffle.ensure_dir(duffle.dirname(out_path))
		duffle.write_file(out_path, generate_header(src.path:gsub("/", "\\"), atoms_data))
	end
	return out_path
end

--- Run the offsets pass.
--- For each canonical source, emits a per-module `<dir_basename>.offsets.h`
--- containing constants for every marker recorded in atom.paths.
--- @param ctx PassCtx
--- @return PassResult
function M.run(ctx)
	local outputs  = {}
	local errors   = {}
	local warnings = {}

	local corpus = ctx.shared and ctx.shared.corpus
	if type(corpus) ~= "table" or type(corpus.source_order) ~= "table" then
		error("offsets.run requires ctx.shared.corpus.source_order (canonical corpus).", 0)
	end

	for _, src in ipairs(corpus.source_order) do
		local out_path = process_source(ctx, src)
		if out_path then
			outputs[#outputs + 1] = { offsets_h = out_path }
		end
	end

	return { outputs = outputs, errors = errors, warnings = warnings }
end

return M
