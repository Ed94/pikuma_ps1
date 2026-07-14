--- passes/scan_source.lua — Source pre-scan pass (the "mega entity" pass).
---
--- Single source-walk pass that produces the fat `SourceScan` payload consumed by all downstream passes. Walks each `ctx.sources` entry once,
--- extracting every construct type the metaprograms need:
---
---   MipsAtom_              (kind = "atom", with optional atom_info inner)
---   MipsAtomComp_          (kind = "comp_bare")
---   MipsAtomComp_Proc_     (kind = "comp_proc", body inside last {})
---   atom_dbg_skip_over     (whole-atom/component debug-step marker; following declaration disambiguates)
---   MipsCode code_<name>   (kind = "raw_atom", offsets pass only)
---   typedef Struct_(Binds_X) { fields }
---   #pragma mac_X tape_atom words=N   +   _Pragma("...")
---
--- The result is attached to each `src.scan` so downstream passes can read from `src.scan.atoms` / `src.scan.binds` / etc. without re-walking the source.
--- This is the first pass in the dep graph (no deps).
--- Every other pass that reads source structure depends on this one — see `ps1_meta.lua :: PASSES`.
---
--- **Conventions**: tabs (1/level), EmmyLua annotations, no regex, Lua 5.3 compatible

-- Bootstrap: same as entry scripts. See `ps1_meta.lua` for the rationale.
-- Bootstrap: load `scripts/duffle_paths.lua` (sets package.path + package.cpath).
-- Uses `debug.getinfo` to find this file's own directory, so it works
-- both standalone and when require'd from the orchestrator.
-- Bootstrap: load `duffle_paths.lua` via `debug.getinfo(1, "S").source` (works both standalone + when require'd).
-- duffle_paths.lua sets package.path then returns `require("duffle")` at the bottom, so the dofile value IS the duffle module.
local _bootstrap_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local duffle        = dofile(_bootstrap_dir .. "../duffle_paths.lua")

-- ════════════════════════════════════════════════════════════════════════════
-- Type declarations
-- ════════════════════════════════════════════════════════════════════════════

--- @class SourceScan
--- @field atoms      AtomEntry[]     -- MipsAtom_ + MipsAtomComp_ + MipsAtomComp_Proc_
--- @field raw_atoms  AtomEntry[]     -- MipsCode code_<name> { body } (offsets pass only)
--- @field binds      BindsEntry[]    -- typedef Struct_(Binds_X) { fields } (fields pre-parsed)
--- @field atom_infos AtomInfoEntry[] -- MipsAtom_(name) atom_info(...) (sub-calls pre-parsed)
--- @field macros     MacroEntry[]    -- #pragma mac_X tape_atom words=N  +   _Pragma("...")
--- @field skip_over  SkipOverScan    -- atom/component debug-step markers + resolved declaration associations
--- @field types      table<string, RegTypeDefault> -- atom_dbg_reg_default(R_X, <type>) declarations
--- @field atom_views table<string, AtomViewEntry> -- MipsAtom_(name) -> {binds_name, reg_type_overrides, info_line}
--- @field line_of    fun(pos: integer): integer  -- shared LineIndex closure

--- @class SkipOverScan
--- @field atoms      table<string, SkipOverAssociation>
--- @field components table<string, SkipOverAssociation>
--- @field markers    SkipOverMarker[]

--- @class SkipOverMarker
--- @field marker_kind    string      -- exact marker ident (always "atom_dbg_skip_over")
--- @field marker_line    integer
--- @field marker_pos     integer
--- @field after_paren    integer
--- @field args           string|nil  -- trimmed marker args; valid Task 13 markers use ""
--- @field has_parens     boolean
--- @field pending        boolean
--- @field superseded_by_marker_line integer|nil
--- @field target_name    string|nil  -- stripped declaration name once observed
--- @field target_raw_name string|nil -- source-written declaration name once observed
--- @field target_kind    string|nil  -- "atom" | "comp_bare" | "comp_proc" | "unrelated" once observed
--- @field declaration_line integer|nil
--- @field declaration_pos  integer|nil
--- @field proc_prelude      boolean|nil -- marker has crossed FI_ and awaits MipsAtomComp_Proc_

--- @class RegTypeDefault
--- @field name          string  -- "R_TapePtr" (the register ident; without the value part)
--- @field type_name     string  -- "U4" / "V3_S2" / "void" (the pointer/struct base name)
--- @field pointer_depth integer -- 0 for `U4`, 1 for `U4*`, 2 for `U4**`
--- @field source_line   integer -- 1-based source line of the declaration

--- @class RegTypeOverride
--- @field reg           string  -- "R_T0"
--- @field type_name     string
--- @field pointer_depth integer

--- @class AtomViewEntry
--- @field atom_name        string                 -- e.g. "red_cube_g4_face"
--- @field binds_name       string|nil             -- "Binds_CubeTri" if attached
--- @field reg_type_overrides table<string, RegTypeOverride> -- "R_T0" -> override
--- @field info_line        integer                -- line of the atom_info call

--- @class SkipOverAssociation
--- @field marker_line      integer
--- @field declaration_line integer
--- @field kind             string
--- @field marker           SkipOverMarker

--- @class SourceFile
--- @field path     string  -- absolute path to the source file
--- @field text     string  -- the full source text
--- @field dir      string  -- the directory containing the source
--- @field basename string  -- filename without extension
--- @field scan     table   -- pre-scanned SourceScan payload (set by this pass)

--- @class PassCtx
--- @field sources            SourceFile[]
--- @field metadata_path      string
--- @field shared             table
--- @field out_root           string
--- @field project_root       string
--- @field upstream           table<string, table>
--- @field flags              table
--- @field dry_run            boolean
--- @field verbose            boolean

--- @class PassResult
--- @field outputs  table[]
--- @field errors   table[]
--- @field warnings table[]

--- @class AtomEntry
--- @field line       integer
--- @field name       string         -- atom name (for components: without ac_ prefix)
--- @field body       string         -- brace-delimited body (without the braces)
--- @field body_off   integer        -- char offset of body[1] in source
--- @field kind       string         -- "atom" | "comp_bare" | "comp_proc" | "raw_atom"
--- @field raw_name   string         -- un-stripped name (for components: with ac_ prefix)
--- @field ident_pos  integer        -- position of the MipsAtom_/MipsAtomComp_ ident start
--- @field after_paren integer       -- position past the closing paren
--- @field args       string|nil     -- populated by components pass (backward lookup)
--- @field comment    string|nil     -- populated by components pass (backward lookup)

-- ════════════════════════════════════════════════════════════════════════════
-- Local helpers (shared by per-form parsers)
-- ════════════════════════════════════════════════════════════════════════════

-- C qualifier keywords that may precede a MipsAtom_ / MipsCode declaration.
-- (typedef is NOT a qualifier here — it's a separate construct (`typedef Struct_(Binds_X) { ... };`)
-- and must be read as an ident so the typedef check below can match it.)
local QUALIFIER_KEYWORDS = {
	["static"]   = true, ["const"] = true, ["volatile"] = true, ["extern"] = true,
	["register"] = true, ["auto"]  = true, ["inline"]   = true,
	["internal"] = true, ["LP_"]   = true, ["global"]   = true, ["gkknown"] = true,
}

-- "ac_" prefix length on component names (e.g., `MipsAtomComp_(ac_X, ...)`). The components pass strips
-- this prefix to derive the macro name (e.g., `mac_X`). Single source of truth — was duplicated in two
-- branches of the pre-refactor scan_source.
local AC_PREFIX     = "ac_"
local AC_PREFIX_LEN = 3

-- Strip the "ac_" prefix from a component name. Returns the input unchanged if it doesn't start with the prefix.
-- @param raw_name string
-- @return string
local function strip_ac_prefix(raw_name)
	if #raw_name > AC_PREFIX_LEN and raw_name:sub(1, AC_PREFIX_LEN) == AC_PREFIX then
		return raw_name:sub(AC_PREFIX_LEN + 1)
	end
	return raw_name
end

-- Preserve a source marker until the following declaration parser observes it.
-- Task 13 records evidence only; Task 14 diagnoses non-empty args,
-- duplicates, dangling markers, and unrelated declaration placement.
local function push_skip_over_marker(out, marker)
	local markers = out.skip_over.markers
	local prior   = markers[#markers]
	if prior and prior.pending then
		prior.pending = false
		prior.superseded_by_marker_line = marker.marker_line
	end
	marker.pending = true
	markers[#markers + 1] = marker
end

-- Attach the pending marker to the next declaration. The declaration form
-- disambiguates whole atoms from components; unsupported declarations retain
-- placement evidence for annotation.lua and populate neither lookup table.
local function associate_skip_over_marker(out, target_name, target_raw_name, target_kind, declaration_line, declaration_pos)
	local markers = out.skip_over.markers
	local marker  = markers[#markers]
	if not (marker and marker.pending) then return end

	marker.pending          = false
	marker.target_name      = target_name
	marker.target_raw_name  = target_raw_name
	marker.target_kind      = target_kind
	marker.declaration_line = declaration_line
	marker.declaration_pos  = declaration_pos

	if not (marker.has_parens and marker.args == "") then return end

	local association = {
		marker_line      = marker.marker_line,
		declaration_line = declaration_line,
		kind             = target_kind,
		marker           = marker,
	}
	if target_kind == "atom" then
		out.skip_over.atoms[target_name] = association
	elseif target_kind == "comp_bare" or target_kind == "comp_proc" then
		out.skip_over.components[target_name] = association
	end
end

-- Read a top-level comma-delimited argument list. Mirrors split_top_level_commas
-- in shape; kept inline so scan_source can remain dependency-free.
local function read_top_level_args(text, pos)
	local args = {}
	pos = duffle.skip_ws_and_cmt(text, pos)
	while pos <= #text do
		local buf, level = {}, 0
		while pos <= #text do
			local c = text:sub(pos, pos)
			if c == "(" or c == "[" or c == "{" then level = level + 1
			elseif c == ")" or c == "]" or c == "}" then
				if level == 0 then break end
				level = level - 1
			elseif c == "," and level == 0 then break end
			buf[#buf + 1] = c
			pos = pos + 1
		end
		local arg = duffle.trim(table.concat(buf))
		if arg ~= "" then args[#args + 1] = arg end
		if pos > #text then break end
		if text:sub(pos, pos) == "," then pos = pos + 1; pos = duffle.skip_ws_and_cmt(text, pos) end
		if not text:sub(pos, pos) or text:sub(pos, pos) == ")" then break end
	end
	return args
end

-- Parse a `Type*` chain (zero or more `*` separated by optional whitespace)
-- followed by the type ident. Returns (type_name, pointer_depth) or nil.
local function parse_type_chain(text, pos)
	if pos > #text then return nil end
	-- Skip leading whitespace before the type ident.
	local start = duffle.skip_ws_and_cmt(text, pos)
	local ident, after = duffle.read_ident(text, start)
	if not ident then return nil end
	local depth  = 0
	local cursor = duffle.skip_ws_and_cmt(text, after)
	while cursor <= #text and text:sub(cursor, cursor) == "*" do
		depth  = depth + 1
		cursor = cursor + 1
		cursor = duffle.skip_ws_and_cmt(text, cursor)
	end
	return ident, depth, cursor
end

-- Parse the U4 fields from a Binds_X body. Returns (fields, byte_count).
local function scan_binds_fields(body)
	local fields   = {}
	local byte_off = 0
	local body_pos = 1
	while body_pos <= #body do
		body_pos = duffle.skip_ws_and_cmt(body, body_pos)
		if body_pos > #body then break end
		local type_ident, type_end = duffle.read_ident(body, body_pos)
		if not type_ident then
			body_pos = body_pos + 1
		elseif type_ident == "U4" then
			local field_ident, field_end = duffle.read_ident(body, duffle.skip_ws_and_cmt(body, type_end))
			if field_ident then
				fields[#fields + 1] = { name = field_ident, offset = byte_off }
				byte_off = byte_off + 0x04    -- U4 field = 4 bytes (= 1 .word)
			end
			body_pos = field_end or (type_end + 1)
		else
			body_pos = type_end + 1
		end
	end
	return fields, byte_off
end

-- Parse the register list from inside `atom_reads(...)` or `atom_writes(...)`.
local function scan_reg_list(sub_inner)
	local regs = {}
	local sub_inner_pos = 1
	while sub_inner_pos <= #sub_inner do
		sub_inner_pos = duffle.skip_ws_and_cmt(sub_inner, sub_inner_pos)
		if sub_inner_pos > #sub_inner then break end
		local reg_ident, reg_end = duffle.read_ident(sub_inner, sub_inner_pos)
		if reg_ident then
			regs[#regs + 1] = duffle.trim(reg_ident)
			sub_inner_pos = reg_end
		else
			sub_inner_pos = sub_inner_pos + 1
		end
		if sub_inner_pos > #sub_inner then break end
		if sub_inner:sub(sub_inner_pos, sub_inner_pos) == "," then sub_inner_pos = sub_inner_pos + 1 end
	end
	return regs
end

-- Parse the sub-calls inside `atom_info(atom_bind(...), atom_reads(...), atom_writes(...), atom_view(...), atom_reg_types(...))`.
-- Returns (binds, reads, writes, view_binds, reg_overrides).
-- `view_binds` is the Binds_X ident from `atom_view(Binds_X)`.
-- `reg_overrides` is a {reg_name = {type_name, pointer_depth}} table for `atom_reg_types(R_X, <type>)`.
local function scan_atom_info_subcalls(info_inner)
	local binds, reads, writes = nil, nil, nil
	local view_binds, reg_overrides = nil, nil
	local sub_pos = 1
	while sub_pos <= #info_inner do
		sub_pos = duffle.skip_ws_and_cmt(info_inner, sub_pos)
		if sub_pos > #info_inner then break end
		local sub_ident, sub_end = duffle.read_ident(info_inner, sub_pos)
		if not sub_ident then
			sub_pos = sub_pos + 1
		elseif sub_ident == "atom_bind" then
			local sub_open = duffle.skip_ws_and_cmt(info_inner, sub_end)
			if info_inner:sub(sub_open, sub_open) == "(" then
				local sub_inner, sub_after2 = duffle.read_parens(info_inner, sub_open)
				-- scan: atom_bind(<Binds_X>)
				binds   = duffle.trim(sub_inner)
				sub_pos = sub_after2
			else
				sub_pos = sub_open + 1
			end
		elseif sub_ident == "atom_reads" or sub_ident == "atom_writes" then
			local kind     = sub_ident
			local sub_open = duffle.skip_ws_and_cmt(info_inner, sub_end)
			if info_inner:sub(sub_open, sub_open) == "(" then
				local sub_inner, sub_after2 = duffle.read_parens(info_inner, sub_open)
				-- scan: atom_reads(<regs>)  OR  atom_writes(<regs>)
				local regs = scan_reg_list(sub_inner)
				if kind == "atom_reads" then reads = regs else writes = regs end
				sub_pos = sub_after2
			else
				sub_pos = sub_open + 1
			end
		elseif sub_ident == "atom_view" then
			local sub_open = duffle.skip_ws_and_cmt(info_inner, sub_end)
			if info_inner:sub(sub_open, sub_open) == "(" then
				local sub_inner, sub_after2 = duffle.read_parens(info_inner, sub_open)
				view_binds = duffle.trim(sub_inner)
				sub_pos    = sub_after2
			else
				sub_pos = sub_open + 1
			end
		elseif sub_ident == "atom_reg_types" then
			local sub_open = duffle.skip_ws_and_cmt(info_inner, sub_end)
			if info_inner:sub(sub_open, sub_open) == "(" then
				local sub_inner, sub_after2 = duffle.read_parens(info_inner, sub_open)
				local args = read_top_level_args(sub_inner, 1)
				if args[1] then
					reg_overrides = reg_overrides or {}
					local reg_name = duffle.trim(args[1])
					local type_name, depth = nil, 0
					if args[2] then
						local parsed_name, parsed_depth = parse_type_chain(args[2], 1)
						if parsed_name then
							type_name, depth = parsed_name, parsed_depth
						else
							type_name, depth = duffle.trim(args[2]), 0
						end
					end
					reg_overrides[reg_name] = { type_name = type_name, pointer_depth = depth }
				end
				sub_pos = sub_after2
			else
				sub_pos = sub_open + 1
			end
		else
			sub_pos = sub_end
		end
	end
	return binds, reads, writes, view_binds, reg_overrides
end

-- Skip C qualifier keywords and return the position past the last one.
local function scan_skip_qualifiers(source, pos)
	while true do
		pos = duffle.skip_ws_and_cmt(source, pos)
		local ident, after = duffle.read_ident(source, pos)
		if not ident then return pos end
		if QUALIFIER_KEYWORDS[ident] then pos = after else return pos end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Per-form parsers (the DECL_PARSERS table's payload)
-- ════════════════════════════════════════════════════════════════════════════
--
-- Each parser has the uniform signature:
--   parser(source, pos, ident_end, line_of, out) -> new_pos
-- where:
--   source    -- the full source text
--   pos       -- position of the construct's leading ident (e.g., `M` of `MipsAtom_`)
--   ident_end -- position past the leading ident (where the `(` should be)
--   line_of   -- closure over LineIndex(source) for 1-based line lookups
--   out       -- the SourceScan out table (mutated in place: out.atoms / out.raw_atoms / out.binds / out.atom_infos / out.macros / out.skip_over)
--   returns   -- new position after the construct
--
-- All parsers read source-as-written via the duffle primitives (skip_ws_and_cmt / read_parens / read_braces / read_balanced).
-- No regex per the no_regex constraint; no hand-rolled depth tracking (the MipsAtomComp_Proc_ brace matcher
-- now uses duffle.read_braces instead of bespoke byte-dispatch).
--
-- Adding a new construct = 1 row in DECL_PARSERS + 1 parser function. The scan_source() loop never needs editing.

--- Parse an empty debug-skip marker and retain its raw placement evidence.
--- @param source string
--- @param pos integer
--- @param ident_end integer
--- @param line_of fun(pos: integer): integer
--- @param out SourceScan
--- @param marker_kind string
--- @return integer
local function parse_skip_over_marker(source, pos, ident_end, line_of, out, marker_kind)
	local open_paren = duffle.skip_ws_and_cmt(source, ident_end)
	local marker = {
		marker_kind = marker_kind,
		marker_line = line_of(pos),
		marker_pos    = pos,
		after_paren   = ident_end,
		args          = nil,
		has_parens    = false,
	}
	if source:sub(open_paren, open_paren) == "(" then
		local inner, after_paren = duffle.read_parens(source, open_paren)
		marker.after_paren = after_paren
		marker.args        = duffle.trim(inner)
		marker.has_parens  = true
	end
	push_skip_over_marker(out, marker)
	return marker.after_paren
end

local function parse_atom_dbg_skip_over(source, pos, ident_end, line_of, out)
	return parse_skip_over_marker(source, pos, ident_end, line_of, out, "atom_dbg_skip_over")
end

-- Parse `atom_dbg_reg_default(R_X, <type>...)`; the second argument may be
-- a `Type` or `Type*`/`Type**` chain. Records in `out.types[R_X]`.
local function parse_atom_dbg_reg_default(source, pos, ident_end, line_of, out)
	local open_paren = duffle.skip_ws_and_cmt(source, ident_end)
	if source:sub(open_paren, open_paren) ~= "(" then return open_paren + 1 end
	local inner, after_paren = duffle.read_parens(source, open_paren)
	local args = read_top_level_args(inner, 1)
	if #args < 1 then
		-- Annotation pass surfaces this; we still consume the marker.
		return after_paren
	end
	local reg_name  = duffle.trim(args[1])
	local type_part = args[2] or "void"
	local type_name, depth = parse_type_chain(type_part, 1)
	if not type_name then type_name, depth = duffle.trim(type_part), 0 end
	out.types[reg_name] = {
		name          = reg_name,
		type_name     = type_name,
		pointer_depth = depth,
		source_line   = line_of(pos),
	}
	out.type_occurrences = out.type_occurrences or {}
	out.type_occurrences[#out.type_occurrences + 1] = {
		reg        = reg_name,
		type_name  = type_name,
		source_line = line_of(pos),
	}
	return after_paren
end

--- Parse: `MipsAtom_(<name>) [atom_info(<binds>, <reads>, <writes>)] { <body> }`
--- @param source string
--- @param pos integer
--- @param ident_end integer
--- @param line_of fun(pos: integer): integer
--- @param out SourceScan
--- @return integer
local function parse_mips_atom(source, pos, ident_end, line_of, out)
	local open_paren = duffle.skip_ws_and_cmt(source, ident_end)
	if source:sub(open_paren, open_paren) ~= "(" then return open_paren + 1 end
	local inner, after_paren = duffle.read_parens(source, open_paren)

	local raw_name = duffle.read_ident(inner, 1)

	-- Lookahead for atom_info(...) between `)` and `{`. Captures sub-calls; updates brace search start.
	local brace_search_pos = after_paren
	local lookahead        = duffle.skip_ws_and_cmt(source, after_paren)
	local look_ident, look_end = duffle.read_ident(source, lookahead)
	if look_ident == "atom_info" then
		local info_open = duffle.skip_ws_and_cmt(source, look_end)
		if source:sub(info_open, info_open) == "(" then
			local info_inner, info_after = duffle.read_parens(source, info_open)
			local ai_binds, ai_reads, ai_writes, ai_view, ai_overrides = scan_atom_info_subcalls(info_inner)
			out.atom_infos[#out.atom_infos + 1] = {
				atom_name = raw_name or "?", binds = ai_binds,
				reads     = ai_reads or {}, writes = ai_writes or {},
				view      = ai_view,
				reg_type_overrides = ai_overrides,
				info_line = line_of(lookahead),
			}
			if ai_view and raw_name then
				out.atom_views[raw_name] = {
					atom_name         = raw_name,
					binds_name        = ai_view,
					reg_type_overrides = ai_overrides,
					info_line         = line_of(lookahead),
				}
			elseif raw_name and ai_overrides then
				-- Record per-atom overrides even without atom_view.
				out.atom_views[raw_name] = out.atom_views[raw_name]
					or { atom_name = raw_name, binds_name = nil, reg_type_overrides = nil, info_line = line_of(lookahead) }
				out.atom_views[raw_name].reg_type_overrides = ai_overrides
			end
			brace_search_pos = info_after
		end
	end

	local brace = duffle.scan_to_char(source, "{", brace_search_pos)
	if not brace then return open_paren + 1 end

	local body, after_brace = duffle.read_braces(source, brace)
	if raw_name and raw_name ~= "" then
		local declaration_line = line_of(pos)
		out.atoms[#out.atoms + 1] = {
			line        = declaration_line, name = raw_name, body = body, body_off = brace + 1,
			kind        = "atom", raw_name = raw_name,
			ident_pos   = pos, after_paren = after_paren,
		}
		associate_skip_over_marker(out, raw_name, raw_name, "atom", declaration_line, pos)
	end

	return after_brace
end

--- Parse: `MipsAtomComp_(<name>) { <body> }`
--- @param source string
--- @param pos integer
--- @param ident_end integer
--- @param line_of fun(pos: integer): integer
--- @param out SourceScan
--- @return integer
local function parse_mips_atom_comp(source, pos, ident_end, line_of, out)
	local open_paren = duffle.skip_ws_and_cmt(source, ident_end)
	if source:sub(open_paren, open_paren) ~= "(" then return open_paren + 1 end
	local inner, after_paren = duffle.read_parens(source, open_paren)

	local raw_name = duffle.read_ident(inner, 1)
	if not raw_name then return open_paren + 1 end

	local brace = duffle.scan_to_char(source, "{", after_paren)
	if not brace then return open_paren + 1 end

	local body, after_brace = duffle.read_braces(source, brace)
	local name = strip_ac_prefix(raw_name)
	local declaration_line = line_of(pos)

	out.atoms[#out.atoms + 1] = {
		line        = declaration_line, name = name, body = body, body_off = brace + 1,
		kind        = "comp_bare", raw_name = raw_name,
		ident_pos   = pos, after_paren = after_paren,
	}
	associate_skip_over_marker(out, name, raw_name, "comp_bare", declaration_line, pos)

	return after_brace
end

--- Parse: `MipsAtomComp_Proc_(<name>, { <body> })` — body is inside the LAST `{` in args.
--- @param source string
--- @param pos integer
--- @param ident_end integer
--- @param line_of fun(pos: integer): integer
--- @param out SourceScan
--- @return integer
local function parse_mips_atom_comp_proc(source, pos, ident_end, line_of, out)
	local open_paren = duffle.skip_ws_and_cmt(source, ident_end)
	if source:sub(open_paren, open_paren) ~= "(" then return open_paren + 1 end
	local inner, after_paren = duffle.read_parens(source, open_paren)

	-- Find the LAST `{` in inner (the body brace, not any potential embedded braces in expressions).
	local last_brace_pos = nil
	for search_pos = #inner, 1, -1 do
		if inner:sub(search_pos, search_pos) == "{" then last_brace_pos = search_pos; break end
	end
	if not last_brace_pos then return after_paren end

	-- Use duffle.read_braces to find the matching close brace.
	-- Replaces the pre-refactor hand-rolled depth tracker (~25 LOC of `if c == 123 then depth = depth + 1 ...`).
	-- If close_pos is past the end of inner, the brace didn't match (malformed input); skip.
	local body, close_pos = duffle.read_braces(inner, last_brace_pos)
	if close_pos > #inner + 1 then return after_paren end

	local raw_name = inner:match("^%s*([%w_]+)") or "?"
	local name = strip_ac_prefix(raw_name)
	local declaration_line = line_of(pos)
	-- Position of body[1] in source = open_paren + 1 (start of inner) + last_brace_pos + 1 (past '{').
	local body_off = open_paren + 2 + last_brace_pos

	out.atoms[#out.atoms + 1] = {
		line        = declaration_line, name = name, body = body, body_off = body_off,
		kind        = "comp_proc", raw_name = raw_name,
		ident_pos   = pos, after_paren = after_paren,
	}
	associate_skip_over_marker(out, name, raw_name, "comp_proc", declaration_line, pos)

	return after_paren
end

--- Parse: `MipsCode code_<name> { <body> }` (raw atom form — offsets pass only).
--- @param source string
--- @param pos integer
--- @param ident_end integer
--- @param line_of fun(pos: integer): integer
--- @param out SourceScan
--- @return integer
local function parse_mips_code(source, pos, ident_end, line_of, out)
	local next_pos = duffle.skip_ws_and_cmt(source, ident_end)
	local next_ident, next_after = duffle.read_ident(source, next_pos)
	if not next_ident or #next_ident <= 5 or next_ident:sub(1, 5) ~= "code_" then
		return ident_end
	end

	local atom_name = next_ident:sub(6)
	local brace_pos = duffle.scan_to_char(source, "{", next_after)
	if not brace_pos then return ident_end end

	local body, after_brace = duffle.read_braces(source, brace_pos)
	local declaration_line = line_of(pos)
	out.raw_atoms[#out.raw_atoms + 1] = {
		line      = declaration_line, name = atom_name, body = body, body_off = brace_pos + 1,
		kind      = "raw_atom", raw_name = atom_name,
	}
	associate_skip_over_marker(out, atom_name, next_ident, "unrelated", declaration_line, pos)

	return after_brace
end

--- Parse: `typedef Struct_(<name>) { <fields> }` — only emits when name starts with `Binds_`.
--- @param source string
--- @param pos integer
--- @param ident_end integer
--- @param line_of fun(pos: integer): integer
--- @param out SourceScan
--- @return integer
local function parse_typedef_binds(source, pos, ident_end, line_of, out)
	local after_typedef = duffle.skip_ws_and_cmt(source, ident_end)
	local id2, id2_end = duffle.read_ident(source, after_typedef)
	if id2 ~= "Struct_" then return ident_end end

	local open_paren = duffle.skip_ws_and_cmt(source, id2_end)
	if source:sub(open_paren, open_paren) ~= "(" then return id2_end end

	local inner, after_paren = duffle.read_parens(source, open_paren)
	local name = duffle.trim(inner)

	local brace = duffle.scan_to_char(source, "{", after_paren)
	if not brace then return open_paren + 1 end

	local body, after_brace = duffle.read_braces(source, brace)
	if name:sub(1, 6) == "Binds_" then
		local fields, byte_off = scan_binds_fields(body)
		out.binds[#out.binds + 1] = { line = line_of(pos), name = name, fields = fields, bytes = byte_off }
	end
	associate_skip_over_marker(out, name, name, "unrelated", line_of(pos), pos)

	return after_brace
end

--- Parse: `_Pragma("mac_X tape_atom words=N")` (operator form).
--- @param source string
--- @param pos integer
--- @param ident_end integer
--- @param line_of fun(pos: integer): integer
--- @param out SourceScan
--- @return integer
local function parse_pragma_macro(source, pos, ident_end, line_of, out)
	local open_paren = duffle.skip_ws_and_cmt(source, ident_end)
	if source:sub(open_paren, open_paren) ~= "(" then return open_paren + 1 end

	local str, str_end = duffle.read_parens(source, open_paren)
	str = duffle.trim(str)
	if str:sub(1, 1) ~= '"' or str:sub(-1) ~= '"' then return str_end end

	local inner = str:sub(2, -2)
	local space = duffle.find_byte(inner, 32, 1)
	if not space then return str_end end

	local name = inner:sub(1, space - 1)
	local rest = inner:sub(space + 1)
	local eq = duffle.find_byte(rest, 61, 1)
	if not eq then return str_end end

	local key = duffle.trim(rest:sub(1, eq - 1))
	local val = duffle.trim(rest:sub(eq + 1))
	if key == "tape_atom words" or key == "words" then
		out.macros[#out.macros + 1] = { line = line_of(pos), name = name, words = tonumber(val) or 0 }
	end

	return str_end
end

--- Parse: `pragma` ident (no-op — directive form `#pragma` is handled by `skip_preprocessor_line` upstream).
--- If we reach this parser it means the directive skip didn't fire, which can happen for non-#-prefixed pragma.
--- Just advance past the ident.
--- @param source string
--- @param pos integer
--- @param ident_end integer
--- @param line_of fun(pos: integer): integer
--- @param out SourceScan
--- @return integer
local function parse_pragma_dummy(source, pos, ident_end, line_of, out)
	return ident_end
end

-- ════════════════════════════════════════════════════════════════════════════
-- DECL_PARSERS — data-driven construct dispatch (the plex pattern)
-- ════════════════════════════════════════════════════════════════════════════
--
-- Each entry maps a leading ident to its parser function. The main scan_source() loop is one line of dispatch:
--   local parser = DECL_PARSERS[ident]; if parser then pos = parser(...) end
--
-- Adding a new construct = 1 row here + 1 parser function above.

local DECL_PARSERS = {
	MipsAtom_                  = parse_mips_atom,
	MipsAtomComp_              = parse_mips_atom_comp,
	MipsAtomComp_Proc_         = parse_mips_atom_comp_proc,
	atom_dbg_skip_over         = parse_atom_dbg_skip_over,
	atom_dbg_reg_default       = parse_atom_dbg_reg_default,
	MipsCode                   = parse_mips_code,
	typedef                    = parse_typedef_binds,
	_Pragma                    = parse_pragma_macro,
	pragma                     = parse_pragma_dummy,
}

-- ════════════════════════════════════════════════════════════════════════════
-- The single source walker
-- ════════════════════════════════════════════════════════════════════════════

--- Single-pass source scan. Walks the source ONCE and extracts every construct type the metaprogram passes need.
--- Returns a fat SourceScan table. Each pass filters from this payload instead of re-walking the source.
--- @param source string
--- @return table  -- SourceScan { atoms, raw_atoms, binds, atom_infos, macros, skip_over, line_of }
local function scan_source(source)
	local line_of = duffle.LineIndex(source)
	local out     = {
		atoms      = {},
		raw_atoms  = {},
		binds      = {},
		atom_infos = {},
		macros     = {},
		skip_over  = {
			atoms      = {},
			components = {},
			markers    = {},
		},
		types      = {},
		atom_views = {},
		line_of    = line_of,
	}
	local pos     = 1
	local src_len = #source

	while pos <= src_len do
		pos = duffle.skip_ws_and_cmt(source, pos)
		if pos > src_len then break end

		-- Skip preprocessor directives (#define / #include / #pragma / etc).
		-- _Pragma is an operator (not a directive) — it doesn't start with #.
		local pp_pos = duffle.skip_preprocessor_line(source, pos)
		if pp_pos then
			pos = pp_pos
		else
			-- Skip C qualifiers (static, const, etc.) that may precede a declaration.
			pos = scan_skip_qualifiers(source, pos)
			if pos <= src_len then
				local ident, ident_end = duffle.read_ident(source, pos)
				if ident then
					local parser = DECL_PARSERS[ident]
					if parser then
						pos = parser(source, pos, ident_end, line_of, out)
					else
						-- A component-procedure declaration has an FI_ signature before
						-- MipsAtomComp_Proc_; keep the marker pending across that prelude.
						-- Any other identifier begins an unrelated declaration/construct
						-- and consumes the marker so it cannot drift to a later atom.
						local markers = out.skip_over.markers
						local marker  = markers[#markers]
						if marker and marker.pending then
							if ident == "FI_" then
								marker.proc_prelude = true
							elseif not marker.proc_prelude then
								associate_skip_over_marker(out, ident, ident, "unrelated", line_of(pos), pos)
							end
						end
						pos = ident_end
					end
				else
					local markers = out.skip_over.markers
					local marker  = markers[#markers]
					if marker and marker.pending and marker.proc_prelude then
						local c = source:sub(pos, pos)
						if c == "{" or c == ";" then
							associate_skip_over_marker(out, c, c, "unrelated", line_of(pos), pos)
						end
					end
					pos = pos + 1
				end
			end
		end
	end

	return out
end

-- ════════════════════════════════════════════════════════════════════════════
-- M — module exports
-- ════════════════════════════════════════════════════════════════════════════

--- @class M

local M = {}

--- Walk each source once and attach the fat SourceScan payload to `src.scan`.
--- No output files; this is a pure in-memory pre-processing pass.
--- @param ctx PassCtx
--- @return PassResult
function M.run(ctx)
	for _, src in ipairs(ctx.sources) do
		src.scan = scan_source(src.text)
		-- Pre-tokenize each atom body once (plex: single source of truth).
		-- Downstream passes (offsets, word-counts, components, static-analysis) read from
		-- `atom.body_tokens` instead of calling `split_top_level_commas` / `tokenize_body` independently.
		-- The tokens are memoized in duffle.lua's cache, so re-access is O(1).
		for _, atom in ipairs(src.scan.atoms) do
			atom.body_tokens = duffle.tokenize_body(atom.body)
		end
		for _, atom in ipairs(src.scan.raw_atoms or {}) do
			atom.body_tokens = duffle.tokenize_body(atom.body)
		end
	end
	return { outputs = {}, errors = {}, warnings = {} }
end

return M
