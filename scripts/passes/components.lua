-- passes/components.lua
--
-- Generate <module>/gen/<basename>.macs.h from MipsAtomComp_ declarations
-- in source files. Ported from tape_atom_annotation_pass.lua:604-1079
-- (find_component_atoms, preceding_comment_block, extract_arg_names,
-- convert_line_comments_to_block, compute_component_word_count,
-- emit_component_macros_h).
--
-- Coding standard: tabs (1/level), EmmyLua annotations, no regex.

--- @class Component
--- @field name    string
--- @field body    string
--- @field args    string|nil
--- @field line    integer
--- @field comment string|nil

--- @class M

-- ════════════════════════════════════════════════════════════════════════════
-- Module-scope requires + package.path setup
-- ════════════════════════════════════════════════════════════════════════════

local script_path = arg and arg[0] or "?"
local last_sep = 0
for i = 1, #script_path do
	local c = script_path:sub(i, i)
	if c == "/" or c == "\\" then last_sep = i end
end
local script_dir = last_sep == 0 and "./" or script_path:sub(1, last_sep)
package.path   = script_dir .. "../?.lua;" .. script_dir .. "../?/init.lua;" .. script_dir .. "?.lua;" .. package.path

local duffle              = require("duffle")
local trim                = duffle.trim
local read_ident          = duffle.read_ident
local is_space            = duffle.is_space
local is_alpha            = duffle.is_alpha
local is_alnum            = duffle.is_alnum
local skip_ws_and_cmt     = duffle.skip_ws_and_cmt
local skip_str_or_cmt     = duffle.skip_str_or_cmt
local split_top_level_commas = duffle.split_top_level_commas
local ensure_dir          = duffle.ensure_dir
local basename_no_ext     = duffle.basename_no_ext
local dirname             = duffle.dirname
local read_parens         = duffle.read_parens
local read_braces         = duffle.read_braces
local scan_to_char        = duffle.scan_to_char

local word_count_eval     = require("word_count_eval")
local count_body_words    = word_count_eval.count_body_words

local M = {}

-- ════════════════════════════════════════════════════════════════════════════
-- Local helpers
-- ════════════════════════════════════════════════════════════════════════════

-- Write content to disk in binary mode so LF line endings are preserved on
-- Windows (text mode would convert LF -> CRLF, breaking byte-identical diffs
-- against git-tracked gen/*.macs.h files which are stored as LF).
local function write_file_lf(path, content)
	local f = io.open(path, "wb")
	if not f then error("Cannot write " .. path) end
	f:write(content)
	f:close()
end

-- Convert a (possibly relative) path to an absolute Windows path. The
-- pre-rework output's "// Source:" comment line used the absolute path
-- (e.g. "C:\projects\Pikuma\ps1\code\duffle\lottes_tape.h"); if we want
-- byte-identical output, we must normalize relative -> absolute before
-- emitting that comment.
local function to_absolute_path(path)
	if #path >= 2 and path:sub(2, 2) == ":" then
		-- Already absolute; normalize slashes for consistency.
		return (path:gsub("/", "\\"))
	end
	local p = io.popen("cd")
	if not p then return path end
	local cwd = p:read("*l")
	p:close()
	if not cwd then return path end
	-- Normalize forward slashes to backslashes (Windows convention) on
	-- both the cwd AND the relative path tail, so the join is uniform.
	cwd = cwd:gsub("/", "\\")
	local tail = (path:gsub("/", "\\"))
	return cwd .. "\\" .. tail
end

-- ════════════════════════════════════════════════════════════════════════════
-- Ported helpers (verbatim from tape_atom_annotation_pass.lua:604-1079)
-- ════════════════════════════════════════════════════════════════════════════

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

--- @param source string
--- @param name string
--- @param before_pos integer
--- @return string|nil
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

-- ============================================================
-- Find the contiguous comment block immediately preceding `pos` in
-- `source`. Returns the comment text (with the `/* */` or `//` markers
-- preserved) or an empty string if no comment is adjacent.
-- Used to copy signature comments from the source declaration
-- (`MipsAtomComp_` / `MipsAtomComp_Proc_` / function decl) over to the generated
-- `mac_X` macro, so LSP/IntelliSense displays the args doc.
-- No regex (per the no_regex constraint).
-- ============================================================

--- @param source string
--- @param pos integer
--- @return string
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

-- ============================================================
-- Extract just the parameter NAMES from a function-args string
-- (stripping type annotations). E.g.,
--   "U4 off, U4 code, U1 r, U1 g, U1 b"  ->  {"off", "code", "r", "g", "b"}
--   "U4 *ptr"                            ->  {"ptr"}
--   ""                                   ->  nil
-- No regex — uses duffle.is_alnum + plain string ops.
-- ============================================================

--- @param args_str string|nil
--- @return string[]|nil
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

--- @param source string
--- @return Component[]
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
-- Output: <source_dir>/gen/<dir_basename>.macs.h
-- ============================================================

-- Convert `//` line comments to `/* */` block comments in a token.
-- C macros use `\` line-continuations; a `//` comment before `\` would
-- consume the continuation, breaking the macro. We convert `//` to
-- `/* */` so the multi-line macro structure is preserved.
-- Skips `//` sequences that are inside string or character literals
-- (a rough heuristic — sufficient for component bodies which don't
-- have those constructs).

--- @param s string
--- @return string
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

-- Compute the word count of a component body, accounting for
-- macro expansion. Each comma-separated entry in the body is a
-- "slot" that contributes its own word count. For most entries
-- (regular MIPS instructions) the count is 1. For `mac_Y(...)`
-- calls, the count is the word count of mac_Y (recursive lookup
-- through `components`). For encoding macros with a known multi-word
-- count (e.g. `mask_upper` = 2), the count is taken from `word_counts`.
--
-- The lookup is memoized via `rec()` to avoid infinite recursion
-- (e.g. if two components referenced each other). This is the
-- same algorithm as the original tape_atom_annotation_pass.lua
-- (commit 7d20a4d) — without it, a fresh build with no pre-existing
-- *.macs.h files in gen/ would compute wrong counts: e.g.
-- `mac_format_f3_color` calls `mac_pack_color_word` which isn't
-- in `wc` yet, so the lookup falls through to the "1 word" default
-- and produces `WORD_COUNT(mac_format_f3_color, 1)` instead of 3.
--
--- @param c Component
--- @param components Component[]
--- @param wc table<string, integer>
--- @return integer
local function compute_component_word_count(c, components, wc)
	-- Build component lookup table once per call.
	local comp_by_name = {}
	for _, cc in ipairs(components) do
		comp_by_name[cc.name] = cc
	end

	local cache = {}
	local function rec(name)
		if cache[name] ~= nil then return cache[name] end
		cache[name] = -1  -- mark in-progress (cycle detection)
		local cc = comp_by_name[name]
		local n
		if cc then
			local body_tokens = {}
			for _, t in ipairs(split_top_level_commas(cc.body)) do
				local trimmed = trim(t)
				if trimmed ~= "" then body_tokens[#body_tokens + 1] = trimmed end
			end
			n = 0
			for _, t in ipairs(body_tokens) do
				-- Read the first identifier from the token.
				local ident = read_ident(t, 1)
				-- Components are stored without the `mac_` prefix
				-- (e.g. "format_f3_color"). The token has `mac_format_f3_color(...)`,
				-- so strip the `mac_` prefix to look up the component.
				local comp_name = ident
				if comp_name and comp_name:sub(1, 4) == "mac_" then
					comp_name = comp_name:sub(5)
				end
				if comp_name and comp_by_name[comp_name] then
					-- It's a `mac_X(...)` call. Recurse.
					n = n + rec(comp_name)
				elseif comp_name and wc and wc[comp_name] then
					-- Encoding macro or pseudo-instruction (e.g. mask_upper = 2, nop2 = 2).
					n = n + wc[comp_name]
				else
					-- Unrecognized token. Fall back to 1 word.
					n = n + 1
				end
			end
		else
			-- Not a known component: assume 1 word (regular instruction).
			n = 1
		end
		cache[name] = n
		return n
	end
	return rec(c.name)
end

-- ============================================================
-- Per-component emit logic. Returns the body of lines for one
-- component (signature comment, #define mac_X(...) line with
-- backslash-continued tokens, then WORD_COUNT(mac_X, N) entry).
--
-- Extracted from emit_component_macros_h so M.run can call it
-- once per component AND extend ctx.shared.word_counts.
-- ============================================================

-- ============================================================
-- Per-component emit logic. Returns the body of lines for one
-- component (signature comment, #define mac_X(...) line with
-- backslash-continued tokens, then WORD_COUNT(mac_X, N) entry).
--
-- Extracted from emit_component_macros_h so M.run can call it
-- once per component AND extend ctx.shared.word_counts.
-- ============================================================

--- Split a (possibly multi-line) comment into per-line entries.
--- Hand-rolled (no regex patterns used).
--- @param s string
--- @return string[]
local function split_comment_lines(s)
	local out = {}
	local i = 1
	local len = #s
	while i <= len do
		local nl = s:find("\n", i, true)
		if not nl then
			out[#out + 1] = s:sub(i)
			break
		end
		out[#out + 1] = s:sub(i, nl - 1)
		i = nl + 1
	end
	return out
end

--- Split an atom body by top-level commas; drop empty tokens.
--- @param body string
--- @return string[]
local function tokens_from_body(body)
	local out = {}
	for _, t in ipairs(split_top_level_commas(body)) do
		local trimmed = trim(t)
		if trimmed ~= "" then out[#out + 1] = trimmed end
	end
	return out
end

--- Determine the macro signature: function-args list (function form)
--- or variadic-ignored (bare form).
--- @param args_str string|nil
--- @return string
local function signature_from_args(args_str)
	local arg_names = extract_arg_names(args_str)
	if arg_names and #arg_names > 0 then
		return table.concat(arg_names, ", ")
	end
	return "..."
end

--- Strip the trailing " \" (space + backslash) line continuation
--- from the last body line. The last 2 chars are always that pair.
local function strip_trailing_continuation(lines)
	local last = lines[#lines]
	if last:sub(-2) == " \\" then
		lines[#lines] = last:sub(1, -3)
	end
end

--- Emit the `#define mac_X(sig) \<newline>\t<tok1> \<newline>,\t<tok2> ...`
--- block. Converts `//` line comments to `/* */` block comments in
--- each token so they don't break the C macro `\` line continuations.
local function emit_macro_body(lines, c, sig, tokens)
	for j = 1, #tokens do
		tokens[j] = convert_line_comments_to_block(tokens[j])
	end
	lines[#lines + 1] = "#define mac_" .. c.name .. "(" .. sig .. ") \\"
	lines[#lines + 1] = "\t" .. tokens[1] .. " \\"
	for j = 2, #tokens do
		lines[#lines + 1] = ",\t" .. tokens[j] .. " \\"
	end
	strip_trailing_continuation(lines)
end

--- @param c Component
--- @param components Component[]
--- @param wc table<string, integer>
--- @return string[]  -- list of lines for this component
local function build_component_lines(c, components, wc)
	local lines = {}

	if c.comment and c.comment ~= "" then
		for _, line in ipairs(split_comment_lines(c.comment)) do
			lines[#lines + 1] = line
		end
	end

	local tokens = tokens_from_body(c.body)
	local sig    = signature_from_args(c.args)
	local n      = compute_component_word_count(c, components, wc)

	if n > 0 then
		emit_macro_body(lines, c, sig, tokens)
	end

	-- Emit the WORD_COUNT(mac_<X>, N) entry.
	lines[#lines + 1] = "WORD_COUNT(mac_" .. c.name .. ", " .. n .. ")"
	lines[#lines + 1] = ""

	return lines
end

-- ============================================================
-- Emit a per-source .macs.h header with the mac_X macros +
-- WORD_COUNT entries. Writes in BINARY mode so LF line endings
-- are preserved (the git blob is LF; Windows text-mode would
-- emit CRLF and break the byte-identical diff).
--
-- Honors ctx.dry_run: prints the intended path but does not
-- write the file.
-- ============================================================

--- @param ctx PassCtx
--- @param src SourceFile
--- @param components Component[]
--- @return string|nil  -- path to the written file (nil on dry-run)
local function emit_component_macros_h(ctx, src, components)
	if #components == 0 then return nil end

	-- Output path: <src.dir>/gen/<src.dir's basename>.macs.h
	-- The pre-rework convention uses the *directory* basename (not
	-- the source file basename) — e.g. `code/duffle/lottes_tape.h`
	-- produces `code/duffle/gen/duffle.macs.h`. This matches what
	-- the C codebase #includes.
	local out_dir  = src.dir .. "/gen"
	local out_path = out_dir .. "/" .. basename_no_ext(src.dir) .. ".macs.h"

	local lines = {
		-- #pragma once wrapped in #ifdef INTELLISENSE_DIRECTIVES, matching
		-- the convention in lottes_tape.h. The build does manual unity
		-- includes (the user controls include order), so the pragma
		-- is only active for IDE/tooling.
		"#ifdef INTELLISENSE_DIRECTIVES",
		"#pragma once",
		"#endif",
		"// Auto-generated by tape_atom_annotation_pass.lua — DO NOT EDIT",
		"// Source: " .. to_absolute_path(src.path),
		"// Component atoms (MipsAtomComp_(ac_*)) -> macro variants (mac_*)",
		"",
		-- Self-contained: define WORD_COUNT if not already defined.
		-- We use the same definition here so the auto-generated
		-- entries below expand to compile-time constants whether
		-- the metadata file is included first or not.
		"#ifndef WORD_COUNT",
		"#define WORD_COUNT(name, count)  enum { words_##name = (count) };",
		"#endif",
		"",
	}

	local wc = ctx.shared.word_counts
	for _, c in ipairs(components) do
		local comp_lines = build_component_lines(c, components, wc)
		for _, l in ipairs(comp_lines) do lines[#lines + 1] = l end
	end

	local content = table.concat(lines, "\n") .. "\n"

	if ctx.dry_run then
		print(string.format("  -> %s (dry-run)", out_path))
		return out_path
	end

	ensure_dir(out_dir)
	write_file_lf(out_path, content)
	print(string.format("  -> %s", out_path))
	return out_path
end

-- ════════════════════════════════════════════════════════════════════════════
-- Pass entry
-- ════════════════════════════════════════════════════════════════════════════

--- @param ctx PassCtx
--- @return PassResult
function M.run(ctx)
	local outputs  = {}
	local errors   = {}
	local warnings = {}

	for _, src in ipairs(ctx.sources) do
		-- find_component_atoms operates on src.text
		local components = find_component_atoms(src.text)
		if #components > 0 then
			local macs_path = emit_component_macros_h(ctx, src, components)
			if macs_path then
				table.insert(outputs, { macs_h = macs_path })

				-- Extend the shared word_counts table so offsets sees the
				-- component macros without re-reading the file.
				local wc = ctx.shared.word_counts
				for _, c in ipairs(components) do
					wc["mac_" .. c.name] = compute_component_word_count(c, components, wc)
				end
			end
		end
	end

	return { outputs = outputs, errors = errors, warnings = warnings }
end

return M
