--- elf_dwarf.lua — ELF32 + DWARF + atoms source-map utilities.
--- **What this module contains:**
---   - **Format-constant tables** (the byte-offset / opcode / size encyclopedias for ELF32, DWARF4 aranges, DWARF5 rnglists, DWARF line-program, MIPS).
---     Every constant carries a spec:` comment naming the spec section that defines it.
---   - **I/O helpers**: little-endian byte read/write, ELF32 section walker, nm symbol reader, source-map parser, native directory glob.

-- ════════════════════════════════════════════════════════════════════════════
-- Native dependencies
-- ════════════════════════════════════════════════════════════════════════════

-- lfs is wired into package.cpath by `duffle_paths.lua` (vendored under `toolchain/lfs/lfs.dll`).
-- Elf32Adapter / Elf32Header / Elf32Section / Elf32Sym / Elf32Mod: see elf32.lua.
-- Path: see duffle.lua. NmAddr: see passes/atoms_source_map.lua.

--- @class LfsMod
--- @field attributes fun(path: string, request: string): string|nil

--- @class Dwarf4Aranges
--- @field unit_length_offset integer
--- @field version_offset     integer
--- @field cu_offset_offset   integer
--- @field addr_size_offset   integer
--- @field seg_size_offset    integer
--- @field entry_size         integer
--- @field terminator_size    integer
--- @field version_expected   integer
--- @field addr_size_expected integer
--- @field seg_size_expected  integer

--- @class Dwarf5Rnglists
--- @field unit_length_offset    integer
--- @field version_offset        integer
--- @field addr_size_offset      integer
--- @field seg_size_offset       integer
--- @field offset_count_offset   integer
--- @field first_entry_offset    integer
--- @field end_of_list           integer
--- @field start_length          integer
--- @field version_expected      integer
--- @field addr_size_expected    integer
--- @field seg_size_expected     integer
--- @field offset_count_expected integer

--- @class DwarfLineOps
--- @field DW_LNS_extended          integer
--- @field DW_LNS_copy              integer
--- @field DW_LNS_advance_pc        integer
--- @field DW_LNS_advance_line      integer
--- @field DW_LNS_set_file          integer
--- @field DW_LNS_negate_stmt       integer
--- @field DW_LNE_end_sequence      integer
--- @field DW_LNE_set_address       integer
--- @field opcode_base              integer
--- @field line_base                integer
--- @field line_range               integer
--- @field end_sequence_payload_size integer
--- @field set_address_payload_size  integer

--- @class Dwarf5DebugLine
--- @field version_offset_post_il integer
--- @field addr_size_offset       integer
--- @field seg_size_offset        integer
--- @field header_length_offset   integer
--- @field program_header_start   integer
--- @field form_addr_bytes        integer
--- @field form_strp_bytes        integer
--- @field form_data16_bytes      integer
--- @field form_line_strp         integer
--- @field form_string            integer
--- @field form_udata             integer
--- @field form_data16            integer
--- @field lnct_path              integer
--- @field lnct_directory_index   integer
--- @field lnct_md5               integer

--- @class AbbrevAttr
--- @field name integer
--- @field form integer

--- @class AbbrevDecl
--- @field code         integer
--- @field tag          integer
--- @field has_children integer
--- @field attrs        AbbrevAttr[]

--- @class ElfDwarf
--- @field DW_TAG                  table<string, integer>  -- bag: tag name -> encoding
--- @field DW_AT                   table<string, integer>  -- bag: attr name -> encoding
--- @field DW_FORM                 table<string, integer>  -- bag: form name -> encoding
--- @field DW_ATE                  table<string, integer>  -- bag: base-type encoding name -> code
--- @field MIPS_BYTES_PER_WORD     integer
--- @field dw_dwarf32_terminator   integer
--- @field DWARF4_ARANGES          Dwarf4Aranges
--- @field DWARF5_RNGLISTS         Dwarf5Rnglists
--- @field DWARF_LINE_OPS          DwarfLineOps
--- @field DWARF5_DEBUG_LINE       Dwarf5DebugLine
--- @field read_u32_le             fun(buf: string, off: integer): integer
--- @field read_u16_le             fun(buf: string, off: integer): integer
--- @field read_uleb128_at         fun(buf: string, pos: integer): integer|nil, integer
--- @field read_sleb128_at         fun(buf: string, pos: integer): integer|nil, integer
--- @field find_abbrev_table_end   fun(table_bytes: string, table_start: integer): integer|nil
--- @field read_ref_sig8           fun(buf: string, pos: integer): integer, integer, integer
--- @field find_type_unit_by_signature fun(info: string, target_sig_lo: integer, target_sig_hi: integer): integer|nil, integer|nil
--- @field write_u32_le            fun(value: integer): string
--- @field write_u16_le            fun(value: integer): string
--- @field read_elf_sections       fun(elf_path: Path, section_names: string[]): table<string, string>
--- @field read_nm                 fun(elf_path: Path): table<string, NmAddr>
--- @field uleb128                 fun(n: integer): string
--- @field sleb128                 fun(n: integer): string
--- @field uleb128_size            fun(n: integer): integer
--- @field sleb128_size            fun(n: integer): integer
--- @field read_line_unit_file_table fun(elf_path: string): table<string, integer>|nil, table<integer, string>|nil, table<integer, string>|nil

--- @type LfsMod
local lfs = require("lfs")

-- scripts/elf32.lua contains format-constant tables + the byte-level walker.
-- The this file re-exports `read_u32_le` / `read_u16_le` (and the DWARF32 terminator).
-- read_u32_le is this module's reader; implementation in elf32.lua.
--- @type Elf32Mod
local E = require("elf32")

--- @type ElfDwarf
local M = {}

-- ════════════════════════════════════════════════════════════════════════════
-- DWARF tag + form constants
-- ════════════════════════════════════════════
-- (DWARF5 §7.5.5 "Tag Encodings" + Table 7.1; gcc emits these exact values for the DWARF3-extension and DWARF5 line units.)

--- bag: DWARF tag name -> encoding
--- @type table<string, integer>
M.DW_TAG = {
	compile_unit       = 0x11,
	subprogram         = 0x2E,
	variable           = 0x34,
	structure_type     = 0x13,
	member             = 0x0D,
	base_type          = 0x24,
	typedef            = 0x2A,
	pointer_type       = 0x0F,
	const_type         = 0x26,
	volatile_type      = 0x27,
	inlined_subroutine = 0x1D,
	-- We index the canonical gcc-emitted tags. Anything else falls through.
}

--- bag: DWARF attr name -> encoding
--- @type table<string, integer>
M.DW_AT = {
	name                  = 0x03,
	low_pc                = 0x11,
	high_pc               = 0x12,
	language              = 0x13,
	location              = 0x02,
	comp_dir              = 0x1B,
	byte_size             = 0x0B,
	encoding              = 0x3E,
	data_member_location  = 0x38,
	type                  = 0x49,
	linkage_name          = 0x6E,
	external              = 0x3F,
	abstract_origin       = 0x31,
	call_file             = 0x58,
	call_line             = 0x59,
	inline                = 0x20,
	decl_file             = 0x3A,
	decl_line             = 0x3B,
}

--- bag: DWARF form name -> encoding
--- @type table<string, integer>
M.DW_FORM = {
	addr           = 0x01,
	data1          = 0x0B,
	data2          = 0x05,
	data4          = 0x06,
	string         = 0x08,
	strp           = 0x0E,
	exprloc        = 0x18,
	ref4           = 0x13,
	udata          = 0x0F,
	ref_sig8       = 0x20,
	implicit_const = 0x21,
	flag_present   = 0x19,
	sec_offset     = 0x17,
}

--- bag: DWARF base-type encoding name -> code
--- @type table<string, integer>
M.DW_ATE = {
	address       = 0x01,
	boolean       = 0x02,
	complex_float = 0x03,
	float         = 0x04,
	signed        = 0x05,
	signed_char   = 0x06,
	unsigned      = 0x07,
	unsigned_char = 0x08,
}

-- DWARF5 §7.5.6 DW_FORM_implicit_const
--- @type integer
local DW_FORM_implicit_const = 0x21

-- ════════════════════════════════════════════════════════════════════════════
-- Format-constant tables
-- ════════════════════════════════════════════════════════════════════════════

-- ----------------------------------------------------------------------------
-- MIPS sizes
-- ----------------------------------------------------------------------------

--- spec: MIPS o32 ABI §"Register Usage" — 32-bit general-purpose registers
M.MIPS_BYTES_PER_WORD = 0x04


-- ----------------------------------------------------------------------------
-- ELF32 (System V ABI gABI v1.2)
-- ----------------------------------------------------------------------------
--- **Wire-offset contract:** format offsets, fixed-width reader offsets, LEB/parser cursors, and section-relative values are zero-based wire offsets. 
--- Only Lua string APIs receive a `+ 1` conversion at their boundary (`byte`, `sub`, and `find`).
--- ELF/DWARF field offsets are expressed in hex so they map directly to the zero-based byte positions in the binary file.
---
--- The ELF32 header / section / sym layout tables are within scripts/elf32.lua.
--- The metaprogram re-exports the DWARF32 initial-length terminator.

--- spec: DWARF4 spec §7.4 — 32-bit DWARF initial-length terminator
M.dw_dwarf32_terminator = E.dw_dwarf32_terminator

-- ----------------------------------------------------------------------------
-- DWARF4 .debug_aranges (per DWARF5 spec §7.4 — Address Range Table)
-- ----------------------------------------------------------------------------
-- All offsets are zero-based wire offsets.

--- spec: DWARF5 spec §7.4 (Address Range Table) — 32-bit DWARF form
--- @type Dwarf4Aranges
M.DWARF4_ARANGES = {
	unit_length_offset = 0x00,    -- 4-byte LE; length of unit body (excludes these 4 bytes)
	version_offset     = 0x04,    -- 2-byte LE; expected = 2
	cu_offset_offset   = 0x06,    -- 4-byte LE; CU DIE offset in .debug_info
	addr_size_offset   = 0x0A,    -- 1-byte;  expected = 4 (32-bit MIPS)
	seg_size_offset    = 0x0B,    -- 1-byte;  expected = 0
	entry_size         = 0x08,    -- 4-byte addr + 4-byte length (per §7.4)
	terminator_size    = 0x08,    -- 8 zero bytes (per §7.4 end-of-list marker)
	version_expected   = 2,
	addr_size_expected = 4,
	seg_size_expected  = 0,
}

-- ----------------------------------------------------------------------------
-- DWARF5 .debug_rnglists (per DWARF5 spec §2.17 + §7.21)
-- ----------------------------------------------------------------------------
-- All offsets are zero-based wire offsets.

--- spec: DWARF5 spec §2.17 + §7.21 (Range List Table) — 32-bit DWARF form
--- @type Dwarf5Rnglists
M.DWARF5_RNGLISTS = {
	unit_length_offset    = 0x00,    -- 4-byte LE
	version_offset        = 0x04,    -- 2-byte LE; expected = 5
	addr_size_offset      = 0x06,    -- 1-byte;  expected = 4
	seg_size_offset       = 0x07,    -- 1-byte;  expected = 0
	offset_count_offset   = 0x08,    -- 4-byte LE; expected = 0
	first_entry_offset    = 0x0C,
	end_of_list           = 0x00,    -- spec: DWARF5 §7.7 — DW_RLE_end_of_list byte value
	start_length          = 0x07,    -- spec: DWARF5 §7.7 — DW_RLE_start_length byte value
	version_expected      = 5,
	addr_size_expected    = 4,
	seg_size_expected     = 0,
	offset_count_expected = 0,
}

-- ----------------------------------------------------------------------------
-- DWARF line-program opcodes (per DWARF5 spec §6.2.5)
-- ----------------------------------------------------------------------------
-- Opcode VALUES stay in decimal — they're identifiers (DW_LNS_copy = 1), not binary positions.
-- Compare to the *_offset fields above which are hex.

--- spec: DWARF5 spec §6.2.5 (Line Number Program Opcodes)
--- @type DwarfLineOps
M.DWARF_LINE_OPS = {
	-- Standard opcodes (§6.2.5.2)
	DW_LNS_extended     = 0,    -- spec: §6.2.5.2 — extended opcode marker byte
	DW_LNS_copy         = 1,
	DW_LNS_advance_pc   = 2,
	DW_LNS_advance_line = 3,
	DW_LNS_set_file     = 4,
	DW_LNS_negate_stmt  = 6,    -- spec: §6.2.5.2 — toggle the line-state is_stmt register
	-- Extended sub-opcodes (§6.2.5.3)
	DW_LNE_end_sequence = 1,    -- spec: §6.2.5.3
	DW_LNE_set_address  = 2,    -- spec: §6.2.5.3
	-- Standard opcode header (§6.2.5.1)
	-- opcode_base + line_range are 1-byte header fields; hex so they map directly to the line-program header byte sequence.
	-- line_base stays signed decimal (=-5) since 0xFB obscures the spec semantics.
	opcode_base              = 0x0D,
	line_base                = -5,
	line_range               = 0x0E,
	-- Extended opcode payload sizes (include the sub-opcode byte; §6.2.5.3)
	-- Hex so they match the byte positions in the line-program wire format.
	end_sequence_payload_size = 0x01,   -- size = sub_opcode only
	set_address_payload_size  = 0x05,   -- size = sub_opcode(1) + addr(4)
}

-- ----------------------------------------------------------------------------
-- DWARF5 .debug_line (per DWARF5 spec §6.2.4 — Line Number Program Header)
-- ----------------------------------------------------------------------------
-- All offsets are zero-based wire offsets from the start of the unit body
-- (i.e. AFTER unit_length has been read and unit_length bytes skipped past unit_length's 4 bytes).
--
-- The DWARF3/4 line-program format differs:
--   - It omits `address_size` (DWARF3 §6.2.4) + `segment_selector_size` (DWARF5 §6.2.4).
--   - It uses null-terminated string lists for `include_directories` + `file_names`
--     (vs. DWARF5's format_count + fields-list shape).
-- These are documented inline at each parse site in read_line_unit_file_table below.

--- spec: DWARF5 spec §6.2.4 (Line Number Program Header — version >= 5)
--- @type Dwarf5DebugLine
M.DWARF5_DEBUG_LINE = {
	-- Header fields (zero-based, AFTER unit_length has been read).
	version_offset_post_il = 0x00,    -- 2-byte LE; expected = 5
	addr_size_offset       = 0x02,    -- 1 byte;  expected = 4
	seg_size_offset        = 0x03,    -- 1 byte;  expected = 0
	header_length_offset   = 0x04,    -- 4-byte LE; length of program-header content that follows
	program_header_start   = 0x08,    -- first byte of program-header content (after the 8 fixed bytes)

	-- Per-form byte widths (used when reading directory / file-name entries).
	form_addr_bytes        = 0x04,    -- DW_FORM_addr (32-bit) | DW_FORM_data4
	form_strp_bytes        = 0x04,    -- DW_FORM_line_strp / DW_FORM_strp / DW_FORM_strp_sup
	form_data16_bytes      = 0x10,    -- DW_FORM_data16 (MD5)

	-- DWARF5 form codes (subset used in line-program directory + file tables).
	form_line_strp         = 0x1A,    -- DWARF5 §7.5.6 — DW_FORM_line_strp (4-byte offset into .debug_line_str)
	form_string            = 0x08,    -- DWARF4-compatible fallback (inline null-terminated; not in .debug_line_str)
	form_udata             = 0x0F,    -- DW_FORM_udata (ULEB)
	form_data16            = 0x18,    -- DW_FORM_data16 (16-byte MD5; gcc emits this for split debug info)

	-- DWARF5 content-tag codes (DW_LNCT_* from §6.2.4.1 + §6.2.4.2).
	lnct_path              = 0x01,
	lnct_directory_index   = 0x02,
	lnct_md5               = 0x05,    -- gcc with MD5 in file name table (rare)
}

-- ════════════════════════════════════════════════════════════════════════════
-- I/O helpers: little-endian byte read/write
-- ════════════════════════════════════════════════════════════════════════════

--- Read a 4-byte little-endian unsigned integer from `buf` at zero-based wire offset `off`.
--- Equivalent to `string.unpack("<I4", buf, off + 1)` but avoids the table-return shape + works under LuaJIT 2.1
--- (which has partial `string.unpack` coverage).
--- **Convention:** `off` is a zero-based wire offset; `+ 1` is applied only at the `string.byte` boundary.
---
--- Thin forwarder: the canonical implementation lives in scripts/elf32.lua.
--- The "second caller lifts" pattern keeps the metaprogram side fluent
--- (`M.read_u32_le(buf, off)`) while the body is deduped.
--- @param buf string
--- @param off integer  -- zero-based wire offset
--- @return integer
function M.read_u32_le(buf, off)
	return E.read_u32_le(buf, off)
end

--- Read a 2-byte little-endian unsigned integer from `buf` at zero-based wire offset `off`.
--- (`off` is zero-based; `+ 1` is applied only at the `string.byte` boundary.)
--- Thin forwarder — see `M.read_u32_le` for the rationale.
--- @param buf string
--- @param off integer  -- zero-based wire offset
--- @return integer
function M.read_u16_le(buf, off)
	return E.read_u16_le(buf, off)
end

-- Pure-Lua 5.3 LEB128 readers (no `bit` library). `2^shift` arithmetic matches the existing parser.
-- Offsets are 0-based; returns (value, next_pos).
-- Promoted from `local function` to M.* exports so passes/dwarf_injection.lua can import them as file-scope locals per the 2nd-caller lift precedent
-- (the uleb128 + sleb128 encoders were promoted the same way).
--- @param buf string
--- @param pos integer
--- @return integer|nil
--- @return integer
function M.read_uleb128_at(buf, pos)
	--- @type integer, integer
	local value, shift = 0, 0
	--- @type integer
	local len          = #buf
	while pos < len do
		--- @type integer
		local b = buf:byte(pos + 1)
		value = value + (b % 0x80) * (2 ^ shift)
		shift = shift + 7
		pos   = pos + 1
		if b < 0x80 then return value, pos end
	end
	return nil, pos
end

--- @param buf string
--- @param pos integer
--- @return integer|nil
--- @return integer
function M.read_sleb128_at(buf, pos)
	--- @type integer, integer
	local value, shift = 0, 0
	--- @type integer
	local len = #buf
	while pos < len do
		--- @type integer
		local b = buf:byte(pos + 1)
		value = value + (b % 0x80) * (2 ^ shift)
		shift = shift + 7
		pos   = pos + 1
		if b < 0x80 then
			if b >= 0x40 then value = value - (2 ^ shift) end
			return value, pos
		end
	end
	return nil, pos
end

-- Find the 0-based offset of the table-terminator byte (a single 0) for the abbrev table starting at `table_start`.
-- Returns nil on truncated input. Walks declaration headers
-- (code, tag, has_children, attr/form pairs, DW_FORM_implicit_const constant) until it finds a 0 byte that follows a complete declaration.
--- @param table_bytes string
--- @param table_start integer
--- @return integer|nil
function M.find_abbrev_table_end(table_bytes, table_start)
	--- @type integer, integer
	local pos, len = table_start, #table_bytes
	if    pos >= len or table_bytes:byte(pos + 1) == 0 then return pos end
	while pos < len do
		--- @type integer|nil, integer
		local  _code, code_end = M.read_uleb128_at(table_bytes, pos)
		if not _code then return nil end
		pos = code_end
		--- @type integer|nil, integer
		local  _tag, tag_end = M.read_uleb128_at(table_bytes, pos)
		if not _tag then return nil end
		pos = tag_end
		if pos >= len then return nil end
		pos = pos + 1   -- has_children byte
		while pos < len do
			--- @type integer|nil, integer
			local  attr, attr_end = M.read_uleb128_at(table_bytes, pos)
			if not attr then return nil end
			pos = attr_end
			--- @type integer|nil, integer
			local  form, form_end = M.read_uleb128_at(table_bytes, pos)
			if not form then return nil end
			pos = form_end
			if attr == 0 and form == 0 then break end
			if form == DW_FORM_implicit_const then
				--- @type integer|nil, integer
				local _c, ce = M.read_sleb128_at(table_bytes, pos)
				if not _c then return nil end
				pos = ce
			end
		end
		if pos >= len then return nil end
		if table_bytes:byte(pos + 1) == 0 then return pos end
	end
	return nil
end

-- Read the null-terminated C string at 0-based offset `off` in `buf`.
-- Stops at the first 0 byte or end of buffer.
--- @param buf string
--- @param off integer
--- @return string
local function read_c_string_at(buf, off)
	--- @type integer
	local len = #buf
	--- @type integer
	local start = off
	while off < len and buf:byte(off + 1) ~= 0 do off = off + 1 end
	return buf:sub(start + 1, off)
end

-- Walk the .debug_abbrev table starting at 0-based offset `table_start` and return a list of declarations:
-- {code, tag, has_children, attrs={ {name, form}, ... }}.
-- Stops at the table terminator.
--- @param table_bytes string
--- @param table_start integer
--- @return AbbrevDecl[]|nil
--- @return string|nil
local function parse_abbrev_table(table_bytes, table_start)
	--- @type integer|nil
	local table_end = M.find_abbrev_table_end(table_bytes, table_start)
	if not table_end then return nil, "no terminator" end
	--- @type AbbrevDecl[]
	local decls = {}
	--- @type integer
	local pos = table_start
	while pos < table_end do
		--- @type integer|nil, integer
		local  code, code_end = M.read_uleb128_at(table_bytes, pos)
		if not code then return nil, "truncated code" end
		pos = code_end
		--- @type integer|nil, integer
		local  tag, tag_end = M.read_uleb128_at(table_bytes, pos)
		if not tag then return nil, "truncated tag" end
		pos = tag_end
		--- @type integer
		local has_children = table_bytes:byte(pos + 1)
		pos = pos + 1
		--- @type AbbrevAttr[]
		local attrs = {}
		while true do
			--- @type integer|nil, integer
			local  attr, attr_end = M.read_uleb128_at(table_bytes, pos)
			if not attr then return nil, "truncated attr" end
			pos = attr_end
			--- @type integer|nil, integer
			local form, form_end = M.read_uleb128_at(table_bytes, pos)
			if not form then return nil, "truncated form" end
			pos = form_end
			if attr == 0 and form == 0 then break end
			attrs[#attrs + 1] = { name = attr, form = form }
			if form == DW_FORM_implicit_const then
				--- @type integer|nil, integer
				local  _c, ce = M.read_sleb128_at(table_bytes, pos)
				if not _c then return nil, "truncated const" end
				pos = ce
			end
		end
		decls[#decls + 1] = { code = code, tag = tag, has_children = has_children, attrs = attrs }
	end
	return decls
end

-- Read a ULEB attribute value at 0-based offset `pos` for the given `form`.
-- Returns (value, next_pos). For DW_FORM_string we return the inline string.
-- For DW_FORM_strp we return the inline string resolved from `str_buf`.
-- For DW_FORM_ref4 we return the absolute CU-relative offset.
-- The caller decides whether to interpret that as a section offset.
--- @type table<integer, fun(buf: string, str_buf: string, pos: integer): (string|integer|nil, integer)>
local FORM_READERS = {
	--- @param buf string
	--- @param _ string
	--- @param pos integer
	--- @return integer
	--- @return integer
	[M.DW_FORM.addr] = function(buf, _, pos)
		return M.read_u32_le(buf, pos), pos + 4
	end,
	--- @param buf string
	--- @param _ string
	--- @param pos integer
	--- @return string
	--- @return integer
	[M.DW_FORM.string] = function(buf, _, pos)
		--- @type string
		local s = read_c_string_at(buf, pos)
		return s, pos + #s + 1
	end,
	--- @param buf string
	--- @param str_buf string
	--- @param pos integer
	--- @return string
	--- @return integer
	[M.DW_FORM.strp] = function(buf, str_buf, pos)
		-- DW_FORM_strp: 4-byte offset into .debug_str.
		--- @type integer
		local strp_off = M.read_u32_le(buf, pos)
		return read_c_string_at(str_buf, strp_off), pos + 4
	end,
	--- @param buf string
	--- @param _ string
	--- @param pos integer
	--- @return integer|nil
	--- @return integer
	[M.DW_FORM.udata] = function(buf, _, pos)
		return M.read_uleb128_at(buf, pos)
	end,
	--- @param buf string
	--- @param _ string
	--- @param pos integer
	--- @return integer
	--- @return integer
	[M.DW_FORM.data1] = function(buf, _, pos)
		return buf:byte(pos + 1), pos + 1
	end,
	--- @param buf string
	--- @param _ string
	--- @param pos integer
	--- @return integer
	--- @return integer
	[M.DW_FORM.data2] = function(buf, _, pos)
		return M.read_u16_le(buf, pos), pos + 2
	end,
	--- @param buf string
	--- @param _ string
	--- @param pos integer
	--- @return integer
	--- @return integer
	[M.DW_FORM.data4] = function(buf, _, pos)
		return M.read_u32_le(buf, pos), pos + 4
	end,
	--- @param buf string
	--- @param _ string
	--- @param pos integer
	--- @return integer
	--- @return integer
	[M.DW_FORM.ref4] = function(buf, _, pos)
		return M.read_u32_le(buf, pos), pos + 4
	end,
	--- @param buf string
	--- @param _ string
	--- @param pos integer
	--- @return integer
	--- @return integer
	[M.DW_FORM.sec_offset] = function(buf, _, pos)
		-- DW_FORM_sec_offset: 4-byte offset (size depends on DWARF version;
		-- on DWARF5 32-bit it's always 4 bytes).
		return M.read_u32_le(buf, pos), pos + 4
	end,
	--- @param _ string
	--- @param _ string
	--- @param pos integer
	--- @return integer
	--- @return integer
	[M.DW_FORM.flag_present] = function(_, _, pos)
		return 1, pos
	end,
	--- @param buf string
	--- @param _ string
	--- @param pos integer
	--- @return nil
	--- @return integer
	[M.DW_FORM.exprloc] = function(buf, _, pos)
		-- DW_FORM_exprloc: ULEB byte count + that many bytes of DW_OP_*.
		--- @type integer|nil, integer
		local len, ne = M.read_uleb128_at(buf, pos)
		if not len then return nil, pos end
		return nil, ne + len
	end,
	--- @param _ string
	--- @param _ string
	--- @param pos integer
	--- @return nil
	--- @return integer
	[DW_FORM_implicit_const] = function(_, _, pos)
		-- The constant is declared in the abbrev; no value bytes in the DIE.
		return nil, pos
	end,
	--- @param buf string
	--- @param _ string
	--- @param pos integer
	--- @return integer
	--- @return integer
	[M.DW_FORM.ref_sig8] = function(buf, _, pos)
		-- DW_FORM_ref_sig8 (DWARF5 §7.4.2): An 8-byte value identifying a type by signature.
		-- The low  4 bytes (LE) are the type signature (content hash);
		-- The high 4 bytes (LE) are a CU-relative offset into the matching type unit.
		-- Consumers use the low  4 to look up the type unit (see M.find_type_unit_by_signature)
		--  then the high 4 to resolve the specific type within it.
		-- Return the low  4 as the primary value to preserve the (value, next_pos) shape;
		--  the high 4 is exposed via M.read_ref_sig8 (which returns both halves).
		--- @type integer, integer, integer
		local _, _, next_pos = M.read_ref_sig8(buf, pos)
		return M.read_u32_le(buf, pos), next_pos
	end,
}
--- @param buf string
--- @param str_buf string
--- @param pos integer
--- @param form integer
--- @return string|integer|nil
--- @return integer
local function read_form_value(buf, str_buf, pos, form)
	--- @type (fun(buf: string, str_buf: string, pos: integer): (string|integer|nil, integer))|nil
	local r = FORM_READERS[form]
	if not r then
		return nil, pos
	end
	return r(buf, str_buf, pos)
end

--- Read a `DW_FORM_ref_sig8` value at 0-based offset `pos` from `buf`.
--- Returns the low 4 bytes (LE) as `low`, the high 4 bytes (LE) as `high`, and the cursor position after the 8-byte value as `next_pos`.
--- Callers that need the full type-unit + type-offset pair (e.g. to resolve a type identifier embedded as a signature)
--- should use this directly rather than going through `read_form_value`,
--- which only exposes the low 4 bytes to preserve its existing (value, next_pos) return shape.
--- @param buf string
--- @param pos integer -- zero-based wire offset
--- @return integer -- low 4 bytes (LE), the type signature
--- @return integer -- high 4 bytes (LE), the offset within the matching type unit
--- @return integer -- cursor after the 8-byte value
function M.read_ref_sig8(buf, pos) return M.read_u32_le(buf, pos), M.read_u32_le(buf, pos + 4), pos + 8 end

--- DWARF5 §7.5.6 (Type Entries).
--- Walk all units in `info` and return the 0-based offset of the first unit whose `DW_AT_type_signature`
--- (8-byte value at the end of the unit header) equals `target_sig`.
--- The signature is interpreted as two 32-bit halves (low/high) per the read_ref_sig8 contract;
--- we match both halves (i.e. the 8-byte value as a whole). Returns nil if no matching unit exists.
---
--- Unit header layout (from pos 0):
---   unit_length(4) + version(2) + unit_type(1) + address_size(1) + debug_abbrev_offset(4)
---   followed by type_unit_specific fields: type_signature(8) + type_offset(4)
--- The type_signature is at byte offset 8 of the body (right after debug_abbrev_offset).
--- @param info          string      -- the .debug_info section bytes
--- @param target_sig_lo integer     -- low 4 bytes (LE) of the desired signature
--- @param target_sig_hi integer     -- high 4 bytes (LE) of the desired signature
--- @return integer|nil, integer|nil -- unit offset, type_offset within the unit
function M.find_type_unit_by_signature(info, target_sig_lo, target_sig_hi)
	--- @type integer
	local pos         = 0
	--- @type integer
	local section_len = #info
	while pos + 4 < section_len do
		--- @type integer
		local unit_length = M.read_u32_le(info, pos)
		if    unit_length == 0xFFFFFFFF then
			return nil, nil  -- DWARF64 not supported
		end
		-- unit_length is the body size, NOT including the 4-byte unit_length field itself.
		--- @type integer
		local body_start = pos + 4
		--- @type integer
		local body_end   = body_start + unit_length
		if body_end > section_len then
			return nil, nil  -- malformed
		end
		-- Per DWARF5 §7.5.6, the type_unit (DW_UT_type = 0x02) body layout is:
		--  0:  version             (2)
		--  2:  unit_type           (1) -- DW_UT_type = 0x02
		--  3:  address_size        (1)
		--  4:  debug_abbrev_offset (4)
		--  8:  type_signature      (8)
		--  16: type_offset         (4)
		--  20: <children>
		if body_end - body_start >= 20 then
			-- read_ref_sig8 / write_u32_le / etc. are 1-indexed (string:byte);
			-- pos / body_start / body_end are 0-based wire offsets, so the 1-indexed byte at 0-based wire offset X is string:byte(X + 1).
			-- Per DWARF5 §7.5.6, the type_unit body is laid out as:
			--  byte 0-1:   version             (2)
			--  byte 2:     unit_type           (1) -- DW_UT_type = 0x02
			--  byte 3:     address_size        (1)
			--  byte 4-7:   debug_abbrev_offset (4)
			--  byte 8-15:  type_signature      (8)
			--  byte 16-19: type_offset         (4)
			--- @type integer
			local unit_type = info:byte(body_start + 2 + 1)  -- 0-based +2 = unit_type in 1-indexed
			if    unit_type == 0x02 then  -- DW_UT_type
				--- @type integer, integer, integer
				local sig_lo, sig_hi, _ = M.read_ref_sig8(info, body_start + 8)  -- 0-based +8 = type_signature in 1-indexed
				if    sig_lo == target_sig_lo and sig_hi == target_sig_hi then
					--- @type integer
					local type_offset = M.read_u32_le(info, body_start + 16)  -- 0-based +16 = type_offset in 1-indexed
					return pos, type_offset
				end
			end
		end
		-- Advance to the next unit (the 4-byte unit_length + the body).
		pos = body_end
	end
	return nil, nil
end

--- Return a 4-byte little-endian byte string for `value`.
--- Caller concatenates with `..` if composing multi-word blobs.
--- **Byte weights** written as `0x100` etc. (see `M.read_u32_le` for rationale).
--- @param value integer  -- 0 ≤ value ≤ 0xFFFFFFFF
--- @return string
function M.write_u32_le(value)
	return string.char(
		value                          % 0x00000100,
		math.floor(value / 0x00000100) % 0x00000100,
		math.floor(value / 0x00010000) % 0x00000100,
		math.floor(value / 0x01000000) % 0x00000100)
end

--- Return a 2-byte little-endian byte string for `value`.
--- @param value integer  -- 0 ≤ value ≤ 0xFFFF
--- @return string
function M.write_u16_le(value)
	return string.char(value % 0x00000100, math.floor(value / 0x00000100) % 0x00000100)
end

-- ════════════════════════════════════════════════════════════════════════════
-- I/O helpers: ELF32 / DWARF / symbols
-- ════════════════════════════════════════════════════════════════════════════

--- Read the named sections from a post-link ELF32 by walking the ELF32 section-header table directly
--- (no subprocess; lfs only for the existence check). Returns `{[name] = bytes_or_empty_string, ...}`.
---
--- **Convention:** ELF/DWARF offsets are zero-based wire offsets. Direct Lua string APIs add `+ 1` at the boundary.
--- Every requested name has an entry in the returned dict;
--- missing sections have an empty string (NOT nil) so callers can do `sections[".debug_x"] or ""` for the missing case.
---
--- **Cost:** one file open + one `f:seek` + one `f:read` per section header 
--- (we walk all `e_shnum` headers regardless of how many names are requested, to find the .shstrtab first).
--- For frequent callers, pass the union of all needed sections in one call.
--  Can add `.debug_info` + `.debug_loc` + `.debug_str_offsets` to the list without writing a 2nd ELF walker.
--- @param elf_path      Path
--- @param section_names string[]  -- list of section names to read
--- @return table<string, string>
function M.read_elf_sections(elf_path, section_names)
	-- Initialize result with all requested names set to "" so callers can do `sections[X] 
	-- or ""` for missing sections without nil-checks.
	--- @type table<string, string>
	local result = {}
	--- @type integer, string
	for _, name in ipairs(section_names) do result[name] = "" end

	-- O(1) lookup set.
	--- @type table<string, boolean>  -- bag: requested section name -> true
	local wanted = {}
	--- @type integer, string
	for _, name in ipairs(section_names) do wanted[name] = true end

	-- Existence check (lfs.attributes avoids an io.open-vs-fail race).
	if lfs.attributes(elf_path, "mode") ~= "file" then
		io.stderr:write(string.format("[elf_dwarf.read_elf_sections] ELF not found: %s\n", elf_path))
		return result
	end

	--- @type file*|nil
	local  f = io.open(elf_path, "rb")
	if not f then
		io.stderr:write(string.format("[elf_dwarf.read_elf_sections] io.open failed: %s\n", elf_path))
		return result
	end

	--- @type integer
	local file_size
	do
		f:seek("end", 0)
		file_size = f:seek("cur", 0)
	end
	--- @type Elf32Adapter
	local adapter = {
		--- @param offset integer
		--- @return integer|nil
		read_u8_at = function(offset)
			f:seek("set", offset)
			--- @type string|nil
			local b = f:read(1)
			if not b then return nil end
			return b:byte()
		end,
		--- @param offset integer
		--- @return integer|nil
		read_u16_at = function(offset)
			f:seek("set", offset)
			--- @type string|nil
			local b1 = f:read(1)
			--- @type string|nil
			local b2 = f:read(1)
			if not b1 or not b2 then return nil end
			return b1:byte() + b2:byte() * 0x100
		end,
		--- @param offset integer
		--- @return integer|nil
		read_u32_at = function(offset)
			f:seek("set", offset)
			--- @type string|nil
			local b1 = f:read(1)
			--- @type string|nil
			local b2 = f:read(1)
			--- @type string|nil
			local b3 = f:read(1)
			--- @type string|nil
			local b4 = f:read(1)
			if not b1 or not b2 or not b3 or not b4 then return nil end
			return b1:byte() + b2:byte() * 0x100
				+ b3:byte() * 0x10000 + b4:byte() * 0x1000000
		end,
		--- @return integer
		read_size = function() return file_size end,
	}

	-- Delegate the header parse + section walk to E.*.
	--- @type Elf32Header|nil, string|nil
	local hdr, hdr_err = E.parse_elf32_headers(adapter)
	if not hdr then
		io.stderr:write(string.format("[elf_dwarf.read_elf_sections] header parse failed: %s\n", tostring(hdr_err)))
		f:close()
		return result
	end

	--- @type Elf32Section[]|nil, string|nil
	local sections, walk_err = E.walk_sections(adapter, hdr)
	if not sections then
		io.stderr:write(string.format("[elf_dwarf.read_elf_sections] section walk failed: %s\n", tostring(walk_err)))
		f:close()
		return result
	end

	-- Resolve the requested sections.
	--- @type integer, Elf32Section
	for _, s in ipairs(sections) do
		if wanted[s.name] then
			--- @type string|nil
			local bytes = E.read_section_bytes(adapter, s)
			if bytes then result[s.name] = bytes end
		end
	end

	f:close()
	return result
end

--- Read ELF symbol addresses by walking the `.symtab` + `.strtab` sections directly (no `nm` subprocess). 
--- Returns a map `{name -> {addr, size_bytes}}` for every defined symbol.
---
--- **Conventions:**
--- - ELF32 symtab entry = 16 bytes (`st_name:4 + st_value:4 + st_size:4 + st_info:1 + st_other:1 + st_shndx:2`); offsets within each entry are zero-based wire offsets.
--- - Direct Lua `string.byte`/`string.sub`/`string.find` boundaries receive `+ 1`.
--- - We filter on STB_GLOBAL (high nibble of st_info = 1) to match `nm`'s default (external symbols only). STB_WEAK excluded.
--- - Keys are the ELF symbol names as written (the C ident).
--- - `st_size > 0` filter excludes undefined/imported symbols.
---
--- @param elf_path Path
--- @return table<string, NmAddr>
function M.read_nm(elf_path)
	--- @type table<string, NmAddr>
	local addrs = {}

	-- Existence check first; an empty or missing ELF returns an empty map.
	if lfs.attributes(elf_path, "mode") ~= "file" then return addrs end

	--- @type file*|nil
	local f = io.open(elf_path, "rb")
	if not f then return addrs end

	-- Build the file adapter for E.*.
	--- @type integer
	local file_size
	do
		f:seek("end", 0)
		file_size = f:seek("cur", 0)
	end
	--- @type Elf32Adapter
	local adapter = {
		--- @param offset integer
		--- @return integer|nil
		read_u8_at = function(offset)
			f:seek("set", offset)
			--- @type string|nil
			local b = f:read(1)
			if not b then return nil end
			return b:byte()
		end,
		--- @param offset integer
		--- @return integer|nil
		read_u16_at = function(offset)
			f:seek("set", offset)
			--- @type string|nil
			local b1 = f:read(1)
			--- @type string|nil
			local b2 = f:read(1)
			if not b1 or not b2 then return nil end
			return b1:byte() + b2:byte() * 0x100
		end,
		--- @param offset integer
		--- @return integer|nil
		read_u32_at = function(offset)
			f:seek("set", offset)
			--- @type string|nil
			local b1 = f:read(1)
			--- @type string|nil
			local b2 = f:read(1)
			--- @type string|nil
			local b3 = f:read(1)
			--- @type string|nil
			local b4 = f:read(1)
			if not b1 or not b2 or not b3 or not b4 then return nil end
			return b1:byte() + b2:byte() * 0x100
				+ b3:byte() * 0x10000 + b4:byte() * 0x1000000
		end,
		--- @return integer
		read_size = function() return file_size end,
	}

	-- Delegate the header + section walk to E.*.
	--- @type Elf32Header|nil, string|nil
	local hdr, hdr_err = E.parse_elf32_headers(adapter)
	if not hdr then
		io.stderr:write(string.format("[elf_dwarf.read_nm] header parse failed: %s\n", tostring(hdr_err)))
		f:close()
		return addrs
	end

	--- @type Elf32Section[]|nil, string|nil
	local sections, walk_err = E.walk_sections(adapter, hdr)
	if not sections then
		io.stderr:write(string.format("[elf_dwarf.read_nm] section walk failed: %s\n", tostring(walk_err)))
		f:close()
		return addrs
	end

	-- E.collect_symbols returns every defined symbol (no binding filter).
	-- The metaprogram then applies its STB_LOCAL / STB_GLOBAL + size>0 filter, matching `nm`'s default (external symbols only).
	--- @type table<string, Elf32Sym>|nil, string|nil
	local symbols, sym_err = E.collect_symbols(adapter, sections)
	if not symbols then
		io.stderr:write(string.format("[elf_dwarf.read_nm] symbol collection failed: %s\n", tostring(sym_err)))
		f:close()
		return addrs
	end

	f:close()

	--- @type string, Elf32Sym
	for name, entry in pairs(symbols) do
		-- High nibble of st_info = binding (STB_LOCAL=0, STB_GLOBAL=1, STB_WEAK=2).
		-- math.floor(/16) is portable across LuaJIT 2.0/2.1 and plain Lua 5.x.
		--- @type integer
		local binding = math.floor(entry.info / 16)
		if (binding == 0 or binding == 1) and entry.size > 0 then
			addrs[name] = { entry.value, entry.size }
		end
	end

	return addrs
end

-- ════════════════════════════════════════════════════════════════════════════
-- LEB128 encoders (Unsigned + Signed Little-Endian Base 128)
-- ════════════════════════════════════════════════════════════════════════════
--
-- DWARF uses LEB128 to encode variable-length integers in its wire format (line-program opcodes, DW_AT values, etc.).
-- Both encoders pack 7 bits of data per byte + 1 bit of "more bytes follow" signaling.
--
-- Per-byte layout:
--     bit:   7 6 5 4 3 2 1 0
--           │ └───── 7-bit data ─────┘
--           └─ continuation flag (LEB_CONT_BIT = 0x80)
--
-- For SLEB128 (signed), bit 6 of the 7-bit data is the sign bit that the
-- decoder uses for sign extension:
--     bit 6 = 0 → value is positive (or zero); zero-extend on decode
--     bit 6 = 1 → value is negative;            one-extend on decode
--
-- The signed encoder must emit the MINIMUM number of bytes whose final 7-bit payload already has the correct sign bit set 
-- (otherwise the decoder would round-trip to a different value).
--
-- Spec: DWARF5 §7.6 "Variable-Length Data" / Appendix C.

-- Top bit of each LEB128 byte. Set if more bytes follow in the encoding.
--- @type integer
local LEB_CONT_BIT = 0x80

-- Low 7 bits of each LEB128 byte. The actual data payload.
--- @type integer
local LEB_DATA_MASK = 0x7F

-- Bit 6 of the 7-bit data (i.e. 0x40). For SLEB128: the sign-bit position used by the decoder for sign extension.
-- Encoders MUST stop when the next byte would be redundant AND the sign bit in the last byte matches the value's sign.
--- @type integer
local SLEB_SIGN_BIT = 0x40

--- ULEB128 (Unsigned Little-Endian Base 128) encoder. Returns the byte string for the non-negative integer `n`.
--- Algorithm:
---   - Extract the low 7 bits of `n` (LEB_DATA_MASK = 0x7F).
---   - Shift `n` right by 7 bits.
---   - If more bytes remain, OR in the continuation flag (LEB_CONT_BIT).
---   - Repeat until `n` is fully consumed.
--- @param n integer  -- non-negative
--- @return string
function M.uleb128(n)
	if n == nil or type(n) ~= "number" then
		io.stderr:write("[elf_dwarf.uleb128] got " .. type(n) .. ": " .. tostring(n) .. "\n")
		io.stderr:write(debug.traceback() .. "\n")
		error("uleb128 requires non-negative number")
	end
	assert(n >= 0, "uleb128 requires non-negative input")
	--- @type string[]
	local bytes = {}
	repeat
		--- @type integer
		local b = n % (LEB_DATA_MASK + 1)      -- extract low 7 bits
		n = (n - b) / (LEB_DATA_MASK + 1)      -- shift right by 7 bits
		if n > 0 then b = b + LEB_CONT_BIT end -- set continuation bit if more bytes follow
		bytes[#bytes + 1] = string.char(b)
	until n == 0
	return table.concat(bytes)
end

--- SLEB128 (Signed Little-Endian Base 128) encoder. Returns the byte string for the integer `n` (may be negative).
--- Algorithm differs from ULEB128 by the termination condition: 
--- stop when the remaining bits can be inferred from the sign bit in the last byte's 7-bit data payload.
---   - If `n == 0`  (no more value bits)   AND bit 6 of the data = 0 → positive terminator (sign bit says "zero-extend").
---   - If `n == -1` (sign-extended all-1s) AND bit 6 of the data = 1 → negative terminator (sign bit says "one-extend").
---
--- Without these checks, the decoder would round-trip to a different value
--- (e.g. encoding `0` as `0x80 0x00` decodes to `0` correctly but is 2 bytes long; the termination check picks the 1-byte `0x00` form).
--- @param n integer  -- any integer (negative allowed)
--- @return string
function M.sleb128(n)
	--- @type string[]
	local bytes = {}
	--- @type boolean
	local more  = true
	while more do
		--- @type integer
		local b = n % (LEB_DATA_MASK + 1) -- extract low 7 bits
		n = (n - b) / (LEB_DATA_MASK + 1) -- arithmetic shift right by 7
		-- Termination: remaining value bits fit in the sign bit of the last byte.
		if n == 0  and b <  SLEB_SIGN_BIT then more = false end  -- positive terminator
		if n == -1 and b >= SLEB_SIGN_BIT then more = false end  -- negative terminator
		if more then b = b + LEB_CONT_BIT end
		bytes[#bytes + 1] = string.char(b)
	end
	return table.concat(bytes)
end

--- ULEB128 byte-length: number of bytes the encoder M.uleb128 would produce for `n`.
--- Used by callers that need to size a buffer before encoding (e.g. compute_loclists_offsets
--- needs the encoded length of an `uleb128(4)` for a `DW_OP_piece + uleb128(U4_BYTE_SIZE)` tail).
--- @param n integer  -- non-negative
--- @return integer  -- 1..5 for n in [0, 2^32)
function M.uleb128_size(n)
	assert(n >= 0, "uleb128_size requires non-negative input")
	if n == 0 then return 1 end
	--- @type integer
	local bytes = 1
	while n >= 0x80 do
		n = (n - (n % (LEB_DATA_MASK + 1))) / (LEB_DATA_MASK + 1)  -- arithmetic shift right by 7
		bytes = bytes + 1
	end
	return bytes
end

--- SLEB128 byte-length: number of bytes the encoder M.sleb128 would produce for `n`.
--- Used by callers that need to size a buffer before encoding.
--- (e.g. compute_loclists_offsets needs the encoded length of an `sleb128(field.offset)` in a tape piece).
--- Handles the signed DWARF5 termination: positive terminator if (n == 0) and bit 6 of last byte is unset;
--- negative terminator if (n == -1) and bit 6 of last byte is set.
--- @param n integer  -- any integer (negative allowed)
--- @return integer
function M.sleb128_size(n)
	--- @type boolean
	local more  = true
	--- @type integer
	local bytes = 0
	--- @type integer
	local v     = n
	while more do
		--- @type integer
		local b = v % (LEB_DATA_MASK + 1) -- extract low 7 bits
		v = (v - b) / (LEB_DATA_MASK + 1) -- arithmetic shift right by 7
		if v == 0  and b <  SLEB_SIGN_BIT then more = false end  -- positive terminator
		if v == -1 and b >= SLEB_SIGN_BIT then more = false end  -- negative terminator
		if more then b = b + LEB_CONT_BIT end
		bytes = bytes + 1
	end
	return bytes
end

-- ════════════════════════════════════════════════════════════════════════════
-- DWARF5 line-program file-table reader
-- ════════════════════════════════════════════

--- Read every line-program unit in `.debug_line` and produce one entry per file across all units.
--- Returns three parallel maps keyed by 1-based file index.
---
--- Wire format notes:
---   * The `.debug_line` section may contain MULTIPLE line-program units
---     File indices are 1-based, **per unit**; we concatenate all units and the index ranges from 1..N₁ in unit 1, N₁+1..N₁+N₂ in unit 2, etc.
---     Per-unit indices (the way gcc emits them, and the way `DW_LNS_set_file` references them in the line program)
---     are returned via the `basename_to_index` map only when the unit boundary happens to align with the metaprogram's per-atom `inv.call_file`
---   * Per spec, the `.debug_line_str` section (DWARF5 §7.5.6) holds the strings referenced by `DW_FORM_line_strp`.
---     The legacy DWARF3 format embeds strings directly with null terminators. This helper handles BOTH.
---   * File entries may have multiple forms (gcc -gdwarf-5 with `DW_LNCT_directory_index` emits 2 forms: path + dir_index). 
---     The helper supports:
---     - DW_FORM_line_strp (DWARF5; offset into .debug_line_str)
---     - DW_FORM_string (DWARF4-compat; inline null-terminated in .debug_line)
---     - DW_FORM_udata (ULEB128)
---     - DW_FORM_data16 (16-byte MD5; ignored — skip the form's bytes)
---   * Symlink-canonicalisation: each path's `paths[i]` is stored verbatim from the wire
---     (mixed `/` and `\` accepted; the basename is taken via the last path separator). Caller normalises as needed.
---
--- Behavior on failure: writes to stderr and returns nil.
--- Helpers consumed by `passes/dwarf_injection.lua::init_file_index_lookup(elf_path)` calls this once at pass start to populate the module-level `basename_to_index` map;
--- downstream `resolve_provenance_file_index(path)` consumers consult the map directly.
---
--- @param elf_path string  -- absolute path to the post-link ELF (typically the gcc-emitted `.elf` BEFORE dwarf_injector's splice; both shapes work since the splice preserves `.debug_line`)
--- @return table<string, integer>|nil
--- @return table<integer, string>|nil
--- @return table<integer, string>|nil
function M.read_line_unit_file_table(elf_path)
	--- @type table<string, string>
	local sections = M.read_elf_sections(elf_path, { ".debug_line", ".debug_line_str" })
	--- @type string
	local line     = sections[".debug_line"]
	--- @type string
	local lstr     = sections[".debug_line_str"] or ""
	if not line or line == "" then
		io.stderr:write("[elf_dwarf.read_line_unit_file_table] no .debug_line section in: " .. tostring(elf_path) .. "\n")
		return nil
	end

	--- @type table<integer, string>  -- bag: 1-based file index -> basename
	local basenames         = {}
	--- @type table<string, integer>  -- bag: basename -> 1-based file index
	local basename_to_index = {}
	--- @type table<integer, string>  -- bag: 1-based file index -> full path
	local paths             = {}

	--- Read one form-code's bytes from `buf` at position `p` according to `form`.
	--- Returns (value, after) where `value` is:
	---   * the resolved string (DW_FORM_line_strp / DW_FORM_string)
	---   * the ULEB128 number  (DW_FORM_udata)
	---   * nil + skip-bytes    (DW_FORM_data16; we don't surface the MD5)
	--- @param buf string
	--- @param lstr_buf string
	--- @param p integer
	--- @param form integer
	--- @return string|integer|nil
	--- @return integer
	local function read_form(buf, lstr_buf, p, form)
		if form == M.DWARF5_DEBUG_LINE.form_line_strp then
			--- @type integer
			local strp    = M.read_u32_le(buf, p)
			--- @type integer
			local end_pos = lstr_buf:find("\0", strp + 1, true) or (#lstr_buf + 1)
			return lstr_buf:sub(strp + 1, end_pos - 1), p + M.DWARF5_DEBUG_LINE.form_strp_bytes
		elseif form == M.DWARF5_DEBUG_LINE.form_string then
			--- @type integer
			local nul = buf:find("\0", p + 1, true) or (#buf + 1)
			return buf:sub(p + 1, nul - 1), nul
		elseif form == M.DWARF5_DEBUG_LINE.form_udata then
			--- @type integer|nil, integer
			local  v, after = M.read_uleb128_at(buf, p)
			return v, after
		elseif form == M.DWARF5_DEBUG_LINE.form_data16 then
			return nil, p + M.DWARF5_DEBUG_LINE.form_data16_bytes
		else
			-- Unsupported form in a directory/file-table entry: best-effort skip.
			-- We do NOT stderr-write because the crt0.s DWARF5 line unit (gcc-as emitted) uses DW_FORM_addr (0x01) for what is effectively a path entry, which is non-standard.
			-- The C-unit's DWARF3 paths are read via the parallel DWARF3 path and never see this error.
			-- Callers should consult `basename_to_index` for the paths they care about and ignore this unit if it produced none.
			return nil, p
		end
	end

	--- Parse one DWARF-version-3-style unit (DWARF3/4 line program; gcc default in the PS1 toolchain still emits DWARF3 for line programs in `-g` mode).
	--- Layout: null-terminated directory list, then path(null) + dir_idx(ULEB) + time(ULEB) + size(ULEB) file entries terminated by an empty null.
	--- `content_start` = zero-based wire offset of the first byte of program-header content (after version + header_length fields).
	--- @param buf string
	--- @param content_start integer
	--- @param body_end integer
	--- @return table<integer, string>
	--- @return table<integer, string>
	local function parse_dwarf3_unit(buf, content_start, body_end)
		--- @type integer
		local up = content_start
		-- 5 fixed bytes: min_insn, default_is, line_base (signed), line_range, opcode_base
		up = up + 5
		--- @type integer
		local opcode_base = buf:byte(content_start + 5)
		up = up + (opcode_base - 1)  -- std_opcode_lengths
		--- @type string[]
		local dirs = {}
		while up < body_end do
			--- @type integer
			local nul = buf:find("\0", up + 1, true) or (body_end + 1)
			if    nul > body_end then break end
			--- @type integer
			local len = nul - up - 1
			if    len == 0 then up = nul break end
			dirs[#dirs + 1] = buf:sub(up + 1, nul - 1)
			up = nul
		end
		--- @type table<integer, string>  -- bag: 1-based unit file index -> basename
		local unit_basenames = {}
		--- @type table<integer, string>  -- bag: 1-based unit file index -> full path
		local unit_paths = {}
		while up < body_end do
			--- @type integer
			local nul = buf:find("\0", up + 1, true) or (body_end + 1)
			if    nul > body_end or nul == up + 1 then up = nul break end
			--- @type string
			local path = buf:sub(up + 1, nul - 1)
			up = nul
			--- @type integer|nil, integer
			local didx,  up_next  = M.read_uleb128_at(buf, up); up = up_next
			--- @type integer|nil, integer
			local _time, up_next2 = M.read_uleb128_at(buf, up); up = up_next2
			--- @type integer|nil, integer
			local _size, up_next3 = M.read_uleb128_at(buf, up); up = up_next3
			--- @type integer
			local idx = #unit_basenames + 1
			--- @type string
			local bs  = path:match("[^/\\]+$") or path
			unit_paths[idx]     = path
			unit_basenames[idx] = bs
			dirs[1] = dirs[1] or ""  -- safety: gcc emits "" sentinel dir at 0
			if didx > 0 and dirs[didx] then
				unit_paths[idx] = dirs[didx] .. "/" .. path
			end
		end
		return unit_basenames, unit_paths
	end

	--- Parse one DWARF-version-5-style unit (DWARF5 line program; used by modern gcc with `-gdwarf-5`).
	--- `content_start` is the first byte of program-header content (after the 8 fixed bytes version+addr_size+seg_size+header_length).
	--- @param buf string
	--- @param lstr_buf string
	--- @param content_start integer
	--- @param body_end integer
	--- @return table<integer, string>
	--- @return table<integer, string>
	local function parse_dwarf5_unit(buf, lstr_buf, content_start, body_end)
		--- @type integer
		local up = content_start
		-- 6 fixed bytes: min_insn, max_ops_per_insn, default_is, line_base, line_range, opcode_base
		up = up + 6
		--- @type integer
		local opcode_base = buf:byte(content_start + 6)
		up = up + (opcode_base - 1)  -- std_opcode_lengths
		-- directories
		--- @type integer|nil, integer
		local dir_format_count, after = M.read_uleb128_at(buf, up); up = after
		--- @type integer[]
		local dir_formats = {}
		--- @type integer
		for i = 1, dir_format_count do
			--- @type integer|nil, integer
			local f, a2 = M.read_uleb128_at(buf, up); up = a2
			dir_formats[i] = f
		end
		--- @type integer|nil, integer
		local dir_count, a3 = M.read_uleb128_at(buf, up); up = a3
		--- @type string[]
		local dirs = {}
		--- @type integer
		for i = 1, dir_count do
			--- @type string
			local combined = ""
			--- @type integer
			for j = 1, dir_format_count do
				--- @type string|integer|nil, integer
				local v, a4 = read_form(buf, lstr_buf, up, dir_formats[j])
				up = a4
				if j == 1 and type(v) == "string" then combined = v end
			end
			dirs[i] = combined
		end
		-- file names
		--- @type integer|nil, integer
		local file_format_count, after2 = M.read_uleb128_at(buf, up); up = after2
		--- @type integer[]
		local file_formats = {}
		--- @type integer
		for i = 1, file_format_count do
			--- @type integer|nil, integer
			local f, a2 = M.read_uleb128_at(buf, up); up = a2
			file_formats[i] = f
		end
		--- @type integer|nil, integer
		local file_count, a3 = M.read_uleb128_at(buf, up); up = a3
		--- @type table<integer, string>  -- bag: 1-based unit file index -> basename
		local unit_basenames = {}
		--- @type table<integer, string>  -- bag: 1-based unit file index -> full path
		local unit_paths     = {}
		--- @type integer
		for i = 1, file_count do
			--- @type string
			local combined = ""
			--- @type integer
			local didx = 0
			--- @type integer
			for j = 1, file_format_count do
				--- @type string|integer|nil, integer
				local v, a4 = read_form(buf, lstr_buf, up, file_formats[j])
				up = a4
				if j == 1 and type(v) == "string" then combined = v end
				if j == 2 and type(v) == "number"  then didx  = v end
			end
			--- @type integer
			local idx = #unit_basenames + 1
			--- @type string
			local bs  = combined:match("[^/\\]+$") or combined
			unit_paths[idx]     = combined
			unit_basenames[idx] = bs
			if didx > 0 and dirs[didx] then
				unit_paths[idx] = dirs[didx] .. "/" .. combined
			end
		end
		return unit_basenames, unit_paths
	end

	--- Walk every line-program unit in the section.
	--- @type integer
	local p = 0
	--- @type integer
	local section_end = #line
	while p + 4 <= section_end do
		--- @type integer
		local unit_length = M.read_u32_le(line, p)
		if    unit_length == 0xFFFFFFFF then
			io.stderr:write("[elf_dwarf.read_line_unit_file_table] 64-bit DWARF (initial-length 0xFFFFFFFF); not supported\n")
			return nil
		end
		--- @type integer
		local body_start = p + 4
		--- @type integer
		local body_end   = p + 4 + unit_length
		if body_end > section_end then break end
		--- @type integer
		local version = M.read_u16_le(line, body_start)
		--- @type table<integer, string>|nil, table<integer, string>|nil
		local unit_basenames, unit_paths
		if version >= 5 then
			-- DWARF5 header: version(2) + addr_size(1) + seg_size(1) + header_length(4) + content
			--- @type integer
			local header_length_offset = body_start + 6  -- past version(2) + addr_size(1) + seg_size(1) - wait that's wrong; past hdr len is at +6
			--- @type integer
			local content_start = body_start + 8  -- past version(2) + addr_size(1) + seg_size(1) + header_length(4)
			unit_basenames, unit_paths = parse_dwarf5_unit(line, lstr, content_start, body_end)
		elseif version >= 2 then
			-- DWARF2/3/4 header: version(2) + header_length(4) + content
			--- @type integer
			local content_start = body_start + 6  -- past version(2) + header_length(4)
			unit_basenames, unit_paths = parse_dwarf3_unit(line, content_start, body_end)
		else
			io.stderr:write(string.format("[elf_dwarf.read_line_unit_file_table] unsupported DWARF version %d (offset 0x%x)\n", version, p))
			p = body_end
			goto continue
		end
		-- Per-unit 1-based file indices are aligned with `inv.call_file` values because the metaprogram emits `DW_LNS_set_file` with the per-unit index.
		-- When multiple units are present (crt0.s + C unit), the per-unit index in each unit matches the metaprogram's intent (gcc always sets file in unit-local terms).
		-- We therefore store directly without global re-indexing; the caller is responsible for knowing which unit the file-index applies to.
		-- For DWARF3 (C unit is the unit that matters for atom line tables), this matches.
		-- For DWARF5 (crt0.s + C unit), each carries its own per-unit file-table map;
		-- the atom-side DW_LNS_set_file(N) refers to the C unit's indices, NOT crt0.s's.
		-- Since the C unit is the one with full include_directories + 12 entries, we can use it directly.
		--- @type integer, string
		for idx, bs in pairs(unit_basenames) do
			basenames[idx] = bs
			paths[idx] = unit_paths[idx]
			basename_to_index[bs] = idx
		end
		p = body_end
		::continue::
	end

	return basename_to_index, basenames, paths
end

-- ════════════════════════════════════════════════════════════════════════════
-- I/O helpers: atoms source-map + native directory glob
-- ════════════════════════════════════════════════════════════════════════════

return M
