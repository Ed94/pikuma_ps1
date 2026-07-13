--- elf_dwarf.lua — ELF32 + DWARF + atoms source-map utilities for the F'' track.
---
--- All ELF32 + DWARF-specific code lives here.
---
--- **What this module contains:**
---   - **Format-constant tables** (the byte-offset / opcode / size encyclopedias for ELF32, DWARF4 aranges, DWARF5 rnglists, DWARF line-program, MIPS).
---     Every constant carries a spec:` comment naming the spec section that defines it (convention established by F'').
---   - **I/O helpers**: little-endian byte read/write, ELF32 section walker, nm symbol reader, source-map parser, native directory glob.
---
--- **Conventions:** tabs (1/level), EmmyLua annotations, no regex,
--- Lua 5.3 compatible.

-- ════════════════════════════════════════════════════════════════════════════
-- Native dependencies
-- ════════════════════════════════════════════════════════════════════════════

-- lfs is wired into package.cpath by `duffle_paths.lua` (vendored under
-- `toolchain/lfs/lfs.dll`). Required here for native directory ops
-- (replaces the ~56ms `dir /b` subprocess with ~2ms native).
local lfs = require("lfs")

local M = {}

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
--
-- All offsets are 1-INDEXED (matching Lua string.sub convention), 
-- expressed in hex so they map directly to the wire-format byte positions in the binary file. 
-- To compute the 0-indexed file offset, subtract 1.
--
-- Example: e_shoff_offset = 0x21 means the 4-byte e_shoff field 
-- starts at string.sub byte 0x21 (= 33 in 1-indexed), i.e. file offset 0x20 (= 32).

--- spec: System V ABI gABI v1.2 §"ELF Header" (Table 1) + §"Section Header Table"
M.ELF32 = {
	magic_offset          = 0x01,         -- 4-byte magic "\127ELF" at file offset 0x00
	magic                 = "\127ELF",
	class_offset          = 0x05,         -- 1-byte; 1 = ELF32, 2 = ELF64
	class_elf32           = 1,
	endian_offset         = 0x06,         -- 1-byte; 1 = little-endian, 2 = big-endian
	endian_little         = 1,
	header_bytes          = 0x34,         -- spec: gABI v1.2 §"ELF Header" — ELF32 header is 52 bytes total
	e_shoff_offset        = 0x21,         -- 4-byte LE; section-header table file offset
	e_shentsize_offset    = 0x2F,         -- 2-byte LE; section-header entry size in bytes
	e_shnum_offset        = 0x31,         -- 2-byte LE; number of section headers
	e_shstrndx_offset     = 0x33,         -- 2-byte LE; index of section-name string table
	sh_size_bytes         = 0x28,         -- spec: gABI v1.2 §"Section Header Table" — each entry is 40 bytes
	sh_name_offset        = 0x01,         -- 4-byte LE; offset into .shstrtab
	sh_type_offset        = 0x05,         -- 4-byte LE; section type (SHT_*)
	sh_offset_offset      = 0x11,         -- 4-byte LE; section's file offset
	sh_size_offset        = 0x15,         -- 4-byte LE; section's size in bytes
	dw_dwarf32_terminator = 0xFFFFFFFF,   -- spec: DWARF4 spec §7.4 — 32-bit DWARF initial-length terminator
}

-- ----------------------------------------------------------------------------
-- DWARF4 .debug_aranges (per DWARF5 spec §7.4 — Address Range Table)
-- ----------------------------------------------------------------------------
--
-- All offsets are 1-INDEXED (matching Lua string.sub convention), in hex.

--- spec: DWARF5 spec §7.4 (Address Range Table) — 32-bit DWARF form
M.DWARF4_ARANGES = {
	unit_length_offset = 0x01,    -- 4-byte LE; length of unit body (excludes these 4 bytes)
	version_offset     = 0x05,    -- 2-byte LE; expected = 2
	cu_offset_offset   = 0x07,    -- 4-byte LE; CU DIE offset in .debug_info
	addr_size_offset   = 0x0B,    -- 1-byte;  expected = 4 (32-bit MIPS)
	seg_size_offset    = 0x0C,    -- 1-byte;  expected = 0
	entry_size         = 0x08,    -- 4-byte addr + 4-byte length (per §7.4)
	terminator_size    = 0x08,    -- 8 zero bytes (per §7.4 end-of-list marker)
	version_expected   = 2,
	addr_size_expected = 4,
	seg_size_expected  = 0,
}

-- ----------------------------------------------------------------------------
-- DWARF5 .debug_rnglists (per DWARF5 spec §2.17 + §7.21)
-- ----------------------------------------------------------------------------
--
-- All offsets are 1-INDEXED (matching Lua string.sub convention), in hex.

--- spec: DWARF5 spec §2.17 + §7.21 (Range List Table) — 32-bit DWARF form
M.DWARF5_RNGLISTS = {
	unit_length_offset    = 0x01,    -- 4-byte LE
	version_offset        = 0x05,    -- 2-byte LE; expected = 5
	addr_size_offset      = 0x07,    -- 1-byte;  expected = 4
	seg_size_offset       = 0x08,    -- 1-byte;  expected = 0
	offset_count_offset   = 0x09,    -- 4-byte LE; expected = 0
	first_entry_offset    = 0x0D,
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
--
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

--- Read a 4-byte little-endian unsigned integer from `buf` at 1-indexed offset `off`.
--- Equivalent to `string.unpack("<I4", buf, off)` but avoids the table-return shape + works under LuaJIT 2.1
--- (which has partial `string.unpack` coverage).
---
--- **Convention:** offsets are 1-indexed (matching Lua `string.sub`).
---
--- **Byte weights** are written as `0x100`, `0x10000`, `0x1000000` (i.e.
--- 2^8, 2^16, 2^24) so the LE byte positions are visually explicit:
--- byte 0 contributes its value directly; byte 1 is shifted left by 8
--- (= 0x100); byte 2 by 16 (= 0x10000); byte 3 by 24 (= 0x1000000).
---
--- @param buf string
--- @param off integer  -- 1-indexed
--- @return integer
function M.read_u32_le(buf, off)
	return buf:byte(off)
		+ buf:byte(off + 0x01) * 0x00000100
		+ buf:byte(off + 0x02) * 0x00010000
		+ buf:byte(off + 0x03) * 0x01000000
end

--- Read a 2-byte little-endian unsigned integer from `buf` at 1-indexed offset `off`.
--- (1-indexed convention; matches `M.read_u32_le`.)
--- @param buf string
--- @param off integer  -- 1-indexed
--- @return integer
function M.read_u16_le(buf, off)
	return buf:byte(off) + buf:byte(off + 0x01) * 0x00000100
end

--- Return a 4-byte little-endian byte string for `value`.
--- Caller concatenates with `..` if composing multi-word blobs.
---
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
--- **Convention:** offsets from `M.ELF32` (1-indexed for string.sub).
--- Every requested name has an entry in the returned dict; missing sections have an empty string (NOT nil)
--- so callers can do `sections[".debug_x"] or ""` for the missing case.
---
--- **Cost:** one file open + one `f:seek` + one `f:read` per section header 
--- (we walk all `e_shnum` headers regardless of how many names are requested, to find the .shstrtab first).
--- For frequent callers, pass the union of all needed sections in one call.
--  can add `.debug_info` + `.debug_loc` + `.debug_str_offsets` to the list without writing a 2nd ELF walker.
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
	if header:sub(M.ELF32.magic_offset, M.ELF32.magic_offset + 0x03) ~= M.ELF32.magic then
		io.stderr:write("[elf_dwarf.read_elf_sections] not an ELF file\n")
		f:close()
		return result
	end
	if header:byte(M.ELF32.class_offset) ~= M.ELF32.class_elf32 then
		io.stderr:write(string.format("[elf_dwarf.read_elf_sections] not ELF32 (class=%d)\n", header:byte(M.ELF32.class_offset)))
		f:close()
		return result
	end
	if header:byte(M.ELF32.endian_offset) ~= M.ELF32.endian_little then
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
--- **Why direct parsing instead of `mipsel-none-elf-nm -S`?**
--- The `nm` subprocess costs ~50ms per spawn on Windows (cmd.exe + mipsel-none-elf-nm.exe). Parsing `.symtab` ourselves is ~0ms.
--- Same return shape, same `code_` prefix filter.
---
--- **Conventions:**
--- - ELF32 symtab entry = 16 bytes (`st_name:4 + st_value:4 + st_size:4 + st_info:1 + st_other:1 + st_shndx:2`). 1-indexed for Lua string.sub.
--- - We filter on STB_GLOBAL (high nibble of st_info = 1) to match `nm`'s default (external symbols only). STB_WEAK excluded.
--- - We strip the `code_` prefix to match the previous `read_nm` output. 
--- - `st_size > 0` filter excludes undefined/imported symbols.
---
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
	-- Each entry (1-indexed): st_name at 1, st_value at 5, st_size at 9,
	-- st_info at 13, st_other at 14, st_shndx at 15.
	local SYM_ENTRY_BYTES = 0x10
	local SYM_ST_NAME     = 0x01
	local SYM_ST_VALUE    = 0x05
	local SYM_ST_SIZE     = 0x09
	local SYM_ST_INFO     = 0x0D
	local n_syms = #symtab / SYM_ENTRY_BYTES
	for i = 0, n_syms - 1 do
		local entry_off  = i * SYM_ENTRY_BYTES + 1     -- 1-indexed
		local st_info    = symtab:byte(entry_off + SYM_ST_INFO - 1)
		-- High nibble = binding (STB_LOCAL=0, STB_GLOBAL=1, STB_WEAK=2).
		-- Use math.floor(/16) instead of bit.rshift for LuaJIT 2.1 compat
		-- (LuaJIT's `>>` is 5.3+, but math.floor(x/16) works on all versions).
		local binding    = math.floor(st_info / 16)
		if binding == 0 or binding == 1 then            -- STB_LOCAL or STB_GLOBAL
			local st_size   = M.read_u32_le(symtab, entry_off + SYM_ST_SIZE  - 1)
			if st_size > 0 then
				local st_name_off = M.read_u32_le(symtab, entry_off + SYM_ST_NAME  - 1)
				-- Extract the name from .strtab (null-terminated C string).
				local name_end = strtab:find("\0", st_name_off + 1, true) or (st_name_off + 1)
				local name     = strtab:sub(st_name_off + 1, name_end - 1)
				-- Filter: keep all symbol-table symbols (atoms emit their name as the bare `<name>` since the `code_` prefix was removed from the MipsAtom_ macro).
				-- The atoms_source_map pass already filters out non-atom symbols via the source-map.txt cross-ref.
				if name and #name > 0 then
					local st_value = M.read_u32_le(symtab, entry_off + SYM_ST_VALUE - 1)
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
--
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
---
--- Algorithm:
---   - Extract the low 7 bits of `n` (LEB_DATA_MASK = 0x7F).
---   - Shift `n` right by 7 bits.
---   - If more bytes remain, OR in the continuation flag (LEB_CONT_BIT).
---   - Repeat until `n` is fully consumed.
---
--- @param n integer  -- non-negative
--- @return string
function M.uleb128(n)
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

--- SLEB128 (Signed Little-Endian Base 128) encoder. Returns the byte
--- string for the integer `n` (may be negative).
---
--- Algorithm differs from ULEB128 by the termination condition: stop when
--- the remaining bits can be inferred from the sign bit in the last byte's
--- 7-bit data payload.
---   - If `n == 0`  (no more value bits)   AND bit 6 of the data = 0 → positive terminator (sign bit says "zero-extend").
---   - If `n == -1` (sign-extended all-1s) AND bit 6 of the data = 1 → negative terminator (sign bit says "one-extend").
---
--- Without these checks, the decoder would round-trip to a different value
--- (e.g. encoding `0` as `0x80 0x00` decodes to `0` correctly but is 2 bytes long; the termination check picks the 1-byte `0x00` form).
---
--- @param n integer  -- any integer (negative allowed)
--- @return string
function M.sleb128(n)
	local bytes = {}
	local more = true
	while more do
		local b = n % (LEB_DATA_MASK + 1)               -- extract low 7 bits
		n = (n - b) / (LEB_DATA_MASK + 1)               -- arithmetic shift right by 7
		-- Termination: remaining value bits fit in the sign bit of the last byte.
		if     n == 0  and b <  SLEB_SIGN_BIT then more = false end  -- positive terminator
		if     n == -1 and b >= SLEB_SIGN_BIT then more = false end  -- negative terminator
		if more then b = b + LEB_CONT_BIT end
		bytes[#bytes + 1] = string.char(b)
	end
	return table.concat(bytes)
end

-- ════════════════════════════════════════════════════════════════════════════
-- I/O helpers: atoms source-map + native directory glob
-- ════════════════════════════════════════════════════════════════════════════

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
	local out = {}
	local cur_name, cur_words = nil, {}
	for raw in io.lines(sm_path) do
		local line = raw
		if line:match("^#") then
			local ver = line:match("^# FORMAT_VERSION%s+(%d+)")
			if ver and tonumber(ver) ~= expected_version then
				io.stderr:write(string.format(
					"[elf_dwarf.parse_source_map_file] source-map version mismatch (got %s, expected %d) in %s\n",
					ver, expected_version, sm_path))
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
			-- WORD <n>  LINE <line>  TEXT <text...>
			local _, n, _, src_line = line:find("WORD%s+(%d+)%s+LINE%s+(%d+)")
			if n and src_line then
				cur_words[#cur_words + 1] = { pos = tonumber(n), line = tonumber(src_line) }
			end
		end
	end
	return out
end

return M
