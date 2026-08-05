--- passes/offsets.lua — Branch-offset generator.
---
--- Reads the pre-scanned SourceScan payload (produced once upstream by `duffle.scan_source`)
--- for `MipsAtom_(name)` and `MipsCode code_<name>` declarations, computes the word offset
--- from each `atom_offset(F, T)` marker to its target `atom_label(T)` declaration, and emits
--- `gen/offsets.h` with one `#define _atom_offset_F_T = N` per branch.
--- Per-directory aggregation: every source in the same directory contributes to the same `gen/offsets.h`.
--- The directory itself is the namespace; the filename does not repeat the module name.
---
--- The offset is `target_word - branch_word - 1` (the standard MIPS branch-immediate encoding: branch_offset = relative_pc_in_words - 1).

-- ════════════════════════════════════════════════════════════════════════════
-- Module-scope requires + package.path setup
-- ════════════════════════════════════════════════════════════════════════════

-- Bootstrap: same as entry scripts. See `ps1_meta.lua` for the rationale.
-- Bootstrap: load `scripts/duffle_paths.lua` (sets package.path + package.cpath).
-- Uses `debug.getinfo` to find this file's own directory, so it works both standalone and when require'd from the orchestrator.
-- Bootstrap: load `duffle_paths.lua` via `debug.getinfo(1, "S").source` (works both standalone + when require'd).
-- duffle_paths.lua sets package.path then returns `require("duffle")` at the bottom, so the dofile value IS the duffle module.
local _bootstrap_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local duffle         = dofile(_bootstrap_dir .. "../duffle_paths.lua")

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
--- @field path     string  -- Absolute path to the source file
--- @field text     string  -- Full source text
--- @field dir      string  -- Directory containing the source
--- @field basename string  -- Filename without extension
--- @field scan     table   -- Pre-scanned SourceScan payload (from duffle.scan_source)

--- @class PassCtx
--- @field shared             table -- Cross-pass shared state
--- @field shared.corpus      table -- Corpus projection
--- @field shared.word_counts table
--- @field out_root           string -- Output root (e.g. "build/gen")

--- @class PassResult
--- @field outputs  table[]  -- {kind=, path=} entries describing emit files
--- @field errors   table[]  -- {line=, msg=}  entries; build-stops
--- @field warnings table[]  -- {line=, msg=}  entries; build-succeeds

--- @class BranchOffset
--- @field tag               string      -- Marker tag (e.g. "F" in `atom_offset(F, T)`)
--- @field target            string      -- Target label name (e.g. "T" in `atom_offset(F, T)`)
--- @field branch_word       integer     -- Branch word position within the atom body
--- @field offset            integer     -- Computed per consuming instruction (see `compute_offsets`)
--- @field consuming_encoder string|nil  -- Instruction consuming the offset (e.g. "branch_le_zero", "jump", "call_addr")
--- @field consuming_arg_pos integer|nil -- 1-based arg position within the consuming instruction's arg list

--- @class AtomData
--- @field name        string         -- Atom name
--- @field total_words integer        -- Total word count of the atom body
--- @field offsets     BranchOffset[] -- Per-branch offset list

-- ════════════════════════════════════════════════════════════════════════════
-- Canonical marker projection
-- ════════════════════════════════════════════════════════════════════════════

-- MARKER_PROJECTORS is the marker-kind data table.
-- The emission-model pass already records marker word positions + consuming-instruction context;
-- this pass only projects those records into the label/branch lookup shape needed by offset computation.
local MARKER_PROJECTORS = {
	label = function(state, marker)
		state.labels[marker.name] = marker.word_index
	end,
	offset = function(state, marker)
		state.branches[#state.branches + 1] = {
			tag                = marker.name,
			target             = marker.target,
			branch_word        = marker.word_index,
			consuming_encoder  = marker.consuming_encoder,
			consuming_arg_pos  = marker.consuming_arg_pos,
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
		if    project then project(state, marker) end
	end
	return state.labels, state.branches
end

-- ════════════════════════════════════════════════════════════════════════════
-- Offset computation + header generation
-- ════════════════════════════════════════════════════════════════════════════

--- Compute branch offsets per consuming instruction.
--- Disposition table:
---   `branch_*`           -> relative offset: `target_word - branch_word - 1` (MIPS branch-immediate encoding).
---   `jump` / `call_addr` -> same value as `branch_*` (a relative word offset). 
---     The duffle headers' `enc_i` macro truncates the value to the immediate-field width (16 bits for branches, 26 bits for jumps).
---     For tape-atom bodies within a single module, this works for `j`/`jal` because the linker's symbol resolution produces the correct 26-bit absolute target via standard `j` relocations.
---     For cross-module `j`/`jal` (atom body in one module, target in another), the linker emits a `R_MIPS_26` relocation against the lower 26 bits; the upper 4 bits come from the PC of the delay slot following the `j`.
---     The metaprogram doesn't know either at compile time, so the emitted value is the relative word offset that the duffle `enc_i` macro places in the immediate field; the toolchain handles the rest.
---   `jump_reg` / `call_reg` / `jump_link` -> ERROR. Register-form jumps have no offset field; `atom_offset` is invalid.
---
--- Top-level `atom_offset(F, T)` markers (where the marker is the entire token — `consuming_encoder` == nil) default to `branch_*` behavior (relative offset).
--- This preserves backward compatibility for any top-level marker that may exist outside a control-transfer instruction.
--- @param labels   table<string, integer>
--- @param branches table[]
--- @return BranchOffset[]
local function compute_offsets(labels, branches)
	local results = {}
	for _, br in ipairs(branches) do
		local target = labels[br.target]
		if not target then
			error("Branch target '" .. br.target .. "' has no atom_label (at word " .. br.branch_word .. ")")
		end
		local consuming = br.consuming_encoder
		local offset
		if consuming == "jump_reg" or consuming == "call_reg" or consuming == "jump_link" then
			-- Register-form jumps have no offset field. `atom_offset` cannot be used here.
			error("atom_offset cannot be used with " .. consuming
				.. " (register-form jumps have no offset field); at word " .. br.branch_word)
		end
		-- All other consuming instructions (including `branch_*`, `jump`, `call_addr`, and nil for top-level markers) use the same relative offset value.
		-- The MIPS encoding differs per opcode but the duffle `enc_i` macro handles the truncation to the immediate-field width.
		offset = target - br.branch_word - 1
		results[#results + 1] = {
			target             = br.target,
			tag                = br.tag,
			branch_word        = br.branch_word,
			offset             = offset,
			consuming_encoder  = br.consuming_encoder,
			consuming_arg_pos  = br.consuming_arg_pos,
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

--- Generate the per-directory .offsets.h header.
--- @param dir          string     -- the absolute source directory
--- @param sources      table[]    -- sources contributing to this directory (for the header comment)
--- @param atoms_data   AtomData[]
--- @return string
local function generate_header(dir, sources, atoms_data)
	local dir_basename = duffle.basename_no_ext(dir)

	local lines = {}
	local function add(s) lines[#lines + 1] = s end

	add("// Auto-generated by ps1_meta.lua (passes/offsets.lua) — DO NOT EDIT")
	add("// Directory: " .. dir:gsub("/", "\\") .. "\\")
	for _, src in ipairs(sources) do
		add("//   source: " .. src.path:gsub("/", "\\"))
	end
	add("#pragma once")
	add("")
	add("#pragma region " .. dir_basename)
	add("")
	add("")
	for _, atom in ipairs(atoms_data) do
		emit_atom_offsets(add, atom)
	end
	add("#pragma endregion " .. dir_basename)
	add("")
	return table.concat(lines, "\n") .. "\n"
end

local M = {}

--- (internal) Aggregate atoms from every source in one directory, render the per-directory `offsets.h`.
--- Returns the offsets_h path if a header was written, or nil.
--- @param ctx     PassCtx
--- @param dir     string       -- the absolute source directory
--- @param sources SourceFile[] -- sources in this directory
--- @return string|nil  -- the offsets_h path
local function process_directory(ctx, dir, sources)
	local atoms_data = {}

	local function append_atom(atom)
		local  paths = atom and atom.paths
		if not paths then return end
		local labels, branches = project_markers(paths.markers)
		atoms_data[#atoms_data + 1] = {
			name        = atom.raw_name or atom.name,
			total_words = #(paths.word_events or {}),
			offsets     = compute_offsets(labels, branches),
		}
	end

	for _, src in ipairs(sources) do
		local scan = src.scan or {}
		for _, atom in ipairs(scan.atoms or {}) do append_atom(atom) end
		for _, atom in ipairs(scan.raw_atoms or {}) do append_atom(atom) end
	end
	if #atoms_data == 0 then return nil end

	local out_path = dir .. "/gen/offsets.h"
	duffle.ensure_dir(duffle.dirname(out_path))
	duffle.write_file(out_path, generate_header(dir, sources, atoms_data))
	return out_path
end

--- Run the offsets pass.
--- For each canonical source-directory, emits a per-directory `gen/offsets.h`
--- containing constants for every marker recorded in atom.paths across every source in that directory.
--- @param ctx PassCtx
--- @return PassResult
function M.run(ctx)
	local outputs  = {}
	local errors   = {}
	local warnings = {}

	local corpus = ctx.shared and ctx.shared.corpus
	if type(corpus) ~= "table" then
		error("offsets.run requires ctx.shared.corpus", 0)
	end
	if type(corpus.source_order) ~= "table" then
		error("offsets.run requires ctx.shared.corpus.source_order.", 0)
	end

	-- Per-directory aggregation: every source in the same directory contributes to one `gen/offsets.h`.
	local sources_by_dir = corpus.sources_by_dir or duffle.group_sources_by_dir(corpus.source_order)
	for dir, sources in pairs(sources_by_dir) do
		local out_path = process_directory(ctx, dir, sources)
		if out_path then
			outputs[#outputs + 1] = { offsets_h = out_path }
		end
	end

	return { outputs = outputs, errors = errors, warnings = warnings }
end

return M
