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
--   luajit tape_atom_annotation_pass.lua <metadata.h> <source1> [source2 ...]
--
-- This script is meant to be run alongside tape_atom_offset_gen.lua.
-- Same input files, complementary output. Both feed the build.

-- Make require("duffle") resolve to the sibling duffle.lua in this dir,
-- AND make require("lpeg") find the vendored LPeg DLL in the toolchain.
-- Both prepends are explicit (no :match / no Lua pattern — plain byte scan).
local script_path = arg[0]
local last_sep = 0
for i = 1, #script_path do
		local c = script_path:sub(i, i)
		if c == "/" or c == "\\" then last_sep = i end
end
local script_dir = last_sep == 0 and "./" or script_path:sub(1, last_sep)
package.path   = script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. package.path
package.cpath = "C:\\projects\\Pikuma\\ps1\\toolchain\\luajit-2.1\\lib\\lua\\5.1\\?.dll;" .. package.cpath

-- Shared primitives + domain tables live in scripts/duffle.lua.
local duffle = require("duffle")

-- Local aliases so the rest of this file reads cleanly. These resolve
-- to the same functions in duffle.lua (5.3-compatible, no regex).
local is_space        = duffle.is_space
local is_alpha        = duffle.is_alpha
local is_alnum        = duffle.is_alnum
local trim            = duffle.trim
local find_byte       = duffle.find_byte
local read_file       = duffle.read_file
local write_file      = duffle.write_file
local ensure_dir      = duffle.ensure_dir
local dirname         = duffle.dirname
local basename_no_ext = duffle.basename_no_ext
local skip_str_or_cmt = duffle.skip_str_or_cmt
local skip_ws_and_cmt = duffle.skip_ws_and_cmt
local read_ident      = duffle.read_ident
local read_parens     = duffle.read_parens
local read_braces     = duffle.read_braces
local scan_to_char    = duffle.scan_to_char
local load_word_counts = duffle.load_word_counts

-- Domain tables (single source of truth in duffle.lua).
local WAVE_CONTEXT_REGS = duffle.WAVE_CONTEXT_REGS
local MACRO_EXPANSION   = duffle.MACRO_EXPANSION
local KNOWN_PHASES      = duffle.KNOWN_PHASES
local KNOWN_REGIONS     = duffle.KNOWN_REGIONS
local KNOWN_CADENCES    = duffle.KNOWN_CADENCES
local TAPE_ATOM_MACROS  = duffle.TAPE_ATOM_MACROS
local ATOM_PRAGMA_KINDS = duffle.ATOM_PRAGMA_KINDS

local function valid_phase(p)        return KNOWN_PHASES[p]   or false end
local function is_wave_context_reg(n) return WAVE_CONTEXT_REGS[n] ~= nil end

-- ============================================================
-- Hand-rolled split helpers (no :gmatch / no regex)
--
-- Phase 2 keeps these inline; Phase 3 may LPeg-ify them.
-- ============================================================

-- Split a string at top-level commas. Used inside TAPE_ATOM_* macro
-- bodies where nested parens/braces/brackets are possible.
local function split_csv_top(s)
		local tokens = {}
		local i, start = 1, 1
		local depth = 0
		while i <= #s do
				local c = s:sub(i, i)
				if c == "(" or c == "{" or c == "[" then
						depth = depth + 1
						i = i + 1
				elseif c == ")" or c == "}" or c == "]" then
						depth = depth - 1
						i = i + 1
				elseif c == "," and depth == 0 then
						tokens[#tokens + 1] = s:sub(start, i - 1)
						i = i + 1
						start = i
				else
						i = i + 1
				end
		end
		local last = s:sub(start)
		if trim(last) ~= "" then tokens[#tokens + 1] = last end
		return tokens
end

-- Split a string into whitespace-separated tokens.
-- The original used :gmatch("%S+"); replaced here with a hand-rolled
-- loop (faster + no regex).
local function split_ws(s)
		local tokens = {}
		local i, n = 1, 1
		local len = #s
		while i <= len do
				-- Skip whitespace.
				while i <= len and is_space(s:sub(i, i)) do i = i + 1 end
				if i > len then break end
				local start = i
				-- Take non-whitespace run.
				while i <= len and not is_space(s:sub(i, i)) do i = i + 1 end
				tokens[n] = s:sub(start, i - 1)
				n = n + 1
		end
		return tokens
end

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

-- Extract identifier args from a parenthesized group. Returns a list
-- of {kind, value} pairs where kind is one of:
--   "ident"      -- a bare identifier (e.g. phase_work)
--   "atom_reads" -- an atom_reads(...) call: value is the register list
--   "atom_writes"-- an atom_writes(...) call: value is the register list
--   "other"      -- something we can't classify (preserved as text)
local function parse_atom_annot_args(inner)
		-- Split at top-level commas, respecting nested parens.
		local args = {}
		local tokens = split_csv_top(inner)
		for _, tok in ipairs(tokens) do
				local s = trim(tok)
				if s ~= "" then
						-- Detect register-list calls: atom_reads(...) / atom_writes(...) / tape_regs(...)
						local regs_kind = nil
						local regs_inner = nil
						if s:sub(-1) == ")" then
								if s:sub(1, 11) == "atom_reads(" then
										regs_kind = "atom_reads"
										regs_inner = s:sub(12, -2)
								elseif s:sub(1, 12) == "atom_writes(" then
										regs_kind = "atom_writes"
										regs_inner = s:sub(13, -2)
								end
						end

						if regs_kind then
								local regs = {}
								for _, r in ipairs(split_csv_top(regs_inner)) do
										local trimmed = trim(r)
										if trimmed ~= "" then regs[#regs + 1] = trimmed end
								end
								-- Resolve any phase_* / R_* alias macros
								for i, r in ipairs(regs) do
										if MACRO_EXPANSION[r] then regs[i] = MACRO_EXPANSION[r] end
								end
								args[#args + 1] = {kind = regs_kind, value = regs}
						else
								-- Bare identifier (e.g. phase_work)
								local id, _ = read_ident(s, 1)
								if id and trim(s) == id then
										local v = id
										if MACRO_EXPANSION[v] then v = MACRO_EXPANSION[v] end
										args[#args + 1] = {kind = "ident", value = v}
								else
										args[#args + 1] = {kind = "other", value = s}
								end
						end
				end
		end
		return args
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
		local line_of = duffle.LineIndex(source)
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
																		out[#out + 1] = {
																				line = line_of(i),
																				name = name,
																				words = n,
																		}
																elseif key == "words" then
																		-- Tolerate "mac_X words=N" if someone writes it that way
																		local n = tonumber(val) or 0
																		out[#out + 1] = {
																				line = line_of(i),
																				name = name,
																				words = n,
																		}
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
								-- tokenize (no :gmatch; use hand-rolled split_ws)
								local tokens = split_ws(line_text)
								if #tokens >= 3 and tokens[2] == "tape_atom" and tokens[3]:sub(1, 6) == "words=" then
										local name = tokens[1]
										local n    = tonumber(tokens[3]:sub(7)) or 0
										out[#out + 1] = { line = line_of(i), name = name, words = n }
								elseif #tokens >= 2 and tokens[2]:sub(1, 6) == "words=" then
										local name = tokens[1]
										local n    = tonumber(tokens[2]:sub(7)) or 0
										out[#out + 1] = { line = line_of(i), name = name, words = n }
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
local function try_parse_atom_attr_macro(source, i, line_of)
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
				line  = line_of(i),
				name  = first,
				attrs = { [key] = value },
		}, body_end
end

local function find_atom_pragmas(source)
		local line_of = duffle.LineIndex(source)
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
						local got, entry, next_i = try_parse_atom_attr_macro(source, i, line_of)
						if got then
								out[#out + 1] = entry
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
																		-- tokenize (no :gmatch; use hand-rolled split_ws)
																		for _, pair in ipairs(split_ws(attrs_str)) do
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
																				out[#out + 1] = {
																						line  = line_of(i),
																						name  = name,
																						attrs = attrs,
																				}
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
		local line_of = duffle.LineIndex(source)
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
																				fields[#fields + 1] = { name = fid, offset = byte_off }
																				byte_off = byte_off + 4
																		end
																		k = fafter or tafter + 1
																else
																		k = tafter + 1
																end
														end
														-- Only emit Binds_* structs (skip FMipsAtom512, MipsAtomBuilder, etc.)
														if name:sub(1, 6) == "Binds_" then
														out[#out + 1] = {
																line   = line_of(i),
																name   = name,
																fields = fields,
																bytes  = byte_off,
														}
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
		local line_of = duffle.LineIndex(source)
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
										out[#out + 1] = { line = line_of(i), name = name }
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
-- Find the args of the function declaration that immediately precedes
-- a MipsAtomComp_Proc_ invocation of the given name. Returns the
-- args string (e.g., "U4 off, U4 code, U1 r, U1 g, U1 b") or nil
-- if no function declaration is found.
--
-- Convention: function form is
--   FI_ MipsAtom ac_X(args) MipsAtomComp_Proc_(ac_X, { body })
-- We find the LAST occurrence of "ac_X(" before before_pos and
-- extract the args from inside the parens.
--
-- No regex (per the no_regex constraint). Uses string.find with
-- plain mode (4th arg = true) to find the name + open paren.
-- ============================================================

local function find_function_args_for(source, name, before_pos)
		local search      = source:sub(1, before_pos)
		local name_paren  = name .. "("
		local last_idx    = nil
		local p           = 1
		while true do
				local s = search:find(name_paren, p, true)  -- plain (no regex)
				if not s then break end
				last_idx = s
				p = s + #name_paren
		end
		if not last_idx then return nil end

		-- Verify the preceding context ends with "MipsAtom" (with
		-- possible qualifiers between). Check the last word is
		-- "MipsAtom" (or the trimmed before ends with that token).
		local before   = search:sub(1, last_idx - 1)
		local trimmed  = duffle.trim(before)
		if trimmed:sub(-#"MipsAtom") ~= "MipsAtom" then
				-- Preceding context is not a function declaration.
				-- This shouldn't happen with the convention, but guard anyway.
				return nil
		end

		local open_paren = last_idx + #name  -- position of "("
		local inner      = read_parens(source, open_paren)
		if not inner then return nil end
		return inner
end

-- Extract just the parameter NAMES from a function-args string
-- (stripping type annotations). E.g.,
--   "U4 off, U4 code, U1 r, U1 g, U1 b"  ->  {"off", "code", "r", "g", "b"}
--   "U4 *ptr"                            ->  {"ptr"}
--   ""                                   ->  nil
-- No regex — uses duffle.is_alnum + plain string ops.
-- ============================================================

-- ============================================================
-- Find the contiguous comment block immediately preceding `pos` in
-- `source`. Returns the comment text (with the `/* */` or `//` markers
-- preserved) or an empty string if no comment is adjacent.
-- Used to copy signature comments from the source declaration
-- (`MipsAtomComp_` / `MipsAtomComp_Proc_` / function decl) over to the generated
-- `mac_X` macro, so LSP/IntelliSense displays the args doc.
-- No regex (per the no_regex constraint).
-- ============================================================

local function preceding_comment_block(source, pos)
		local i      = pos
		local pieces = {}
		while true do
				-- Skip whitespace
				local j = i - 1
				while j > 0 do
						local c = source:sub(j, j)
						if c == " " or c == "\t" or c == "\n" or c == "\r" then
								j = j - 1
						else
								break
						end
				end
				if j == 0 then break end
				-- Check for /* ... */ ending at j
				if j >= 2 and source:sub(j-1, j) == "*/" then
						local s = source:sub(1, j - 1)
						local last_open = nil
						for k = #s - 1, 1, -1 do
								if s:sub(k, k+1) == "/*" then
										last_open = k
										break
								end
						end
						if last_open then
								-- Include the leading whitespace+indentation before /*
								local block_start = last_open
								while block_start > 1 do
										local c = source:sub(block_start - 1, block_start - 1)
										if c == " " or c == "\t" then
												block_start = block_start - 1
										else
												break
										end
								end
								table.insert(pieces, 1, source:sub(block_start, j))
								i = block_start
						else
								break
						end
				-- Check for // comment ending at j (j is at end of line, j-1 is \n)
				elseif j >= 1 and (source:sub(j, j) == "\n" or source:sub(j, j) == "\r") then
						-- Walk back to the start of the line
						local line_start = j
						while line_start > 1 and source:sub(line_start-1, line_start-1) ~= "\n" do
								line_start = line_start - 1
						end
						local line = source:sub(line_start, j)
						if line:sub(1, 2) == "//" then
								table.insert(pieces, 1, line)
								i = line_start - 1
						else
								break
						end
				else
						break
				end
		end
		if #pieces == 0 then return "" end
		return table.concat(pieces, "\n")
end

-- Extract just the parameter NAMES from a function-args string
-- (stripping type annotations). E.g.,
--   "U4 off, U4 code, U1 r, U1 g, U1 b"  ->  {"off", "code", "r", "g", "b"}
--   "U4 *ptr"                            ->  {"ptr"}
--   ""                                   ->  nil
-- No regex — uses duffle.is_alnum + plain string ops.
-- ============================================================

local function extract_arg_names(args_str)
		if not args_str or args_str == "" then return nil end
		local names = {}
		local tokens = duffle.split_top_level_commas(args_str)
		for _, tok in ipairs(tokens) do
				local trimmed = duffle.trim(tok)
				if trimmed ~= "" then
						-- Walk backwards from end of trimmed arg, skipping
						-- trailing whitespace / asterisks / brackets.
						local i = #trimmed
						while i > 0 do
								local c = trimmed:sub(i, i)
								if c == " " or c == "\t" or c == "*" or c == "]" or c == "[" then
										i = i - 1
								else
										break
								end
						end
						-- Now find the end of the last identifier (the param name).
						local j = i
						while j > 0 do
								local c = trimmed:sub(j, j)
								if duffle.is_alnum(c) or c == "_" then
										j = j - 1
								else
										break
								end
						end
						local name = trimmed:sub(j + 1, i)
						if name ~= "" then
								names[#names + 1] = name
						end
				end
		end
		if #names == 0 then return nil end
		return names
end

-- ============================================================
-- Find every MipsAtomComp_(ac_<X>) { body } declaration in source.
-- Supports BOTH the bare form and the function form:
--   Bare:      MipsAtomComp_(ac_X) { body }
--   Function:  MipsAtomComp_Proc_(ac_X, { body })  (with a preceding
--              "FI_ MipsAtom ac_X(args)" function declaration)
-- Returns: {line, name, body, args} where args is the function-args
-- string (or nil for the bare form).
-- ============================================================
--  WORD_COUNT entry in gen/<dir_basename>.components.h)
-- ============================================================

local function find_component_atoms(source)
		local line_of = duffle.LineIndex(source)
		local out  = {}
		local len  = #source
		local i    = 1
		while i <= len do
				i = skip_ws_and_cmt(source, i); if i > len then break end
				local ident, after = read_ident(source, i)
				if not ident then
						i = i + 1
				elseif ident == "MipsAtomComp_Proc_"
						or ident == "MipsAtomComp_" then
						local open = skip_ws_and_cmt(source, after)
						if source:sub(open, open) == "(" then
								local inner, after_paren = read_parens(source, open)
								-- Parse args: 1 arg = bare form, 2 args = function form
								local tokens = duffle.split_top_level_commas(inner)
								local name, body = nil, nil
								if #tokens == 1 then
										name = duffle.trim(tokens[1])
								elseif #tokens == 2 then
										name = duffle.trim(tokens[1])
										local body_raw = duffle.trim(tokens[2])
										-- Strip leading { and trailing } if present
										if #body_raw >= 2
											 and body_raw:sub(1, 1) == "{"
											 and body_raw:sub(-1)   == "}" then
												body = duffle.trim(body_raw:sub(2, -2))
										else
												body = body_raw
										end
								end
								if name and name:sub(1, 3) == "ac_" then
										-- Find the function args (preceding function decl).
										-- For the bare form this returns nil (no function).
										local args = find_function_args_for(source, name, open)
										-- Capture the preceding comment block (signature doc).
										-- Walk back from `i` (position of the identifier start)
										-- so the walk-back goes through whitespace+comment and
										-- stops AT the comment (not at the identifier chars).
										local comment = preceding_comment_block(source, i)
										if body == nil then
												-- Bare form: body is the brace block AFTER the parens.
												local brace = scan_to_char(source, "{", after_paren)
												if brace then
														local body_content, after_brace = read_braces(source, brace)
														out[#out + 1] = {
																line = line_of(i),
																name = name:sub(4),  -- strip "ac_" prefix
																body = body_content,
																args = args,
																comment = comment,
														}
														i = after_brace
												else
														i = open + 1
												end
										else
												-- Function form: body is the second arg (already extracted).
												out[#out + 1] = {
														line = line_of(i),
														name = name:sub(4),  -- strip "ac_" prefix
														body = body,
														args = args,
														comment = comment,
												}
												i = after_paren
										end
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
-- Emit a per-directory generated header with mac_X(...) macros
-- derived from MipsAtomComp_ declarations + auto word-counts.
-- Output: <source_dir>/gen/<dir_basename>.components.h
-- ============================================================

-- Convert `//` line comments to `/* */` block comments in a token.
-- C macros use `\` line-continuations; a `//` comment before `\` would
-- consume the continuation, breaking the macro. We convert `//` to
-- `/* */` so the multi-line macro structure is preserved.
-- Skips `//` sequences that are inside string or character literals
-- (a rough heuristic — sufficient for component bodies which don't
-- have those constructs).
local function convert_line_comments_to_block(s)
	local result = s
	local i = 1
	while i <= #result do
		local c = result:byte(i)
		if c == 47 and i + 1 <= #result and result:byte(i + 1) == 47 then
			-- Found `//`. Find end of line.
			local eol = i
			while eol <= #result and result:byte(eol) ~= 10 do
				eol = eol + 1
			end
			local before   = result:sub(1, i - 1)
			local comment  = result:sub(i + 2, eol - 1)  -- skip the `//`
			local after
			if eol <= #result and result:byte(eol) == 10 then
				after = " */" .. result:sub(eol)  -- keep the newline
			else
				after = " */"
			end
			result = before .. "/*" .. comment .. after
			i = #before + 2 + #comment + 3  -- skip past converted comment
		else
			i = i + 1
		end
	end
	return result
end

local function emit_component_macros_h(source_path, components)
		if #components == 0 then return end

		local dir          = duffle.dirname(source_path)
		local dir_basename = duffle.basename_no_ext(dir)
		-- Components header stays in the source dir (used by the codebase).
		local out_dir      = dir .. "/gen"
		local out_path     = out_dir .. "/" .. dir_basename .. ".macs.h"

		local lines = {
				-- #pragma once wrapped in #ifdef INTELLISENSE_DIRECTIVES, matching
				-- the convention in lottes_tape.h. The build does manual unity
				-- includes (the user controls include order), so the pragma
				-- is only active for IDE/tooling.
				"#ifdef INTELLISENSE_DIRECTIVES",
				"#pragma once",
				"#endif",
				"// Auto-generated by tape_atom_annotation_pass.lua — DO NOT EDIT",
				"// Source: " .. source_path,
				"// Component atoms (MipsAtomComp_(ac_*)) -> macro variants (mac_*)",
				"// + auto word-counts (so tape_atom.metadata.h stays manual-only",
				"//   for encoding macros).",
				"",
				-- Self-contained: define WORD_COUNT if not already defined.
				-- The metadata file (tape_atom.metadata.h) defines it as
				--     enum { words_##name = (count) };
				-- We use the same definition here so the auto-generated
				-- entries below expand to compile-time constants whether
				-- the metadata file is included first or not.
				"#ifndef WORD_COUNT",
				"#define WORD_COUNT(name, count)  enum { words_##name = (count) };",
				"#endif",
				"",
		}

		for _, c in ipairs(components) do
				-- Emit the signature comment (if any) above the macro.
				-- This is the same comment that preceded the MipsAtomComp_
				-- declaration in the source; LSP/IntelliSense shows it on the
				-- generated mac_X macro.
				if c.comment and c.comment ~= "" then
						for line in (c.comment .. "\n"):gmatch("([^\n]*)\n") do
								lines[#lines + 1] = line
						end
				end

				-- Split body by top-level commas; filter empty tokens.
				local tokens = {}
				for _, t in ipairs(duffle.split_top_level_commas(c.body)) do
						local trimmed = duffle.trim(t)
						if trimmed ~= "" then tokens[#tokens + 1] = trimmed end
				end
				local n = #tokens

				-- Determine the macro signature: with function args (function
				-- form) or variadic-ignored (bare form).
				local arg_names = extract_arg_names(c.args)
				local sig
				if arg_names and #arg_names > 0 then
						sig = table.concat(arg_names, ", ")
				else
						sig = "..."
				end

        if n > 0 then
            -- Convert `//` line comments to `/* */` block comments in each
            -- token. C macros use `\` line-continuations; if a `//` comment
            -- appears before a `\`, the rest of the line (including the
            -- continuation) is consumed by the `//`, breaking the macro.
            -- Converting to `/* */` preserves the macro structure.
            for j = 1, n do
                tokens[j] = convert_line_comments_to_block(tokens[j])
            end
            -- Emit the mac_<X>(<sig>) macro
            lines[#lines + 1] = "#define mac_" .. c.name .. "(" .. sig .. ") \\"
            lines[#lines + 1] = "\t" .. tokens[1] .. " \\"
            for j = 2, n do
                lines[#lines + 1] = ",\t" .. tokens[j] .. " \\"
            end
						-- Strip the trailing line-continuation on the last body line.
						-- The last 2 chars are always " \" (space + backslash).
						-- No regex — just trim with string.sub.
						local last = lines[#lines]
						if last:sub(-2) == " \\" then
								lines[#lines] = last:sub(1, -3)
						end
				end

				-- Emit the WORD_COUNT(mac_<X>, N) entry.
				lines[#lines + 1] = "WORD_COUNT(mac_" .. c.name .. ", " .. n .. ")"
				lines[#lines + 1] = ""
		end

		duffle.ensure_dir(out_dir)
		duffle.write_file(out_path, table.concat(lines, "\n") .. "\n")
		print(string.format("  -> %s", out_path))
end

local function find_atom_annotations(source)
		local line_of = duffle.LineIndex(source)
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
										annots[#annots + 1] = {
												line  = line_of(i),
												macro = ident,
												kind  = macro_def.kind,
												error = "missing atom name (first arg)",
										}
								else
										local name = args[1].value
										-- atom_bind: (name, Binds_Struct, writes)
										-- atom_annot: (name, phase, reads, writes)
										-- atom_setup / atom_commit: (name, reads)
										-- atom_init / atom_terminate: (name)
										local entry = {
												line   = line_of(i),
												macro  = ident,
												name   = name,
												kind   = macro_def.kind,
												binds  = nil,
												phase  = nil,
												reads  = {},
												writes = {},
												errors = {},
										}

										-- Is this arg a register-list call (any of the recognized forms)?
										local function is_regs(a)
												return a and (a.kind == "atom_reads" or a.kind == "atom_writes" or a.kind == "regs")
										end

										if macro_def.binds then
												-- atom_bind(name, Binds_Struct, writes)
												if #args >= 2 and args[2].kind == "ident" then
														entry.binds = args[2].value
												end
												if #args >= 3 and is_regs(args[3]) then
														-- A bind writes the wave-context, so atom_writes(...) is the
														-- canonical form, but legacy regs(...) is also accepted.
														entry.writes = args[3].value
												end
										elseif ident == "atom_init" or ident == "atom_terminate" then
												-- (name) only, no reads/writes to extract
										elseif ident == "atom_setup" then
												-- atom_setup(name, reads)
												if #args >= 2 and is_regs(args[2]) then
														entry.reads = args[2].value
												end
										elseif ident == "atom_commit" then
												-- atom_commit(name, reads)
												if #args >= 2 and is_regs(args[2]) then
														entry.reads = args[2].value
												end
										elseif ident == "atom_annot" then
												-- atom_annot(name, phase, reads, writes)
												if #args >= 2 and args[2].kind == "ident" then
														entry.phase = MACRO_EXPANSION[args[2].value] or args[2].value
												end
												-- reads slot: atom_reads(...) is the canonical form;
												-- atom_writes(...) in the reads slot is a likely bug.
												if #args >= 3 and is_regs(args[3]) then
														if args[3].kind == "atom_writes" then
																entry.errors[#entry.errors + 1] =
																		"reads slot has atom_writes — swap order?"
														end
														entry.reads = args[3].value
												end
												-- writes slot: atom_writes(...) is canonical;
												-- atom_reads(...) here is a likely bug.
												if #args >= 4 and is_regs(args[4]) then
														if args[4].kind == "atom_reads" then
																entry.errors[#entry.errors + 1] =
																		"writes slot has atom_reads — swap order?"
														end
														entry.writes = args[4].value
												end
										end

										annots[#annots + 1] = entry
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
-- Validation
-- ============================================================

local function validate(source_path, word_counts)
		local source = read_file(source_path)

		local annots      = find_atom_annotations(source)
		local macros     = find_macro_word_annotations(source)
		local pragmas    = find_atom_pragmas(source)
		local binds      = find_binds_structs(source)
		local atoms      = find_atom_names(source)

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
						errors[#errors + 1] = {line = a.line, msg = a.error}
				elseif not atom_index[a.name] then
						errors[#errors + 1] = {
								line = a.line,
								msg  = string.format("annotation for '%s' has no matching MipsAtom_(%s) { ... }", a.name, a.name)
						}
				end
				-- Per-entry parser errors (e.g. reads/writes slot mix-ups)
				if a.errors then
						for _, msg in ipairs(a.errors) do
								errors[#errors + 1] = {line = a.line, msg = string.format("'%s': %s", a.name, msg)}
						end
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
						warnings[#warnings + 1] = {
								line = atom.line,
								msg  = string.format("MipsAtom_(%s) has no TAPE_ATOM_* annotation", atom.name)
						}
				elseif n > 1 then
						errors[#errors + 1] = {
								line = atom.line,
								msg  = string.format("MipsAtom_(%s) has %d annotations (expected 1)", atom.name, n)
						}
				end
		end

		-- 3. Phase validity.
		for _, a in ipairs(annots) do
				if a.name and not a.error and a.phase and not valid_phase(a.phase) then
						errors[#errors + 1] = {
								line = a.line,
								msg  = string.format("'%s' has unknown phase '%s' (expected one of init/bind/setup/work/commit/terminate)", a.name, a.phase)
						}
				end
		end

		-- 4. BIND atoms must reference a real Binds_* struct.
		for _, a in ipairs(annots) do
				if a.binds then
						if not binds_index[a.binds] then
								errors[#errors + 1] = {
										line = a.line,
										msg  = string.format("'%s' binds '%s' but no Struct_(%s) { ... } declaration found", a.name, a.binds, a.binds)
								}
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
										warnings[#warnings + 1] = {
												line = bs.line,
												msg  = string.format("%s field '%s' doesn't match a known wave-context register (candidate '%s')", a.binds, f.name, candidate)
										}
								end
						end

						-- Bind writes must all be wave-context registers.
						for _, w in ipairs(a.writes) do
								if not is_wave_context_reg(w) then
										warnings[#warnings + 1] = {
												line = a.line,
												msg  = string.format("%s writes '%s' which is not a known wave-context register", a.name, w)
										}
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
										warnings[#warnings + 1] = {
												line = a.line,
												msg  = string.format("work atom '%s' reads '%s' which is not a known wave-context register", a.name, r)
										}
								end
						end
				end
		end

		-- 7. TAPE_WORDS(mac_X, N) ↔ WORD_COUNT(mac_X, N) drift.
		for _, m in ipairs(macros) do
				local declared = word_counts[m.name]
				if not declared then
						errors[#errors + 1] = {
								line = m.line,
								msg  = string.format("TAPE_WORDS(%s, %d) but '%s' is not in metadata.h", m.name, m.words, m.name)
						}
				elseif declared ~= m.words then
						errors[#errors + 1] = {
								line = m.line,
								msg  = string.format("DRIFT: TAPE_WORDS(%s, %d) but metadata.h declares WORD_COUNT(%s, %d)", m.name, m.words, m.name, declared)
						}
				else
						info[#info + 1] = {
								line = m.line,
								msg  = string.format("OK: %s = %d words", m.name, m.words)
						}
				end
		end

		-- 8. atom_<...> _Pragma validation: resource/region/group/cadence/async
		for _, p in ipairs(pragmas) do
				-- Validate the atom name is real
				if not atom_index[p.name] then
						errors[#errors + 1] = {
								line = p.line,
								msg  = string.format("pragma references unknown atom '%s'", p.name),
						}
				end

				-- Validate each key
				for k, v in pairs(p.attrs) do
						local spec = ATOM_PRAGMA_KINDS[k]
						if not spec then
								errors[#errors + 1] = {
										line = p.line,
										msg  = string.format("'%s' has unknown pragma key '%s' (allowed: resource/region/group/cadence/async)", p.name, k),
								}
						elseif spec.allowed and not spec.allowed[v] then
								-- Build a human-readable allowed-set
								local allowed = {}
								for kk in pairs(spec.allowed) do allowed[#allowed + 1] = kk end
								table.sort(allowed)
								local allowed_str = table.concat(allowed, ", ")
								errors[#errors + 1] = {
										line = p.line,
										msg  = string.format("'%s' pragma %s=%s but '%s' is not allowed (allowed: %s)", p.name, k, v, v, allowed_str),
								}
						end
				end
		end

		-- 9. cad_async requires CADENCE_ONDEMAND (or no cadence — default-frame atoms can still async).
		--    CADENCE_ONDEMAND requires async=true (otherwise the trigger is undefined).
		for _, p in ipairs(pragmas) do
				if p.attrs.cadence == "ondemand" and p.attrs.async ~= "true" then
						errors[#errors + 1] = {
								line = p.line,
								msg  = string.format("'%s' is CADENCE_ONDEMAND but does not declare atom_async(true)", p.name),
						}
				end
		end

		-- 10. Information summary.
		info[#info + 1] = {
				line = 0,
				msg  = string.format("scanned: %d atom(s), %d annotation(s), %d pragma(s), %d macro-word-decl(s), %d binds struct(s)",
														 #atoms, #annots, #pragmas, #macros, #binds)
		}

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
		local function add(s) lines[#lines + 1] = s end

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
				for k, v in pairs(p.attrs) do kvs[#kvs + 1] = k .. "=" .. v end
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
		local function add(s) lines[#lines + 1] = s end

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
				print("Usage: luajit tape_atom_annotation_pass.lua <metadata.h> <source1> [source2 ...]")
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
				local dir_basename = basename_no_ext(dirname(source_path))
				local out_dir     = dirname(source_path) .. "/../../build/gen/" .. dir_basename
				local out_txt     = out_dir .. "/" .. basename .. ".annotations.txt"
				local out_err     = out_dir .. "/" .. basename .. ".errors.h"

				local result = validate(source_path, word_counts)
				result.source = source_path

				-- Decide whether this source contributes to the build at all. A source
				-- without atoms (e.g. mips.h, gte.h, gcc_asm.h) has nothing for the
				-- annotation DSL to validate — skip both report files. The previously
				-- emitted ones, if any, get pruned below.
				local has_atoms = #result.atoms > 0

				-- print(string.format("[pass] %s%s", source_path,
						-- has_atoms and "" or "  (no atoms - skip report)"))

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
								header_lines[#header_lines + 1] =
										string.format('#error "annotation: %s (line %d)"', e.msg, e.line)
						end
						if #result.errors == 0 then
								header_lines[#header_lines + 1] = "// annotation pass OK"
						end
						write_file(out_err, table.concat(header_lines, "\n") .. "\n")
						print(string.format("  -> %s", out_err))

						all_results[#all_results + 1] = result
				else
						-- No atoms: best-effort delete stale report files from a prior build.
						-- We only remove the ones we know belong to this source (filename is
						-- derived from the source path), never anything else in the dir.
						for _, stale in ipairs({ out_txt, out_err }) do
								local f = io.open(stale, "r")
								if f then f:close(); os.remove(stale) end
						end
				end

				-- Emit the per-directory component-macros header (gen/<dir>.components.h)
				-- if this source has any MipsAtomComp_ declarations. Independent of
				-- has_atoms: a header can have components without having full atoms.
				-- (TODO: pass source text into validate() to avoid the double-read.)
				local source_text = duffle.read_file(source_path)
				local components  = find_component_atoms(source_text)
				if #components > 0 then
						emit_component_macros_h(source_path, components)
				end
		end

		-- Write project-level summary. Goes to build/gen/ (reporting cruft),
		-- not the source dir.
		local summary_path = dirname(args[2]) .. "/../../build/gen/annotation_validation.txt"
		ensure_dir(dirname(summary_path))
		write_file(summary_path, render_project_report(all_results))
		print(string.format("[summary] %s\n", summary_path))

		-- Exit code
		local total_errors = 0
		for _, r in ipairs(all_results) do total_errors = total_errors + #r.errors end
		if total_errors > 0 then os.exit(1) end
end

main({...})