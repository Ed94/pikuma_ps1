--- passes/scan_source.lua — Source pre-scan pass (the "mega entity" pass).
---
--- Single source-walk pass that produces the fat `SourceScan` payload consumed by all downstream passes. Walks each corpus source record once,
--- extracting every construct type the metaprograms need:
---   MipsAtom_              (kind = "atom", with optional atom_info inner)
---   MipsAtom_Proc_         (kind = "atom_proc", body inside last {})
---   MipsAtomComp_          (kind = "comp_bare")
---   MipsAtomComp_Proc_     (kind = "comp_proc", body inside last {})
---   MipsAtomComp_ProcMap_  (kind = "comp_proc", body is the one command)
---   atom_dbg_skip          — bare whole-atom/component debug-step marker; following declaration disambiguates
---   MipsCode code_<name>   (kind = "raw_atom", offsets pass only)
---   typedef Struct_(Binds_X) { fields }
---   #pragma mac_X tape_atom words=N   +   _Pragma("...")
---
--- The result is attached to each `src.scan` so downstream passes can read from `src.scan.atoms` / `src.scan.binds` / etc. without re-walking the source.
--- This is the first pass in the dep graph (no deps).
--- Every other pass that reads source structure depends on this one — see `ps1_meta.lua :: PASSES`.

-- Bootstrap: same as entry scripts. See `ps1_meta.lua` for the rationale.
-- Bootstrap: load `scripts/duffle_paths.lua` (sets package.path + package.cpath).
-- Uses `debug.getinfo` to find this file's own directory, so it works both standalone and when require'd from the orchestrator.
-- Bootstrap: load `duffle_paths.lua` via `debug.getinfo(1, "S").source` (works both standalone + when required).
-- duffle_paths.lua sets package.path then returns `require("duffle")` at the bottom, so the dofile value IS the duffle module.
local _bootstrap_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local duffle         = dofile(_bootstrap_dir .. "../duffle_paths.lua")

-- Forward declarations for helpers used by earlier parsers (parse_enum_body_fields needs parse_enum_int_literal;
-- parse_typedef_binds needs duffle.find_byte).
-- Lua local scoping rules require explicit forward declarations because locals are visible only AFTER their declaration site.
-- The actual assignments happen later in this file;
-- the closures captured by the early parsers resolve the upvalue at call time (Lua 5.3 / LuaJIT upvalue semantics).
local parse_enum_int_literal

-- ════════════════════════════════════════════════════════════════════════════
-- Type declarations
-- ════════════════════════════════════════════════════════════════════════════

--- @class SourceScan
--- @field atoms             AtomEntry[]     -- MipsAtom_ + MipsAtom_Proc_ + MipsAtomComp_ + MipsAtomComp_Proc_
--- @field raw_atoms         AtomEntry[]     -- MipsCode code_<name> { body } (offsets pass only)
--- @field binds             BindsEntry[]    -- typedef Struct_(Binds_X) { fields } (fields pre-parsed)
--- @field atom_infos        AtomInfoEntry[] -- MipsAtom_(name) atom_info(...) (sub-calls pre-parsed)
--- @field macros            MacroEntry[]    -- #pragma mac_X tape_atom words=N  +   _Pragma("...")
--- @field debug_skip_markers DebugSkipMarker[] -- raw marker evidence for annotation validation; `debug_skip` lives on the declaration record itself
--- @field types             table<string, RegTypeDefault>    -- atom_dbg_reg_default(R_X, <type>) declarations
--- @field atom_views        table<string, AtomViewEntry>     -- MipsAtom_(name) -> {binds_name, reg_type_overrides, info_line}
--- @field atom_ctxs         table<string, AtomCtxEntry>      -- MipsAtom_(name) -> {rbind_atom, info_line, source} (atom_ctx(...) call sites)
--- @field atom_phases       table<string, AtomPhaseGroup>    -- phase_label -> {atoms = {atom_name1, atom_name2, ...}} (atom_phase(...) tags)
--- @field line_of           fun(pos: integer): integer       -- shared LineIndex closure

--- @class DebugSkipMarker
--- @field marker_kind    string      -- Exact marker ident read from source. Only "atom_dbg_skip" (bare) is positive; any other ident reaches the unrelated fallback and is never associated with a declaration.
--- @field marker_line    integer     -- Line of the marker ident start
--- @field marker_pos     integer     -- Byte position of the marker ident start (the comment walker anchors here)
--- @field is_bare        boolean     -- true iff marker_kind == "atom_dbg_skip" AND has_parens == false (the only positive form)
--- @field has_parens     boolean     -- true iff a `(...)` follows the marker ident (diagnostic-only)
--- @field args           string|nil  -- Trimmed args inside the `(...)` (nil when has_parens is false)
--- @field pending        boolean     -- true while awaiting the following declaration
--- @field superseded_by_marker_line integer|nil -- set when a newer marker bumped this one out of the pending slot
--- @field target_kind    string|nil  -- "atom" | "atom_proc" | "comp_bare" | "comp_proc" | "unrelated" once observed (nil if no declaration ever followed)
--- @field proc_prelude   boolean|nil -- true after the marker crossed an `FI_` prelude and awaits `MipsAtomComp_Proc_`

--- @class RegTypeDefault
--- @field name          string  -- "R_TapePtr" (the register ident; without the value part)
--- @field type_name     string  -- "U4" / "V3_S2" / "void" (the pointer/struct base name)
--- @field pointer_depth integer -- 0 for `U4`, 1 for `U4*`, 2 for `U4**`
--- @field source_line   integer -- 1-based source line of the declaration

--- @class RegTypeOverride
--- @field reg           string  -- "R_T0"
--- @field type_name     string
--- @field pointer_depth integer
--- @field source_line   integer -- Line of the call site (callsite or enum-site)

--- @class AtomCtxEntry
--- @field rbind_atom string  -- The rbind atom ident that this consumer should propagate types from
--- @field info_line  integer
--- @field source     string  -- Absolute path of the source file

--- @class AtomPhaseGroup
--- @field atoms string[]  -- Atom names tagged with this phase label (source-order)

--- @class AtomViewEntry
--- @field atom_name        string                 -- e.g. "red_cube_g4_face"
--- @field binds_name       string|nil             -- "Binds_CubeTri" if attached
--- @field reg_type_overrides table<string, RegTypeOverride> -- "R_T0" -> override
--- @field info_line        integer                -- line of the atom_info call

--- @class SourceFile
--- @field path     string  -- Absolute path to the source file
--- @field text     string  -- Full source text
--- @field dir      string  -- Directory containing the source
--- @field basename string  -- Filename without extension
--- @field scan     table   -- Pre-scanned SourceScan payload (set by this pass)

--- @class PassCtx
--- @field sources            SourceFile[]
--- @field metadata_path      string
--- @field shared             table
--- @field out_root           string
--- @field project_root       string
--- @field upstream           table<string, table>
--- @field flags              table
--- @field verbose            boolean

--- @class PassResult
--- @field outputs  table[]
--- @field errors   table[]
--- @field warnings table[]

--- @class AtomEntry
--- @field line              integer
--- @field name              string       -- Atom name (for components: without ac_ prefix)
--- @field body              string       -- Brace-delimited body (without the braces)
--- @field body_off          integer      -- Char offset of body[1] in source
--- @field kind              string       -- "atom" | "atom_proc" | "comp_bare" | "comp_proc" | "raw_atom"
--- @field raw_name          string       -- Un-stripped name (for components: with ac_ prefix)
--- @field ident_pos         integer      -- Position of the MipsAtom_/MipsAtomComp_ ident start
--- @field after_paren       integer      -- Position past the closing paren
--- @field debug_skip        boolean      -- true when an `atom_dbg_skip` bare marker immediately precedes this declaration (sole-owner stamp; see push_debug_skip_marker)
--- @field declaration_comment string|nil -- Populated by the scanner (backward walk past the marker, captures contiguous `/* */` or `//` block)

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

-- The function-decl keyword that precedes a MipsAtomComp_Proc_ call.
-- Used by the backward walk in duffle.find_function_decl_for.
local SLICE_MIPS_CODE    = "Slice_MipsCode"
local SLICE_MIPS_CODE_LEN = #SLICE_MIPS_CODE

-- The return type that precedes a MipsAtom_Proc_ function declaration.
-- Used by the backward walk in duffle.find_atom_proc_decl_for.
local MIPS_ATOM_PTR    = "MipsAtom*"
local MIPS_ATOM_PTR_LEN = #MIPS_ATOM_PTR

--- Strip the "ac_" prefix from a component name.
--- Returns the input unchanged if it doesn't start with the prefix.
--- @param raw_name string
--- @return string
local function strip_ac_prefix(raw_name)
	if #raw_name > AC_PREFIX_LEN and raw_name:sub(1, AC_PREFIX_LEN) == AC_PREFIX then
		return raw_name:sub(AC_PREFIX_LEN + 1)
	end
	return raw_name
end

-- Preserve a source marker until the following declaration parser observes it.
-- The scanner is the sole owner of marker recognition, placement association, declaration comment attachment, and canonical `debug_skip` fields.
-- Raw marker evidence lives in `out.debug_skip_markers` for annotation validation; the declaration record carries the resolved `debug_skip` boolean directly.
local function push_debug_skip_marker(out, marker)
	local markers = out.debug_skip_markers
	local prior   = markers[#markers]
	if    prior and prior.pending then
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
	local  brace = duffle.scan_to_char(source, "{", after_paren)
	if not brace then return nil, fallback or (after_paren + 1) end
	local body, after_brace = duffle.read_braces(source, brace)
	return body, after_brace, brace + 1
end

--- Walk backward from `start_pos` capturing contiguous `/* */` block(s) and
--- `//` line(s) that immediately precede it. The caller (preceding_declaration_comment)
--- supplies `start_pos` so the walker does not need to detect marker shape or prelude layout.
--- The scanner already knows the marker_pos + decl ident_pos and threads that knowledge forward.
---
--- The walker captures:
---   - Block comment close `*/` followed by walking back to `/*`.
---   - `//` line comments (the line containing the current non-ws position starts with `//`).
--- It stops at the first non-ws char that does not begin a comment block or line.
--- Empty string if no comment is adjacent.
--- @param source    string
--- @param start_pos integer -- exclusive upper bound for the captured block
--- @return string
local function preceding_comment_walk_backward(source, start_pos)
	local pieces  = {}
	local scan_pos = start_pos
	while scan_pos > 0 do
		local non_ws = scan_pos - 1
		while non_ws > 0 do
			local ch = source:sub(non_ws, non_ws)
			if ch == " " or ch == "\t" or ch == "\n" or ch == "\r" then
				non_ws = non_ws - 1
			else
				break
			end
		end
		if non_ws == 0 then break end

		if non_ws >= 2 and source:sub(non_ws - 1, non_ws) == "*/" then
			-- Block comment close: walk back over `/*` candidates.
			local prefix  = source:sub(1, non_ws - 1)
			local open_at = nil
			for scan = #prefix - 1, 1, -1 do
				if prefix:sub(scan, scan + 1) == "/*" then
					open_at = scan
					break
				end
			end
			if not open_at then break end
			local block_start = open_at
			while block_start > 1 do
				local ch = source:sub(block_start - 1, block_start - 1)
				if ch ~= " " and ch ~= "\t" then break end
				block_start = block_start - 1
			end
			table.insert(pieces, 1, source:sub(block_start, non_ws))
			scan_pos = block_start
		else
			-- Line comment check: walk back from non_ws to the most recent `\n`
			-- (or position 1) and inspect the resulting line. This handles both
			-- `// foo\n<marker>` (non_ws ends on `o`) and `// foo\r\n<marker>`.
			local line_start = non_ws
			while line_start > 1 and source:sub(line_start - 1, line_start - 1) ~= "\n" do
				line_start = line_start - 1
			end
			local line = source:sub(line_start, non_ws)
			if line:sub(1, 2) ~= "//" then break end
			table.insert(pieces, 1, line)
			scan_pos = line_start - 1
		end
	end
	if #pieces == 0 then return "" end
	return table.concat(pieces, "\n")
end

--- Resolve the start position for the declaration-comment walk.
--- When a debug-skip marker is pending, the walker must start from the position immediately before the marker ident
--- (so it walks backward past the marker text and any `FI_ MipsAtom ac_X(args)` proc-prelude layout — neither of which is visible if we start from the declaration ident_pos).
--- When no marker is pending, the walker starts from the declaration ident_pos directly.
--- @param pending_marker DebugSkipMarker|nil
--- @param ident_pos      integer -- declaration ident position
--- @return integer
local function comment_walk_start(pending_marker, ident_pos)
	if pending_marker then
		return pending_marker.marker_pos - 1
	end
	return ident_pos - 1
end

--- Attach the pending marker to the next declaration.
--- The declaration form disambiguates whole atoms from components; the resolved `debug_skip` is stamped directly on the declaration record
--- (sole-owner discipline; see push_debug_skip_marker).
---
--- A marker is POSITIVE (stamps `debug_skip = true` on the declaration) iff:
---   marker_kind == "atom_dbg_skip" AND is_bare == true
--- Any other spelling or shape (parenthesized form, legacy name) is recorded as a raw marker for annotation validation but never stamps `debug_skip`.
--- @param out         SourceScan
--- @param target_kind string|nil -- "atom" | "atom_proc" | "comp_bare" | "comp_proc" | "unrelated" once observed
--- @return boolean|nil -- true iff the marker is the positive bare form
local function attach_debug_skip_marker(out, target_kind)
	local markers = out.debug_skip_markers
	local marker  = markers[#markers]
	if not (marker and marker.pending) then return nil end

	marker.pending     = false
	marker.target_kind = target_kind

	if marker.marker_kind == "atom_dbg_skip" and marker.is_bare then
		return true
	end
	return nil
end

-- Register a parsed atom entry in `out.atoms`. Stamps the resolved `debug_skip` boolean
-- on the record when a positive bare `atom_dbg_skip` marker is pending.
-- Captures the shared shape used by MipsAtom_, MipsAtomComp_, MipsAtomComp_Proc_.
local function register_atom(out, kind, declaration_line, name, body, body_off, raw_name, pos, after_paren, source)
	-- Capture the pending marker BEFORE attaching so the walker can anchor the backward comment walk on the marker's marker_pos
	-- (which is the correct anchor even when an `FI_ MipsAtom ac_X(args)` proc-prelude separates the marker from the declaration).
	local pending_marker = nil
	local markers = out.debug_skip_markers
	local m = markers[#markers]
	if m and m.pending then pending_marker = m end

	local positive = attach_debug_skip_marker(out, kind)
	local comment  = ""
	if kind == "comp_bare" or kind == "comp_proc" then
		-- Scanner-owned declaration-comment attachment.
		-- The walker does not need to detect marker shape.
		-- A pending_marker record (or the declaration ident_pos fallback) supplies the anchor position.
		local start_pos = comment_walk_start(pending_marker, pos)
		comment = preceding_comment_walk_backward(source, start_pos)
	end
	out.atoms[#out.atoms + 1] = {
		line              = declaration_line,
		name              = name,
		body              = body,
		body_off          = body_off,
		kind              = kind,
		raw_name          = raw_name,
		ident_pos         = pos,
		after_paren       = after_paren,
		debug_skip        = positive == true,
		declaration_comment = comment,
	}
end

-- Register a parsed raw-atom entry in `out.raw_atoms`.
-- Captures the 5-field shape used by MipsCode (the raw-atom form; offsets pass only).
local function register_raw_atom(out, declaration_line, name, body, body_off, raw_name, pos)
	out.raw_atoms[#out.raw_atoms + 1] = {
		line = declaration_line, name = name, body = body, body_off = body_off,
		kind = "raw_atom", raw_name = raw_name,
	}
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

--- Walk a `Struct_` / `Enum_` body, calling `build_field(first, first_end, after_first)` for each entry.
--- The builder returns either:
---   - (record, new_pos)  -- append record to fields; advance body_pos to new_pos
---   - (nil, new_pos)     -- skip this entry; advance body_pos to new_pos
--- After each entry, the walker skips a single trailing `,` or `;`.
--- The 2 body-field parsers in this file (struct + enum) share this body-walk loop.
--- @param body string
--- @param build_field fun(first: string, first_end: integer, after_first: integer): (table|nil, integer)
--- @return table[]
local function walk_body_fields(body, build_field)
	local fields   = {}
	local body_pos = 1
	local body_len = #body
	while body_pos <= body_len do
		body_pos = duffle.skip_ws_and_cmt(body, body_pos)
		if body_pos > body_len then break end
		local  first, first_end = duffle.read_ident(body, body_pos)
		if not first then
			body_pos = body_pos + 1
		else
			local after_first     = duffle.skip_ws_and_cmt(body, first_end)
			local result, new_pos = build_field(first, first_end, after_first)
			if    result then fields[#fields + 1] = result end
			body_pos = new_pos or first_end
			-- Skip a single trailing `,` or `;`.
			if body_pos <= body_len and (body:sub(body_pos, body_pos) == "," or body:sub(body_pos, body_pos) == ";") then
				body_pos = body_pos + 1
			end
		end
	end
	return fields
end

-- Parse the `<type> <field>[, <field>...];` declarations from a Struct_ body.
-- After the type and `*` chain, keep reading `, ident` until `;`.
-- Same type, same pointer depth for every name on that list.
-- Returns the raw fields array with `{name, type_name, pointer_depth}` only (NO offset / byte_size).
-- The propagation pass `resolve_struct_field_sizes` walks each struct's fields AFTER type resolution and populates offset + byte_size in place.
local function parse_struct_body_fields(body)
	local fields = {}
	local body_pos = 1
	local body_len = #body
	while body_pos <= body_len do
		body_pos = duffle.skip_ws_and_cmt(body, body_pos)
		if body_pos > body_len then break end
		local type_name, type_end = duffle.read_ident(body, body_pos)
		if not type_name then
			body_pos = body_pos + 1
		else
			local depth, cursor = 0, duffle.skip_ws_and_cmt(body, type_end)
			while cursor <= body_len and body:sub(cursor, cursor) == "*" do
				depth = depth + 1
				cursor = duffle.skip_ws_and_cmt(body, cursor + 1)
			end
			while cursor <= body_len do
				local field_ident, field_end = duffle.read_ident(body, cursor)
				if not field_ident then break end
				fields[#fields + 1] = {
					name          = field_ident,
					type_name     = type_name,
					pointer_depth = depth,
					offset        = nil,
					byte_size     = nil,
				}
				cursor = duffle.skip_ws_and_cmt(body, field_end)
				if body:sub(cursor, cursor) == "," then
					cursor = duffle.skip_ws_and_cmt(body, cursor + 1)
				else
					break
				end
			end
			if cursor <= body_len and body:sub(cursor, cursor) == ";" then
				cursor = cursor + 1
			end
			body_pos = cursor
		end
	end
	return fields
end

-- Parse the `Enum_(<underlying>, <name>) { <body> }` body for entries.
-- Captures one field per named enumerator with the shape { name, value }.
-- The value is the integer literal parsed from the source via `parse_enum_int_literal`.
local function parse_enum_body_fields(body)
	return walk_body_fields(body, function(entry_name, name_end, after_name)
		local value
		local new_pos
		if body:sub(after_name, after_name) == "=" then
			local val_pos    = duffle.skip_ws_and_cmt(body, after_name + 1)
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
	if visited[type_name]           then return nil end
	visited[type_name] = true

	-- Check the builtin primitive map FIRST.
	-- This handles undeclared builtin idents (e.g. `__UINT32_TYPE__` appears as underlying_type in `typedef __UINT32_TYPE__ TSet_(V4_S2);` 
	-- even though the fixture never declares `__UINT32_TYPE__` itself).
	local builtin = BUILTIN_BYTE_SIZES[type_name]
	if    builtin ~= nil then return builtin end

	local  entry = type_name_registry[type_name]
	if not entry then return nil end

	-- Confident: this entry was already resolved by the propagation pass (e.g., a builtin or a struct whose fields are all resolved).
	if entry.byte_size ~= nil then return entry.byte_size end

	-- Chain-following: typedef / TSet_ aliases follow underlying_type.
	if entry.underlying_type then
		return resolve_typedef_byte_size(entry.underlying_type, type_name_registry, visited, depth + 1)
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
	local  reg = out.type_name_registry
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
				if    resolved ~= nil then
					entry.byte_size = resolved
					any_change      = true
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
-- On malformed `atom_type(...)` (missing close paren, trailing tokens after the close paren, empty type chain, trailing junk inside the parens like `V4_S2*()`),
-- the function still returns the leading reg_name but sets `malformed_flag = true` and `override_entry = nil`
-- so the caller can silently drop the override while keeping the register in the reads/writes list.
local function parse_atom_info_reg_entry(entry)
	local pos = 1
	pos = duffle.skip_ws_and_cmt(entry, pos)
	if pos > #entry then return nil, nil, false end
	local  reg_name, reg_end = duffle.read_ident(entry, pos)
	if not reg_name then return nil, nil, false end
	pos = duffle.skip_ws_and_cmt(entry, reg_end)
	-- Plain register, no adjacent atom_type — done.
	if pos > #entry then return reg_name, nil, false end

	-- Adjacent ident must be a bare `atom_type` (word-bounded both sides).
	local  next_ident, next_end = duffle.read_ident(entry, pos)
	if not next_ident or next_ident ~= "atom_type" then return reg_name, nil, false end
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
	if pos > #entry or entry:sub(pos, pos) ~= "(" then return reg_name, nil, true end
	local sub_inner, sub_after = duffle.read_parens(entry, pos)

	-- Reject any trailing tokens (including `;` / `,`) after the close paren.
	-- The outer caller already split on top-level commas, so the only legal terminator here is end-of-entry.
	local after_close = duffle.skip_ws_and_cmt(entry, sub_after)
	if    after_close <= #entry then return reg_name, nil, true end

	-- Parse the type chain inside the parens; require full consumption.
	-- parse_type_chain returns (ident, depth, end_pos);
	-- We reject any non-whitespace residue past end_pos (catches `V4_S2*()` etc.).
	local  type_name, depth, after_chain = parse_type_chain(sub_inner, 1)
	if not type_name then return reg_name, nil, true end
	local end_check = duffle.skip_ws_and_cmt(sub_inner, after_chain)
	if    end_check <= #sub_inner then return reg_name, nil, true end

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
		-- reads/writes arrays contain ONLY register idents;
		-- `atom_type(...)` sub-entry (when present and well-formed) is recorded as a per-atom reg_type_override.
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
		-- Silently reject malformed args; DWARF chain treats the field as un-set.
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
		atom_bind       = function(sub_inner)            binds = duffle.trim(sub_inner)                       end, -- scan: atom_bind(<Binds_X>)
		atom_reads      = function(sub_inner, info_line) rw_handler(sub_inner, info_line, "atom_reads")       end, -- scan: atom_reads(<R_X [atom_type(<T>)], ...>)
		atom_writes     = function(sub_inner, info_line) rw_handler(sub_inner, info_line, "atom_writes")      end, -- scan: atom_writes(<R_X [atom_type(<T>)], ...>)
		atom_view       = function(sub_inner)            view_binds = duffle.trim(sub_inner)                  end, -- scan: atom_view(<Binds_X>)
		atom_reg_types  = reg_types_handler,                                                                       -- scan: atom_reg_types(<R_X>, <T>)
		atom_ctx        = function(sub_inner, info_line) ident_handler(sub_inner, info_line, "ctx_atom_name") end, -- scan: atom_ctx(<atom_name>)
		atom_phase      = function(sub_inner, info_line) ident_handler(sub_inner, info_line, "phase_label")   end, -- scan: atom_phase(<label>)
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
-- enum / atom_reg / R_*_Code parsing
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
local BYTE_SEMI       = 0x3B   -- ';'
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
local BYTE_SLASH      = 0x2F   -- '/'
local BYTE_STAR       = 0x2A   -- '*'
local BYTE_SPACE      = 0x20   -- ' '
local BYTE_TAB        = 0x09   -- '\t'
local BYTE_CR         = 0x0D   -- '\r'

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

-- Read one trailing C-comment that appears immediately after `pos` in `body`,
-- skipping horizontal whitespace and newlines first. Used by `parse_enum_entry` to
-- recover the `atom_auto_reg:` / `phase_auto_reg:` scope annotation embedded by
-- the `atom_auto_reg` / `phase_auto_reg` macros' RHS expansion
-- (`R_<Sym> = R_<Sym>_Code /* atom_auto_reg: <scope> */`).
-- Handles both block (`/* ... */`) and line (`// ...`) forms.
-- Returns the comment text (without delimiters), or nil if no comment is adjacent.
local function read_trailing_cmt_after(body, pos)
	local body_len = #body
	while pos <= body_len do
		local b = body:byte(pos)
		if b == BYTE_SPACE or b == BYTE_TAB or b == BYTE_NEWLINE or b == BYTE_CR then
			pos = pos + 1
		elseif b == BYTE_SLASH then
			local b2 = body:byte(pos + 1)
			if b2 == BYTE_STAR then
				-- Block comment /* ... */
				local i = pos + 2
				while i < body_len do
					if body:byte(i) == BYTE_STAR and body:byte(i + 1) == BYTE_SLASH then
						return body:sub(pos + 2, i - 1)
					end
					i = i + 1
				end
				return nil  -- unterminated; treat as no comment
			elseif b2 == BYTE_SLASH then
				-- Line comment // ... (strip the trailing newline)
				local end_pos = duffle.find_byte(body, BYTE_NEWLINE, pos + 2) or (body_len + 1)
				return body:sub(pos + 2, end_pos - 1)
			end
			return nil
		else
			return nil
		end
	end
	return nil
end

--- Parse a decimal/negative-decimal/hex integer literal starting at byte position `start`.
--- Returns (value, end_pos) on success, or (nil, start) on failure / no match.
--- Accepts: 12, -1, 0, 0x10, 0X1F, -0x10.
--- @param text  string
--- @param start integer
--- @return integer|nil, integer
--- Implementation note: this is a plain assignment (not `local function`) 
--- so the forward declaration at the top of the file is the same upvalue the earlier `parse_enum_body_fields` closure captures.
--- Lua 5.3 / LuaJIT upvalue semantics resolve the assignment at call time.
parse_enum_int_literal = function(text, start)
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
-- Uses byte checks for the fixed bytes.
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
	if    int_val ~= nil then return int_val end

	-- Try symbol reference (must be R_*_Code per the spec).
	local  sym = duffle.read_ident(source, pos)
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
	if    body then
		return resolve_code_macro_value(body, 1, code_macros, code_macro_bodies, visited, depth + 1)
	end

	-- Forward reference / unresolved: pass 1 stores resolved ints;
	-- pass 2 re-encounters every `#define R_*_Code` line and resolves using the now-populated cross-source registries.
	-- Returning nil here is the documented behavior; the enum-value lookup in pass 2 will also see nil and report via the AliasEntry.code = nil path.
	return nil
end

--- Intercept a `#define R_*_Code <RHS>` preprocessor line.
--- Always saves the raw RHS text into `code_macro_bodies` (for cross-source fallback during chain resolution),
--- then (if resolvable) stores the resolved integer code into `code_macros` keyed by the macro name.
--- `directive_start` points at the `#` byte. The function is silent on non-matching directives, the caller skips the line in any case.
--- @param source          string
--- @param directive_start integer  -- byte position of `#`
--- @param code_macros     table    -- out._code_macros / ctx.shared._code_macros
--- @param code_macro_bodies table  -- out._code_macro_bodies / ctx.shared._code_macro_bodies
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

--- Quick pre-pass: walk the source looking ONLY for `#define R_*_Code` lines.
--- Populates `code_macros` with resolved integer codes AND `code_macro_bodies` with raw RHS text
--- (used by the chain walker as cross-source fallback during pass 1b in `M.run`); ignores everything else.
--- Used by `M.run` pass 1a to build the cross-source `_code_macros` + `_code_macro_bodies` registries before pass 1b resolves chains.
--- @param source            string
--- @param code_macros       table
--- @param code_macro_bodies table
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
	if    ident ~= "atom_type" then return nil, 0, pos end
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
	if    open_pos > #body or body:sub(open_pos, open_pos) ~= "(" then return nil, 0, pos end
	local inner, after_close = duffle.read_parens(body, open_pos)
	-- Reject any trailing tokens past the close paren other than comma / close-brace (next enum entry / end of enum).
	local residue = duffle.skip_ws_and_cmt(body, after_close)
	if    residue <= #body then
		local rbyte = body:byte(residue)
		if rbyte ~= BYTE_COMMA and rbyte ~= BYTE_CLOSE_BRACE then return nil, 0, pos end
	end
	-- Parse the type chain inside the parens (e.g. `V4_S2*` -> ("V4_S2", 1)).
	local  type_name, depth, after_chain = parse_type_chain(inner, 1)
	if not type_name then return nil, 0, pos end
	local end_check = duffle.skip_ws_and_cmt(inner, after_chain)
	if    end_check <= #inner then return nil, 0, pos end
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
--   out       -- the SourceScan out table (mutated in place: out.atoms / out.raw_atoms / out.binds / out.atom_infos / out.macros / out.debug_skip_markers)
--   returns   -- new position after the construct
--
-- All parsers read source-as-written via the duffle primitives (skip_ws_and_cmt / read_parens / read_braces / read_balanced).
-- No regex per the no_regex constraint; no hand-rolled depth tracking
-- The MipsAtomComp_Proc_ brace matcher uses `duffle.read_braces`.
--
-- Adding a new construct = 1 row in DECL_PARSERS + 1 parser function. The scan_source() loop never needs editing.

--- Parse a `atom_dbg_skip` marker and record its raw placement evidence.
---
--- Positive path: the BARE form (`atom_dbg_skip` followed by whitespace + a supported declaration)
--- stamps the `debug_skip` field on the immediately-following declaration record via `attach_debug_skip_marker`. `is_bare` 
--- is set true only when `marker_kind == "atom_dbg_skip"` and there are no parens.
---
--- Diagnostic-only path: a following `(...)` is recorded as an invalid parenthesized-form marker so the annotation rule can emit a precise "parenthesized form" diagnostic.
--- The parenthesized form stays diagnostic; the bare form alone carries the runtime stamp.
--- @param source    string
--- @param pos       integer
--- @param ident_end integer
--- @param line_of   fun(pos: integer): integer
--- @param out       SourceScan
--- @return integer -- source cursor position to resume from
local function parse_dbg_skip_marker(source, pos, ident_end, line_of, out)
	local marker_kind = source:sub(pos, ident_end - 1)

	-- Diagnostic-only detection of an invalid following `(...)`.
	-- The cursor is advanced past the `()` either way to keep token order coherent for the next scan iteration.
	local marker_end  = ident_end
	local open_paren  = duffle.skip_ws_and_cmt(source, ident_end)
	local has_parens  = false
	local args        = nil
	if source:sub(open_paren, open_paren) == "(" then
		local inner, after_paren = duffle.read_parens(source, open_paren)
		marker_end = after_paren
		has_parens = true
		args       = duffle.trim(inner)
	end

	push_debug_skip_marker(out, {
		marker_kind = marker_kind,
		marker_line = line_of(pos),
		marker_pos  = pos,
		is_bare     = (marker_kind == "atom_dbg_skip") and (not has_parens),
		has_parens  = has_parens,
		args        = args,
	})
	return marker_end
end

--- Parse `atom_auto_reg(<atom>, R_<Sym>)` and `phase_auto_reg(<phase>, R_<Sym>)` markers.
---
--- The macros expand to `sym = sym##_Code` per their definition in dsl.atom.h.
--- After preprocessing, the marker renders as a full enum entry of the form `R_<Sym> = R_<Sym>_Code,`.
--- This parser detects the macro invocation site, extracts `(scope_name, sym)`, and stores it
--- in the per-source table (atom_auto_regs or phase_auto_regs) under the scope's name.
---
--- @param source    string
--- @param pos       integer
--- @param ident_end integer
--- @param line_of   fun(pos: integer): integer
--- @param out       SourceScan
--- @return integer
local function parse_auto_reg_marker(source, pos, ident_end, line_of, out)
	local marker_kind = source:sub(pos, ident_end - 1)  -- "atom_auto_reg" or "phase_auto_reg"
	local scope_kind  = marker_kind == "atom_auto_reg" and "atom" or "phase"

	local inner, after_paren = read_parens_after(source, ident_end)
	if not inner then return after_paren end

	local args = duffle.split_top_level_commas(inner)
	local scope_name = args[1] and duffle.trim(args[1]) or nil
	local sym        = args[2] and duffle.trim(args[2]) or nil

	-- Filter: only accept `R_<Sym>` form (matches `^R_[%w_]+$`).
	if scope_name and sym and sym:match("^R_[%w_]+$") then
		if scope_kind == "atom" then
			out.atom_auto_regs = out.atom_auto_regs or {}
			out.atom_auto_regs[scope_name] = out.atom_auto_regs[scope_name] or {}
			out.atom_auto_regs[scope_name][sym] = sym
		else
			out.phase_auto_regs = out.phase_auto_regs or {}
			out.phase_auto_regs[scope_name] = out.phase_auto_regs[scope_name] or {}
			out.phase_auto_regs[scope_name][sym] = sym
		end
	end

	return after_paren
end

-- Parse `atom_dbg_reg_default(R_X, <type>...)`;
-- the second argument may be a `Type` or `Type*`/`Type**` chain. Records in `out.types[R_X]`.
local function parse_atom_dbg_reg_default(source, pos, ident_end, line_of, out)
	local  inner, after_paren = read_parens_after(source, ident_end)
	if not inner then return after_paren end
	local args = duffle.split_top_level_commas(inner)
	if   #args < 1 then
		-- Annotation pass surfaces this; we still consume the marker.
		return after_paren
	end
	local reg_name         = duffle.trim(args[1])
	local type_part        = args[2] or "void"
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

--- Lookahead for `atom_info(...)` after a declaration's closing paren.
--- Records into `dest` (atom_infos or component_atom_infos). Returns the position after the info, or after_paren if none.
local function parse_atom_info_after_decl(source, after_paren, raw_name, line_of, out, dest)
	local lookahead            = duffle.skip_ws_and_cmt(source, after_paren)
	local look_ident, look_end = duffle.read_ident(source, lookahead)
	if look_ident ~= "atom_info" then return after_paren end
	local info_open = duffle.skip_ws_and_cmt(source, look_end)
	if source:sub(info_open, info_open) ~= "(" then return after_paren end
	local info_inner, info_after = duffle.read_parens(source, info_open)
	if not info_inner then return after_paren end
	local info_line = line_of(info_open)
	local ai_binds, ai_reads, ai_writes, ai_view, ai_overrides, ai_ctx, ai_phase = scan_atom_info_subcalls(info_inner, info_line)
	dest = dest or out.atom_infos
	dest[#dest + 1] = {
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
		out.atom_views[raw_name] = out.atom_views[raw_name] or { atom_name = raw_name, binds_name = nil, reg_type_overrides = nil, info_line = line_of(lookahead) }
		out.atom_views[raw_name].reg_type_overrides = ai_overrides
	end
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
	return info_after
end

local DECL_FORMS = {
	MipsAtom_ = {
		kind = "atom", name = "paren_ident", body = "braces_after",
		info_dest = "atom_infos", strip = false,
	},
	MipsAtom_Proc_ = {
		kind = "atom_proc", name = "backward_atom_proc", body = "last_brace_in_args",
		info_dest = "atom_infos", strip = false, after = "reguse_hook",
	},
	MipsAtomComp_ = {
		kind = "comp_bare", name = "paren_ident", body = "braces_after",
		info_dest = "component_atom_infos", strip = "ac_",
	},
	MipsAtomComp_Proc_ = {
		kind = "comp_proc", name = "backward_fi", body = "last_brace_in_args",
		info_dest = nil, strip = "ac_",
	},
	MipsAtomComp_ProcMap_ = {
		kind = "comp_proc", name = "backward_fi", body = "comma_arg_2",
		info_dest = nil, strip = "ac_", after = "map_command_hook",
	},
}

local function last_brace_body(inner, open_paren)
	local last_brace_pos = nil
	for search_pos = #inner, 1, -1 do
		if inner:sub(search_pos, search_pos) == "{" then
			last_brace_pos = search_pos
			break
		end
	end
	if not last_brace_pos then return nil end
	local body, close_pos = duffle.read_braces(inner, last_brace_pos)
	if close_pos > #inner + 1 then return nil end
	return body, open_paren + 2 + last_brace_pos
end

local function reguse_hook(source, pos, line_of, out, extras)
	local entry = out.atoms[#out.atoms]
	if not entry then return end
	local reg_use_schema_name, reg_use_param_name
	if extras.args_inner then
		local arg_tokens = duffle.split_top_level_commas(extras.args_inner)
		for _, tok in ipairs(arg_tokens) do
			local trimmed = duffle.trim(tok)
			local schema_suffix, param = trimmed:match("RegUse_([%w_]+)%s+([%w_]+)$")
			if schema_suffix then
				if reg_use_schema_name then
					out.reg_use_errors[#out.reg_use_errors + 1] = {
						kind        = "reguse_multiple_params",
						schema_name = "RegUse_" .. schema_suffix,
						source_line = line_of(pos),
					}
				else
					reg_use_schema_name = "RegUse_" .. schema_suffix
					reg_use_param_name  = param
				end
			end
		end
	end
	entry.reg_use_schema_name = reg_use_schema_name
	entry.reg_use_param_name  = reg_use_param_name
	if reg_use_schema_name and extras.func_ident then
		local expected = "RegUse_" .. extras.func_ident
		if reg_use_schema_name ~= expected then
			out.reg_use_errors[#out.reg_use_errors + 1] = {
				kind        = "reguse_name_mismatch",
				schema_name = reg_use_schema_name,
				func_ident  = extras.func_ident,
				source_line = line_of(pos),
			}
		end
	end
end

local function parse_decl_form(source, pos, ident_end, line_of, out)
	local ident = duffle.read_ident(source, pos)
	local form = ident and DECL_FORMS[ident]
	if not form then return ident_end end

	local inner, after_paren, open_paren = read_parens_after(source, ident_end)
	if not inner then return after_paren end

	local extras = {}
	local raw_name
	if form.name == "paren_ident" then
		raw_name = duffle.read_ident(inner, 1)
		if form.strip and not raw_name then return open_paren + 1 end
	elseif form.name == "backward_fi" then
		raw_name = duffle.find_function_decl_for(source, open_paren, SLICE_MIPS_CODE_LEN)
	elseif form.name == "backward_atom_proc" then
		raw_name, extras.args_inner, extras.func_ident, extras.after_func_paren =
			duffle.find_atom_proc_decl_for(source, open_paren, MIPS_ATOM_PTR_LEN)
	end
	if form.name == "paren_ident" and form.strip and not raw_name then
		return open_paren + 1
	end
	if not raw_name then raw_name = "?" end
	local name = form.strip and strip_ac_prefix(raw_name) or raw_name

	if form.info_dest == "component_atom_infos" then
		out.component_atom_infos = out.component_atom_infos or {}
	end
	local info_dest = form.info_dest and out[form.info_dest]

	local body, body_off, resume
	if form.body == "braces_after" then
		local brace_search = after_paren
		if info_dest then
			brace_search = parse_atom_info_after_decl(
				source, after_paren, name, line_of, out, info_dest)
		end
		local after_brace
		body, after_brace, body_off = find_body_braces(source, brace_search, open_paren + 1)
		if not body then return after_brace end
		resume = after_brace
	elseif form.body == "last_brace_in_args" then
		body, body_off = last_brace_body(inner, open_paren)
		if not body then return after_paren end
		resume = after_paren
		if form.info_dest then
			if extras.after_func_paren then
				parse_atom_info_after_decl(
					source, extras.after_func_paren, name, line_of, out, out.atom_infos)
			else
				parse_atom_info_after_decl(source, pos, name, line_of, out, out.atom_infos)
			end
		end
	elseif form.body == "comma_arg_2" then
		local args = duffle.split_top_level_commas(inner)
		if #args < 2 then return after_paren end
		body = duffle.trim(args[2])
		if body == "" then return after_paren end
		body_off = open_paren + 1 + (inner:find(body, 1, true) or 1) - 1
		resume = after_paren
	else
		return after_paren
	end

	local skip_register = form.name == "paren_ident" and not form.strip
		and (raw_name == "?" or raw_name == "")
	if not skip_register then
		register_atom(out, form.kind, line_of(pos), name, body, body_off,
			raw_name, pos, after_paren, source)
	end

	if form.after == "reguse_hook" then
		reguse_hook(source, pos, line_of, out, extras)
	elseif form.after == "map_command_hook" then
		local entry = out.atoms[#out.atoms]
		if entry then entry.map_command = body end
	end

	return resume
end

--- Parse: `MipsCode code_<name> { <body> }` (raw atom form — offsets pass only).
--- @param source    string
--- @param pos       integer
--- @param ident_end integer
--- @param line_of   fun(pos: integer): integer
--- @param out       SourceScan
--- @return integer
local function parse_mips_code(source, pos, ident_end, line_of, out)
	local  next_pos               = duffle.skip_ws_and_cmt(source, ident_end)
	local  next_ident, next_after = duffle.read_ident(source, next_pos)
	if not next_ident or #next_ident <= 5 or next_ident:sub(1, 5) ~= "code_" then
		return ident_end
	end

	local  atom_name                   = next_ident:sub(6)
	local  body, after_brace, body_off = find_body_braces(source, next_after, ident_end)
	if not body then return after_brace end
	register_raw_atom(out, line_of(pos), atom_name, body, body_off, atom_name, pos)

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
--- @param body    string
--- @param name    string
--- @param pos     integer
--- @param line_of fun(pos: integer): integer
--- @param out     SourceScan
local function register_struct_type(body, name, pos, line_of, out)
	local fields     = parse_struct_body_fields(body)
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
--- @param name       string
--- @param body       string
--- @param pos        integer
--- @param line_of    fun(pos: integer): integer
--- @param out        SourceScan
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
--- @param name       string
--- @param pos        integer
--- @param line_of    fun(pos: integer): integer
--- @param out        SourceScan
local function register_typedef_alias(underlying, name, pos, line_of, out)
	out.type_name_registry[name] = {
		name            = name,
		kind            = "typedef",
		underlying_type = underlying,
		source_line     = line_of(pos),
		source_file     = out._source_file,
		pointer_depth   = 0,
	}
end

local parse_reg_use_schema_body

local function fields_for_reg_type(type_name, type_registry)
	local reg_name = "Reg_" .. type_name
	local entry = type_registry and type_registry[reg_name]
	if entry and entry.fields and #entry.fields > 0 then
		local names = {}
		for _, field in ipairs(entry.fields) do
			if field.name then names[#names + 1] = field.name end
		end
		if #names > 0 then return names end
	end
	if entry and entry.body and parse_reg_use_schema_body then
		local schema = parse_reg_use_schema_body(entry.body, type_registry)
		if schema and schema.slots then
			local names = {}
			for _, slot in ipairs(schema.slots) do
				if slot.name then names[#names + 1] = slot.name end
			end
			if #names > 0 then return names end
		end
	end
	return nil
end

parse_reg_use_schema_body = function(body, type_registry, opts)
	opts = opts or {}
	local require_types = opts.require_types == true
	local pending = false
	local slots = {}
	local alias_to_slot = {}
	local slot_names = {}
	local errors = {}

	local function add_alias(path, slot)
		if alias_to_slot[path] then
			errors[#errors + 1] = { kind = "reguse_duplicate_alias", path = path }
			return false
		end
		alias_to_slot[path] = slot
		return true
	end

	local function add_slot(name, aliases, readonly)
		if slot_names[name] then
			errors[#errors + 1] = { kind = "reguse_duplicate_slot", name = name }
			return nil
		end
		slot_names[name] = true
		local slot = { name = name, aliases = aliases, readonly = readonly == true }
		slots[#slots + 1] = slot
		return slot
	end

	local function parse_reg_names(text, pos)
		local names = {}
		while pos <= #text do
			pos = duffle.skip_ws_and_cmt(text, pos)
			local name, name_end = duffle.read_ident(text, pos)
			if not name then return nil, pos end
			names[#names + 1] = name
			pos = duffle.skip_ws_and_cmt(text, name_end)
			if text:sub(pos, pos) == "," then
				pos = pos + 1
			else
				break
			end
		end
		if text:sub(pos, pos) == ";" then pos = pos + 1 end
		return names, pos
	end

	local pos = 1
	while pos <= #body do
		pos = duffle.skip_ws_and_cmt(body, pos)
		if pos > #body then break end
		local first, first_end = duffle.read_ident(body, pos)
		if not first then
			pos = pos + 1
			goto continue
		end
		local after = duffle.skip_ws_and_cmt(body, first_end)
		if first == "const" then
			errors[#errors + 1] = { kind = "reguse_const_reg_spelling" }
			return nil, errors
		elseif first == "union" then
			if body:sub(after, after) ~= "{" then
				errors[#errors + 1] = { kind = "reguse_malformed" }
				return nil, errors
			end
			local inner, after_braces = duffle.read_braces(body, after)
			if not inner then
				errors[#errors + 1] = { kind = "reguse_malformed" }
				return nil, errors
			end
			local views = {}
			local union_readonly = nil
			local inner_pos = 1

			local function note_readonly(flag)
				if union_readonly == nil then
					union_readonly = flag
				elseif union_readonly ~= flag then
					errors[#errors + 1] = { kind = "reguse_mixed_const" }
					return false
				end
				return true
			end

			while inner_pos <= #inner do
				inner_pos = duffle.skip_ws_and_cmt(inner, inner_pos)
				if inner_pos > #inner then break end
				local m_type, m_type_end = duffle.read_ident(inner, inner_pos)
				if not m_type then
					inner_pos = inner_pos + 1
					goto continue_inner
				end
				if m_type == "const" then
					errors[#errors + 1] = { kind = "reguse_const_reg_spelling" }
					return nil, errors
				end

				if m_type == "Reg_" then
					local after_ty = duffle.skip_ws_and_cmt(inner, m_type_end)
					if inner:sub(after_ty, after_ty) ~= "(" then
						errors[#errors + 1] = { kind = "reguse_malformed" }
						return nil, errors
					end
					local type_inner, after_paren = duffle.read_parens(inner, after_ty)
					if not type_inner then
						errors[#errors + 1] = { kind = "reguse_malformed" }
						return nil, errors
					end
					local typed_fields = fields_for_reg_type(duffle.trim(type_inner), type_registry)
					after_paren = duffle.skip_ws_and_cmt(inner, after_paren)
					local inst_names, new_inner = parse_reg_names(inner, after_paren)
					if not inst_names or #inst_names == 0 then
						errors[#errors + 1] = { kind = "reguse_malformed" }
						return nil, errors
					end
					if not note_readonly(false) then return nil, errors end
					if not typed_fields then
						if require_types then
							errors[#errors + 1] = { kind = "reguse_unknown_reg_type", type_name = duffle.trim(type_inner) }
							return nil, errors
						end
						pending = true
					else
						for _, inst in ipairs(inst_names) do
							local names = {}
							for _, field in ipairs(typed_fields) do
								names[#names + 1] = inst .. "." .. field
							end
							views[#views + 1] = { names = names, lanes = true }
						end
					end
					inner_pos = new_inner

				elseif m_type == "struct" then
					local after_struct = duffle.skip_ws_and_cmt(inner, m_type_end)
					if inner:sub(after_struct, after_struct) ~= "{" then
						local _, tag_end = duffle.read_ident(inner, after_struct)
						if not tag_end then
							errors[#errors + 1] = { kind = "reguse_malformed" }
							return nil, errors
						end
						after_struct = duffle.skip_ws_and_cmt(inner, tag_end)
					end
					if inner:sub(after_struct, after_struct) ~= "{" then
						errors[#errors + 1] = { kind = "reguse_malformed" }
						return nil, errors
					end
					local struct_inner, after_struct_braces = duffle.read_braces(inner, after_struct)
					if not struct_inner then
						errors[#errors + 1] = { kind = "reguse_malformed" }
						return nil, errors
					end
					local lane_names = {}
					local s_pos = 1
					while s_pos <= #struct_inner do
						s_pos = duffle.skip_ws_and_cmt(struct_inner, s_pos)
						if s_pos > #struct_inner then break end
						local s_ty, s_ty_end = duffle.read_ident(struct_inner, s_pos)
						if not s_ty then
							s_pos = s_pos + 1
							goto continue_struct
						end
						if s_ty == "Reg_" then
							local after_ty = duffle.skip_ws_and_cmt(struct_inner, s_ty_end)
							if struct_inner:sub(after_ty, after_ty) ~= "(" then
								errors[#errors + 1] = { kind = "reguse_malformed" }
								return nil, errors
							end
							local type_inner, after_paren = duffle.read_parens(struct_inner, after_ty)
							if not type_inner then
								errors[#errors + 1] = { kind = "reguse_malformed" }
								return nil, errors
							end
							local typed_fields = fields_for_reg_type(duffle.trim(type_inner), type_registry)
							after_paren = duffle.skip_ws_and_cmt(struct_inner, after_paren)
							local inst_names, new_s = parse_reg_names(struct_inner, after_paren)
							if not inst_names or #inst_names == 0 then
								errors[#errors + 1] = { kind = "reguse_malformed" }
								return nil, errors
							end
							if not note_readonly(false) then return nil, errors end
							if not typed_fields then
								if require_types then
									errors[#errors + 1] = { kind = "reguse_unknown_reg_type", type_name = duffle.trim(type_inner) }
									return nil, errors
								end
								pending = true
							else
								for _, inst in ipairs(inst_names) do
									for _, field in ipairs(typed_fields) do
										lane_names[#lane_names + 1] = inst .. "." .. field
									end
								end
							end
							s_pos = new_s
						elseif s_ty == "Reg" then
							local s_after = duffle.skip_ws_and_cmt(struct_inner, s_ty_end)
							local s_readonly = false
							local maybe_const, maybe_end = duffle.read_ident(struct_inner, s_after)
							if maybe_const == "const" then
								s_readonly = true
								s_after = duffle.skip_ws_and_cmt(struct_inner, maybe_end)
							end
							if not note_readonly(s_readonly) then return nil, errors end
							local names, new_s = parse_reg_names(struct_inner, s_after)
							if not names or #names == 0 then
								errors[#errors + 1] = { kind = "reguse_malformed" }
								return nil, errors
							end
							for _, n in ipairs(names) do lane_names[#lane_names + 1] = n end
							s_pos = new_s
						else
							errors[#errors + 1] = { kind = "reguse_malformed" }
							return nil, errors
						end
						::continue_struct::
					end
					if #lane_names == 0 and not pending then
						errors[#errors + 1] = { kind = "reguse_malformed" }
						return nil, errors
					end
					if #lane_names > 0 then
						views[#views + 1] = { names = lane_names, lanes = true }
					end
					inner_pos = duffle.skip_ws_and_cmt(inner, after_struct_braces)
					if inner:sub(inner_pos, inner_pos) == ";" then inner_pos = inner_pos + 1 end

				elseif m_type == "Reg" then
					local m_after = duffle.skip_ws_and_cmt(inner, m_type_end)
					local m_readonly = false
					local maybe_const, maybe_end = duffle.read_ident(inner, m_after)
					if maybe_const == "const" then
						m_readonly = true
						m_after = duffle.skip_ws_and_cmt(inner, maybe_end)
					end
					if not note_readonly(m_readonly) then return nil, errors end
					local names, new_inner = parse_reg_names(inner, m_after)
					if not names or #names == 0 then
						errors[#errors + 1] = { kind = "reguse_malformed" }
						return nil, errors
					end
					views[#views + 1] = { names = names, lanes = false }
					inner_pos = new_inner
				else
					errors[#errors + 1] = { kind = "reguse_malformed" }
					return nil, errors
				end
				::continue_inner::
			end

			local after_close = duffle.skip_ws_and_cmt(body, after_braces)
			local inst_name, inst_end = duffle.read_ident(body, after_close)

			if #views == 0 then
				if not pending then
					errors[#errors + 1] = { kind = "reguse_malformed" }
					return nil, errors
				end
			else
			local has_lanes = false
			for _, v in ipairs(views) do
				if v.lanes then has_lanes = true end
			end

			if has_lanes then
				local width = nil
				for _, v in ipairs(views) do
					if not v.lanes then
						errors[#errors + 1] = { kind = "reguse_malformed" }
						return nil, errors
					end
					if width == nil then
						width = #v.names
					elseif #v.names ~= width then
						errors[#errors + 1] = { kind = "reguse_union_width" }
						return nil, errors
					end
				end
				if width then
					for i = 1, width do
						local slot_name = views[1].names[i]
						if inst_name then slot_name = inst_name .. "." .. slot_name end
						local aliases = {}
						for _, v in ipairs(views) do
							local n = v.names[i]
							if inst_name then n = inst_name .. "." .. n end
							if not add_alias(n, slot_name) then return nil, errors end
							aliases[#aliases + 1] = n
						end
						if not add_slot(slot_name, aliases, union_readonly) then return nil, errors end
					end
				end
			else
				local members = {}
				for _, v in ipairs(views) do
					for _, n in ipairs(v.names) do members[#members + 1] = n end
				end
				local aliases = {}
				local slot_name
				if inst_name then
					slot_name = inst_name
					for _, m in ipairs(members) do
						local path = inst_name .. "." .. m
						if not add_alias(path, slot_name) then return nil, errors end
						aliases[#aliases + 1] = path
					end
				else
					slot_name = members[1]
					for _, m in ipairs(members) do
						if not add_alias(m, slot_name) then return nil, errors end
						aliases[#aliases + 1] = m
					end
				end
				if not add_slot(slot_name, aliases, union_readonly) then return nil, errors end
			end
			end

			if inst_name then after_close = inst_end end
			after_close = duffle.skip_ws_and_cmt(body, after_close)
			if body:sub(after_close, after_close) == ";" then after_close = after_close + 1 end
			pos = after_close
		elseif first == "Reg" or first == "Reg_" then
			local typed_fields = nil
			if first == "Reg_" then
				if body:sub(after, after) ~= "(" then
					errors[#errors + 1] = { kind = "reguse_malformed" }
					return nil, errors
				end
				local type_inner, after_paren = duffle.read_parens(body, after)
				if not type_inner then
					errors[#errors + 1] = { kind = "reguse_malformed" }
					return nil, errors
				end
				local type_ident = duffle.trim(type_inner)
				typed_fields = fields_for_reg_type(type_ident, type_registry)
				if not typed_fields then
					if require_types then
						errors[#errors + 1] = { kind = "reguse_unknown_reg_type", type_name = type_ident }
					else
						pending = true
					end
				end
				after = duffle.skip_ws_and_cmt(body, after_paren)
			end
			local readonly = false
			local maybe_const, maybe_end = duffle.read_ident(body, after)
			if maybe_const == "const" then
				readonly = true
				after = duffle.skip_ws_and_cmt(body, maybe_end)
			end
			local names, new_pos = parse_reg_names(body, after)
			if not names or #names == 0 then
				errors[#errors + 1] = { kind = "reguse_malformed" }
				return nil, errors
			end
			for _, n in ipairs(names) do
				if first == "Reg_" then
					if typed_fields then
						for _, field in ipairs(typed_fields) do
							local path = n .. "." .. field
							if not add_alias(path, path) then return nil, errors end
							if not add_slot(path, { path }, readonly) then return nil, errors end
						end
					end
				else
					if not add_alias(n, n) then return nil, errors end
					if not add_slot(n, { n }, readonly) then return nil, errors end
				end
			end
			pos = new_pos
		else
			errors[#errors + 1] = { kind = "reguse_malformed" }
			return nil, errors
		end
		::continue::
	end
	if #slots == 0 then
		if pending and not require_types then
			return { slots = slots, alias_to_slot = alias_to_slot, pending = true }, errors
		end
		if #errors == 0 then
			errors[#errors + 1] = { kind = "reguse_malformed" }
		end
		return nil, errors
	end
	return { slots = slots, alias_to_slot = alias_to_slot, pending = pending }, errors
end

--- Parse: `typedef` declarations.
---
--- Recognizes four shapes:
---   1. `typedef Struct_(<name>) { <body> } <alias>;` adds to type_name_registry (kind="struct"). 
---       Binds_* aliases also land in out.binds[].
---   2. `typedef Enum_(<underlying>, <name>) { <body> } <alias>;` 
---       Adds to type_name_registry (kind="enum"). 
---   3. `typedef <type> <alias>;` simple typedef alias.
---       Adds to type_name_registry (kind="typedef").
---   4. `typedef <type> TSet_(<name>);` duffle TSet_ convention.
---       Strips TSet_ wrapper; adds to type_name_registry (kind="typedef") with underlying_type=<type>.
---
--- All four shapes also attach an "unrelated" debug-skip marker (the existing behavior — typedef declarations don't carry atom_dbg_skip).
--- @param source    string
--- @param pos       integer
--- @param ident_end integer
--- @param line_of   fun(pos: integer): integer
--- @param out       SourceScan
--- @return          integer
local function parse_typedef_binds(source, pos, ident_end, line_of, out)
	local  after_typedef = duffle.skip_ws_and_cmt(source, ident_end)
	local  id2, id2_end  = duffle.read_ident(source, after_typedef)
	if not id2 then return ident_end end

	-- ── Shape 1: `typedef Struct_(<name>) { <body> } <alias>;` ────────────
	if id2 == "Struct_" then
		local  inner, after_paren, open_paren = read_parens_after(source, id2_end, id2_end)
		if not inner then return id2_end end
		local name = duffle.trim(inner)

		local body, after_brace = find_body_braces(source, after_paren, open_paren + 1)
		if not body then return after_brace end
		register_struct_type(body, name, pos, line_of, out)
		if name:sub(1, 7) == "RegUse_" then
			local schema, schema_errors = parse_reg_use_schema_body(body, out.type_name_registry)
			if schema then
				schema.name        = name
				schema.source_file = out._source_file
				schema.source_line = line_of(pos)
				out.reg_use_schemas[name] = schema
			end
			for _, err in ipairs(schema_errors or {}) do
				err.schema_name = name
				err.source_file = out._source_file
				err.source_line = line_of(pos)
				out.reg_use_errors[#out.reg_use_errors + 1] = err
			end
		end
		attach_debug_skip_marker(out, "unrelated")
		return after_brace

	-- ── Shape 2: `typedef Enum_(<underlying>, <name>) { <body> } <alias>;`
	elseif id2 == "Enum_" then
		local  inner, after_paren, open_paren = read_parens_after(source, id2_end, id2_end)
		if not inner then return id2_end end
		-- Split `inner` on the first top-level comma into (<underlying>, <name>).
		local args = duffle.split_top_level_commas(inner)
		if   #args < 2 then return after_paren end
		local underlying = duffle.trim(args[1])
		local name       = duffle.trim(args[2])

		local  body, after_brace = find_body_braces(source, after_paren, open_paren + 1)
		if not body then return after_brace end
		register_enum_type(underlying, name, body, pos, line_of, out)
		attach_debug_skip_marker(out, "unrelated")
		return after_brace
	end

	-- ── Shapes 3 + 4: `typedef <span> <alias>;`  or
	--                  `typedef <span> TSet_(<name>);`
	--
	-- The <span> between `typedef` and the alias ident may be MULTI-token (e.g. `unsigned char`, `__UINT8_TYPE__`, `const U4`).
	-- The alias is the LAST identifier before `;` (Shape 3), OR the argument of `TSet_(...)` when that wrapper is present (Shape 4).
	--
	-- Two required exact outcomes:
	--   typedef unsigned char UTF8;       -> name=UTF8, underlying="unsigned char"
	--   typedef __UINT8_TYPE__ TSet_(U1); -> name=U1,   underlying="__UINT8_TYPE__"
	--
	-- Algorithm:
	--   1. Find the terminating `;` (BYTE_SEMI). If absent, abort cleanly.
	--   2. If id2 itself is `TSet_`, capture the parenthesized argument and use it as the alias (the preceding underlying span is empty).
	--   3. Otherwise walk idents forward from id2_end to semi_pos: 
	--      - If any ident is `TSet_`, capture its argument as the alias and mark the underlying span as everything from id2 to before TSet_.
	--      - Otherwise remember the last ident (and its source position) as the alias; the underlying span is everything from id2 to before that ident.
	--   4. Trim the underlying span and call register_typedef_alias.
	--
	-- Struct_/Enum_ declarations carry their own dedicated parser paths above; this branch only handles non-Struct_/Enum_ typedefs.

	-- Find the terminating `;` (BYTE_SEMI). If absent, abort cleanly.
	local  semi_pos = duffle.find_byte(source, BYTE_SEMI, id2_end)
	if not semi_pos then return id2_end end

	-- Shape 4 (TSet_ at id2 position): no preceding underlying span.
	if id2 == "TSet_" then
		local  inner, after_paren = read_parens_after(source, id2_end, id2_end)
		if not inner then return id2_end end
		local tset_name = duffle.trim(inner)
		-- Empty underlying span is acceptable; the TSet_ wrapper itself encodes the alias identity (per the duffle TSet_ convention).
		register_typedef_alias("", tset_name, pos, line_of, out)
		attach_debug_skip_marker(out, "unrelated")
		return after_paren
	end

	-- Walk idents forward to find the alias ident (last ident before `;`), or the TSet_(<arg>) form (capture the arg, use it as the alias).
	local last_ident      = nil
	local last_ident_pos  = nil
	local last_ident_end  = nil
	local tset_arg        = nil
	local tset_arg_end    = nil
	local tset_pos        = nil

	local scan = id2_end
	while scan < semi_pos do
		scan = duffle.skip_ws_and_cmt(source, scan)
		if scan >= semi_pos then break end
		local  id, id_end = duffle.read_ident(source, scan)
		if not id then
			scan = scan + 1
		elseif id == "TSet_" then
			-- Shape 4 (TSet_ at non-id2 position): grab the parenthesized argument.
			local inner, after_paren = read_parens_after(source, id_end, id_end)
			if    inner then
				tset_arg     = duffle.trim(inner)
				tset_arg_end = after_paren
				tset_pos     = scan
				scan         = after_paren
			else
				scan = id_end
			end
		else
			last_ident     = id
			last_ident_pos = scan
			last_ident_end = id_end
			scan           = id_end
		end
	end

	if tset_arg then
		-- Shape 4: alias is the TSet_ argument; the underlying span is the trimmed text from the start of id2 up to (but not including) the TSet_ ident.
		local underlying_span = source:sub(after_typedef, tset_pos - 1)
		local underlying      = duffle.trim(underlying_span)
		register_typedef_alias(underlying, tset_arg, pos, line_of, out)
		attach_debug_skip_marker(out, "unrelated")
		return tset_arg_end or (semi_pos + 1)
	end

	if last_ident then
		-- Shape 3: alias is the last ident before `;`; the underlying span is the trimmed text from the start of id2 up to (but not including) the alias ident.
		local underlying_span = source:sub(after_typedef, last_ident_pos - 1)
		local underlying      = duffle.trim(underlying_span)
		register_typedef_alias(underlying, last_ident, pos, line_of, out)
		attach_debug_skip_marker(out, "unrelated")
		return last_ident_end
	end

	-- Malformed: id2 with no following ident before `;`. Skip past the terminating semicolon and let the main loop continue.
	return semi_pos + 1
end

--- Parse: `_Pragma("mac_X tape_atom words=N")` (operator form).
--- @param source    string
--- @param pos       integer
--- @param ident_end integer
--- @param line_of   fun(pos: integer): integer
--- @param out       SourceScan
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

-- Parse the value side of an enum entry.
-- Accepts integer literals (decimal/negative/hex), `R_*_Code` symbol references resolved via `out._code_macros`,
-- AND bare `R_*` symbols that map to an `R_*_Code` variant in the registry.
-- The bare-`R_*` fallback is needed for the lottes_tape.h wave-context aliases whose enum RHS is the bare register ident (e.g. `R_TapePtr = R_T8 atom_reg`);
-- The `R_*_Code` form holds the GPR code and resolves across sources through the chain walker.
-- Returns (value, end_pos) on success or (nil, pos) if unresolvable.
local function parse_enum_value(body, pos, out)
	local int_val, int_end = parse_enum_int_literal(body, pos)
	if    int_val ~= nil then return int_val, int_end end

	local  sym = duffle.read_ident(body, pos)
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

	-- Capture the trailing C-comment (if any) before `skip_ws_and_cmt` discards it.
	-- The `atom_auto_reg(<scope>, <sym>)` macro expands to `R_<Sym> = R_<Sym>_Code /* atom_auto_reg: <scope> */`,
	-- so the scope name lives in the comment after the RHS value. Routes through `out.atom_entry_comments`
	-- for downstream `parse_enum` to split into `out.atom_auto_regs` / `out.phase_auto_regs`.
	local trailing_cmt = read_trailing_cmt_after(body, value_end)
	if trailing_cmt then
		out.atom_entry_comments = out.atom_entry_comments or {}
		out.atom_entry_comments[entry_name] = trailing_cmt
	end

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
				-- In-enum `atom_auto_reg(<scope>, R_<Sym>)` / `phase_auto_reg(<scope>, R_<Sym>)` markers:
				-- the C preprocessor expands them to `R_<Sym> = R_<Sym>_Code /* atom_auto_reg: <scope> */`,
				-- but the metaprogram reads source-as-written so we must dispatch the parser here too.
				-- Mirrors the top-level `DECL_PARSERS` entry for `atom_auto_reg` / `phase_auto_reg`.
				if entry_name == "atom_auto_reg" or entry_name == "phase_auto_reg" then
					local new_pos = parse_auto_reg_marker(body, pos, name_end, line_of, out)
					if new_pos > pos then pos = new_pos else pos = name_end end
				else
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

	-- Route `atom_auto_reg:` / `phase_auto_reg:` markers discovered in trailing C-comments
	-- into the per-source `atom_auto_regs` / `phase_auto_regs` projections.
	-- Pattern matches the RHS expansion `R_<Sym> = R_<Sym>_Code /* <kind>_auto_reg: <scope> */`
	-- emitted by the `atom_auto_reg` / `phase_auto_reg` macros in dsl.atom.h.
	for entry_name, cmt_text in pairs(out.atom_entry_comments or {}) do
		local atom_scope = cmt_text:match("atom_auto_reg:%s*([%w_]+)")
		if atom_scope then
			out.atom_auto_regs = out.atom_auto_regs or {}
			out.atom_auto_regs[atom_scope] = out.atom_auto_regs[atom_scope] or {}
			out.atom_auto_regs[atom_scope][entry_name] = entry_name
		end
		local phase_scope = cmt_text:match("phase_auto_reg:%s*([%w_]+)")
		if phase_scope then
			out.phase_auto_regs = out.phase_auto_regs or {}
			out.phase_auto_regs[phase_scope] = out.phase_auto_regs[phase_scope] or {}
			out.phase_auto_regs[phase_scope][entry_name] = entry_name
		end
	end

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
	MipsAtom_                  = parse_decl_form,
	MipsAtom_Proc_             = parse_decl_form,
	MipsAtomComp_              = parse_decl_form,
	MipsAtomComp_Proc_         = parse_decl_form,
	MipsAtomComp_ProcMap_     = parse_decl_form,
	-- `atom_dbg_skip` is the only debug-skip parser entry. Every other
	-- identifier follows the ordinary unrelated-token path; there is no alias.
	atom_dbg_skip              = parse_dbg_skip_marker,
	atom_dbg_reg_default       = parse_atom_dbg_reg_default,
	-- `atom_auto_reg(atom, R_<Sym>)` and `phase_auto_reg(phase, R_<Sym>)` populate per-source
	-- `out.atom_auto_regs` / `out.phase_auto_regs`; the cross-source merge lands in
	-- `corpus.atom_auto_regs` / `corpus.phase_auto_regs` (first-wins).
	atom_auto_reg              = parse_auto_reg_marker,
	phase_auto_reg             = parse_auto_reg_marker,
	MipsCode                   = parse_mips_code,
	typedef                    = parse_typedef_binds,
	_Pragma                    = parse_pragma_macro,
	-- `enum [<tag>] { <body> }` populates `out.register_alias_registry`.
	enum                       = parse_enum,
}

-- Only the bare `atom_dbg_skip` marker reaches `parse_dbg_skip_marker`.
-- Unknown identifiers follow the same unrelated-token path as every other unsupported source token.

local function tape_skip_ident(ident)
	return ident and (DECL_FORMS[ident] or ident == "Struct_" or ident == "Enum_")
end

local function collect_addrs_assigns_REMOVED(text)
	local addrs = {}
	local pos = 1
	local n = #text
	while pos <= n do
		pos = duffle.skip_ws_and_cmt(text, pos)
		if pos > n then break end
		local ident, ident_end = duffle.read_ident(text, pos)
		if ident == "addrs" then
			local after = duffle.skip_ws_and_cmt(text, ident_end)
			if text:sub(after, after) == "[" then
				local inner, after_br = duffle.read_brackets(text, after)
				local idx = inner and tonumber(duffle.trim(inner))
				after_br = duffle.skip_ws_and_cmt(text, after_br or after)
				if idx and text:sub(after_br, after_br) == "=" then
					local rhs = duffle.skip_ws_and_cmt(text, after_br + 1)
					local rhs_ident = duffle.read_ident(text, rhs)
					if rhs_ident then addrs[idx] = rhs_ident end
					pos = rhs
				else
					pos = after_br or (after + 1)
				end
			else
				pos = ident_end
			end
		elseif ident then
			pos = ident_end
		else
			pos = pos + 1
		end
	end
	return addrs
end

local function collect_tb_emits(body, addrs)
	local names = {}
	local pos = 1
	local n = #body
	while pos <= n do
		pos = duffle.skip_ws_and_cmt(body, pos)
		if pos > n then break end
		local ident, ident_end = duffle.read_ident(body, pos)
		if ident == "tb_emit_" or ident == "tb_emit" then
			local after = duffle.skip_ws_and_cmt(body, ident_end)
			if body:sub(after, after) == "(" then
				local inner, after_p = duffle.read_parens(body, after)
				local name
				if ident == "tb_emit_" then
					name = duffle.trim(inner or ""):match("^([%w_]+)")
				else
					local args = duffle.split_top_level_commas(inner or "")
					local last = duffle.trim(args[#args] or "")
					local idx = last:match("^addrs%s*%[%s*(%d+)%s*%]$")
					if idx then
						name = addrs[tonumber(idx)]
					else
						name = last:match("([%w_]+)$")
					end
				end
				if name then names[#names + 1] = name end
				pos = after_p or (after + 1)
			else
				pos = ident_end
			end
		elseif ident then
			pos = ident_end
		else
			pos = pos + 1
		end
	end
	return names
end

-- Linear appearance order of tb_emit / tb_emit_ in each C function body.
-- Commented-out emits are skipped by skip_ws_and_cmt. No C if/loop CFG.
local function scan_tape_chains(source)
	local addrs = collect_addrs_assigns(source)
	local chains = {}
	local pos = 1
	local n = #source
	while pos <= n do
		pos = duffle.skip_ws_and_cmt(source, pos)
		if pos > n then break end
		local ident, ident_end = duffle.read_ident(source, pos)
		if tape_skip_ident(ident) then
			local after = duffle.skip_ws_and_cmt(source, ident_end)
			if source:sub(after, after) == "(" then
				local _, after_p = duffle.read_parens(source, after)
				after = duffle.skip_ws_and_cmt(source, after_p or after)
			end
			if source:sub(after, after) == "{" then
				local _, after_b = duffle.read_braces(source, after)
				pos = after_b or (after + 1)
			else
				pos = after
			end
		elseif ident then
			local after = duffle.skip_ws_and_cmt(source, ident_end)
			if source:sub(after, after) == "(" then
				local _, after_p = duffle.read_parens(source, after)
				after = duffle.skip_ws_and_cmt(source, after_p or after)
				if source:sub(after, after) == "{" then
					local body, after_b = duffle.read_braces(source, after)
					local names = collect_tb_emits(body or "", addrs)
					if #names > 0 then
						chains[#chains + 1] = names
					end
					pos = after_b or (after + 1)
				else
					pos = after
				end
			else
				pos = ident_end
			end
		else
			pos = pos + 1
		end
	end
	return chains
end

-- ════════════════════════════════════════════════════════════════════════════
-- The single source walker
-- ════════════════════════════════════════════════════════════════════════════

--- Single-pass source scan. Walks the source ONCE and extracts every construct type the metaprogram passes need.
--- Returns a fat SourceScan table. Each pass filters from this payload instead of re-walking the source.
--- @param source string
--- @param source_file string|nil       -- absolute source path (forwarded into AliasEntry.source_file)
--- @param code_macros table|nil        -- cross-source `R_*_Code` registry; nil = local-only
--- @param code_macro_bodies table|nil  -- cross-source raw RHS body table; nil = local-only
--- @return table  -- SourceScan { atoms, raw_atoms, binds, atom_infos, macros, debug_skip_markers, line_of, register_alias_registry, _code_macros, _code_macro_bodies }
local function scan_source(source, source_file, code_macros, code_macro_bodies)
	local line_of = duffle.LineIndex(source)
	local out     = {
		atoms             = {},
		raw_atoms         = {},
		binds             = {},
		atom_infos        = {},
		component_atom_infos = {},
		macros            = {},
		-- Raw marker evidence for annotation validation. The `debug_skip` boolean
		-- is stamped on the declaration record itself; the projection lives on AtomEntry.debug_skip.
		debug_skip_markers = {},
		types             = {},
		atom_views        = {},
		-- Per-source projection for `atom_auto_reg(<atom>, R_<Sym>)` markers.
		-- Each entry is keyed by atom_name; the inner table maps `R_<Sym>` -> `R_<Sym>` (raw LHS sym).
		-- Merged cross-source into `corpus.atom_auto_regs` (first-wins).
		atom_auto_regs    = {},
		-- Per-source projection for `phase_auto_reg(<phase>, R_<Sym>)` markers.
		-- Each entry is keyed by phase_label; the inner table maps `R_<Sym>` -> `R_<Sym>` (raw LHS sym).
		-- Merged cross-source into `corpus.phase_auto_regs` (first-wins).
		phase_auto_regs   = {},
		line_of           = line_of,
		-- Source-derived register-alias registry (atom_reg opt-in entries).
		-- Keys are full R_* idents (never stripped); see parse_enum / parse_enum_body.
		register_alias_registry = {},
		-- Source-derived type-name registry.
		-- Populated from `typedef Struct_(...)`, `typedef Enum_(...)`, `typedef <type> <alias>`, and `typedef <type> TSet_(<name>)` declarations.
		-- The propagation pass at the end of `scan_source()` resolves byte_size via the builtin map,
		-- typedef chain walking (cycle-guarded, depth <= 8), and struct field sums.
		-- See `propagate_type_sizes()` below.
		type_name_registry = {},
		reg_use_schemas    = {},
		tape_chains        = {},
		_addrs             = {},
		_chain             = nil,
		_brace_depth       = 0,
		reg_use_errors     = {},
		-- Shared `R_*_Code -> integer code` registry
		-- (passed in from M.run pass 1; same reference so preprocessor intercept writes are visible to the enum-value resolver).
		-- Stripped from `src.scan` before return.
		_code_macros       = code_macros or {},
		-- Shared raw RHS body table (passed in from M.run pass 1a;
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
			-- Resolve `#define R_*_Code <int-or-symbol>` into the shared `_code_macros` registry before skipping the line.
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
					elseif ident == "addrs" then
						local after = duffle.skip_ws_and_cmt(source, ident_end)
						if source:sub(after, after) == "[" then
							local inner, after_br = duffle.read_brackets(source, after)
							local idx = inner and tonumber(duffle.trim(inner))
							after_br = duffle.skip_ws_and_cmt(source, after_br or after)
							if idx and source:sub(after_br, after_br) == "=" then
								local rhs = duffle.skip_ws_and_cmt(source, after_br + 1)
								local rhs_ident = duffle.read_ident(source, rhs)
								if rhs_ident then out._addrs[idx] = rhs_ident end
								pos = rhs
							else
								pos = after_br or (after + 1)
							end
						else
							pos = ident_end
						end
					elseif ident == "tb_emit_" or ident == "tb_emit" then
						local after = duffle.skip_ws_and_cmt(source, ident_end)
						if source:sub(after, after) == "(" then
							local inner, after_p = duffle.read_parens(source, after)
							local name
							if ident == "tb_emit_" then
								name = duffle.trim(inner or ""):match("^([%w_]+)")
							else
								local args = duffle.split_top_level_commas(inner or "")
								local last = duffle.trim(args[#args] or "")
								local idx = last:match("^addrs%s*%[%s*(%d+)%s*%]$")
								if idx then
									name = out._addrs[tonumber(idx)]
								else
									name = last:match("([%w_]+)$")
								end
							end
							if name then
								out._chain = out._chain or {}
								out._chain[#out._chain + 1] = name
							end
							pos = after_p or (after + 1)
						else
							pos = ident_end
						end
					else
						-- Unsupported identifiers follow the unrelated-token path. If a
						-- pending marker is still open, consume it so it cannot drift to a
						-- later declaration. Unsupported identifiers never create marker records.
						local markers = out.debug_skip_markers
						local marker  = markers[#markers]
						if marker and marker.pending then
							if ident == "FI_" then
								marker.proc_prelude = true
							elseif not marker.proc_prelude then
								attach_debug_skip_marker(out, "unrelated")
							end
						end
						pos = ident_end
					end
				else
					local markers = out.debug_skip_markers
					local marker  = markers[#markers]
					local c = source:sub(pos, pos)
					if marker and marker.pending and marker.proc_prelude then
						if c == "{" or c == ";" then
							attach_debug_skip_marker(out, "unrelated")
						end
					end
					if c == "{" then
						out._brace_depth = out._brace_depth + 1
					elseif c == "}" then
						if out._brace_depth == 1 and out._chain and #out._chain > 0 then
							out.tape_chains[#out.tape_chains + 1] = out._chain
						end
						out._chain = nil
						out._brace_depth = out._brace_depth - 1
						if out._brace_depth < 0 then out._brace_depth = 0 end
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
	if out._chain and #out._chain > 0 then
		out.tape_chains[#out.tape_chains + 1] = out._chain
	end
	out._addrs = nil
	out._chain = nil
	out._brace_depth = nil

	return out
end

-- ════════════════════════════════════════════════════════════════════════════
-- Corpus merge — first-wins lookup identity + typed collisions
-- ════════════════════════════════════════════════════════════════════════════
-- These helpers run ONCE per `M.run` invocation, after every per-source scan has attached `src.scan`.
-- They merge per-source scans into the `ctx.shared.corpus.*` registries.
-- `src.scan` keeps the source-local projection for the duration of the run; the cross-source visibility lives on `corpus`.

-- Build a deterministic site record (path + line) from a per-source entry.
-- Falls back to the placeholder when an entry lacks a recorded source file or line.
local function build_site(path, line)
	return { path = path or "?", line = line or 0 }
end

-- Compute a deterministic shape signature for an AliasEntry (register_alias_registry).
-- Two alias declarations are "identical" iff they resolve to the same shape: 
--   code (integer) + default_type + default_depth + pointer_depth + has_atom_reg.
local function alias_shape(entry)
	if type(entry) ~= "table" then return "" end
	return string.format("code=%s;default=%s/%s;depth=%s;atom_reg=%s",
		tostring(entry.code),
		tostring(entry.default_type or ""),
		tostring(entry.default_depth or 0),
		tostring(entry.pointer_depth or 0),
		tostring(entry.has_atom_reg and 1 or 0))
end

-- Compute a deterministic shape signature for a type-name registry entry.
-- struct:  serialized fields (name:type:depth, in declaration order)
-- enum:    serialized fields (name=value, declaration order)
-- typedef: The underlying_type string
local function type_shape(entry)
	if type(entry) ~= "table" then return "" end
	if entry.kind == "struct" then
		local fields = entry.fields or {}
		local parts  = {}
		for _, f in ipairs(fields) do
			parts[#parts + 1] = string.format("%s:%s*%s",
				tostring(f.name), tostring(f.type_name), tostring(f.pointer_depth or 0))
		end
		return "struct[" .. table.concat(parts, ",") .. "]"
	elseif entry.kind == "enum" then
		local fields = entry.fields or {}
		local parts  = {}
		for _, f in ipairs(fields) do
			parts[#parts + 1] = string.format("%s=%s", tostring(f.name), tostring(f.value))
		end
		return "enum[" .. table.concat(parts, ",") .. "]"
	elseif entry.kind == "typedef" then
		return "typedef[" .. tostring(entry.underlying_type or "") .. "]"
	end
	return "?"
end

-- Compute a deterministic shape signature for a Binds_* entry (Struct_ projection).
-- Binds_* entries come from scan.binds[] (per-source array) with `{line, name, fields, body, bytes}`;
-- They share the same `fields` layout as the matching struct entry in `type_name_registry`, so the shape is the struct-field serialization.
-- The `kind` field is absent here, so the struct branch of `type_shape` would misfire; we serialize the fields directly.
local function bind_shape(entry)
	if type(entry) ~= "table" then return "" end
	local fields = entry.fields or {}
	local parts  = {}
	for _, f in ipairs(fields) do
		parts[#parts + 1] = string.format("%s:%s*%s",
			tostring(f.name), tostring(f.type_name), tostring(f.pointer_depth or 0))
	end
	return "struct[" .. table.concat(parts, ",") .. "]"
end

-- Compute a deterministic shape signature for an AtomEntry.
-- The "kind + body" pair uniquely identifies the same declaration when re-encountered.
-- `body` is the brace-delimited body text.
local function atom_shape(entry)
	if type(entry) ~= "table" then return "" end
	return string.format("kind=%s;body=%s",
		tostring(entry.kind or ""), tostring(entry.body or ""))
end

-- Compute a deterministic shape signature for an AtomViewEntry.
-- Two views are identical iff they bind the same Binds_X with the same reg overrides.
local function view_shape(entry)
	if type(entry) ~= "table" then return "" end
	local overrides = entry.reg_type_overrides or {}
	local keys = {}
	for k in pairs(overrides) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	local parts = {}
	for _, k in ipairs(keys) do
		local ov = overrides[k]
		parts[#parts + 1] = string.format("%s=%s*%s", tostring(k),
			tostring(ov.type_name), tostring(ov.pointer_depth or 0))
	end
	return string.format("binds=%s;overrides=[%s]",
		tostring(entry.binds_name or ""), table.concat(parts, ","))
end

-- Compute a deterministic shape signature for an AtomCtxEntry.
local function ctx_shape(entry)
	if type(entry) ~= "table" then return "" end
	return "rbind=" .. tostring(entry.rbind_atom or "")
end

-- Compute a deterministic shape signature for an AtomPhaseGroup.
-- The atoms list is compared as a SET (sorted) so that two declarations of `atom_phase(setup)` with atoms = [A] vs atoms = [B]
-- are DIFFERENT shapes (first-wins + collision), while atoms = [A,B] vs atoms = [B,A] are considered identical (and coalesce).
local function phase_shape(entry)
	if type(entry) ~= "table" then return "" end
	local atoms = entry.atoms or {}
	local sorted = {}
	for _, a in ipairs(atoms) do sorted[#sorted + 1] = a end
	table.sort(sorted)
	return "atoms=[" .. table.concat(sorted, ",") .. "]"
end

-- Merge a new declaration site into a registry following the first-wins discipline.
-- * first declaration:    Entry becomes the corpus entry (entry.sites initialized).
-- * identical subsequent: Append the new site to entry.sites.
-- * conflicting shape:    Keep first entry, append ONE typed collision record with shape diff.
local function merge_named_with_sites(registry, name, new_entry, site, collisions, kind, shape_fn)
	if registry[name] == nil then
		registry[name] = new_entry
		registry[name].sites = { site }
		return
	end
	local existing  = registry[name]
	local new_shape = shape_fn(new_entry)
	local old_shape = shape_fn(existing)
	if new_shape == old_shape and new_shape ~= "" then
		-- Identical shape: coalesce by appending the site.
		existing.sites = existing.sites or { build_site(existing.source_file, existing.source_line) }
		existing.sites[#existing.sites + 1] = site
		return
	end
	-- Conflicting shape: first-wins; record exactly one typed collision.
	collisions[#collisions + 1] = {
		kind              = kind,
		name              = name,
		first_site        = existing.sites and existing.sites[1]
			or build_site(existing.source_file, existing.source_line),
		conflicting_site  = site,
		first_shape       = old_shape,
		conflicting_shape = new_shape,
	}
end

-- Merge per-source scans into the corpus registries.
-- Iterates `corpus.source_order` (not `ctx.sources`).
-- Each source owns only its `src.scan`; the corpus owns the cross-source lookup tables.
local function merge_corpus_registries(corpus)
	-- Ensure every expected corpus table exists (the fixture_ctx seeds most of these,
	-- but a barebones corpus from build_ctx should also be safe).
	corpus.register_alias_registry = corpus.register_alias_registry or {}
	corpus.type_name_registry      = corpus.type_name_registry      or {}
	corpus.binds_by_name           = corpus.binds_by_name           or {}
	corpus.atoms_by_name           = corpus.atoms_by_name           or {}
	corpus.atom_views              = corpus.atom_views              or {}
	corpus.atom_ctxs               = corpus.atom_ctxs               or {}
	corpus.atom_phases             = corpus.atom_phases             or {}
	corpus.atom_infos              = corpus.atom_infos              or {}
	corpus.component_atom_infos    = corpus.component_atom_infos    or {}
	corpus.atom_auto_regs          = corpus.atom_auto_regs          or {}
	corpus.phase_auto_regs         = corpus.phase_auto_regs         or {}
	corpus.collisions              = corpus.collisions              or {}
	corpus.reg_use_schemas         = corpus.reg_use_schemas         or {}
	corpus.reg_use_errors          = corpus.reg_use_errors          or {}
	corpus.tape_chains             = corpus.tape_chains             or {}

	-- Replace the existing corpus collections with empty tables so a re-run on the same corpus produces identical state (deterministic merge).
	-- This is safe because M.run is the only writer to these tables within a single orchestrator invocation.
	for _, key in ipairs({
		"register_alias_registry", "type_name_registry", "binds_by_name",
		"atoms_by_name", "atom_views", "atom_ctxs", "atom_phases",
		"atom_infos", "component_atom_infos", "collisions", "reg_use_schemas", "reg_use_errors",
		"tape_chains",
	}) do
		corpus[key] = {}
	end

	for _, src in ipairs(corpus.source_order or {}) do
		local scan = src.scan
		if scan then
			local path = src.path
			-- register_alias_registry: keyed by R_* alias ident.
			-- Each AliasEntry carries `source_file` (set by scan_source to the path).
			for name, entry in pairs(scan.register_alias_registry or {}) do
				local site = build_site(entry.source_file or path, entry.source_line)
				merge_named_with_sites(
					corpus.register_alias_registry, name, entry, site,
					corpus.collisions, "alias", alias_shape)
			end

			-- type_name_registry: keyed by type ident; covers Struct_/Enum_/typedef.
			for name, entry in pairs(scan.type_name_registry or {}) do
				local site = build_site(path, entry.source_line)
				merge_named_with_sites(
					corpus.type_name_registry, name, entry, site,
					corpus.collisions, "type", type_shape)
			end

			-- binds_by_name: the Binds_* projection of Struct_ types.
			-- Sources populate scan.binds[] (per-source array) with `{line, name, fields, body}`.
			-- We merge by name (Binds_X) so cross-source Struct_(X) declarations can be coalesced or collided.
			for _, bind_entry in ipairs(scan.binds or {}) do
				local site = build_site(path, bind_entry.line)
				merge_named_with_sites(
					corpus.binds_by_name, bind_entry.name, bind_entry, site,
					corpus.collisions, "binds", bind_shape)
			end

			-- atoms_by_name: MipsAtom_(name) + MipsAtom_Proc_(name) + MipsAtomComp_(name) + MipsAtomComp_Proc_(name).
			-- Each atom carries `{line, name, body, body_off, kind, raw_name, ...}`.
			-- Duplicate atom names across sources are first-wins + collision; see the atom_infos block below for the evidence list.
			for _, atom_entry in ipairs(scan.atoms or {}) do
				local site = build_site(path, atom_entry.line)
				merge_named_with_sites(
					corpus.atoms_by_name, atom_entry.name, atom_entry, site,
					corpus.collisions, "atom", atom_shape)
			end

			-- atom_views: keyed by atom_name; each carries `binds_name` + per-atom overrides.
			for name, entry in pairs(scan.atom_views or {}) do
				local site = build_site(path, entry.info_line)
				merge_named_with_sites(
					corpus.atom_views, name, entry, site,
					corpus.collisions, "view", view_shape)
			end

			-- atom_ctxs: keyed by atom_name; each carries `rbind_atom`.
			for name, entry in pairs(scan.atom_ctxs or {}) do
				local site = build_site(path, entry.info_line)
				merge_named_with_sites(
					corpus.atom_ctxs, name, entry, site,
					corpus.collisions, "ctx", ctx_shape)
			end

			-- atom_phases: keyed by phase label; each carries `atoms = [...]`.
			-- The phase atoms list is set-shaped for the collision discipline (phase_shape sorts atoms before comparing).
			for name, entry in pairs(scan.atom_phases or {}) do
				local site = build_site(path, 0)
				merge_named_with_sites(
					corpus.atom_phases, name, entry, site,
					corpus.collisions, "phase", phase_shape)
			end

			-- atom_auto_regs: keyed by atom scope name; each carries a `{R_<Sym> = R_<Sym>}` map.
			-- Per-source entries are simple inner maps (no body / no shape comparison); first-wins suffices.
			for atom_scope, syms in pairs(scan.atom_auto_regs or {}) do
				if corpus.atom_auto_regs[atom_scope] == nil then
					corpus.atom_auto_regs[atom_scope] = syms
				end
			end

			-- phase_auto_regs: keyed by phase label; each carries a `{R_<Sym> = R_<Sym>}` map.
			-- Per-source entries are simple inner maps (no body / no shape comparison); first-wins suffices.
			for phase_label, syms in pairs(scan.phase_auto_regs or {}) do
				if corpus.phase_auto_regs[phase_label] == nil then
					corpus.phase_auto_regs[phase_label] = syms
				end
			end

			-- atom_infos: ALWAYS append every record in source/declaration order.
			-- Duplicates are preserved so the annotation pass can flag them via `check_unique_annotation`;
			-- The merge is purely order-preserving.
			for _, info in ipairs(scan.atom_infos or {}) do
				corpus.atom_infos[#corpus.atom_infos + 1] = info
			end
			for _, info in ipairs(scan.component_atom_infos or {}) do
				corpus.component_atom_infos[#corpus.component_atom_infos + 1] = info
			end

			for name, schema in pairs(scan.reg_use_schemas or {}) do
				if corpus.reg_use_schemas[name] == nil then
					corpus.reg_use_schemas[name] = schema
				end
			end
			for _, err in ipairs(scan.reg_use_errors or {}) do
				corpus.reg_use_errors[#corpus.reg_use_errors + 1] = err
			end
			for _, chain in ipairs(scan.tape_chains or {}) do
				corpus.tape_chains[#corpus.tape_chains + 1] = chain
			end
		end
	end
end

local SCHEMA_BODY_ERROR = {
	reguse_malformed          = true,
	reguse_unknown_reg_type   = true,
	reguse_duplicate_alias    = true,
	reguse_duplicate_slot     = true,
	reguse_const_reg_spelling = true,
	reguse_mixed_const        = true,
	reguse_union_width        = true,
}

-- Re-parse every RegUse_* body against the merged type_name_registry.
-- Scan-time expansion still runs when Reg_T is in the same source.
-- Missing Reg_T after merge is reguse_unknown_reg_type, not a fallback table.
local function resolve_reg_use_schemas(corpus)
	local kept = {}
	for _, err in ipairs(corpus.reg_use_errors or {}) do
		if not SCHEMA_BODY_ERROR[err.kind] then
			kept[#kept + 1] = err
		end
	end
	corpus.reg_use_errors = kept

	for name, type_entry in pairs(corpus.type_name_registry or {}) do
		if name:sub(1, 7) == "RegUse_" and type_entry.body then
			local fresh, errs = parse_reg_use_schema_body(
				type_entry.body, corpus.type_name_registry, { require_types = true })
			if fresh then
				fresh.name = name
				local old = corpus.reg_use_schemas[name]
				fresh.source_file = (old and old.source_file) or type_entry.source_file
				fresh.source_line = (old and old.source_line) or type_entry.source_line
				corpus.reg_use_schemas[name] = fresh
			else
				corpus.reg_use_schemas[name] = nil
			end
			for _, err in ipairs(errs or {}) do
				err.schema_name = name
				err.source_file = type_entry.source_file
				err.source_line = type_entry.source_line
				corpus.reg_use_errors[#corpus.reg_use_errors + 1] = err
			end
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
-- M — module exports
-- ════════════════════════════════════════════════════════════════════════════

--- @class M

local M = {}

--- Walk each source once and attach the fat SourceScan payload to `src.scan`.
--- No output files; this is a pure in-memory pre-processing pass.
---
--- Runs in 5 phases.
---   Resolve: Source order from `ctx.shared.corpus.source_order` (the corpus owns it; the check below enforces the invariant).
---   Pass 1a: `scan_source_pre_pass` over every source, populating LOCAL `code_macros` AND LOCAL `code_macro_bodies` tables.
---            The bodies table holds the raw post-`=` text of every `#define R_*_Code` line (cross-source) 
---            so the chain walker can fall back when the defining `#define` lives in a different source than the chain call site.
---   Pass 1b: Resolve every collected macro's chain using the bodies table as fallback.
---            This fills in `code_macros` entries whose defining source was scanned AFTER the call site (e.g. lottes_tape.h's `R_TapePtr_Code -> R_T8_Code` chain into mips.h's `R_T8_Code = 24`).
---   Pass 2:  The full `scan_source(source, source_file, code_macros, code_macro_bodies)` walk per source. The per-source `src.scan` payload includes the source-local registries
---            (register_alias_registry, type_name_registry, atom_views, atom_ctxs, atom_phases, binds, atoms, atom_infos, ...).
---   Strip:   Strip `src.scan._code_macros`, `src.scan._code_macro_bodies`, and the `_source_file` pointer.
---            The LOCAL tables `code_macros` and `code_macro_bodies` stay confined to this function; they go out of scope on return.
---   Merge:   Iterate `ctx.shared.corpus.source_order` in declared order. For every source's local registry, first-wins lookup identity (entry from the first declaration site becomes the corpus entry);
---            identical shapes coalesce by appending the declaration site; conflicting shapes keep the first lookup entry and append ONE typed collision record with shape diff.
---            Populate `register_alias_registry`, `type_name_registry`, `binds_by_name`, `atoms_by_name`, `atom_views`, `atom_ctxs`, `atom_phases`.
---            `atom_infos` ALWAYS appends every record (preserving source order + duplicates for annotation evidence).
---
--- @param ctx PassCtx
--- @return PassResult
function M.run(ctx)
	-- The cross-source _code_macros / _code_macro_bodies tables are LOCAL to this run.
	-- They live across source scans only long enough to resolve cross-source R_*_Code chains, then go out of scope on M.run return.
	-- The Lua GC reclaims them; nothing here survives onto ctx.shared, ctx.shared.corpus, or any src.scan.
	local code_macros       = {}
	local code_macro_bodies = {}

	-- Canonical-corpus check (see the docstring Resolve phase). The corpus is the only source of source_order.
	ctx.shared = ctx.shared or {}
	local corpus = ctx.shared.corpus
	if not corpus or type(corpus.source_order) ~= "table" then
		error("scan_source.run requires ctx.shared.corpus.source_order (the canonical corpus is the source of truth; no per-source fallback is supported)", 0)
	end
	local sources = corpus.source_order

	-- Pass 1a: collect `_code_macros` + `_code_macro_bodies` across ALL sources.
	for _, src in ipairs(sources) do
		scan_source_pre_pass(src.text, code_macros, code_macro_bodies)
	end

	-- Pass 1b: resolve every collected macro's chain with cross-source fallback.
	-- The bodies table was populated for every `#define R_*_Code` line in pass 1a;
	-- This iteration finishes the chain even when the chain hops span sources
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

	-- Pass 2: run the full scan with the shared `_code_macros` + `_code_macro_bodies` so the enum parser can resolve cross-source
	-- `R_*_Code` references and bare `R_*` symbols via the `_Code` registry fallback.
	-- The private `_code_macros` / `_code_macro_bodies` / `_source_file` strip is midway through `source_order`.
	-- Must not leave earlier sources leaking the private parse state, because a separate post-loop would not run when an exception propagates out of pass 2.
	for _, src in ipairs(sources) do
		src.scan = scan_source(src.text, src.path, code_macros, code_macro_bodies)
		-- Strip the three private fields immediately so a later fatal source does not leave this source leaking parse state.
		-- The shared `code_macros` / `code_macro_bodies` locals remain in the outer scope and keep their contents for subsequent sources.
		if src.scan then
			src.scan._code_macros       = nil
			src.scan._code_macro_bodies = nil
			src.scan._source_file       = nil
		end
		-- Pre-tokenize each atom body once (plex: cache lives in duffle.lua; downstream passes read from `atom.body_tokens` instead of calling `split_top_level_commas` / `tokenize_body` independently).
		-- Re-access is O(1) thanks to the memoization.
		for _, atom in ipairs(src.scan.atoms)           do atom.body_tokens = duffle.tokenize_body(atom.body) end
		for _, atom in ipairs(src.scan.raw_atoms or {}) do atom.body_tokens = duffle.tokenize_body(atom.body) end
	end

	-- Merge per-source scans into the corpus registries (see merge_corpus_registries for first-wins + collision discipline).
	merge_corpus_registries(corpus)
	resolve_reg_use_schemas(corpus)

	-- code_macros and code_macro_bodies are function-local; the GC reclaims them on M.run return.
	return { outputs = {}, errors = {}, warnings = {} }
end

return M
