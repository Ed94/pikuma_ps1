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

local DW_LNS_copy          = DWARF_LINE_OPS.DW_LNS_copy
local DW_LNS_advance_pc    = DWARF_LINE_OPS.DW_LNS_advance_pc
local DW_LNS_advance_line  = DWARF_LINE_OPS.DW_LNS_advance_line
local DW_LNS_set_file      = DWARF_LINE_OPS.DW_LNS_set_file
local DW_LNS_extended      = DWARF_LINE_OPS.DW_LNS_extended
local DW_LNE_end_sequence  = DWARF_LINE_OPS.DW_LNE_end_sequence
local DW_LNE_set_address   = DWARF_LINE_OPS.DW_LNE_set_address

local DW_RLE_end_of_list   = DWARF5_RNGLISTS.end_of_list
local DW_RLE_start_length  = DWARF5_RNGLISTS.start_length

-- File index 11 in the existing main line unit is hello_gte_tape.c.
-- The injector extends that unit rather than appending an unreferenced unit.
local ATOM_SOURCE_FILE_INDEX = 11

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
		local addr_bytes = elf_dwarf.write_u32_le(addr)
		local sub_size = string.char(DW_LNE_set_address) .. addr_bytes
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
		local unit_length = elf_dwarf.read_u32_le(existing, unit_pos)
		if unit_length == elf_dwarf.ELF32.dw_dwarf32_terminator then return existing end
		local unit_end = unit_pos + 3 + unit_length
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
		if ul == elf_dwarf.ELF32.dw_dwarf32_terminator then
			-- DWARF64 marker - not supported.
			return existing
		end

		local unit_start = i
		local unit_end   = i + 3 + ul  -- last byte of unit content
		is_last_unit = (unit_end == #existing)

		if is_last_unit then
			-- The old terminator is replaced by entries + a new terminator, so
			-- net section growth (and unit_length growth) is entries only.
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

local SECTION_BUILDERS = {
	debug_line     = build_dwarf_line_section,
	debug_aranges  = build_dwarf_aranges_section,
	debug_rnglists = build_dwarf_rnglists_section,
}

-- Per-section output path resolver (mirrors SECTION_BUILDERS).
-- Returns the on-disk path for the section's `.bin` blob.
local SECTION_WRITERS = {
	debug_line     = function(out_root, basename) return out_root .. "\\" .. basename .. ".dwarf_line.bin"     end,
	debug_aranges  = function(out_root, basename) return out_root .. "\\" .. basename .. ".dwarf_aranges.bin"  end,
	debug_rnglists = function(out_root, basename) return out_root .. "\\" .. basename .. ".dwarf_rnglists.bin" end,
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

	-- Resolve relative ELF path to absolute via the canonical duffle helper.
	elf_path = duffle.to_absolute_path(elf_path)

	-- Read the existing DWARF sections directly (no subprocess; lfs + io.open + manual ELF32 section-header walk).
	local existing_sections = elf_dwarf.read_elf_sections(elf_path, {".debug_line", ".debug_aranges", ".debug_rnglists"})
	local existing_line     = existing_sections[".debug_line"]     or ""
	local existing_aranges  = existing_sections[".debug_aranges"]  or ""
	local existing_rnglists = existing_sections[".debug_rnglists"] or ""
	io.stderr:write(string.format("[dwarf_injection] read .debug_line (%d) + .debug_aranges (%d) + .debug_rnglists (%d) bytes\n"
		, #existing_line, #existing_aranges, #existing_rnglists))

	-- Build the atom table (cross-ref nm symbols with source-map.txt entries).
	local atom_table = build_atom_table(ctx)
	io.stderr:write(string.format("[dwarf_injection] matched %d atoms between nm + source-map\n", #atom_table))

	-- Write the .bin files. The build_psyq.ps1 post-link hook splices these into a copy of the ELF via objcopy --update-section.
	local basename = ctx.basename or DEFAULT_BASENAME
	if ctx.out_root and ctx.out_root ~= "" then
		duffle.ensure_dir(ctx.out_root)

		-- Build + write each section via the SECTION_BUILDERS / SECTION_WRITERS dispatch.
		local outputs = {}
		for name, builder in pairs(SECTION_BUILDERS) do
			local existing = existing_sections["." .. name] or ""
			local bytes    = builder(existing, atom_table)
			local path     = SECTION_WRITERS[name](ctx.out_root, basename)
			io.stderr:write(string.format("[dwarf_injection] new .%s = %d bytes (was %d, +%d atoms)\n"
				, name, #bytes, #existing, #atom_table))
			local f = io.open(path, "wb")
			if not f then
				io.stderr:write(string.format("[dwarf_injection] failed to open %s for write\n", path))
			else
				f:write(bytes); f:close()
				outputs[#outputs + 1] = { [name .. "_bin"] = path }
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
