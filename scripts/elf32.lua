-- elf32.lua — Pure-Lua ELF32 format helpers with no lfs / no lpeg dependency.
-- The reload helper's `parse_manifest` (scripts/pcsx_debug_helper/reload.lua) 
-- and the metaprogram's `read_elf_sections` + `read_nm` (scripts/elf_dwarf.lua)
-- both parsed ELF32 headers from wire bytes.
--
-- This module contains the format constants and the byte-level walker.
--- The metaprogram side keeps `read_u32_le` / `read_u16_le` as local forwarders; the helper side calls `E.*` directly.
--
-- **Adapter contract (explicit pass style):**
-- The helper VM's `Support.File` exposes byte-read methods that require `self` (fileffi.lua:225-227),
-- so callers wrap once in a 1-line adapter that strips `self`.
-- The parsers here operate on the unwrapped form.
-- Reads are flat function calls — `E.read_u8(adapter, off)`, `E.read_u32(adapter, off)`, `E.size(adapter)`.
--   read_u8(adapter, off)   -> integer | nil
--   read_u16(adapter, off)  -> integer | nil
--   read_u32(adapter, off)  -> integer | nil
--   size(adapter)           -> integer
--
-- **Convention:** every offset in the constants tables is a zero-based wire offset.
-- The `+ 1` conversion happens only at the `string.byte` boundary inside the readers.
--
-- spec: System V ABI gABI v1.2 §"ELF Header" (Table 1) + §"Section Header Table"
-- spec: System V ABI gABI v1.2 §"Symbol Table" (Elf32_Sym layout)

local M = {}

-- ════════════════════════════════════════════════════════════════════════════
-- Little-endian readers (bit-weighted accumulator, math.floor only)
-- ════════════════════════════════════════════════════════════════════════════

--- Read a 4-byte little-endian unsigned integer from `adapter` at zero-based wire offset `off`.
---
--- Bit weights are written as `0x100`, `0x10000`, `0x1000000` (i.e. 2^8, 2^16, 2^24) so the LE byte positions are visually explicit:
--- byte 0 contributes its value directly;
--- byte 1 is shifted left by 8; byte 2 by 16; byte 3 by 24.
---
--- math.floor (not LuaJIT's `>>`) keeps the body portable across LuaJIT 2.0/2.1 and plain Lua 5.x. `string.byte` receives `+ 1` at the boundary.
---
--- **Call form:** explicit-pass. The reader receives `adapter` as the first positional argument and the offset as the second; no `self` is passed.
--- Test fixtures declare `function(offset) ... end` and the parsers call them via dot syntax `adapter.read_u8_at(off)`.
--- The colon form `adapter:read_u8_at(off)` would prepend the adapter table as `offset` and break the contract.
--- @param adapter table
--- @param off     integer  -- zero-based wire offset
--- @return integer|nil
function M.read_u32(adapter, off)
	return adapter.read_u8_at(off)
		+ adapter.read_u8_at(off + 0x01) * 0x00000100
		+ adapter.read_u8_at(off + 0x02) * 0x00010000
		+ adapter.read_u8_at(off + 0x03) * 0x01000000
end

--- Read a 2-byte little-endian unsigned integer from `adapter` at zero-based wire offset `off`.
--- @param adapter table
--- @param off integer  -- zero-based wire offset
--- @return integer|nil
function M.read_u16(adapter, off)
	return adapter.read_u8_at(off)
		+ adapter.read_u8_at(off + 0x01) * 0x00000100
end

--- Read a 1-byte unsigned integer from `adapter` at zero-based wire offset `off`.
--- @param adapter table
--- @param off integer  -- zero-based wire offset
--- @return integer|nil
function M.read_u8(adapter, off)
	return adapter.read_u8_at(off)
end

--- Total adapter byte length.
--- @param adapter table
--- @return integer
function M.size(adapter)
	return adapter.read_size()
end

--- Forwarders kept for backward compat with scripts/elf_dwarf.lua.
--- The metaprogram side keeps `read_u32_le` / `read_u16_le`;
--- both layers now use the same byte-level helpers under the hood.
function M.read_u32_le(buf, off)
	local byte_off = off + 1
	return buf:byte(byte_off)
		+ buf:byte(byte_off + 0x01) * 0x00000100
		+ buf:byte(byte_off + 0x02) * 0x00010000
		+ buf:byte(byte_off + 0x03) * 0x01000000
end

--- Read a 2-byte little-endian unsigned integer from `buf` at zero-based wire offset `off`.
--- @param buf string
--- @param off integer  -- zero-based wire offset
--- @return integer
function M.read_u16_le(buf, off)
	local byte_off = off + 1
	return buf:byte(byte_off) + buf:byte(byte_off + 0x01) * 0x00000100
end

-- ════════════════════════════════════════════════════════════════════════════
-- Format constants
-- ════════════════════════════════════════════════════════════════════════════

-- ELF format constants (System V ABI gABI v1.2).
M.ELFCLASS32  = 1    -- spec: gABI v1.2 §"ELF Header" — EI_CLASS byte
M.ELFDATA2LSB = 1    -- spec: gABI v1.2 §"ELF Header" — EI_DATA byte
M.EM_MIPS     = 8    -- spec: gABI v1.2 §"Machine Information" — MIPS architecture

-- Section type constants (System V ABI gABI v1.2 §"Section Header Table").
M.SHT_SYMTAB = 2     -- spec: gABI v1.2 §"Section Types" — symbol table
M.SHT_STRTAB = 3     -- spec: gABI v1.2 §"Section Types" — string table
M.SHT_NOBITS = 8     -- spec: gABI v1.2 §"Section Types" — no space in file

-- Section flag constants (System V ABI gABI v1.2 §"Section Header Table").
M.SHF_WRITE     = 0x1 -- spec: gABI v1.2 §"Section Attributes" — writable
M.SHF_ALLOC     = 0x2 -- spec: gABI v1.2 §"Section Attributes" — occupies memory
M.SHF_EXECINSTR = 0x4 -- spec: gABI v1.2 §"Section Attributes" — executable

-- ---------------------------------------------------------------------------
-- ELF32 header layout (System V ABI gABI v1.2 §"ELF Header" Table 1)
-- ---------------------------------------------------------------------------
-- All offsets are zero-based wire offsets. The header is 52 bytes total (header_bytes = 0x34 = 52).
M.ELF32_HEADER = {
	magic_offset         = 0x00,  -- 4 bytes; expected "\127ELF"
	magic                = "\127ELF",
	class_offset         = 0x04,  -- 1 byte;  1 = ELF32, 2 = ELF64
	endian_offset        = 0x05,  -- 1 byte;  1 = little-endian, 2 = big-endian
	header_bytes         = 0x34,  -- ELF32 header is 52 bytes total
	e_entry_offset       = 0x18,  -- 4-byte LE; entry-point virtual address
	e_shoff_offset       = 0x20,  -- 4-byte LE; section-header table file offset
	e_shentsize_offset   = 0x2E,  -- 2-byte LE; section-header entry size in bytes
	e_shnum_offset       = 0x30,  -- 2-byte LE; number of section headers
	e_shstrndx_offset    = 0x32,  -- 2-byte LE; index of section-name string table
}

-- ---------------------------------------------------------------------------
-- ELF32 section-header layout (System V ABI gABI v1.2 §"Section Header Table")
-- ---------------------------------------------------------------------------
-- Each entry is 40 bytes (sh_entsize_bytes = 0x28 = 40);
-- zero-based, field offsets relative to the start of the entry.
M.ELF32_SECTION = {
	sh_name_offset    = 0x00,  -- 4-byte LE; offset into .shstrtab
	sh_type_offset    = 0x04,  -- 4-byte LE; section type (SHT_*)
	sh_flags_offset   = 0x08,  -- 4-byte LE; section flags (SHF_*)
	sh_addr_offset    = 0x0C,  -- 4-byte LE; virtual address at execution
	sh_offset_offset  = 0x10,  -- 4-byte LE; section's file offset
	sh_size_offset    = 0x14,  -- 4-byte LE; section's size in bytes
	sh_link_offset    = 0x18,  -- 4-byte LE; link to a related section
	sh_entsize_bytes  = 0x28,  -- spec: gABI v1.2 §"Section Header Table" — 40 bytes per entry
}

-- ---------------------------------------------------------------------------
-- ELF32 symbol-table entry layout (System V ABI gABI v1.2 §"Symbol Table")
-- ---------------------------------------------------------------------------
-- Each entry is 16 bytes (sym_entry_bytes = 0x10 = 16);
-- zero-based, field offsets relative to the start of the entry.
M.ELF32_SYM = {
	st_name          = 0x00,  -- 4-byte LE; offset into the linked string table
	st_value         = 0x04,  -- 4-byte LE; symbol value (address / absolute)
	st_size          = 0x08,  -- 4-byte LE; symbol size in bytes
	st_info          = 0x0C,  -- 1 byte;  binding (high nibble) + type (low nibble)
	sym_entry_bytes  = 0x10,  -- spec: gABI v1.2 §"Symbol Table" — 16 bytes per entry
}

-- DWARF32 initial-length terminator (DWARF4 §7.4) — kept here so the metaprogram's elf_dwarf.lua can drop its own copy of the same constant.
M.dw_dwarf32_terminator = 0xFFFFFFFF

-- ════════════════════════════════════════════════════════════════════════════
-- Adapter validation
-- ════════════════════════════════════════════════════════════════════════════

--- Validate that `adapter` exposes the byte-read surface.
--- Returns true on success, false + a stable error code on failure.
--- The helper side calls this before parse_manifest to reject callers before any byte is read.
--- @param adapter any
--- @return boolean, string|nil
function M.validate_adapter(adapter)
	if type(adapter) ~= "table" then return false, "bad_file_adapter" end
	if type(adapter.read_u8_at)  ~= "function" then return false, "bad_file_adapter" end
	if type(adapter.read_u16_at) ~= "function" then return false, "bad_file_adapter" end
	if type(adapter.read_u32_at) ~= "function" then return false, "bad_file_adapter" end
	if type(adapter.read_size)   ~= "function" then return false, "bad_file_adapter" end
	return true, nil
end

-- ════════════════════════════════════════════════════════════════════════════
-- String-table reader
-- ════════════════════════════════════════════════════════════════════════════

--- Extract a NUL-terminated C string from `strtab` at zero-based offset `off`.
--- Returns nil if `off` is out of range or the string is not NUL-terminated.
--- @param strtab string
--- @param off integer
--- @return string|nil
function M.get_str(strtab, off)
	if off < 0 or off >= #strtab then return nil end
	local  end_pos = strtab:find("\0", off + 1, true)
	if not end_pos then return nil end
	return strtab:sub(off + 1, end_pos - 1)
end

-- ════════════════════════════════════════════════════════════════════════════
-- Header / section / symbol walkers
-- ════════════════════════════════════════════════════════════════════════════

--- Read the ELF32 header through `adapter` and validate the magic, class, and data encoding.
--- Returns a table on success:
---   { e_entry, e_shoff, e_shentsize, e_shnum, e_shstrndx, error = nil }
--- On failure returns nil + a stable error code:
---   bad_magic, unsupported_elf_class, unsupported_elf_data, truncated_header
--- The header's machine field is NOT validated here — callers (e.g. the helper's prime path) decide whether to require EM_MIPS before symbol reads.
--- @param adapter table
--- @return table|nil, string|nil
function M.parse_elf32_headers(adapter)
	local  ok, err = M.validate_adapter(adapter)
	if not ok then return nil, err end

	-- 4-byte magic: 0x7F 'E' 'L' 'F'.
	-- The byte readers take the adapter explicitly.
	-- The production `Support.File` adapter is wrapped by the caller to drop its implicit `self` so the parser shape is flat pass-style.
	local b1 = M.read_u8(adapter, 0)
	local b2 = M.read_u8(adapter, 1)
	local b3 = M.read_u8(adapter, 2)
	local b4 = M.read_u8(adapter, 3)
	if not (b1 and b2 and b3 and b4)
		or not (b1 == 0x7f and b2 == 0x45 and b3 == 0x4c and b4 == 0x46) then
		return nil, "bad_magic"
	end

	local class = M.read_u8(adapter, M.ELF32_HEADER.class_offset)
	if    class ~= M.ELFCLASS32 then
		return nil, "unsupported_elf_class"
	end

	local data = M.read_u8(adapter, M.ELF32_HEADER.endian_offset)
	if    data ~= M.ELFDATA2LSB then
		return nil, "unsupported_elf_data"
	end

	local e_entry     = M.read_u32(adapter, M.ELF32_HEADER.e_entry_offset)
	local e_shoff     = M.read_u32(adapter, M.ELF32_HEADER.e_shoff_offset)
	local e_shentsize = M.read_u16(adapter, M.ELF32_HEADER.e_shentsize_offset)
	local e_shnum     = M.read_u16(adapter, M.ELF32_HEADER.e_shnum_offset)
	local e_shstrndx  = M.read_u16(adapter, M.ELF32_HEADER.e_shstrndx_offset)
	if not (e_entry and e_shoff and e_shentsize and e_shnum and e_shstrndx) then
		return nil, "truncated_header"
	end

	return {
		e_entry     = e_entry,
		e_shoff     = e_shoff,
		e_shentsize = e_shentsize,
		e_shnum     = e_shnum,
		e_shstrndx  = e_shstrndx,
		error       = nil,
	}
end

--- Read one section-header entry from `adapter` at `sh_off`.
--- Returns a table with the wire fields plus a (yet-unresolved) `name` field.
--- @param adapter table
--- @param sh_off  integer
--- @return table|nil, string|nil  -- entry, error
local function read_section_entry(adapter, sh_off)
	local entry = {
		sh_name   = M.read_u32(adapter, sh_off + M.ELF32_SECTION.sh_name_offset),
		sh_type   = M.read_u32(adapter, sh_off + M.ELF32_SECTION.sh_type_offset),
		sh_flags  = M.read_u32(adapter, sh_off + M.ELF32_SECTION.sh_flags_offset),
		sh_addr   = M.read_u32(adapter, sh_off + M.ELF32_SECTION.sh_addr_offset),
		sh_offset = M.read_u32(adapter, sh_off + M.ELF32_SECTION.sh_offset_offset),
		sh_size   = M.read_u32(adapter, sh_off + M.ELF32_SECTION.sh_size_offset),
		sh_link   = M.read_u32(adapter, sh_off + M.ELF32_SECTION.sh_link_offset),
		name      = "",
	}
	if not (entry.sh_name and entry.sh_type and entry.sh_flags and entry.sh_addr
		and entry.sh_offset and entry.sh_size and entry.sh_link) then
		return nil, "truncated_section_headers"
	end
	return entry, nil
end

--- Walk every section header in `hdr` and return a 1-based array of entries
--- (the section at logical index 0 is at array position 1, etc.).
--- Each entry has the wire fields plus a resolved `name` derived from `.shstrtab`.
--- Returns nil + a stable error code on failure: truncated_section_headers, missing_shstrtab, truncated_strtab
--- @param adapter table
--- @param hdr     table  -- the table returned by parse_elf32_headers
--- @return table|nil, string|nil
function M.walk_sections(adapter, hdr)
	if not hdr or hdr.error then return nil, hdr and hdr.error or "truncated_section_headers" end

	local file_size = M.size(adapter)
	if hdr.e_shoff + hdr.e_shnum * hdr.e_shentsize > file_size then
		return nil, "truncated_section_headers"
	end

	-- Read every section header first; we need .shstrtab to resolve names.
	local sections = {}
	for i = 0, hdr.e_shnum - 1 do
		local sh_off = hdr.e_shoff + i * hdr.e_shentsize
		local entry, err = read_section_entry(adapter, sh_off)
		if not entry then return nil, err end
		sections[i + 1] = entry
	end

	if hdr.e_shstrndx >= hdr.e_shnum then
		return nil, "missing_shstrtab"
	end

	local  shstrtab = sections[hdr.e_shstrndx + 1]
	if not shstrtab or shstrtab.sh_type ~= M.SHT_STRTAB then
		return nil, "missing_shstrtab"
	end
	if shstrtab.sh_offset + shstrtab.sh_size > file_size then
		return nil, "truncated_section_headers"
	end
	local  shstrtab_bytes = M.read_section_bytes(adapter, shstrtab)
	if not shstrtab_bytes then return nil, "truncated_section_headers" end

	for _, s in ipairs(sections) do
		s.name = M.get_str(shstrtab_bytes, s.sh_name) or ""
	end

	return sections, nil
end

--- Read the bytes of one section. Returns a string, or nil if the adapter returns nil for any byte (out-of-bounds).
--- The caller is responsible fors sizing the buffer (the section's sh_offset + sh_size must fit in adapter.size).
--- @param adapter table
--- @param section table  -- one entry from walk_sections
--- @return string|nil
function M.read_section_bytes(adapter, section)
	local size = section.sh_size
	if    size == 0 then return "" end
	local out = {}
	for i = 0, size - 1 do
		local b = M.read_u8(adapter, section.sh_offset + i)
		if    b == nil then return nil end
		out[#out + 1] = string.char(b)
	end
	return table.concat(out)
end

--- Convenience: walk sections, then look up the named section, then read its bytes.
--- Returns nil + a stable error code if the section is absent or out-of-bounds.
--- @param adapter  table
--- @param sections table  -- 1-based array from walk_sections
--- @param name     string
--- @return string|nil, string|nil
function M.read_named_section(adapter, sections, name)
	if not sections then return nil, "missing_section" end
	for _, s in ipairs(sections) do
		if   s.name == name then
			local bytes = M.read_section_bytes(adapter, s)
			if not bytes then return nil, "truncated_section_data" end
			return bytes, nil
		end
	end
	return nil, "missing_section"
end

--- Walk every SHT_SYMTAB section in `sections` and accumulate symbols by name.
--- Each stored entry is `{ value = st_value, size = st_size, info = st_info, shndx = st_shndx }`.
--- Both STB_LOCAL and STB_GLOBAL symbols are included; the live ELF stores `smem` as a local symbol.
--- Returns nil + a stable error code on failure: missing_symtab_strtab, truncated_section_headers
--- @param adapter  table
--- @param sections table
--- @return table|nil, string|nil
function M.collect_symbols(adapter, sections)
	if not sections then return nil, "missing_sections" end
	local symbols = {}
	local file_size = M.size(adapter)
	for _, s in ipairs(sections) do
		if s.sh_type == M.SHT_SYMTAB then
			local  strtab = sections[s.sh_link + 1]
			if not strtab or strtab.sh_type ~= M.SHT_STRTAB then
				return nil, "missing_symtab_strtab"
			end
			if strtab.sh_offset + strtab.sh_size > file_size then
				return nil, "truncated_section_headers"
			end
			local  strtab_bytes = M.read_section_bytes(adapter, strtab)
			if not strtab_bytes then return nil, "truncated_section_headers" end
			if s.sh_offset + s.sh_size > file_size then
				return nil, "truncated_section_headers"
			end
			local  symtab_bytes = M.read_section_bytes(adapter, s)
			if not symtab_bytes then return nil, "truncated_section_headers" end
			local n = #symtab_bytes / M.ELF32_SYM.sym_entry_bytes
			for j = 0, n - 1 do
				local e = s.sh_offset + j * M.ELF32_SYM.sym_entry_bytes
				local st_name  = M.read_u32(adapter, e + M.ELF32_SYM.st_name)
				if    st_name then
					local st_value = M.read_u32(adapter, e + M.ELF32_SYM.st_value)
					local st_size  = M.read_u32(adapter, e + M.ELF32_SYM.st_size)
					local st_info  = M.read_u8(adapter, e + M.ELF32_SYM.st_info)
					-- st_shndx is at offset 14 (2 bytes) — derived from the layout
					-- the metaprogram reads too. Inline the read to keep the
					-- adapter as the only I/O surface.
					local b1 = M.read_u8(adapter, e + 14)
					local b2 = M.read_u8(adapter, e + 15)
					if not (b1 and b2) then
						return nil, "truncated_section_headers"
					end
					local st_shndx = b1 + b2 * 0x100
					local name = M.get_str(strtab_bytes, st_name) or ""
					if    name ~= "" then
						symbols[name] = {
							value = st_value,
							size  = st_size,
							info  = st_info,
							shndx = st_shndx,
						}
					end
				end
			end
		end
	end
	return symbols, nil
end

return M
