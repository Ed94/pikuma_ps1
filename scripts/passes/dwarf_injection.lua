--- passes/dwarf_injection.lua — Per-atom DWARF injection for tape-atom step-debug.
---
--- Reads the post-link ELF directly (lfs + io.open; walks the ELF32 section header table to find
--- `.debug_info` + `.debug_abbrev` + `.debug_str` + `.debug_line` + `.debug_aranges` + `.debug_rnglists`),
--- APPENDS synthetic DWARF line-program sequences for every `code_<name>` atom, EXTENDS the `.debug_aranges`
--- and main-CU range tables with the atom ranges, and APPENDS a new compilation unit to `.debug_info` with
--- per-atom `DW_TAG_subprogram` + per-wave-context-reg `DW_TAG_variable` entries 
--- (so `R_PrimCursor` etc. appear as atom-scoped locals in VSCode's Variables pane). 
--- Writes the new section data to `<out_root>/<basename>.dwarf_*.bin` plus deterministic `<out_root>/<basename>.gdbinit` skip commands.
---
--- The `build_psyq.ps1` post-link hook then splices those `.bin` files into a copy of the ELF via:
---   mipsel-none-elf-objcopy --update-section .debug_info=<bin>     <elf>
---   mipsel-none-elf-objcopy --update-section .debug_abbrev=<bin>   <elf>
---   mipsel-none-elf-objcopy --update-section .debug_str=<bin>      <elf>
---   mipsel-none-elf-objcopy --update-section .debug_line=<bin>     <elf>
---   mipsel-none-elf-objcopy --update-section .debug_aranges=<bin>  <elf>
---   mipsel-none-elf-objcopy --update-section .debug_rnglists=<bin> <elf>
---   mipsel-none-elf-objcopy --add-section    .debug_loc=<bin>      <elf>
--- (.debug_loc doesn't exist in the source ELF; --add-section creates it.
--- Splice step runs from PowerShell — no Lua subprocess; no cmd /c parsing issues.
--- objcopy's --update-section works fine in PowerShell even though Lua's `os.execute`/`io.popen` would mangle the `=` on Windows.)
---
--- Result: source stepping follows atom-body lines, and wave-context registers appear as atom-scoped locals.
--- Native VSCode stepping, line highlighting, run-to-cursor, conditional breakpoints, and per-atom locals.
--- No VSCode plugin, no Python, no pyelftools — pure Lua + objcopy.
---
--- **Conventions:** tabs (1/level), EmmyLua annotations, Lua 5.3 compatible.

-- ════════════════════════════════════════════════════════════════════════════
-- Bootstrap
-- ════════════════════════════════════════════════════════════════════════════

-- Load `duffle_paths.lua` via `debug.getinfo(1, "S").source` (works both standalone + when require'd). 
-- Sets package.path + package.cpath then returns duffle.
local _bootstrap_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local duffle         = dofile(_bootstrap_dir .. "../duffle_paths.lua")

-- ELF32 / DWARF / atoms-source-map utilities (post-link debug-info injection).
-- Sister module to duffle.lua — contains the format-constant tables (ELF32 byte offsets, DWARF opcodes, etc.) and the I/O helpers
-- (read_elf_sections, nm, source-map parser, LE byte r/w). `list_dir` is the general directory primitive in duffle.lua.
local elf_dwarf = require("elf_dwarf")

-- Per-word body lines come from the canonical `atom.paths` projection.

local lfs = require("lfs")

-- File-scope aliases to elf_dwarf helpers; the canonical implementations live in scripts/elf_dwarf.lua.
-- ELF decoding helpers come from `elf_dwarf.lua`.
local read_uleb128_at       = elf_dwarf.read_uleb128_at
local read_sleb128_at       = elf_dwarf.read_sleb128_at
local find_abbrev_table_end = elf_dwarf.find_abbrev_table_end
-- Note: uleb128 + sleb128 are encoders; read_uleb128_at + read_sleb128_at are decoders. Different functions.
local uleb128 = elf_dwarf.uleb128
local sleb128 = elf_dwarf.sleb128

-- ════════════════════════════════════════════════════════════════════════════
-- Constants
-- ════════════════════════════════════════════════════════════════════════════

-- DWARF line-program opcodes + range-list entry encodings (per DWARF5 spec).
-- All values lifted from `elf_dwarf.DWARF_LINE_OPS` + `elf_dwarf.DWARF5_RNGLISTS`.
-- Local aliases preserve the code's readability
-- (e.g. `DW_LNS_copy` reads better than `elf_dwarf.DWARF_LINE_OPS.DW_LNS_copy` in an emitter body).
local DWARF_LINE_OPS      = elf_dwarf.DWARF_LINE_OPS
local DWARF5_RNGLISTS     = elf_dwarf.DWARF5_RNGLISTS
local MIPS_BYTES_PER_WORD = elf_dwarf.MIPS_BYTES_PER_WORD

local DW_LNS_copy         = DWARF_LINE_OPS.DW_LNS_copy
local DW_LNS_advance_pc   = DWARF_LINE_OPS.DW_LNS_advance_pc
local DW_LNS_advance_line = DWARF_LINE_OPS.DW_LNS_advance_line
local DW_LNS_set_file     = DWARF_LINE_OPS.DW_LNS_set_file
local DW_LNS_negate_stmt  = DWARF_LINE_OPS.DW_LNS_negate_stmt
local DW_LNS_extended     = DWARF_LINE_OPS.DW_LNS_extended
local DW_LNE_end_sequence = DWARF_LINE_OPS.DW_LNE_end_sequence
local DW_LNE_set_address  = DWARF_LINE_OPS.DW_LNE_set_address

local DW_RLE_end_of_list   = DWARF5_RNGLISTS.end_of_list
local DW_RLE_start_length  = DWARF5_RNGLISTS.start_length

-- File index 11 in the existing main line unit is hello_gte_tape.c.
-- The injector extends that unit rather than appending an unreferenced unit.
local ATOM_SOURCE_FILE_INDEX = 11

-- RR_<R_Name> debug-visible variables come from the merged register_alias_registry filtered to aliases whose code is a valid MIPS GPR 0..31
-- (see collect_per_source_registries + by_alias in build_inserted_children).
-- Names are prefixed with `RR` to avoid collision with the C-level enum (`{R_AtomJmp = 25, R_TapePtr = 24, R_PrimCursor = 15, ...}` declared in duffle headers);
-- without the prefix, gdb's `print R_PrimCursor` resolves to the enum constant, not to this DWARF variable.
-- With `set print enum on`, gdb displays the enum identifier, so the Watch panel would show `R_PrimCursor = R_PrimCursor` instead of the register value.
-- Each RR_<R_Name>'s DW_OP_regN uses the alias's `code` as N.
-- DW_OP_bregN would describe a memory location addressed from a register; 
-- the breg form would make gdb dereference the atom register value rather than display it.

-- New abbreviation codes (100+ to avoid collision with gcc's existing 1-60+ codes).
local ABBREV_CU          = 0x64   -- 100: DW_TAG_compile_unit
local ABBREV_SUBPROGRAM  = 0x65   -- 101: DW_TAG_subprogram
local ABBREV_VARIABLE    = 0x66   -- 102: DW_TAG_variable with DW_AT_type = ref4 to U4
local ABBREV_STRUCT_TYPE = 0x67   -- 103: DW_TAG_structure_type with children (Binds_X mirror)
local ABBREV_MEMBER      = 0x68   -- 104: DW_TAG_member no children (DW_AT_type = ref4 to U4 base)
local ABBREV_BIND_VAR    = 0x69   -- 105: DW_TAG_variable no children + DW_AT_type = ref4 (the bind_args variable)
local ABBREV_BASE_TYPE   = 0x6A   -- 106: DW_TAG_base_type no children (U4)
-- Component step-into (DW_TAG_inlined_subroutine + abstract DW_TAG_subprogram).
local ABBREV_ABSTRACT_SUBPROGRAM = 0x6B   -- 107: DW_TAG_subprogram (abstract — no low_pc/high_pc); for each unique mac_X component
local ABBREV_INLINED_SUBROUTINE  = 0x6C   -- 108: DW_TAG_inlined_subroutine with children (per-component invocation range)
-- Bind_args uses DW_FORM_sec_offset → .debug_loclists for PC-ranged liveness 
-- (each field transitions from tape memory to GPR at load_pc + 8 = MIPS I load-delay slot boundary).
local ABBREV_BIND_VAR_LOCLIST = 0x6D   -- 109: DW_TAG_variable no children + DW_AT_type = ref4 + DW_AT_location = sec_offset
-- Typed-view pointer_type (for the synthetic V4_S2* / V3_S2* / U4* / void* chains).
-- MUST be a fresh abbrev code in the appended table — emitting uleb128(9) collides with GCC's
-- existing abbrev 9 (a pointer_type that carries DW_AT_byte_size + DW_AT_type), so gdb misparses
-- our 4-byte ref4 as (byte_size, type[0..2]) and lands the cursor mid-attribute.
local ABBREV_TYPED_VIEW_POINTER = 0x6E   -- 110: DW_TAG_pointer_type no children + DW_AT_type = ref4 (typed-view / U4 / void chain)

-- DWARF5 §7.7.3 loclist opcodes.
local DW_LLE_end_of_list    = 0x00
local DW_LLE_start_length   = 0x08
local DW_OP_reg0            = 0x50   -- base reg op; regN = 0x50 + N
local DW_OP_breg0           = 0x70   -- base breg op; bregN = 0x70 + N (SLEB offset)
local DW_OP_piece           = 0x93
local MIPS_LOAD_DELAY_BYTES = 0x08 -- 1 load word + 1 BD-slot word

-- DIE children-list terminator: each DIE that has children ends with a single 0 byte (DWARF5 §7.5.3).
-- This is NOT the same as DW_LLE_end_of_list despite sharing the value 0x00 — different spec sections.
local DIE_CHILDREN_TERMINATOR = 0x00

-- Field/piece byte sizes for the typed-view piece chains.
-- All Binds_* struct fields are U4 (sizeof(uint32_t) on MIPS32 = 4 bytes).
local U4_BYTE_SIZE = 4

-- DWARF3/4/5 opcodes / attributes / forms (for the .debug_info synth).
-- DW_TAG values are stable across DWARF3-5 per the standard's Table 7.1;
-- gcc emits DW_TAG_structure_type=0x13 + DW_TAG_base_type=0x24 even in DWARF5-versioned CUs, so we match those exact byte values.
local DW_TAG_compile_unit    = 0x11
local DW_TAG_subprogram      = 0x2E
local DW_TAG_variable        = 0x34
local DW_TAG_structure_type  = 0x13
local DW_TAG_member          = 0x0D
local DW_TAG_base_type       = 0x24
local DW_TAG_pointer_type    = 0x0F
-- Component step-into.
local DW_TAG_inlined_subroutine = 0x1D

local DW_AT_name             = 0x03
local DW_AT_low_pc           = 0x11
local DW_AT_high_pc          = 0x12
local DW_AT_language         = 0x13
local DW_AT_location         = 0x02
local DW_AT_comp_dir         = 0x1B
local DW_AT_byte_size        = 0x0B
local DW_AT_encoding         = 0x3E   -- DWARF5 §7.7.1: DW_AT_encoding for the DW_ATE_unsigned base type
local DW_AT_data_member_location = 0x38
local DW_AT_type             = 0x49
local DW_AT_linkage_name     = 0x6E   -- DWARF5 §7.7.1: DW_AT_linkage_name with DW_FORM_string
local DW_AT_external         = 0x3F   -- marks a variable/function as externally visible
-- Inlined_subroutine + abstract_origin attributes.
local DW_AT_abstract_origin  = 0x31
local DW_AT_call_file        = 0x58
local DW_AT_call_line        = 0x59
local DW_AT_inline           = 0x20   -- DWARF5 §7.7.1: DW_AT_inline (used by abstract subprogram for the mac_X() components)
-- decl_file + decl_line on the abstract subprogram so consumers can resolve an abstract origin back to its definition site even when no inlined_subroutine instance currently maps to it.
local DW_AT_decl_file        = 0x3A   -- DWARF5 §7.7.1: DW_AT_decl_file (1-based file index into the CU's file table)
local DW_AT_decl_line        = 0x3B   -- DWARF5 §7.7.1: DW_AT_decl_line

-- File index lookup table for the existing main line unit (Unit 2).
-- Provenance paths come back with mixed slashes; we normalize to basename and look up against the line unit's actual file table.
-- Current scope has two provenance basenames: hello_gte_tape.c (the atom's call site) and lottes_tape.h (the component definition). 
-- Both live in the existing gcc-generated line unit;
-- their 1-based indices are stable across rebuilds because the include order in code/gte_hello/hello_gte.c determines the unit's file table.
local PROVENANCE_BASENAME_TO_FILE_INDEX = {
	["hello_gte_tape.c"] = ATOM_SOURCE_FILE_INDEX,  -- = 11
	["lottes_tape.h"]    = 4,
}

--- Resolve an absolute provenance path to the line-unit file index used by the emitting line program.
--- Normalizes mixed `/` and `\` separators to a basename and looks it up against the known file table.
---
--- Fails loudly on an unknown provenance basename: adding a new component source file requires extending
--- `PROVENANCE_BASENAME_TO_FILE_INDEX` so the line-program emission contract stays explicit.
--- Silent fallback to ATOM_SOURCE_FILE_INDEX would mask the new-file case by misattributing component rows to the atom's source file.
--- @param path string  -- absolute provenance path (e.g. "C:/.../lottes_thttps://www.youtube.com/watch?v=ORM4yLkdKx8ape.h" or "C:\\...\\lottes_tape.h")
--- @return integer  -- 1-based line-unit file index
local function resolve_provenance_file_index(path)
	if path == nil or path == "" then
		error("[dwarf_injection] resolve_provenance_file_index: empty path")
	end
	-- Normalize backslashes → forward slashes (paths arrive with mixed separators from the provenance file: forward slashes from Lua's io.lines;
	-- backslashes if the input ever round-trips through Windows shell expansion).
	local normalized = path:gsub("\\", "/")
	-- Take the last path component (the basename).
	local basename = normalized:match("([^/]+)$") or normalized
	local idx      = PROVENANCE_BASENAME_TO_FILE_INDEX[basename]
	if idx == nil then
		error(string.format(
			"[dwarf_injection] resolve_provenance_file_index: unknown provenance basename '%s' (from '%s'). "
			.. "Extend PROVENANCE_BASENAME_TO_FILE_INDEX in passes/dwarf_injection.lua.",
			basename, path))
	end
	return idx
end

local DW_FORM_addr           = 0x01
local DW_FORM_data1          = 0x0B
local DW_FORM_string         = 0x08   -- inline null-terminated
local DW_FORM_strp           = 0x0E   -- 4-byte offset into .debug_str
local DW_FORM_exprloc        = 0x18   -- length-prefixed (ULEB128) DW_OP bytes
local DW_FORM_ref4           = 0x13   -- 4-byte offset within the same .debug_info CU
local DW_FORM_udata          = 0x0F   -- ULEB128 (DW_AT_byte_size for struct_type, DW_AT_data_member_location for member)
local DW_FORM_implicit_const = 0x21   -- DWARF5 §7.5.6: abbrev declaration carries a SLEB constant (used by the abbrev-table walker)
local DW_FORM_sec_offset     = 0x17   -- 4-byte section-relative offset (into .debug_loclists / .debug_rnglists)

local DW_OP_reg0             = 0x50
-- DW_OP_regN = 0x50 + N; the variable's value resides in that register.
local DW_OP_piece            = 0x93   -- followed by ULEB128 byte count (per DWARF5 §7.7.5)

local DW_ATE_unsigned        = 0x07   -- DWARF5 §7.8.1: DW_ATE_unsigned (used for U4 base type)

local DW_LANG_C99            = 0x0C   -- = 12 (C99); use as a safe "C-like" placeholder
-- (DW_LANG_Mips_Assembler = 0x8001 was used in the, but we want this CU to look like a C TU so VSCode's Variables pane treats it as code.)

-- R_<name> → MIPS GPR lookups go through the merged register_alias_registry
-- (collected by collect_per_source_registries from ctx.sources[*].scan.register_alias_registry).
-- Aliases without an `atom_reg` opt-in are absent from the registry, which means they are NOT debug-visible (no fallback GPR).
-- See the precedence chain in build_inserted_children for the per-alias type resolution.

-- Build the .debug_loclists section for every rbind atom.
-- Returns the section bytes (DWARF5 layout: unit_length(4) + version=5(2) + address_size=4(1) + segment_size=0(1) + offset_entry_count=0(4) + DW_LLE entries;
-- each atom contributes one loclist terminated by DW_LLE_end_of_list).
--
-- Per rbind atom we emit 2 loclist entries (tape → GPR split) using the last field's transition as the boundary.
-- This is a conservative approximation that always reads the correct GPR value once the first load has retired (load_pc + 8).
--
-- `tape_alias` (default: "R_TapePtr") names the wave-runtime pointer register whose value is the tape address.
-- The GPR integer comes from the merged registry; if the alias is absent, this function fails loud 
-- (the build was misconfigured; rbind atoms depend on R_TapePtr being in the registry for their piece-chain DW_OP_breg<N> location).
-- @param atom_table table[]  -- list of atoms with .rbind set
-- @param registries table    -- merged registries from collect_per_source_registries
-- @return string             -- section bytes
local function build_debug_loclists_section(atom_table, registries)
	registries = registries or {}
	-- R_TapePtr comes from the merged register_alias_registry (only present if the user opted it in via `#define atom_reg` in lottes_tape.h).
	-- When absent we emit just the section terminator (a single DW_LLE_end_of_list byte);
	-- the .debug_loclists section MUST not be empty for the linker, and `bind_args` will be emitted with no loclist PC range
	-- (readelf will display it as having no .debug_loclists entries).
	local tape_alias_entry = registries.register_alias_registry and registries.register_alias_registry["R_TapePtr"]
	local tape_reg = tape_alias_entry and tape_alias_entry.code
	local parts = {}
	for _, atom in ipairs(atom_table) do
		if atom.rbind and tape_reg then
			local fields        = atom.rbind.fields or {}
			local regs          = atom.rbind.regs or {}
			local n_fields      = #fields
			local last_load_pc  = atom.addr + (n_fields - 1) * MIPS_BYTES_PER_WORD
			local transition_pc = last_load_pc + MIPS_LOAD_DELAY_BYTES
			local tape_pieces   = {}
			for _, f in ipairs(fields) do
				local offset      = f.offset or 0
				local offset_sleb = elf_dwarf.sleb128(offset)
				-- (DW_OP_bregN, SLEB128(offset), DW_OP_piece, ULEB128(U4_BYTE_SIZE))
				-- 4 = U4_BYTE_SIZE: each piece is sizeof(uint32_t) on MIPS32.
				table.insert(tape_pieces, string.char(DW_OP_breg0 + tape_reg) .. offset_sleb .. string.char(DW_OP_piece) .. uleb128(U4_BYTE_SIZE))
			end
			local tape_expr  = table.concat(tape_pieces)
			local gpr_pieces = {}
			for _, pair in ipairs(regs) do
				-- (DW_OP_regN, DW_OP_piece, ULEB128(4)) — one piece per GPR-resident field.
		-- The 4 = U4_BYTE_SIZE: each piece is sizeof(uint32_t) on MIPS32.
		table.insert(gpr_pieces, string.char(DW_OP_reg0 + pair.reg) .. string.char(DW_OP_piece) .. uleb128(U4_BYTE_SIZE))
			end
			local gpr_expr = table.concat(gpr_pieces)
			parts[#parts + 1] = string.char(DW_LLE_start_length)
				.. elf_dwarf.write_u32_le(atom.addr)
				.. uleb128(#tape_expr)
				.. tape_expr
			parts[#parts + 1] = string.char(DW_LLE_start_length)
				.. elf_dwarf.write_u32_le(transition_pc)
				.. uleb128(#gpr_expr)
				.. gpr_expr
			parts[#parts + 1] = string.char(DW_LLE_end_of_list)
		end
	end
	-- Loclist unit header (DWARF5 §7.7.2):
	--   unit_length(4) + version(2) + address_size(1) + segment_size(1) + offset_entry_count(4) = 12 bytes header.
	--   version = 5 (DWARF5); address_size = 4 (MIPS32); segment_size = 0; offset_entry_count = 0 (we use DW_LLE_start_length, not offsets).
	local LOCLIST_HEADER_SIZE = 12
	local body        = table.concat(parts)
	local unit_length = LOCLIST_HEADER_SIZE - 4 + #body  -- -4 because unit_length excludes itself
	local header      = elf_dwarf.write_u32_le(unit_length)
		.. elf_dwarf.write_u16_le(5)    -- DWARF5
		.. string.char(U4_BYTE_SIZE)     -- address_size
		.. string.char(0)                -- segment_size
		.. elf_dwarf.write_u32_le(0)     -- offset_entry_count
	return header .. body
end

-- Compute the size of one tape piece for an atom's struct field offset.
-- The piece is: DW_OP_bregN(1) + sleb128(offset)(1..5) + DW_OP_piece(1) + uleb128(4)(1).
-- Sleb128(0) is 1 byte; sleb128(63) is 1 byte; sleb128(64) is 2 bytes; ...; sleb128(2^28) is 5 bytes.
-- 4 = U4_BYTE_SIZE: each field is sizeof(uint32_t) on MIPS32.
-- @param offset integer  -- the field's offset within the struct (0..2^32-1)
-- @return integer        -- encoded size in bytes (4 for offsets < 64, 5 for offsets 64..8191, ..., 8 for > 2^28)
local function tape_piece_size(offset)
	return 1 + elf_dwarf.sleb128_size(offset) + 1 + elf_dwarf.uleb128_size(U4_BYTE_SIZE)
end

-- Compute the per-atom loclist offset within a .debug_loclists section.
-- @param atom_table table[]  -- list of atoms with .rbind set
-- @return table  -- {[atom_name] = offset_in_section}
local function compute_loclists_offsets(atom_table)
	local LOCLIST_ENTRY_HEADER_SIZE = 1 + 4 + 1  -- DW_LLE_start_length(1) + addr(4) + uleb_length(1)
	local offsets = {}
	-- Loclist unit header (DWARF5 §7.7.2): unit_length(4) + version(2) + address_size(1) + segment_size(1) + offset_entry_count(4) = 12 bytes.
	-- The unit_length itself is not counted in the unit_length value, so the body starts at byte 12.
	local cursor = 4 + 2 + 1 + 1 + 4  -- = 12
	for _, atom in ipairs(atom_table) do
		if atom.rbind then
			offsets[atom.name] = cursor
			local n_fields = #atom.rbind.fields
			-- Sum the actual size of each tape piece based on the field's offset, not an assumed constant.
			-- The expression below mirrors what build_debug_loclists_section produces:
			--   1 (DW_LLE_start_length) + 4 (PC) + 1 (uleb length prefix) + sum(tape_piece_size(field.offset))
			--   + 1 (DW_LLE_start_length) + 4 (transition_pc) + 1 (uleb length prefix) + n_fields * 3 (gpr pieces)
			--   + 1 (DW_LLE_end_of_list)
			local tape_pieces_size = 0
			for _, f in ipairs(atom.rbind.fields or {}) do
				tape_pieces_size = tape_pieces_size + tape_piece_size(f.offset or 0)
			end
			local gpr_pieces_size   = n_fields * 3  -- each gpr piece: DW_OP_regN(1) + DW_OP_piece(1) + uleb(4)(1) = 3 bytes
			local tape_entry = LOCLIST_ENTRY_HEADER_SIZE + tape_pieces_size
			local gpr_entry  = LOCLIST_ENTRY_HEADER_SIZE + gpr_pieces_size
			local body_len   = tape_entry + gpr_entry + 1  -- +1 for DW_LLE_end_of_list
			cursor = cursor + body_len
		end
	end
	return offsets
end

-- Default name for the synthetic CU (so VSCode lists it as a known source).
local DEFAULT_CU_NAME     = "tape_atom_locals"
local DEFAULT_CU_COMP_DIR = "."

-- SECTION_WRITERS owns the .bin output path templates.

-- Default basename if not provided via ctx.
local DEFAULT_BASENAME = "hello_gte"

-- ════════════════════════════════════════════════════════════════════════════
-- Type declarations
-- ════════════════════════════════════════════════════════════════════════════

--- @class DwarfInjectionCtx
--- @field flags    table   -- ctx.flags; reads flags.elf_path + flags.dwarf_injection
--- @field sources  table[] -- source files with scan.skip_over associations
--- @field out_root string  -- output root (e.g. "build/gen")
--- @field basename string  -- input ELF basename (default "hello_gte")

--- Normalize a source path for GDB linespecs and component-association keys.
--- GDB accepts forward slashes on Windows; absolute paths avoid cwd-dependent sidecars and match provenance contract.
--- @param path string
--- @return string
local function normalize_debug_path(path)
	return duffle.to_absolute_path(path):gsub("\\", "/")
end

--- Consume the per-source scanner associations without naming any atom or component in production.
--- Whole atoms remain symbol-keyed; components are file-qualified internally so a source marker associates
--- with its exact component definition even though GDB 12 requires function-only skip entries for the resulting synthetic inline frame.
--- Iterates `corpus.source_order` (the canonical corpus projection).
--- @param corpus table  -- the canonical corpus from `ctx.shared.corpus`
--- @return table  -- {atoms = {[symbol] = association}, components = {[file|name] = association}}
local function collect_skip_over(corpus)
	local skip_over = { atoms = {}, components = {} }
	for _, src in ipairs((corpus and corpus.source_order) or {}) do
		local scan_skip = src.scan and src.scan.skip_over
		if scan_skip then
			for atom_name, association in pairs(scan_skip.atoms or {}) do
				skip_over.atoms[atom_name] = {
					name        = atom_name,
					source_path = normalize_debug_path(src.path),
					association = association,
				}
			end
			for component_name, association in pairs(scan_skip.components or {}) do
				local source_path = normalize_debug_path(src.path)
				-- component_skip_key (the lower() .. "\0" .. component_name part) inlined at this single call site
				-- (no other callers remain after pass 17).
				skip_over.components[source_path:lower() .. "\0" .. component_name] = {
					name        = component_name,
					source_path = source_path,
					association = association,
				}
			end
		end
	end
	return skip_over
end

--- Project the canonical corpus registries into the shape the section builders expect.
--- The corpus already owns the merged `register_alias_registry`, `type_name_registry`, `atom_views`, `atom_ctxs`, `atom_phases`, and `atom_infos` projections (populated by `passes.scan_source.lua`).
--- This helper just references them so the rest of `dwarf_injection.lua` keeps the same `registries.<key>` access shape it has always used.
---
--- Every `R_*` lookup and per-atom type override resolution in this file goes through this merged table.
--- Aliases without `atom_reg` adjacent are absent; the absence is treated as "not debug-visible" (see build_inserted_children for the precedence chain).
---
--- When two sources register the same key, the last-writer wins (later sources override earlier).
--- Today only one source declares wave-context enums, so collisions are absent.
--- @param corpus table  -- the canonical corpus from `ctx.shared.corpus`
--- @return table  -- {
---   register_alias_registry = {[R_Name]    = AliasEntry},
---   type_name_registry      = {[T]         = TypeEntry},
--- 	atom_views              = {[atom_name] = AtomViewEntry},
--- }
local function collect_per_source_registries(corpus)
	-- The corpus already holds the merged registries; reference them directly.
	-- No per-source iteration is needed because `passes.scan_source.lua` has already folded every per-source scan into the canonical tables.
	-- `atom_infos` is preserved byte-for-byte with no filtering; consumers consult `corpus.atoms_by_name`
	-- themselves when they need to know whether a particular atom_info corresponds to an actual atom record.
	local atom_infos_list = {}
	for _, ai in ipairs((corpus and corpus.atom_infos) or {}) do
		atom_infos_list[#atom_infos_list + 1] = ai
	end
	return {
		register_alias_registry = (corpus and corpus.register_alias_registry) or {},
		type_name_registry      = (corpus and corpus.type_name_registry)      or {},
		atom_views              = (corpus and corpus.atom_views)              or {},
		-- Per-atom atom_ctx declarations: atom_name -> {rbind_atom, ...}
		-- (populated by scan_source from `atom_ctx(<atom_name>)` sub-calls inside `atom_info`)
		atom_ctxs               = (corpus and corpus.atom_ctxs)               or {},
		-- Per-phase atom groups: phase_label -> {atoms = {atom_name1, ...}}
		-- (populated by scan_source from `atom_phase(<label>)` sub-calls inside `atom_info`; cross-source merged)
		atom_phases             = (corpus and corpus.atom_phases)             or {},
		-- Corpus-wide atom_infos list, byte-for-byte.
		atom_infos              = atom_infos_list,
	}
end

--- Render deterministic debugger skip commands. 
--- Ordering is stable by category: exact atom symbols first (lexicographic), then exact component function names (lexicographic full command).
--- Atom commands come from the matched nm/source-map table so the emitted name is the actual ELF symbol.
--- The scanner tables and command set both deduplicate repeated source observations.
--- @param skip_over  table
--- @param atom_table table[] -- nm/source-map cross-reference; names are actual ELF symbols
--- @return string
local function build_gdbinit(skip_over, atom_table)
	local commands = {}
	local atom_names = {}
	for _, atom in ipairs(atom_table) do
		if atom.skip_over then atom_names[#atom_names + 1] = atom.name end
	end
	table.sort(atom_names)
	for _, atom_name in ipairs(atom_names) do
		commands[#commands + 1] = "skip function " .. atom_name
	end

	local component_commands = {}
	for _, component in pairs(skip_over.components) do
		component_commands[#component_commands + 1] = "skip function mac_" .. component.name
	end
	table.sort(component_commands)
	local prior = nil
	for _, command in ipairs(component_commands) do
		if command ~= prior then commands[#commands + 1] = command end
		prior = command
	end

	return table.concat(commands, "\n") .. "\n"
end

-- ════════════════════════════════════════════════════════════════════════════
-- LEB128 encoders
-- ════════════════════════════════════════════════════════════════════════════
--
-- Uses `elf_dwarf.uleb128` and `elf_dwarf.sleb128`.
-- See those helpers for the bit-layout documentation + named constants (LEB_CONT_BIT, LEB_DATA_MASK, SLEB_SIGN_BIT).
-- File-scope `local uleb128` + `local sleb128` aliases live near the module top so they're resolvable by every function below.

-- ════════════════════════════════════════════════════════════════════════════
-- DWARF line-program encoder
-- ════════════════════════════════════════════════════════════════════════════

--- Build the byte sequence for ONE atom's line program:
---   DW_LNE_set_address(addr)
---   [entry 1 emission]
---   for each subsequent entry (idx 2..N):
---     DW_LNS_advance_pc(1 .word = 4 bytes)
---     [entry emission at new PC]
---   DW_LNE_end_sequence
---
--- Each "entry emission" emits one or more rows at the same PC, tracking the source state {file_idx, line}.
--- State transitions emit DW_LNS_set_file + DW_LNS_advance_line as needed; 
--- same-state transitions emit only the row (copy).
---
--- Entry rules:
---   * RAW entry (no invocation): emit (call_file, entry.line) at this PC.
---   * Invocation entry, NOT first word: emit (comp_file, comp_line).
---   * Invocation entry, IS first word: emit TWO rows at the same PC in order: (call_file, inv.call_line), then (comp_file, inv.comp_line).
---
--- atom-entry rules:
---   * Atom entry 1 also gets a duplicate copy_op for the GDB 12 zero-instruction-prologue marker (no advance_pc — same PC).
---
--- Wire format reminder (DWARF5 §6.2.5):
---   - Standard opcodes: 1 byte opcode + payload (per opcode length).
---   - Extended opcode marker byte = 0.
---   - Extended opcodes: marker byte + ULEB128 size + sub_opcode + payload.
---
--- Statement-state rules:
---   * A marked whole atom emits one opaque is_stmt=false range row and no nested component rows; its subprogram symbol/range remains available.
---   * A marked component keeps its first-word call-site row true, toggles only the definition row/range false, and restores before the next unmarked row.
---   * Whole-atom suppression wins over component markers; no nested inversion.
--- @param atom table  -- {name, addr, size_bytes, words, entries, invocations?, skip_over?}
--- @return string
local function build_atom_sequence(atom)
	local function set_address(addr)
		-- Per DWARF5 §6.2.5.3: marker(0) + size(ULEB128, includes sub_opcode byte) + sub_opcode + payload
		-- For set_address: size = 1 (sub_opcode) + 4 (addr) = 5
		local addr_bytes = elf_dwarf.write_u32_le(addr)
		local sub_size   = string.char(DW_LNE_set_address) .. addr_bytes
		return string.char(DW_LNS_extended) .. uleb128(#sub_size) .. sub_size
	end
	local function copy_op()                return string.char(DW_LNS_copy) end
	local function set_file(file_index)     return string.char(DW_LNS_set_file)     .. uleb128(file_index)  end
	local function advance_pc(bytes_delta)  return string.char(DW_LNS_advance_pc)   .. uleb128(bytes_delta) end
	local function advance_line(line_delta) return string.char(DW_LNS_advance_line) .. sleb128(line_delta)  end
	local function negate_stmt()            return string.char(DW_LNS_negate_stmt) end
	local function end_sequence()
		-- size = 1 (just the sub_opcode byte, no payload)
		return string.char(DW_LNS_extended)
			.. string.char(DWARF_LINE_OPS.end_sequence_payload_size)
			.. string.char(DW_LNE_end_sequence)
	end

	if not atom.entries or #atom.entries == 0 then return set_address(atom.addr) .. end_sequence() end

	-- A jump-threaded atom is reached by `jr`, not a C call.
	-- GDB therefore cannot apply the parent `skip function` entry before descending into a visible child inline frame.
	-- Make an explicitly marked atom DWARF-opaque:
	-- one non-statement row covers its complete address range, with no per-word or component source transitions.
	-- The atom's subprogram DIE remains, so symbolic lookup, explicit address breakpoints, and stepi are unaffected.
	if atom.skip_over then
		return table.concat({
			set_address(atom.addr),
			set_file(ATOM_SOURCE_FILE_INDEX),
			advance_line(atom.entries[1].line - 1),
			negate_stmt(),
			copy_op(),
			advance_pc(atom.size_bytes),
			negate_stmt(),
			end_sequence(),
		})
	end

	-- Find which invocation each entry belongs to (if any).
	-- Returns the invocation record or nil. Pre-computed once so we don't rescan per emitted row.
	local function inv_for_idx(idx)
		if not atom.invocations then return nil end
		for _, inv in ipairs(atom.invocations) do
			-- inv.start_pos / inv.end_pos are 0-based .word positions; entries are 1-based.
			if idx >= inv.start_pos + 1 and idx <= inv.end_pos + 1 then
				return inv
			end
		end
		return nil
	end

	local parts = {
		set_address(atom.addr),  -- 7 bytes: marker + size + sub + addr; PC := atom.addr
	}

	-- Source state tracker: emits set_file + advance_line only on transitions, keeps bytes minimal.
	-- Both fields stay in sync with what we emit so we never duplicate a set_file or skip a state-change emit.
	local cur_file = nil  -- line-state.file_idx (nil = uninitialized)
	local cur_line = 1    -- line-state.line starts at 1 (per DWARF spec)
	local is_stmt  = true -- main line unit default_is_stmt; every sequence ends restored

	local function set_statement_state(want_stmt)
		if is_stmt ~= want_stmt then
			parts[#parts + 1] = negate_stmt()
			is_stmt = want_stmt
		end
	end

	-- Emit a state transition (set_file + advance_line + is_stmt as needed) before a row, then the row itself.
	-- Used for the row(s) at one entry PC.
	local function emit_row(file_idx, line, want_stmt)
		if cur_file ~= file_idx then
			parts[#parts + 1] = set_file(file_idx)
			cur_file          = file_idx
		end
		if cur_line ~= line then
			parts[#parts + 1] = advance_line(line - cur_line)
			cur_line          = line
		end
		set_statement_state(want_stmt)
		parts[#parts + 1] = copy_op()
	end

	-- Whole-atom suppression wraps the independent sequence itself.
	-- File/line state setup follows while is_stmt is already false; the matching restore is emitted after the final row below.
	if atom.skip_over then set_statement_state(false) end

	-- --- Atom entry (idx 1) -------------------------------------------------
	-- Determine entry-1's primary row (always the call-site file/line;
	-- we may emit a second row immediately after if entry 1 is also a component invocation's first word).
	local inv1    = inv_for_idx(1)
	local entry_1 = atom.entries[1]
	-- The atom body's own source file (the call site for any mac_X(...) inside it).
	local call_file_idx = ATOM_SOURCE_FILE_INDEX

	-- Primary row: call site at atom start.
	-- Capture its (file, line) so we can re-emit it as the GDB 12 zero-instruction-prologue marker below.
	local entry_1_call_file = call_file_idx
	local entry_1_call_line = (inv1 and inv1.call_line) or entry_1.line
	local atom_is_stmt      = not atom.skip_over

	-- Primary row: call site at atom start.
	emit_row(entry_1_call_file, entry_1_call_line, atom_is_stmt)

	-- If entry 1 is the first word of a component invocation, emit the component-definition row at the same PC immediately after.
	-- The def line is always a statement target unless the inv is explicitly skip-over (atom_dbg_skip_over);
	-- the whole-atom skip path takes the early-return at line ~497 above so atom_is_stmt is irrelevant here.
	-- For the body row, prefer `body_lines[1]`  (the actual source line of the first body word in the macro's expansion)
	-- over `comp_line` (the macro signature line).
	-- When `body_lines` is absent (the component was not indexed by the scan, e.g. an external macro), 
	-- fall back to `comp_line` so the line program remains valid.
	if inv1 and 1 == inv1.start_pos + 1 then
		local comp_file_idx_1 = resolve_provenance_file_index(inv1.comp_file)
		local body_line_1     = (inv1.body_lines and inv1.body_lines[1]) or inv1.comp_line
		emit_row(comp_file_idx_1, body_line_1, not inv1.skip_over)
	end

	-- GDB 12 zero-instruction-prologue marker: duplicate of the PRIMARY entry-1 emission (the call-site row).
	-- We must explicitly restore the source state to (call_file, call_line) before emitting the duplicate,
	-- otherwise the duplicate lands at whatever state we ended entry-1 in (the component row, if entry 1 is an invocation start), 
	---which would attach the marker to the wrong source statement.
	---
	-- Only emitted at atom entry, NOT at every component-invocation start.
	emit_row(entry_1_call_file, entry_1_call_line, atom_is_stmt)

	-- --- Subsequent entries (idx 2..N) --------------------------------------
	for idx = 2, #atom.entries do
		local entry = atom.entries[idx]
		local inv   = inv_for_idx(idx)

		-- Advance PC by 1 .word (4 bytes on MIPS).
		parts[#parts + 1] = advance_pc(MIPS_BYTES_PER_WORD)

		if inv and idx == inv.start_pos + 1 then
			-- First word of a component invocation: emit TWO rows at this PC.
			-- 1) call-site row remains a statement target unless the whole atom is marked.
			emit_row(call_file_idx, inv.call_line, atom_is_stmt)
			-- 2) component body row at this PC.
			-- Prefer `body_lines[1]` over `comp_line` so gdb's `step` lands on the macro's actual body line (not the signature line above `{ ... }`).
			-- Fallback to `comp_line` when the component isn't indexed.
			local body_file_idx = resolve_provenance_file_index(inv.comp_file)
			local body_line_1   = (inv.body_lines and inv.body_lines[1]) or inv.comp_line
			emit_row(body_file_idx, body_line_1, not inv.skip_over)
		elseif inv then
			-- Subsequent word of an invocation: 1-based offset into body_lines:
			-- word 1 of the invocation corresponds to body_lines[1], word 2 -> body_lines[2], etc.
			-- 1-based offset = idx - inv.start_pos (since idx = inv.start_pos + i for the i-th body word).
			-- When `body_lines` is missing (older emitters / external macros), fall back to comp_line.
			local body_file_idx = resolve_provenance_file_index(inv.comp_file)
			local words_into    = idx - inv.start_pos  -- 1-based word position in invocation
			local body_line_i   = (inv.body_lines and inv.body_lines[words_into]) or inv.comp_line
			emit_row(body_file_idx, body_line_i, not inv.skip_over)
		else
			-- RAW word: single call-site row. emit_row restores is_stmt after a selected component range before exposing this adjacent row.
			emit_row(call_file_idx, entry.line, atom_is_stmt)
		end
	end

	-- Every sequence starts from default_is_stmt=true.
	-- Restore that state before DW_LNE_end_sequence so a marked whole atom has explicit bounded toggles
	-- and no state can leak to a following independent atom sequence.
	set_statement_state(true)
	parts[#parts + 1] = end_sequence()
	return table.concat(parts)
end

-- ════════════════════════════════════════════════════════════════════════════
-- Helpers: nm + source-map.txt + atom table
-- ════════════════════════════════════════════════════════════════════════════

--- Build the atom table the section builders consume.
--- Cross-references nm symbols with `corpus.atoms_by_name` and derives word rows + format-1 outermost invocation rows from `atom.paths`.
---
--- The atom table is built entirely from in-memory state — disk source-map and provenance text artifacts are NOT consulted.
--- Those artifacts are diagnostic outputs, not semantic inputs; the DWARF injection pass must remain correct regardless of their on-disk content.
---
--- The result shape (one entry per ELF symbol matched against the corpus):
---   `{name, addr, size_bytes, words, entries, invocations, skip_over?}`
--- where:
---   * `entries[i].pos`  — 0-based `.word` position (matches the source-map format-1 row layout; downstream DWARF builders compare against this).
---   * `entries[i].line` — call-site line for that word.
---   * `entries[i].text` — trimmed encoder token text from `atom.paths.word_events`.
---   * `invocations[j]` — one entry per format-1 outermost `mac_X(...)` invocation with 
---     `{comp_name, call_file, call_line, comp_file, comp_line, start_pos, end_pos, body_lines, skip_over}`. `body_lines[k]`
---     is the k-th word's source line within the component body.
---
--- @param corpus    table -- the canonical corpus from `ctx.shared.corpus`
--- @param addrs     table -- ELF symbols keyed by atom name from `elf_dwarf.read_nm`
--- @param skip_over table -- {atoms = {[symbol] = association}, components = {[file|name] = association}}
--- @return table[]  -- list of {name, addr, size_bytes, words, entries, invocations, skip_over?}
local function build_atom_table(corpus, addrs, skip_over)
	local atoms_by_name = corpus.atoms_by_name or {}

	-- Cross-ref: keep only the atoms that exist in BOTH the nm symbol table AND the canonical corpus projection.
	-- Address-ascending sort + lexical Stable tie-breaker: declaration order, then symbol address.
	local out = {}
	for name, info in pairs(addrs) do
		local atom_record = atoms_by_name[name]
		if atom_record then
			local paths            = atom_record.paths or {}
			local word_events      = paths.word_events or {}
			local invocations_proj = paths.invocations or {}

			-- Build the dense entries list from `word_events`. `word_events[i].i` is the 0-based `.word` position;
			-- `call_line` is the root atom's physical source line for that word (stamped by emission_model).
			local entries = {}
			for idx, ev in ipairs(word_events) do
				entries[#entries + 1] = {
					pos  = ev.i or (idx - 1),
					line = ev.call_line or 0,
					text = ev.call_text or "",
				}
			end

			local atom = {
				name       = name,
				addr       = info[1],
				size_bytes = info[2],
				words      = #word_events,
				entries    = entries,
				skip_over  = skip_over.atoms[name] ~= nil,
			}

			-- Group consecutive `word_events` rows whose outermost invocation
			-- is the SAME format-1 invocation into a single `atom.invocations`
			-- entry. Keep entries grouped by outermost invocation
			-- (two consecutive rows with the same comp_name/call_file/call_line/
			-- comp_file/comp_line are part of the same invocation).
			if #invocations_proj > 0 then
				local invocations = {}
				local cur_inv = nil
				for _, ev in ipairs(word_events) do
					local outer_id = ev.outermost_invocation_id
					local outer_inv = outer_id and invocations_proj[outer_id] or nil
					if outer_inv and outer_inv.component_name then
						local inv_key = outer_inv.component_name
							.. "|" .. (outer_inv.call_path or "")
							.. "|" .. tostring(outer_inv.call_line or 0)
							.. "|" .. (outer_inv.def_path or "")
							.. "|" .. tostring(outer_inv.def_line or 0)
						local ev_pos = ev.i or 0
						if cur_inv and cur_inv.key == inv_key then
							cur_inv.end_pos = ev_pos
							cur_inv.body_lines[#cur_inv.body_lines + 1] = ev.body_line or 0
						else
							if cur_inv then invocations[#invocations + 1] = cur_inv end
							cur_inv = {
								key        = inv_key,
								comp_name  = outer_inv.component_name,
								call_file  = outer_inv.call_path or "",
								call_line  = outer_inv.call_line or 0,
								comp_file  = outer_inv.def_path or "",
								comp_line  = outer_inv.def_line or 0,
								start_pos  = ev_pos,
								end_pos    = ev_pos,
								skip_over  = skip_over.components[normalize_debug_path(outer_inv.def_path or ""):lower()
									.. "\0" .. outer_inv.component_name] ~= nil,
								body_lines = { ev.body_line or 0 },
							}
						end
					else
						-- RAW row: flush the current invocation.
						if cur_inv then invocations[#invocations + 1] = cur_inv; cur_inv = nil end
					end
				end
				if cur_inv then invocations[#invocations + 1] = cur_inv end
				atom.invocations = invocations
			end
			out[#out + 1] = atom
		end
	end
	table.sort(out, function(a, b) return a.addr < b.addr end)
	return out
end

--- Compute the set of distinct components invoked across all atoms.
--- Returns `{name -> {kind, def_file, def_line}}` keyed by component name (e.g. `yield`, `gte_load_tri_verts`).
--- @param atom_table table[]
--- @return table<string, table>
local function collect_component_defs(atom_table)
	local out = {}
	for _, atom in ipairs(atom_table) do
		for _, inv in ipairs(atom.invocations or {}) do
			if not out[inv.comp_name] then
				out[inv.comp_name] = {
					name     = inv.comp_name,
					def_file = inv.comp_file,
					def_line = inv.comp_line,
				}
			end
		end
	end
	return out
end

-- ════════════════════════════════════════════════════════════════════════════
-- rbind atom detection + (reg, field) pairing
-- ════════════════════════════════════════════════════════════════════════════
--
-- An "rbind atom" has `atom_bind(Binds_X)` in its `atom_info(...)` sub-call.
-- The atom body pops one field per `load_word(R_<reg>, R_TapePtr, O_(Binds_X,Field))`
-- and the order of these load_word calls defines the (reg, field) pairing for the piece-chain DWARF location expression.
--
-- We use the SourceScan payload populated by `passes/scan_source.lua` (the dep-closed upstream pass).
-- That pass walks each source once and populates `src.scan.atom_infos` (the atom_info sub-call parse) and `src.scan.binds` (the Binds_X struct field parse).
--
-- parse_rbind_atoms consumes `scan.binds[i].fields` directly, which is populated by the scan-source pass with the typed-field record ({name, type_name, pointer_depth, offset, byte_size}).

--- Find every `load_word(R_<reg>, R_TapePtr, O_(Binds_X, FieldName))` call in the atom body and return ordered (reg_index, field_name) pairs.
--- Source pattern (single-line, comma-separated at top level):
---   load_word(R_PrimCursor, R_TapePtr, O_(Binds_CubeTri,PrimCursor)),
---   load_word(R_FaceCursor, R_TapePtr, O_(Binds_CubeTri,FaceCursor)),
---   ...
---
--- The GPR for each `R_<reg>` is looked up in the merged register_alias_registry; aliases absent from the registry
--- (no `atom_reg` opt-in) are silently skipped — the resulting rbind record will be incomplete and the atom will fail to bind a usable piece chain.
--- This is intentional: silently falling back to a hardcoded GPR would mask the missing opt-in.
---
--- Pre-tokenized: `body_tokens` is the scan-source pass's pre-split list of top-level
--- statements (each entry is a single `load_word(...)` call or other statement).
--- @param body_tokens table[]  -- the atom's pre-tokenized body statements (from atom.body_tokens)
--- @param binds_name  string   -- expected Binds_X name (skip pairs with mismatching binds)
--- @param registries  table    -- merged registries from collect_per_source_registries
--- @return table[]             -- list of {reg = <MIPS index>, field = <field name>}
local function parse_body_load_pairs(body_tokens, binds_name, registries)
	local pairs = {}
	local reg_index_by_name = (registries and registries.register_alias_registry) or {}
	for _, t in ipairs(body_tokens or {}) do
		local tok = duffle.trim(t.tok or "")
		-- Match "load_word(...)" — the entire call is one body_tokens entry.
		local inner = tok:match("^load_word%s*%((.*)%)$")
		if inner then
			local args = duffle.split_top_level_commas(inner)
			-- Expected shape: (R_<reg>, R_TapePtr, O_(Binds_<X>, FieldName))
			if #args >= 3 then
				local reg_name  = duffle.trim(args[1])
				local third_arg = duffle.trim(args[3])
				-- Match O_(Binds_<X>, FieldName)
				local b, f = third_arg:match("^O_%((Binds_[%w_]+)%s*,%s*(.-)%s*%)$")
				local alias_entry = reg_index_by_name[reg_name]
				if b and b == binds_name and alias_entry and alias_entry.code then
					pairs[#pairs + 1] = {
						reg   = alias_entry.code,
						field = duffle.trim(f),
					}
				end
			end
		end
	end
	return pairs
end

--- Collect every rbind atom + the matching Binds_X struct + (reg, field) pairs.
---
--- Inputs come from the dep-closed `scan-source` pass (the per-source `src.scan` payload is preserved on each `corpus.source_order` entry).
---
--- Returns:
---   rbind_atoms     = {[atom_name] = {binds, fields, regs, byte_size, info_line}}
---   rbind_structs   = {[binds_name] = {byte_size, fields, atom_names}}
---
--- The `regs` list per atom is ordered: each entry is the MIPS reg index that holds the matching field in the source-order pop sequence.
--- The piece chain uses (DW_OP_regN, DW_OP_piece, ULEB128(field_size)).
---
--- Binds fields come from `scan.binds`; no body-text source walk is needed.
--- per-source `scan.binds[i].fields` already carries the typed-field record after the scan-source generalization.
--- @param corpus     table   -- the canonical corpus from `ctx.shared.corpus`
--- @param atom_table table[] -- the cross-ref'd atom table from build_atom_table
--- @param registries table   -- merged registries from collect_per_source_registries
--- @return table, table      -- (rbind_atoms, rbind_structs)
local function parse_rbind_atoms(corpus, atom_table, registries)
	registries = registries or {}
	local rbind_atoms   = {}
	local rbind_structs = {}

	-- Index binds by struct name; consume `scan.binds[i].fields` directly (no body-text re-walk).
	-- The scan-source pass emits each Binds_X's fields as {[type_name, pointer_depth, offset, byte_size, ...]}
	-- so this pass can build the rbind_structs entry without re-parsing.
	local binds_by_name = {}
	for _, src in ipairs((corpus and corpus.source_order) or {}) do
		local scan = src.scan
		if scan then
			for _, b in ipairs(scan.binds or {}) do
				binds_by_name[b.name] = b
			end
		end
	end

	for binds_name, b in pairs(binds_by_name) do
		if b.fields and b.bytes then
			rbind_structs[binds_name] = {
				bytes      = b.bytes,
				fields     = b.fields,
				atom_names = {},
			}
		end
	end

	-- Walk every atom_info; if `binds` is set, find the atom body_tokens + parse load_word pairs.
	local body_tokens_by_atom = {}
	for _, src in ipairs((corpus and corpus.source_order) or {}) do
		local scan = src.scan
		if scan then
			for _, atom in ipairs(scan.atoms or {}) do
				body_tokens_by_atom[atom.name] = atom.body_tokens
			end
		end
	end

	local ai_by_atom = {}
	for _, src in ipairs((corpus and corpus.source_order) or {}) do
		local scan = src.scan
		if scan then
			for _, ai in ipairs(scan.atom_infos or {}) do
				ai_by_atom[ai.atom_name] = ai
			end
		end
	end

	for atom_name, ai in pairs(ai_by_atom) do
		if ai.binds then
			local struct     = rbind_structs[ai.binds]
			local body_toks  = body_tokens_by_atom[atom_name]
			if struct and body_toks then
				local pairs = parse_body_load_pairs(body_toks, ai.binds, registries)
				if #pairs > 0 then
					rbind_atoms[atom_name] = {
						binds     = ai.binds,
						fields    = struct.fields, -- {name, offset} from scan.binds
						bytes     = struct.bytes,
						regs      = pairs,         -- ordered list of {reg, field}
						info_line = ai.info_line,
					}
					table.insert(struct.atom_names, atom_name)
				end
			end
		end
	end

	-- Mark rbind atoms in the main atom_table.
	for _, atom in ipairs(atom_table) do
		if rbind_atoms[atom.name] then
			atom.rbind = rbind_atoms[atom.name]
		end
	end

	return rbind_atoms, rbind_structs
end

-- ════════════════════════════════════════════════════════════════════════════
-- Section builders (single dispatch table — see guide_metaprogram_ssdl.md §11)
-- ════════════════════════════════════════════════════════════════════════════

--- Append per-atom line-program sequences to the existing main .debug_line unit 
--- (the final unit, referenced by the main CU's DW_AT_stmt_list).
---
--- This builder extends the main compilation unit.
--- No compilation unit pointed at it through DW_AT_stmt_list, so gdb ignored it. 
--- It also encoded byte 13 as the extended-opcode marker; byte 13 is actually the first special opcode. 
--- The existing final unit already contains hello_gte_tape.c as file index 11 and ends with a valid end_sequence.
--- We preserve its bytes, append independent atom sequences, and increase only that unit's DWARF32 unit_length.
--- @param existing   string -- existing section bytes, byte-for-byte
--- @param atom_table table  -- list of {name, addr, size_bytes, words, entries}
--- @return string
local function build_dwarf_line_section(existing, atom_table)
	if #atom_table == 0 then return existing end

	-- Build the sequences.
	local sequences = {}
	for _, atom in ipairs(atom_table) do
		sequences[#sequences + 1] = build_atom_sequence(atom)
	end
	local appended = table.concat(sequences)

	-- Walk DWARF32 line units and retain the final unit's bounds.
	-- The main C CU points at this final unit (DW_AT_stmt_list = 0x5b in today's ELF).
	local unit_pos, last_pos, last_length, last_end = 0, nil, nil, nil
	while unit_pos < #existing do
		if unit_pos + 4 > #existing then return existing end
		local unit_length = elf_dwarf.read_u32_le(existing, unit_pos)
		if    unit_length == elf_dwarf.ELF32.dw_dwarf32_terminator then return existing end
		local unit_end_excl = unit_pos + 4 + unit_length
		if unit_end_excl > #existing then return existing end
		last_pos, last_length, last_end = unit_pos, unit_length, unit_end_excl
		unit_pos                        = unit_end_excl
	end
	if unit_pos ~= #existing or not last_pos then return existing end

	local new_length       = last_length + #appended
	local new_length_bytes = elf_dwarf.write_u32_le(new_length)

	return existing:sub(1, last_pos)
		.. new_length_bytes
		.. existing:sub(last_pos + 5, last_end)
		.. appended
end

--- Extend .debug_aranges with one entry per atom, pointing at the same CU the existing entries point at 
--- (read from the existing header's debug_info_offset field). 
--- The 8-byte zero terminator is preserved.
---
--- Existing .debug_aranges layout (DWARF4 §6.1.1, 32-bit):
---   unit_length       (4 bytes) -- size of the rest
---   version           (2 bytes) -- = 2
---   debug_info_offset (4 bytes) -- CU DIE offset in .debug_info
---   address_size      (1 byte)  -- = 4 on MIPS
---   segment_size      (1 byte)  -- = 0
---   [entries...]      -- address(4) + length(4) per entry
---   terminator        -- address=0 + length=0 (8 zero bytes)
--- @param existing   string
--- @param atom_table table
--- @return string
local function build_dwarf_aranges_section(existing, atom_table)
	if #existing < 12 then
		io.stderr:write("[dwarf_injection] WARN: .debug_aranges section too short (" .. #existing .. " bytes) to contain a unit header; passing through unchanged\n")
		return existing
	end  -- header sanity

	-- .debug_aranges can contain multiple compilation units (CUs).
	-- gcc-mips-elf emits one CU per .text section TU.
	-- We extend the LAST unit by replacing its 8-byte terminator with our atom entries followed by a new 8-byte terminator.
	-- We bump the unit's length field accordingly.
	--
	-- Unit structure (DWARF4 §7.21):
	--   unit_length (4)
	--   version (2)
	--   debug_info_offset (4)  -- CU DIE offset in .debug_info
	--   address_size (1)
	--   segment_size (1)
	--   entries... (4-byte addr + 4-byte length)
	--   terminator (8 bytes: addr=0, length=0)

	-- Walk all units and emit each one (preserving existing structure).
	-- For the LAST unit, replace the terminator with my entries + new term.
	local result       = {}
	local i            = 0  -- zero-based wire offset
	local is_last_unit = false

	while i < #existing do
		-- Read this unit's length.
		local ul = elf_dwarf.read_u32_le(existing, i)
		if    ul == elf_dwarf.ELF32.dw_dwarf32_terminator then
			-- DWARF64 marker - not supported.
			io.stderr:write("[dwarf_injection] WARN: .debug_aranges contains a DWARF64 marker (0xFFFFFFFF); the 64-bit extension is not supported by this metaprogram; passing through unchanged\n")
			return existing
		end

		local unit_start    = i
		local unit_end_excl = i + 4 + ul
		is_last_unit = (unit_end_excl == #existing)

		if is_last_unit then
			-- The old terminator is replaced by entries + a new terminator, so net section growth (and unit_length growth) is entries only.
			local added_bytes  = #atom_table * elf_dwarf.DWARF4_ARANGES.entry_size
			local new_ul       = ul + added_bytes
			local new_ul_bytes = elf_dwarf.write_u32_le(new_ul)
			-- Emit everything EXCEPT the last 8 bytes (terminator).
			result[#result + 1] = new_ul_bytes
				.. existing:sub(i + 5, unit_end_excl - elf_dwarf.DWARF4_ARANGES.terminator_size)
			-- Append my atom entries.
			for _, atom in ipairs(atom_table) do
				local a    = atom.addr
				local size = atom.size_bytes
				result[#result + 1] = elf_dwarf.write_u32_le(a) .. elf_dwarf.write_u32_le(size)
			end
			-- Append a new terminator.
			result[#result + 1] = string.rep("\0", elf_dwarf.DWARF4_ARANGES.terminator_size)
		else
			-- Emit this unit unchanged.
			result[#result + 1] = existing:sub(unit_start + 1, unit_end_excl)
		end

		i = unit_end_excl
	end

	if not is_last_unit then
		-- Malformed: walked past the end of the section without finding a unit whose end aligns with #existing.
		-- This means a unit's length field overruns the section, or there is no terminator on the last unit.
		-- For now, return existing unchanged to avoid making it worse; warn so the user can investigate.
		io.stderr:write("[dwarf_injection] WARN: .debug_aranges layout is malformed (no unit's end aligned with section end at " .. #existing .. " bytes); passing through unchanged\n")
		return existing
	end

	return table.concat(result)
end

--- Extend the main CU's DWARF5 range list with one DW_RLE_start_length entry per atom.
--- GDB validates an address against DW_AT_ranges before consulting the CU's line program; 
--- .debug_aranges alone is not sufficient.
---
--- Current section shape (one DWARF32 table):
---   unit_length(4), version=5(2), address_size=4(1), segment_size=0(1),
---   offset_entry_count=0(4), start_length entries..., end_of_list(1).
--- @param existing string
--- @param atom_table table
--- @return string
local function build_dwarf_rnglists_section(existing, atom_table)
	if #existing <= elf_dwarf.DWARF5_RNGLISTS.first_entry_offset or #atom_table == 0 then return existing end

	local unit_length        = elf_dwarf.read_u32_le(existing, elf_dwarf.DWARF5_RNGLISTS.unit_length_offset)
	local version            = elf_dwarf.read_u16_le(existing, elf_dwarf.DWARF5_RNGLISTS.version_offset)
	local address_size       = existing:byte(elf_dwarf.DWARF5_RNGLISTS.addr_size_offset + 1)
	local segment_size       = existing:byte(elf_dwarf.DWARF5_RNGLISTS.seg_size_offset + 1)
	local offset_entry_count = elf_dwarf.read_u32_le(existing, elf_dwarf.DWARF5_RNGLISTS.offset_count_offset)

	if unit_length + 4 ~= #existing
		or version                  ~= elf_dwarf.DWARF5_RNGLISTS.version_expected
		or address_size             ~= elf_dwarf.DWARF5_RNGLISTS.addr_size_expected
		or segment_size             ~= elf_dwarf.DWARF5_RNGLISTS.seg_size_expected
		or offset_entry_count       ~= elf_dwarf.DWARF5_RNGLISTS.offset_count_expected
		or existing:byte(#existing) ~= DW_RLE_end_of_list then
		return existing
	end

	local entries = {}
	for _, atom in ipairs(atom_table) do
		entries[#entries + 1] = string.char(DW_RLE_start_length)
			.. elf_dwarf.write_u32_le(atom.addr)
			.. uleb128(atom.size_bytes)
	end
	local appended         = table.concat(entries)
	local new_length       = unit_length + #appended
	local new_length_bytes = elf_dwarf.write_u32_le(new_length)

	return new_length_bytes
		.. existing:sub(5, #existing - 1)
		.. appended
		.. string.char(DW_RLE_end_of_list)
end

-- ════════════════════════════════════════════════════════════════════════════
-- Helpers: per-atom .debug_info synthesis (DW_TAG_subprogram + DW_TAG_variable)
-- ════════════════════════════════════════════════════════════════════════════

--- Build the location bytes (DW_FORM_exprloc) for a register-resident value.
--- DW_OP_reg0..reg31 occupy opcodes 0x50..0x6f. DW_OP_reg15 is 0x5f;
--- 0x90 is DW_OP_regx, not the base of the compact register opcode range.
--- Build the piece-chain location bytes (DW_FORM_exprloc) for an rbind atom's bind_args.
---
--- The location expression is a sequence of (DW_OP_regN, DW_OP_piece, ULEB128(size)) tuples, one per field.
--- GDB composites the pieces into a struct-shaped value matching the Binds_X layout.
---
--- Order matters: the i-th piece corresponds to the i-th byte range in the composite.
--- For Binds_CubeTri (4 fields × 4 bytes), the chain is:
---   reg15 piece(4)    -- R_PrimCursor → PrimCursor @ offset 0
---   reg12 piece(4)    -- R_FaceCursor → FaceCursor @ offset 4
---   reg13 piece(4)    -- R_VertBase   → VertBase   @ offset 8
---   reg14 piece(4)    -- R_OtBase     → OtBase     @ offset 12
---
--- Each piece's size = byte offset of next field - byte offset of this field (or struct.byte_size for the last piece).
--- Since all fields are U4/pointer (4 bytes each) in the current source, each piece is 4 bytes.
--- @param rbind table  -- {regs = {{reg, field}, ...}, fields = {{name, offset}, ...}, bytes = N}
--- @return string  -- the exprloc byte sequence (length-prefixed)
local function piece_chain_exprloc(rbind)
	local op_bytes             = {}
	local field_offset_by_name = {}
	for _, f in ipairs(rbind.fields) do
		field_offset_by_name[f.name] = f.offset
	end
	local next_offset = rbind.bytes
	for i = #rbind.regs, 1, -1 do  -- walk backwards to know each piece's size
		local pair = rbind.regs[i]
		local off  = field_offset_by_name[pair.field] or 0
		local size
		if i == #rbind.regs then
			size = next_offset - off
		else
			local next_off = field_offset_by_name[rbind.regs[i + 1].field]
			if not next_off then
				-- Defensive: a load_word references a field not in the Binds_X struct.
				-- Use struct.bytes as a fallback so the piece chain is still well-formed.
				next_off = rbind.bytes
			end
			size = next_off - off
		end
		-- DW_OP_regN, DW_OP_piece, ULEB128(size)
		op_bytes[#op_bytes + 1] = string.char(DW_OP_reg0 + pair.reg, DW_OP_piece) .. uleb128(size)
		next_offset = off
	end
	-- We built it back-to-front; reverse it.
	local rev = {}
	for i = #op_bytes, 1, -1 do rev[#rev + 1] = op_bytes[i] end
	local op = table.concat(rev)
	return uleb128(#op) .. op
end

-- ════════════════════════════════════════════════════════════════════════════
-- ULEB/SLEB decoders + .debug_abbrev walker + main-CU locator
-- ════════════════════════════════════════════════════════════════════════════
--
-- Per-atom DWARF DIE synthesis from a DETACHED synthetic CU (which GDB ignored at PC lookup) into the MAIN CU as inserted children.
-- That requires us to:
--   1. Locate the main CU in .debug_info (walk DWARF32 unit lengths).
--   2. Locate the main CU's abbrev table in .debug_abbrev (from the CU header).
--   3. Duplicate that table to a new offset + append codes 100..106.
--   4. Patch the main CU's debug_abbrev_offset to the duplicate.
--   5. Insert our DIEs as children of the main CU (just before its root terminator).
--
-- All binary coordinates in this section are zero-based wire offsets. Direct Lua string APIs add `+ 1` at the boundary.
--
-- Pure-Lua 5.3 LEB decoders (no `bit` library; `2^shift` arithmetic matches elf_dwarf.lua's 
-- "math.floor(/16) instead of bit.rshift for LuaJIT 2.1 compat" comment at line 352).

-- DWARF5 compile-unit header constants.
local DW_VERSION_5       = 5
local DW_UT_compile      = 0x01
local DWARF32_TERMINATOR = 0xFFFFFFFF  -- sentinel for DWARF64 marker
local CU_HEADER_SIZE     = 12            -- 4 + 2 + 1 + 1 + 4

--- Walk .debug_info to find the FINAL compilation unit, validate it as a DWARF5 32-bit compile-unit, and extract its bounds + abbrev-table offset.
--- Returns nil on any layout mismatch. Callers fall back to existing sections.
---
--- Returns (cu_start, cu_end_excl, abbrev_offset), all 0-based:
---   cu_start       -- byte offset of the unit_length field
---   cu_end_excl    -- byte offset of the first byte AFTER the main CU
---   abbrev_offset  -- the main CU's debug_abbrev_offset field value (0-based)
---
--- Validation:
---   - Section is non-empty.
---   - All units are DWARF32 (unit_length != 0xFFFFFFFF).
---   - No truncated units (each unit's end <= section length).
---   - The section ends exactly on a unit boundary.
---   - At least 2 units present (crt CU + main CU).
---   - The FINAL unit is DWARF5 32-bit compile-unit (version=5, unit_type=0x01, address_size=4).
---   - The final byte of the main CU is 0x00 (the CU's root children-terminator).
--- @param existing string  -- the .debug_info section bytes
--- @return integer|nil, integer|nil, integer|nil
local function find_main_cu_layout(existing)
	local buf_len = #existing
	if    buf_len < CU_HEADER_SIZE then return nil end

	local pos               = 0
	local main_cu_start     = nil
	local main_cu_end_excl  = nil
	while pos + 4 <= buf_len do
		local unit_length   = elf_dwarf.read_u32_le(existing, pos)
		if    unit_length  == DWARF32_TERMINATOR then return nil end
		local unit_end_excl = pos + 4 + unit_length
		if unit_end_excl > buf_len then return nil end
		main_cu_start    = pos
		main_cu_end_excl = unit_end_excl
		pos              = unit_end_excl
	end
	if pos ~= buf_len or main_cu_start == nil then return nil end
	if main_cu_start == 0 then return nil end  -- need at least 2 units (crt + main)

	-- Validate the main CU header.
	-- Bytes relative to main_cu_start (0-based):
	--   [0..3]   unit_length
	--   [4..5]   version
	--   [6]      unit_type
	--   [7]      address_size
	--   [8..11]  debug_abbrev_offset
	local hdr          = main_cu_start + 4
	local version      = elf_dwarf.read_u16_le(existing, hdr)
	local unit_type    = existing:byte(hdr + 2 + 1)
	local address_size = existing:byte(hdr + 3 + 1)
	local abbrev_off   = elf_dwarf.read_u32_le(existing, hdr + 4)
	if version ~= DW_VERSION_5 or unit_type ~= DW_UT_compile or address_size ~= 4 then
		return nil
	end

	-- Final byte of the main CU must be the root children-terminator (0).
	local final_pos = main_cu_end_excl - 1
	if final_pos >= buf_len or existing:byte(final_pos + 1) ~= 0 then return nil end

	return main_cu_start, main_cu_end_excl, abbrev_off
end

--- Build the new abbreviation declarations that go AFTER the existing gcc-generated ones. We use codes 100+ to avoid collision.
---
--- The new abbreviations define a 4-deep tree:
---   Abbrev 100 (DW_TAG_compile_unit, with children):
---     DW_AT_name       (DW_FORM_strp)   -- CU name
---     DW_AT_comp_dir   (DW_FORM_strp)   -- compilation dir
---     DW_AT_language   (DW_FORM_data1)  -- DW_LANG_C99
---   Abbrev 101 (DW_TAG_subprogram, with children):
---     DW_AT_name       (DW_FORM_string) -- atom function name
---     DW_AT_low_pc     (DW_FORM_addr)   -- atom.addr
---     DW_AT_high_pc    (DW_FORM_addr)   -- atom.addr + size
---   Abbrev 102 (DW_TAG_variable, no children):
---     DW_AT_name       (DW_FORM_string) -- "R_PrimCursor" etc.
---     DW_AT_location   (DW_FORM_exprloc) -- DW_OP_regN
---   Abbrev 103 (DW_TAG_structure_type, with children):   
---     DW_AT_name       (DW_FORM_string) -- "Binds_CubeTri" etc.
---     DW_AT_byte_size  (DW_FORM_udata)  -- struct byte size
---   Abbrev 104 (DW_TAG_member, no children):              
---     DW_AT_name                  (DW_FORM_string) -- "PrimCursor" etc.
---     DW_AT_data_member_location  (DW_FORM_udata)  -- byte offset in struct
---     DW_AT_type                  (DW_FORM_ref4)   -- → U4 base type
---   Abbrev 105 (DW_TAG_variable, no children):            
---     DW_AT_name       (DW_FORM_string) -- "bind_args"
---     DW_AT_location   (DW_FORM_exprloc) -- DW_OP_regN, piece, regN, piece, ...
---     DW_AT_type       (DW_FORM_ref4)   -- → DW_TAG_structure_type DIE
---   Abbrev 106 (DW_TAG_base_type, no children):           
---     DW_AT_name       (DW_FORM_string) -- "unsigned int"
---     DW_AT_byte_size  (DW_FORM_data1)  -- 4
---     DW_AT_encoding   (DW_FORM_data1)  -- DW_ATE_unsigned
---   Abbrev 107 (DW_TAG_subprogram, NO children) — abstract origin.
---     DW_AT_name       (DW_FORM_string) -- "mac_yield" etc. (component ident)
---     DW_AT_inline     (DW_FORM_data1)  -- DW_INL_declared_inlined (= 3)
---     DW_AT_external   (DW_FORM_data1)  -- 1 (visible across the CU)
---   Abbrev 108 (DW_TAG_inlined_subroutine, with children):
---     DW_AT_abstract_origin (DW_FORM_ref4)    -- → ABBREV_ABSTRACT_SUBPROGRAM
---     DW_AT_low_pc          (DW_FORM_addr)    -- invocation start PC
---     DW_AT_high_pc         (DW_FORM_addr)    -- invocation end PC
---     DW_AT_call_file       (DW_FORM_udata)   -- file index of the call site
---     DW_AT_call_line       (DW_FORM_udata)   -- line of the call site
---
--- Returns the 9 abbrev declarations + a trailing `\0` byte (the table terminator per DWARF5 §7.5.3).
--- When APPENDED to the existing .debug_abbrev (which has its own terminator), the result is:
---     [existing declarations] [existing \0] [new declarations] [\0]
--- which is a valid (extended) abbrev table.
--- @return string
local function build_new_abbrev()
	local function attr(name, form) return uleb128(name) .. uleb128(form) end
	local function abbrev(code, tag, has_children, attrs)
		local children = has_children and 0x01 or 0x00  -- DW_CHILDREN_yes / no
		return uleb128(code)
			 .. uleb128(tag)
			 .. string.char(children)
			 .. attrs
			 .. string.char(0x00, 0x00)  -- end of attr list (2 zeros)
	end

	local abbrev_cu = abbrev(ABBREV_CU, DW_TAG_compile_unit, true,  -- DW_CHILDREN_yes
		attr(   DW_AT_name,     DW_FORM_strp)
	  .. attr(DW_AT_comp_dir, DW_FORM_strp)
	  .. attr(DW_AT_language, DW_FORM_data1))

	local abbrev_subprogram = abbrev(ABBREV_SUBPROGRAM, DW_TAG_subprogram, true,  -- DW_CHILDREN_yes
		attr(   DW_AT_name,         DW_FORM_string)
	  .. attr(DW_AT_low_pc,       DW_FORM_addr)
	  .. attr(DW_AT_high_pc,      DW_FORM_addr)
	  .. attr(DW_AT_linkage_name, DW_FORM_string))  -- equals DW_AT_name; lets gdb's symbol-table lookup resolve to our subprogram (not the gcc global `code_<name>` const U4 array)

	local abbrev_variable = abbrev(ABBREV_VARIABLE, DW_TAG_variable, false,  -- DW_CHILDREN_no
		attr(   DW_AT_name,     DW_FORM_string)
	  .. attr(DW_AT_location, DW_FORM_exprloc)
	  .. attr(DW_AT_type,     DW_FORM_ref4)
	  .. attr(DW_AT_external, DW_FORM_data1))   -- DW_AT_external=1: visible at CU scope (gdb's `info locals` + Variables pane shows these for the current frame even if the scope lookup misses)

	-- rbind composite.
	-- DW_FORM_udata (0x0F, ULEB128) is declared at module scope. For small values (struct byte_size, member offsets) 1 byte is enough;
	-- we emit ULEB128 anyway for spec compliance.
	local abbrev_struct_type = abbrev(ABBREV_STRUCT_TYPE, DW_TAG_structure_type, true,  -- DW_CHILDREN_yes
		attr(   DW_AT_name,      DW_FORM_string)
	  .. attr(DW_AT_byte_size, DW_FORM_udata))

	local abbrev_member = abbrev(ABBREV_MEMBER, DW_TAG_member, false,  -- DW_CHILDREN_no
		attr(   DW_AT_name,                 DW_FORM_string)
	  .. attr(DW_AT_data_member_location, DW_FORM_udata)
	  .. attr(DW_AT_type,                 DW_FORM_ref4))

	local abbrev_bind_var = abbrev(ABBREV_BIND_VAR, DW_TAG_variable, false,  -- DW_CHILDREN_no
		attr(   DW_AT_name,     DW_FORM_string)
	  .. attr(DW_AT_location, DW_FORM_exprloc)
	  .. attr(DW_AT_type,     DW_FORM_ref4))

	local abbrev_base_type = abbrev(ABBREV_BASE_TYPE, DW_TAG_base_type, false,  -- DW_CHILDREN_no
		attr(   DW_AT_name,      DW_FORM_string)
	  .. attr(DW_AT_byte_size, DW_FORM_data1)
	  .. attr(DW_AT_encoding,  DW_FORM_data1))

	-- Component step-into abstract + inline DIE abbreviations.
	local DW_INL_declared_inlined = 0x03   -- DWARF5 §3.33.3: "this subroutine was declared inline"
	-- Abstract subprograms carry DW_AT_decl_file and DW_AT_decl_line for definition-site resolution.
	-- even when no inlined_subroutine instance currently maps to it.
	-- DW_FORM_udata is consistent with the call_file/call_line forms on abbrev 108.
	local abbrev_abstract_subprogram = abbrev(ABBREV_ABSTRACT_SUBPROGRAM, DW_TAG_subprogram, false,  -- DW_CHILDREN_no
		attr(   DW_AT_name,       DW_FORM_string)
	  .. attr(DW_AT_inline,      DW_FORM_data1)
	  .. attr(DW_AT_external,    DW_FORM_data1)
	  .. attr(DW_AT_decl_file,   DW_FORM_udata)
	  .. attr(DW_AT_decl_line,   DW_FORM_udata))

	local abbrev_inlined_subroutine = abbrev(ABBREV_INLINED_SUBROUTINE, DW_TAG_inlined_subroutine, false,  -- DW_CHILDREN_no (emits no per-inlined-instance children; the PC range IS the inlining scope)
		attr(   DW_AT_abstract_origin, DW_FORM_ref4)
	  .. attr(DW_AT_low_pc,           DW_FORM_addr)
	  .. attr(DW_AT_high_pc,          DW_FORM_addr)
	  .. attr(DW_AT_call_file,        DW_FORM_udata)
	  .. attr(DW_AT_call_line,        DW_FORM_udata))

	-- bind_args with DW_FORM_sec_offset → .debug_loclists.
	-- The .debug_loclists section holds a sequence of DW_LLE entries;
	-- the first matching entry for a PC describes each field's value (tape memory DW_OP_breg24 or register DW_OP_regN).
	local abbrev_bind_var_loclists = abbrev(ABBREV_BIND_VAR_LOCLIST, DW_TAG_variable, false,  -- DW_CHILDREN_no
		attr(   DW_AT_name,     DW_FORM_string)
	  .. attr(DW_AT_location, DW_FORM_sec_offset)
	  .. attr(DW_AT_type,     DW_FORM_ref4))

	-- Typed-view pointer_type: DW_TAG_pointer_type, DW_AT_type = ref4 (no DW_AT_byte_size; the
	-- chain target carries the byte size via the base_type or struct_type we point at).
	-- MUST be in the appended table — see ABBREV_TYPED_VIEW_POINTER above.
	local abbrev_typed_view_pointer = abbrev(ABBREV_TYPED_VIEW_POINTER, DW_TAG_pointer_type, false,  -- DW_CHILDREN_no
		attr(DW_AT_type, DW_FORM_ref4))

	return abbrev_cu .. abbrev_subprogram .. abbrev_variable
		.. abbrev_struct_type .. abbrev_member .. abbrev_bind_var .. abbrev_base_type
		.. abbrev_abstract_subprogram .. abbrev_inlined_subroutine
		.. abbrev_bind_var_loclists
		.. abbrev_typed_view_pointer
		.. string.char(0x00)  -- abbrev table terminator (DWARF5 §7.5.3)
end


--- Strip a leading "R_" prefix from an enum alias name.
--- The .debug_str/.debug_info consumers display the local without the C-enum prefix (RR_PrimCursor, not RR_R_PrimCursor)
--- because the C-level identifier `R_PrimCursor` would collide with the enum constant value 15 when the user runs `print R_PrimCursor` in gdb.
--- @param r_name string  -- e.g. "R_PrimCursor"
--- @return string        -- "PrimCursor" (or the input unchanged if it does not start with "R_")
local function strip_r_prefix(r_name)
	if #r_name >= 2 and r_name:byte(1) == 0x52 and r_name:byte(2) == 0x5F then  -- "R_"
		return r_name:sub(3)
	end
	return r_name
end

--- Build the new strings to append to .debug_str. Each string is null-terminated.
-- The CU name + comp_dir + one entry per RR_<name> debug-visible alias all go into one new blob.
-- Register names are sourced from the merged registry filtered to MIPS GPR 0..31
-- (the same filter that build_inserted_children applies for the RR_<name> locals, so .debug_str entries stay in sync with .debug_info).
-- @param atom_table  table[]  -- list of {name, addr, size_bytes, ...}
-- @param registries  table    -- merged registries from collect_per_source_registries
-- @return string, table       -- (new_strings_blob, map_of_name_to_offset_in_new_blob)
local function build_new_strings(atom_table, registries)
	registries = registries or {}
	-- The CU name + comp_dir are the first two strings (offsets 0 and N1).
	-- Then each unique atom name + each register name follows.
	local strings = {}
	local map = {}

	-- CU name at offset 0 in the new blob
	strings[#strings + 1] = DEFAULT_CU_NAME .. "\0"
	map["__cu_name__"]    = 0
	local cu_name_len = #strings[#strings]

	-- comp_dir at offset cu_name_len
	strings[#strings + 1] = DEFAULT_CU_COMP_DIR .. "\0"
	map["__comp_dir__"]   = cu_name_len
	local comp_dir_len = #strings[#strings]

	-- Atom names (one per unique atom)
	for _, atom in ipairs(atom_table) do
		local name = atom.name
		if not map[name] then
			map[name]             = #table.concat(strings)
			strings[#strings + 1] = name .. "\0"
		end
	end

	-- Register names (one per unique debug-visible R_Name alias from the merged registry,
	-- filtered to MIPS GPR 0..31 — the same filter that build_inserted_children applies
	-- for the RR_<name> locals, so .debug_str entries stay in sync with .debug_info).
	-- Lua's pairs() is non-deterministic; sort the alias names first so the emitted$ .debug_str bytes are byte-identical across runs.
	local sorted_alias_names = {}
	for r_name, alias in pairs(registries.register_alias_registry or {}) do
		if alias.code and alias.code >= 0 and alias.code <= 31 then
			sorted_alias_names[#sorted_alias_names + 1] = r_name
		end
	end
	table.sort(sorted_alias_names)
	for _, r_name in ipairs(sorted_alias_names) do
		local rr_name = "RR_" .. strip_r_prefix(r_name)
		if not map[rr_name] then
			map[rr_name]         = #table.concat(strings)
			strings[#strings + 1] = rr_name .. "\0"
		end
	end

	return table.concat(strings), map
end

--- Build the DWARF DIE bytes to insert into the MAIN CU as children, immediately
--- before the main CU's root children-terminator (the final 0 byte of the CU).
---
--- Insert the DIEs as children of the main compilation unit.
--- This keeps `RR_PrimCursor` and `bind_args` in scope for atom PCs.
--- Inserting the DIEs as children of the main CU puts them in scope for every PC the main CU owns; 
--- including every atom PC (since `.debug_aranges` + `.debug_rnglists` already assign atom PCs to it).
---
--- Layout (matches the pre-build_new_cu exactly; only the insertion point and ref4 basis change):
---   1) DW_TAG_base_type "unsigned int" (abbrev 106)
---        DW_AT_name = "unsigned int" (DW_FORM_string)
---        DW_AT_byte_size = 4 (DW_FORM_data1)
---        DW_AT_encoding   = DW_ATE_unsigned (DW_FORM_data1)
---   2) Per Binds_X: DW_TAG_structure_type (abbrev 103, children=yes)
---        DW_AT_name      = "Binds_CubeTri" etc. (DW_FORM_string)
---        DW_AT_byte_size = struct bytes (DW_FORM_udata)
---        (children: one DW_TAG_member per field)
---   3) Per field: DW_TAG_member (abbrev 104)
---        DW_AT_name                  = "PrimCursor" etc.
---        DW_AT_data_member_location  = byte offset (DW_FORM_udata)
---        DW_AT_type                  = ref4 → base_type DIE
---   4) Per atom: DW_TAG_subprogram (abbrev 101, children=yes)
---        DW_AT_name         = atom.name (DW_FORM_string)
---        DW_AT_low_pc       = atom.addr
---        DW_AT_high_pc      = atom.addr + size_bytes
---        DW_AT_linkage_name = atom.name (DW_FORM_string; same as DW_AT_name)
---        (children: 6 wave-context vars + 1 bind_args var if rbind)
---   5) Per wave-context reg: DW_TAG_variable (abbrev 102)
---        DW_AT_name      = "RR_<reg>" (DW_FORM_string)
---        DW_AT_location  = DW_OP_regN  (DW_FORM_exprloc)
---        DW_AT_type      = ref4 → base_type DIE
---        DW_AT_external  = 1
---   6) For rbind atoms: DW_TAG_variable "bind_args" (abbrev 105)
---        DW_AT_name      = "bind_args"
---        DW_AT_location  = piece-chain (DW_FORM_exprloc)
---        DW_AT_type      = ref4 → structure_type DIE
---
--- **DOES NOT** emit the final 0 byte (root terminator).
--- build_debug_info_section splices bytes ahead of the root terminator and preserves existing DIE bytes exactly.
---
--- **ref4 basis**: DW_FORM_ref4 is CU-relative (offset from the first byte of the CU header).
--- Our inserted DIEs live in the main CU, so every ref4 = (target section offset) - main_cu_offset.
--- Per-die section offsets are tracked via the running `next_offset` cursor (= section offset of the NEXT byte to emit).
---
--- @param main_cu_offset integer    -- 0-based section offset of the main CU's unit_length field
--- @param main_cu_end_excl integer  -- 0-based section offset of the first byte AFTER the main CU
--- @param atom_table table[]        -- atoms (with atom.rbind set if rbind; atom.invocations set if mac_X(...) calls)
--- @param rbind_structs table       -- {[binds_name] = {bytes, fields, atom_names}}
--- @param loclists_offsets table    -- {[atom_name] = section-relative offset into the new .debug_loclists}
--- @param registries table          -- merged registries from collect_per_source_registries
--- @return string  -- bytes to splice into the main CU just before its root terminator
local function build_inserted_children(main_cu_offset, main_cu_end_excl, atom_table, rbind_structs, loclists_offsets, registries)
	rbind_structs    = rbind_structs    or {}
	loclists_offsets = loclists_offsets or {}
	registries       = registries       or {}

	-- by_alias: the merged register_alias_registry filtered to aliases whose `code` is a valid MIPS GPR 0..31.
	-- Aliases absent from the merged registry are not debug-visible and are skipped entirely (no fallback GPR).
	-- by_alias_order: sorted list of by_alias keys, for deterministic iteration order.
	-- (Lua's pairs() order is implementation-defined and may vary between runs;
	-- without sorting, the per-atom variable emission order would be non-deterministic
	-- and the .debug_info bytes would differ across builds.)
	local by_alias = {}
	for r_name, alias in pairs(registries.register_alias_registry or {}) do
		if alias.code and alias.code >= 0 and alias.code <= 31 then
			by_alias[r_name] = alias
		end
	end
	local by_alias_order = {}
	for r_name in pairs(by_alias) do by_alias_order[#by_alias_order + 1] = r_name end
	table.sort(by_alias_order)

	-- Build a name->atom lookup for fast rbind_atom resolution during the per-atom phase/ctx propagation.
	-- Cheap (O(atom_table)) and built once.
	local function build_atom_name_index(atoms)
		local m = {}
		for _, a in ipairs(atoms or {}) do
			if a and a.name then m[a.name] = a end
		end
		return m
	end
	local atom_by_name_global = build_atom_name_index(atom_table)

	-- We insert IMMEDIATELY BEFORE the main CU's root children-terminator (the last byte of the main CU).
	-- The first emitted byte lives at section offset (main_cu_end_excl - 1).
	local insertion_start = main_cu_end_excl - 1

	-- Closure state: bytes + next_offset + the typed-view/structure/abstract offset caches.
	-- All step-emitters mutate this state in place.
	local S = {
		bytes                     = {},
		next_offset               = insertion_start,  -- 0-based section offset of the NEXT byte to emit
		type_chain_offsets        = {},  -- {[type_name.."|"..depth] = section_offset for the outermost pointer_type}
		struct_section_offsets    = {},  -- {[binds_name] = section_offset for the structure_type}
		abstract_offsets          = {},  -- {[comp_name] = section_offset for the abstract subprogram}
		member_base_type_offsets  = {},  -- {[tn.."|"..byte_size.."|"..encoding] = section_offset}
		base_type_section_offset  = nil, -- set by emit_unsigned_int_base_type
	}
	
	local function emit(s)
		S.bytes[#S.bytes + 1] = s
		S.next_offset       = S.next_offset + #s
	end
	local function ref4_of(section_offset)
		return section_offset - main_cu_offset
	end


	-- 1) Emit the base_type DIE first (member ref4s reference it).
	local base_type_section_offset = S.next_offset
	emit(uleb128(ABBREV_BASE_TYPE))
	emit("unsigned int\0")                   -- DW_FORM_string (DW_AT_name)
	emit(string.char(4))                     -- DW_FORM_data1  (DW_AT_byte_size)
	emit(string.char(DW_ATE_unsigned))       -- DW_FORM_data1  (DW_AT_encoding)
	-- (The function body below reads S.next_offset directly via the `next_offset` function;
	-- this keeps offsets synchronized with emitted data.)
	local function next_offset() return S.next_offset end

	-- Typed local views.
	-- For each unique (type_name, pointer_depth) pair across all rbind atom fields, emit a synthetic type chain.
	-- The chain is: ... → pointer_type → typedef → base_type.
	-- The outermost pointer_type (depth = N) is the variable's DW_AT_type.
	-- For a field declared "V4_S2*" (depth=1), the chain is:
	--   V4_S2 (typedef, references base_type 4-byte unsigned) + ptr_to_V4_S2_1 (pointer_type, byte_size 4, refs the typedef)
	-- gdb walks: variable type = ptr_to_V4_S2_1 → V4_S2 → base_type, and displays "V4_S2 *" (the typedef's name + the pointer depth).
	local type_offsets = {}  -- {[type_name] = section_offset for the typedef DIE}
	-- Always include the base_type "unsigned int" as the U4 target.
	type_offsets["U4"] = base_type_section_offset
	-- Collect every unique (type_name, max_pointer_depth) used by any rbind field.
	local used_typed_views = {}  -- { [type_name] = max_depth }
	for _, atom in ipairs(atom_table) do
		if atom.rbind and atom.rbind.fields then
			for _, f in ipairs(atom.rbind.fields) do
				if f.type_name and f.pointer_depth and f.pointer_depth > 0 then
					local depth = used_typed_views[f.type_name] or 0
					if f.pointer_depth > depth then
						used_typed_views[f.type_name] = f.pointer_depth
					end
				end
			end
		end
	end
	-- Sort for deterministic emission.
	local sorted_typed_types = {}
	for tn in pairs(used_typed_views) do sorted_typed_types[#sorted_typed_types + 1] = tn end
	table.sort(sorted_typed_types)
	-- For each non-U4 type, emit a typedef (DW_TAG_typedef) named after the type and referencing the base_type "unsigned int" (4 bytes).
	-- The typedef gives gdb a named anchor; the pointer_type chain wraps it.
	-- We use a fresh abbrev for the typedef + the pointer_type. 
	-- To stay within the existing abbrev budget, we reuse the duplicated main table's abbrev 4 (DW_TAG_typedef) and abbrev 9 (DW_TAG_pointer_type)
	-- via a synthetic-emit pattern: emit the abbrev code (a ULEB) + attribute bytes using DW_FORM values that match those abbrevs.
	-- The cleanest path is to define new abbrevs in build_new_abbrev(). 
	-- We emit fresh DW_TAG_base_type DIEs (the simplest correct shape: byte_size 4, encoding unsigned) 
	-- and the variable's DW_AT_type references the pointer chain's outermost base_type.
	-- The displayed type name is the type_name (e.g. "V4_S2") because we use DW_FORM_string on the field type. 
	-- gdb walks the chain and displays the name.
	--
	-- For each (type_name, depth), emit a real structure_type with proper member layout,
	-- then a single DW_TAG_pointer_type pointing at the structure_type. gdb's
	-- `print *<var>` then expands the struct and lists its members (x, y, z, w for V4_S2; etc.).
	--
	-- Hardcoded member-info table for the 6 typed views the prototype uses (V2_S2 / V3_S2 / V4_S2 / V2_S4 / V3_S4 / V4_S4).
	-- Each row is {byte_size, members}, where each member is {name, offset, byte_size, type_name}.
	-- `type_name` is the base type name from `type_name_registry`; "S2" / "S4" need a signed base_type emit too.
	--
	-- The table is small + explicit (no introspection of the struct types from production source)
	-- because the prototype principle treats the typed-view struct layout as data, not derived state.
	local STRUCT_MEMBER_TABLE = {
		-- 2-element signed short vector (rare; placeholder for future use).
		V2_S2 = { byte_size = 4, members = {
			{ name = "x", offset = 0, byte_size = 2 },
			{ name = "y", offset = 2, byte_size = 2 },
		}},
		-- 4-element signed short vector (the dominant face-cursor type).
		V4_S2 = { byte_size = 8, members = {
			{ name = "x", offset = 0, byte_size = 2 },
			{ name = "y", offset = 2, byte_size = 2 },
			{ name = "z", offset = 4, byte_size = 2 },
			{ name = "w", offset = 6, byte_size = 2 },
		}},
		-- 3-element signed short vector (the floor face-cursor type; includes explicit pad byte to match math.h's S2 pad member).
		V3_S2 = { byte_size = 8, members = {
			{ name = "x",   offset = 0, byte_size = 2 },
			{ name = "y",   offset = 2, byte_size = 2 },
			{ name = "z",   offset = 4, byte_size = 2 },
			{ name = "pad", offset = 6, byte_size = 2 },
		}},
		-- 2-element signed int vector.
		V2_S4 = { byte_size = 8, members = {
			{ name = "x", offset = 0, byte_size = 4 },
			{ name = "y", offset = 4, byte_size = 4 },
		}},
		-- 3-element signed int vector.
		V3_S4 = { byte_size = 16, members = {
			{ name = "x",   offset = 0,  byte_size = 4 },
			{ name = "y",   offset = 4,  byte_size = 4 },
			{ name = "z",   offset = 8,  byte_size = 4 },
			{ name = "pad", offset = 12, byte_size = 4 },
		}},
		-- 4-element signed int vector.
		V4_S4 = { byte_size = 16, members = {
			{ name = "x", offset = 0,  byte_size = 4 },
			{ name = "y", offset = 4,  byte_size = 4 },
			{ name = "z", offset = 8,  byte_size = 4 },
			{ name = "w", offset = 12, byte_size = 4 },
		}},
	}
	local S2_TYPE_BYTE_SIZE = 2  -- S2 = signed 16-bit (see dsl.h)
	local S4_TYPE_BYTE_SIZE = 4  -- S4 = signed 32-bit (see dsl.h)

	-- Pre-emit the signed base types (S2, S4) once if any typed view's member needs them.
	-- We emit per-typed-view lazily below; build a member-base-type offset cache (idempotent).
	local member_base_type_offsets = {}
	local function ensure_member_base_type(tn, byte_size, encoding)
		local key = tn .. "|" .. byte_size .. "|" .. encoding
		if member_base_type_offsets[key] then return member_base_type_offsets[key] end
		local off = next_offset()
		emit(uleb128(ABBREV_BASE_TYPE))
		emit(tn .. "\0")
		emit(string.char(byte_size))
		emit(string.char(encoding))
		member_base_type_offsets[key] = off
		return off
	end
	-- Always emit S2 + S4 (the v*_S2 / v*_S4 family base types) once before any typed-view,
	-- even if no atom currently declares a v*_S2 field, so future atoms pick them up without rewiring.
	ensure_member_base_type("S2", S2_TYPE_BYTE_SIZE, 5)  -- DW_ATE_signed = 5
	ensure_member_base_type("S4", S4_TYPE_BYTE_SIZE, 5)

	local type_chain_offsets = {}
	for _, tn in ipairs(sorted_typed_types) do
		if tn ~= "U4" then
			local depth = used_typed_views[tn]
			local type_info = STRUCT_MEMBER_TABLE[tn]
			if not type_info then
				-- Unknown typed view — fall back to a generic 4-byte unsigned base_type to keep the wire valid
				-- (gdb will render as the typename but `print *ptr` will only see the first 4 bytes).
				local innermost_offset = next_offset()
				emit(uleb128(ABBREV_BASE_TYPE))
				emit(tn .. "\0")
				emit(string.char(U4_BYTE_SIZE))        -- byte_size = 4 (fallback for unknown types)
				emit(string.char(DW_ATE_unsigned))     -- encoding = unsigned
				local outermost_offset = next_offset()
				emit(uleb128(ABBREV_TYPED_VIEW_POINTER))  -- DW_TAG_pointer_type (abbrev 110; NOT 9)
				emit(elf_dwarf.write_u32_le(ref4_of(innermost_offset)))
				type_chain_offsets[tn .. "|" .. depth] = outermost_offset
			else
				-- Emit a proper structure_type DIE for this typed view.
				local struct_offset = next_offset()
				emit(uleb128(ABBREV_STRUCT_TYPE))
				emit(tn .. "\0")                   -- DW_AT_name (struct_type has children, no name in abbrev 103 [DW_FORM_string only])
				emit(uleb128(type_info.byte_size)) -- DW_AT_byte_size (DW_FORM_udata)
				-- For each member, emit ABBREV_MEMBER (name + data_member_location + type ref4).
				for _, m in ipairs(type_info.members) do
					emit(uleb128(ABBREV_MEMBER))
					emit(m.name .. "\0")
					emit(uleb128(m.offset))
					-- The member's type is S2 (for v*_S2 family) or S4 (for v*_S4 family), based on the member's byte_size.
					local member_type_name, member_type_encoding
					if m.byte_size == 2 then
						member_type_name = "S2"
						member_type_encoding = 5  -- DW_ATE_signed = 5
					elseif m.byte_size == 4 then
						member_type_name = "S4"
						member_type_encoding = 5  -- DW_ATE_signed = 5
					else
						-- Unexpected byte_size; fall back to U4 (unsigned int) since U4 base type is already emitted
						member_type_name = "U4"
						member_type_encoding = 7  -- DW_ATE_unsigned = 7
					end
					local member_base_off = ensure_member_base_type(member_type_name, m.byte_size, member_type_encoding)
					emit(elf_dwarf.write_u32_le(ref4_of(member_base_off)))  -- DW_AT_type ref4 → base_type
				end
				emit(string.char(DIE_CHILDREN_TERMINATOR)) -- end of structure_type's children (DWARF5 §7.5.3)
				-- Emit a single DW_TAG_pointer_type (abbrev 110, NOT 9) pointing at the structure_type.
				-- For depth > 1, we'd chain pointer_type → pointer_type → ... → structure_type; not exercised.
				if depth == 1 then
					local outermost_offset = next_offset()
					emit(uleb128(ABBREV_TYPED_VIEW_POINTER))  -- DW_TAG_pointer_type (abbrev 110; NOT 9)
					emit(elf_dwarf.write_u32_le(ref4_of(struct_offset)))  -- DW_AT_type → structure_type
					type_chain_offsets[tn .. "|" .. depth] = outermost_offset
				else
					error("typed-view: pointer_depth > 1 is not yet supported in this emission path")
				end
			end
		end
	end

	-- 1b) Emit the void* fallback chain (used by step (f) of the per-RR_<R_Name> precedence chain).
	-- One DW_TAG_base_type DIE named "void" + one DW_TAG_pointer_type pointing at it.
	-- Unannotated RR_<R_X> locals reference the outermost pointer_type; gdb displays the value as `(void *) 0x...` 
	-- (hex) per the prototype principle rather than `unsigned int`.
	-- The void base_type is emitted BEFORE any other typed chain so its ref4 pointer remains stable.
	-- Follow the SAME pattern as the typed-views chain above: capture the offset BEFORE the uleb tag
	-- (this is the ref4 target), emit the DIE bytes, then emit the pointer_type pointing at the offset.
	local void_chain_offset = next_offset()
	emit(uleb128(ABBREV_BASE_TYPE))
	emit("void\0")                              -- DW_FORM_string (DW_AT_name)
	emit(string.char(1))                        -- DW_FORM_data1  (DW_AT_byte_size = 1; DWARF's "void" base_type)
	emit(string.char(DW_ATE_unsigned))          -- DW_FORM_data1  (DW_AT_encoding = unsigned; DWARF doesn't define a void encoding but gdb reads the name "void" off the DIE and renders it correctly as `(void *)` when wrapped in a pointer_type)
	emit(uleb128(ABBREV_TYPED_VIEW_POINTER))  -- DW_TAG_pointer_type (abbrev 110; NOT 9; void chain target)
	emit(elf_dwarf.write_u32_le(ref4_of(void_chain_offset)))  -- 4-byte ref4: points at the void base_type's tag byte
	-- type_chain_offsets["void|1"] is what step (f) of the per-RR_<R_Name> chain looks up.
	type_chain_offsets["void|1"] = void_chain_offset  -- both the base_type offset and the pointer_type are emitted consecutively; the OUTERMOST is the pointer_type. The variable's DW_AT_type must reference the pointer_type, not the base_type. Patch below.
	-- Capture the pointer_type's offset (the last-thing-emitted DIE start) and overwrite the lookup.
	-- The pointer_type was emitted as: uleb(9) (1 byte) + 4-byte ref4 = 5 bytes. Its tag byte is at void_chain_offset + 8 (the base_type's 8 bytes: 1 tag + 5 name + 1 byte_size + 1 encoding).
	local ptr_void_offset = void_chain_offset + 8
	type_chain_offsets["void|1"] = ptr_void_offset

	-- 1c) Emit the U4 * pointer chain (step (e) fallback for enum-site `atom_type(U4 *)`).
	-- The chain is just one DW_TAG_pointer_type pointing at the pre-emitted "unsigned int" base_type at `base_type_section_offset`.
	-- This is intentionally separate from the per-type typed-views chain (which emits V4_S2* / V3_S2* etc.)
	-- because U4 is the C-side typedef alias for `unsigned int`, not a fresh struct;
	-- reusing the pre-emitted base type keeps the wire consistent.
	-- Once this chain is registered as `type_chain_offsets["U4|1"]`, step (e) of the per-RR_<R_Name> precedence chain will resolve `atom_type(U4 *)`
	-- declarations on aliases like `R_PrimCursor` and `R_OtBase` to `U4 *` (gdb renders as `(unsigned int *)` with the value displayed in hex).
	emit(uleb128(ABBREV_TYPED_VIEW_POINTER))                         -- DW_TAG_pointer_type (abbrev 110; NOT 9; U4 chain target)
	emit(elf_dwarf.write_u32_le(ref4_of(base_type_section_offset)))  -- 4-byte ref4 → "unsigned int" base_type
	local u4_chain_offset = next_offset() - 5                        -- 1 (uleb tag) + 4 (ref4) = 5 bytes; capture the pointer_type's start offset
	type_chain_offsets["U4|1"] = u4_chain_offset

	-- 2) Emit one DW_TAG_structure_type per unique Binds_X.
	local struct_section_offsets = {}
	local sorted_struct_names    = {}
	for k in pairs(rbind_structs) do sorted_struct_names[#sorted_struct_names + 1] = k end
	table.sort(sorted_struct_names)
	for _, binds_name in ipairs(sorted_struct_names) do
		local struct = rbind_structs[binds_name]
		struct_section_offsets[binds_name] = next_offset()

		emit(uleb128(ABBREV_STRUCT_TYPE))
		emit(binds_name .. "\0")    -- DW_FORM_string (DW_AT_name)
		emit(uleb128(struct.bytes)) -- DW_FORM_udata  (DW_AT_byte_size)

		-- Emit DW_TAG_member children (one per field).
		for _, field in ipairs(struct.fields) do
			emit(uleb128(ABBREV_MEMBER))
			emit(field.name .. "\0")    -- DW_FORM_string (DW_AT_name)
			emit(uleb128(field.offset)) -- DW_FORM_udata  (DW_AT_data_member_location)
			-- typed field.
			-- For a pointer-typed field, the member's DW_AT_type points at the deepest pointer_type in its chain.
			-- For U4 (no pointer), it points at the base_type.
			local field_type_offset
			if field.pointer_depth and field.pointer_depth > 0 then
				field_type_offset = type_chain_offsets[field.type_name .. "|" .. field.pointer_depth]
			end
			if not field_type_offset then
				field_type_offset = base_type_section_offset
			end
			emit(elf_dwarf.write_u32_le(ref4_of(field_type_offset)))  -- DW_FORM_ref4 → type
		end

		emit(string.char(DIE_CHILDREN_TERMINATOR))   -- end of structure_type's children (DWARF5 §7.5.3)
	end

	-- 3) Emit one abstract DW_TAG_subprogram per unique mac_X component.
	--    Each abstract DIE is a CU-level child (sibling of the per-atom subprograms below).
	--    The abstract DIE's section offset is later used by inlined_subroutine DIEs (which embed `DW_AT_abstract_origin = ref4 → abstract DIE`).
	--    Each abstract DIE also carries DW_AT_decl_file + DW_AT_decl_line pointing at the component's definition site (file path + body line).
	local component_defs     = collect_component_defs(atom_table)
	local abstract_offsets   = {}  -- name -> section offset
	local sorted_comp_names  = {}
	for name in pairs(component_defs) do sorted_comp_names[#sorted_comp_names + 1] = name end
	table.sort(sorted_comp_names)
	-- DW_INL_inlined (1) = "this subroutine was inlined" — accurate for the mac_* components.
	local DW_INL_inlined = 0x01
	for _, comp_name in ipairs(sorted_comp_names) do
		local def = component_defs[comp_name]
		abstract_offsets[comp_name] = next_offset()
		emit(uleb128(ABBREV_ABSTRACT_SUBPROGRAM))
		emit("mac_" .. comp_name .. "\0") -- DW_FORM_string (DW_AT_name)
		emit(string.char(DW_INL_inlined)) -- DW_FORM_data1 (DW_AT_inline)
		emit(string.char(0x01))           -- DW_FORM_data1 (DW_AT_external=1)
		-- decl_file + decl_line resolve the abstract origin back to its definition site even when no inlined_subroutine instance maps to it.
		emit(uleb128(resolve_provenance_file_index(def.def_file)))  -- DW_FORM_udata (DW_AT_decl_file)
		emit(uleb128(def.def_line))                                 -- DW_FORM_udata (DW_AT_decl_line)
	end

	-- 4) Emit per-atom DW_TAG_subprograms (children of main CU).
	--    Subprogram names match nm symbols without a `code_` prefix.
	--    The gcc global `<name>[]` is a DW_TAG_variable without children; our subprogram has the wave-context var children.
	--    gdb's symbol resolution picks our subprogram (it has low_pc/high_pc + children) over the gcc global for function-context lookups.
	for _, atom in ipairs(atom_table) do
		emit(uleb128(ABBREV_SUBPROGRAM))
		emit(atom.name .. "\0") -- DW_FORM_string (DW_AT_name)
		emit(elf_dwarf.write_u32_le(atom.addr))
		emit(elf_dwarf.write_u32_le(atom.addr + atom.size_bytes))
		emit(atom.name .. "\0") -- DW_FORM_string (DW_AT_linkage_name; same as DW_AT_name for non-mangled C)

	-- Per debug-visible R_ alias (filtered to GPR 0..31 in `by_alias`): DW_TAG_variable.
	-- Precedence chain (per atom, per RR_<R_Name>):
	--   (a) per-atom callsite atom_type(R_X, <T>):  atom_views reg_type_overrides[atom_name][R_Name] — most specific; user explicit override for THIS atom only
	--   (b) atom_ctx(<rbind_atom>):                 propagate THIS atom's declared rbind atom's Binds_* field types
	--   (c) self-binding:                           atom.rbind.fields / regs (only when this atom IS the rbind atom for its Binds_*)
	--   (d) atom_phase(<label>)-grouped:            first atom in source-order that shares this label AND has its own atom.rbind provides the Binds_* field types
	--   (e) enum-site atom_type(<T>) default:       register_alias_registry[R_Name].default_type  (per-alias fallback declared in lottes_tape.h)
	--   (f) void* fallback:                         the void_chain_offset built in section 1b; gdb renders `(void *) 0x...` (hex)
	-- If (a)..(e) miss AND no alias registry entry exists for this R_Name, the emission is skipped for that alias entirely.
		local atom_view_ctx_fields   = nil  -- populated by step (b); map field_name -> field entry
		local reg_to_field_ctx       = nil  -- populated by step (b); map GPR index -> field name
		local atom_view_phase_fields = nil  -- populated by step (d); map field_name -> field entry
		local reg_to_field_phase     = nil  -- populated by step (d); map GPR index -> field name
		-- atom-name -> atom lookup is precomputed once as atom_by_name_global.
		local field_type_by_name = {}
		if atom.rbind and atom.rbind.fields then
			for _, f in ipairs(atom.rbind.fields) do
				if f.type_name then
					field_type_by_name[f.name] = f
				end
			end
		end
		local reg_to_field = {}
		if atom.rbind and atom.rbind.regs then
			for _, pair in ipairs(atom.rbind.regs) do
				reg_to_field[pair.reg] = pair.field
			end
		end
		local atom_view = (registries.atom_views or {})[atom.name]
		-- Build the atom-name lookup table once (cheap; O(atom_table)) so step (b) and step (d) can resolve rbind_atom names.
		local atom_by_name = atom_by_name or (function() local m = {}; for _, a in ipairs(atom_table) do if a.name then m[a.name] = a end end; return m end)()
		-- step (b) inputs: this atom's `atom_ctx(<rbind_atom>)` (resolved from the registries' atom_ctxs)
		local this_ctx = registries.atom_ctxs and registries.atom_ctxs[atom.name]
		if this_ctx and this_ctx.rbind_atom then
			local rbind = atom_by_name_global[this_ctx.rbind_atom]
			if rbind and rbind.rbind and rbind.rbind.fields then
				atom_view_ctx_fields = {}
				for _, f in ipairs(rbind.rbind.fields) do atom_view_ctx_fields[f.name] = f end
				if rbind.rbind.regs then
					reg_to_field_ctx = {}
					for _, pair in ipairs(rbind.rbind.regs) do reg_to_field_ctx[pair.reg] = pair.field end
				end
			end
		end
		-- step (d) inputs: this atom's `atom_phase(<label>)`;
		-- find the FIRST atom in the same phase group that has its own rbind and is in source-order (i.e., declared before this atom in any source file).
		-- Find the per-atom_info entry that has phase == this atom's name.
		local my_phase_label = nil
		for _, ai in ipairs(registries.atom_infos or {}) do
			if ai.atom_name == atom.name and ai.phase then
				my_phase_label = ai.phase
				break
			end
		end
		if my_phase_label then
			local group = (registries.atom_phases or {})[my_phase_label]
			if group and group.atoms then
				for _, group_atom_name in ipairs(group.atoms) do
					if group_atom_name ~= atom.name then
						local cand = atom_by_name_global[group_atom_name]
						if cand and cand.rbind and cand.rbind.fields then
							atom_view_phase_fields = {}
							for _, f in ipairs(cand.rbind.fields) do atom_view_phase_fields[f.name] = f end
							if cand.rbind.regs then
								reg_to_field_phase = {}
								for _, pair in ipairs(cand.rbind.regs) do reg_to_field_phase[pair.reg] = pair.field end
							end
							break
						end
					end
				end
			end
		end

		-- 5-step precedence chain. The dispatch loop runs the first step that yields a non-nil offset.
		-- Each step returns the type's section offset or nil if it missed.
		-- Each precedence rule is one table row and one function.
		-- Per-atom precomputed state is captured in upvalues: atom_view, reg_to_field_ctx, atom_view_ctx_fields,
		-- reg_to_field_phase, atom_view_phase_fields, field_type_by_name, reg_to_field, alias, type_chain_offsets.
		local PRECEDENCE_STEPS = {
			-- (a) per-atom callsite atom_type(R_X, <T>): most specific; user explicit override for THIS atom only.
			function(r_name, alias_code)
				local override = atom_view and atom_view.reg_type_overrides and atom_view.reg_type_overrides[r_name]
				if override and override.pointer_depth and override.pointer_depth > 0 then
					return type_chain_offsets[override.type_name .. "|" .. override.pointer_depth]
				end
			end,
			-- (b) atom_ctx(<rbind_atom>) propagation.
			function(r_name, alias_code)
				local ctx_field_name = reg_to_field_ctx and reg_to_field_ctx[alias_code]
				local ctx_f          = ctx_field_name and atom_view_ctx_fields and atom_view_ctx_fields[ctx_field_name]
				if ctx_f and ctx_f.pointer_depth and ctx_f.pointer_depth > 0 then
					return type_chain_offsets[ctx_f.type_name .. "|" .. ctx_f.pointer_depth]
				end
			end,
			-- (c) self-binding (this atom IS the rbind atom for its Binds_*).
			function(r_name, alias_code)
				local field_name = reg_to_field[alias_code]
				local f         = field_name and field_type_by_name[field_name]
				if f and f.pointer_depth and f.pointer_depth > 0 then
					return type_chain_offsets[f.type_name .. "|" .. f.pointer_depth]
				end
			end,
			-- (d) atom_phase(<label>)-grouped propagation.
			function(r_name, alias_code)
				local phase_field_name = reg_to_field_phase and reg_to_field_phase[alias_code]
				local phase_f          = phase_field_name and atom_view_phase_fields and atom_view_phase_fields[phase_field_name]
				if phase_f and phase_f.pointer_depth and phase_f.pointer_depth > 0 then
					return type_chain_offsets[phase_f.type_name .. "|" .. phase_f.pointer_depth]
				end
			end,
			-- (e) enum-site atom_type(<T>) default on the registry entry.
			function(r_name, alias_code)
				if alias and alias.default_type and alias.default_depth and alias.default_depth > 0 then
					return type_chain_offsets[alias.default_type .. "|" .. alias.default_depth]
				end
			end,
		}

		-- Iterate `by_alias` in sorted order (Lua's pairs() is non-deterministic;
		-- sorting ensures byte-identical DWARF output across builds).
		for _, r_name in ipairs(by_alias_order) do
			local alias = by_alias[r_name]
			local rr_name = "RR_" .. strip_r_prefix(r_name)
			local alias_code = alias.code
			emit(uleb128(ABBREV_VARIABLE))
			emit(rr_name .. "\0") -- DW_FORM_string (DW_AT_name)
			-- DW_FORM_exprloc: ULEB byte count + DW_OP_regN byte.
			-- DW_OP_reg0..reg31 occupy opcodes 0x50..0x6f; DW_OP_reg15 is 0x5f.
					-- DW_FORM_exprloc: ULEB byte count + DW_OP_regN byte.
				-- The `1` is the length prefix — DW_OP_regN occupies exactly 1 byte (the base opcode is 0x50; regN = 0x50 + N).
			-- `alias_code` is the MIPS GPR index (0..31) from the merged register_alias_registry.
			emit(uleb128(1) .. string.char(DW_OP_reg0 + alias_code)) -- DW_FORM_exprloc (DW_OP_regN from registry code)
			-- Precedence chain (a..e); step (f) is the void* fallback (initial value).
			local type_offset = type_chain_offsets["void|1"]
			for _, step in ipairs(PRECEDENCE_STEPS) do
				local candidate = step(r_name, alias_code)
				if candidate then type_offset = candidate; break end
			end
			emit(elf_dwarf.write_u32_le(ref4_of(type_offset)))  -- DW_FORM_ref4 → type
			emit(string.char(0x01))              -- DW_AT_external=1 (visible at CU scope)
		end

		-- If rbind, emit bind_args variable with PC-ranged location list.
		-- The loclist is in .debug_loclists, indexed by `DW_FORM_sec_offset` (4-byte section-relative offset).
		-- The location list uses two PC ranges: [atom.addr, last_load+8) describes every field as tape memory
		-- (DW_OP_bregN + offset) piece, and [last_load+8, atom.end) where every field is described as a GPR (DW_OP_regN) piece.
		if atom.rbind then
			local binds_name = atom.rbind.binds
			local loclists_offset = loclists_offsets[atom.name] or 0
			emit(uleb128(ABBREV_BIND_VAR_LOCLIST))
			emit("bind_args\0")                  -- DW_FORM_string (DW_AT_name)
			emit(elf_dwarf.write_u32_le(loclists_offset))         -- DW_FORM_sec_offset → .debug_loclists
			emit(elf_dwarf.write_u32_le(ref4_of(struct_section_offsets[binds_name])))  -- DW_FORM_ref4 → struct_type
		end

		-- Per-component invocation inlined_subroutine instances.
		-- Each invocation covers a contiguous .word range [start_pos, end_pos] within the atom.
		-- We compute the corresponding PC range from the atom's start + .word offsets × MIPS_BYTES_PER_WORD.
		-- Resolve `inv.call_file` to the line-unit file index;
		-- this preserves call-site attribution across source files.
		if atom.invocations and not atom.skip_over then
			for _, inv in ipairs(atom.invocations) do
				local inv_low  = atom.addr + inv.start_pos * MIPS_BYTES_PER_WORD
				local inv_high = atom.addr + (inv.end_pos + 1) * MIPS_BYTES_PER_WORD
				emit(uleb128(ABBREV_INLINED_SUBROUTINE))
				emit(elf_dwarf.write_u32_le(ref4_of(abstract_offsets[inv.comp_name])))  -- DW_FORM_ref4 → abstract_origin
				emit(elf_dwarf.write_u32_le(inv_low))    -- DW_FORM_addr (DW_AT_low_pc)
				emit(elf_dwarf.write_u32_le(inv_high))   -- DW_FORM_addr (DW_AT_high_pc)
				emit(uleb128(resolve_provenance_file_index(inv.call_file)))            -- DW_FORM_udata (DW_AT_call_file)
				emit(uleb128(inv.call_line))                                           -- DW_FORM_udata (DW_AT_call_line)
			end
		end

		emit(string.char(DIE_CHILDREN_TERMINATOR))   -- end of subprogram's children (DWARF5 §7.5.3)
	end

	-- Do not emit a final 0 here; build_debug_info_section preserves the root terminator byte.
	return table.concat(S.bytes)
end

--- Build the new .debug_abbrev: existing + duplicate of the main CU's table + the new declarations 100..106 (with their terminating 0).
---
--- **Why duplicate the main table**: a CU can name only one abbrev table via its `debug_abbrev_offset` field.
--- The main CU currently points at the gcc-generated table (codes 1..60+);
--- codes 100..106 are NEW, so they live in a different table. 
--- To keep all main-CU abbreviation codes in one table we DUPLICATE 
--- the gcc-generated codes at a new offset and append our new declarations 100..106 immediately after (with a single shared terminator 0).
---
--- Result layout (0-based section offsets):
---   [0 .. #existing-1]               existing .debug_abbrev (unchanged)
---   [#existing .. +#main_dup-1]      duplicate of the main table (codes 1..60+, NO terminator)
---   [+#main_dup .. +#new_abbrevs-1]  codes 100..106 + final 0
---
--- The MAIN CU's debug_abbrev_offset is patched to `#existing` (start of the duplicate table).
--- Codes 100..106 live inside the same table immediately after the duplicated gcc codes, so a single abbrev-table pointer is enough.
---
--- Fails safely by returning existing sections unchanged if the table walker can't find the table terminator (malformed input).
---
--- @param existing string  -- existing .debug_abbrev bytes, byte-for-byte
--- @param main_abbrev_offset integer  -- 0-based offset into `existing` of the main CU's abbrev table
--- @return string, integer  -- (new_abbrev_bytes, offset_where_duplicate_table_starts = #existing)
local function build_debug_abbrev_section(existing, main_abbrev_offset)
	local  table_end = find_abbrev_table_end(existing, main_abbrev_offset)
	if not table_end then return existing, nil end

	-- Duplicate the main table declarations EXCLUDING its terminating 0 byte.
	-- (1-indexed sub: existing:sub(main_abbrev_offset + 1, table_end)
	-- reads bytes from 0-based [main_abbrev_offset .. table_end - 1].)
	local main_table_dup = existing:sub(main_abbrev_offset + 1, table_end)
	local new_abbrevs    = build_new_abbrev()  -- includes its own terminating 0

	-- The MAIN CU's debug_abbrev_offset points to the duplicate's start (= #existing).
	-- Codes 100..106 follow the duplicate's declarations inside that same table.
	return existing .. main_table_dup .. new_abbrevs, #existing
end

--- Build the new .debug_str: existing strings + new strings appended.
--- @param existing string  -- existing .debug_str bytes, byte-for-byte
--- @param atom_table table[]
--- @param registries table  -- merged registries from collect_per_source_registries
--- @return string, integer, table  -- (new_str_bytes, new_strings_offset, string_map)
local function build_debug_str_section(existing, atom_table, registries)
	local new_strings, string_map = build_new_strings(atom_table, registries)
	return existing .. new_strings, #existing, string_map
end

--- Build the new .debug_info: SPLICE inserted DIEs into the MAIN CU as children.
---
--- This function appended a DETACHED synthetic CU to the end of .debug_info.
--- That put every atom DIE in a separate CU from the one GDB selected for PC lookup, so `RR_PrimCursor` + `bind_args` never appeared in scope.
--- This implementation instead:
---   1. Builds the inserted-children bytes (base_type, struct_types, subprograms with their RR_* + bind_args children) via build_inserted_children.
---   2. Patches the main CU's `unit_length` field to account for the inserted bytes.
---   3. Patches the main CU's `debug_abbrev_offset` field to point at the duplicate abbrev table (offset = #existing_abbrev_before_append).
---   4. Preserves all original main CU DIE bytes.
---   5. Replaces the main CU's final byte (the root children-terminator, 0) with: inserted_children_bytes + a single 0 byte (root terminator preserved).
---
--- The crt CU (everything before main_cu_start) is preserved.
--- **No detached synthetic CU is appended.**
--- @param existing string            -- existing .debug_info section bytes
--- @param main_cu_start integer      -- 0-based offset of the main CU's unit_length field
--- @param main_cu_end_excl integer   -- 0-based offset of the first byte AFTER the main CU
--- @param new_abbrev_offset integer  -- 0-based offset into the new .debug_abbrev of the duplicate main table
--- @param atom_table table[]
--- @param rbind_structs table     -- {[binds_name] = {bytes, fields, atom_names}}
--- @param loclists_offsets table  -- {[atom_name] = section-relative offset}
--- @param registries table        -- merged registries from collect_per_source_registries
--- @return string  -- the rebuilt .debug_info bytes
local function build_debug_info_section(existing, main_cu_start, main_cu_end_excl, new_abbrev_offset, atom_table, rbind_structs, loclists_offsets, registries)
	-- 1) Build the inserted children bytes (just before the main CU's root terminator).
	local inserted     = build_inserted_children(main_cu_start, main_cu_end_excl, atom_table, rbind_structs, loclists_offsets, registries)
	local inserted_len = #inserted

	-- 2) Patch main CU's unit_length += inserted_len.
	local old_unit_length       = elf_dwarf.read_u32_le(existing, main_cu_start)
	local new_unit_length       = old_unit_length + inserted_len
	local new_unit_length_bytes = elf_dwarf.write_u32_le(new_unit_length)

	-- 3) Patch main CU's debug_abbrev_offset (bytes [main_cu_start + 8 .. + 11]).
	local new_abbrev_offset_bytes = elf_dwarf.write_u32_le(new_abbrev_offset)

	-- 4) Splice. All offsets below are 0-based; existing:sub is 1-indexed inclusive.
	--    Byte ranges (0-based, inclusive):
	--      [0 .. main_cu_start - 1]                 crt CU, unchanged
	--      [main_cu_start + 0 .. + 3]               unit_length (PATCHED)
	--      [main_cu_start + 4 .. + 7]               version + unit_type + address_size, unchanged
	--      [main_cu_start + 8 .. + 11]              debug_abbrev_offset (PATCHED)
	--      [main_cu_start + 12 .. main_cu_end_excl - 2]   existing DIE bytes, unchanged
	--      [main_cu_end_excl - 1]                   root children-terminator, unchanged 0
	local pre_end         = main_cu_end_excl - 2  -- 0-based end of existing DIE bytes (inclusive)
	local root_terminator = main_cu_end_excl - 1  -- 0-based position of the final 0 byte

	return existing:sub(1, main_cu_start)                    -- crt CU
		.. new_unit_length_bytes                               -- patched unit_length (4 bytes)
		.. existing:sub(main_cu_start + 5, main_cu_start + 8)  -- version(2) + unit_type(1) + address_size(1), unchanged
		.. new_abbrev_offset_bytes                             -- patched debug_abbrev_offset (4 bytes)
		.. existing:sub(main_cu_start + 13, pre_end + 1)       -- existing DIE bytes, unchanged
		.. inserted                                            -- our inserted children
		.. existing:sub(root_terminator + 1, main_cu_end_excl) -- root children-terminator, unchanged 0
end

--- Build the .debug_loc: just a terminator.
--- Atoms don't have stack frames. The .debug_loc section describes per-instruction location adjustments for call-frame-based variables;
--- We use DW_OP_regN which is register-based and doesn't need .debug_loc entries).
--- The section itself must not be empty OR gdb may complain; the DW_LLE_end_of_list marker (per DWARF5 §7.7) is a single byte 0x00.
-- local function build_debug_loc_section() return string.char(0x00) end

local SECTION_BUILDERS = {
	debug_line     = build_dwarf_line_section,
	debug_aranges  = build_dwarf_aranges_section,
	debug_rnglists = build_dwarf_rnglists_section,
	debug_abbrev   = build_debug_abbrev_section,
	debug_info     = build_debug_info_section,
	debug_str      = build_debug_str_section,
	debug_loc      = function() return string.char(DW_LLE_end_of_list) end,
	-- debug_loclists is fed directly in M.run (it needs the merged registries for the R_TapePtr GPR lookup;
	-- the SECTION_BUILDERS table cannot carry that context, so the dispatch is inlined in the per-run writers loop).
}

-- Per-section output path resolver (mirrors SECTION_BUILDERS).
-- Returns the on-disk path for the section's `.bin` blob.
local SECTION_WRITERS = {
	debug_line     = function(out_root, basename) return out_root .. "\\" .. basename .. ".dwarf_line.bin"     end,
	debug_aranges  = function(out_root, basename) return out_root .. "\\" .. basename .. ".dwarf_aranges.bin"  end,
	debug_rnglists = function(out_root, basename) return out_root .. "\\" .. basename .. ".dwarf_rnglists.bin" end,
	debug_abbrev   = function(out_root, basename) return out_root .. "\\" .. basename .. ".dwarf_abbrev.bin"   end,
	debug_info     = function(out_root, basename) return out_root .. "\\" .. basename .. ".dwarf_info.bin"     end,
	debug_str      = function(out_root, basename) return out_root .. "\\" .. basename .. ".dwarf_str.bin"      end,
	debug_loc      = function(out_root, basename) return out_root .. "\\" .. basename .. ".dwarf_loc.bin"      end,
	debug_loclists = function(out_root, basename) return out_root .. "\\" .. basename .. ".dwarf_loclists.bin" end,
}

-- Write a list of {name, data, was} section records to disk via SECTION_WRITERS.
-- Used twice in M.run (safe-path + production-path).
-- The only difference between the two call sites is the `is_production` flag, which gates the per-section progress line.
-- @param results table[]     -- list of {name=, data=, was=} records to write
-- @param ctx      PassCtx
-- @param basename string     -- output file basename (e.g. "hello_gte")
-- @param is_production bool  -- true → emit progress line; false → silent
-- @param atom_table table    -- used by the progress line (only when is_production)
-- @return table  -- list of {name_bin = path} entries to append to M.run's outputs
local function write_sections(results, ctx, basename, is_production, atom_table)
	local outputs = {}
	for _, r in ipairs(results) do
		local path = SECTION_WRITERS[r.name](ctx.out_root, basename)
		local f = io.open(path, "wb")
		if not f then
			io.stderr:write(string.format("[dwarf_injection] failed to open %s for write\n", path))
		else
			f:write(r.data); f:close()
			if is_production then
				io.stderr:write(string.format("[dwarf_injection] new .%s = %d bytes (was %d, +%d atoms)\n"
					, r.name, #r.data, r.was, #atom_table))
			end
			outputs[#outputs + 1] = { [r.name .. "_bin"] = path }
		end
	end
	return outputs
end

local function write_gdbinit(out_root, basename, skip_over, atom_table)
	local path = out_root .. "\\" .. basename .. ".gdbinit"
	duffle.write_file_lf(path, build_gdbinit(skip_over, atom_table))
	return { gdbinit = path }
end

-- ════════════════════════════════════════════════════════════════════════════
-- Pass entry
-- ════════════════════════════════════════════════════════════════════════════

local M = {}

--- M.run — orchestrator entry.
--- @param ctx DwarfInjectionCtx
--- @return table
function M.run(ctx)
	-- Guard: this pass is opt-in via --dwarf-injection (not run on --all).
	if not (ctx.flags and ctx.flags.dwarf_injection) then
		return { outputs = {}, errors = {}, warnings = {} }
	end

	-- Guard: --elf is required.
	local elf_path = ctx.flags and ctx.flags.elf_path
	if not elf_path or elf_path == "" then
		io.stderr:write("[dwarf_injection] --elf flag missing\n")
		return { outputs = {}, errors = {}, warnings = {} }
	end

	-- Resolve relative ELF path to absolute via the canonical duffle helper.
	elf_path = duffle.to_absolute_path(elf_path)

	-- Read the existing DWARF sections directly (no subprocess; lfs + io.open + manual ELF32 section-header walk).
	-- We need all 8 sections: .debug_line / .debug_aranges / .debug_rnglists get extended
	-- (additional rows appended to the existing unit), and .debug_info / .debug_abbrev / .debug_str / .debug_loc / .debug_loclists 
	-- get spliced (the main CU's unit_length is patched;
	-- no new compile unit is appended; debug_loc/debug_loclists may not exist in the source ELF so we add-section them on splice).
	-- The dispatch (SECTION_BUILDERS) handles each.
	local existing_sections = elf_dwarf.read_elf_sections(elf_path, {
		".debug_line", ".debug_aranges", ".debug_rnglists",
		".debug_info", ".debug_abbrev", ".debug_str",
		-- .debug_loc and .debug_loclists don't exist in the source ELF (we add-section them on splice);
		-- reading them just returns "" which is the "missing" case the builder handles.
		".debug_loc", ".debug_loclists",
	})
	io.stderr:write(string.format(
		"[dwarf_injection] read %d DWARF sections: .debug_line=%d .debug_aranges=%d .debug_rnglists=%d .debug_info=%d .debug_abbrev=%d .debug_str=%d .debug_loc=%d .debug_loclists=%d\n",
		8,
		#(existing_sections[".debug_line"]     or ""),
		#(existing_sections[".debug_aranges"]  or ""),
		#(existing_sections[".debug_rnglists"] or ""),
		#(existing_sections[".debug_info"]     or ""),
		#(existing_sections[".debug_abbrev"]   or ""),
		#(existing_sections[".debug_str"]      or ""),
		#(existing_sections[".debug_loc"]      or ""),
		#(existing_sections[".debug_loclists"] or "")))

	-- Consume source-as-written skip associations from every scanned source,
	-- then build the atom/provenance table with those generic selections.
	-- Whole atoms remain symbol-keyed; components are file-qualified internally so a source marker associates
	-- with its exact component definition even though GDB 12 requires function-only skip entries for the resulting synthetic inline frame.
	-- `corpus` is the sole canonical source projection;
	-- the sole source of truth; no `ctx.sources` / `ctx.by_dir` aliases).
	local corpus = (ctx.shared and ctx.shared.corpus) or {}
	local skip_over  = collect_skip_over(corpus)
	local registries = collect_per_source_registries(corpus)
	-- Read nm symbols (the ONLY disk-side input to the atom table) and join
	-- them against `corpus.atoms_by_name` + `atom.paths` for word rows + invocation ancestry.
	-- Disk source-map/provenance text is NOT consulted (those are diagnostic artifacts; semantic inputs are in memory).
	local addrs = elf_dwarf.read_nm(ctx.flags.elf_path)
	local atom_table = build_atom_table(corpus, addrs, skip_over)
	io.stderr:write(string.format("[dwarf_injection] matched %d atoms between nm + corpus.atoms_by_name\n", #atom_table))

	-- Detect rbind atoms + index Binds_* struct fields (from ctx.sources[i].scan, populated by scan-source pass).
	-- The merged registries are threaded through so parse_body_load_pairs resolves R_<reg> via register_alias_registry.
	local _rbind_atoms, rbind_structs = parse_rbind_atoms(corpus, atom_table, registries)
	local rbind_count = 0
	for _ in pairs(_rbind_atoms) do rbind_count = rbind_count + 1 end
	io.stderr:write(string.format("[dwarf_injection] matched %d rbind atoms across %d Binds_* structs\n",
		rbind_count, (function() local n = 0; for _ in pairs(rbind_structs) do n = n + 1 end; return n end)()))

	-- Write the .bin files. The build_psyq.ps1 post-link hook splices these into a copy of the ELF via objcopy --update-section.
	-- Build order:
	--   0. Validate .debug_info layout (crT CU + DWARF5 main CU + final 0 root terminator).
	--      If validation fails, write existing sections unchanged and emit no synthetic data.
	--   1. Build new .debug_abbrev using the main CU's abbrev offset → returns the offset of the duplicate main table (= #existing_abbrev).
	--   2. Build new .debug_info by splicing inserted children into the main CU (patches main CU's unit_length + debug_abbrev_offset;
	--      preserves all original DIE bytes; does NOT append a synthetic CU).
	--   3. Build .debug_line + .debug_aranges + .debug_rnglists.
	--   4. Build .debug_loc (just a terminator).
	--
	-- .debug_str now also receives the new RR_<R_Name> entries
	-- (the merged registry drives the strings table to keep .debug_str and .debug_info in sync).
	local basename = ctx.basename or duffle.basename_no_ext(elf_path) or DEFAULT_BASENAME
	if ctx.out_root and ctx.out_root ~= "" then
		duffle.ensure_dir(ctx.out_root)
		local gdbinit_output = write_gdbinit(ctx.out_root, basename, skip_over, atom_table)

		-- Step 0: layout validation. Bail out safely if the .debug_info layout doesn't match what we expect (crt CU + DWARF5 main CU + final 0 byte).
		local existing_info   = existing_sections[".debug_info"]   or ""
		local existing_abbrev = existing_sections[".debug_abbrev"] or ""
		local main_cu_start, main_cu_end_excl, main_abbrev_offset = find_main_cu_layout(existing_info)
		if not main_cu_start then
			io.stderr:write("[dwarf_injection] layout validation failed; writing existing sections unchanged\n")
			local existing_str = existing_sections[".debug_str"] or ""
			local results_safe = {
				{ name = "debug_info",     data = existing_info,       was = #existing_info },
				{ name = "debug_abbrev",   data = existing_abbrev,     was = #existing_abbrev },
				{ name = "debug_str",      data = existing_str,                                                       was = #existing_str },
				{ name = "debug_line",     data = build_dwarf_line_section    (existing_sections[".debug_line"] or "",     atom_table), was = #(existing_sections[".debug_line"]     or "") },
				{ name = "debug_aranges",  data = build_dwarf_aranges_section (existing_sections[".debug_aranges"] or "",  atom_table), was = #(existing_sections[".debug_aranges"]  or "") },
				{ name = "debug_rnglists", data = build_dwarf_rnglists_section(existing_sections[".debug_rnglists"] or "", atom_table), was = #(existing_sections[".debug_rnglists"] or "") },
			{ name = "debug_loc",      data = string.char(DW_LLE_end_of_list),                                                       was = #(existing_sections[".debug_loc"]      or "") },
			}
			local section_outputs = write_sections(results_safe, ctx, basename, false, atom_table)
			local outputs_safe = { gdbinit_output }
			for _, o in ipairs(section_outputs) do outputs_safe[#outputs_safe + 1] = o end
			return { outputs = outputs_safe, errors = {}, warnings = {} }
		end

		-- Step 1: duplicate main abbrev table + append new codes 100..109.
		local new_abbrev, new_abbrev_offset = build_debug_abbrev_section(existing_abbrev, main_abbrev_offset)
		if not new_abbrev_offset then
			io.stderr:write("[dwarf_injection] main abbrev-table validation failed; refusing to emit malformed DWARF\n")
			return { outputs = { gdbinit_output }, errors = {}, warnings = {"main abbrev-table validation failed"} }
		end

		-- Step 1b: compute per-atom loclist offsets BEFORE building .debug_info
		-- (the bind_args variable references the loclist via DW_FORM_sec_offset).
		local loclists_offsets = compute_loclists_offsets(atom_table)

		-- Step 2: splice inserted children into the main CU (patches unit_length + abbrev_offset; no synthetic CU).
		local new_info  = build_debug_info_section(existing_info, main_cu_start, main_cu_end_excl, new_abbrev_offset, atom_table, rbind_structs, loclists_offsets, registries)

		-- Step 2b: rebuild .debug_str now that we know which RR_<R_Name> entries
		-- get emitted (this aligns with build_debug_info_section's by_alias loop).
		local new_str, new_str_offset, string_map = build_debug_str_section(existing_sections[".debug_str"] or "", atom_table, registries)

		-- Step 3-5: independent sections.
		local results = {
			{ name = "debug_abbrev",   data = new_abbrev,                                                                            was = #existing_abbrev },
			{ name = "debug_info",     data = new_info,                                                                              was = #existing_info },
			{ name = "debug_str",      data = new_str,                                                                               was = #(existing_sections[".debug_str"]      or "") },
			{ name = "debug_line",     data = build_dwarf_line_section    (existing_sections[".debug_line"] or "",     atom_table),  was = #(existing_sections[".debug_line"]     or "") },
			{ name = "debug_aranges",  data = build_dwarf_aranges_section (existing_sections[".debug_aranges"] or "",  atom_table),  was = #(existing_sections[".debug_aranges"]  or "") },
			{ name = "debug_rnglists", data = build_dwarf_rnglists_section(existing_sections[".debug_rnglists"] or "", atom_table),  was = #(existing_sections[".debug_rnglists"] or "") },
			{ name = "debug_loc",      data = string.char(DW_LLE_end_of_list),                                                       was = #(existing_sections[".debug_loc"]      or "") },
			{ name = "debug_loclists", data = build_debug_loclists_section(atom_table, registries),                                 was = 0 },
		}

		local section_outputs = write_sections(results, ctx, basename, true, atom_table)
		local outputs = { gdbinit_output }
		for _, o in ipairs(section_outputs) do outputs[#outputs + 1] = o end
		return {
			outputs  = outputs,
			errors   = {},
			warnings = {},
		}
	end
	return { outputs = {}, errors = {}, warnings = {} }
end

-- Test-only exports expose the emission and offset paths.
-- tests drive the real emission and offset computation paths.
M.compute_loclists_offsets_for_test     = compute_loclists_offsets
M.build_debug_loclists_section_for_test = build_debug_loclists_section
M.tape_piece_size_for_test              = tape_piece_size

return M
