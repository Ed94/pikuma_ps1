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
--- Writes the new section data to `<out_root>/<basename>.dwarf_*.bin` (7 blobs total).
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

local DW_AT_name             = 0x03
local DW_AT_low_pc           = 0x11
local DW_AT_high_pc          = 0x12
local DW_AT_language         = 0x13
local DW_AT_location         = 0x02
local DW_AT_comp_dir         = 0x1B
local DW_AT_byte_size        = 0x0B
local DW_AT_encoding         = 0x3E   -- DWARF5 §7.7.1: DW_AT_encoding (for DW_ATE_unsigned base type; was 0x13 = DW_AT_language in prior slice — semantically wrong)
local DW_AT_data_member_location = 0x38
local DW_AT_type             = 0x49
local DW_AT_linkage_name     = 0x6E   -- DWARF5 §7.7.1: DW_AT_linkage_name (standard form; 0x200027 was the GNU extension form — wrong vs DW_FORM_string abbrev)
local DW_AT_external         = 0x3F   -- marks a variable/function as externally visible

local DW_FORM_addr           = 0x01
local DW_FORM_data1          = 0x0B
local DW_FORM_string         = 0x08   -- inline null-terminated
local DW_FORM_strp           = 0x0E   -- 4-byte offset into .debug_str
local DW_FORM_exprloc        = 0x18   -- length-prefixed (ULEB128) DW_OP bytes
local DW_FORM_ref4           = 0x13   -- 4-byte offset within the same .debug_info CU
local DW_FORM_udata          = 0x0F   -- ULEB128 (DW_AT_byte_size for struct_type, DW_AT_data_member_location for member)
local DW_FORM_implicit_const = 0x21   -- DWARF5 §7.5.6: abbrev declaration carries a SLEB constant (used by the abbrev-table walker)

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
--- @field out_root string  -- output root (e.g. "build/gen")
--- @field basename string  -- input ELF basename (default "hello_gte")

-- ════════════════════════════════════════════════════════════════════════════
-- LEB128 encoders
-- ════════════════════════════════════════════════════════════════════════════
--
-- Lifted to `elf_dwarf.uleb128` + `elf_dwarf.sleb128` (F'' refactor).
-- See those helpers for the bit-layout documentation + named constants
-- (LEB_CONT_BIT, LEB_DATA_MASK, SLEB_SIGN_BIT).

-- Local aliases so the line-program encoder (below) can keep its short names.
local uleb128 = elf_dwarf.uleb128
local sleb128 = elf_dwarf.sleb128

-- ════════════════════════════════════════════════════════════════════════════
-- DWARF line-program encoder
-- ════════════════════════════════════════════════════════════════════════════

--- Build the byte sequence for ONE atom's line program:
---   DW_LNE_set_address(addr)
---   DW_LNS_copy -- entry 1: addr, file, line=first.line
---   for each subsequent word:
---     DW_LNS_advance_pc(1 .word = 4 bytes)
---     DW_LNS_advance_line(line - prev_line)
---     DW_LNS_copy
---   DW_LNE_end_sequence
---
--- Wire format reminder (DWARF5 §6.2.5):
---   - Standard opcodes: 1 byte opcode + payload (per opcode length).
---   - Extended opcode marker byte = 0.
---   - Extended opcodes: marker byte + ULEB128 size + sub_opcode + payload.
---
--- @param atom table  -- {name, addr, size_bytes, words, entries}
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
	local function end_sequence()
		-- size = 1 (just the sub_opcode byte, no payload)
		return string.char(DW_LNS_extended)
			.. string.char(DWARF_LINE_OPS.end_sequence_payload_size)
			.. string.char(DW_LNE_end_sequence)
	end

	if not atom.entries or #atom.entries == 0 then return set_address(atom.addr) .. end_sequence() end

	-- set_address sets the address register to atom.addr.
	-- line_state.line starts at 1 (per DWARF spec). 
	-- To land at entries[1].line for the FIRST emitted entry, we need to advance_line by (entries[1].line - 1) + then copy.
	-- Then each subsequent entry uses the delta from the previous entry.
	local parts = {
		set_file(ATOM_SOURCE_FILE_INDEX),       -- existing Unit 2 file table: hello_gte_tape.c
		set_address(atom.addr),                 -- 7 bytes: marker + size + sub + addr
		advance_line(atom.entries[1].line - 1), -- (entries[1].line - 1) bytes; line_state.line -> entries[1].line
		copy_op(),                              -- emit entry 1: addr=atom.addr, line=entries[1].line
		copy_op(),                              -- same PC/line: GDB 12 zero-instruction-prologue marker
	}
	local prev_line = atom.entries[1].line
	for idx = 2, #atom.entries do
		local entry = atom.entries[idx]
		parts[#parts + 1] = advance_pc(MIPS_BYTES_PER_WORD) -- 1 .word = MIPS_BYTES_PER_WORD bytes on MIPS
		parts[#parts + 1] = advance_line(entry.line - prev_line)
		parts[#parts + 1] = copy_op()
		prev_line = entry.line
	end
	parts[#parts + 1] = end_sequence()
	return table.concat(parts)
end

-- ════════════════════════════════════════════════════════════════════════════
-- Helpers: nm + source-map.txt + atom table
-- ════════════════════════════════════════════════════════════════════════════

--- Build the atom table the section builders consume.
--- Cross-references nm symbols with source-map.txt entries; sorted by addr.
--- @param ctx DwarfInjectionCtx
--- @return table[]  -- list of {name, addr, size_bytes, words, entries}
local function build_atom_table(ctx)
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

	-- Cross-ref; keep atoms that exist in both.
	local out = {}
	for name, info in pairs(addrs) do
		local sm = merged[name]
		if sm then
			out[#out + 1] = {
				name       = name,
				addr       = info[1],
				size_bytes = info[2],
				words      = sm.total,
				entries    = sm.words,
			}
		end
	end
	table.sort(out, function(a, b) return a.addr < b.addr end)
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
			if p <= body_len and body:sub(p, p) == "*" then
				is_pointer = true
				p = p + 1
			end
			local field_pos              = duffle.skip_ws_and_cmt(body, p)
			local field_ident, field_end = duffle.read_ident(body, field_pos)
			-- A field is "recognized" if type is `U4` (no *) OR if it's a pointer.
			if field_ident and (type_ident == "U4" or is_pointer) then
				fields[#fields + 1] = { name = field_ident, offset = byte_off }
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
---
--- Returns the 7 abbrev declarations + a trailing `\0` byte (the table terminator per DWARF5 §7.5.3).
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

	return abbrev_cu .. abbrev_subprogram .. abbrev_variable
		.. abbrev_struct_type .. abbrev_member .. abbrev_bind_var .. abbrev_base_type
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
--- @param atom_table table[]  -- atoms (with atom.rbind set if rbind)
--- @param rbind_structs table  -- {[binds_name] = {bytes, fields, atom_names}}
--- @return string  -- bytes to splice into the main CU just before its root terminator
local function build_inserted_children(main_cu_offset, main_cu_end_excl, atom_table, rbind_structs)
	rbind_structs = rbind_structs or {}

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
			emit(elf_dwarf.write_u32_le(ref4_of(base_type_section_offset)))  -- DW_FORM_ref4 → base_type
		end

		emit(string.char(0x00))               -- end of structure_type's children
	end

	-- 3) Emit per-atom DW_TAG_subprograms (children of main CU).
	--    Subprograms are named `<name>` (matching the nm symbol; the `code_` prefix was removed from the MipsAtom_ macro in code/duffle/lottes_tape.h).
	--    The gcc global `<name>[]` is a DW_TAG_variable without children; our subprogram has the wave-context var children.
	--    gdb's symbol resolution picks our subprogram (it has low_pc/high_pc + children) over the gcc global for function-context lookups.
	for _, atom in ipairs(atom_table) do
		emit(uleb128(ABBREV_SUBPROGRAM))
		emit(atom.name .. "\0")                  -- DW_FORM_string (DW_AT_name)
		emit(elf_dwarf.write_u32_le(atom.addr))
		emit(elf_dwarf.write_u32_le(atom.addr + atom.size_bytes))
		emit(atom.name .. "\0")                  -- DW_FORM_string (DW_AT_linkage_name; same as DW_AT_name for non-mangled C)

		-- Per wave-context reg: DW_TAG_variable (type = U4 via ref4 to base_type DIE)
		for _, loc in ipairs(WAVE_CONTEXT_LOCATIONS) do
			emit(uleb128(ABBREV_VARIABLE))
			emit(loc.name .. "\0")               -- DW_FORM_string
			emit(reg_exprloc(loc.reg))           -- DW_FORM_exprloc (DW_OP_regN)
			emit(elf_dwarf.write_u32_le(ref4_of(base_type_section_offset)))  -- DW_FORM_ref4 → base_type
			emit(string.char(0x01))              -- DW_AT_external=1 (visible at CU scope)
		end

		-- If rbind, emit bind_args variable with piece-chain location.
		if atom.rbind then
			local binds_name = atom.rbind.binds
			emit(uleb128(ABBREV_BIND_VAR))
			emit("bind_args\0")                  -- DW_FORM_string (DW_AT_name)
			emit(piece_chain_exprloc(atom.rbind)) -- DW_FORM_exprloc
			emit(elf_dwarf.write_u32_le(ref4_of(struct_section_offsets[binds_name])))  -- DW_FORM_ref4 → struct_type
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
--- @param existing string  -- existing .debug_info bytes (verbatim)
--- @param main_cu_start integer  -- 0-based offset of the main CU's unit_length field
--- @param main_cu_end_excl integer  -- 0-based offset of the first byte AFTER the main CU
--- @param new_abbrev_offset integer  -- 0-based offset into the new .debug_abbrev of the duplicate main table
--- @param atom_table table[]
--- @param rbind_structs table  -- {[binds_name] = {bytes, fields, atom_names}} (Task 8)
--- @return string  -- the rebuilt .debug_info bytes
local function build_debug_info_section(existing, main_cu_start, main_cu_end_excl, new_abbrev_offset, atom_table, rbind_structs)
	-- 1) Build the inserted children bytes (just before the main CU's root terminator).
	local inserted     = build_inserted_children(main_cu_start, main_cu_end_excl, atom_table, rbind_structs)
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
}

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
		-- .debug_loc doesn't exist in the source ELF (we --add-section it on splice);
		-- reading it just returns "" which is the "missing" case the builder handles.
		".debug_loc",
	})
	io.stderr:write(string.format(
		"[dwarf_injection] read %d DWARF sections: .debug_line=%d .debug_aranges=%d .debug_rnglists=%d .debug_info=%d .debug_abbrev=%d .debug_str=%d .debug_loc=%d\n",
		7,
		#(existing_sections[".debug_line"]     or ""),
		#(existing_sections[".debug_aranges"]  or ""),
		#(existing_sections[".debug_rnglists"] or ""),
		#(existing_sections[".debug_info"]     or ""),
		#(existing_sections[".debug_abbrev"]   or ""),
		#(existing_sections[".debug_str"]      or ""),
		#(existing_sections[".debug_loc"]      or "")))

	-- Build the atom table (cross-ref nm symbols with source-map.txt entries).
	local atom_table = build_atom_table(ctx)
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
	local basename = ctx.basename or DEFAULT_BASENAME
	if ctx.out_root and ctx.out_root ~= "" then
		duffle.ensure_dir(ctx.out_root)

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
			local outputs_safe = {}
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

		-- Step 1: duplicate main abbrev table + append new codes 100..106.
		local new_abbrev, new_abbrev_offset = build_debug_abbrev_section(existing_abbrev, main_abbrev_offset)
		if not new_abbrev_offset then
			io.stderr:write("[dwarf_injection] main abbrev-table validation failed; refusing to emit malformed DWARF\n")
			return { outputs = {}, errors = {}, warnings = {"main abbrev-table validation failed"} }
		end

		-- Step 2: splice inserted children into the main CU (patches unit_length + abbrev_offset; no synthetic CU).
		local new_info = build_debug_info_section(existing_info, main_cu_start, main_cu_end_excl, new_abbrev_offset, atom_table, rbind_structs)

		-- Step 3-4: independent sections (.debug_str left untouched — see comment above).
		local results = {
			{ name = "debug_abbrev",   data = new_abbrev,                                                                            was = #existing_abbrev },
			{ name = "debug_info",     data = new_info,                                                                              was = #existing_info },
			{ name = "debug_str",      data = existing_sections[".debug_str"] or "",                                                 was = #(existing_sections[".debug_str"]      or "") },
			{ name = "debug_line",     data = build_dwarf_line_section    (existing_sections[".debug_line"] or "",     atom_table),  was = #(existing_sections[".debug_line"]     or "") },
			{ name = "debug_aranges",  data = build_dwarf_aranges_section (existing_sections[".debug_aranges"] or "",  atom_table),  was = #(existing_sections[".debug_aranges"]  or "") },
			{ name = "debug_rnglists", data = build_dwarf_rnglists_section(existing_sections[".debug_rnglists"] or "", atom_table),  was = #(existing_sections[".debug_rnglists"] or "") },
			{ name = "debug_loc",      data = build_debug_loc_section(),                                                             was = #(existing_sections[".debug_loc"]      or "") },
		}

		local outputs = {}
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
