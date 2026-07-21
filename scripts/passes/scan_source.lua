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
-- Uses `debug.getinfo` to find this file's own directory, so it works both standalone and when require'd from the orchestrator.
-- Bootstrap: load `duffle_paths.lua` via `debug.getinfo(1, "S").source` (works both standalone + when required).
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
--- @field atom_infos  AtomInfoEntry[]                 -- MipsAtom_(name) atom_info(...) (sub-calls pre-parsed)
--- @field macros      MacroEntry[]                    -- #pragma mac_X tape_atom words=N  +   _Pragma("...")
--- @field skip_over   SkipOverScan                    -- atom/component debug-step markers + resolved declaration associations
--- @field types       table<string, RegTypeDefault>   -- atom_dbg_reg_default(R_X, <type>) declarations
--- @field atom_views  table<string, AtomViewEntry>    -- MipsAtom_(name) -> {binds_name, reg_type_overrides, info_line}
--- @field atom_ctxs   table<string, AtomCtxEntry>     -- MipsAtom_(name) -> {rbind_atom, info_line, source} (atom_ctx(...) call sites)
--- @field atom_phases table<string, AtomPhaseGroup>   -- phase_label -> {atoms = {atom_name1, atom_name2, ...}} (atom_phase(...) tags)
--- @field line_of     fun(pos: integer): integer      -- shared LineIndex closure

--- @class SkipOverScan
--- @field atoms      table<string, SkipOverAssociation>
--- @field components table<string, SkipOverAssociation>
--- @field markers    SkipOverMarker[]

--- @class SkipOverMarker
--- @field marker_kind    string      -- exact marker ident (always "atom_dbg_skip_over")
--- @field marker_line    integer
--- @field marker_pos     integer
--- @field after_paren    integer
--- @field args           string|nil  -- trimmed marker args""
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
--- @field source_line   integer -- line of the call site (callsite or enum-site)

--- @class AtomCtxEntry
--- @field rbind_atom string  -- the rbind atom ident that this consumer should propagate types from
--- @field info_line  integer
--- @field source     string  -- absolute path of the source file

--- @class AtomPhaseGroup
--- @field atoms string[]  -- atom names tagged with this phase label (source-order)

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
--- @field name       string     -- atom name (for components: without ac_ prefix)
--- @field body       string     -- brace-delimited body (without the braces)
--- @field body_off   integer    -- char offset of body[1] in source
--- @field kind       string     -- "atom" | "comp_bare" | "comp_proc" | "raw_atom"
--- @field raw_name   string     -- un-stripped name (for components: with ac_ prefix)
--- @field ident_pos  integer    -- position of the MipsAtom_/MipsAtomComp_ ident start
--- @field after_paren integer   -- position past the closing paren
--- @field args       string|nil -- populated by components pass (backward lookup)
--- @field comment    string|nil -- populated by components pass (backward lookup)

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

-- "ac_" prefix length on component names (e.g., `MipsAtomComp_(ac_X, ...)`).
-- The components pass strips this prefix to derive the macro name (e.g., `mac_X`). 
local AC_PREFIX     = "ac_"
local AC_PREFIX_LEN = 3

-- Strip the "ac_" prefix from a component name.
-- Returns the input unchanged if it doesn't start with the prefix.
-- @param raw_name string
-- @return string
local function strip_ac_prefix(raw_name)
	if #raw_name > AC_PREFIX_LEN and raw_name:sub(1, AC_PREFIX_LEN) == AC_PREFIX then
		return raw_name:sub(AC_PREFIX_LEN + 1)
	end
	return raw_name
end

-- Preserve a source marker until the following declaration parser observes it.
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

-- Try to read `(...)` parens after `ident_end`.
-- Returns (inner, after_paren, open_paren) on success, or (nil, fallback_pos) if no parens.
-- `fallback_pos` defaults to `open_paren + 1` (the common "advance by 1" no-parens case).
local function read_parens_after(source, ident_end, fallback)
	local open_paren = duffle.skip_ws_and_cmt(source, ident_end)
	if source:sub(open_paren, open_paren) ~= "(" then return nil, fallback or open_paren + 1 end
	local inner, after_paren = duffle.read_parens(source, open_paren)
	return inner, after_paren, open_paren
end

-- Find the opening `{` of a body block and read its contents.
-- Returns (body, after_brace, body_off) on success, or (nil, fallback_pos) on no brace.
-- `fallback_pos` defaults to `after_paren + 1` (the common "advance by 1" case).
local function find_body_braces(source, after_paren, fallback)
	local brace = duffle.scan_to_char(source, "{", after_paren)
	if not brace then return nil, fallback or (after_paren + 1) end
	local body, after_brace = duffle.read_braces(source, brace)
	return body, after_brace, brace + 1
end

-- Attach the pending marker to the next declaration. 
-- The declaration form disambiguates whole atoms from components;
-- unsupported declarations retain placement evidence for annotation.lua and populate neither lookup table.
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

-- Register a parsed atom entry in `out.atoms` and link its skip-over marker.
-- Captures the shared 8-field shape used by MipsAtom_, MipsAtomComp_, MipsAtomComp_Proc_.
local function register_atom(out, kind, declaration_line, name, body, body_off, raw_name, pos, after_paren)
	out.atoms[#out.atoms + 1] = {
		line      = declaration_line, name = name, body = body, body_off = body_off,
		kind      = kind, raw_name = raw_name,
		ident_pos = pos, after_paren = after_paren,
	}
	associate_skip_over_marker(out, name, raw_name, kind, declaration_line, pos)
end

-- Register a parsed raw-atom entry in `out.raw_atoms` and link its skip-over marker.
-- Captures the 5-field shape used by MipsCode (the raw-atom form; offsets pass only).
local function register_raw_atom(out, declaration_line, name, body, body_off, raw_name, pos, marker_kind)
	out.raw_atoms[#out.raw_atoms + 1] = {
		line = declaration_line, name = name, body = body, body_off = body_off,
		kind = "raw_atom", raw_name = raw_name,
	}
	associate_skip_over_marker(out, name, raw_name, marker_kind, declaration_line, pos)
end

-- Parse a `Type*` chain (zero or more `*` separated by optional whitespace) followed by the type ident.
-- Returns (type_name, pointer_depth) or nil.
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

-- Byte-size lookup for builtin C primitives + the GCC __UINT*_TYPE__ family.
-- Returns a confident byte_size (positive integer) or nil if `type_name` is not a known builtin primitive.
-- Builtin primitive map; used by the byte-size propagation pass to seed confident byte_size values for typedef chains that bottom out at a builtin.
local BUILTIN_BYTE_SIZES = {
	["U1"]                  = 1,
	["U2"]                  = 2,
	["U4"]                  = 4,
	["S1"]                  = 1,
	["S2"]                  = 2,
	["S4"]                  = 4,
	-- GCC __UINT*/__INT*_TYPE__ family (used by the duffle TSet_ convention in dsl.h).
	-- MIPS32 has no 64-bit types; __UINT64_TYPE__/__INT64_TYPE__ are excluded.
	["__UINT8_TYPE__"]      = 1,
	["__UINT16_TYPE__"]     = 2,
	["__UINT32_TYPE__"]     = 4,
	["__INT8_TYPE__"]       = 1,
	["__INT16_TYPE__"]      = 2,
	["__INT32_TYPE__"]      = 4,
}

-- Pointer fields collapse to 4 bytes on MIPS32 (PS1).
local POINTER_BYTE_SIZE = 4

-- Maximum chain depth when resolving typedef / TSet_ chains (cycle guard).
local TYPE_CHAIN_MAX_DEPTH = 8

-- Walk a `Struct_` / `Enum_` body, calling `build_field(first, first_end, after_first)` for each entry.
-- The builder returns either:
--   - (record, new_pos)  -- append record to fields; advance body_pos to new_pos
--   - (nil, new_pos)     -- skip this entry; advance body_pos to new_pos
-- After each entry, the walker skips a single trailing `,` or `;`.
-- The 2 body-field parsers in this file (struct + enum) share this body-walk loop.
-- @param body string
--- @param build_field fun(first: string, first_end: integer, after_first: integer): (table|nil, integer)
--- @return table[]
local function walk_body_fields(body, build_field)
	local fields   = {}
	local body_pos = 1
	local body_len = #body
	while body_pos <= body_len do
		body_pos = duffle.skip_ws_and_cmt(body, body_pos)
		if body_pos > body_len then break end
		local first, first_end = duffle.read_ident(body, body_pos)
		if not first then
			body_pos = body_pos + 1
		else
			local after_first = duffle.skip_ws_and_cmt(body, first_end)
			local result, new_pos = build_field(first, first_end, after_first)
			if result then fields[#fields + 1] = result end
			body_pos = new_pos or first_end
			-- Skip a single trailing `,` or `;`.
			if body_pos <= body_len and (body:sub(body_pos, body_pos) == "," or body:sub(body_pos, body_pos) == ";") then
				body_pos = body_pos + 1
			end
		end
	end
	return fields
end

-- Parse the `<type> <field>;` declarations from a Struct_ body.
-- Returns the raw fields array with `{name, type_name, pointer_depth}` only (NO offset / byte_size).
-- The propagation pass `resolve_struct_field_sizes` walks each struct's fields AFTER type resolution and populates offset + byte_size in place.
-- Returns (fields). The aggregate byte_count is computed in the propagation pass (it depends on whether every field's type resolved).
local function parse_struct_body_fields(body)
	return walk_body_fields(body, function(type_name, type_end, after_type)
		-- Parse the trailing `*` chain to derive pointer_depth.
		local depth, cursor = 0, after_type
		while cursor <= #body and body:sub(cursor, cursor) == "*" do
			depth  = depth + 1
			cursor = cursor + 1
			cursor = duffle.skip_ws_and_cmt(body, cursor)
		end
		-- Read the field ident immediately after the type chain.
		local field_ident, field_end = duffle.read_ident(body, cursor)
		if not field_ident then return nil, type_end + 1 end
		return {
			name          = field_ident,
			type_name     = type_name,
			pointer_depth = depth,
			-- offset + byte_size filled by resolve_struct_field_sizes
			offset        = nil,
			byte_size     = nil,
		}, field_end
	end)
end

-- Parse the `Enum_(<underlying>, <name>) { <body> }` body for entries.
-- Captures one field per named enumerator with the shape { name, value }.
-- The value is the integer literal parsed from the source via the canonical `parse_enum_int_literal`.
local function parse_enum_body_fields(body)
	return walk_body_fields(body, function(entry_name, name_end, after_name)
		local value
		local new_pos
		if body:sub(after_name, after_name) == "=" then
			local val_pos = duffle.skip_ws_and_cmt(body, after_name + 1)
			local v, end_pos = parse_enum_int_literal(body, val_pos)
			if v ~= nil then
				value   = v
				new_pos = end_pos
			else
				new_pos = after_name + 1
			end
		else
			new_pos = name_end
		end
		return { name = entry_name, value = value }, new_pos
	end)
end

-- Resolve a typedef chain's `byte_size` via repeated underlying_type walks.
-- Returns a positive integer byte_size when the chain bottoms out at a builtin, or nil if the chain is broken, exceeds TYPE_CHAIN_MAX_DEPTH, or contains a cycle.
local function resolve_typedef_byte_size(type_name, type_name_registry, visited, depth)
	if depth > TYPE_CHAIN_MAX_DEPTH then return nil end
	if visited[type_name] then return nil end
	visited[type_name] = true

	-- Check the builtin primitive map FIRST.
	-- This handles undeclared builtin idents (e.g. `__UINT32_TYPE__` appears as underlying_type in `typedef __UINT32_TYPE__ TSet_(V4_S2);` 
	-- even though the fixture never declares `__UINT32_TYPE__` itself).
	local builtin = BUILTIN_BYTE_SIZES[type_name]
	if builtin ~= nil then return builtin end

	local entry = type_name_registry[type_name]
	if not entry then return nil end

	-- Confident: this entry was already resolved by the propagation pass
	-- (e.g., a builtin or a struct whose fields are all resolved).
	if entry.byte_size ~= nil then return entry.byte_size end

	-- Chain-following: typedef / TSet_ aliases follow underlying_type.
	if entry.underlying_type then
		return resolve_typedef_byte_size(
			entry.underlying_type, type_name_registry, visited, depth + 1)
	end

	-- Struct_ entries with unresolved byte_size can still resolve when their fields are all resolved.
	if entry.kind == "struct" and entry.fields then
		local sum       = 0
		local all_have  = true
		for _, f in ipairs(entry.fields) do
			if f.byte_size == nil then all_have = false; break end
			sum = sum + f.byte_size
		end
		if all_have and #entry.fields > 0 then return sum end
	end

	return nil
end

-- Propagation pass: resolve every entry's `byte_size` field by walking typedef chains, struct field sums, and the builtin primitive map.
-- Builtins seed confident values; chains follow underlying_type recursively with a per-chain cycle guard (depth <= 8);
-- struct byte_size derives from confident fields; void is invalid and skipped; pointers collapse to 4 bytes at parse time.
-- Mutates `out.type_name_registry[name].byte_size` AND each struct's fields' `offset` + `byte_size` in place.
local function propagate_type_sizes(out)
	local reg = out.type_name_registry
	if not reg then return end

	-- Seed builtin primitives (U1/U2/U4/S1/S2/S4 + __UINT*_TYPE__ family).
	for name, size in pairs(BUILTIN_BYTE_SIZES) do
		if reg[name] and reg[name].byte_size == nil then
			reg[name].byte_size = size
		end
	end

	-- Resolve typedef / TSet_ chains. Iterate to a fixed point (max TYPE_CHAIN_MAX_DEPTH iterations) 
	-- since chains may span multiple hops and the resolution order isn't guaranteed by declaration order.
	-- The visited map is empty when handed to the resolver.
	-- The resolver marks visited as it enters each node, so the cycle guard fires only on RECURSIVE re-entry (not on the initial call).
	for _ = 1, TYPE_CHAIN_MAX_DEPTH do
		local any_change = false
		for name, entry in pairs(reg) do
			if entry.byte_size == nil then
				local resolved = resolve_typedef_byte_size(name, reg, {}, 1)
				if resolved ~= nil then
					entry.byte_size = resolved
					any_change = true
				end
			end
		end
		if not any_change then break end
	end

	-- Resolve struct field byte_sizes + offsets, then aggregate the struct's own byte_size.
	-- Iterate to a fixed point: struct A may reference struct B which hasn't been resolved yet on the first pass.
	-- Each pass updates as many fields + aggregates as possible; the loop terminates when no struct's byte_size changes between passes.
	for _ = 1, TYPE_CHAIN_MAX_DEPTH do
		local any_change = false
		for _, entry in pairs(reg) do
			if entry.kind == "struct" and entry.fields then
				local byte_off  = 0
				local gap_seen  = false
				local sum       = 0
				local all_have  = true
				for _, f in ipairs(entry.fields) do
					-- Resolve field byte_size (pointer / builtin / typedef chain).
					if f.byte_size == nil then
						if     f.pointer_depth > 0                                    then f.byte_size = POINTER_BYTE_SIZE
						elseif BUILTIN_BYTE_SIZES[f.type_name]                        then f.byte_size = BUILTIN_BYTE_SIZES[f.type_name]
						elseif reg[f.type_name] and reg[f.type_name].byte_size ~= nil then f.byte_size = reg[f.type_name].byte_size
						end
					end

					-- Set offset (clean prefix rule).
					if not gap_seen then
						if f.byte_size ~= nil then
							f.offset = byte_off
							byte_off = byte_off + f.byte_size
						else
							f.offset = nil
							gap_seen = true
						end
					else
						f.offset = nil
					end

					if f.byte_size ~= nil then
						sum = sum + f.byte_size
					else
						all_have = false
					end
				end
				if all_have and #entry.fields > 0 then
					if entry.byte_size ~= sum then
						entry.byte_size = sum
						any_change      = true
					end
				end
			end
		end
		if not any_change then break end
	end

	-- Mirror aggregate byte_size onto the Binds_* entries in out.binds (Binds_* structs are shared via type_name_registry fields;
	-- Only the aggregate bytes needs a mirror write since binds.bytes is a separate field from type_name_registry[name].byte_size).
	for _, bind_entry in ipairs(out.binds or {}) do
		local reg_entry = reg[bind_entry.name]
		if reg_entry then
			bind_entry.bytes = reg_entry.byte_size
		end
	end
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

-- Parse one entry inside `atom_reads(...)` or `atom_writes(...)`.
-- Each top-level comma-separated entry is either:
--   - a plain register ident:               `R_FaceCursor` → reg_name only
--   - register + atom_type sub-call:        `R_FaceCursor atom_type(V4_S2*)` → reg_name + override entry
-- Returns (reg_name, override_entry_or_nil, malformed_flag).
-- On malformed `atom_type(...)` (missing close paren, trailing tokens after the close paren, empty type chain, trailing junk inside the
-- parens like `V4_S2*()`), the function still returns the leading reg_name but sets `malformed_flag = true` and `override_entry = nil`
-- so the caller can silently drop the override while keeping the register in the reads/writes list
-- (per the parser-safety contract — "malformed atom_type MUST NOT create any override").
local function parse_atom_info_reg_entry(entry)
	local pos = 1
	pos = duffle.skip_ws_and_cmt(entry, pos)
	if pos > #entry then return nil, nil, false end
	local reg_name, reg_end = duffle.read_ident(entry, pos)
	if not reg_name then return nil, nil, false end
	pos = duffle.skip_ws_and_cmt(entry, reg_end)
	-- Plain register, no adjacent atom_type — done.
	if pos > #entry then return reg_name, nil, false end

	-- Adjacent ident must be a bare `atom_type` (word-bounded both sides).
	local next_ident, next_end = duffle.read_ident(entry, pos)
	if not next_ident or next_ident ~= "atom_type" then
		return reg_name, nil, false
	end
	-- Left word-boundary: `_atom_type` should NOT match `atom_type`.
	if pos > 1 then
		local prev = entry:byte(pos - 1)
		if duffle.is_alnum_byte(prev) then return reg_name, nil, false end
	end
	-- Right word-boundary: `atom_type_foo` should NOT match `atom_type`.
	if next_end <= #entry then
		local nxt = entry:byte(next_end)
		if duffle.is_alnum_byte(nxt) then return reg_name, nil, false end
	end

	-- Expect `(` immediately after `atom_type` (whitespace tolerated).
	pos = duffle.skip_ws_and_cmt(entry, next_end)
	if pos > #entry or entry:sub(pos, pos) ~= "(" then
		return reg_name, nil, true
	end
	local sub_inner, sub_after = duffle.read_parens(entry, pos)

	-- Reject any trailing tokens (including `;` / `,`) after the close paren.
	-- The outer caller already split on top-level commas, so the only legal terminator here is end-of-entry.
	local after_close = duffle.skip_ws_and_cmt(entry, sub_after)
	if after_close <= #entry then
		return reg_name, nil, true
	end

	-- Parse the type chain inside the parens; require full consumption.
	-- parse_type_chain returns (ident, depth, end_pos);
	-- we reject any non-whitespace residue past end_pos (catches `V4_S2*()` etc.).
	local type_name, depth, after_chain = parse_type_chain(sub_inner, 1)
	if not type_name then return reg_name, nil, true end
	local end_check = duffle.skip_ws_and_cmt(sub_inner, after_chain)
	if end_check <= #sub_inner then
		return reg_name, nil, true
	end

	return reg_name, { type_name = type_name, pointer_depth = depth }, false
end

-- Parse the sub-calls inside `atom_info(atom_bind(...), atom_reads(...), atom_writes(...), atom_view(...), atom_reg_types(...), atom_ctx(...), atom_phase(...))`.
-- Returns (binds, reads, writes, view_binds, reg_overrides, ctx_atom_name, phase_label).
-- `view_binds` is the Binds_X ident from `atom_view(Binds_X)`.
-- `reg_overrides` is a {reg_name = {reg, type_name, pointer_depth, source_line}}
-- table populated from `atom_reg_types(R_X, <type>)` and `atom_type(...)` sub-entries inside `atom_reads(...)` / `atom_writes(...)`.
-- `ctx_atom_name` is the rbind atom ident from `atom_ctx(<atom_name>)` (singular; last-write-wins).
-- `phase_label` is the user-authored C-ident label from `atom_phase(<label>)` (singular; last-write-wins).
-- `info_line` is the 1-based line of the enclosing `atom_info(...)` call;
-- It is recorded as `source_line` on every override entry so downstream passes can locate the declaration.
local function scan_atom_info_subcalls(info_inner, info_line)
	local binds, reads, writes       = nil, nil, nil
	local view_binds, reg_overrides  = nil, nil
	local ctx_atom_name, phase_label = nil, nil

	-- Per-subcall handler table. Each handler takes (sub_inner, info_line) and mutates the outer locals above.
	-- atom_reads/atom_writes share a handler (same shape; just different output target).
	local function rw_handler(sub_inner, info_line, kind)
		-- The reads/writes arrays contain ONLY register idents;
		-- the `atom_type(...)` sub-entry (when present and well-formed) is recorded as a per-atom reg_type_override.
		local entries = duffle.split_top_level_commas(sub_inner)
		local regs     = {}
		for _, entry in ipairs(entries) do
			local reg_name, override, malformed = parse_atom_info_reg_entry(entry)
			if reg_name then
				regs[#regs + 1] = reg_name
				if override then
					reg_overrides = reg_overrides or {}
					reg_overrides[reg_name] = {
						reg           = reg_name,
						type_name     = override.type_name,
						pointer_depth = override.pointer_depth,
						source_line   = info_line,
					}
				end
				-- malformed = silent: plain register still recorded; no override.
			end
		end
		if kind == "atom_reads" then reads = regs else writes = regs end
	end
	local function ident_handler(sub_inner, info_line, out_name)
		-- Validates the arg is a single C identifier (no commas / parens / whitespace).
		-- Silently reject malformed args; the DWARF chain treats the field as un-set.
		local name = duffle.read_ident(sub_inner, 1)
		if name then
			local after_id = duffle.skip_ws_and_cmt(sub_inner, 1 + #name)
			if after_id > #sub_inner then
				if     out_name == "ctx_atom_name" then ctx_atom_name = name
				elseif out_name == "phase_label"   then phase_label   = name end
			end
		end
	end
	local function reg_types_handler(sub_inner, info_line)
		local args = duffle.split_top_level_commas(sub_inner)
		if not args[1] then return end
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
		reg_overrides[reg_name] = {
			reg           = reg_name,
			type_name     = type_name,
			pointer_depth = depth,
			source_line   = info_line,
		}
	end
	local SUBCALL_HANDLERS = {
		-- scan: atom_bind(<Binds_X>)
		atom_bind       = function(sub_inner)            binds = duffle.trim(sub_inner) end,
		-- scan: atom_reads(<R_X [atom_type(<T>)], ...>)
		atom_reads      = function(sub_inner, info_line) rw_handler(sub_inner, info_line, "atom_reads") end,
		-- scan: atom_writes(<R_X [atom_type(<T>)], ...>)
		atom_writes     = function(sub_inner, info_line) rw_handler(sub_inner, info_line, "atom_writes") end,
		-- scan: atom_view(<Binds_X>)
		atom_view       = function(sub_inner)            view_binds = duffle.trim(sub_inner) end,
		-- scan: atom_reg_types(<R_X>, <T>)
		atom_reg_types  = reg_types_handler,
		-- scan: atom_ctx(<atom_name>)
		atom_ctx        = function(sub_inner, info_line) ident_handler(sub_inner, info_line, "ctx_atom_name") end,
		-- scan: atom_phase(<label>)
		atom_phase      = function(sub_inner, info_line) ident_handler(sub_inner, info_line, "phase_label")   end,
	}

	local sub_pos = 1
	while sub_pos <= #info_inner do
		sub_pos = duffle.skip_ws_and_cmt(info_inner, sub_pos)
		if sub_pos > #info_inner then break end
		local sub_ident, sub_end = duffle.read_ident(info_inner, sub_pos)
		if not sub_ident then
			sub_pos = sub_pos + 1
		else
			local sub_open = duffle.skip_ws_and_cmt(info_inner, sub_end)
			if info_inner:sub(sub_open, sub_open) == "(" then
				local sub_inner, sub_after2 = duffle.read_parens(info_inner, sub_open)
				local handler = SUBCALL_HANDLERS[sub_ident]
				if handler then handler(sub_inner, info_line) end
				sub_pos = sub_after2
			else
				sub_pos = sub_open + 1
			end
		end
	end
	return binds, reads, writes, view_binds, reg_overrides, ctx_atom_name, phase_label
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
-- Track A helpers: enum / atom_reg / R_*_Code parsing
-- ════════════════════════════════════════════════════════════════════════════
--
-- The parser walks `enum { <body> }` declarations and emits one AliasEntry per R_* entry whose value is followed by a bare `atom_reg` token.
-- Value resolution handles decimal/negative/hex literals and `R_*_Code` symbol references; 
-- symbol references resolve via the cross-source `_code_macros` registry built in two passes by `M.run`.

-- Byte constants (local to this file).
local BYTE_HASH       = 0x23   -- '#'
local BYTE_NEWLINE    = 0x0A   -- '\n'
local BYTE_DASH       = 0x2D   -- '-'
local BYTE_COMMA      = 0x2C   -- ','
local BYTE_EQUAL      = 0x3D   -- '='
local BYTE_R          = 0x52   -- 'R'
local BYTE_UNDERSCORE = 0x5F   -- '_'
local BYTE_0          = 0x30   -- '0'
local BYTE_9          = 0x39   -- '9'
local BYTE_a          = 0x61   -- 'a'
local BYTE_f          = 0x66   -- 'f'
local BYTE_A          = 0x41   -- 'A'
local BYTE_F          = 0x46   -- 'F'
local BYTE_x          = 0x78   -- 'x'
local BYTE_X          = 0x58   -- 'X'
local BYTE_OPEN_BRACE = 0x7B   -- '{'
local BYTE_CLOSE_BRACE= 0x7D   -- '}'

-- Maximum chain depth when resolving `R_*_Code` symbol RHS references.
-- Eight hops is enough for any production chain (R_TapePtr_Code -> R_T8_Code -> ...).
local CODE_MACRO_MAX_DEPTH = 8

-- Returns true iff the byte is one of [0-9a-fA-F].
local function is_hex_digit_byte(b)
	if not b then return false end
	if b >= BYTE_0 and b <= BYTE_9 then return true end
	if b >= BYTE_a and b <= BYTE_f then return true end
	if b >= BYTE_A and b <= BYTE_F then return true end
	return false
end

-- Returns the hex digit value for byte `b`, or nil if `b` is not a hex digit.
local function hex_digit_value(b)
	if not b then return nil end
	if b >= BYTE_0 and b <= BYTE_9 then return b - BYTE_0 end
	if b >= BYTE_a and b <= BYTE_f then return b - BYTE_a + 10 end
	if b >= BYTE_A and b <= BYTE_F then return b - BYTE_A + 10 end
	return nil
end

-- Parse a decimal/negative-decimal/hex integer literal starting at byte position `start`.
-- Returns (value, end_pos) on success, or (nil, start) on failure / no match.
-- Accepts: 12, -1, 0, 0x10, 0X1F, -0x10.
-- @param text string
-- @param start integer
-- @return integer|nil, integer
local function parse_enum_int_literal(text, start)
	local pos = start
	local len = #text
	if pos > len then return nil, start end

	local sign = 1
	if text:byte(pos) == BYTE_DASH then
		sign = -1
		pos  = pos + 1
	end
	if pos > len then return nil, start end
	if not duffle.is_digit_byte(text:byte(pos)) then return nil, start end

	-- Detect hex form: `0x` / `0X`. Decimal fallback otherwise.
	if text:byte(pos) == BYTE_0 and pos + 1 <= len then
		local peek = text:byte(pos + 1)
		if peek == BYTE_x or peek == BYTE_X then
			pos = pos + 2
			local value     = 0
			local has_digit = false
			while pos <= len do
				local d = hex_digit_value(text:byte(pos))
				if not d then break end
				value     = value * 16 + d
				has_digit = true
				pos       = pos + 1
			end
			if not has_digit then return nil, start end
			return sign * value, pos
		end
	end

	-- Decimal form.
	local value = 0
	while pos <= len do
		local b = text:byte(pos)
		if not (b >= BYTE_0 and b <= BYTE_9) then break end
		value = value * 10 + (b - BYTE_0)
		pos   = pos + 1
	end
	return sign * value, pos
end

-- Returns true iff `name` matches the `R_*_Code` ident pattern (R, _, <anything>, _Code).
-- Uses byte checks for the fixed bytes per the Track A spec.
local function is_r_code_macro(name)
	if not name or #name < 6 then return false end
	if name:byte(1) ~= BYTE_R          then return false end
	if name:byte(2) ~= BYTE_UNDERSCORE then return false end
	if name:sub(-5) ~= "_Code"         then return false end
	return true
end

-- Look up an already-extracted `R_*_Code` macro name via the resolved `code_macros` registry,
-- with cross-source fallback to the raw RHS bodies in `code_macro_bodies` when the registry misses.
-- The chain recurses through the body via `resolve_code_macro_value` (which parses the body string as if it were the original RHS text).
-- Cycle guard via the per-chain `visited` table; cap at CODE_MACRO_MAX_DEPTH. Returns the resolved integer or nil.
local function lookup_code_value(sym, code_macros, code_macro_bodies, visited, depth)
	if depth > CODE_MACRO_MAX_DEPTH then return nil end
	if visited[sym] then return nil end
	visited[sym] = true

	-- Direct registry hit.
	if code_macros and code_macros[sym] ~= nil then return code_macros[sym] end

	-- Cross-source fallback: walk the raw RHS body of the missing symbol.
	local body = code_macro_bodies and code_macro_bodies[sym]
	if body then
		return resolve_code_macro_value(body, 1, code_macros, code_macro_bodies, visited, depth + 1)
	end

	return nil
end

-- Try to resolve the RHS at byte position `pos` (in `source`) as an integer code.
-- The RHS may be either an integer literal (decimal/negative/hex) or a `R_*_Code` symbol reference resolved via the `code_macros` registry.
-- When the registry misses, falls back to the cross-source `code_macro_bodies` table
-- (raw RHS text collected from all sources during pass 1a) so the chain `R_TapePtr_Code -> R_T8_Code -> 24`
-- resolves even when the defining `#define R_T8_Code 24` lives in a different source than the chain call site.
-- Recursive via per-chain `visited` + `depth`; cap at CODE_MACRO_MAX_DEPTH; on cycle return nil.
-- Returns the resolved integer value, or nil if unresolvable.
local function resolve_code_macro_value(source, pos, code_macros, code_macro_bodies, visited, depth)
	if depth > CODE_MACRO_MAX_DEPTH then return nil end
	pos = duffle.skip_ws_and_cmt(source, pos)

	-- Try integer literal first (decimal / negative / hex).
	local int_val, int_end = parse_enum_int_literal(source, pos)
	if int_val ~= nil then return int_val end

	-- Try symbol reference (must be R_*_Code per the spec).
	local sym = duffle.read_ident(source, pos)
	if not sym then return nil end
	if not is_r_code_macro(sym) then return nil end

	-- Cycle guard: bail if we've already seen this symbol on the current chain.
	if visited[sym] then return nil end
	visited[sym] = true

	-- Direct registry hit — done.
	if code_macros[sym] ~= nil then return code_macros[sym] end

	-- Cross-source fallback: walk the body of the missing symbol if any other source collected its RHS during pass 1a.
	-- The body is parsed as a fresh RHS (it's the raw post-`=` text of the original `#define` line), so the chain continues transparently.
	local body = code_macro_bodies and code_macro_bodies[sym]
	if body then
		return resolve_code_macro_value(body, 1, code_macros, code_macro_bodies, visited, depth + 1)
	end

	-- Forward reference / unresolved: pass 1 stores resolved ints;
	-- pass 2 re-encounters every `#define R_*_Code` line and resolves using the now-populated cross-source registries.
	-- Returning nil here is the documented behavior; the enum-value lookup in pass 2 will also see nil and report via the AliasEntry.code = nil path.
	return nil
end

-- Intercept a `#define R_*_Code <RHS>` preprocessor line.
-- Always saves the raw RHS text into `code_macro_bodies` (for cross-source fallback during chain resolution),
-- then (if resolvable) stores the resolved integer code into `code_macros` keyed by the macro name.
-- `directive_start` points at the `#` byte. The function is silent on non-matching directives, the caller skips the line in any case.
-- @param source string
-- @param directive_start integer  -- byte position of `#`
-- @param code_macros table        -- out._code_macros / ctx.shared._code_macros
-- @param code_macro_bodies table  -- out._code_macro_bodies / ctx.shared._code_macro_bodies
local function try_extract_code_macro(source, directive_start, code_macros, code_macro_bodies)
	local rest = duffle.skip_ws_and_cmt(source, directive_start + 1)
	local kw, kw_end = duffle.read_ident(source, rest)
	if kw ~= "define" then return end

	local after_kw = duffle.skip_ws_and_cmt(source, kw_end)
	local macro_name, macro_end = duffle.read_ident(source, after_kw)
	if not macro_name then return end
	if not is_r_code_macro(macro_name) then return end

	-- Save the raw RHS (post-`=` text up to the line end) into the cross-source body table 
	-- FIRST so the chain walker can fall back to it when the defining `#define` lives in a different source.
	local rhs_pos  = duffle.skip_ws_and_cmt(source, macro_end)
	local rhs_end  = duffle.find_byte(source, BYTE_NEWLINE, rhs_pos) or (#source + 1)
	local rhs_text = duffle.trim(source:sub(rhs_pos, rhs_end - 1))
	if rhs_text ~= "" then
		code_macro_bodies[macro_name] = rhs_text
	end

	-- Resolve RHS via per-chain visited + depth-bounded recursion.
	local visited = { [macro_name] = true }
	local value   = resolve_code_macro_value(source, rhs_pos, code_macros, code_macro_bodies, visited, 1)
	if value ~= nil then code_macros[macro_name] = value end
end

-- Quick pre-pass: walk the source looking ONLY for `#define R_*_Code` lines.
-- Populates `code_macros` with resolved integer codes AND `code_macro_bodies` with raw RHS text
-- (used by the chain walker as cross-source fallback during pass 1b in `M.run`); ignores everything else.
-- Used by `M.run` pass 1a to build the cross-source `_code_macros` + `_code_macro_bodies` registries before pass 1b resolves chains.
-- @param source string
-- @param code_macros table
-- @param code_macro_bodies table
local function scan_source_pre_pass(source, code_macros, code_macro_bodies)
	local pos     = 1
	local src_len = #source
	while pos <= src_len do
		pos = duffle.skip_ws_and_cmt(source, pos)
		if pos > src_len then break end
		if source:byte(pos) == BYTE_HASH then
			local pp_pos = duffle.skip_preprocessor_line(source, pos)
			if pp_pos then
				try_extract_code_macro(source, pos, code_macros, code_macro_bodies)
				pos = pp_pos
			else
				pos = pos + 1
			end
		else
			pos = pos + 1
		end
	end
end

-- Check whether `atom_reg` appears as a BARE token at byte position `pos`.
-- `pos` should be at the first non-whitespace byte after the value position
-- (caller is responsible for skipping whitespace before calling).
-- Returns (true, end_pos) iff the identifier at `pos` is exactly `atom_reg` AND the byte immediately before `pos` is a non-word char
-- (whitespace, `,`, `=`, `{`, `}`, `(`, `)`, `[`, `]`, etc.) AND the byte immediately after the ident is a non-word char or end-of-input.
-- Returns (false, pos) otherwise.
local function check_bare_atom_reg(body, pos)
	if pos > #body then return false, pos end

	local ident, ident_end = duffle.read_ident(body, pos)
	if ident ~= "atom_reg" then return false, pos end

	-- Word-boundary check on the LEFT side: the byte at `pos - 1` must NOT be an alphanumeric/underscore byte (otherwise `atom_reg` is a suffix of `_not_atom_reg` or similar).
	if pos > 1 then
		local prev = body:byte(pos - 1)
		if duffle.is_alnum_byte(prev) then return false, pos end
	end

	-- Word-boundary check on the RIGHT side: the byte at `ident_end` must NOT be an alphanumeric/underscore byte (otherwise `atom_reg` is a prefix of a longer identifier).
	if ident_end <= #body then
		local nxt = body:byte(ident_end)
		if duffle.is_alnum_byte(nxt) then return false, pos end
	end

	return true, ident_end
end

-- Parse the type chain in an enum-site `atom_type(<T>)` call following the bare `atom_reg` token.
-- Returns (type_name, depth, after_pos) on success or (nil, 0, pos) on any malformed input
-- (silent; the alias is still emitted with `has_atom_reg = true` but without a default typed view).
-- Caller has already advanced past `atom_reg` and skipped whitespace.
local function parse_enum_atom_type_default(body, pos)
	if pos > #body then return nil, 0, pos end
	-- Bare `atom_type` word with word-bounding on both sides.
	local ident, ident_end = duffle.read_ident(body, pos)
	if ident ~= "atom_type" then return nil, 0, pos end
	if pos > 1 then
		local prev = body:byte(pos - 1)
		if duffle.is_alnum_byte(prev) then return nil, 0, pos end
	end
	if ident_end <= #body then
		local nxt = body:byte(ident_end)
		if duffle.is_alnum_byte(nxt) then return nil, 0, pos end
	end
	-- Expect `( ... )` immediately after.
	local open_pos = duffle.skip_ws_and_cmt(body, ident_end)
	if open_pos > #body or body:sub(open_pos, open_pos) ~= "(" then return nil, 0, pos end
	local inner, after_close = duffle.read_parens(body, open_pos)
	-- Reject any trailing tokens past the close paren other than comma / close-brace (next enum entry / end of enum).
	local residue = duffle.skip_ws_and_cmt(body, after_close)
	if residue <= #body then
		local rbyte = body:byte(residue)
		if rbyte ~= BYTE_COMMA and rbyte ~= BYTE_CLOSE_BRACE then return nil, 0, pos end
	end
	-- Parse the type chain inside the parens (e.g. `V4_S2*` -> ("V4_S2", 1)).
	local type_name, depth, after_chain = parse_type_chain(inner, 1)
	if not type_name then return nil, 0, pos end
	local end_check = duffle.skip_ws_and_cmt(inner, after_chain)
	if end_check <= #inner then return nil, 0, pos end
	return type_name, depth, duffle.skip_ws_and_cmt(body, after_close)
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
-- No regex per the no_regex constraint; no hand-rolled depth tracking
-- (the MipsAtomComp_Proc_ brace matcher now uses duffle.read_braces instead of bespoke byte-dispatch).
--
-- Adding a new construct = 1 row in DECL_PARSERS + 1 parser function. The scan_source() loop never needs editing.

--- Parse an empty debug-skip marker and retain its raw placement evidence.
--- The marker_kind is the source ident itself (e.g. `atom_dbg_skip_over`).
--- The dispatch table maps each ident to this same function;
--- the marker_kind is derived from the source so future idents route through the same row.
--- @param source string
--- @param pos integer
--- @param ident_end integer
--- @param line_of fun(pos: integer): integer
--- @param out SourceScan
--- @return integer
local function parse_skip_over_marker(source, pos, ident_end, line_of, out)
	local open_paren = duffle.skip_ws_and_cmt(source, ident_end)
	local marker = {
		marker_kind  = source:sub(pos, ident_end - 1),
		marker_line  = line_of(pos),
		marker_pos   = pos,
		after_paren  = ident_end,
		args         = nil,
		has_parens   = false,
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

-- Parse `atom_dbg_reg_default(R_X, <type>...)`;
-- the second argument may be a `Type` or `Type*`/`Type**` chain. Records in `out.types[R_X]`.
local function parse_atom_dbg_reg_default(source, pos, ident_end, line_of, out)
	local inner, after_paren = read_parens_after(source, ident_end)
	if not inner then return after_paren end
	local args = duffle.split_top_level_commas(inner)
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
		reg         = reg_name,
		type_name   = type_name,
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
	local inner, after_paren, open_paren = read_parens_after(source, ident_end)
	if not inner then return after_paren end

	local raw_name = duffle.read_ident(inner, 1)

	-- Lookahead for atom_info(...) between `)` and `{`. Captures sub-calls; updates brace search start.
	local brace_search_pos = after_paren
	local lookahead        = duffle.skip_ws_and_cmt(source, after_paren)
	local look_ident, look_end = duffle.read_ident(source, lookahead)
	if look_ident == "atom_info" then
		local info_open = duffle.skip_ws_and_cmt(source, look_end)
		if source:sub(info_open, info_open) == "(" then
			local info_inner, info_after = duffle.read_parens(source, info_open)
			-- info_line feeds the per-atom reg_type_overrides table.
			local info_line = line_of(info_open)
			local ai_binds, ai_reads, ai_writes, ai_view, ai_overrides, ai_ctx, ai_phase = scan_atom_info_subcalls(info_inner, info_line)
			out.atom_infos[#out.atom_infos + 1] = {
				atom_name = raw_name or "?", binds = ai_binds,
				reads     = ai_reads or {}, writes = ai_writes or {},
				view      = ai_view,
				reg_type_overrides = ai_overrides,
				ctx_atom  = ai_ctx,
				phase     = ai_phase,
				info_line = line_of(lookahead),
			}
			if ai_view and raw_name then
				out.atom_views[raw_name] = {
					atom_name          = raw_name,
					binds_name         = ai_view,
					reg_type_overrides = ai_overrides,
					info_line          = line_of(lookahead),
				}
			elseif raw_name and ai_overrides then
				-- Record per-atom overrides even without atom_view.
				out.atom_views[raw_name] = out.atom_views[raw_name] or { atom_name = raw_name, binds_name = nil, reg_type_overrides = nil, info_line = line_of(lookahead) }
				out.atom_views[raw_name].reg_type_overrides = ai_overrides
			end
			-- Project the per-atom atom_ctx / atom_phase declarations onto the global phase index.
			if raw_name then
				if ai_ctx then
					out.atom_ctxs = out.atom_ctxs or {}
					out.atom_ctxs[raw_name] = { rbind_atom = ai_ctx, info_line = line_of(lookahead), source = source }
				end
				if ai_phase then
					out.atom_phases = out.atom_phases or {}
					out.atom_phases[ai_phase] = out.atom_phases[ai_phase] or { atoms = {} }
					out.atom_phases[ai_phase].atoms[#out.atom_phases[ai_phase].atoms + 1] = raw_name
				end
			end
			brace_search_pos = info_after
		end
	end

	local body, after_brace, body_off = find_body_braces(source, brace_search_pos, open_paren + 1)
	if not body then return after_brace end
	if raw_name and raw_name ~= "" then
		register_atom(out, "atom", line_of(pos), raw_name, body, body_off, raw_name, pos, after_paren)
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
	local inner, after_paren, open_paren = read_parens_after(source, ident_end)
	if not inner then return after_paren end

	local  raw_name = duffle.read_ident(inner, 1)
	if not raw_name then return open_paren + 1 end

	local body, after_brace, body_off = find_body_braces(source, after_paren, open_paren + 1)
	if not body then return after_brace end
	local name = strip_ac_prefix(raw_name)
	register_atom(out, "comp_bare", line_of(pos), name, body, body_off, raw_name, pos, after_paren)

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
	local inner, after_paren, open_paren = read_parens_after(source, ident_end)
	if not inner then return after_paren end

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
	-- Position of body[1] in source = open_paren + 1 (start of inner) + last_brace_pos + 1 (past '{').
	local body_off = open_paren + 2 + last_brace_pos

	register_atom(out, "comp_proc", line_of(pos), name, body, body_off, raw_name, pos, after_paren)

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
	local  next_pos               = duffle.skip_ws_and_cmt(source, ident_end)
	local  next_ident, next_after = duffle.read_ident(source, next_pos)
	if not next_ident or #next_ident <= 5 or next_ident:sub(1, 5) ~= "code_" then
		return ident_end
	end

	local  atom_name = next_ident:sub(6)
	local body, after_brace, body_off = find_body_braces(source, next_after, ident_end)
	if not body then return after_brace end
	register_raw_atom(out, line_of(pos), atom_name, body, body_off, atom_name, pos, "unrelated")

	return after_brace
end

--- Register a Struct_ entry in type_name_registry.
--- Local helper for parse_typedef_binds. Populates the registry with
---   { 
--- 		name          = name, 
--- 		kind          = "struct",
--- 		fields        = [...],
--- 		body          = body,
---     source_line   = line,
--- 		source_file   = source_path,
---     pointer_depth = 0 
--- 	} -- byte_size + per-field offset/byte_size set by the propagation pass.
--- Also populates `out.binds[]` IFF `name:sub(1, 6) == "Binds_"`.
--- @param body string
--- @param name string
--- @param pos integer
--- @param line_of fun(pos: integer): integer
--- @param out SourceScan
local function register_struct_type(body, name, pos, line_of, out)
	local fields = parse_struct_body_fields(body)
	local source_pos = line_of(pos)
	out.type_name_registry[name] = {
		name          = name,
		kind          = "struct",
		fields        = fields,
		body          = body,
		source_line   = source_pos,
		source_file   = out._source_file,
		pointer_depth = 0,
		byte_size     = nil,    -- set by propagation pass
	}
	if name:sub(1, 6) == "Binds_" then
		out.binds[#out.binds + 1] = {
			line   = source_pos,
			name   = name,
			fields = fields,
			body   = body,
			bytes  = nil,    -- set by propagation pass
		}
	end
end

--- Register an Enum_ entry in type_name_registry.
--- Local helper for parse_typedef_binds. Captures the underlying type (1st arg of `Enum_(<underlying>, <name>)`) and the body fields.
--- @param underlying string
--- @param name string
--- @param body string
--- @param pos integer
--- @param line_of fun(pos: integer): integer
--- @param out SourceScan
local function register_enum_type(underlying, name, body, pos, line_of, out)
	local fields = parse_enum_body_fields(body)
	out.type_name_registry[name] = {
		name            = name,
		kind            = "enum",
		underlying_type = underlying,
		fields          = fields,
		body            = body,
		source_line     = line_of(pos),
		source_file     = out._source_file,
		pointer_depth   = 0,
	}
end

--- Register a simple typedef / TSet_ alias in type_name_registry.
--- Captures the underlying type ident (LHS of `typedef <type> <alias>;`) and exposes it through the registry.
--- The propagation pass follows the underlying_type chain to resolve byte_size.
--- @param underlying string
--- @param name string
--- @param pos integer
--- @param line_of fun(pos: integer): integer
--- @param out SourceScan
local function register_typedef_alias(underlying, name, pos, line_of, out)
	out.type_name_registry[name] = {
		name           = name,
		kind           = "typedef",
		underlying_type = underlying,
		source_line    = line_of(pos),
		source_file    = out._source_file,
		pointer_depth  = 0,
	}
end

--- Parse: `typedef` declarations.
---
--- Recognizes four shapes:
---   1. `typedef Struct_(<name>) { <body> } <alias>;` adds to type_name_registry (kind="struct"). 
---       Binds_* aliases also land in out.binds[].
---   2. `typedef Enum_(<underlying>, <name>) { <body> } <alias>;` 
---       adds to type_name_registry (kind="enum"). 
---   3. `typedef <type> <alias>;` simple typedef alias.
---       Adds to type_name_registry (kind="typedef").
---   4. `typedef <type> TSet_(<name>);` duffle TSet_ convention.
---       Strips TSet_ wrapper; adds to type_name_registry (kind="typedef") with underlying_type=<type>.
---
--- All four shapes also associate an "unrelated" skip-over marker (the existing behavior — typedef declarations don't carry atom_dbg_skip_over).
--- @param source string
--- @param pos integer
--- @param ident_end integer
--- @param line_of fun(pos: integer): integer
--- @param out SourceScan
--- @return integer
local function parse_typedef_binds(source, pos, ident_end, line_of, out)
	local after_typedef = duffle.skip_ws_and_cmt(source, ident_end)
	local id2, id2_end  = duffle.read_ident(source, after_typedef)
	if not id2 then return ident_end end

	-- ── Shape 1: `typedef Struct_(<name>) { <body> } <alias>;` ────────────
	if id2 == "Struct_" then
		local inner, after_paren, open_paren = read_parens_after(source, id2_end, id2_end)
		if not inner then return id2_end end
		local name               = duffle.trim(inner)

		local body, after_brace = find_body_braces(source, after_paren, open_paren + 1)
		if not body then return after_brace end
		register_struct_type(body, name, pos, line_of, out)
		associate_skip_over_marker(out, name, name, "unrelated", line_of(pos), pos)
		return after_brace
	end

	-- ── Shape 2: `typedef Enum_(<underlying>, <name>) { <body> } <alias>;`
	if id2 == "Enum_" then
		local inner, after_paren, open_paren = read_parens_after(source, id2_end, id2_end)
		if not inner then return id2_end end
		-- Split `inner` on the first top-level comma into (<underlying>, <name>).
		local args = duffle.split_top_level_commas(inner)
		if   #args < 2 then return after_paren end
		local underlying = duffle.trim(args[1])
		local name       = duffle.trim(args[2])

		local body, after_brace = find_body_braces(source, after_paren, open_paren + 1)
		if not body then return after_brace end
		register_enum_type(underlying, name, body, pos, line_of, out)
		associate_skip_over_marker(out, name, name, "unrelated", line_of(pos), pos)
		return after_brace
	end

	-- ── Shapes 3 + 4: `typedef <type> <alias>;`  or
	--                  `typedef <type> TSet_(<name>);`
	-- Read the <type> ident we already have (id2) and the trailing alias.
	local after_id2 = duffle.skip_ws_and_cmt(source, id2_end)
	local id3, id3_end = duffle.read_ident(source, after_id2)
	if not id3 then return ident_end end

	-- Shape 4: `typedef <type> TSet_(<name>);`
	if id3 == "TSet_" then
		local tset_inner, tset_after = read_parens_after(source, id3_end, id3_end)
		if not tset_inner then return id3_end end
		local tset_name = duffle.trim(tset_inner)
		register_typedef_alias(id2, tset_name, pos, line_of, out)
		associate_skip_over_marker(out, tset_name, tset_name, "unrelated", line_of(pos), pos)
		return tset_after
	end

	-- Shape 3: `typedef <type> <alias>;`
	register_typedef_alias(id2, id3, pos, line_of, out)
	associate_skip_over_marker(out, id3, id3, "unrelated", line_of(pos), pos)
	return id3_end
end

--- Parse: `_Pragma("mac_X tape_atom words=N")` (operator form).
--- @param source string
--- @param pos integer
--- @param ident_end integer
--- @param line_of fun(pos: integer): integer
--- @param out SourceScan
--- @return integer
local function parse_pragma_macro(source, pos, ident_end, line_of, out)
	local str, str_end = read_parens_after(source, ident_end)
	if not str then return str_end end
	str = duffle.trim(str)
	if str:sub(1, 1) ~= '"' or str:sub(-1) ~= '"' then return str_end end

	local  inner = str:sub(2, -2)
	local  space = duffle.find_byte(inner, 32, 1)
	if not space then return str_end end

	local  name = inner:sub(1, space - 1)
	local  rest = inner:sub(space + 1)
	local  eq   = duffle.find_byte(rest, 61, 1)
	if not eq then return str_end end

	local key = duffle.trim(rest:sub(1, eq - 1))
	local val = duffle.trim(rest:sub(eq + 1))
	if    key == "tape_atom words" or key == "words" then
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

-- Parse the value side of an enum entry.
-- Accepts integer literals (decimal/negative/hex), `R_*_Code` symbol references resolved via `out._code_macros`,
-- AND bare `R_*` symbols that map to an `R_*_Code` variant in the registry.
-- The bare-`R_*` fallback is needed for the lottes_tape.h wave-context aliases whose enum RHS is the bare register ident (e.g. `R_TapePtr = R_T8 atom_reg`);
-- the `R_*_Code` form (e.g. `R_T8_Code`) holds the actual GPR code in mips.h and is now resolvable cross-source via the chain walker.
-- Returns (value, end_pos) on success or (nil, pos) if unresolvable.
local function parse_enum_value(body, pos, out)
	local int_val, int_end = parse_enum_int_literal(body, pos)
	if int_val ~= nil then return int_val, int_end end

	local sym = duffle.read_ident(body, pos)
	if not sym then return nil, pos end

	-- Bare `R_*` (no `_Code` suffix) → translate to `R_*_Code` and look that up. Non-`R_*` symbols
	-- (plain idents without the prefix) are not value sources and fall through to the nil return.
	local lookup_sym = sym
	if not is_r_code_macro(sym)
		and sym:byte(1) == BYTE_R
		and sym:byte(2) == BYTE_UNDERSCORE then
		lookup_sym = sym .. "_Code"
	end

	-- visited starts empty; lookup_code_value marks visited[sym] = true on its first cycle-guard check,
	-- so pre-marking here would falsely trigger the cycle short-circuit and return nil.
	local value = lookup_code_value(lookup_sym, out._code_macros, out._code_macro_bodies, {}, 1)
	if value ~= nil then return value, (pos + #sym) end

	return nil, pos
end

-- Walk one enum entry: read value, check for bare `atom_reg`, and
-- (if both are present and the name starts with `R_`) write an AliasEntry into `out.register_alias_registry`.
-- If `atom_reg` is followed by an adjacent `atom_type(<T>)`, the parsed T is stored on the AliasEntry
-- as `default_type` (type_name + pointer_depth). Silent if `atom_type(...)` is malformed.
-- Returns the new byte position within `body` (advanced past `atom_type(...)` if well-formed, past `atom_reg` alone, or past the value if neither was present).
local function parse_enum_entry(source, body, body_offset, line_of, out, entry_name, name_body_pos, value_start)
	-- value_start is within `body`, just past the `=`.
	local after_ws = duffle.skip_ws_and_cmt(body, value_start)
	local value, value_end = parse_enum_value(body, after_ws, out)
	if value == nil then return value_start end

	local after_value       = duffle.skip_ws_and_cmt(body, value_end)
	local has_atom_reg, end_after_atom_reg = check_bare_atom_reg(body, after_value)

	-- Only register R_* entries whose value is followed by bare `atom_reg`.
	if has_atom_reg and entry_name:byte(1) == BYTE_R and entry_name:byte(2) == BYTE_UNDERSCORE then
		local entry_source_pos = body_offset + name_body_pos - 1
		local entry = {
			name          = entry_name,
			code          = value,
			source_line   = line_of(entry_source_pos),
			source_file   = source,
			pointer_depth = 0,
			has_atom_reg  = true,
		}
		-- Adjacent enum-site default view, if any. Tolerant of malformed `atom_type(...)`.
		local after_atom_reg = duffle.skip_ws_and_cmt(body, end_after_atom_reg)
		local dflt_type_name, dflt_depth, end_after_atom_type = parse_enum_atom_type_default(body, after_atom_reg)
		if dflt_type_name then
			entry.default_type  = dflt_type_name
			entry.default_depth = dflt_depth
			entry.pointer_depth = dflt_depth   -- override; this alias is a pointer-type alias by default
			out.register_alias_registry[entry_name] = entry
			return end_after_atom_type
		end
		out.register_alias_registry[entry_name] = entry
		return end_after_atom_reg
	end

	return has_atom_reg and end_after_atom_reg or value_end
end

-- Walk the body of an `enum { ... }` declaration. Each entry is comma-separated (mips.h style: leading commas allowed);
-- each entry optionally has the shape `NAME = VALUE atom_reg`.
-- Inline `#define` directives inside the body (lottes_tape.h style) are skipped past the newline.
local function parse_enum_body(source, body, body_offset, line_of, out)
	local pos      = 1
	local body_len = #body
	while pos <= body_len do
		pos = duffle.skip_ws_and_cmt(body, pos)
		if pos > body_len then break end

		local c = body:byte(pos)
		if c == BYTE_COMMA then
			-- Leading comma (mips.h style: `, rtmp_0 = R_T0,`).
			pos = pos + 1
		elseif c == BYTE_CLOSE_BRACE then
			break
		elseif c == BYTE_HASH then
			-- Inline `#define` inside the enum body (lottes_tape.h style).
			-- Skip past the newline; the main preprocessor intercept in scan_source has already resolved the `_Code` chain.
			local nl = duffle.find_byte(body, BYTE_NEWLINE, pos)
			if nl then pos = nl + 1 else pos = body_len + 1 end
		else
			local entry_name, name_end = duffle.read_ident(body, pos)
			if entry_name then
				local after_name = duffle.skip_ws_and_cmt(body, name_end)
				if body:byte(after_name) == BYTE_EQUAL then
					local new_pos = parse_enum_entry(
						source, body, body_offset, line_of, out,
						entry_name, pos, after_name + 1
					)
					if new_pos > pos then pos = new_pos else pos = after_name + 1 end
				else
					pos = name_end
				end
			else
				pos = pos + 1
			end
		end
	end
end

--- Parse: `enum [<tag>] { <body> }`. Walks the body and populates `out.register_alias_registry` with one entry per `R_* = <value> atom_reg` line.
--- @param source string
--- @param pos integer
--- @param ident_end integer
--- @param line_of fun(pos: integer): integer
--- @param out SourceScan
--- @return integer
local function parse_enum(source, pos, ident_end, line_of, out)
	-- pos points at the `e` of `enum`; ident_end points past `enum`.
	-- Optional enum tag (e.g. `enum Foo { ... }`): a single ident between `enum` and `{` that is not followed by `(`.
	local after_ident        = duffle.skip_ws_and_cmt(source, ident_end)
	local tag_ident, tag_end = duffle.read_ident(source, after_ident)
	if tag_ident and source:byte(tag_end) ~= 0x28 then  -- not '('
		after_ident = tag_end
	end

	-- Find the opening brace of the enum body.
	local body, after_brace, body_off = find_body_braces(source, after_ident, ident_end)
	if not body then return after_brace end
	parse_enum_body(source, body, body_off, line_of, out)

	return after_brace
end

-- ════════════════════════════════════════════════════════════════════════════
-- DECL_PARSERS — data-driven construct dispatch (the plex pattern)
-- ════════════════════════════════════════════════════════════════════════════
-- Each entry maps a leading ident to its parser function. The main scan_source() loop is one line of dispatch:
--   local parser = DECL_PARSERS[ident]; if parser then pos = parser(...) end
--
-- Adding a new construct = 1 row here + 1 parser function above.

local DECL_PARSERS = {
	MipsAtom_                  = parse_mips_atom,
	MipsAtomComp_              = parse_mips_atom_comp,
	MipsAtomComp_Proc_         = parse_mips_atom_comp_proc,
	atom_dbg_skip_over         = parse_skip_over_marker,
	atom_dbg_reg_default       = parse_atom_dbg_reg_default,
	MipsCode                   = parse_mips_code,
	typedef                    = parse_typedef_binds,
	_Pragma                    = parse_pragma_macro,
	pragma                     = parse_pragma_dummy,
	-- Track A: `enum [<tag>] { <body> }` populates `out.register_alias_registry`.
	enum                       = parse_enum,
}

-- ════════════════════════════════════════════════════════════════════════════
-- The single source walker
-- ════════════════════════════════════════════════════════════════════════════

--- Single-pass source scan. Walks the source ONCE and extracts every construct type the metaprogram passes need.
--- Returns a fat SourceScan table. Each pass filters from this payload instead of re-walking the source.
--- @param source string
--- @param source_file string|nil       -- absolute source path (forwarded into AliasEntry.source_file)
--- @param code_macros table|nil        -- cross-source `R_*_Code` registry; nil = local-only
--- @param code_macro_bodies table|nil  -- cross-source raw RHS body table; nil = local-only
--- @return table  -- SourceScan { atoms, raw_atoms, binds, atom_infos, macros, skip_over, line_of, register_alias_registry, _code_macros, _code_macro_bodies }
local function scan_source(source, source_file, code_macros, code_macro_bodies)
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
		-- Track A: source-derived register-alias registry (atom_reg opt-in entries).
		-- Keys are full R_* idents (never stripped); see parse_enum / parse_enum_body.
		register_alias_registry = {},
		-- Track A: source-derived type-name registry. 
		-- Populated from `typedef Struct_(...)`, `typedef Enum_(...)`, `typedef <type> <alias>`, and `typedef <type> TSet_(<name>)` declarations. 
		-- The propagation pass at the end of `scan_source()` resolves byte_size via the builtin map, 
		-- typedef chain walking (cycle-guarded, depth <= 8), and struct field sums.
		-- See `propagate_type_sizes()` below.
		type_name_registry = {},
		-- Track A: shared `R_*_Code -> integer code` registry 
		-- (passed in from M.run pass 1; same reference so preprocessor intercept writes are visible to the enum-value resolver).
		-- Stripped from `src.scan` before return.
		_code_macros       = code_macros or {},
		-- Track A: shared raw RHS body table (passed in from M.run pass 1a;
		-- same reference so preprocessor intercept writes are visible to the cross-source chain walker in resolve_code_macro_value).
		-- Stripped from `src.scan` before return.
		_code_macro_bodies = code_macro_bodies or {},
		_source_file       = source_file,
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
			-- Track A intercept: resolve `#define R_*_Code <int-or-symbol>`
			-- into the shared `_code_macros` registry before skipping the line.
			try_extract_code_macro(source, pos, out._code_macros, out._code_macro_bodies)
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
						-- A component-procedure declaration has an FI_ signature before MipsAtomComp_Proc_;
						-- keep the marker pending across that prelude. 
						-- Any other identifier begins an unrelated declaration/construct and consumes the marker so it cannot drift to a later atom.
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

	-- Propagate byte_size through the type-name registry.
	-- Runs AFTER the source walk so all typedef / Struct_ / Enum_ declarations have been parsed into `out.type_name_registry`.
	-- Mutates each entry's `byte_size` field in place; fields with pointer_depth > 0 already carry byte_size = 4 from parse time and are unaffected.
	propagate_type_sizes(out)

	return out
end

-- ════════════════════════════════════════════════════════════════════════════
-- M — module exports
-- ════════════════════════════════════════════════════════════════════════════

--- @class M

local M = {}

--- Walk each source once and attach the fat SourceScan payload to `src.scan`.
--- No output files; this is a pure in-memory pre-processing pass.
---
--- Runs in 3 phases.
---   Pass 1a: `scan_source_pre_pass` over every source, populating the cross-source `ctx.shared._code_macros` AND `ctx.shared._code_macro_bodies` registries.
---             The bodies table holds the raw post-`=` text of every `#define R_*_Code` line (cross-source) so the chain walker can fall back when a 
---             sdefining `#define` lives in a different source than the chain call site.
---   Pass 1b:  Resolve every collected macro's chain using the bodies table as fallback.
---             This fills in `code_macros` entries whose defining source was scanned AFTER the call site 
---             (e.g. lottes_tape.h's `R_TapePtr_Code -> R_T8_Code` chain into mips.h's `R_T8_Code = 24`).
---   Pass 2:   The full `scan_source(source, source_file, code_macros, code_macro_bodies)` walk, which feeds `out._code_macros = ctx.shared._code_macros`
---             (and `out._code_macro_bodies = ctx.shared._code_macro_bodies`)
---             so the enum parser can resolve cross-source `R_*_Code` references and bare `R_*` symbols via the `_Code` registry fallback.
---   Strip:    `src.scan._code_macros` AND `src.scan._code_macro_bodies` are nilled before returning so downstream passes 
---             (annotation, components, offsets, dwarf_injection, etc.) don't see the private parse state.
--- @param ctx PassCtx
--- @return PassResult
function M.run(ctx)
	-- Initialize the cross-source code-macro + body registries in ctx.shared.
	-- (Pass 1a writes into both; pass 1b reads from both; pass 2 reads both.)
	ctx.shared                       = ctx.shared or {}
	ctx.shared._code_macros          = ctx.shared._code_macros or {}
	ctx.shared._code_macro_bodies    = ctx.shared._code_macro_bodies or {}
	local code_macros                = ctx.shared._code_macros
	local code_macro_bodies          = ctx.shared._code_macro_bodies

	-- Pass 1a: collect `_code_macros` + `_code_macro_bodies` across ALL sources.
	for _, src in ipairs(ctx.sources) do
		scan_source_pre_pass(src.text, code_macros, code_macro_bodies)
	end

	-- Pass 1b: resolve every collected macro's chain with cross-source fallback.
	-- The bodies table was populated for every `#define R_*_Code` line in pass 1a;
	-- this iteration finishes the chain even when the chain hops span sources
	-- (e.g. R_TapePtr_Code -> R_T8_Code -> 24 spans lottes_tape.h into mips.h).
	-- Same `code_macros` table is shared with pass 2 below.
	for macro_name, _ in pairs(code_macro_bodies) do
		if code_macros[macro_name] == nil then
			local body    = code_macro_bodies[macro_name]
			local visited = { [macro_name] = true }
			local value   = resolve_code_macro_value(body, 1, code_macros, code_macro_bodies, visited, 1)
			if value ~= nil then code_macros[macro_name] = value end
		end
	end

	-- Pass 2: run the full scan with the shared `_code_macros` + `_code_macro_bodies` 
	-- so the enum parser can resolve cross-source `R_*_Code` references and bare `R_*` symbols via the `_Code` registry fallback.
	for _, src in ipairs(ctx.sources) do
		src.scan = scan_source(src.text, src.path, code_macros, code_macro_bodies)
		-- Pre-tokenize each atom body once (plex: single source of truth).
		-- Downstream passes (offsets, word-counts, components, static-analysis) read from
		-- `atom.body_tokens` instead of calling `split_top_level_commas` / `tokenize_body` independently.
		-- The tokens are memoized in duffle.lua's cache, so re-access is O(1).
		for _, atom in ipairs(src.scan.atoms)           do atom.body_tokens = duffle.tokenize_body(atom.body) end
		for _, atom in ipairs(src.scan.raw_atoms or {}) do atom.body_tokens = duffle.tokenize_body(atom.body) end
	end

	-- Strip `_code_macros` + `_code_macro_bodies` (and the convenience `_source_file` pointer)
	-- before returning so downstream passes don't see private parse state.
	for _, src in ipairs(ctx.sources) do
		if src.scan then
			src.scan._code_macros       = nil
			src.scan._code_macro_bodies = nil
			src.scan._source_file       = nil
		end
	end

	return { outputs = {}, errors = {}, warnings = {} }
end

return M
