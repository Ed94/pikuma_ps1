#!/usr/bin/env lua
-- tape_atom_annotation_pass.lua
--
-- Augments tape_atom_offset_gen.lua with the annotation pass:
--
--   1. Parses TAPE_ATOM_ANNOT / TAPE_ATOM_BIND / TAPE_ATOM_SETUP /
--      TAPE_ATOM_COMMIT / TAPE_ATOM_INIT / TAPE_ATOM_TERMINATE lines
--      placed above each MipsAtom_(name) { ... } declaration.
--   2. Parses TAPE_WORDS(mac_X, N) pragmas (the _Pragma form) before
--      each #define mac_X(...) ... macro.
--   3. Parses typedef Struct_(Binds_X) { U4 field1; U4 field2; ... };
--      declarations to extract field names + byte offsets.
--   4. Cross-checks:
--        - TAPE_WORDS(mac_X, N) ↔ WORD_COUNT(mac_X, N) in metadata.h
--        - TAPE_ATOM_BIND(rbind_X, Binds_Y, ...) ↔ Struct_(Binds_Y)
--        - Binds_Y field names ↔ wave-context register aliases
--          (R_PrimCursor / R_FaceCursor / R_VertBase / R_OtBase)
--        - Every atom has exactly one phase annotation
--   5. Reports annotation drift / structural issues.
--
-- Outputs per source:
--   <source_dir>/gen/<basename>.annotations.txt
--
-- And a project-level summary:
--   <first_source_dir>/gen/annotation_validation.txt
--
-- Usage:
--   lua tape_atom_annotation_pass.lua <metadata.h> <source1> [source2 ...]
--
-- This script is meant to be run alongside tape_atom_offset_gen.lua.
-- Same input files, complementary output. Both feed the build.

-- ============================================================
-- Shared primitives (copied from tape_atom_offset_gen.lua so this
-- script can stand alone; if you require() the original instead,
-- these become the original's locals).
-- ============================================================

local function is_space(c) return c == " " or c == "\t" or c == "\n" or c == "\r" or c == "\v" or c == "\f" end
local function is_alpha(c)
	if not c or #c == 0      then return false end
	if c >= "a" and c <= "z" then return true  end
	if c >= "A" and c <= "Z" then return true  end
	return c == "_"
end
local function is_digit(c) return c and c >= "0" and c <= "9" end
local function is_alnum(c) return is_alpha(c) or is_digit(c) end

local function trim(s)
	local a = 1;  while a <= #s and is_space(s:sub(a, a)) do a = a + 1 end
	local b = #s; while b >= a  and is_space(s:sub(b, b)) do b = b - 1 end
	return s:sub(a, b)
end

local function find_byte(haystack, target, start)
	for i = start or 1, #haystack do
		if haystack:sub(i, i) == target then return i end
	end
	return nil
end

local function read_file(path)
	local  f = io.open(path, "r")
	if not f then error("Cannot open " .. path) end
	local content = f:read("*a")
	f:close()
	return content
end

local function write_file(path, content)
	local  f = io.open(path, "w")
	if not f then error("Cannot write " .. path) end
	f:write(content)
	f:close()
end

local function dirname(path)
	local last_sep = 0
	for i = 1, #path do
		local c = path:sub(i, i)
		if c == "/" or c == "\\" then last_sep = i end
	end
	if last_sep == 0 then return "." end
	return path:sub(1, last_sep - 1)
end

local function basename_no_ext(path)
	local last_sep = 0
	for i = 1, #path do
		local c = path:sub(i, i)
		if c == "/" or c == "\\" then last_sep = i end
	end
	local a = last_sep + 1
	local last_dot = #path + 1
	for i = #path, a, -1 do
		if path:sub(i, i) == "." then last_dot = i; break end
	end
	return path:sub(a, last_dot - 1)
end

local function ensure_dir(path)
	local is_win = package.config:sub(1, 1) == "\\"
	os.execute(is_win and ('if not exist "' .. path .. '" mkdir "' .. path .. '"') or ('mkdir -p "' .. path .. '" 2>/dev/null'))
end

-- ============================================================
-- Lexer primitives (mirror the offset-gen tool)
-- ============================================================

local function skip_str_or_cmt(s, i)
	local c = s:sub(i, i)
	if    c == '"' or c == "'" then
		i = i + 1
		while i <= #s do
			if s:sub(i, i) == "\\" then i = i + 2
			elseif s:sub(i, i) == c then return i + 1
			else i = i + 1 end
		end
		return #s + 1
	elseif c == "/" then
		local nx = s:sub(i+1, i+1)
		if nx == "/" then
			while i <= #s and s:sub(i, i) ~= "\n" do i = i + 1 end
			return i
		elseif nx == "*" then
			i = i + 2
			while i <= #s - 1 do
				if s:sub(i, i) == "*" and s:sub(i+1, i+1) == "/" then
					return i + 2
				end
				i = i + 1
			end
			return #s + 1
		end
	end
	return i
end

local function skip_ws_and_cmt(s, i)
	while i <= #s do
		if is_space(s:sub(i, i)) then i = i + 1
		else
			local nx = skip_str_or_cmt(s, i)
			if nx > i then i = nx else break end
		end
	end
	return i
end

local function read_ident(source, i)
	if not is_alpha(source:sub(i, i)) then return nil, i end
	local a = i
	i = i + 1
	while i <= #source and is_alnum(source:sub(i, i)) do i = i + 1 end
	return source:sub(a, i - 1), i
end

local function read_balanced(s, open_char, close_char, i)
	if s:sub(i, i) ~= open_char then return nil, i end
	i = i + 1
	local len   = #s
	local depth = 1
	local a     = i
	while i <= len and depth > 0 do
		local c = s:sub(i, i)
		if c == open_char then
			depth = depth + 1
			i = i + 1
		elseif c == close_char then
			depth = depth - 1
			if depth == 0 then break end
			i = i + 1
		else
			local nx = skip_str_or_cmt(s, i)
			if nx > i then i = nx else i = i + 1 end
		end
	end
	return s:sub(a, i - 1), i + 1
end

local read_parens   = function(s, i) return read_balanced(s, "(", ")", i) end
local read_braces   = function(s, i) return read_balanced(s, "{", "}", i) end
local read_brackets = function(s, i) return read_balanced(s, "[", "]", i) end

local function scan_to_char(s, target, start)
	local i = start
	while i <= #s do
		local c = s:sub(i, i)
		if    c == target then return i end
		if     c == "(" then local _, a = read_balanced(s, "(", ")", i); i = a
		elseif c == "{" then local _, a = read_balanced(s, "{", "}", i); i = a
		elseif c == "[" then local _, a = read_balanced(s, "[", "]", i); i = a
		else
			local nx = skip_str_or_cmt(s, i)
			if nx > i then i = nx else i = i + 1 end
		end
	end
end

-- ============================================================
-- Load WORD_COUNT manifest (mirror of the offset-gen tool)
-- ============================================================

local function load_word_counts(metadata_path)
	local counts  = {}
	local content = read_file(metadata_path)
	local len     = #content
	local i       = 1
	local prefix  = "WORD_COUNT("
	while i <= len do
		local nl       = find_byte(content, "\n", i)
		local line_end = nl or (len + 1)
		local line     = content:sub(i, line_end - 1)
		local trimmed  = trim(line)
		if trimmed:sub(1, #prefix) == prefix and trimmed:sub(-1) == ")" then
			local inner = trimmed:sub(#prefix + 1, #trimmed - 1)
			local comma = find_byte(inner, ",", 1)
			if comma then
				counts[trim(inner:sub(1, comma - 1))] = tonumber(trim(inner:sub(comma + 1)))
			end
		end
		i = line_end + 1
	end
	return counts
end

-- ============================================================
-- Wave-context register aliases
--
-- These are the canonical names of the registers that get bound
-- into the wave by the rbind atoms. The annotation pass uses this
-- table to validate Binds_* struct field names — every field that
-- the bind writes must map to a known wave-context register.
-- ============================================================

local WAVE_CONTEXT_REGS = {
	["R_PrimCursor"]  = { alias = "R_T7", size = 4, role = "output cursor (prim arena)" },
	["R_FaceCursor"]  = { alias = "R_T4", size = 4, role = "input cursor (face array)" },
	["R_VertBase"]    = { alias = "R_T5", size = 4, role = "base pointer (vertex array)" },
	["R_OtBase"]      = { alias = "R_T6", size = 4, role = "base pointer (ordering table)" },
}

-- Macro expansion table: maps source-level macro names to the value they expand
-- to at preprocessing time. Used so the metaprogram can validate annotations
-- against the un-preprocessed source.
local MACRO_EXPANSION = {
	-- phase_* tokens
	["phase_init"]       = "init",
	["phase_bind"]       = "bind",
	["phase_setup"]      = "setup",
	["phase_work"]       = "work",
	["phase_commit"]     = "commit",
	["phase_terminate"]  = "terminate",
	-- region tokens
	["REGION_PRIM_ARENA"]    = "prim_arena",
	["REGION_FACE_ARENA"]    = "face_arena",
	["REGION_VERTEX_ARENA"]  = "vertex_arena",
	["REGION_OT_ARENA"]      = "ot_arena",
	["REGION_HEAP_3D"]       = "heap_3d_models",
	["REGION_CDROM_STREAM"]  = "cdrom_stream",
	["REGION_VRAM"]          = "vram_heap",
	-- cadence tokens
	["CADENCE_FRAME"]        = "frame",
	["CADENCE_ONCE"]         = "once",
	["CADENCE_ONDEMAND"]     = "ondemand",
}

local function valid_phase(p) return KNOWN_PHASES[p] end
local function is_wave_context_reg(name) return WAVE_CONTEXT_REGS[name] ~= nil end

-- ============================================================
-- Parse TAPE_ATOM_ANNOT(...) calls in source
-- ============================================================
--
-- We scan for these top-level macro invocations anywhere in the file.
-- Each call has positional args: name, phase, reads, writes.
-- The reads/writes args are themselves TAPE_REGS(...) calls that we
-- expand to extract the register identifier list.
--
-- Returns a list of {line, name, phase, reads = {...}, writes = {...},
--                       binds = nil-or-string}
-- in source order.
-- ============================================================

local function split_top_level_commas(body)
	local tokens = {}
	local i = 1
	local token_start = 1
	while i <= #body do
		local c = body:sub(i, i)
		if c == "(" then local _, a = read_parens(body, i); i = a
		elseif c == "{" then local _, a = read_braces(body, i); i = a
		elseif c == "[" then local _, a = read_brackets(body, i); i = a
		elseif c == "," then
			table.insert(tokens, body:sub(token_start, i - 1))
			i = i + 1
			token_start = i
		else
			local nx = skip_str_or_cmt(body, i)
			if nx > i then i = nx else i = i + 1 end
		end
	end
	local last = body:sub(token_start)
	if trim(last) ~= "" then table.insert(tokens, last) end
	return tokens
end

local function line_of(source, pos)
	local line = 1
	for i = 1, pos do
		if source:sub(i, i) == "\n" then line = line + 1 end
	end
	return line
end

-- Extract identifier args from a parenthesized group. Returns a list
-- of {kind, value} pairs where kind is one of:
--   "ident"  -- a bare identifier (e.g. TAPE_PHASE_WORK)
--   "regs"   -- a TAPE_REGS(...) call whose args are extracted as a list
--   "other"  -- something we can't classify (preserved as text)
local function parse_atom_annot_args(inner)
	-- Split at top-level commas, respecting nested parens.
	local args = {}
	local tokens = split_top_level_commas(inner)
	for _, tok in ipairs(tokens) do
		local s = trim(tok)
		if s ~= "" then
			-- TAPE_REGS(...) → extract inner identifiers
			if s:sub(1, 10) == "TAPE_REGS(" and s:sub(-1) == ")" then
				local regs_inner = s:sub(11, -2)
				local regs = {}
				for r in regs_inner:gmatch("[^,]+") do
					local trimmed = trim(r)
					if trimmed ~= "" then table.insert(regs, trimmed) end
				end
				table.insert(args, {kind = "regs", value = regs})
			else
				-- Bare identifier (e.g. TAPE_PHASE_WORK)
				local id, _ = read_ident(s, 1)
				if id and trim(s) == id then
					table.insert(args, {kind = "ident", value = id})
				else
					table.insert(args, {kind = "other", value = s})
				end
			end
		end
	end
	return args
end

local TAPE_ATOM_MACROS = {
	["atom_annot"]     = { kind = "work",     binds = false },
	["atom_bind"]      = { kind = "bind",     binds = true  },
	["atom_setup"]     = { kind = "setup",    binds = false },
	["atom_commit"]    = { kind = "commit",   binds = false },
	["atom_init"]      = { kind = "init",     binds = false },
	["atom_terminate"] = { kind = "terminate",binds = false },
}

-- Phase token names (must match macros in tape_atom_dsl.h)
local KNOWN_PHASES = {
	["init"] = true, ["bind"] = true, ["setup"] = true,
	["work"] = true, ["commit"] = true, ["terminate"] = true,
}

-- Region token names (must match REGION_* macros in tape_atom_dsl.h)
local KNOWN_REGIONS = {
	["prim_arena"] = true, ["face_arena"] = true, ["vertex_arena"] = true,
	["ot_arena"]   = true, ["heap_3d_models"] = true, ["cdrom_stream"] = true,
	["vram_heap"]  = true,
}

-- Cadence token names (must match CADENCE_* macros in tape_atom_dsl.h)
local KNOWN_CADENCES = {
	["frame"] = true, ["once"] = true, ["ondemand"] = true,
}

-- Valid pragmas (must match atom_* macros that emit `_Pragma(...)` in tape_atom_dsl.h)
local ATOM_PRAGMA_KINDS = {
	["resource"] = { kind = "string" },
	["region"]   = { kind = "ident",  allowed = KNOWN_REGIONS },
	["group"]    = { kind = "ident"  },
	["cadence"]  = { kind = "ident",  allowed = KNOWN_CADENCES },
	["async"]    = { kind = "ident",  allowed = { ["true"] = true, ["false"] = true } },
}

local function find_atom_annotations(source)
	local annots = {}
	local len = #source
	local i   = 1
	while i <= len do
		i = skip_ws_and_cmt(source, i); if i > len then break end
		-- Match the leading identifier of a TAPE_ATOM_* macro.
		local ident, after = read_ident(source, i)
		if not ident then
			i = i + 1
		elseif TAPE_ATOM_MACROS[ident] then
			local open = skip_ws_and_cmt(source, after)
			if source:sub(open, open) == "(" then
				local inner, after_paren = read_parens(source, open)
				local args = parse_atom_annot_args(inner)
				local macro_def = TAPE_ATOM_MACROS[ident]

				if #args < 1 then
					table.insert(annots, {
						line = line_of(source, i),
						macro = ident,
						kind  = macro_def.kind,
						error = "missing atom name (first arg)"
					})
				else
					local name = args[1].value
					-- For TAPE_ATOM_BIND: arg layout is (name, Binds_Struct, writes)
					-- For others:          (name, phase, reads, writes)
					-- INIT / TERMINATE:    (name)
					local entry = {
						line    = line_of(source, i),
						macro   = ident,
						name    = name,
						kind    = macro_def.kind,
						binds   = nil,
						phase   = nil,
						reads   = {},
						writes  = {},
					}
					if macro_def.binds then
						-- (name, Binds_Struct, writes)
						if #args >= 2 and args[2].kind == "ident" then
							entry.binds = args[2].value
						end
						if #args >= 3 and args[3].kind == "regs" then
							entry.writes = args[3].value
						end
					elseif ident == "TAPE_ATOM_INIT" or ident == "TAPE_ATOM_TERMINATE" then
						-- (name) — no phase, no reads/writes to extract
					elseif ident == "TAPE_ATOM_SETUP" then
						-- (name, reads)
						if #args >= 2 and args[2].kind == "regs" then
							entry.reads = args[2].value
						end
					elseif ident == "TAPE_ATOM_COMMIT" then
						-- (name, reads)
						if #args >= 2 and args[2].kind == "regs" then
							entry.reads = args[2].value
						end
					elseif ident == "TAPE_ATOM_ANNOT" then
						-- (name, phase, reads, writes)
						if #args >= 2 and args[2].kind == "ident" then
							-- Expand TAPE_PHASE_* macro references
							local phase_id = args[2].value
							entry.phase = MACRO_EXPANSION[phase_id] or phase_id
						end
						if #args >= 3 and args[3].kind == "regs" then
							entry.reads = args[3].value
						end
						if #args >= 4 and args[4].kind == "regs" then
							entry.writes = args[4].value
						end
					end
					table.insert(annots, entry)
				end
				i = after_paren
			else
				i = open + 1
			end
		else
			i = after
		end
	end
	return annots
end

-- ============================================================
-- Parse TAPE_WORDS(mac_X, N) pragma directives
--
-- Either form is acceptable:
--   _Pragma("mac_X tape_atom words=N")     (operator form)
--   #pragma mac_X tape_atom words=N        (directive form)
--
-- We extract (mac_name, n).
-- ============================================================

local function find_macro_word_annotations(source)
	local out = {}
	local len = #source
	local i   = 1
	while i <= len do
		i = skip_ws_and_cmt(source, i); if i > len then break end
		-- Skip preprocessor directives (lines starting with #).
		-- read_ident doesn't recognize '#' so without this guard we'd
		-- infinite-loop on `#ifdef` / `#pragma region` / etc.
		if source:sub(i, i) == "#" then
			local j = i
			while j <= len and source:sub(j, j) ~= "\n" do j = j + 1 end
			i = j + 1
		else
			local ident, after = read_ident(source, i)
			if not ident then
				i = i + 1
			elseif ident == "_Pragma" then
				local open = skip_ws_and_cmt(source, after)
				if source:sub(open, open) == "(" then
					local str, str_end = read_parens(source, open)
					-- str is a parenthesized string literal; strip parens, then quotes
					str = trim(str)
					if str:sub(1, 1) == '"' and str:sub(-1) == '"' then
						local inner = str:sub(2, -2)
						-- Expect "<mac_name> tape_atom words=<n>"
						local space = find_byte(inner, " ", 1)
						if space then
							local name = inner:sub(1, space - 1)
							local rest = inner:sub(space + 1)
							local eq = find_byte(rest, "=", 1)
							if eq then
								local key  = trim(rest:sub(1, eq - 1))
								local val  = trim(rest:sub(eq + 1))
								if key == "tape_atom words" then
									-- key is "tape_atom words"; val is "<n>"
									local n = tonumber(val) or 0
									table.insert(out, {
										line = line_of(source, i),
										name = name,
										words = n,
									})
								elseif key == "words" then
									-- Tolerate "mac_X words=N" if someone writes it that way
									local n = tonumber(val) or 0
									table.insert(out, {
										line = line_of(source, i),
										name = name,
										words = n,
									})
								end
							end
						end
					end
					i = str_end
				else
					i = open + 1
				end
			elseif ident == "pragma" then
				-- Directive form: `#pragma mac_X tape_atom words=N`
				local rest_start = skip_ws_and_cmt(source, after)
				-- Read the rest of the line (no #pragma content spans lines)
				local j = rest_start
				while j <= len and source:sub(j, j) ~= "\n" do j = j + 1 end
				local line_text = trim(source:sub(rest_start, j - 1))
				-- tokenize
				local tokens = {}
				for tok in line_text:gmatch("%S+") do table.insert(tokens, tok) end
				if #tokens >= 4 and tokens[2] == "tape_atom" and tokens[3] == "words=*" or
				   (#tokens >= 3 and tokens[2] == "words=") then
					-- handled below in two forms
				end
				if #tokens >= 3 and tokens[2] == "tape_atom" and tokens[3]:sub(1, 6) == "words=" then
					local name = tokens[1]
					local n    = tonumber(tokens[3]:sub(7)) or 0
					table.insert(out, { line = line_of(source, i), name = name, words = n })
				elseif #tokens >= 2 and tokens[2]:sub(1, 6) == "words=" then
					local name = tokens[1]
					local n    = tonumber(tokens[2]:sub(7)) or 0
					table.insert(out, { line = line_of(source, i), name = name, words = n })
				end
				i = j
			else
				i = after
			end
		end
	end
	return out
end

-- ============================================================
-- Parse `atom_<...>` Pragma / _Pragma annotations
--
-- Two source-level forms are accepted:
--
--   Macro form (preferred — what tape_atom_dsl.h provides):
--       atom_resource(cube_tri, "model_ship_cube")
--       atom_region  (cube_tri, REGION_PRIM_ARENA)
--       atom_group   (cube_tri, GROUP_RENDER_PRIMS)
--       atom_cadence (cube_tri, CADENCE_FRAME)
--       atom_async   (cube_tri, false)
--
--   Directive form (raw — what _Pragma expands to):
--       _Pragma("atom cube_tri resource=model_ship_cube")
--       _Pragma("atom cube_tri region=prim_arena")
--       _Pragma("atom cube_tri group=GROUP_RENDER_PRIMS")
--       _Pragma("atom cube_tri cadence=frame")
--       _Pragma("atom cube_tri async=false")
--
-- Returns: {
--   { line, name, attrs = {key = value_string, ...} },
--   ...
-- }
--
-- The two forms are normalized to the same internal representation
-- so downstream validation doesn't need to care about which form was used.
-- ============================================================

-- Map: macro name → pragma key
local ATOM_ATTR_MACROS = {
	["atom_resource"] = "resource",
	["atom_region"]   = "region",
	["atom_group"]    = "group",
	["atom_cadence"]  = "cadence",
	["atom_async"]    = "async",
}

-- Parse macro form: `atom_<key>(atom_name, value, ...)`.
-- Returns (true, entry, str_end) on success, (false) on no match.
-- The entry has shape { line, name, attrs = {key = value} }.
local function try_parse_atom_attr_macro(source, i)
	local ident, after = read_ident(source, i)
	if not ident then return false end
	local key = ATOM_ATTR_MACROS[ident]
	if not key then return false end
	local open = skip_ws_and_cmt(source, after)
	if source:sub(open, open) ~= "(" then return false end

	-- Read parenthesized arg list.
	local body, body_end = read_parens(source, open)
	-- First arg = atom_name
	local first, after_name = read_ident(body, 1)
	if not first then return false end

	-- Skip whitespace, expect ",", skip whitespace to reach value.
	local j = after_name
	while j <= #body and is_space(body:sub(j, j)) do j = j + 1 end
	if body:sub(j, j) ~= "," then return false end
	j = j + 1
	while j <= #body and is_space(body:sub(j, j)) do j = j + 1 end

	-- Value parser. Accepts either:
	--   - string literal: "..." (preserves inner text verbatim)
	--   - bare identifier or macro name (resolved via MACRO_EXPANSION)
	local value
	if body:sub(j, j) == '"' then
		-- find matching closing quote (handle \" escapes)
		local k = j + 1
		while k <= #body do
			local c = body:sub(k, k)
			if c == "\\" then
				k = k + 2
			elseif c == '"' then
				break
			else
				k = k + 1
			end
		end
		if body:sub(k, k) ~= '"' then return false end
		value = body:sub(j + 1, k - 1)
	else
		local id2, after_id = read_ident(body, j)
		if not id2 then return false end
		value = id2
		if MACRO_EXPANSION[value] then value = MACRO_EXPANSION[value] end
	end

	return true, {
		line  = line_of(source, i),
		name  = first,
		attrs = { [key] = value },
	}, body_end
end

local function find_atom_pragmas(source)
	local out = {}
	local len = #source
	local i   = 1
	while i <= len do
		i = skip_ws_and_cmt(source, i); if i > len then break end
		if source:sub(i, i) == "#" then
			local j = i
			while j <= len and source:sub(j, j) ~= "\n" do j = j + 1 end
			i = j + 1
		else
			local got, entry, next_i = try_parse_atom_attr_macro(source, i)
			if got then
				table.insert(out, entry)
				i = next_i
			else
				local ident, after = read_ident(source, i)
				if not ident then
					i = i + 1
				elseif ident == "_Pragma" then
					local open = skip_ws_and_cmt(source, after)
					if source:sub(open, open) == "(" then
						local str, str_end = read_parens(source, open)
						str = trim(str)
						if str:sub(1, 1) == '"' and str:sub(-1) == '"' then
							local inner = str:sub(2, -2)
							-- Expect: "atom <name> <k>=<v> [<k>=<v> ...]"
							local sp1 = find_byte(inner, " ", 1)
							if sp1 and trim(inner:sub(1, sp1 - 1)) == "atom" then
								local rest = trim(inner:sub(sp1 + 1))
								local sp2 = find_byte(rest, " ", 1)
								if sp2 then
									local name = trim(rest:sub(1, sp2 - 1))
									local attrs_str = trim(rest:sub(sp2 + 1))
									local attrs = {}
									local got_any = false
									for pair in attrs_str:gmatch("%S+") do
										local eq = find_byte(pair, "=", 1)
										if eq then
											local k = trim(pair:sub(1, eq - 1))
											local v = trim(pair:sub(eq + 1))
											if MACRO_EXPANSION[v] then v = MACRO_EXPANSION[v] end
											attrs[k] = v
											got_any = true
										end
									end
									if got_any then
										table.insert(out, {
											line  = line_of(source, i),
											name  = name,
											attrs = attrs,
										})
									end
								end
							end
						end
						i = str_end
					else
						i = open + 1
					end
				else
					i = after
				end
			end
		end
	end
	return out
end


-- ============================================================
-- Parse `typedef Struct_(Binds_X) { ... };` declarations
-- ============================================================
--
-- Returns a list of {line, name, fields = {{name, byte_offset}, ...}}
-- ============================================================

local function find_binds_structs(source)
	local out = {}
	local len = #source
	local i   = 1
	while i <= len do
		i = skip_ws_and_cmt(source, i); if i > len then break end
		-- Skip preprocessor directives (lines starting with #).
		if source:sub(i, i) == "#" then
			local j = i
			while j <= len and source:sub(j, j) ~= "\n" do j = j + 1 end
			i = j + 1
		else
			local ident, after = read_ident(source, i)
			if not ident then
				i = i + 1
			elseif ident == "typedef" then
				local j = skip_ws_and_cmt(source, after)
				local id2, after2 = read_ident(source, j)
				if id2 ~= "Struct_" then
					i = after2 or (j + 1)
				elseif id2 == "Struct_" then
					local open = skip_ws_and_cmt(source, after2)
					if source:sub(open, open) == "(" then
						local inner, after_paren = read_parens(source, open)
						local name = trim(inner)
						local brace = scan_to_char(source, "{", after_paren)
						if brace then
							local body, after_brace = read_braces(source, brace)
							local fields = {}
							local byte_off = 0
							local k = 1
							while k <= #body do
								k = skip_ws_and_cmt(body, k); if k > #body then break end
								local tid, tafter = read_ident(body, k)
								if not tid then
									k = k + 1
								elseif tid == "U4" then
									local fid, fafter = read_ident(body, skip_ws_and_cmt(body, tafter))
									if fid then
										table.insert(fields, { name = fid, offset = byte_off })
										byte_off = byte_off + 4
									end
									k = fafter or tafter + 1
								else
									k = tafter + 1
								end
							end
							-- Only emit Binds_* structs (skip FMipsAtom512, MipsAtomBuilder, etc.)
							if name:sub(1, 6) == "Binds_" then
							table.insert(out, {
								line   = line_of(source, i),
								name   = name,
								fields = fields,
								bytes  = byte_off,
							})
							end
							i = after_brace
						else
							i = open + 1
						end
					else
						i = open + 1
					end
				else
					i = after2 or (j + 1)
				end
			else
				i = after
			end
		end
	end
	return out
end

-- ============================================================
-- Find every MipsAtom_(name) { ... } declaration in source
-- (so we can pair annotations → atoms and check coverage)
-- ============================================================

local function find_atom_names(source)
	local out  = {}
	local len  = #source
	local i    = 1
	while i <= len do
		i = skip_ws_and_cmt(source, i); if i > len then break end
		local ident, after = read_ident(source, i)
		if not ident then
			i = i + 1
		elseif ident == "MipsAtom_" then
			local open = skip_ws_and_cmt(source, after)
			if source:sub(open, open) == "(" then
				local inner, after_paren = read_parens(source, open)
				local a = 1
				while a <= #inner and is_space(inner:sub(a, a)) do a = a + 1 end
				local b = a
				while b <= #inner and is_alnum(inner:sub(b, b)) do b = b + 1 end
				local name = inner:sub(a, b - 1)
				if name ~= "" then
					table.insert(out, { line = line_of(source, i), name = name })
				end
				local brace = scan_to_char(source, "{", after_paren)
				if brace then
					local _, after_brace = read_braces(source, brace)
					i = after_brace
				else
					i = open + 1
				end
			else
				i = open + 1
			end
		else
			i = after
		end
	end
	return out
end

-- ============================================================
-- Validation
-- ============================================================

local function validate(source_path, word_counts)
	local source = read_file(source_path)

	local annots  = find_atom_annotations(source)
	local macros  = find_macro_word_annotations(source)
	local pragmas = find_atom_pragmas(source)
	local binds   = find_binds_structs(source)
	local atoms   = find_atom_names(source)

	-- Index for O(1) lookup
	local atom_index = {}
	for _, a in ipairs(atoms) do atom_index[a.name] = a end

	local binds_index = {}
	for _, b in ipairs(binds) do binds_index[b.name] = b end

	local errors   = {}
	local warnings = {}
	local info     = {}

	-- 1. Every annotated atom must exist as a real MipsAtom_ declaration.
	for _, a in ipairs(annots) do
		if a.error then
			table.insert(errors, {line = a.line, msg = a.error})
		elseif not atom_index[a.name] then
			table.insert(errors, {
				line = a.line,
				msg  = string.format("annotation for '%s' has no matching MipsAtom_(%s) { ... }", a.name, a.name)
			})
		end
	end

	-- 2. Every atom must have exactly one annotation (no orphans, no duplicates).
	local count_per_atom = {}
	for _, a in ipairs(annots) do
		if a.name and not a.error then
			count_per_atom[a.name] = (count_per_atom[a.name] or 0) + 1
		end
	end
	for _, atom in ipairs(atoms) do
		local n = count_per_atom[atom.name] or 0
		if n == 0 then
			table.insert(warnings, {
				line = atom.line,
				msg  = string.format("MipsAtom_(%s) has no TAPE_ATOM_* annotation", atom.name)
			})
		elseif n > 1 then
			table.insert(errors, {
				line = atom.line,
				msg  = string.format("MipsAtom_(%s) has %d annotations (expected 1)", atom.name, n)
			})
		end
	end

	-- 3. Phase validity.
	for _, a in ipairs(annots) do
		if a.name and not a.error and a.phase and not valid_phase(a.phase) then
			table.insert(errors, {
				line = a.line,
				msg  = string.format("'%s' has unknown phase '%s' (expected one of init/bind/setup/work/commit/terminate)", a.name, a.phase)
			})
		end
	end

	-- 4. BIND atoms must reference a real Binds_* struct.
	for _, a in ipairs(annots) do
		if a.binds then
			if not binds_index[a.binds] then
				table.insert(errors, {
					line = a.line,
					msg  = string.format("'%s' binds '%s' but no Struct_(%s) { ... } declaration found", a.name, a.binds, a.binds)
				})
			end
		end
	end

	-- 5. BIND writes must be wave-context registers that match Binds_ fields.
	for _, a in ipairs(annots) do
		if a.binds and binds_index[a.binds] then
			local bs = binds_index[a.binds]
			local field_names = {}
			for _, f in ipairs(bs.fields) do field_names[f.name] = true end

			-- Binds_ field names should match wave-context registers.
			-- Convention: field name == register name minus the "R_" prefix and
			-- "Cursor"/"Base" suffix mapped to canonical names.
			-- We accept either direct match (rare) or a simple "R_" prefix.
			for _, f in ipairs(bs.fields) do
				local candidate = "R_" .. f.name
				if not is_wave_context_reg(candidate) then
					table.insert(warnings, {
						line = bs.line,
						msg  = string.format("%s field '%s' doesn't match a known wave-context register (candidate '%s')", a.binds, f.name, candidate)
					})
				end
			end

			-- Bind writes must all be wave-context registers.
			for _, w in ipairs(a.writes) do
				if not is_wave_context_reg(w) then
					table.insert(warnings, {
						line = a.line,
						msg  = string.format("%s writes '%s' which is not a known wave-context register", a.name, w)
					})
				end
			end
		end
	end

	-- 6. WORK reads should be a subset of BIND writes (the wave contract).
	--    We can't see tape emission sites here, but we can warn when a WORK
	--    atom reads a register that no BIND atom writes.
	for _, a in ipairs(annots) do
		if a.kind == "work" then
			for _, r in ipairs(a.reads) do
				if not is_wave_context_reg(r) and r ~= "R_TapePtr" then
					table.insert(warnings, {
						line = a.line,
						msg  = string.format("work atom '%s' reads '%s' which is not a known wave-context register", a.name, r)
					})
				end
			end
		end
	end

	-- 7. TAPE_WORDS(mac_X, N) ↔ WORD_COUNT(mac_X, N) drift.
	for _, m in ipairs(macros) do
		local declared = word_counts[m.name]
		if not declared then
			table.insert(errors, {
				line = m.line,
				msg  = string.format("TAPE_WORDS(%s, %d) but '%s' is not in metadata.h", m.name, m.words, m.name)
			})
		elseif declared ~= m.words then
			table.insert(errors, {
				line = m.line,
				msg  = string.format("DRIFT: TAPE_WORDS(%s, %d) but metadata.h declares WORD_COUNT(%s, %d)", m.name, m.words, m.name, declared)
			})
		else
			table.insert(info, {
				line = m.line,
				msg  = string.format("OK: %s = %d words", m.name, m.words)
			})
		end
	end

	-- 8. atom_<...> _Pragma validation: resource/region/group/cadence/async
	for _, p in ipairs(pragmas) do
		-- Validate the atom name is real
		if not atom_index[p.name] then
			table.insert(errors, {
				line = p.line,
				msg  = string.format("pragma references unknown atom '%s'", p.name),
			})
		end

		-- Validate each key
		for k, v in pairs(p.attrs) do
			local spec = ATOM_PRAGMA_KINDS[k]
			if not spec then
				table.insert(errors, {
					line = p.line,
					msg  = string.format("'%s' has unknown pragma key '%s' (allowed: resource/region/group/cadence/async)", p.name, k),
				})
			elseif spec.allowed and not spec.allowed[v] then
				-- Build a human-readable allowed-set
				local allowed = {}
				for kk in pairs(spec.allowed) do table.insert(allowed, kk) end
				table.sort(allowed)
				local allowed_str = table.concat(allowed, ", ")
				table.insert(errors, {
					line = p.line,
					msg  = string.format("'%s' pragma %s=%s but '%s' is not allowed (allowed: %s)", p.name, k, v, v, allowed_str),
				})
			end
		end
	end

	-- 9. cad_async requires CADENCE_ONDEMAND (or no cadence — default-frame atoms can still async).
	--    CADENCE_ONDEMAND requires async=true (otherwise the trigger is undefined).
	for _, p in ipairs(pragmas) do
		if p.attrs.cadence == "ondemand" and p.attrs.async ~= "true" then
			table.insert(errors, {
				line = p.line,
				msg  = string.format("'%s' is CADENCE_ONDEMAND but does not declare atom_async(true)", p.name),
			})
		end
	end

	-- 10. Information summary.
	table.insert(info, {
		line = 0,
		msg  = string.format("scanned: %d atom(s), %d annotation(s), %d pragma(s), %d macro-word-decl(s), %d binds struct(s)",
		                     #atoms, #annots, #pragmas, #macros, #binds)
	})

	return {
		atoms    = atoms,
		annots   = annots,
		macros   = macros,
		pragmas  = pragmas,
		binds    = binds,
		errors   = errors,
		warnings = warnings,
		info     = info,
	}
end

-- ============================================================
-- Report rendering
-- ============================================================

local function render_source_report(source_path, result)
	local lines = {}
	local function add(s) table.insert(lines, s) end

	add("========================================================")
	add("ANNOTATION PASS — " .. source_path)
	add("========================================================")
	add("")
	add(string.format("Atoms: %d   Annotations: %d   Pragmas: %d   Binds structs: %d   Macro decls: %d",
	                  #result.atoms, #result.annots, #result.pragmas and #result.pragmas or 0,
	                  #result.binds, #result.macros))
	add("")

	add("── Atoms ────────────────────────────────────────────────")
	for _, a in ipairs(result.atoms) do
		add(string.format("  MipsAtom_(%s)   line %d", a.name, a.line))
	end
	add("")

	add("── Annotations ──────────────────────────────────────────")
	for _, a in ipairs(result.annots) do
		if a.error then
			add(string.format("  ✗ line %d  %s  [ERROR: %s]", a.line, a.macro or "?", a.error))
		else
			local line = string.format("  %s  line %d  %s  phase=%s",
			    a.kind == "work" and "●" or (a.kind == "bind" and "◆" or "○"),
			    a.line, a.name, a.phase or a.kind)
			if a.binds then line = line .. "  binds=" .. a.binds end
			if #a.reads > 0 then line = line .. "  reads={" .. table.concat(a.reads, ",") .. "}" end
			if #a.writes > 0 then line = line .. "  writes={" .. table.concat(a.writes, ",") .. "}" end
			add(line)
		end
	end
	add("")

	add("── Binds_* structs ──────────────────────────────────────")
	for _, b in ipairs(result.binds) do
		add(string.format("  %s   line %d   %d bytes", b.name, b.line, b.bytes))
		for _, f in ipairs(b.fields) do
			add(string.format("    +%2d: %s", f.offset, f.name))
		end
	end
	add("")

	add("── Macro word-count declarations ─────────────────────────")
	for _, m in ipairs(result.macros) do
		add(string.format("  %s  line %d  words=%d", m.name, m.line, m.words))
	end
	add("")

	add("── Atom pragmas (resource / region / group / cadence / async) ─")
	if not result.pragmas or #result.pragmas == 0 then add("  (none)") end
	for _, p in ipairs(result.pragmas or {}) do
		local kvs = {}
		for k, v in pairs(p.attrs) do table.insert(kvs, k .. "=" .. v) end
		table.sort(kvs)
		add(string.format("  ◇ line %d  %s  {%s}", p.line, p.name, table.concat(kvs, ", ")))
	end
	add("")

	add("── Errors ──────────────────────────────────────────────")
	if #result.errors == 0 then add("  (none)") end
	for _, e in ipairs(result.errors) do
		add(string.format("  ✗ line %d  %s", e.line, e.msg))
	end
	add("")

	add("── Warnings ────────────────────────────────────────────")
	if #result.warnings == 0 then add("  (none)") end
	for _, w in ipairs(result.warnings) do
		add(string.format("  ⚠ line %d  %s", w.line, w.msg))
	end
	add("")

	return table.concat(lines, "\n") .. "\n"
end

local function render_project_report(all_results)
	local lines = {}
	local function add(s) table.insert(lines, s) end

	local total_atoms, total_annots, total_macros, total_binds = 0, 0, 0, 0
	local total_errors, total_warnings = 0, 0

	for _, r in ipairs(all_results) do
		total_atoms   = total_atoms   + #r.atoms
		total_annots  = total_annots  + #r.annots
		total_macros  = total_macros  + #r.macros
		total_binds   = total_binds   + #r.binds
		total_errors  = total_errors  + #r.errors
		total_warnings = total_warnings + #r.warnings
	end

	add("========================================================")
	add("ANNOTATION VALIDATION — project summary")
	add("========================================================")
	add("")
	add(string.format("Atoms:        %d", total_atoms))
	add(string.format("Annotations:  %d", total_annots))
	add(string.format("Macros:       %d", total_macros))
	add(string.format("Binds:        %d", total_binds))
	add("")
	add(string.format("Errors:       %d", total_errors))
	add(string.format("Warnings:     %d", total_warnings))
	add("")

	if total_errors > 0 then
		add("Per-source error counts:")
		for _, r in ipairs(all_results) do
			if #r.errors > 0 then
				add(string.format("  %s : %d error(s)", r.source, #r.errors))
			end
		end
		add("")
	end

	return table.concat(lines, "\n") .. "\n"
end

-- ============================================================
-- Main
-- ============================================================

local function main(args)
	if #args < 2 then
		print("Usage: lua tape_atom_annotation_pass.lua <metadata.h> <source1> [source2 ...]")
		os.exit(1)
	end
	local word_counts = load_word_counts(args[1])
	local all_results = {}

	-- Collect every <source_dir>/gen directory we touch, so we can prune stale
	-- empty reports left over by previous runs. A file that USED to have atoms
	-- but doesn't any more (refactor / template removal) shouldn't keep its
	-- report polluting the source tree.
	local pruned_dirs = {}

	for i = 2, #args do
		local source_path = args[i]
		local basename    = basename_no_ext(source_path)
		local out_dir     = dirname(source_path) .. "/gen"
		local out_txt     = out_dir .. "/" .. basename .. ".annotations.txt"
		local out_err     = out_dir .. "/" .. basename .. ".errors.h"

		local result = validate(source_path, word_counts)
		result.source = source_path

		-- Decide whether this source contributes to the build at all. A source
		-- without atoms (e.g. mips.h, gte.h, gcc_asm.h) has nothing for the
		-- annotation DSL to validate — skip both report files. The previously
		-- emitted ones, if any, get pruned below.
		local has_atoms = #result.atoms > 0

		print(string.format("[pass] %s%s", source_path,
			has_atoms and "" or "  (no atoms - skip report)"))

		if has_atoms then
			ensure_dir(out_dir)
			pruned_dirs[out_dir] = true

			-- Per-source annotation report
			write_file(out_txt, render_source_report(source_path, result))
			print(string.format("  -> %s", out_txt))

			-- gen/<basename>.errors.h with #error lines for any structural problems.
			-- The C build refuses to compile if any source produces errors via -include.
			local header_lines = {
				"// Auto-generated by tape_atom_annotation_pass.lua — DO NOT EDIT",
				"#pragma once",
				"",
			}
			for _, e in ipairs(result.errors) do
				table.insert(header_lines,
					string.format('#error "annotation: %s (line %d)"', e.msg, e.line))
			end
			if #result.errors == 0 then
				table.insert(header_lines, "// annotation pass OK")
			end
			write_file(out_err, table.concat(header_lines, "\n") .. "\n")
			print(string.format("  -> %s", out_err))

			table.insert(all_results, result)
		else
			-- No atoms: best-effort delete stale report files from a prior build.
			-- We only remove the ones we know belong to this source (filename is
			-- derived from the source path), never anything else in the dir.
			for _, stale in ipairs({ out_txt, out_err }) do
				local f = io.open(stale, "r")
				if f then f:close(); os.remove(stale) end
			end
		end
	end

	-- Write project-level summary.
	local summary_path = dirname(args[2]) .. "/gen/annotation_validation.txt"
	ensure_dir(dirname(summary_path))
	write_file(summary_path, render_project_report(all_results))
	print(string.format("[summary] %s\n", summary_path))

	-- Exit code
	local total_errors = 0
	for _, r in ipairs(all_results) do total_errors = total_errors + #r.errors end
	if total_errors > 0 then os.exit(1) end
end

main({...})
