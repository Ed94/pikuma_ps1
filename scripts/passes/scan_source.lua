--- passes/scan_source.lua — Source pre-scan pass (the "mega entity" pass).
---
--- Single source-walk pass that produces the fat `SourceScan` payload consumed by all downstream passes. Walks each `ctx.sources` entry once,
--- extracting every construct type the metaprograms need:
---
---   MipsAtom_              (kind = "atom", with optional atom_info inner)
---   MipsAtomComp_          (kind = "comp_bare")
---   MipsAtomComp_Proc_     (kind = "comp_proc", body inside last {})
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
--- @field line_of    fun(pos: integer): integer  -- shared LineIndex closure

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

-- Parse the sub-calls inside `atom_info(atom_bind(...), atom_reads(...), atom_writes(...))`.
-- Returns (binds, reads, writes).
local function scan_atom_info_subcalls(info_inner)
	local binds, reads, writes = nil, nil, nil
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
		else
			sub_pos = sub_end
		end
	end
	return binds, reads, writes
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
--   out       -- the SourceScan out table (mutated in place: out.atoms / out.raw_atoms / out.binds / out.atom_infos / out.macros)
--   returns   -- new position after the construct
--
-- All parsers read source-as-written via the duffle primitives (skip_ws_and_cmt / read_parens / read_braces / read_balanced).
-- No regex per the no_regex constraint; no hand-rolled depth tracking (the MipsAtomComp_Proc_ brace matcher
-- now uses duffle.read_braces instead of bespoke byte-dispatch).
--
-- Adding a new construct = 1 row in DECL_PARSERS + 1 parser function. The scan_source() loop never needs editing.

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
			local ai_binds, ai_reads, ai_writes = scan_atom_info_subcalls(info_inner)
			out.atom_infos[#out.atom_infos + 1] = {
				atom_name = raw_name or "?", binds = ai_binds,
				reads     = ai_reads or {}, writes = ai_writes or {},
				info_line = line_of(lookahead),
			}
			brace_search_pos = info_after
		end
	end

	local brace = duffle.scan_to_char(source, "{", brace_search_pos)
	if not brace then return open_paren + 1 end

	local body, after_brace = duffle.read_braces(source, brace)
	if raw_name and raw_name ~= "" then
		out.atoms[#out.atoms + 1] = {
			line        = line_of(pos), name = raw_name, body = body, body_off = brace + 1,
			kind        = "atom", raw_name = raw_name,
			ident_pos   = pos, after_paren = after_paren,
		}
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

	out.atoms[#out.atoms + 1] = {
		line        = line_of(pos), name = strip_ac_prefix(raw_name), body = body, body_off = brace + 1,
		kind        = "comp_bare", raw_name = raw_name,
		ident_pos   = pos, after_paren = after_paren,
	}

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
	-- Position of body[1] in source = open_paren + 1 (start of inner) + last_brace_pos + 1 (past '{').
	local body_off = open_paren + 2 + last_brace_pos

	out.atoms[#out.atoms + 1] = {
		line        = line_of(pos), name = strip_ac_prefix(raw_name), body = body, body_off = body_off,
		kind        = "comp_proc", raw_name = raw_name,
		ident_pos   = pos, after_paren = after_paren,
	}

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
	out.raw_atoms[#out.raw_atoms + 1] = {
		line      = line_of(pos), name = atom_name, body = body, body_off = brace_pos + 1,
		kind      = "raw_atom", raw_name = atom_name,
	}

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
	MipsAtom_          = parse_mips_atom,
	MipsAtomComp_      = parse_mips_atom_comp,
	MipsAtomComp_Proc_ = parse_mips_atom_comp_proc,
	MipsCode           = parse_mips_code,
	typedef            = parse_typedef_binds,
	_Pragma            = parse_pragma_macro,
	pragma             = parse_pragma_dummy,
}

-- ════════════════════════════════════════════════════════════════════════════
-- The single source walker
-- ════════════════════════════════════════════════════════════════════════════

--- Single-pass source scan. Walks the source ONCE and extracts every construct type the metaprogram passes need.
--- Returns a fat SourceScan table. Each pass filters from this payload instead of re-walking the source.
--- @param source string
--- @return table  -- SourceScan { atoms, raw_atoms, binds, atom_infos, macros, line_of }
local function scan_source(source)
	local line_of = duffle.LineIndex(source)
	local out     = {
		atoms      = {},
		raw_atoms  = {},
		binds      = {},
		atom_infos = {},
		macros     = {},
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
						-- Unrecognized ident — advance past it.
						pos = ident_end
					end
				else
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
