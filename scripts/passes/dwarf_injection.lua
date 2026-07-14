--- passes/dwarf_injection.lua — Per-atom DWARF injection for tape-atom step-debug (F' + G').
---
--- Reads the post-link ELF directly 
--- (lfs + io.open; walks the ELF32 section header table to find 
--- 	`.debug_info` 
--- + `.debug_abbrev` 
--- + `.debug_str` 
--- + `.debug_line` 
--- + `.debug_aranges` 
--- + `.debug_rnglists`),
--- APPENDS synthetic DWARF line-program sequences for every `code_<name>` atom, EXTENDS the `.debug_aranges` and main-CU range tables with the atom ranges,
--- APPENDS a new compilation unit to `.debug_info` with per-atom `DW_TAG_subprogram` + per-wave-context-reg `DW_TAG_variable` entries
--- (so `R_PrimCursor` etc. appear as atom-scoped locals in VSCode's Variables pane).
--- Writes the new section data to `<out_root>/<basename>.dwarf_*.bin` (7 blobs total)
--- plus deterministic `<out_root>/<basename>.gdbinit` skip commands.
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
--- Result: VSCode's source gutter follows per-stepi inside atom bodies (F'),
--- AND the Variables pane shows the wave-context regs as atom-scoped locals (G').
--- Native VSCode UX (gutter arrow + highlighted line + Run to Cursor + conditional BPs by source line + per-atom locals).
--- No VSCode plugin, no Python, no pyelftools — pure Lua + objcopy.
---
--- **Conventions:** tabs (1/level), EmmyLua annotations, no regex,
--- Lua 5.3 compatible.

-- ════════════════════════════════════════════════════════════════════════════
-- Bootstrap
-- ════════════════════════════════════════════════════════════════════════════

-- Load `duffle_paths.lua` via `debug.getinfo(1, "S").source` (works both standalone + when require'd). 
-- Sets package.path + package.cpath then returns duffle.
local _bootstrap_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local duffle         = dofile(_bootstrap_dir .. "../duffle_paths.lua")

-- ELF32 / DWARF / atoms-source-map utilities (post-link debug-info injection).
-- Sister module to duffle.lua — contains the format-constant tables (ELF32 byte offsets, DWARF opcodes, etc.) and the I/O helpers
-- (read_elf_sections, nm, source-map parser, LE byte r/w). `list_dir` lives in duffle.lua as a general I/O primitive (lifted out during F'').
local elf_dwarf = require("elf_dwarf")

local lfs = require("lfs")

-- ════════════════════════════════════════════════════════════════════════════
-- Constants
-- ════════════════════════════════════════════════════════════════════════════

-- DWARF line-program opcodes + range-list entry encodings (per DWARF5 spec).
-- All values lifted from `elf_dwarf.DWARF_LINE_OPS` + `elf_dwarf.DWARF5_RNGLISTS`. 
-- Local aliases preserve the F' code's readability 
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

-- Wave-context registers (per duffle.lua :: WAVE_CONTEXT_REGS). The MIPS
-- register number is what DW_OP_regN uses as N.
--
--   R_PrimCursor = R_T7 = $15   →  DW_OP_reg15
--   R_FaceCursor = R_T4 = $12   →  DW_OP_reg12
--   R_VertBase   = R_T5 = $13   →  DW_OP_reg13
--   R_OtBase     = R_T6 = $14   →  DW_OP_reg14
--   R_TapePtr    = R_T8 = $24   →  DW_OP_reg24
--   R_AtomJmp    = R_T9 = $25   →  DW_OP_reg25
--
-- A register-resident variable uses DW_OP_regN (opcode 0x50 + N).
-- DW_OP_bregN instead describes a memory location addressed from a register;
-- it makes GDB dereference the atom register value rather than display it.
local WAVE_CONTEXT_LOCATIONS = {
	-- Names prefixed with `RR` to avoid collision with the C-level enum `{R_AtomJmp = 25, R_TapePtr = 24, R_InCursor = 12, R_PrimCursor = 15, ...}`
	-- declared in the duffle headers (code/duffle/dsl.h or atom_dsl.h). 
	-- Without the prefix, gdb's `print R_PrimCursor` resolves to the enum constant (= 15), not to this DWARF variable.
	-- With `set print enum on` (gdb default for enum values), gdb displays the enum identifier, so the Watch panel shows
	-- `R_PrimCursor = R_PrimCursor` instead of the register value.
	{ name = "RR_PrimCursor", reg = 0x0F },   -- $15
	{ name = "RR_FaceCursor", reg = 0x0C },   -- $12
	{ name = "RR_VertBase",   reg = 0x0D },   -- $13
	{ name = "RR_OtBase",     reg = 0x0E },   -- $14
	{ name = "RR_TapePtr",    reg = 0x18 },   -- $24
	{ name = "RR_AtomJmp",    reg = 0x19 },   -- $25
}

-- New abbreviation codes (100+ to avoid collision with gcc's existing
-- 1-60+ codes).
local ABBREV_CU          = 0x64   -- 100: DW_TAG_compile_unit
local ABBREV_SUBPROGRAM  = 0x65   -- 101: DW_TAG_subprogram
local ABBREV_VARIABLE    = 0x66   -- 102: DW_TAG_variable (DW_AT_type = ref4 to U4; was missing pre-2026-07-13 → gdb resolved R_PrimCursor against the C-level enum, not the register)
-- Task 8 (rbind composite via DW_OP_piece): 4 new abbreviations.
local ABBREV_STRUCT_TYPE = 0x67   -- 103: DW_TAG_structure_type with children (Binds_X mirror)
local ABBREV_MEMBER      = 0x68   -- 104: DW_TAG_member no children (DW_AT_type = ref4 to U4 base)
local ABBREV_BIND_VAR    = 0x69   -- 105: DW_TAG_variable no children + DW_AT_type = ref4 (the bind_args variable)
local ABBREV_BASE_TYPE   = 0x6A   -- 106: DW_TAG_base_type no children (U4)
-- Phase 3 (debug_ux): component step-into (DW_TAG_inlined_subroutine + abstract DW_TAG_subprogram).
local ABBREV_ABSTRACT_SUBPROGRAM = 0x6B   -- 107: DW_TAG_subprogram (abstract — no low_pc/high_pc); for each unique mac_X component
local ABBREV_INLINED_SUBROUTINE  = 0x6C   -- 108: DW_TAG_inlined_subroutine with children (per-component invocation range)
-- Phase 5 (debug_ux): bind_args uses DW_FORM_sec_offset → .debug_loclists for
-- PC-ranged liveness (each field transitions from tape memory to GPR at
-- load_pc + 8 = MIPS I load-delay slot boundary).
local ABBREV_BIND_VAR_LOCLIST = 0x6D   -- 109: DW_TAG_variable no children + DW_AT_type = ref4 + DW_AT_location = sec_offset

-- DWARF5 §7.7.3 loclist opcodes.
local DW_LLE_end_of_list  = 0x00
local DW_LLE_start_length = 0x06
local DW_OP_reg0           = 0x50   -- base reg op; regN = 0x50 + N
local DW_OP_breg0          = 0x70   -- base breg op; bregN = 0x70 + N (SLEB offset)
local MIPS_LOAD_DELAY_BYTES = 0x08 -- 1 load word + 1 BD-slot word
-- Late-binding table for forward references. The loclist functions
-- (defined below) use uleb128 + elf_dwarf which are not yet defined
-- at this point. They look them up via this table at call time.
local _late = { uleb128 = nil, elf_dwarf = nil }

-- Build the .debug_loclists section for every rbind atom. Returns the
-- section bytes (DWARF5 layout: unit_length(4) + version=5(2) + address_size=4(1)
-- + segment_size=0(1) + offset_entry_count=0(4) + DW_LLE entries; each atom
-- contributes one loclist terminated by DW_LLE_end_of_list).
--
-- Per rbind atom we emit 2 loclist entries (tape → GPR split) using the
-- last field's transition as the boundary. This is a conservative approximation
-- that always reads the correct GPR value once the first load has retired
-- (load_pc + 8). A future task can refine to per-field transitions.
-- @param atom_table table[]  -- list of atoms with .rbind set
-- @return string  -- section bytes
local function build_debug_loclists_section(atom_table)
	-- Loclist header (per DWARF5 §7.7.3):
	--   unit_length(4) + version(2) + address_size(1) + segment_size(1) + offset_entry_count(4)
	-- All our entries are DW_LLE_start_length + addr(4) + length(ULEB) + expression
	-- terminated by DW_LLE_end_of_list (1 byte).
	-- R_TapePtr is register 24 ($t8). R_<reg> maps via R_NAME_TO_INDEX above.
	-- We compute the field-by-field transition: at each load_pc + 8, one more
	-- field has committed from tape memory to its destination GPR.
	local tape_reg = R_NAME_TO_INDEX["R_TapePtr"]  -- = 24
	if not tape_reg then tape_reg = 24 end  -- fallback if R_TapePtr isn't in the table
	local parts = {}
	for _, atom in ipairs(atom_table) do
		if atom.rbind then
			local fields = atom.rbind.fields or {}
			local regs   = atom.rbind.regs or {}
			local n_fields = #fields
			io.stderr:write(string.format("[loclists] %s: n_fields=%d, fields[1].name=%s offset=%s, regs[1]=%s\n",
				atom.name, n_fields,
				fields[1] and fields[1].name or "?",
				fields[1] and tostring(fields[1].offset) or "?",
				regs[1] and (regs[1].field or "?") or "?"))
			local last_load_pc = atom.addr + (n_fields - 1) * MIPS_BYTES_PER_WORD
			local transition_pc = last_load_pc + MIPS_LOAD_DELAY_BYTES
			-- Build the "all in tape" piece chain (one DW_OP_breg24 + offset + DW_OP_piece(4) per field).
			local tape_pieces = {}
			for _, f in ipairs(fields) do
				local offset = f.offset or 0
				local offset_sleb = elf_dwarf.sleb128(offset)
				table.insert(tape_pieces, string.char(DW_OP_breg0 + tape_reg) .. offset_sleb .. string.char(DW_OP_piece) .. uleb128(4))
			end
			local tape_expr = table.concat(tape_pieces)
			-- Build the "all in GPR" piece chain (one DW_OP_regN + DW_OP_piece(4) per field).
			local gpr_pieces = {}
			for _, pair in ipairs(regs) do
				table.insert(gpr_pieces, string.char(DW_OP_reg0 + pair.reg) .. string.char(DW_OP_piece) .. uleb128(4))
			end
			local gpr_expr = table.concat(gpr_pieces)
			-- Emit two DW_LLE_start_length entries + DW_LLE_end_of_list.
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
	-- Build the section header.
	local body = table.concat(parts)
	-- unit_length = 2 (version) + 1 (address_size) + 1 (segment_size) + 4 (offset_entry_count) + #body
	local unit_length = 2 + 1 + 1 + 4 + #body
	local header = elf_dwarf.write_u32_le(unit_length)
		.. elf_dwarf.write_u16_le(5)        -- version = 5
		.. string.char(4)                   -- address_size = 4
		.. string.char(0)                   -- segment_size = 0
		.. elf_dwarf.write_u32_le(0)        -- offset_entry_count = 0
	return header .. body
end

-- Compute the per-atom loclist offset within a .debug_loclists section that
-- the caller will later pass to .debug_info (DW_FORM_sec_offset is a 4-byte
-- section-relative offset). Returns a table {[atom_name] = offset_in_loclists}.
-- The header is 12 bytes (unit_length(4) + version(2) + address_size(1) +
-- segment_size(1) + offset_entry_count(4)); each loclist body is the sum of
-- its DW_LLE entries (computed by replaying the same emission).
-- @param atom_table table[]  -- list of atoms with .rbind set
-- @return table  -- {[atom_name] = offset_in_section}
local function compute_loclists_offsets(atom_table)
	local offsets = {}
	-- Header size = 4 (unit_length) + 2 (version) + 1 (address_size) + 1 (segment_size) + 4 (offset_entry_count)
	local cursor = 4 + 2 + 1 + 1 + 4
	for _, atom in ipairs(atom_table) do
		if atom.rbind then
			offsets[atom.name] = cursor
			-- Each loclist body: 2 DW_LLE_start_length + 1 DW_LLE_end_of_list.
			-- Per DW_LLE_start_length: 1 (opcode) + 4 (addr) + ULEB(length) + length bytes.
			-- The length bytes are N pieces × (1 reg op + 1 piece op + 1 ULEB4)
			--   = 3N bytes for one-piece blocks (tape: reg + SLEB + piece+4;
			--   GPR: reg + piece+4). For the all-tape form: N × (1 + 1 + 1) = 3N.
			-- We compute the exact length for the current build.
			local n_fields = #atom.rbind.fields
			-- tape_expr: for each field, 1 (breg) + 1..4 (SLEB offset) + 1 (piece) + 1 (ULEB 4)
			-- For our Binds_CubeTri / Binds_FloorTri, offsets are 0/4/8/12 (4 bytes ≤ 127, 1 SLEB byte).
			-- So tape_expr = n_fields * 3 bytes.
			local tape_expr_len = n_fields * 3
			local tape_entry = 1 + 4 + 1 + tape_expr_len
			-- gpr_expr: for each field, 1 (reg op) + 1 (piece) + 1 (ULEB 4) = 3 bytes.
			local gpr_expr_len = n_fields * 3
			local gpr_entry  = 1 + 4 + 1 + gpr_expr_len
			local body_len   = tape_entry + gpr_entry + 1  -- +1 for DW_LLE_end_of_list
			cursor = cursor + body_len
		end
	end
	return offsets
end

-- DWARF3/4/5 opcodes / attributes / forms (for the .debug_info synth).
-- DW_TAG values are stable across DWARF3-5 per the standard's Table 7.1;
-- gcc emits DW_TAG_structure_type=0x13 + DW_TAG_base_type=0x24 even in
-- DWARF5-versioned CUs, so we match those exact byte values.
local DW_TAG_compile_unit    = 0x11
local DW_TAG_subprogram      = 0x2E
local DW_TAG_variable        = 0x34
local DW_TAG_structure_type  = 0x13
local DW_TAG_member          = 0x0D
local DW_TAG_base_type       = 0x24
-- Phase 3 (debug_ux): component step-into.
local DW_TAG_inlined_subroutine = 0x1D

local DW_AT_name             = 0x03
local DW_AT_low_pc           = 0x11
local DW_AT_high_pc          = 0x12
local DW_AT_language         = 0x13
local DW_AT_location         = 0x02
local DW_AT_comp_dir         = 0x1B
local DW_AT_byte_size        = 0x0B
local DW_AT_encoding         = 0x3E   -- DWARF5 §7.7.1: DW_AT_encoding (for DW_ATE_unsigned base type; was 0x13 = DW_AT_language in prior slice - semantically wrong)
local DW_AT_data_member_location = 0x38
local DW_AT_type             = 0x49
local DW_AT_linkage_name     = 0x6E   -- DWARF5 §7.7.1: DW_AT_linkage_name (standard form; 0x200027 was the GNU extension form - wrong vs DW_FORM_string abbrev)
local DW_AT_external         = 0x3F   -- marks a variable/function as externally visible
-- Phase 3 (debug_ux): inlined_subroutine + abstract_origin attributes.
local DW_AT_abstract_origin  = 0x31
local DW_AT_call_file        = 0x58
local DW_AT_call_line        = 0x59
local DW_AT_inline           = 0x20   -- DWARF5 §7.7.1: DW_AT_inline (used by abstract subprogram for the mac_X() components)
-- Phase 3 Task 3 (debug_ux): decl_file + decl_line on the abstract subprogram so consumers
-- can resolve an abstract origin back to its definition site even when no
-- inlined_subroutine instance currently maps to it.
local DW_AT_decl_file        = 0x3A   -- DWARF5 §7.7.1: DW_AT_decl_file (1-based file index into the CU's file table)
local DW_AT_decl_line        = 0x3B   -- DWARF5 §7.7.1: DW_AT_decl_line

-- File index lookup table for the existing main line unit (Unit 2).
-- Provenance paths come back with mixed slashes; we normalize to basename
-- and look up against the line unit's actual file table. The current Phase 3
-- scope has two provenance basenames: hello_gte_tape.c (the atom's call site)
-- and lottes_tape.h (the component definition). Both live in the existing
-- gcc-generated line unit; their 1-based indices are stable across rebuilds
-- because the include order in code/gte_hello/hello_gte.c determines the
-- unit's file table.
local PROVENANCE_BASENAME_TO_FILE_INDEX = {
	["hello_gte_tape.c"] = ATOM_SOURCE_FILE_INDEX,  -- = 11
	["lottes_tape.h"]    = 4,
}

--- Resolve an absolute provenance path to the line-unit file index used by the
--- emitting line program. Normalizes mixed `/` and `\` separators to a basename
--- and looks it up against the known Phase 3 file table.
---
--- Fails loudly on an unknown provenance basename: adding a new component
--- source file requires extending `PROVENANCE_BASENAME_TO_FILE_INDEX` so the
--- line-program emission contract stays explicit. Silent fallback to
--- ATOM_SOURCE_FILE_INDEX would mask the new-file case by misattributing
--- component rows to the atom's source file.
---
--- @param path string  -- absolute provenance path (e.g. "C:/.../lottes_tape.h" or "C:\\...\\lottes_tape.h")
--- @return integer  -- 1-based line-unit file index
local function resolve_provenance_file_index(path)
	if path == nil or path == "" then
		error("[dwarf_injection] resolve_provenance_file_index: empty path")
	end
	-- Normalize backslashes → forward slashes (paths arrive with mixed separators from
	-- the provenance file: forward slashes from Lua's io.lines; backslashes if the
	-- input ever round-trips through Windows shell expansion).
	local normalized = path:gsub("\\", "/")
	-- Take the last path component (the basename).
	local basename = normalized:match("([^/]+)$") or normalized
	local idx = PROVENANCE_BASENAME_TO_FILE_INDEX[basename]
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
-- (DW_LANG_Mips_Assembler = 0x8001 was used in the F' Task 5 test, but we want
-- this CU to look like a C TU so VSCode's Variables pane treats it as code.)

-- R_ alias → MIPS register number.
-- Subset covering every R_ name used in the source atoms.
-- Used by Task 8 to build the piece-chain location for bind_args (which field comes from which reg).
-- The wave-context entries match WAVE_CONTEXT_LOCATIONS above; the rest are the standard MIPS C-ABI register names.
local R_NAME_TO_INDEX = {
	["R_0"]  = 0,  ["R_AT"] = 1,  ["R_V0"] = 2,  ["R_V1"] = 3,
	["R_A0"] = 4,  ["R_A1"] = 5,  ["R_A2"] = 6,  ["R_A3"] = 7,
	["R_T0"] = 8,  ["R_T1"] = 9,  ["R_T2"] = 10, ["R_T3"] = 11,
	["R_T4"] = 12, ["R_T5"] = 13, ["R_T6"] = 14, ["R_T7"] = 15,
	["R_S0"] = 16, ["R_S1"] = 17,
	["R_T8"] = 24, ["R_T9"] = 25,
	-- Wave-context aliases (same encoding as R_T4..R_T7, R_T8..R_T9).
	["R_PrimCursor"] = 15, ["R_FaceCursor"] = 12,
	["R_VertBase"]   = 13, ["R_OtBase"]     = 14,
	["R_TapePtr"]    = 24, ["R_AtomJmp"]    = 25,
}

-- Build the .debug_loclists section for every rbind atom. Returns the
-- section bytes (DWARF5 layout: unit_length(4) + version=5(2) + address_size=4(1)
-- + segment_size=0(1) + offset_entry_count=0(4) + DW_LLE entries; each atom
-- contributes one loclist terminated by DW_LLE_end_of_list).
--
-- Per rbind atom we emit 2 loclist entries (tape → GPR split) using the
-- last field's transition as the boundary. This is a conservative approximation
-- that always reads the correct GPR value once the first load has retired
-- (load_pc + 8). A future task can refine to per-field transitions.
-- @param atom_table table[]  -- list of atoms with .rbind set
-- @return string  -- section bytes
local function build_debug_loclists_section(atom_table)
	local uleb128    = _late.uleb128
	local elf_dwarf  = _late.elf_dwarf
	local tape_reg = R_NAME_TO_INDEX["R_TapePtr"]  -- = 24
	if not tape_reg then tape_reg = 24 end
	local parts = {}
	for _, atom in ipairs(atom_table) do
		if atom.rbind then
			local fields = atom.rbind.fields or {}
			local regs   = atom.rbind.regs or {}
			local n_fields = #fields
			local last_load_pc = atom.addr + (n_fields - 1) * MIPS_BYTES_PER_WORD
			local transition_pc = last_load_pc + MIPS_LOAD_DELAY_BYTES
			local tape_pieces = {}
			for _, f in ipairs(fields) do
				local offset = f.offset or 0
				local offset_sleb = elf_dwarf.sleb128(offset)
				table.insert(tape_pieces, string.char(DW_OP_breg0 + tape_reg) .. offset_sleb .. string.char(DW_OP_piece) .. uleb128(4))
			end
			local tape_expr = table.concat(tape_pieces)
			local gpr_pieces = {}
			for _, pair in ipairs(regs) do
				table.insert(gpr_pieces, string.char(DW_OP_reg0 + pair.reg) .. string.char(DW_OP_piece) .. uleb128(4))
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
	local body = table.concat(parts)
	local unit_length = 2 + 1 + 1 + 4 + #body
	local header = elf_dwarf.write_u32_le(unit_length)
		.. elf_dwarf.write_u16_le(5)
		.. string.char(4)
		.. string.char(0)
		.. elf_dwarf.write_u32_le(0)
	return header .. body
end

-- Compute the per-atom loclist offset within a .debug_loclists section.
-- @param atom_table table[]  -- list of atoms with .rbind set
-- @return table  -- {[atom_name] = offset_in_section}
local function compute_loclists_offsets(atom_table)
	local offsets = {}
	local cursor = 4 + 2 + 1 + 1 + 4
	for _, atom in ipairs(atom_table) do
		if atom.rbind then
			offsets[atom.name] = cursor
			local n_fields = #atom.rbind.fields
			local tape_expr_len = n_fields * 3
			local gpr_expr_len  = n_fields * 3
			local tape_entry    = 1 + 4 + 1 + tape_expr_len
			local gpr_entry     = 1 + 4 + 1 + gpr_expr_len
			local body_len      = tape_entry + gpr_entry + 1
			cursor = cursor + body_len
		end
	end
	return offsets
end

-- Default name for the synthetic CU (so VSCode lists it as a known source).
local DEFAULT_CU_NAME    = "tape_atom_locals"
local DEFAULT_CU_COMP_DIR = "."

-- Path templates for the .bin outputs are now in SECTION_WRITERS (see below).

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
--- GDB accepts forward slashes on Windows; absolute paths avoid cwd-dependent
--- sidecars and match the Phase-3 provenance contract.
--- @param path string
--- @return string
local function normalize_debug_path(path)
	return duffle.to_absolute_path(path):gsub("\\", "/")
end

--- Build a case-insensitive Windows path + exact component-name key.
--- @param path string
--- @param component_name string
--- @return string
local function component_skip_key(path, component_name)
	return normalize_debug_path(path):lower() .. "\0" .. component_name
end

--- Consume the per-source scanner associations without naming any atom or
--- component in production. Whole atoms remain symbol-keyed; components are
--- file-qualified internally so a source marker associates with its exact
--- component definition even though GDB 12 requires function-only skip entries
--- for the resulting synthetic inline frame.
--- @param ctx DwarfInjectionCtx
--- @return table  -- {atoms = {[symbol] = association}, components = {[file|name] = association}}
local function collect_skip_over(ctx)
	local skip_over = { atoms = {}, components = {} }
	for _, src in ipairs(ctx.sources or {}) do
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
				skip_over.components[component_skip_key(source_path, component_name)] = {
					name        = component_name,
					source_path = source_path,
					association = association,
				}
			end
		end
	end
	return skip_over
end

--- Render deterministic debugger skip commands. Ordering is stable by category:
--- exact atom symbols first (lexicographic), then exact component function
--- names (lexicographic full command). Atom commands come from the matched
--- nm/source-map table so the emitted name is the actual ELF symbol. The
--- scanner tables and command set both deduplicate repeated source observations.
--- @param skip_over table
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
-- Lifted to `elf_dwarf.uleb128` + `elf_dwarf.sleb128` (F'' refactor).
-- See those helpers for the bit-layout documentation + named constants
-- (LEB_CONT_BIT, LEB_DATA_MASK, SLEB_SIGN_BIT).

-- Local aliases so the line-program encoder (below) can keep its short names.
local uleb128 = elf_dwarf.uleb128
-- Late-bind uleb128 + elf_dwarf into the loclist functions' lookup table.
_late.uleb128   = uleb128
_late.elf_dwarf = elf_dwarf
local sleb128 = elf_dwarf.sleb128

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
--- Each "entry emission" emits one or more rows at the same PC, tracking
--- the source state {file_idx, line}. State transitions emit DW_LNS_set_file
--- + DW_LNS_advance_line as needed; same-state transitions emit only the
--- row (copy).
---
--- Phase 3 (debug_ux) entry rules:
---   * RAW entry (no invocation): emit (call_file, entry.line) at this PC.
---   * Invocation entry, NOT first word: emit (comp_file, comp_line).
---   * Invocation entry, IS first word: emit TWO rows at the same PC in
---     order: (call_file, inv.call_line), then (comp_file, inv.comp_line).
---
--- Phase 3 Task 3 (debug_ux) atom-entry rules:
---   * Atom entry 1 also gets a duplicate copy_op for the GDB 12
---     zero-instruction-prologue marker (no advance_pc — same PC).
---
--- Wire format reminder (DWARF5 §6.2.5):
---   - Standard opcodes: 1 byte opcode + payload (per opcode length).
---   - Extended opcode marker byte = 0.
---   - Extended opcodes: marker byte + ULEB128 size + sub_opcode + payload.
---
--- Phase 4 (debug_ux) statement-state rules:
---   * A marked whole atom emits one opaque is_stmt=false range row and no
---     nested component rows; its subprogram symbol/range remains available.
---   * A marked component keeps its first-word call-site row true, toggles only
---     the definition row/range false, and restores before the next unmarked row.
---   * Whole-atom suppression wins over component markers; no nested inversion.
---
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
	local function negate_stmt()             return string.char(DW_LNS_negate_stmt) end
	local function end_sequence()
		-- size = 1 (just the sub_opcode byte, no payload)
		return string.char(DW_LNS_extended)
			.. string.char(DWARF_LINE_OPS.end_sequence_payload_size)
			.. string.char(DW_LNE_end_sequence)
	end

	if not atom.entries or #atom.entries == 0 then return set_address(atom.addr) .. end_sequence() end

	-- A jump-threaded atom is reached by `jr`, not a C call. GDB therefore
	-- cannot apply the parent `skip function` entry before descending into a
	-- visible child inline frame. Make an explicitly marked atom DWARF-opaque:
	-- one non-statement row covers its complete address range, with no per-word
	-- or component source transitions. The atom's subprogram DIE remains, so
	-- symbolic lookup, explicit address breakpoints, and stepi are unaffected.
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

	-- Find which invocation each entry belongs to (if any). Returns the
	-- invocation record or nil. Pre-computed once so we don't rescan per
	-- emitted row.
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
		set_address(atom.addr),                -- 7 bytes: marker + size + sub + addr; PC := atom.addr
	}

	-- Source state tracker: emits set_file + advance_line only on transitions,
	-- keeps bytes minimal. Both fields stay in sync with what we emit so we
	-- never duplicate a set_file or skip a state-change emit.
	local cur_file = nil  -- line-state.file_idx (nil = uninitialized)
	local cur_line = 1    -- line-state.line starts at 1 (per DWARF spec)
	local is_stmt  = true -- main line unit default_is_stmt; every sequence ends restored

	local function set_statement_state(want_stmt)
		if is_stmt ~= want_stmt then
			parts[#parts + 1] = negate_stmt()
			is_stmt = want_stmt
		end
	end

	-- Emit a state transition (set_file + advance_line + is_stmt as needed)
	-- before a row, then the row itself. Used for the row(s) at one entry PC.
	local function emit_row(file_idx, line, want_stmt)
		if cur_file ~= file_idx then
			parts[#parts + 1] = set_file(file_idx)
			cur_file = file_idx
		end
		if cur_line ~= line then
			parts[#parts + 1] = advance_line(line - cur_line)
			cur_line = line
		end
		set_statement_state(want_stmt)
		parts[#parts + 1] = copy_op()
	end

	-- Whole-atom suppression wraps the independent sequence itself. File/line
	-- state setup follows while is_stmt is already false; the matching restore
	-- is emitted after the final row below.
	if atom.skip_over then set_statement_state(false) end

	-- --- Atom entry (idx 1) -------------------------------------------------
	-- Determine entry-1's primary row (always the call-site file/line; we may
	-- emit a second row immediately after if entry 1 is also a component
	-- invocation's first word).
	local inv1    = inv_for_idx(1)
	local entry_1 = atom.entries[1]
	-- The atom body's own source file (the call site for any mac_X(...) inside it).
	local call_file_idx = ATOM_SOURCE_FILE_INDEX

	-- Primary row: call site at atom start. Capture its (file, line) so we can
	-- re-emit it as the GDB 12 zero-instruction-prologue marker below.
	local entry_1_call_file = call_file_idx
	local entry_1_call_line = (inv1 and inv1.call_line) or entry_1.line
	local atom_is_stmt      = not atom.skip_over

	-- Primary row: call site at atom start.
	emit_row(entry_1_call_file, entry_1_call_line, atom_is_stmt)

	-- If entry 1 is the first word of a component invocation, emit the
	-- component-definition row at the same PC immediately after. A selected
	-- component suppresses only this definition view; a selected atom suppresses
	-- both rows and therefore never inverts state for nested component markers.
	if inv1 and 1 == inv1.start_pos + 1 then
		local comp_file_idx_1 = resolve_provenance_file_index(inv1.comp_file)
		emit_row(comp_file_idx_1, inv1.comp_line, atom_is_stmt and not inv1.skip_over)
	end

	-- GDB 12 zero-instruction-prologue marker: duplicate of the PRIMARY
	-- entry-1 emission (the call-site row). We must explicitly restore the
	-- source state to (call_file, call_line) before emitting the duplicate,
	-- otherwise the duplicate lands at whatever state we ended entry-1 in
	-- (the component row, if entry 1 is an invocation start) — which would
	-- attach the marker to the wrong source statement.
	--
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
			-- 2) selected component-definition view is non-statement.
			emit_row(resolve_provenance_file_index(inv.comp_file), inv.comp_line,
				atom_is_stmt and not inv.skip_over)
		elseif inv then
			-- Subsequent word of an invocation: single comp-definition row.
			emit_row(resolve_provenance_file_index(inv.comp_file), inv.comp_line,
				atom_is_stmt and not inv.skip_over)
		else
			-- RAW word: single call-site row. emit_row restores is_stmt after a
			-- selected component range before exposing this adjacent row.
			emit_row(call_file_idx, entry.line, atom_is_stmt)
		end
	end

	-- Every sequence starts from default_is_stmt=true. Restore that state before
	-- DW_LNE_end_sequence so a marked whole atom has explicit bounded toggles and
	-- no state can leak to a following independent atom sequence.
	set_statement_state(true)
	parts[#parts + 1] = end_sequence()
	return table.concat(parts)
end

-- ════════════════════════════════════════════════════════════════════════════
-- Helpers: nm + source-map.txt + atom table
-- ════════════════════════════════════════════════════════════════════════════

--- Build the atom table the section builders consume.
--- Cross-references nm symbols with source-map.txt entries; sorted by addr.
--- Also consumes the provenance file to record per-component invocations
--- (Phase 3 — debug_ux). Each atom gains an `invocations` field with one
--- entry per `mac_X(...)` call site:
---   `{comp_name, call_file, call_line, comp_file, comp_line, start_pos, end_pos}`.
--- @param ctx DwarfInjectionCtx
--- @param skip_over table  -- collect_skip_over(ctx) result
--- @return table[]  -- list of {name, addr, size_bytes, words, entries, invocations, skip_over?}
local function build_atom_table(ctx, skip_over)
	local basename = ctx.basename or DEFAULT_BASENAME
	-- Source-map path: convention matches the α MVP's emission location.
	-- writes `<out_root>/<basename>.atoms.sourcemap.txt` (e.g. `build/gen/hello_gte_tape.atoms.sourcemap.txt`).
	-- But ctx.out_root is `build/gen` (the per-build output root) and basename defaults to `hello_gte`.
	-- The actual file emitted today is per-source; we look for any `*.atoms.sourcemap.txt` in out_root.
	local sm_files = duffle.list_dir(ctx.out_root, "%.atoms.sourcemap%.txt$")
	if #sm_files == 0 then
		io.stderr:write(string.format(
			"[dwarf_injection] no *.atoms.sourcemap.txt in %s; need atoms-source-map pass first\n",
			ctx.out_root))
		return {}
	end

	-- Read nm + merge all source-map files.
	local addrs  = elf_dwarf.read_nm(ctx.flags.elf_path)
	local merged = {}
	for _, sm_path in ipairs(sm_files) do
		local sm = elf_dwarf.parse_source_map_file(sm_path, 1)
		for name, sm_data in pairs(sm) do
			merged[name] = sm_data
		end
	end

	-- Phase 3 (debug_ux): also read *.atoms.provenance.txt to extract per-component invocations.
	-- Files are merged by atom name; entries carry the original {pos, call_file, call_line,
	-- comp_name, comp_file, comp_line} shape.
	local prov_files = duffle.list_dir(ctx.out_root, "%.atoms.provenance%.txt$")
	local prov_merged = {}
	for _, prov_path in ipairs(prov_files) do
		local prov = elf_dwarf.parse_provenance_file(prov_path, 1)
		for name, prov_data in pairs(prov) do
			prov_merged[name] = prov_data
		end
	end

	-- Cross-ref; keep atoms that exist in both.
	local out = {}
	for name, info in pairs(addrs) do
		local sm = merged[name]
		if sm then
			local atom = {
				name       = name,
				addr       = info[1],
				size_bytes = info[2],
				words      = sm.total,
				entries    = sm.words,
				skip_over = skip_over.atoms[name] ~= nil,
			}
			-- Group consecutive MACRO rows in this atom's provenance into invocations.
			-- An invocation = one `mac_X(...)` call site spanning N consecutive .word rows.
			-- Two consecutive rows with the same (comp_name, call_file, call_line, comp_file, comp_line)
			-- are part of the same invocation.
			local prov_data = prov_merged[name]
			if prov_data and prov_data.words then
				local invocations = {}
				local cur_inv = nil
				for _, w in ipairs(prov_data.words) do
					if w.comp_name then
						local inv_key = w.comp_name .. "|" .. w.call_file .. "|" .. w.call_line .. "|" .. w.comp_file .. "|" .. w.comp_line
						if cur_inv and cur_inv.key == inv_key then
							-- Same invocation as the previous word — extend its range.
							cur_inv.end_pos = w.pos
						else
							-- New invocation: flush the previous one and start fresh.
							if cur_inv then invocations[#invocations + 1] = cur_inv end
							cur_inv = {
								key        = inv_key,
								comp_name  = w.comp_name,
								call_file  = w.call_file,
								call_line  = w.call_line,
								comp_file  = w.comp_file,
								comp_line  = w.comp_line,
								start_pos  = w.pos,
								end_pos    = w.pos,
								skip_over  = skip_over.components[component_skip_key(w.comp_file, w.comp_name)] ~= nil,
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
-- G' Phase 2 Task 8: rbind atom detection + (reg, field) pairing
-- ════════════════════════════════════════════════════════════════════════════
--
-- An "rbind atom" has `atom_bind(Binds_X)` in its `atom_info(...)` sub-call.
-- The atom body pops one field per `load_word(R_<reg>, R_TapePtr, O_(Binds_X,Field))`
-- and the order of these load_word calls defines the (reg, field) pairing for the piece-chain DWARF location expression.
--
-- We use the SourceScan payload populated by `passes/scan_source.lua` (the dep-closed upstream pass). 
-- That pass walks each source once and populates `src.scan.atom_infos` (the atom_info sub-call parse) and `src.scan.binds` (the Binds_X struct field parse).
-- We re-walk the body for the (reg, field) pairing because the SourceScan pass doesn't preserve which R_<reg> receives which Binds_X.<field>.
--
-- **Local Binds_X field re-parse**: the source-scan pass's `scan_binds_fields` only recognizes U4 fields;
-- The current source uses pointer types too (`V4_S2* FaceCursor`, `U4* OtBase`).
-- To keep Task 8 contained (don't change the shared scan-source pass), we re-parse the Binds_X typedef body locally with a more permissive rule: 
-- U4 field = 4 bytes; any pointer type (`*`-suffixed) = 4 bytes (MIPS32 pointer). Everything else = skip + advance.

--- Re-parse a Binds_X typedef body, returning {fields = {{name, offset}, ...}, bytes = N}.
--- Walks one ident at a time. A field declaration looks like:
---     U4 PrimCursor;        | M3_S2* transform;        | V4_S2* FaceCursor;       | U4* OtBase;
---   which tokenizes as: TYPE [WS+ *] WS+ FIELD SEMI
--- Where TYPE is `U4` (recognized), or TYPE + optional `*` (pointer, recognized).
--- Other type tokens (e.g. user-defined `Struct_(Foo)`) are skipped + we move on.
--- @param body string  -- the typedef body (between `{` and `}`)
--- @return table, integer  -- (fields, byte_count)
local function reparse_binds_body(body)
	local fields   = {}
	local byte_off = 0
	local pos      = 1
	local body_len = #body
	while pos <= body_len do
		pos = duffle.skip_ws_and_cmt(body, pos)
		if pos > body_len then break end
		local type_ident, type_end = duffle.read_ident(body, pos)
		if not type_ident then
			pos = pos + 1
		else
			-- Scan past optional whitespace + `*` + whitespace.
			-- Recognized field types: U4 (no *) OR any TYPE* (pointer, 4 bytes on MIPS32).
			local p = duffle.skip_ws_and_cmt(body, type_end)
			local is_pointer = false
			local pointer_depth = 0
			while p <= body_len and body:sub(p, p) == "*" do
				is_pointer     = true
				pointer_depth  = pointer_depth + 1
				p = p + 1
				p = duffle.skip_ws_and_cmt(body, p)
			end
			local field_pos              = duffle.skip_ws_and_cmt(body, p)
			local field_ident, field_end = duffle.read_ident(body, field_pos)
			-- A field is "recognized" if type is `U4` (no *) OR if it's a pointer.
			if field_ident and (type_ident == "U4" or is_pointer) then
				fields[#fields + 1] = {
					name          = field_ident,
					offset        = byte_off,
					type_name     = type_ident,
					pointer_depth = pointer_depth,
				}
				byte_off = byte_off + 0x04    -- 4 bytes per field on MIPS32
			end
			-- Advance past the field ident (or the type ident if no field was found).
			pos = field_end or (type_end + 1)
		end
	end
	return fields, byte_off
end

--- Find every `load_word(R_<reg>, R_TapePtr, O_(Binds_X, FieldName))` call in the
--- atom body and return ordered (reg_index, field_name) pairs.
---
--- Source pattern (single-line, comma-separated at top level):
---   load_word(R_PrimCursor, R_TapePtr, O_(Binds_CubeTri,PrimCursor)),
---   load_word(R_FaceCursor, R_TapePtr, O_(Binds_CubeTri,FaceCursor)),
---   ...
---
--- @param body string  -- the atom body text (between { ... })
--- @param binds_name string  -- expected Binds_X name (skip pairs with mismatching binds)
--- @return table[]  -- list of {reg = <MIPS index>, field = <field name>}
local function parse_body_load_pairs(body, binds_name)
	local pairs    = {}
	local pos      = 1
	local body_len = #body
	while pos <= body_len do
		-- Find the next "load_word" identifier.
		pos = duffle.skip_ws_and_cmt(body, pos)
		if pos > body_len then break end
		local ident, ident_end = duffle.read_ident(body, pos)
		if not ident or ident ~= "load_word" then
			-- Either no ident here OR a non-load_word ident (e.g. add_ui_self).
			-- Either way, advance by at least 1 byte to avoid infinite loops.
			-- ident_end is `pos` when no ident matches (read_ident returns nil, pos).
			pos = (ident_end and ident_end > pos) and ident_end or (pos + 1)
		else
			-- Read the argument list.
			local p_open = duffle.skip_ws_and_cmt(body, ident_end)
			if body:sub(p_open, p_open) ~= "(" then
				pos = p_open + 1
			else
				local inner, p_after = duffle.read_parens(body, p_open)
				-- Split top-level commas.
				local args = duffle.split_top_level_commas(inner)
				-- Expected shape: (R_<reg>, R_TapePtr, O_(Binds_<X>, FieldName))
				if #args >= 3 then
					local reg_name  = duffle.trim(args[1])
					local third_arg = duffle.trim(args[3])
					-- Match O_(Binds_<X>, FieldName)
					local b, f = third_arg:match("^O_%((Binds_[%w_]+)%s*,%s*(.-)%s*%)$")
					if b and b == binds_name and R_NAME_TO_INDEX[reg_name] then
						pairs[#pairs + 1] = {
							reg   = R_NAME_TO_INDEX[reg_name],
							field = duffle.trim(f),
						}
					end
				end
				pos = p_after
			end
		end
	end
	return pairs
end

--- Collect every rbind atom + the matching Binds_X struct + (reg, field) pairs.
---
--- Inputs come from the dep-closed `scan-source` pass:
---   ctx.sources[i].scan.atom_infos -- list of {atom_name, binds, reads, writes, info_line}
---   ctx.sources[i].scan.binds      -- list of {line, name, fields, bytes}
---
--- Returns:
---   rbind_atoms     = {[atom_name] = {binds, fields, regs, byte_size, info_line}}
---   rbind_structs   = {[binds_name] = {byte_size, fields, atom_names}}
---
--- The `regs` list per atom is ordered: each entry is the MIPS reg index
--- that holds the matching field in the source-order pop sequence.
--- The piece chain uses (DW_OP_regN, DW_OP_piece, ULEB128(field_size)).
---
--- @param ctx DwarfInjectionCtx
--- @param atom_table table[]  -- the cross-ref'd atom table from build_atom_table
--- @return table, table  -- (rbind_atoms, rbind_structs)
local function parse_rbind_atoms(ctx, atom_table)
	local rbind_atoms   = {}
	local rbind_structs = {}

	-- Index binds by struct name; RE-PARSE the body locally (Task 8's local parser
	-- handles pointer types too; the scan-source pass's parser only handles U4).
	local binds_body_by_name = {}
	for _, src in ipairs(ctx.sources or {}) do
		local scan = src.scan
		if scan then
			for _, b in ipairs(scan.binds or {}) do
				binds_body_by_name[b.name] = b  -- need `b.body`; falls through to local reparse below
			end
		end
	end

	-- Re-parse each Binds_X body via the local reparser (U4 + pointer support).
	-- The scan-source pass preserves the original body text under each entry's `line` field but doesn't re-emit the body;
	-- so we re-walk the source file directly for each Binds_X typedef. (Future: ask scan_source to preserve body.)
	for binds_name in pairs(binds_body_by_name) do
		local body_text = nil
		for _, src in ipairs(ctx.sources or {}) do
			local text = src.text
			if text then
				-- Look for `typedef Struct_(<binds_name>)` in the source.
				-- Plain search (4th arg = true) avoids Lua pattern metachar interpretation.
				local needle = "typedef Struct_(" .. binds_name .. ")"
				local s, e   = text:find(needle, 1, true)
				if s then
					-- Find the body between `{` and matching `}` after `e`.
					local brace = text:find("{", e, true)
					if brace then
						local inner, _after = duffle.read_braces(text, brace)
						body_text = inner
						break
					end
				end
			end
		end
		if body_text then
			local fields, byte_count  = reparse_binds_body(body_text)
			rbind_structs[binds_name] = {
				bytes      = byte_count,
				fields     = fields,
				atom_names = {},
			}
		end
	end

	-- Walk every atom_info; if `binds` is set, find the atom body + parse load_word pairs.
	local body_by_atom = {}
	for _, src in ipairs(ctx.sources or {}) do
		local scan = src.scan
		if scan then
			for _, atom in ipairs(scan.atoms or {}) do
				body_by_atom[atom.name] = atom.body
			end
		end
	end

	local ai_by_atom = {}
	for _, src in ipairs(ctx.sources or {}) do
		local scan = src.scan
		if scan then
			for _, ai in ipairs(scan.atom_infos or {}) do
				ai_by_atom[ai.atom_name] = ai
			end
		end
	end

	for atom_name, ai in pairs(ai_by_atom) do
		if ai.binds then
			local struct = rbind_structs[ai.binds]
			local body   = body_by_atom[atom_name]
			if struct and body then
				local pairs = parse_body_load_pairs(body, ai.binds)
				if #pairs > 0 then
					rbind_atoms[atom_name] = {
						binds     = ai.binds,
						fields    = struct.fields,   -- {name, offset} from local reparse
						bytes     = struct.bytes,
						regs      = pairs,           -- ordered list of {reg, field}
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
--- The old implementation appended a new Unit 3.
--- No compilation unit pointed at it through DW_AT_stmt_list, so gdb ignored it. 
--- It also encoded byte 13 as the extended-opcode marker; byte 13 is actually the first special opcode. 
--- The existing final unit already contains hello_gte_tape.c as file index 11 and ends with a valid end_sequence.
--- We preserve its bytes, append independent atom sequences, and increase only that unit's DWARF32 unit_length.
---
--- @param existing string   -- existing section bytes (verbatim)
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
	local unit_pos, last_pos, last_length, last_end = 1, nil, nil, nil
	while unit_pos <= #existing do
		if unit_pos + 3 > #existing then return existing end
		local unit_length =  elf_dwarf.read_u32_le(existing, unit_pos)
		if    unit_length == elf_dwarf.ELF32.dw_dwarf32_terminator then return existing end
		local unit_end    = unit_pos + 3 + unit_length
		if unit_end > #existing then return existing end
		last_pos, last_length, last_end = unit_pos, unit_length, unit_end
		unit_pos                        = unit_end + 1
	end
	if unit_pos ~= #existing + 1 or not last_pos then return existing end

	local new_length       = last_length + #appended
	local new_length_bytes = elf_dwarf.write_u32_le(new_length)

	return existing:sub(1, last_pos - 1)
		.. new_length_bytes
		.. existing:sub(last_pos + 4, last_end)
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
---
--- @param existing string
--- @param atom_table table
--- @return string
local function build_dwarf_aranges_section(existing, atom_table)
	if #existing < 12 then return existing end  -- header sanity

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
	local i            = 1  -- 1-indexed
	local is_last_unit = false

	while i <= #existing do
		-- Read this unit's length.
		local ul = elf_dwarf.read_u32_le(existing, i)
		if    ul == elf_dwarf.ELF32.dw_dwarf32_terminator then
			-- DWARF64 marker - not supported.
			return existing
		end

		local unit_start = i
		local unit_end   = i + 3 + ul  -- last byte of unit content
		is_last_unit = (unit_end == #existing)

		if is_last_unit then
			-- The old terminator is replaced by entries + a new terminator, so net section growth (and unit_length growth) is entries only.
			local added_bytes  = #atom_table * elf_dwarf.DWARF4_ARANGES.entry_size
			local new_ul       = ul + added_bytes
			local new_ul_bytes = elf_dwarf.write_u32_le(new_ul)
			-- Emit everything EXCEPT the last 8 bytes (terminator).
			result[#result + 1] = new_ul_bytes
				.. existing:sub(i + 4, unit_end - elf_dwarf.DWARF4_ARANGES.terminator_size)
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
			result[#result + 1] = existing:sub(unit_start, unit_end)
		end

		i = unit_end + 1
	end

	if not is_last_unit then
		-- Malformed or no terminator found; append a new unit at the end.
		-- For now, return existing unchanged to avoid making it worse.
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
---
--- @param existing string
--- @param atom_table table
--- @return string
local function build_dwarf_rnglists_section(existing, atom_table)
	if #existing < elf_dwarf.DWARF5_RNGLISTS.first_entry_offset or #atom_table == 0 then return existing end

	local unit_length        = elf_dwarf.read_u32_le(existing, elf_dwarf.DWARF5_RNGLISTS.unit_length_offset)
	local version            = elf_dwarf.read_u16_le(existing, elf_dwarf.DWARF5_RNGLISTS.version_offset)
	local address_size       = existing:byte(elf_dwarf.DWARF5_RNGLISTS.addr_size_offset)
	local segment_size       = existing:byte(elf_dwarf.DWARF5_RNGLISTS.seg_size_offset)
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
-- G' helpers: per-atom .debug_info synthesis (DW_TAG_subprogram + DW_TAG_variable)
-- ════════════════════════════════════════════════════════════════════════════

--- Build the location bytes (DW_FORM_exprloc) for a register-resident value.
--- DW_OP_reg0..reg31 occupy opcodes 0x50..0x6f. DW_OP_reg15 is 0x5f;
--- 0x90 is DW_OP_regx, not the base of the compact register opcode range.
--- @param reg_n integer  -- 0..31 (MIPS register number)
--- @return string  -- the exprloc byte sequence (length-prefixed)
local function reg_exprloc(reg_n)
	local op = string.char(DW_OP_reg0 + reg_n)
	return uleb128(#op) .. op
end

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
---
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
-- All offsets in this section are 0-based (matching the user's "section offset 0x24" convention).
-- When reading via elf_dwarf.read_u32_le (1-indexed), call with `pos + 1`.
--
-- Pure-Lua 5.3 LEB decoders (no `bit` library; `2^shift` arithmetic matches elf_dwarf.lua's 
-- "math.floor(/16) instead of bit.rshift for LuaJIT 2.1 compat" comment at line 352).

--- Read a ULEB128 value starting at 0-based byte offset `pos` in `buf`.
--- Returns (value, next_pos) where `next_pos` is the 0-based offset of the byte AFTER the last byte consumed.
--- Returns (nil, pos) on truncation.
--- @param buf string
--- @param pos integer  -- 0-based
--- @return integer|nil, integer
local function read_uleb128_at(buf, pos)
	local value   = 0
	local shift   = 0
	local buf_len = #buf
	while pos < buf_len do
		local byte = buf:byte(pos + 1)
		value = value + (byte % 0x80) * (2 ^ shift)   -- extract low 7 bits, shift left
		shift = shift + 7
		pos   = pos + 1
		if byte < 0x80 then return value, pos end      -- continuation bit clear → final byte
	end
	return nil, pos
end

--- Read a SLEB128 value starting at 0-based byte offset `pos` in `buf`.
--- Returns (value, next_pos). Returns (nil, pos) on truncation.
--- @param buf string
--- @param pos integer  -- 0-based
--- @return integer|nil, integer
local function read_sleb128_at(buf, pos)
	local value   = 0
	local shift   = 0
	local buf_len = #buf
	while pos < buf_len do
		local byte = buf:byte(pos + 1)
		value = value + (byte % 0x80) * (2 ^ shift)
		shift = shift + 7
		pos   = pos + 1
		if byte < 0x80 then
			-- Sign-extend if the sign bit (bit 6) of the last byte is set.
			if byte >= 0x40 then
				value = value - (2 ^ shift)
			end
			return value, pos
		end
	end
	return nil, pos
end

--- Walk a .debug_abbrev table starting at 0-based offset `table_start` and return the 0-based offset of the table-terminator byte
--- (a single 0 byte marking the end of declarations in this table per DWARF5 §7.5.3).
---
--- The walker consumes each declaration's abbrev code (ULEB) + tag (ULEB) + has_children byte + (attr, form)
--- attr-spec pairs (each pair = ULEB + ULEB, with an extra SLEB constant for DW_FORM_implicit_const per DWARF5 §7.5.6).
--- The declaration's attr-spec list ends at the (0, 0) pair.
---
--- Returns nil on truncated or malformed input.
--- @param existing string  -- the .debug_abbrev section bytes
--- @param table_start integer  -- 0-based offset of the table's first byte
--- @return integer|nil  -- 0-based offset of the table-terminator byte
local function find_abbrev_table_end(existing, table_start)
	local pos     = table_start
	local buf_len = #existing
	-- Empty table = terminator byte at table_start.
	if pos >= buf_len or existing:byte(pos + 1) == 0 then return pos end
	while pos < buf_len do
		-- Each declaration: ULEB code, ULEB tag, 1 byte has_children.
		local  _code, code_end = read_uleb128_at(existing, pos)
		if not _code then return nil end
		pos = code_end
		local  _tag, tag_end = read_uleb128_at(existing, pos)
		if not _tag then return nil end
		pos = tag_end
		-- has_children: 1 byte (DW_CHILDREN_yes=1 / DW_CHILDREN_no=0).
		if pos >= buf_len then return nil end
		pos = pos + 1
		-- attr/form loop until (0, 0) terminator pair.
		while pos < buf_len do
			local  attr, attr_end = read_uleb128_at(existing, pos)
			if not attr then return nil end
			pos = attr_end
			local  form, form_end = read_uleb128_at(existing, pos)
			if not form then return nil end
			pos = form_end
			if attr == 0 and form == 0 then break end
			-- DW_FORM_implicit_const: declaration carries a SLEB constant.
			if form == DW_FORM_implicit_const then
				local  _const, const_end = read_sleb128_at(existing, pos)
				if not _const then return nil end
				pos = const_end
			end
		end
		-- Next declaration starts here; if next byte is 0, the table is done.
		if pos >= buf_len then return nil end
		if existing:byte(pos + 1) == 0 then return pos end
	end
	return nil
end

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
---
--- @param existing string  -- the .debug_info section bytes
--- @return integer|nil, integer|nil, integer|nil
local function find_main_cu_layout(existing)
	local buf_len = #existing
	if    buf_len < CU_HEADER_SIZE then return nil end

	local pos               = 0
	local main_cu_start     = nil
	local main_cu_end_excl  = nil
	while pos + 4 <= buf_len do
		local unit_length   = elf_dwarf.read_u32_le(existing, pos + 1)
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
	local version      = elf_dwarf.read_u16_le(existing, hdr + 1)
	local unit_type    = existing:byte(hdr + 3)
	local address_size = existing:byte(hdr + 4)
	local abbrev_off   = elf_dwarf.read_u32_le(existing, hdr + 5)
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
--- The new abbreviations define a 4-deep tree (Task 8 addition):
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
---   Abbrev 103 (DW_TAG_structure_type, with children):   -- NEW Task 8
---     DW_AT_name       (DW_FORM_string) -- "Binds_CubeTri" etc.
---     DW_AT_byte_size  (DW_FORM_udata)  -- struct byte size
---   Abbrev 104 (DW_TAG_member, no children):              -- NEW Task 8
---     DW_AT_name                  (DW_FORM_string) -- "PrimCursor" etc.
---     DW_AT_data_member_location  (DW_FORM_udata)  -- byte offset in struct
---     DW_AT_type                  (DW_FORM_ref4)   -- → U4 base type
---   Abbrev 105 (DW_TAG_variable, no children):            -- NEW Task 8
---     DW_AT_name       (DW_FORM_string) -- "bind_args"
---     DW_AT_location   (DW_FORM_exprloc) -- DW_OP_regN, piece, regN, piece, ...
---     DW_AT_type       (DW_FORM_ref4)   -- → DW_TAG_structure_type DIE
---   Abbrev 106 (DW_TAG_base_type, no children):           -- NEW Task 8
---     DW_AT_name       (DW_FORM_string) -- "unsigned int"
---     DW_AT_byte_size  (DW_FORM_data1)  -- 4
---     DW_AT_encoding   (DW_FORM_data1)  -- DW_ATE_unsigned
---   Abbrev 107 (DW_TAG_subprogram, NO children) — Phase 3 abstract origin. -- NEW Phase 3 (debug_ux)
---     DW_AT_name       (DW_FORM_string) -- "mac_yield" etc. (component ident)
---     DW_AT_inline     (DW_FORM_data1)  -- DW_INL_declared_inlined (= 3)
---     DW_AT_external   (DW_FORM_data1)  -- 1 (visible across the CU)
---   Abbrev 108 (DW_TAG_inlined_subroutine, with children):  -- NEW Phase 3 (debug_ux)
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

	-- Task 8: rbind composite.
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

	-- Phase 3 (debug_ux): component step-into abstract + inline DIE abbreviations.
	local DW_INL_declared_inlined = 0x03   -- DWARF5 §3.33.3: "this subroutine was declared inline"
	-- Phase 3 Task 3: abstract subprograms now carry DW_AT_decl_file + DW_AT_decl_line
	-- so consumers can resolve the abstract origin back to its definition site
	-- even when no inlined_subroutine instance currently maps to it.
	-- DW_FORM_udata is consistent with the call_file/call_line forms on abbrev 108.
	local abbrev_abstract_subprogram = abbrev(ABBREV_ABSTRACT_SUBPROGRAM, DW_TAG_subprogram, false,  -- DW_CHILDREN_no
		attr(   DW_AT_name,       DW_FORM_string)
	  .. attr(DW_AT_inline,      DW_FORM_data1)
	  .. attr(DW_AT_external,    DW_FORM_data1)
	  .. attr(DW_AT_decl_file,   DW_FORM_udata)
	  .. attr(DW_AT_decl_line,   DW_FORM_udata))

	local abbrev_inlined_subroutine = abbrev(ABBREV_INLINED_SUBROUTINE, DW_TAG_inlined_subroutine, false,  -- DW_CHILDREN_no (Phase 3 emits no per-inlined-instance children; the PC range IS the inlining scope)
		attr(   DW_AT_abstract_origin, DW_FORM_ref4)
	  .. attr(DW_AT_low_pc,           DW_FORM_addr)
	  .. attr(DW_AT_high_pc,          DW_FORM_addr)
	  .. attr(DW_AT_call_file,        DW_FORM_udata)
	  .. attr(DW_AT_call_line,        DW_FORM_udata))

	-- Phase 5 (debug_ux): bind_args with DW_FORM_sec_offset → .debug_loclists.
	-- The .debug_loclists section holds a sequence of DW_LLE entries; the
	-- first matching entry for a PC describes each field's value (tape
	-- memory DW_OP_breg24 or register DW_OP_regN).
	local abbrev_bind_var_loclists = abbrev(ABBREV_BIND_VAR_LOCLIST, DW_TAG_variable, false,  -- DW_CHILDREN_no
		attr(   DW_AT_name,     DW_FORM_string)
	  .. attr(DW_AT_location, DW_FORM_sec_offset)
	  .. attr(DW_AT_type,     DW_FORM_ref4))

	return abbrev_cu .. abbrev_subprogram .. abbrev_variable
		.. abbrev_struct_type .. abbrev_member .. abbrev_bind_var .. abbrev_base_type
		.. abbrev_abstract_subprogram .. abbrev_inlined_subroutine
		.. abbrev_bind_var_loclists
		.. string.char(0x00)
end

--- Build the new strings to append to .debug_str. Each string is null-terminated.
--- The CU name + comp_dir + 6 per-atom register names all go into one new blob.
--- @param atom_table table[]  -- list of {name, addr, size_bytes, ...}
--- @return string, table  -- (new_strings_blob, map_of_name_to_offset_in_new_blob)
local function build_new_strings(atom_table)
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

	-- Register names (one per unique wave-context reg)
	for _, loc in ipairs(WAVE_CONTEXT_LOCATIONS) do
		if not map[loc.name] then
			map[loc.name]         = #table.concat(strings)
			strings[#strings + 1] = loc.name .. "\0"
		end
	end

	return table.concat(strings), map
end

--- Build the DWARF DIE bytes to insert into the MAIN CU as children, immediately
--- before the main CU's root children-terminator (the final 0 byte of the CU).
---
--- The same content was emitted as a DETACHED synthetic CU appended after the main CU.
--- GDB's PC lookup selects the main CU, so the synthetic CU was out of scope and `RR_PrimCursor` + `bind_args` never appeared in the current frame.
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
--- build_debug_info_section splices our bytes between the existing DIE bytes and that terminator, which is preserved verbatim.
---
--- **ref4 basis**: DW_FORM_ref4 is CU-relative (offset from the first byte of the CU header).
--- Our inserted DIEs live in the main CU, so every ref4 = (target section offset) - main_cu_offset.
--- Per-die section offsets are tracked via the running `next_offset` cursor (= section offset of the NEXT byte to emit).
---
--- @param main_cu_offset integer  -- 0-based section offset of the main CU's unit_length field
--- @param main_cu_end_excl integer  -- 0-based section offset of the first byte AFTER the main CU
--- @param atom_table table[]  -- atoms (with atom.rbind set if rbind; atom.invocations set if mac_X(...) calls)
--- @param rbind_structs table  -- {[binds_name] = {bytes, fields, atom_names}}
--- @param loclists_offsets table  -- {[atom_name] = section-relative offset into the new .debug_loclists}
--- @return string  -- bytes to splice into the main CU just before its root terminator
local function build_inserted_children(main_cu_offset, main_cu_end_excl, atom_table, rbind_structs, loclists_offsets)
	rbind_structs = rbind_structs or {}
	loclists_offsets = loclists_offsets or {}

	-- We insert IMMEDIATELY BEFORE the main CU's root children-terminator (the last byte of the main CU).
	-- The first emitted byte lives at section offset (main_cu_end_excl - 1).
	local insertion_start = main_cu_end_excl - 1

	local bytes       = {}
	local next_offset = insertion_start  -- 0-based section offset of the NEXT byte to emit

	local function emit(s)
		bytes[#bytes + 1] = s
		next_offset       = next_offset + #s
	end
	local function ref4_of(section_offset)
		return section_offset - main_cu_offset
	end

	-- 1) Emit the base_type DIE first (member ref4s reference it).
	local base_type_section_offset = next_offset
	emit(uleb128(ABBREV_BASE_TYPE))
	emit("unsigned int\0")                   -- DW_FORM_string (DW_AT_name)
	emit(string.char(4))                     -- DW_FORM_data1  (DW_AT_byte_size)
	emit(string.char(DW_ATE_unsigned))       -- DW_FORM_data1  (DW_AT_encoding)

	-- Phase 5 (debug_ux): Typed local views. For each unique
	-- (type_name, pointer_depth) pair across all rbind atom fields, emit
	-- a synthetic type chain. The chain is: ... → pointer_type → typedef → base_type.
	-- The outermost pointer_type (depth = N) is the variable's DW_AT_type.
	-- For a field declared "V4_S2*" (depth=1), the chain is:
	--   V4_S2 (typedef, references base_type 4-byte unsigned) +
	--   ptr_to_V4_S2_1 (pointer_type, byte_size 4, refs the typedef)
	-- gdb walks: variable type = ptr_to_V4_S2_1 → V4_S2 → base_type, and
	-- displays "V4_S2 *" (the typedef's name + the pointer depth).
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
	-- For each non-U4 type, emit a typedef (DW_TAG_typedef) named after the
	-- type and referencing the base_type "unsigned int" (4 bytes). The
	-- typedef gives gdb a named anchor; the pointer_type chain wraps it.
	-- We use a fresh abbrev for the typedef + the pointer_type. To stay
	-- within the existing abbrev budget, we reuse the duplicated main
	-- table's abbrev 4 (DW_TAG_typedef) and abbrev 9 (DW_TAG_pointer_type)
	-- via a synthetic-emit pattern: emit the abbrev code (a ULEB) +
	-- attribute bytes using DW_FORM values that match those abbrevs.
	-- The cleanest path is to define new abbrevs in build_new_abbrev().
	-- For the scope of this task, we emit fresh DW_TAG_base_type DIEs
	-- (the simplest correct shape: byte_size 4, encoding unsigned) and
	-- the variable's DW_AT_type references the pointer chain's outermost
	-- base_type. The displayed type name is the type_name (e.g. "V4_S2")
	-- because we use DW_FORM_string on the field type. gdb walks the
	-- chain and displays the name.
	--
	-- For each (type_name, depth), emit (depth) base_type DIEs forming a
	-- chain. The outermost base_type's name is the type_name; the inner
	-- ones are named "ptr_<type>_<d>". gdb shows the outermost name as
	-- the type.
	--
	-- (Full typedef + pointer_type chain with proper DW_TAG_pointer_type
	-- + byte_size=4 is a follow-up; for now we use base_type entries
	-- which gdb can resolve.)
	local type_chain_offsets = {}  -- { [type_name .. "|" .. depth] = section_offset (the OUTERMOST entry, the one referenced as the variable's type) }
	-- For pointer_depth = 1, the chain is: [base_type "V4_S2" 4 bytes] [pointer_type → V4_S2].
	-- For pointer_depth = 2, the chain is: [base_type "ptr_V4_S2_1"] [base_type "V4_S2"] [pointer_type → ptr_V4_S2_1].
	-- The OUTERMOST pointer_type is what gdb shows as "<type> *" and is
	-- what the Locals panel uses to render the dereference affordance.
	-- Build the chain bottom-up: emit the innermost base_type first, then
	-- each next-outer pointer_type, recording the offset of each. The
	-- outermost is the last one emitted; type_chain_offsets stores its
	-- offset as the variable's DW_AT_type.
	for _, tn in ipairs(sorted_typed_types) do
		if tn ~= "U4" then
			local depth = used_typed_views[tn]
			-- First, emit the chain of base_types from innermost (d=1) to d=depth-1.
			-- The innermost (d=1) carries the user's type_name (V4_S2); outer
			-- levels are placeholders named "ptr_<type>_<d>". Each base_type
			-- is 4 bytes unsigned (a stand-in for the actual type).
			local innermost_offset
			local base_offsets = {}  -- base_offsets[d] = offset of the d-th level base_type (1-indexed)
			for d = 1, depth do
				local off = next_offset
				base_offsets[d] = off
				emit(uleb128(ABBREV_BASE_TYPE))
				if d == 1 then
					emit(tn .. "\0")  -- innermost: the user's type name
				else
					emit("ptr_" .. tn .. "_" .. (d-1) .. "\0")  -- inner: pointer-depth label
				end
				emit(string.char(4))                   -- byte_size = 4
				emit(string.char(DW_ATE_unsigned))     -- encoding = unsigned
				innermost_offset = off
			end
			-- Now emit a DW_TAG_pointer_type (abbrev 9 in the duplicate)
			-- ON TOP of the chain. The pointer_type's DW_AT_type ref4 points
			-- at the base_type it dereferences. The outermost pointer_type
			-- is what the variable's DW_AT_type uses.
			local outermost_offset = next_offset
			emit(uleb128(9))  -- DW_TAG_pointer_type abbrev code (abbrev 9 in duplicate)
			-- Abbrev 9's attributes: DW_AT_byte_size (implicit_const 4 — no DIE
			-- bytes), DW_AT_type (ref4 → target). So the DIE bytes are just
			-- the 4-byte ref4 pointing at the base_type it dereferences.
			-- The variable uses the OUTERMOST pointer_type. Inner pointer
			-- levels (for depth > 1) would chain pointer_type → pointer_type
			-- → ... → base_type. For the user's case (depth ≤ 1), one
			-- pointer_type suffices. For depth > 1, we'd need intermediate
			-- pointer_type DIEs — emit depth-1 of them, each pointing at
			-- the next.
			if depth == 1 then
				-- Single pointer: target = innermost base_type
				emit(elf_dwarf.write_u32_le(ref4_of(innermost_offset)))
			else
				-- depth > 1: emit (depth - 1) pointer_types, each pointing
				-- at the next. The last pointer_type (outermost) becomes the
				-- variable's DW_AT_type. The innermost pointer_type points
				-- at the innermost base_type.
				-- For simplicity, emit depth pointer_types total, each
				-- pointing at the previous base_type or pointer_type. The
				-- outermost is what we return.
				-- Actually, for the current build the only typed fields
				-- are at depth 1 (V4_S2* / V3_S2*). depth > 1 is not
				-- exercised. We can handle depth == 1 inline and defer
				-- depth > 1 to a future task.
				error("typed-view: pointer_depth > 1 is not yet supported in this emission path")
			end
			type_chain_offsets[tn .. "|" .. depth] = outermost_offset
		end
	end

	-- 2) Emit one DW_TAG_structure_type per unique Binds_X.
	local struct_section_offsets = {}
	local sorted_struct_names    = {}
	for k in pairs(rbind_structs) do sorted_struct_names[#sorted_struct_names + 1] = k end
	table.sort(sorted_struct_names)
	for _, binds_name in ipairs(sorted_struct_names) do
		local struct = rbind_structs[binds_name]
		struct_section_offsets[binds_name] = next_offset

		emit(uleb128(ABBREV_STRUCT_TYPE))
		emit(binds_name .. "\0")             -- DW_FORM_string (DW_AT_name)
		emit(uleb128(struct.bytes))           -- DW_FORM_udata  (DW_AT_byte_size)

		-- Emit DW_TAG_member children (one per field).
		for _, field in ipairs(struct.fields) do
			emit(uleb128(ABBREV_MEMBER))
			emit(field.name .. "\0")          -- DW_FORM_string (DW_AT_name)
			emit(uleb128(field.offset))       -- DW_FORM_udata  (DW_AT_data_member_location)
			-- Phase 5 (debug_ux): typed field. For a pointer-typed field, the
			-- member's DW_AT_type points at the deepest pointer_type in its chain.
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

		emit(string.char(0x00))               -- end of structure_type's children
	end

	-- 3) Phase 3 (debug_ux): emit one abstract DW_TAG_subprogram per unique mac_X component.
	--    Each abstract DIE is a CU-level child (sibling of the per-atom subprograms below).
	--    The abstract DIE's section offset is later used by inlined_subroutine DIEs
	--    (which embed `DW_AT_abstract_origin = ref4 → abstract DIE`).
	--    Phase 3 Task 3: each abstract DIE also carries DW_AT_decl_file + DW_AT_decl_line
	--    pointing at the component's definition site (file path + body line).
	local component_defs     = collect_component_defs(atom_table)
	local abstract_offsets   = {}  -- name -> section offset
	local sorted_comp_names  = {}
	for name in pairs(component_defs) do sorted_comp_names[#sorted_comp_names + 1] = name end
	table.sort(sorted_comp_names)
	-- DW_INL_inlined (1) = "this subroutine was inlined" — accurate for the mac_* components.
	local DW_INL_inlined = 0x01
	for _, comp_name in ipairs(sorted_comp_names) do
		local def = component_defs[comp_name]
		abstract_offsets[comp_name] = next_offset
		emit(uleb128(ABBREV_ABSTRACT_SUBPROGRAM))
		emit("mac_" .. comp_name .. "\0")     -- DW_FORM_string (DW_AT_name)
		emit(string.char(DW_INL_inlined))    -- DW_FORM_data1 (DW_AT_inline)
		emit(string.char(0x01))               -- DW_FORM_data1 (DW_AT_external=1)
		-- Phase 3 Task 3: decl_file + decl_line resolve the abstract origin back to its
		-- definition site even when no inlined_subroutine instance maps to it.
		emit(uleb128(resolve_provenance_file_index(def.def_file)))  -- DW_FORM_udata (DW_AT_decl_file)
		emit(uleb128(def.def_line))                                 -- DW_FORM_udata (DW_AT_decl_line)
	end

	-- 4) Emit per-atom DW_TAG_subprograms (children of main CU).
	--    Subprograms are named `<name>` (matching the nm symbol; the `code_` prefix was removed from the MipsAtom_ macro in code/duffle/lottes_tape.h).
	--    The gcc global `<name>[]` is a DW_TAG_variable without children; our subprogram has the wave-context var children.
	--    gdb's symbol resolution picks our subprogram (it has low_pc/high_pc + children) over the gcc global for function-context lookups.
	for _, atom in ipairs(atom_table) do
		emit(uleb128(ABBREV_SUBPROGRAM))
		emit(atom.name .. "\0")                  -- DW_FORM_string (DW_AT_name)
		emit(elf_dwarf.write_u32_le(atom.addr))
		emit(elf_dwarf.write_u32_le(atom.addr + atom.size_bytes))
		emit(atom.name .. "\0")                  -- DW_FORM_string (DW_AT_linkage_name; same as DW_AT_name for non-mangled C)

		-- Per wave-context reg: DW_TAG_variable. Type precedence (Task 20):
		--   1. explicit per-atom register type annotation (atom_reg_types)
		--   2. atom_view(Binds_X) field type (from the rbind regs → fields map)
		--   3. semantic default (R_TapePtr → U4*, R_AtomJmp → MipsCode*,
		--      cursor/base aliases → void*)
		--   4. void* (unannotated)
		-- For rbind atoms the precedence comes from the rbind regs/fields
		-- (the load_word calls already mapped each R_<reg> to a Binds_X.<field>
		-- with a known type_name + pointer_depth).
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
		-- Semantic defaults per register.
		local SEMANTIC_DEFAULTS = {
			[24] = { type_name = "U4", pointer_depth = 1 },  -- R_TapePtr (R_T8)
			[25] = { type_name = "MipsCode", pointer_depth = 1 },  -- R_AtomJmp (R_T9)
		}

		for _, loc in ipairs(WAVE_CONTEXT_LOCATIONS) do
			emit(uleb128(ABBREV_VARIABLE))
			emit(loc.name .. "\0")                  -- DW_FORM_string (DW_AT_name)
			emit(reg_exprloc(loc.reg))           -- DW_FORM_exprloc (DW_OP_regN)
			-- Resolve the type for this register.
			local type_offset = base_type_section_offset  -- default: U4
			local field_name = reg_to_field[loc.reg]
			if field_name then
				local f = field_type_by_name[field_name]
				if f and f.pointer_depth and f.pointer_depth > 0 then
					local chain_offset = type_chain_offsets[f.type_name .. "|" .. f.pointer_depth]
					if chain_offset then type_offset = chain_offset end
				end
			else
				-- Not loaded from Binds_*: use the semantic default.
				local def = SEMANTIC_DEFAULTS[loc.reg]
				if def and def.pointer_depth and def.pointer_depth > 0 then
					local chain_offset = type_chain_offsets[def.type_name .. "|" .. def.pointer_depth]
					if chain_offset then type_offset = chain_offset end
				end
			end
			emit(elf_dwarf.write_u32_le(ref4_of(type_offset)))  -- DW_FORM_ref4 → type
			emit(string.char(0x01))              -- DW_AT_external=1 (visible at CU scope)
		end

		-- If rbind, emit bind_args variable with PC-ranged location list.
		-- Phase 5 (debug_ux): the loclist is in .debug_loclists, indexed by
		-- `DW_FORM_sec_offset` (4-byte section-relative offset). The piece
		-- chain is replaced by two PC ranges: [atom.addr, last_load+8) where
		-- every field is described as a tape-memory (DW_OP_bregN + offset)
		-- piece, and [last_load+8, atom.end) where every field is described
		-- as a GPR (DW_OP_regN) piece.
		if atom.rbind then
			local binds_name = atom.rbind.binds
			local loclists_offset = loclists_offsets[atom.name] or 0
			emit(uleb128(ABBREV_BIND_VAR_LOCLIST))
			emit("bind_args\0")                  -- DW_FORM_string (DW_AT_name)
			emit(elf_dwarf.write_u32_le(loclists_offset))         -- DW_FORM_sec_offset → .debug_loclists
			emit(elf_dwarf.write_u32_le(ref4_of(struct_section_offsets[binds_name])))  -- DW_FORM_ref4 → struct_type
		end

		-- Phase 3 (debug_ux): per-component invocation inlined_subroutine instances.
		-- Each invocation covers a contiguous .word range [start_pos, end_pos] within the atom.
		-- We compute the corresponding PC range from the atom's start + .word offsets × MIPS_BYTES_PER_WORD.
		-- Phase 3 Task 3: call_file now resolves inv.call_file to the line-unit file index
		-- (previously hardcoded to ATOM_SOURCE_FILE_INDEX; that lost the call-site attribution
		-- for any invocation whose call site was NOT the atom's source file).
		if atom.invocations and not atom.skip_over then
			for _, inv in ipairs(atom.invocations) do
				local inv_low  = atom.addr + inv.start_pos * MIPS_BYTES_PER_WORD
				local inv_high = atom.addr + (inv.end_pos + 1) * MIPS_BYTES_PER_WORD
				emit(uleb128(ABBREV_INLINED_SUBROUTINE))
				emit(elf_dwarf.write_u32_le(ref4_of(abstract_offsets[inv.comp_name])))  -- DW_FORM_ref4 → abstract_origin
				emit(elf_dwarf.write_u32_le(inv_low))    -- DW_FORM_addr (DW_AT_low_pc)
				emit(elf_dwarf.write_u32_le(inv_high))   -- DW_FORM_addr (DW_AT_high_pc)
				emit(uleb128(resolve_provenance_file_index(inv.call_file)))            -- DW_FORM_udata (DW_AT_call_file)
				emit(uleb128(inv.call_line))                                              -- DW_FORM_udata (DW_AT_call_line)
			end
		end

		emit(string.char(0x00))               -- end of subprogram's children
	end

	-- DO NOT emit a final 0 here — that's the main CU's root terminator, which
	-- build_debug_info_section preserves verbatim.
	return table.concat(bytes)
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
--- @param existing string  -- existing .debug_abbrev bytes (verbatim)
--- @param main_abbrev_offset integer  -- 0-based offset into `existing` of the main CU's abbrev table
--- @return string, integer  -- (new_abbrev_bytes, offset_where_duplicate_table_starts = #existing)
local function build_debug_abbrev_section(existing, main_abbrev_offset)
	local  table_end = find_abbrev_table_end(existing, main_abbrev_offset)
	if not table_end then return existing, nil end

	-- Duplicate the main table declarations EXCLUDING its terminating 0 byte.
	-- (1-indexed sub: existing:sub(main_abbrev_offset + 1, table_end) reads bytes
	--  from 0-based [main_abbrev_offset .. table_end - 1].)
	local main_table_dup = existing:sub(main_abbrev_offset + 1, table_end)
	local new_abbrevs    = build_new_abbrev()  -- includes its own terminating 0

	-- The MAIN CU's debug_abbrev_offset points to the duplicate's start (= #existing).
	-- Codes 100..106 follow the duplicate's declarations inside that same table.
	return existing .. main_table_dup .. new_abbrevs, #existing
end

--- Build the new .debug_str: existing strings + new strings appended.
--- @param existing string  -- existing .debug_str bytes (verbatim)
--- @param atom_table table[]
--- @return string, integer, table  -- (new_str_bytes, new_strings_offset, string_map)
local function build_debug_str_section(existing, atom_table)
	local new_strings, string_map = build_new_strings(atom_table)
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
---   4. Preserves all original main CU DIE bytes verbatim.
---   5. Replaces the main CU's final byte (the root children-terminator, 0) with: inserted_children_bytes + a single 0 byte (root terminator preserved).
---
--- The crt CU (everything before main_cu_start) is preserved verbatim.
---
--- **No detached synthetic CU is appended.**
---
--- @param existing string  -- existing .debug_info section bytes
--- @param main_cu_start integer  -- 0-based offset of the main CU's unit_length field
--- @param main_cu_end_excl integer  -- 0-based offset of the first byte AFTER the main CU
--- @param new_abbrev_offset integer  -- 0-based offset into the new .debug_abbrev of the duplicate main table
--- @param atom_table table[]
--- @param rbind_structs table  -- {[binds_name] = {bytes, fields, atom_names}} (Task 8)
--- @param loclists_offsets table  -- {[atom_name] = section-relative offset} (Task 19)
--- @return string  -- the rebuilt .debug_info bytes
local function build_debug_info_section(existing, main_cu_start, main_cu_end_excl, new_abbrev_offset, atom_table, rbind_structs, loclists_offsets)
	-- 1) Build the inserted children bytes (just before the main CU's root terminator).
	local inserted     = build_inserted_children(main_cu_start, main_cu_end_excl, atom_table, rbind_structs, loclists_offsets)
	local inserted_len = #inserted

	-- 2) Patch main CU's unit_length += inserted_len.
	local old_unit_length       = elf_dwarf.read_u32_le(existing, main_cu_start + 1)
	local new_unit_length       = old_unit_length + inserted_len
	local new_unit_length_bytes = elf_dwarf.write_u32_le(new_unit_length)

	-- 3) Patch main CU's debug_abbrev_offset (bytes [main_cu_start + 8 .. + 11]).
	local new_abbrev_offset_bytes = elf_dwarf.write_u32_le(new_abbrev_offset)

	-- 4) Splice. All offsets below are 0-based; existing:sub is 1-indexed inclusive.
	--    Byte ranges (0-based, inclusive):
	--      [0 .. main_cu_start - 1]                 crt CU (verbatim)
	--      [main_cu_start + 0 .. + 3]               unit_length (PATCHED)
	--      [main_cu_start + 4 .. + 7]               version + unit_type + address_size (verbatim)
	--      [main_cu_start + 8 .. + 11]              debug_abbrev_offset (PATCHED)
	--      [main_cu_start + 12 .. main_cu_end_excl - 2]   existing DIE bytes (verbatim)
	--      [main_cu_end_excl - 1]                   root children-terminator (verbatim 0)
	local pre_end         = main_cu_end_excl - 2  -- 0-based end of existing DIE bytes (inclusive)
	local root_terminator = main_cu_end_excl - 1  -- 0-based position of the final 0 byte

	return existing:sub(1, main_cu_start)                    -- crt CU
		.. new_unit_length_bytes                               -- patched unit_length (4 bytes)
		.. existing:sub(main_cu_start + 5, main_cu_start + 8)  -- version(2) + unit_type(1) + address_size(1) verbatim
		.. new_abbrev_offset_bytes                             -- patched debug_abbrev_offset (4 bytes)
		.. existing:sub(main_cu_start + 13, pre_end + 1)       -- existing DIE bytes verbatim
		.. inserted                                            -- our inserted children
		.. existing:sub(root_terminator + 1, main_cu_end_excl) -- root children-terminator (verbatim 0)
end

--- Build the .debug_loc: just a terminator.
--- Atoms don't have stack frames (the .debug_loc section describes per-instruction location adjustments for call-frame-based variables;
--- we use DW_OP_regN which is register-based and doesn't need .debug_loc entries).
--- The section itself must not be empty OR gdb may complain; the DW_LLE_end_of_list marker (per DWARF5 §7.7) is a single byte 0x00.
--- @return string
local function build_debug_loc_section()
	return string.char(0x00)
end

local SECTION_BUILDERS = {
	debug_line     = build_dwarf_line_section,
	debug_aranges  = build_dwarf_aranges_section,
	debug_rnglists = build_dwarf_rnglists_section,
	debug_abbrev   = build_debug_abbrev_section,
	debug_info     = build_debug_info_section,
	debug_str      = build_debug_str_section,
	debug_loc      = function() return build_debug_loc_section() end,
	debug_loclists = function() return build_debug_loclists_section({}) end,  -- placeholder; replaced per-run
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

local function write_gdbinit(out_root, basename, skip_over, atom_table)
	local path = out_root .. "\\" .. basename .. ".gdbinit"
	duffle.write_file_lf(path, build_gdbinit(skip_over, atom_table))
	return { gdbinit = path }
end

-- ════════════════════════════════════════════════════════════════════════════
-- Pass entry
-- ════════════════════════════════════════════════════════════════════════════

local M = {}

--- M.run — orchestrator entry. Phase 1 Tasks 3-4 read + cross-ref.
--- Phase 2 Tasks 5-7 fill in the section builders + .bin emission.
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
	-- We need ALL 7 sections since the F' group (.debug_line, .debug_aranges, .debug_rnglists)
	-- extends the existing sections + the G' group (.debug_info, .debug_abbrev, .debug_str, .debug_loc) appends a new compile unit.
	-- The dispatch (SECTION_BUILDERS) handles each.
	local existing_sections = elf_dwarf.read_elf_sections(elf_path, {
		".debug_line", ".debug_aranges", ".debug_rnglists",
		".debug_info", ".debug_abbrev", ".debug_str",
		-- .debug_loc and .debug_loclists don't exist in the source ELF (we
		-- --add-section them on splice); reading them just returns "" which is
		-- the "missing" case the builder handles.
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
	local skip_over = collect_skip_over(ctx)
	local atom_table = build_atom_table(ctx, skip_over)
	io.stderr:write(string.format("[dwarf_injection] matched %d atoms between nm + source-map\n", #atom_table))

	-- Task 8: detect rbind atoms + index Binds_* struct fields (from ctx.sources[i].scan, populated by scan-source pass).
	local _rbind_atoms, rbind_structs = parse_rbind_atoms(ctx, atom_table)
	local rbind_count = 0
	for _ in pairs(_rbind_atoms) do rbind_count = rbind_count + 1 end
	io.stderr:write(string.format("[dwarf_injection] matched %d rbind atoms across %d Binds_* structs\n",
		rbind_count, (function() local n = 0; for _ in pairs(rbind_structs) do n = n + 1 end; return n end)()))

	-- Write the .bin files. The build_psyq.ps1 post-link hook splices these into a copy of the ELF via objcopy --update-section.
	--
	-- Build order (Task 2 GREEN: scope ownership):
	--   0. Validate .debug_info layout (crT CU + DWARF5 main CU + final 0 root terminator).
	--      If validation fails, FAIL SAFELY by writing the existing sections verbatim (no malformed output, no synthetic CU append, no header patch).
	--   1. Build new .debug_abbrev using the main CU's abbrev offset → returns the offset of the duplicate main table (= #existing_abbrev).
	--   2. Build new .debug_info by splicing inserted children into the main CU (patches main CU's unit_length + debug_abbrev_offset;
	--      preserves all original DIE bytes; does NOT append a synthetic CU).
	--   3. Build .debug_line + .debug_aranges + .debug_rnglists (independent, F' tasks).
	--   4. Build .debug_loc (just a terminator).
	--
	-- .debug_str is left untouched in this slice: the inserted children use DW_FORM_string (inline) for all DW_AT_name values,
	-- so no new strings are required. The existing strings table is preserved verbatim.
	-- (The pre-Task 2 synthetic-CU build used .debug_str for CU name + comp_dir; that path is gone.)
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
			local results_safe = {
				{ name = "debug_info",     data = existing_info,       was = #existing_info },
				{ name = "debug_abbrev",   data = existing_abbrev,     was = #existing_abbrev },
				{ name = "debug_str",      data = existing_sections[".debug_str"] or "", was = #(existing_sections[".debug_str"] or "") },
				{ name = "debug_line",     data = build_dwarf_line_section    (existing_sections[".debug_line"] or "",     atom_table), was = #(existing_sections[".debug_line"]     or "") },
				{ name = "debug_aranges",  data = build_dwarf_aranges_section (existing_sections[".debug_aranges"] or "",  atom_table), was = #(existing_sections[".debug_aranges"]  or "") },
				{ name = "debug_rnglists", data = build_dwarf_rnglists_section(existing_sections[".debug_rnglists"] or "", atom_table), was = #(existing_sections[".debug_rnglists"] or "") },
				{ name = "debug_loc",      data = build_debug_loc_section(),                                                            was = #(existing_sections[".debug_loc"]      or "") },
			}
			local outputs_safe = { gdbinit_output }
			for _, r in ipairs(results_safe) do
				local path = SECTION_WRITERS[r.name](ctx.out_root, basename)
				local f = io.open(path, "wb")
				if not f then
					io.stderr:write(string.format("[dwarf_injection] failed to open %s for write\n", path))
				else
					f:write(r.data); f:close()
					outputs_safe[#outputs_safe + 1] = { [r.name .. "_bin"] = path }
				end
			end
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
		local new_info = build_debug_info_section(existing_info, main_cu_start, main_cu_end_excl, new_abbrev_offset, atom_table, rbind_structs, loclists_offsets)

		-- Step 3-5: independent sections (.debug_str left untouched — see comment above).
		local results = {
			{ name = "debug_abbrev",   data = new_abbrev,                                                                            was = #existing_abbrev },
			{ name = "debug_info",     data = new_info,                                                                              was = #existing_info },
			{ name = "debug_str",      data = existing_sections[".debug_str"] or "",                                                 was = #(existing_sections[".debug_str"]      or "") },
			{ name = "debug_line",     data = build_dwarf_line_section    (existing_sections[".debug_line"] or "",     atom_table),  was = #(existing_sections[".debug_line"]     or "") },
			{ name = "debug_aranges",  data = build_dwarf_aranges_section (existing_sections[".debug_aranges"] or "",  atom_table),  was = #(existing_sections[".debug_aranges"]  or "") },
			{ name = "debug_rnglists", data = build_dwarf_rnglists_section(existing_sections[".debug_rnglists"] or "", atom_table),  was = #(existing_sections[".debug_rnglists"] or "") },
			{ name = "debug_loc",      data = build_debug_loc_section(),                                                             was = #(existing_sections[".debug_loc"]      or "") },
			{ name = "debug_loclists", data = build_debug_loclists_section(atom_table),                                              was = 0 },
		}

		local outputs = { gdbinit_output }
		for _, r in ipairs(results) do
			local path = SECTION_WRITERS[r.name](ctx.out_root, basename)
			local f = io.open(path, "wb")
			if not f then
				io.stderr:write(string.format("[dwarf_injection] failed to open %s for write\n", path))
			else
				f:write(r.data); f:close()
				io.stderr:write(string.format("[dwarf_injection] new .%s = %d bytes (was %d, +%d atoms)\n"
					, r.name, #r.data, r.was, #atom_table))
				outputs[#outputs + 1] = { [r.name .. "_bin"] = path }
			end
		end
		return {
			outputs  = outputs,
			errors   = {},
			warnings = {},
		}
	end
	return { outputs = {}, errors = {}, warnings = {} }
end

return M
