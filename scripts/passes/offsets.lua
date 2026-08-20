--- passes/offsets.lua — Branch-offset generator.
---
--- Reads the pre-scanned SourceScan payload (produced once upstream by `duffle.scan_source`)
--- for `MipsAtom_(name)` and leftover `MipsCode code_*` declarations, computes the word offset
--- (ELF symbol is the C ident; raw `code_*` is leftover, not the atom rule)
--- from each `atom_offset(F, T)` marker to its target `atom_label(T)` declaration, and emits
--- `gen/offsets.h` with one `#define _atom_offset_F_T = N` per branch.
---
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
--- @type string
local _bootstrap_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
--- @type DuffleExport
local duffle         = dofile(_bootstrap_dir .. "../duffle_paths.lua")

-- ════════════════════════════════════════════════════════════════════════════
-- Constants
-- ════════════════════════════════════════════════════════════════════════════

-- Offset macro/enum naming prefixes (the emitted header uses these).
--- @type string
local OFFSET_MACRO_PREFIX = "_atom_offset_"
--- @type string
local OFFSET_ENUM_PREFIX  = "atom_offset_"

-- Column width for the `#define _atom_offset_F_T = N` alignment.
--- @type integer
local OFFSET_MACRO_COL = 44

-- ════════════════════════════════════════════════════════════════════════════
-- Type declarations
-- ════════════════════════════════════════════════════════════════════════════

-- SourceFile, PassCtx, PassResult: see ps1_meta.lua

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

--- @class OffsetBranch
--- @field tag               string
--- @field target            string
--- @field branch_word       integer
--- @field consuming_encoder string|nil
--- @field consuming_arg_pos integer|nil
--- @field line              integer|nil

--- @class MarkerProjectState
--- @field labels   table<string, integer>  -- bag: label name -> word index
--- @field branches OffsetBranch[]

--- @class OffsetConst
--- @field macro_name string
--- @field enum_name  string
--- @field value      integer

--- @class OffsetOutput
--- @field offsets_h string

--- @class OffsetsPass
--- @field run fun(ctx: PassCtx): PassResult

--- @class AtomEntry
--- @field paths AtomPaths|nil

-- ════════════════════════════════════════════════════════════════════════════
-- Canonical marker projection
-- ════════════════════════════════════════════════════════════════════════════

-- MARKER_PROJECTORS is the marker-kind data table.
-- The emission-model pass already records marker word positions + consuming-instruction context;
-- this pass only projects those records into the label/branch lookup shape needed by offset computation.
--- @type table<string, fun(state: MarkerProjectState, marker: EmissionMarker): nil>
local MARKER_PROJECTORS = {
	--- @param state MarkerProjectState
	--- @param marker EmissionMarker
	--- @return nil
	label = function(state, marker)
		state.labels[marker.name] = marker.word_index
	end,
	--- @param state MarkerProjectState
	--- @param marker EmissionMarker
	--- @return nil
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
--- @param markers EmissionMarker[]
--- @return table<string, integer>
--- @return OffsetBranch[]
local function project_markers(markers)
	--- @type MarkerProjectState
	local state = { labels = {}, branches = {} }
	--- @type integer, EmissionMarker
	for _, marker in ipairs(markers or {}) do
		--- @type (fun(state: MarkerProjectState, marker: EmissionMarker): nil)|nil
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
---   missing `consuming_encoder` -> ERROR. A lone top-level `atom_offset` is not a branch.
--- @param labels   table<string, integer>
--- @param branches OffsetBranch[]
--- @param errors   PassFinding[]
--- @return BranchOffset[]
local function compute_offsets(labels, branches, errors)
	--- @type BranchOffset[]
	local results = {}
	--- @type integer, OffsetBranch
	for _, br in ipairs(branches) do
		--- @type integer|nil
		local target = labels[br.target]
		if not target then
			errors[#errors + 1] = {
				line = br.line or 0,
				msg  = "Branch target '" .. br.target .. "' has no atom_label (at word " .. br.branch_word .. ")",
			}
		else
			--- @type string|nil
			local consuming = br.consuming_encoder
			if consuming == nil or consuming == "" then
				errors[#errors + 1] = {
					line = br.line or 0,
					msg  = "atom_offset requires a consuming encoder (branch_*, jump, call_addr); top-level atom_offset is invalid; at word " .. br.branch_word,
				}
			elseif consuming == "jump_reg" or consuming == "call_reg" or consuming == "jump_link" then
				errors[#errors + 1] = {
					line = br.line or 0,
					msg  = "atom_offset cannot be used with " .. consuming
						.. " (register-form jumps have no offset field); at word " .. br.branch_word,
				}
			else
				-- Consuming instructions with an offset field (`branch_*`, `jump`, `call_addr`) use the same relative offset value.
				-- The MIPS encoding differs per opcode but the duffle `enc_i` macro handles the truncation to the immediate-field width.
				results[#results + 1] = {
					target             = br.target,
					tag                = br.tag,
					branch_word        = br.branch_word,
					offset             = target - br.branch_word - 1,
					consuming_encoder  = br.consuming_encoder,
					consuming_arg_pos  = br.consuming_arg_pos,
				}
			end
		end
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
--- @return OffsetConst
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
--- @return nil
local function emit_atom_offsets(add, atom)
	if #atom.offsets == 0 then return end
	add("// --- atom: " .. atom.name .. " (" .. atom.total_words .. " words) ---")
	add("")
	--- @type OffsetConst[]
	local consts = {}
	--- @type integer, BranchOffset
	for _, r in ipairs(atom.offsets) do
		consts[#consts + 1] = make_offset_const(r)
	end
	--- @type integer, OffsetConst
	for _, c in ipairs(consts) do
		add("#define " .. pad_right(c.macro_name, OFFSET_MACRO_COL) .. "  " .. c.value)
	end
	add("")
	add("enum {")
	--- @type integer, OffsetConst
	for _, c in ipairs(consts) do
		add("    " .. c.enum_name .. " = " .. c.macro_name .. ",")
	end
	add("};")
	add("")
end

--- Generate the per-directory .offsets.h header.
--- @param dir        string
--- @param sources    SourceFile[]
--- @param atoms_data AtomData[]
--- @return string
local function generate_header(dir, sources, atoms_data)
	--- @type string
	local dir_basename = duffle.basename_no_ext(dir)

	--- @type string[]
	local lines = {}
	--- @param s string
	--- @return nil
	local function add(s) lines[#lines + 1] = s end

	add("// Auto-generated by ps1_meta.lua (passes/offsets.lua) — DO NOT EDIT")
	add("// Directory: " .. dir:gsub("/", "\\") .. "\\")
	--- @type integer, SourceFile
	for _, src in ipairs(sources) do
		add("//   source: " .. src.path:gsub("/", "\\"))
	end
	add("#pragma once")
	add("")
	add("#pragma region " .. dir_basename)
	add("")
	add("")
	--- @type integer, AtomData
	for _, atom in ipairs(atoms_data) do
		emit_atom_offsets(add, atom)
	end
	add("#pragma endregion " .. dir_basename)
	add("")
	return table.concat(lines, "\n") .. "\n"
end

--- @type OffsetsPass
local M = {}

--- (internal) Aggregate atoms from every source in one directory, render the per-directory `offsets.h`.
--- Returns the offsets_h path if a header was written, or nil.
--- @param ctx     PassCtx
--- @param dir     string
--- @param sources SourceFile[]
--- @param errors  PassFinding[]
--- @return string|nil
local function process_directory(ctx, dir, sources, errors)
	--- @type AtomData[]
	local atoms_data = {}

	--- @param atom AtomEntry
	--- @return nil
	local function append_atom(atom)
		--- @type AtomPaths|nil
		local  paths = atom and atom.paths
		if not paths then return end
		--- @type table<string, integer>, OffsetBranch[]
		local labels, branches = project_markers(paths.markers)
		atoms_data[#atoms_data + 1] = {
			name        = atom.raw_name or atom.name,
			total_words = #(paths.word_events or {}),
			offsets     = compute_offsets(labels, branches, errors),
		}
	end

	--- @type integer, SourceFile
	for _, src in ipairs(sources) do
		--- @type SourceScan
		local scan = src.scan or {}
		--- @type integer, AtomEntry
		for _, atom in ipairs(scan.atoms or {}) do append_atom(atom) end
		--- @type integer, AtomEntry
		for _, atom in ipairs(scan.raw_atoms or {}) do append_atom(atom) end
	end
	if #atoms_data == 0 then return nil end

	--- @type string
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
	--- @type OffsetOutput[]
	local outputs  = {}
	--- @type PassFinding[]
	local errors   = {}
	--- @type PassFinding[]
	local warnings = {}

	--- @type Corpus|nil
	local corpus = ctx.shared and ctx.shared.corpus
	if type(corpus) ~= "table" then
		error("offsets.run requires ctx.shared.corpus", 0)
	end
	if type(corpus.source_order) ~= "table" then
		error("offsets.run requires ctx.shared.corpus.source_order.", 0)
	end

	-- Per-directory aggregation: every source in the same directory contributes to one `gen/offsets.h`.
	--- @type table<string, SourceFile[]>
	local sources_by_dir = corpus.sources_by_dir or duffle.group_sources_by_dir(corpus.source_order)
	--- @type string, SourceFile[]
	for dir, sources in pairs(sources_by_dir) do
		--- @type string|nil
		local out_path = process_directory(ctx, dir, sources, errors)
		if out_path then
			outputs[#outputs + 1] = { offsets_h = out_path }
		end
	end

	return { outputs = outputs, errors = errors, warnings = warnings }
end

return M
