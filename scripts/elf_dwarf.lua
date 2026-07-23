--- elf_dwarf.lua — ELF32 + DWARF + atoms source-map utilities.
--- All ELF32 + DWARF-specific code lives here.
---
--- **What this module contains:**
---   - **Format-constant tables** (the byte-offset / opcode / size encyclopedias for ELF32, DWARF4 aranges, DWARF5 rnglists, DWARF line-program, MIPS).
---     Every constant carries a spec:` comment naming the spec section that defines it.
---   - **I/O helpers**: little-endian byte read/write, ELF32 section walker, nm symbol reader, source-map parser, native directory glob.
---
--- **Conventions:** tabs (1/level), EmmyLua annotations, no regex,
--- Lua 5.3 compatible.

-- ════════════════════════════════════════════════════════════════════════════
-- Native dependencies
-- ════════════════════════════════════════════════════════════════════════════

-- lfs is wired into package.cpath by `duffle_paths.lua` (vendored under `toolchain/lfs/lfs.dll`). 
local lfs = require("lfs")

local M = {}

-- ════════════════════════════════════════════════════════════════════════════
-- DWARF tag + form constants
-- ════════════════════════════════════════════
-- (DWARF5 §7.5.5 "Tag Encodings" + Table 7.1; gcc emits these exact values for the DWARF3-extension and DWARF5 line units.)

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

M.DW_FORM = {
	addr        = 0x01,
	data1       = 0x0B,
	data2       = 0x05,
	data4       = 0x06,
	string      = 0x08,
	strp        = 0x0E,
	exprloc     = 0x18,
	ref4        = 0x13,
	udata       = 0x0F,
	ref_sig8    = 0x20,
	implicit_const = 0x21,
	flag_present = 0x19,
	sec_offset  = 0x17,
}

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
--- **Wire-offset contract:** format offsets, fixed-width reader offsets, LEB/parser cursors,
--- and section-relative values are zero-based wire offsets. Only Lua string APIs receive
--- a `+ 1` conversion at their boundary (`byte`, `sub`, and `find`).
---
--- ELF/DWARF field offsets are expressed in hex so they map directly to the
--- zero-based byte positions in the binary file.


--- spec: System V ABI gABI v1.2 §"ELF Header" (Table 1) + §"Section Header Table"
M.ELF32 = {
	magic_offset          = 0x00,         -- 4-byte magic "\127ELF" at file offset 0x00
	magic                 = "\127ELF",
	class_offset          = 0x04,         -- 1-byte; 1 = ELF32, 2 = ELF64
	class_elf32           = 1,
	endian_offset         = 0x05,         -- 1-byte; 1 = little-endian, 2 = big-endian
	endian_little         = 1,
	header_bytes          = 0x34,         -- spec: gABI v1.2 §"ELF Header" — ELF32 header is 52 bytes total
	e_shoff_offset        = 0x20,         -- 4-byte LE; section-header table file offset
	e_shentsize_offset    = 0x2E,         -- 2-byte LE; section-header entry size in bytes
	e_shnum_offset        = 0x30,         -- 2-byte LE; number of section headers
	e_shstrndx_offset     = 0x32,         -- 2-byte LE; index of section-name string table
	sh_size_bytes         = 0x28,         -- spec: gABI v1.2 §"Section Header Table" — each entry is 40 bytes
	sh_name_offset        = 0x00,         -- 4-byte LE; offset into .shstrtab
	sh_type_offset        = 0x04,         -- 4-byte LE; section type (SHT_*)
	sh_offset_offset      = 0x10,         -- 4-byte LE; section's file offset
	sh_size_offset        = 0x14,         -- 4-byte LE; section's size in bytes
	dw_dwarf32_terminator = 0xFFFFFFFF,   -- spec: DWARF4 spec §7.4 — 32-bit DWARF initial-length terminator
}

-- ----------------------------------------------------------------------------
-- DWARF4 .debug_aranges (per DWARF5 spec §7.4 — Address Range Table)
-- ----------------------------------------------------------------------------
-- All offsets are zero-based wire offsets.

--- spec: DWARF5 spec §7.4 (Address Range Table) — 32-bit DWARF form
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
	-- opcode_base + line_range are 1-byte header fields; hex so they map
	-- directly to their position in the line-program header byte sequence.
	-- line_base stays signed decimal (=-5) since 0xFB obscures the spec semantics.
	opcode_base              = 0x0D,
	line_base                = -5,
	line_range               = 0x0E,
	-- Extended opcode payload sizes (include the sub-opcode byte; §6.2.5.3)
	-- Hex so they match the byte positions in the line-program wire format.
	end_sequence_payload_size = 0x01,   -- size = sub_opcode only
	set_address_payload_size  = 0x05,   -- size = sub_opcode(1) + addr(4)
}

-- ════════════════════════════════════════════════════════════════════════════
-- I/O helpers: little-endian byte read/write
-- ════════════════════════════════════════════════════════════════════════════

--- Read a 4-byte little-endian unsigned integer from `buf` at zero-based wire offset `off`.
--- Equivalent to `string.unpack("<I4", buf, off + 1)` but avoids the table-return shape + works under LuaJIT 2.1
--- (which has partial `string.unpack` coverage).
---
--- **Convention:** `off` is a zero-based wire offset; `+ 1` is applied only at the `string.byte` boundary.
---
--- **Byte weights** are written as `0x100`, `0x10000`, `0x1000000` (i.e. 2^8, 2^16, 2^24) so the LE byte positions are visually explicit:
--- byte 0 contributes its value directly; byte 1 is shifted left by 8
--- (= 0x100); byte 2 by 16 (= 0x10000); byte 3 by 24 (= 0x1000000).
--- @param buf string
--- @param off integer  -- zero-based wire offset
--- @return integer
function M.read_u32_le(buf, off)
	local byte_off = off + 1
	return buf:byte(byte_off)
		+ buf:byte(byte_off + 0x01) * 0x00000100
		+ buf:byte(byte_off + 0x02) * 0x00010000
		+ buf:byte(byte_off + 0x03) * 0x01000000
end

--- Read a 2-byte little-endian unsigned integer from `buf` at zero-based wire offset `off`.
--- (`off` is zero-based; `+ 1` is applied only at the `string.byte` boundary.)
--- @param buf string
--- @param off integer  -- zero-based wire offset
--- @return integer
function M.read_u16_le(buf, off)
	local byte_off = off + 1
	return buf:byte(byte_off) + buf:byte(byte_off + 0x01) * 0x00000100
end

-- Pure-Lua 5.3 LEB128 readers (no `bit` library). `2^shift` arithmetic matches the existing parser.
-- Offsets are 0-based; returns (value, next_pos).
-- Promoted from `local function` to M.* exports so passes/dwarf_injection.lua
-- can import them as file-scope locals per the 2nd-caller lift precedent
-- (the uleb128 + sleb128 encoders were promoted the same way).
function M.read_uleb128_at(buf, pos)
	local value, shift = 0, 0
	local len = #buf
	while pos < len do
		local b = buf:byte(pos + 1)
		value = value + (b % 0x80) * (2 ^ shift)
		shift = shift + 7
		pos   = pos + 1
		if b < 0x80 then return value, pos end
	end
	return nil, pos
end

function M.read_sleb128_at(buf, pos)
	local value, shift = 0, 0
	local len = #buf
	while pos < len do
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
function M.find_abbrev_table_end(table_bytes, table_start)
	local pos, len = table_start, #table_bytes
	if    pos >= len or table_bytes:byte(pos + 1) == 0 then return pos end
	while pos < len do
		local  _code, code_end = M.read_uleb128_at(table_bytes, pos)
		if not _code then return nil end
		pos = code_end
		local  _tag, tag_end = M.read_uleb128_at(table_bytes, pos)
		if not _tag then return nil end
		pos = tag_end
		if pos >= len then return nil end
		pos = pos + 1   -- has_children byte
		while pos < len do
			local  attr, attr_end = M.read_uleb128_at(table_bytes, pos)
			if not attr then return nil end
			pos = attr_end
			local  form, form_end = M.read_uleb128_at(table_bytes, pos)
			if not form then return nil end
			pos = form_end
			if attr == 0 and form == 0 then break end
			if form == DW_FORM_implicit_const then
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
local function read_c_string_at(buf, off)
	local len = #buf
	local start = off
	while off < len and buf:byte(off + 1) ~= 0 do off = off + 1 end
	return buf:sub(start + 1, off)
end

-- Walk the .debug_abbrev table starting at 0-based offset `table_start` and return a list of declarations:
-- {code, tag, has_children, attrs={ {name, form}, ... }}.
-- Stops at the table terminator.
local function parse_abbrev_table(table_bytes, table_start)
	local table_end = M.find_abbrev_table_end(table_bytes, table_start)
	if not table_end then return nil, "no terminator" end
	local decls = {}
	local pos = table_start
	while pos < table_end do
		local  code, code_end = M.read_uleb128_at(table_bytes, pos)
		if not code then return nil, "truncated code" end
		pos = code_end
		local  tag, tag_end = M.read_uleb128_at(table_bytes, pos)
		if not tag then return nil, "truncated tag" end
		pos = tag_end
		local has_children = table_bytes:byte(pos + 1)
		pos = pos + 1
		local attrs = {}
		while true do
			local  attr, attr_end = M.read_uleb128_at(table_bytes, pos)
			if not attr then return nil, "truncated attr" end
			pos = attr_end
			local form, form_end = M.read_uleb128_at(table_bytes, pos)
			if not form then return nil, "truncated form" end
			pos = form_end
			if attr == 0 and form == 0 then break end
			attrs[#attrs + 1] = { name = attr, form = form }
			if form == DW_FORM_implicit_const then
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
local function read_form_value(buf, str_buf, pos, form)
	if form == M.DW_FORM.addr then
		return M.read_u32_le(buf, pos), pos + 4
	elseif form == M.DW_FORM.string then
		local s = read_c_string_at(buf, pos)
		return s, pos + #s + 1
	elseif form == M.DW_FORM.strp then
		-- DW_FORM_strp: 4-byte offset into .debug_str.
		local strp_off = M.read_u32_le(buf, pos)
		return read_c_string_at(str_buf, strp_off), pos + 4
	elseif form == M.DW_FORM.udata then return M.read_uleb128_at(buf, pos)
	elseif form == M.DW_FORM.data1 then return buf:byte(pos + 1), pos + 1
	elseif form == M.DW_FORM.data2 then return M.read_u16_le(buf, pos), pos + 2
	elseif form == M.DW_FORM.data4 then return M.read_u32_le(buf, pos), pos + 4
	elseif form == M.DW_FORM.ref4  then return M.read_u32_le(buf, pos), pos + 4
	elseif form == M.DW_FORM.sec_offset then
		-- DW_FORM_sec_offset: 4-byte offset (size depends on DWARF version;
		-- on DWARF5 32-bit it's always 4 bytes).
		return M.read_u32_le(buf, pos), pos + 4
	elseif form == M.DW_FORM.flag_present then
		return 1, pos
	elseif form == M.DW_FORM.exprloc then
		-- DW_FORM_exprloc: ULEB byte count + that many bytes of DW_OP_*.
		local  len, ne = M.read_uleb128_at(buf, pos)
		if not len then return nil, pos end
		return nil, ne + len
	elseif form == DW_FORM_implicit_const then
		-- The constant is declared in the abbrev; no value bytes in the DIE.
		return nil, pos
	elseif form == M.DW_FORM.ref_sig8 then
		-- DW_FORM_ref_sig8 (DWARF5 §7.4.2): an 8-byte value identifying a type
		-- by signature. The low 4 bytes (LE) are the type signature (content hash);
		-- the high 4 bytes (LE) are a CU-relative offset into the matching type unit.
		-- Consumers use the low 4 to look up the type unit (see M.find_type_unit_by_signature)
		-- then the high 4 to resolve the specific type within it.
		-- Return the low 4 as the primary value to preserve the (value, next_pos) shape;
		-- the high 4 is exposed via M.read_ref_sig8 (which returns both halves).
		local _, _, next_pos = M.read_ref_sig8(buf, pos)
		return M.read_u32_le(buf, pos), next_pos
	else
		return nil, pos
	end
end

--- Read a `DW_FORM_ref_sig8` value at 0-based offset `pos` from `buf`.
--- Returns the low 4 bytes (LE) as `low`, the high 4 bytes (LE) as `high`, and
--- the cursor position after the 8-byte value as `next_pos`.
--- Callers that need the full type-unit + type-offset pair
--- (e.g. to resolve a type identifier embedded as a signature)
--- should use this directly rather than going through `read_form_value`,
--- which only exposes the low 4 bytes to preserve its existing (value, next_pos) return shape.
--- @param buf string
--- @param pos integer  -- zero-based wire offset
--- @return integer  -- low 4 bytes (LE), the type signature
--- @return integer  -- high 4 bytes (LE), the offset within the matching type unit
--- @return integer  -- cursor after the 8-byte value
function M.read_ref_sig8(buf, pos)
	return M.read_u32_le(buf, pos), M.read_u32_le(buf, pos + 4), pos + 8
end

-- DWARF5 §7.5.6 (Type Entries).
-- Walk all units in `info` and return the 0-based offset of the first unit
-- whose `DW_AT_type_signature` (8-byte value at the end of the unit header) equals `target_sig`.
-- The signature is interpreted as two 32-bit halves (low/high) per the read_ref_sig8 contract;
-- we match both halves (i.e. the 8-byte value as a whole). Returns nil if no matching unit exists.
--
-- Unit header layout (from pos 0):
--   unit_length(4) + version(2) + unit_type(1) + address_size(1) + debug_abbrev_offset(4)
--   -- followed by type_unit_specific fields:
--   type_signature(8) + type_offset(4)
-- The type_signature is at byte offset 8 of the body (right after debug_abbrev_offset).
-- @param info string  -- the .debug_info section bytes
-- @param target_sig_lo integer  -- low 4 bytes (LE) of the desired signature
-- @param target_sig_hi integer  -- high 4 bytes (LE) of the desired signature
-- @return integer|nil, integer|nil  -- unit offset, type_offset within the unit
function M.find_type_unit_by_signature(info, target_sig_lo, target_sig_hi)
	local pos = 0
	local section_len = #info
	while pos + 4 < section_len do
		local unit_length = M.read_u32_le(info, pos)
		if unit_length == 0xFFFFFFFF then
			return nil, nil  -- DWARF64 not supported
		end
		-- unit_length is the body size, NOT including the 4-byte unit_length field itself.
		local body_start = pos + 4
		local body_end   = body_start + unit_length
		if body_end > section_len then
			return nil, nil  -- malformed
		end
		-- Per DWARF5 §7.5.6, the type_unit (DW_UT_type = 0x02) body layout is:
		--   0:  version (2)
		--   2:  unit_type (1) -- DW_UT_type = 0x02
		--   3:  address_size (1)
		--   4:  debug_abbrev_offset (4)
		--   8:  type_signature (8)
		--   16: type_offset (4)
		--   20: <children>
		if body_end - body_start >= 20 then
			-- read_ref_sig8 / write_u32_le / etc. are 1-indexed (string:byte);
			-- pos / body_start / body_end are 0-based wire offsets, so the
			-- 1-indexed byte at 0-based wire offset X is string:byte(X + 1).
			-- Per DWARF5 §7.5.6, the type_unit body is laid out as:
			--   byte 0-1: version (2)
			--   byte 2:   unit_type (1) -- DW_UT_type = 0x02
			--   byte 3:   address_size (1)
			--   byte 4-7: debug_abbrev_offset (4)
			--   byte 8-15: type_signature (8)
			--   byte 16-19: type_offset (4)
			local unit_type = info:byte(body_start + 2 + 1)  -- 0-based +2 = unit_type in 1-indexed
			if unit_type == 0x02 then  -- DW_UT_type
				local sig_lo, sig_hi, _ = M.read_ref_sig8(info, body_start + 8)  -- 0-based +8 = type_signature in 1-indexed
				if sig_lo == target_sig_lo and sig_hi == target_sig_hi then
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
--- @param elf_path Path
--- @param section_names string[]  -- list of section names to read
--- @return table<string, string>
function M.read_elf_sections(elf_path, section_names)
	-- Initialize result with all requested names set to "" so callers can do `sections[X] 
	-- or ""` for missing sections without nil-checks.
	local result = {}
	for _, name in ipairs(section_names) do result[name] = "" end

	-- O(1) lookup set.
	local wanted = {}
	for _, name in ipairs(section_names) do wanted[name] = true end

	-- Existence check (lfs.attributes avoids an io.open-vs-fail race).
	if lfs.attributes(elf_path, "mode") ~= "file" then
		io.stderr:write(string.format("[elf_dwarf.read_elf_sections] ELF not found: %s\n", elf_path))
		return result
	end

	local f = io.open(elf_path, "rb")
	if not f then
		io.stderr:write(string.format("[elf_dwarf.read_elf_sections] io.open failed: %s\n", elf_path))
		return result
	end

	-- Read the ELF32 header.
	local header = f:read(M.ELF32.header_bytes)
	if not header or #header < M.ELF32.header_bytes then
		io.stderr:write("[elf_dwarf.read_elf_sections] ELF too small for ELF32 header\n")
		f:close()
		return result
	end

	-- Sanity-check magic + class + endianness.
	if header:sub(M.ELF32.magic_offset + 1, M.ELF32.magic_offset + 0x04) ~= M.ELF32.magic then
		io.stderr:write("[elf_dwarf.read_elf_sections] not an ELF file\n")
		f:close()
		return result
	end
	if header:byte(M.ELF32.class_offset + 1) ~= M.ELF32.class_elf32 then
		io.stderr:write(string.format("[elf_dwarf.read_elf_sections] not ELF32 (class=%d)\n", header:byte(M.ELF32.class_offset + 1)))
		f:close()
		return result
	end
	if header:byte(M.ELF32.endian_offset + 1) ~= M.ELF32.endian_little then
		io.stderr:write("[elf_dwarf.read_elf_sections] not little-endian; unsupported\n")
		f:close()
		return result
	end

	-- Parse section-header table location + dimensions from the header.
	local e_shoff     = M.read_u32_le(header, M.ELF32.e_shoff_offset)
	local e_shentsize = M.read_u16_le(header, M.ELF32.e_shentsize_offset)
	local e_shnum     = M.read_u16_le(header, M.ELF32.e_shnum_offset)
	local e_shstrndx  = M.read_u16_le(header, M.ELF32.e_shstrndx_offset)

	-- Read the section-header string table (.shstrtab) so we can resolve section names from their `sh_name` offsets.
	f:seek("set", e_shoff + e_shstrndx * e_shentsize)
	local strtab_hdr = f:read(e_shentsize)
	if not strtab_hdr or #strtab_hdr < e_shentsize then
		io.stderr:write("[elf_dwarf.read_elf_sections] could not read .shstrtab header\n")
		f:close()
		return result
	end
	local strtab_offset = M.read_u32_le(strtab_hdr, M.ELF32.sh_offset_offset)
	local strtab_size   = M.read_u32_le(strtab_hdr, M.ELF32.sh_size_offset)
	f:seek("set", strtab_offset)
	local strtab = f:read(strtab_size) or ""

	-- Walk all section headers; collect (offset, size) for the wanted names.
	local function read_section_bytes(sh_offset, sh_size)
		f:seek("set", sh_offset)
		return f:read(sh_size) or ""
	end

	for sh_idx = 0, e_shnum - 1 do
		f:seek("set", e_shoff + sh_idx * e_shentsize)
		local sh = f:read(e_shentsize)
		if not sh or #sh < e_shentsize then break end
		local sh_name   = M.read_u32_le(sh, M.ELF32.sh_name_offset)
		local sh_offset = M.read_u32_le(sh, M.ELF32.sh_offset_offset)
		local sh_size   = M.read_u32_le(sh, M.ELF32.sh_size_offset)

		-- Extract the name (null-terminated C string in strtab).
		local name_end = strtab:find("\0", sh_name + 1, true) or (sh_name + 1)
		local name     = strtab:sub(sh_name + 1, name_end - 1)
		if wanted[name] then
			result[name] = read_section_bytes(sh_offset, sh_size)
		end
	end

	f:close()
	return result
end

--- Read ELF symbol addresses by walking the `.symtab` + `.strtab` sections directly (no `nm` subprocess). 
--- Returns a map `{name -> {addr, size_bytes}}` for every `code_<name>` symbol.
---
--- **Conventions:**
--- - ELF32 symtab entry = 16 bytes (`st_name:4 + st_value:4 + st_size:4 + st_info:1 + st_other:1 + st_shndx:2`); offsets within each entry are zero-based wire offsets.
--- - Direct Lua `string.byte`/`string.sub`/`string.find` boundaries receive `+ 1`.
--- - We filter on STB_GLOBAL (high nibble of st_info = 1) to match `nm`'s default (external symbols only). STB_WEAK excluded.
--- - We strip the `code_` prefix to match the previous `read_nm` output. 
--- - `st_size > 0` filter excludes undefined/imported symbols.
--- @param elf_path Path
--- @return table<string, {integer, integer}>
function M.read_nm(elf_path)
	local addrs = {}

	-- Read .symtab + .strtab via the existing ELF walker (no subprocess).
	local sections = M.read_elf_sections(elf_path, {".symtab", ".strtab"})
	local symtab   = sections[".symtab"]
	local strtab   = sections[".strtab"]
	if not symtab or not strtab or #symtab == 0 or #strtab == 0 then
		-- No symbol table (e.g. stripped ELF). Return empty.
		return addrs
	end

	-- Iterate the 16-byte ELF32 symtab entries.
	-- Each entry (zero-based): st_name at 0, st_value at 4, st_size at 8, st_info at 12, st_other at 13, st_shndx at 14.
	local SYM_ENTRY_BYTES = 0x10
	local SYM_ST_NAME     = 0x00
	local SYM_ST_VALUE    = 0x04
	local SYM_ST_SIZE     = 0x08
	local SYM_ST_INFO     = 0x0C
	local n_syms = #symtab / SYM_ENTRY_BYTES
	for i = 0, n_syms - 1 do
		local entry_off  = i * SYM_ENTRY_BYTES
		local st_info    = symtab:byte(entry_off + SYM_ST_INFO + 1)
		-- High nibble = binding (STB_LOCAL=0, STB_GLOBAL=1, STB_WEAK=2).
		-- Use math.floor(/16) instead of bit.rshift for LuaJIT 2.1 compat
		-- (LuaJIT's `>>` is 5.3+, but math.floor(x/16) works on all versions).
		local binding    = math.floor(st_info / 16)
		if binding == 0 or binding == 1 then            -- STB_LOCAL or STB_GLOBAL
			local st_size   = M.read_u32_le(symtab, entry_off + SYM_ST_SIZE)
			if st_size > 0 then
				local st_name_off = M.read_u32_le(symtab, entry_off + SYM_ST_NAME)
				-- Extract the name from .strtab (null-terminated C string).
				local name_end = strtab:find("\0", st_name_off + 1, true) or (st_name_off + 1)
				local name     = strtab:sub(st_name_off + 1, name_end - 1)
				-- Filter: keep all symbol-table symbols (atoms emit their name as the bare `<name>` since the `code_` prefix was removed from the MipsAtom_ macro).
				-- The atoms_source_map pass already filters out non-atom symbols via the source-map.txt cross-ref.
				if name and #name > 0 then
					local st_value = M.read_u32_le(symtab, entry_off + SYM_ST_VALUE)
					addrs[name] = { st_value, st_size }
				end
			end
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
local LEB_CONT_BIT = 0x80

-- Low 7 bits of each LEB128 byte. The actual data payload.
local LEB_DATA_MASK = 0x7F

-- Bit 6 of the 7-bit data (i.e. 0x40). For SLEB128: the sign-bit position used by the decoder for sign extension.
-- Encoders MUST stop when the next byte would be redundant AND the sign bit in the last byte matches the value's sign.
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
	local bytes = {}
	repeat
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
	local bytes = {}
	local more = true
	while more do
		local b = n % (LEB_DATA_MASK + 1) -- extract low 7 bits
		n = (n - b) / (LEB_DATA_MASK + 1) -- arithmetic shift right by 7
		-- Termination: remaining value bits fit in the sign bit of the last byte.
		if     n == 0  and b <  SLEB_SIGN_BIT then more = false end  -- positive terminator
		if     n == -1 and b >= SLEB_SIGN_BIT then more = false end  -- negative terminator
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
	local more = true
	local bytes = 0
	local v = n
	while more do
		local b = v % (LEB_DATA_MASK + 1) -- extract low 7 bits
		v = (v - b) / (LEB_DATA_MASK + 1) -- arithmetic shift right by 7
		if     v == 0  and b <  SLEB_SIGN_BIT then more = false end  -- positive terminator
		if     v == -1 and b >= SLEB_SIGN_BIT then more = false end  -- negative terminator
		if more then b = b + LEB_CONT_BIT end
		bytes = bytes + 1
	end
	return bytes
end

-- ════════════════════════════════════════════════════════════════════════════
-- I/O helpers: atoms source-map + native directory glob
-- ════════════════════════════════════════════════════════════════════════════

--- Parse a FORMAT_VERSION <expected_version> atoms-meta file (sourcemap or provenance).
--- Shared by M.parse_source_map_file + M.parse_provenance_file.
--- The two callers differ only in how they parse WORD lines; that's `extract_word(line)`.
--- Returns the standard `{name -> {total, words}}` shape.
--- Returns `{}` on format-version mismatch (and logs to stderr).
--- @param path             string
--- @param expected_version integer
--- @param extract_word     fun(line: string): table|nil  -- caller-supplied per-line parser
--- @return table<string, table>
function M.parse_atom_records(path, expected_version, extract_word)
	local out = {}
	local cur_name, cur_words = nil, {}
	for raw in io.lines(path) do
		local line = raw
		if line:match("^#") then
			local ver = line:match("^# FORMAT_VERSION%s+(%d+)")
			if ver and tonumber(ver) ~= expected_version then
				io.stderr:write(string.format(
					"[elf_dwarf.parse_atom_records] version mismatch (got %s, expected %d) in %s\n",
					ver, expected_version, path))
				return {}
			end
			-- skip other comments
		elseif line:sub(1, 4) == "ATOM" then
			-- ATOM <name> "<abs-source-path>" <total>
			local _, _, name = line:find("ATOM%s+(%S+)%s+\"[^\"]*\"%s+(%d+)")
			if name then
				cur_name  = name
				cur_words = {}
				out[name] = { total = 0, words = cur_words }
			end
		elseif line == "ENDATOM" then
			-- Update the recorded total from the entries count
			-- (matches the `lines[1] = lines[1]:gsub(" 0$", " " .. total)` patch in atoms_source_map.lua:170).
			if cur_name and out[cur_name] then
				out[cur_name].total = #cur_words
			end
			cur_name, cur_words = nil, {}
		elseif line:sub(1, 4) == "WORD" and cur_name then
			local field = extract_word(line)
			if field then
				cur_words[#cur_words + 1] = field
			end
		end
	end
	return out
end

--- Parse a FORMAT_VERSION <expected_version> `*.atoms.sourcemap.txt` file.
--- Returns `{name -> {total = N, words = {{pos, line}, ...}}}`.
--- Returns `{}` on format-version mismatch (and logs to stderr).
---
--- **Wire format** (emitted by `passes/atoms_source_map.lua`):
--- ```
--- # FORMAT_VERSION <n>
--- ATOM <name> "<abs-source-path>" <total>
--- WORD <n> LINE <line> TEXT <text...>
--- ...
--- ENDATOM
--- ```
---
--- **Conventions:** the in-memory shape uses `{pos, line, text}`
--- (`atoms_source_map.lua:142`); the `.txt` file uses `WORD <n>` so the parser maps `n` → `pos` field name.
--- @param sm_path Path
--- @param expected_version integer  -- expected FORMAT_VERSION line
--- @return table<string, table>
function M.parse_source_map_file(sm_path, expected_version)
	return M.parse_atom_records(sm_path, expected_version, function(line)
		local _, n, _, src_line = line:find("WORD%s+(%d+)%s+LINE%s+(%d+)")
		if n and src_line then
			return { pos = tonumber(n), line = tonumber(src_line) }
		end
	end)
end

--- Parse a FORMAT_VERSION <expected_version> `*.atoms.provenance.txt` file.
--- Returns `{name -> {total = N, words = {{pos, call_file, call_line, comp_name, comp_file, comp_line}, ...}}}`.
--- Returns `{}` on format-version mismatch (and logs to stderr).
---
--- **Wire format** (emitted by `passes/atoms_source_map.lua`):
--- ```
--- # FORMAT_VERSION <n>
--- ATOM <name> "<abs-source-path>" <total>
--- WORD <n>  CALL <src-file>:<src-line>  RAW
--- WORD <n>  CALL <src-file>:<src-line>  MACRO <comp_name> "<comp-file>:<comp-line>"
--- ...
--- ENDATOM
--- ```
---
--- **Used by** `passes/dwarf_injection.lua` to:
---   - group consecutive MACRO rows into component invocations (one `DW_TAG_inlined_subroutine` each)
---   - emit abstract `DW_TAG_subprogram` per unique component name
---   - extend `.debug_line` so stepping into a `mac_X(...)` lands on the component's source line.
--- @param prov_path string  -- path to *.atoms.provenance.txt
--- @param expected_version integer  -- expected FORMAT_VERSION line
--- @return table<string, table>
function M.parse_provenance_file(prov_path, expected_version)
	return M.parse_atom_records(prov_path, expected_version, function(line)
		-- Two accepted shapes:
		--   WORD <n>  CALL <call-file>:<call-line>  RAW
		--   WORD <n>  CALL <call-file>:<call-line>  MACRO <comp_name> "<comp-file>:<comp-line>"
		local pos, call_file, call_line, comp_name, comp_file, comp_line =
			line:match('WORD%s+(%d+)%s+CALL%s+(.-):(%d+)%s+MACRO%s+(%S+)%s+"([^"]*):(%d+)"')
		if pos then
			return {
				pos       = tonumber(pos),
				call_file = call_file,
				call_line = tonumber(call_line),
				comp_name = comp_name,
				comp_file = comp_file,
				comp_line = tonumber(comp_line),
			}
		end
		-- RAW row.
		local raw_pos, raw_file, raw_line = line:match('WORD%s+(%d+)%s+CALL%s+(.-):(%d+)%s+RAW')
		if raw_pos then
			return {
				pos       = tonumber(raw_pos),
				call_file = raw_file,
				call_line = tonumber(raw_line),
				comp_name = nil,
				comp_file = nil,
				comp_line = nil,
			}
		end
	end)
end

return M
