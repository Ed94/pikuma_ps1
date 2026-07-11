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
--- **Conventions**: tabs (1/level), EmmyLua annotations, no regex,
--- Lua 5.3 compatible.

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
--- @field macros     MacroEntry[]    -- #pragma mac_X tape_atom words=N  +  _Pragma("...")
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
-- Local helpers
-- ════════════════════════════════════════════════════════════════════════════

-- C qualifier keywords that may precede a MipsAtom_ / MipsCode declaration.
-- (typedef is NOT a qualifier here — it's a separate construct (`typedef Struct_(Binds_X) { ... };`)
-- and must be read as an ident so the typedef check below can match it.)
local QUALIFIER_KEYWORDS = {
	["static"]   = true, ["const"] = true, ["volatile"] = true, ["extern"] = true,
	["register"] = true, ["auto"]  = true, ["inline"]   = true,
	["internal"] = true, ["LP_"]   = true, ["global"]   = true, ["gkknown"] = true,
}

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
				byte_off = byte_off + 4
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
				binds = duffle.trim(sub_inner)
				sub_pos = sub_after2
			else
				sub_pos = sub_open + 1
			end
		elseif sub_ident == "atom_reads" or sub_ident == "atom_writes" then
			local kind = sub_ident
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
-- The single source walker
-- ════════════════════════════════════════════════════════════════════════════

--- Single-pass source scan. Walks the source ONCE and extracts every construct type the metaprogram passes need.
--- Returns a fat SourceScan table. Each pass filters from this payload instead of re-walking the source.
--- @param source string
--- @return table  -- SourceScan { atoms, raw_atoms, binds, atom_infos, macros, line_of }
local function scan_source(source)
	local line_of = duffle.LineIndex(source)
	local atoms       = {}
	local raw_atoms   = {}
	local binds       = {}
	local atom_infos  = {}
	local macros      = {}
	local pos         = 1
	local src_len     = #source

	while pos <= src_len do
		pos = duffle.skip_ws_and_cmt(source, pos)
		if pos > src_len then break end

		-- Skip preprocessor directives (#define / #include / #pragma / etc).
		-- _Pragma is an operator (not a directive) — it doesn't start with #.
		local pp_pos = duffle.skip_preprocessor_line(source, pos)
		if pp_pos then pos = pp_pos; goto continue end

		-- Skip C qualifiers (static, const, etc.) that may precede a declaration.
		pos = scan_skip_qualifiers(source, pos)
		if pos > src_len then break end

		local ident, ident_end = duffle.read_ident(source, pos)
		-- scan: <ident>
		if not ident then pos = pos + 1; goto continue end

		-- ── MipsAtom_ / MipsAtomComp_ / MipsAtomComp_Proc_ ──
		if ident == "MipsAtom_" or ident == "MipsAtomComp_" or ident == "MipsAtomComp_Proc_" then
			local is_atom = ident == "MipsAtom_"
			local is_comp = ident == "MipsAtomComp_"
			local is_proc = ident == "MipsAtomComp_Proc_"
			local kind = is_atom and "atom" or (is_comp and "comp_bare" or "comp_proc")
			local open_paren = duffle.skip_ws_and_cmt(source, ident_end)
			if source:sub(open_paren, open_paren) ~= "(" then pos = open_paren + 1; goto continue end

			local inner, after_paren = duffle.read_parens(source, open_paren)
			-- scan: <ident>(<args>)

			if is_proc then
				-- MipsAtomComp_Proc_(name, { body }) — body is inside the LAST { } in args.
				local last_brace_pos
				for search_pos = #inner, 1, -1 do
					if inner:sub(search_pos, search_pos) == "{" then last_brace_pos = search_pos; break end
				end
				if last_brace_pos then
					local depth = 1
					local inner_pos = last_brace_pos + 1
					while inner_pos <= #inner and depth > 0 do
						local c = inner:byte(inner_pos)
						if c == 123 then depth = depth + 1; inner_pos = inner_pos + 1
						elseif c == 125 then depth = depth - 1; if depth == 0 then break end; inner_pos = inner_pos + 1
						elseif c == 40 then local _, a = duffle.read_parens(inner, inner_pos); inner_pos = a
						elseif c == 91 then local _, a = duffle.read_brackets(inner, inner_pos); inner_pos = a
						elseif c == 34 or c == 39 then inner_pos = duffle.skip_str_or_cmt(inner, inner_pos) + 1
						else inner_pos = inner_pos + 1 end
					end
					if depth == 0 then
						-- scan: <ident>(<name>, { <body> })
						local name_match = inner:match("^%s*([%w_]+)")
						local raw_name = name_match or "?"
						-- Strip "ac_" prefix for component names (components pass convention).
						local name = raw_name
						if #raw_name > 3 and raw_name:sub(1, 3) == "ac_" then
							name = raw_name:sub(4)
						end
						local body = inner:sub(last_brace_pos + 1, inner_pos - 1)
						local body_off = open_paren + 1 + last_brace_pos
						atoms[#atoms + 1] = {
							line = line_of(pos), name = name, body = body, body_off = body_off + 1,
							kind = kind, raw_name = raw_name,
							ident_pos = pos, after_paren = after_paren,
							args = nil, comment = nil,
						}
					end
				end
				pos = after_paren
			else
				-- MipsAtom_(name) { body }  OR  MipsAtomComp_(name) { body }
				local name_start = 1
				while name_start <= #inner and inner:sub(name_start, name_start):match("[%s]") do name_start = name_start + 1 end
				local name_end = name_start
				while name_end <= #inner and inner:sub(name_end, name_end):match("[%w_]") do name_end = name_end + 1 end
				local raw_name = inner:sub(name_start, name_end - 1)
				-- scan: <ident>(<name>)
				if raw_name ~= "" then
					local brace = duffle.scan_to_char(source, "{", after_paren)
					-- scan: <ident>(<name>) {
					if brace then
						local body, after_brace = duffle.read_braces(source, brace)
						-- scan: <ident>(<name>) { <body> }
						-- Strip "ac_" prefix for component names (components pass convention).
						local disp_name = raw_name
						if is_comp and #raw_name > 3 and raw_name:sub(1, 3) == "ac_" then
							disp_name = raw_name:sub(4)
						end
						atoms[#atoms + 1] = {
							line = line_of(pos), name = disp_name, body = body, body_off = brace + 1,
							kind = kind, raw_name = raw_name,
							ident_pos = pos, after_paren = after_paren,
							args = nil, comment = nil,
						}
						pos = after_brace
					else
						pos = open_paren + 1
					end
				else
					pos = open_paren + 1
				end
			end

			-- For MipsAtom_ entries: check if atom_info(...) follows.
			if is_atom then
				local lookahead = duffle.skip_ws_and_cmt(source, after_paren)
				local look_ident, look_end = duffle.read_ident(source, lookahead)
				-- scan: MipsAtom_(<name>) <look_ident>
				if look_ident == "atom_info" then
					local info_open = duffle.skip_ws_and_cmt(source, look_end)
					if source:sub(info_open, info_open) == "(" then
						local info_inner, info_after = duffle.read_parens(source, info_open)
						-- scan: MipsAtom_(<name>) atom_info(<binds>, <reads>, <writes>)
						-- Find the atom name from the just-parsed atom entry (last one added).
						local last_atom = atoms[#atoms]
						local atom_name = last_atom and last_atom.raw_name or "?"
						local ai_binds, ai_reads, ai_writes = scan_atom_info_subcalls(info_inner)
						atom_infos[#atom_infos + 1] = {
							atom_name = atom_name, binds = ai_binds,
							reads = ai_reads or {}, writes = ai_writes or {},
							info_line = line_of(lookahead),
						}
						-- Don't advance pos past info_after — the body { ... } still needs to be skipped
						-- by the brace scan below. But if there's no body (forward decl), advance.
						local body_brace = duffle.scan_to_char(source, "{", info_after)
						if body_brace then
							local _, after_body = duffle.read_braces(source, body_brace)
							pos = after_body
						else
							pos = info_after
						end
					end
				end
			end
			goto continue
		end

		-- ── MipsCode code_<name> { body } (raw atom form — offsets pass only) ──
		if ident == "MipsCode" then
			local next_pos = duffle.skip_ws_and_cmt(source, ident_end)
			local next_ident, next_after = duffle.read_ident(source, next_pos)
			-- scan: MipsCode <next_ident>
			if next_ident and #next_ident > 5 and next_ident:sub(1, 5) == "code_" then
				local atom_name = next_ident:sub(6)
				-- scan: MipsCode code_<name>
				local brace_pos = duffle.scan_to_char(source, "{", next_after)
				-- scan: MipsCode code_<name> {
				if brace_pos then
					local body, after_brace = duffle.read_braces(source, brace_pos)
					-- scan: MipsCode code_<name> { <body> }
					raw_atoms[#raw_atoms + 1] = {
						line = line_of(pos), name = atom_name, body = body, body_off = brace_pos + 1,
						kind = "raw_atom", raw_name = atom_name,
					}
					pos = after_brace
					goto continue
				end
			end
			pos = ident_end
			goto continue
		end

		-- ── typedef Struct_(Binds_X) { fields } ──
		if ident == "typedef" then
			local after_typedef = duffle.skip_ws_and_cmt(source, ident_end)
			local id2, id2_end = duffle.read_ident(source, after_typedef)
			-- scan: typedef <id2>
			if id2 == "Struct_" then
				local open_paren = duffle.skip_ws_and_cmt(source, id2_end)
				if source:sub(open_paren, open_paren) == "(" then
					local inner, after_paren = duffle.read_parens(source, open_paren)
					-- scan: typedef Struct_(<name>)
					local name = duffle.trim(inner)
					local brace = duffle.scan_to_char(source, "{", after_paren)
					-- scan: typedef Struct_(<name>) {
					if brace then
						local body, after_brace = duffle.read_braces(source, brace)
						-- scan: typedef Struct_(<name>) { <fields> }
						if name:sub(1, 6) == "Binds_" then
							local fields, byte_off = scan_binds_fields(body)
							binds[#binds + 1] = { line = line_of(pos), name = name, fields = fields, bytes = byte_off }
						end
						pos = after_brace
						goto continue
					end
					pos = open_paren + 1
					goto continue
				end
				pos = id2_end or (after_typedef + 1)
				goto continue
			end
			pos = ident_end
			goto continue
		end

		-- ── _Pragma("mac_X tape_atom words=N") (operator form) ──
		if ident == "_Pragma" then
			local open_paren = duffle.skip_ws_and_cmt(source, ident_end)
			if source:sub(open_paren, open_paren) == "(" then
				local str, str_end = duffle.read_parens(source, open_paren)
				-- scan: _Pragma(<string>)
				str = duffle.trim(str)
				if str:sub(1, 1) == '"' and str:sub(-1) == '"' then
					local inner = str:sub(2, -2)
					local space = duffle.find_byte(inner, 32, 1)
					if space then
						local name = inner:sub(1, space - 1)
						local rest = inner:sub(space + 1)
						local eq = duffle.find_byte(rest, 61, 1)
						if eq then
							local key = duffle.trim(rest:sub(1, eq - 1))
							local val = duffle.trim(rest:sub(eq + 1))
							if key == "tape_atom words" or key == "words" then
								macros[#macros + 1] = { line = line_of(pos), name = name, words = tonumber(val) or 0 }
							end
						end
					end
				end
				pos = str_end
				goto continue
			end
			pos = open_paren + 1
			goto continue
		end

		-- ── #pragma mac_X tape_atom words=N (directive form) ──
		-- (preprocessor skip above handles # lines, but pragma is an ident here
		--  only if it appeared without a leading # — which happens when the
		--  preprocessor skip didn't fire because the # was on a previous line.
		--  The annotation pass handles this via its own skip_preprocessor_line,
		--  but scan_source handles it here by checking the ident.)
		if ident == "pragma" then
			-- This shouldn't normally fire — #pragma lines are skipped by
			-- skip_preprocessor_line above. If we get here, it's a _Pragma
			-- variant or a non-#-prefixed pragma. Just advance.
			pos = ident_end
			goto continue
		end

		-- ── Unrecognized ident — advance past it ──
		pos = ident_end

		::continue::
	end

	return {
		atoms      = atoms,
		raw_atoms  = raw_atoms,
		binds      = binds,
		atom_infos = atom_infos,
		macros     = macros,
		line_of    = line_of,
	}
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
