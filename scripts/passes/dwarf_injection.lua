--- passes/dwarf_injection.lua — Per-atom DWARF injection for tape-atom step-debug (F').
---
--- Reads the post-link ELF directly (lfs + io.open; walks the ELF32 section
--- header table to find `.debug_line` + `.debug_aranges` + `.debug_rnglists`), 
--- APPENDS synthetic DWARF line-program sequences for every `code_<name>` atom, 
--- EXTENDS the `.debug_aranges` and main-CU range tables with the atom ranges. 
--- Writes the new section data to `<out_root>/<basename>.dwarf_*.bin`.
---
--- The `build_psyq.ps1` post-link hook then splices those `.bin` files into a copy of the ELF via:
---   mipsel-none-elf-objcopy --update-section .debug_line=<bin>     <elf>
---   mipsel-none-elf-objcopy --update-section .debug_aranges=<bin>  <elf>
---   mipsel-none-elf-objcopy --update-section .debug_rnglists=<bin> <elf>
--- (Splice step runs from PowerShell — no Lua subprocess; no cmd /c parsing issues.
--- objcopy's --update-section works fine in PowerShell even though Lua's `os.execute`/`io.popen` would mangle the `=` on Windows.)
---
--- Result: VSCode's source gutter follows per-stepi inside atom bodies.
--- Native VSCode UX (gutter arrow + highlighted line + Run to Cursor + conditional BPs by source line).
--- No VSCode plugin, no Python, no pyelftools — pure Lua + objcopy.
---
--- **Conventions:** tabs (1/level), EmmyLua annotations, no regex,
--- Lua 5.3 compatible.

-- ════════════════════════════════════════════════════════════════════════════
-- Bootstrap
-- ════════════════════════════════════════════════════════════════════════════

-- Load `duffle_paths.lua` via `debug.getinfo(1, "S").source` (works both
-- standalone + when require'd). Sets package.path + package.cpath then
-- returns duffle.
local _bootstrap_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local duffle         = dofile(_bootstrap_dir .. "../duffle_paths.lua")

-- Native `lfs` for file/directory operations.
local lfs = require("lfs")

-- ════════════════════════════════════════════════════════════════════════════
-- Constants
-- ════════════════════════════════════════════════════════════════════════════

-- DWARF line-program opcodes (per raddebugger's `dwarf_writer.c`).
-- Standard opcodes 1-12 are single-byte + payload.
local DW_LNS_copy          = 1
local DW_LNS_advance_pc    = 2
local DW_LNS_advance_line  = 3
local DW_LNS_set_file      = 4

-- Byte 0 introduces every extended opcode. `opcode_base` is instead the first
-- special opcode and must never be used as the extended marker.
local DW_LNS_extended      = 0

-- Extended sub-opcodes (encoded as a single byte AFTER the ULEB128 size).
local DW_LNE_end_sequence  = 1
local DW_LNE_set_address   = 2

-- DWARF5 range-list entry encodings used by the main CU.
local DW_RLE_end_of_list    = 0
local DW_RLE_start_length   = 7

-- File index 11 in the existing main line unit is hello_gte_tape.c. The
-- injector extends that unit rather than appending an unreferenced unit.
local ATOM_SOURCE_FILE_INDEX = 11

-- Path templates for the .bin outputs.
local function dwarf_line_path(out_root, basename)
	return out_root .. "\\" .. basename .. ".dwarf_line.bin"
end
local function dwarf_aranges_path(out_root, basename)
	return out_root .. "\\" .. basename .. ".dwarf_aranges.bin"
end
local function dwarf_rnglists_path(out_root, basename)
	return out_root .. "\\" .. basename .. ".dwarf_rnglists.bin"
end

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

--- ULEB128 encoder. Returns the byte string.
--- @param n integer  -- non-negative
--- @return string
local function uleb128(n)
	assert(n >= 0, "uleb128 requires non-negative input")
	local bytes = {}
	repeat
		local b = n % 128
		n = (n - b) / 128
		if n > 0 then b = b + 128 end
		bytes[#bytes + 1] = string.char(b)
	until n == 0
	return table.concat(bytes)
end

--- SLEB128 encoder. Returns the byte string.
--- @param n integer
--- @return string
local function sleb128(n)
	local bytes = {}
	local more = true
	while more do
		local b = n % 128
		n = (n - b) / 128
		if n == 0  and (b % 128) <  64 then more = false end
		if n == -1 and (b % 128) >= 64 then more = false end
		if more then b = b + 128 end
		bytes[#bytes + 1] = string.char(b)
	end
	return table.concat(bytes)
end

-- ════════════════════════════════════════════════════════════════════════════
-- DWARF line-program encoder
-- ════════════════════════════════════════════════════════════════════════════

--- Build the byte sequence for ONE atom's line program:
---   DW_LNE_set_address(addr)
---   DW_LNS_copy                            -- entry 1: addr, file, line=first.line
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
		-- Per DWARF5 §6.2.5.3:
		--   marker(0) + size(ULEB128, includes sub_opcode byte) + sub_opcode + payload
		-- For set_address: size = 1 (sub_opcode) + 4 (addr) = 5
		local addr_bytes = string.char(
			addr % 256,
			math.floor(addr / 256) % 256,
			math.floor(addr / 65536) % 256,
			math.floor(addr / 16777216) % 256)
		local sub_size = string.char(DW_LNE_set_address) .. addr_bytes
		return string.char(DW_LNS_extended) .. uleb128(#sub_size) .. sub_size
	end
	local function copy_op()
		return string.char(DW_LNS_copy)
	end
	local function set_file(file_index)
		return string.char(DW_LNS_set_file) .. uleb128(file_index)
	end
	local function advance_pc(bytes_delta)
		return string.char(DW_LNS_advance_pc) .. uleb128(bytes_delta)
	end
	local function advance_line(line_delta)
		return string.char(DW_LNS_advance_line) .. sleb128(line_delta)
	end
	local function end_sequence()
		-- size = 1 (just the sub_opcode byte, no payload)
		return string.char(DW_LNS_extended) .. string.char(1) .. string.char(DW_LNE_end_sequence)
	end

	if not atom.entries or #atom.entries == 0 then
		return set_address(atom.addr) .. end_sequence()
	end

	-- set_address sets the address register to atom.addr.
	-- line_state.line starts at 1 (per DWARF spec). 
	-- To land at entries[1].line for the FIRST emitted entry, we need to advance_line by (entries[1].line - 1) + then copy.
	-- Then each subsequent entry uses the delta from the previous entry.
	local parts = {
		set_file(ATOM_SOURCE_FILE_INDEX),       -- existing Unit 2 file table: hello_gte_tape.c
		set_address(atom.addr),                 -- 7 bytes: marker + size + sub + addr
		advance_line(atom.entries[1].line - 1), -- (entries[1].line - 1) bytes; line_state.line -> entries[1].line
		copy_op(),                              -- emit entry 1: addr=atom.addr, line=entries[1].line
	}
	local prev_line = atom.entries[1].line
	for idx = 2, #atom.entries do
		local entry = atom.entries[idx]
		parts[#parts + 1] = advance_pc(4) -- 1 .word = 4 bytes on MIPS
		parts[#parts + 1] = advance_line(entry.line - prev_line)
		parts[#parts + 1] = copy_op()
		prev_line = entry.line
	end
	parts[#parts + 1] = end_sequence()
	return table.concat(parts)
end

-- ════════════════════════════════════════════════════════════════════════════
-- ELF32 direct reader
-- ════════════════════════════════════════════════════════════════════════════

--- Read the existing `.debug_line` + `.debug_aranges` + `.debug_rnglists` bytes by walking the
--- ELF32 section-header table directly (no subprocess). 
--- lfs is used only for the existence check; io.open + manual byte arithmetic does the rest.
---
--- ELF32 header layout (52 bytes):
---   off  0:  magic \x7fELF
---   off  4:  class (1 = ELF32), endianness (1 = LE, 2 = BE)
---   ...
---   off 16:  e_type (2),  e_machine (2), e_version (4)
---   off 24:  e_entry (4), e_phoff (4)
---   off 32:  e_shoff (4)      <-- section-header table file offset
---   off 36:  e_flags (4), e_ehsize (2)
---   off 42:  e_phentsize (2), e_phnum (2)
---   off 46:  e_shentsize (2)  <-- section-header entry size (40 for ELF32)
---   off 48:  e_shnum (2)      <-- number of section headers
---   off 50:  e_shstrndx (2)   <-- index of section-name string table
---
--- Section header (40 bytes for ELF32):
---   off  0:  sh_name      (4)
---   off  4:  sh_type      (4)
---   off  8:  sh_flags     (4)
---   off 12:  sh_addr      (4)
---   off 16:  sh_offset    (4)  <-- file offset of section data
---   off 20:  sh_size      (4)  <-- size of section data
---   off 24:  sh_link      (4)
---   off 28:  sh_info      (4)
---   off 32:  sh_addralign (4)
---   off 36:  sh_entsize   (4)
---
--- Returns the three section byte strings (any may be empty if absent).
--- @param elf_path string
--- @return string, string, string
local function read_elf_dwarf_sections(elf_path)
	-- Existence check (lfs.attributes avoids an io.open-vs-fail race).
	if lfs.attributes(elf_path, "mode") ~= "file" then
		io.stderr:write(string.format("[dwarf_injection] ELF not found: %s\n", elf_path))
		return "", "", ""
	end

	local f = io.open(elf_path, "rb")
	if not f then
		io.stderr:write(string.format("[dwarf_injection] io.open failed: %s\n", elf_path))
		return "", "", ""
	end

	-- Read the ELF32 header (52 bytes).
	local header = f:read(52)
	if not header or #header < 52 then
		io.stderr:write("[dwarf_injection] ELF too small for ELF32 header\n")
		f:close()
		return "", "", ""
	end

	-- Sanity-check magic + class + endianness.
	if header:sub(1, 4) ~= "\127ELF" then
		io.stderr:write("[dwarf_injection] not an ELF file\n")
		f:close()
		return "", "", ""
	end
	local class = header:byte(5)
	local endian = header:byte(6)
	if class ~= 1 then
		io.stderr:write(string.format("[dwarf_injection] not ELF32 (class=%d)\n", class))
		f:close()
		return "", "", ""
	end
	if endian ~= 1 then
		io.stderr:write(string.format("[dwarf_injection] not little-endian (endian=%d); unsupported\n", endian))
		f:close()
		return "", "", ""
	end

	-- Parse e_shoff (off 32, 4 bytes LE), e_shentsize 
	-- (off 46, 2 bytes LE), e_shnum (off 48, 2 bytes LE), e_shstrndx (off 50, 2 bytes LE).
	local function u32_le(buf, off)
		return buf:byte(off) + buf:byte(off + 1) * 256 + buf:byte(off + 2) * 65536 + buf:byte(off + 3) * 16777216
	end
	local function u16_le(buf, off)
		return buf:byte(off) + buf:byte(off + 1) * 256
	end

	local e_shoff     = u32_le(header, 33)
	local e_shentsize = u16_le(header, 47)
	local e_shnum     = u16_le(header, 49)
	local e_shstrndx  = u16_le(header, 51)

	-- Read the section-header string table (.shstrtab).
	-- Walk to section header index `e_shstrndx`, read its sh_offset + sh_size.
	f:seek("set", e_shoff + e_shstrndx * e_shentsize)
	local strtab_hdr = f:read(e_shentsize)
	if not strtab_hdr or #strtab_hdr < e_shentsize then
		io.stderr:write("[dwarf_injection] could not read .shstrtab header\n")
		f:close()
		return "", "", ""
	end
	local strtab_offset = u32_le(strtab_hdr, 17)
	local strtab_size   = u32_le(strtab_hdr, 21)
	f:seek("set", strtab_offset)
	local strtab = f:read(strtab_size) or ""

	-- Walk all section headers; collect names + (offset, size) for the
	-- sections we care about.
	local function read_section_bytes(sh_offset, sh_size)
		f:seek("set", sh_offset)
		return f:read(sh_size) or ""
	end

	local debug_line_bytes     = ""
	local debug_aranges_bytes  = ""
	local debug_rnglists_bytes = ""

	for sh_idx = 0, e_shnum - 1 do
		f:seek("set", e_shoff + sh_idx * e_shentsize)
		local sh = f:read(e_shentsize)
		if not sh or #sh < e_shentsize then break end
		local sh_name   = u32_le(sh, 1)
		local sh_offset = u32_le(sh, 17)
		local sh_size   = u32_le(sh, 21)

		-- Extract the name (null-terminated C string in strtab).
		local name_end = strtab:find("\0", sh_name + 1, true) or (sh_name + 1)
		local name     = strtab:sub(sh_name + 1, name_end - 1)
		if     name == ".debug_line"     then debug_line_bytes     = read_section_bytes(sh_offset, sh_size)
		elseif name == ".debug_aranges"  then debug_aranges_bytes  = read_section_bytes(sh_offset, sh_size)
		elseif name == ".debug_rnglists" then debug_rnglists_bytes = read_section_bytes(sh_offset, sh_size)
		end
	end

	f:close()
	return debug_line_bytes, debug_aranges_bytes, debug_rnglists_bytes
end

-- ════════════════════════════════════════════════════════════════════════════
-- Helpers: nm + source-map.txt + atom table
-- ════════════════════════════════════════════════════════════════════════════

--- Read ELF symbol addresses via `mipsel-none-elf-nm -S`.
--- Returns `{name -> {addr, size_bytes}}` for every `code_<name>` symbol.
--- Duplicated from passes/atoms_source_map.lua 
--- (lift decision in scratch/phase1_helpers_audit.md: keep duplication until 3+ callers).
--- @param elf_path string
--- @return table
local function read_nm(elf_path)
	local addrs = {}
	local f = io.popen(string.format('mipsel-none-elf-nm -S "%s" 2>nul', elf_path))
	if not f then return addrs end
	for line in f:lines() do
		local addr_hex, size_hex, name = line:match("^(%x+)%s+(%x+)%s+%a%s+code_(%S+)")
		if addr_hex and size_hex and name then
			addrs[name] = { tonumber(addr_hex, 16), tonumber(size_hex, 16) }
		end
	end
	f:close()
	return addrs
end

--- Parse FORMAT_VERSION 1 atoms.sourcemap.txt. 
--- Returns `{name -> {total = N, words = {{n, line}, ...}}}`.
--- Matches the in-memory shape 
--- (atoms_source_map.lua:142 uses `{pos, line, text}`; the `.txt` file uses `WORD <n>` so the parser maps `n` -> `pos`).
--- @param sm_path string
--- @return table
local function read_source_map(sm_path)
	local out = {}
	local cur_name, cur_total, cur_words = nil, 0, {}
	for raw in io.lines(sm_path) do
		local line = raw
		if line:match("^#") then
			if line:match("^# FORMAT_VERSION%s+(%d+)") then
				local ver = tonumber(line:match("^# FORMAT_VERSION%s+(%d+)"))
				if ver ~= 1 then
					io.stderr:write(string.format(
						"[dwarf_injection] source-map version mismatch (got %d, expected 1)\n", ver))
					return {}
				end
			end
			-- skip other comments
		elseif line:sub(1, 4) == "ATOM" then
			-- ATOM <name> "<abs-source-path>" <total_words>
			-- The path is quoted. Format per emission: string.format('ATOM %s "%s" 0', name, rel_path)
			-- then patched: .gsub(" 0$", " " .. total). 
			-- So the wire format is: ATOM <name> "<path>" <total>.
			local _, _, name = line:find("ATOM%s+(%S+)%s+\"[^\"]*\"%s+(%d+)")
			if name then
				cur_name  = name
				cur_total = 0
				cur_words = {}
				out[name] = { total = 0, words = cur_words }
			end
		elseif line == "ENDATOM" then
			-- Update the recorded total from the entries count 
			-- (matches the `lines[1] = lines[1]:gsub(" 0$", " " .. total)` patch in atoms_source_map.lua:170).
			if cur_name and out[cur_name] then
				out[cur_name].total = #cur_words
			end
			cur_name, cur_total, cur_words = nil, 0, {}
		elseif line:sub(1, 4) == "WORD" and cur_name then
			-- WORD <n>  LINE <line>  TEXT <text...>
			local _, n, _, src_line = line:find("WORD%s+(%d+)%s+LINE%s+(%d+)")
			if n and src_line then
				cur_words[#cur_words + 1] = { n = tonumber(n), line = tonumber(src_line) }
			end
		end
	end
	return out
end

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
	local sm_files = {}
	if duffle and duffle.list_dir then
		sm_files = duffle.list_dir(ctx.out_root, "%.atoms.sourcemap%.txt$")
	elseif lfs then
		-- Manual walk via lfs.
		for entry in lfs.dir(ctx.out_root) do
			if entry:match("%.atoms.sourcemap%.txt$") then
				sm_files[#sm_files + 1] = ctx.out_root .. "\\" .. entry
			end
		end
	end
	if #sm_files == 0 then
		io.stderr:write(string.format(
			"[dwarf_injection] no *.atoms.sourcemap.txt in %s; need atoms-source-map pass first\n",
			ctx.out_root))
		return {}
	end

	-- Read nm + merge all source-map files.
	local addrs  = read_nm(ctx.flags.elf_path)
	local merged = {}
	for _, sm_path in ipairs(sm_files) do
		local sm = read_source_map(sm_path)
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
		local unit_length = existing:byte(unit_pos)
			+ existing:byte(unit_pos + 1) * 256
			+ existing:byte(unit_pos + 2) * 65536
			+ existing:byte(unit_pos + 3) * 16777216
		if unit_length == 0xFFFFFFFF then return existing end
		local unit_end = unit_pos + 3 + unit_length
		if unit_end > #existing then return existing end
		last_pos, last_length, last_end = unit_pos, unit_length, unit_end
		unit_pos                        = unit_end + 1
	end
	if unit_pos ~= #existing + 1 or not last_pos then return existing end

	local new_length       = last_length + #appended
	local new_length_bytes = string.char(
		           new_length             % 256,
		math.floor(new_length / 256)      % 256,
		math.floor(new_length / 65536)    % 256,
		math.floor(new_length / 16777216) % 256)

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
		local ul = existing:byte(i)
			+ existing:byte(i + 1) * 256
			+ existing:byte(i + 2) * 65536
			+ existing:byte(i + 3) * 16777216
		if ul == 0xFFFFFFFF then
			-- DWARF64 marker - not supported.
			return existing
		end

		local unit_start = i
		local unit_end   = i + 3 + ul  -- last byte of unit content
		is_last_unit = (unit_end == #existing)

		if is_last_unit then
			-- The old terminator is replaced by entries + a new terminator, so
			-- net section growth (and unit_length growth) is entries only.
			local added_bytes = #atom_table * 8
			local new_ul = ul + added_bytes
			local new_ul_bytes = string.char(
				new_ul % 256,
				math.floor(new_ul / 256) % 256,
				math.floor(new_ul / 65536) % 256,
				math.floor(new_ul / 16777216) % 256)
			-- Emit everything EXCEPT the last 8 bytes (terminator).
			result[#result + 1] = new_ul_bytes
				.. existing:sub(i + 4, unit_end - 8)
			-- Append my atom entries.
			for _, atom in ipairs(atom_table) do
				local a    = atom.addr
				local size = atom.size_bytes
				result[#result + 1] = string.char(
					           a             % 256,
					math.floor(a / 256)      % 256,
					math.floor(a / 65536)    % 256,
					math.floor(a / 16777216) % 256,
					           size             % 256,
					math.floor(size / 256)      % 256,
					math.floor(size / 65536)    % 256,
					math.floor(size / 16777216) % 256)
			end
			-- Append a new terminator.
			result[#result + 1] = string.rep("\0", 8)
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
	if #existing < 13 or #atom_table == 0 then return existing end

	local unit_length = existing:byte(1)
		+ existing:byte(2) * 256
		+ existing:byte(3) * 65536
		+ existing:byte(4) * 16777216
	local version            = existing:byte(5) + existing:byte(6) * 256
	local address_size       = existing:byte(7)
	local segment_size       = existing:byte(8)
	local offset_entry_count = existing:byte(9)
		+ existing:byte(10) * 256
		+ existing:byte(11) * 65536
		+ existing:byte(12) * 16777216

	if unit_length + 4 ~= #existing
		or version            ~= 5
		or address_size       ~= 4
		or segment_size       ~= 0
		or offset_entry_count ~= 0
		or existing:byte(#existing) ~= DW_RLE_end_of_list then
		return existing
	end

	local entries = {}
	for _, atom in ipairs(atom_table) do
		local addr = atom.addr
		entries[#entries + 1] = string.char(DW_RLE_start_length, 
		            addr              % 256,
			math.floor(addr / 256)      % 256,
			math.floor(addr / 65536)    % 256,
			math.floor(addr / 16777216) % 256)
			.. uleb128(atom.size_bytes)
	end
	local appended         = table.concat(entries)
	local new_length       = unit_length + #appended
	local new_length_bytes = string.char(
		new_length % 256,
		math.floor(new_length / 256) % 256,
		math.floor(new_length / 65536) % 256,
		math.floor(new_length / 16777216) % 256)

	return new_length_bytes
		.. existing:sub(5, #existing - 1)
		.. appended
		.. string.char(DW_RLE_end_of_list)
end

local SECTION_BUILDERS = {
	debug_line     = build_dwarf_line_section,
	debug_aranges  = build_dwarf_aranges_section,
	debug_rnglists = build_dwarf_rnglists_section,
}

-- ════════════════════════════════════════════════════════════════════════════
-- Pass entry
-- ════════════════════════════════════════════════════════════════════════════

local M = {}

--- M.run — orchestrator entry. Phase 1 Tasks 3-4 read + cross-ref. Phase 2
--- Tasks 5-7 fill in the section builders + .bin emission.
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

	-- Resolve relative ELF path to absolute (io.open inherits the calling
	-- process's CWD which is reliable, but absolute paths are safer when
	-- this module is required from another directory).
	if not elf_path:match("^[%a]:[\\/]") and not elf_path:match("^[/\\]") then
		local cwd = lfs.currentdir()
		elf_path = cwd:gsub("[\\/]$", "") .. "\\" .. elf_path
	end

	-- Read the existing DWARF sections directly (no subprocess; lfs + io.open + manual ELF32 section-header walk).
	local existing_line, existing_aranges, existing_rnglists = read_elf_dwarf_sections(elf_path)
	io.stderr:write(string.format("[dwarf_injection] read .debug_line (%d) + .debug_aranges (%d) + .debug_rnglists (%d) bytes\n"
		, #existing_line, #existing_aranges, #existing_rnglists))

	-- Build the atom table (cross-ref nm symbols with source-map.txt entries).
	local atom_table = build_atom_table(ctx)
	io.stderr:write(string.format("[dwarf_injection] matched %d atoms between nm + source-map\n", #atom_table))

	-- Build the new sections via the SECTION_BUILDERS dispatch.
	local new_line     = build_dwarf_line_section    (existing_line,     atom_table)
	local new_aranges  = build_dwarf_aranges_section (existing_aranges,  atom_table)
	local new_rnglists = build_dwarf_rnglists_section(existing_rnglists, atom_table)
	io.stderr:write(string.format("[dwarf_injection] new .debug_line = %d bytes (was %d, +%d atoms)\n"
		, #new_line, #existing_line, #atom_table))
	io.stderr:write(string.format("[dwarf_injection] new .debug_aranges = %d bytes (was %d, +%d atoms)\n"
		, #new_aranges, #existing_aranges, #atom_table))
	io.stderr:write(string.format("[dwarf_injection] new .debug_rnglists = %d bytes (was %d, +%d atoms)\n"
		, #new_rnglists, #existing_rnglists, #atom_table))

	-- Write the .bin files. The build_psyq.ps1 post-link hook splices these into a copy of the ELF via objcopy --update-section.
	local basename = ctx.basename or DEFAULT_BASENAME
	if ctx.out_root and ctx.out_root ~= "" then
		if lfs.attributes(ctx.out_root, "mode") ~= "directory" then
			lfs.mkdir(ctx.out_root)
		end
		local line_path     = dwarf_line_path    (ctx.out_root, basename)
		local aranges_path  = dwarf_aranges_path (ctx.out_root, basename)
		local rnglists_path = dwarf_rnglists_path(ctx.out_root, basename)
		local f1 = io.open(line_path, "wb")
		if not f1 then
			io.stderr:write(string.format("[dwarf_injection] failed to open %s for write\n", line_path))
		else
			f1:write(new_line); f1:close()
		end
		local f2 = io.open(aranges_path, "wb")
		if not f2 then
			io.stderr:write(string.format("[dwarf_injection] failed to open %s for write\n", aranges_path))
		else
			f2:write(new_aranges); f2:close()
		end
		local f3 = io.open(rnglists_path, "wb")
		if not f3 then
			io.stderr:write(string.format("[dwarf_injection] failed to open %s for write\n", rnglists_path))
		else
			f3:write(new_rnglists); f3:close()
		end
		io.stderr:write(string.format("[dwarf_injection] wrote %s + %s + %s\n", line_path, aranges_path, rnglists_path))
		return {
			outputs = {
				{ dwarf_line_bin     = line_path },
				{ dwarf_aranges_bin  = aranges_path },
				{ dwarf_rnglists_bin = rnglists_path },
			},
			errors = {}, warnings = {},
		}
	end
	return { outputs = {}, errors = {}, warnings = {} }
end

return M
