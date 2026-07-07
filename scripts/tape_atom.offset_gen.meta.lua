#!/usr/bin/env lua
-- tape_atom_offset_gen.lua
--
-- Finds every `MipsAtom_(name) { ... }` declaration in the given sources,
-- counts the words in each body using the WORD_COUNT manifest, computes
-- branch offsets for atom_label(name) / atom_offset(tag, name) markers,
-- and writes one header per source into <source_dir>/gen/<basename>.offsets.h
--
-- Generated header layout (per source):
--   #pragma region <basename>
--   #undef atom_offset
--   #define atom_offset(tag, name)  atom_offset_##tag##_##name
--   // --- atom: <name> (<n> words) ---
--   #define atom_offset_<tag>_<target>  (N)        // preprocessor form
--   #undef atom_offset_<tag>_<target>              // (so enum can reuse)
--   enum {
--       atom_offset_<tag>_<target> = N,            // C enum form
--   };
--   #define atom_offset_<tag>_<target>  (N)        // re-define for preprocessor
--   #pragma endregion <basename>
--
-- Usage:
--   lua gen_atom_offsets.lua <metadata.h> <source1> [source2 ...]

-- ============================================================
-- Character classification
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

-- ============================================================
-- I/O
-- ============================================================

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

-- PowerShell aliases `mkdir` to New-Item, which treats `-p` as a path, so guard the call.
local function ensure_dir(path)
	local is_win = package.config:sub(1, 1) == "\\"
	os.execute(is_win and ('if not exist "' .. path .. '" mkdir "' .. path .. '"') or ('mkdir -p "' .. path .. '" 2>/dev/null'))
end

-- ============================================================
-- String primitives
-- ============================================================

local function trim(s)
	local a = 1;  while a <= #s and is_space(s:sub(a, a)) do a = a + 1 end
	local b = #s; while b >= a  and is_space(s:sub(b, b)) do b = b - 1 end
	return s:sub(a, b)
end

local function starts_with(s, prefix)
	if #s < #prefix then return false end
	for i = 1, #prefix do
		if s:sub(i, i) ~= prefix:sub(i, i) then return false end
	end
	return true
end

local function ends_with(s, suffix)
	if #s < #suffix then return false end
	local off = #s - #suffix
	for i = 1, #suffix do
		if s:sub(off + i, off + i) ~= suffix:sub(i, i) then return false end
	end
	return true
end

local function find_byte(haystack, target, start)
	for i = start or 1, #haystack do
		if haystack:sub(i, i) == target then return i end
	end
	return nil
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

local function to_upper(s) return s:upper() end
local function to_alnum_underscore(s)
	local out = ""
	for i = 1, #s do
		local c = s:sub(i, i)
		if is_alnum(c) then out = out .. c
		else out = out .. "_" end
	end
	return out
end
local function pad_right(s, w) return s .. string.rep(" ", w - #s) end

-- ============================================================
-- Lexer helpers
-- ============================================================

-- If position i starts a C string literal ("..."), char literal ('.'),
-- // line comment, or /* block comment, advance past it and return the
-- position just after the construct (or #s+1 if unterminated).
-- Otherwise return i unchanged.
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
-- Extract comma-separated identifier args from a parenthesized group
-- after a function-like macro call.
-- ============================================================

local function extract_ident_args(token, after_ident)
	local arg_start = skip_ws_and_cmt(token, after_ident)
	if token:sub(arg_start, arg_start) ~= "(" then return {}, nil end
	local inner, after_paren = read_parens(token, arg_start)

	local args = {}
	local n    = 1
	local len  = #inner
	while n <= len do
		   n = skip_ws_and_cmt(inner, n)
		if n > len then break end
		local ident, after = read_ident(inner, n)
		if ident and ident ~= "" then
			table.insert(args, ident)
			n = after
		else
			n = n + 1
		end
		n = skip_ws_and_cmt(inner, n)
		if n <= len and inner:sub(n, n) == "," then n = n + 1 end
	end

	return args, after_paren
end

-- ============================================================
-- Load WORD_COUNT manifest
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
		if starts_with(trimmed, prefix) and ends_with(trimmed, ")") then
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
-- Count words for a single comma-separated token
-- ============================================================

local function word_count_of_token(token, wc)
	local s = trim(token)
	if    s == "" then return 0 end
	local name, after = read_ident(s, 1)
	if not name then return 1        end
	if wc[name] then return wc[name] end
	local j = skip_ws_and_cmt(s, after)
	if s:sub(j, j) == "(" then
		io.stderr:write("  warning: unknown macro '" .. name .. "', assuming 1 word\n")
	end
	return 1
end

-- ============================================================
-- Split brace-body into top-level comma-separated tokens
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

-- ============================================================
-- Scan token for atom_label/atom_offset markers, walking through
-- balanced groups transparently (so nested calls are found)
-- ============================================================

local function scan_for_atom_markers(token, at_pos, labels, branches)
	local i   = 1
	local len = #token
	while i <= len do
		   i = skip_ws_and_cmt(token, i)
		if i > len then break end
		local c = token:sub(i, i)
		if is_alpha(c) then
			local ident, after = read_ident(token, i)
			if ident == "atom_label" then
				local args, after_paren = extract_ident_args(token, after)
				if #args >= 1 then labels[args[1]] = at_pos end
				if after_paren then i = after_paren else i = after end
			elseif ident == "atom_offset" then
				local args, after_paren = extract_ident_args(token, after)
				if #args >= 2 then table.insert(branches, {pos = at_pos, target = args[2], tag = args[1]}) end
				if after_paren then i = after_paren else i = after end
			else
				i = after
			end
		else
			local nx = skip_str_or_cmt(token, i)
			if nx > i then i = nx else i = i + 1 end
		end
	end
end

-- ============================================================
-- Scan atom body, count words, find markers
-- ============================================================

local function scan_atom_body(body, word_counts)
	local pos      = 0
	local labels   = {}
	local branches = {}
	for _, tok in ipairs(split_top_level_commas(body)) do
		local k    = 1
		local tlen = #tok
		while k <= tlen and is_space(tok:sub(k, k)) do k = k + 1 end
		local leading_ident = read_ident(tok, k)
		if leading_ident == "atom_label" or leading_ident == "atom_offset" then
			scan_for_atom_markers(tok, pos, labels, branches)
		else
			local words = word_count_of_token(tok, word_counts)
			scan_for_atom_markers(tok, pos, labels, branches)
			pos = pos + words
		end
	end
	return labels, branches, pos
end

-- ============================================================
-- Find every MipsAtom_(name) { ... } in a source
-- ============================================================

local function skip_qualifiers(source, i)
	local keywords = {
		["static"]  = true, ["const"]    = true, ["volatile"] = true,
		["extern"]  = true, ["register"] = true, ["auto"]     = true,
		["inline"]  = true, ["typedef"]  = true,
		["internal"]= true, ["LP_"]      = true, ["global"] = true, ["gkknown"] = true
	}
	while true do
		i = skip_ws_and_cmt(source, i)
		local ident, after = read_ident(source, i)
		if not ident       then                return i end
		if keywords[ident] then i = after else return i end
	end
end

local function find_atoms(source_text)
	local atoms = {}
	local len   = #source_text
	local i     = 1

	local function try_wrapped(after_pos)
		local paren_pos = skip_ws_and_cmt(source_text, after_pos)
		if source_text:sub(paren_pos, paren_pos) ~= "(" then return nil end
		local inner, after_paren = read_parens(source_text, paren_pos)
		local n = 1
		while n <= #inner and is_space(inner:sub(n, n)) do n = n + 1 end
		local ns = n
		while n <= #inner and is_alnum(inner:sub(n, n)) do n = n + 1 end
		local name = inner:sub(ns, n - 1)
		if name == "" then return nil end
		local brace_pos = scan_to_char(source_text, "{", after_paren)
		if not brace_pos then return nil end
		local body, after_brace = read_braces(source_text, brace_pos)
		return {name = name, body = body, after_brace = after_brace}
	end

	local function try_raw(after_pos)
		local next_pos = skip_ws_and_cmt(source_text, after_pos)
		local next_ident, next_after = read_ident(source_text, next_pos)
		if not next_ident then return nil end
		if not starts_with(next_ident, "code_") then return nil end
		if #next_ident <= 5 then return nil end
		local atom_name = next_ident:sub(6)
		local brace_pos = scan_to_char(source_text, "{", next_after)
		if not brace_pos then return nil end
		local body, after_brace = read_braces(source_text, brace_pos)
		return {name = atom_name, body = body, after_brace = after_brace}
	end

	while i <= len do
		i = skip_ws_and_cmt(source_text, i); if i > len then break end
		i = skip_qualifiers(source_text, i); if i > len then break end
		local ident, after = read_ident(source_text, i)
		if not ident then
			i = i + 1
		elseif ident == "MipsAtom_" then
			local atom = try_wrapped(after)
			if atom then
				table.insert(atoms, {name = atom.name, body = atom.body})
				i = atom.after_brace
			else
				i = i + 1
			end
		elseif ident == "MipsCode" then
			local atom = try_raw(after)
			if atom then
				table.insert(atoms, {name = atom.name, body = atom.body})
				i = atom.after_brace
			else
				i = after
			end
		else
			i = after
		end
	end
	return atoms
end

-- ============================================================
-- Compute branch offsets (target - branch - 1)
-- ============================================================

local function compute_offsets(labels, branches)
	local results = {}
	for _, br in ipairs(branches) do
		local target = labels[br.target]
		if not target then
			error("Branch target '" .. br.target .. "' has no atom_label (at word " .. br.pos .. ")")
		end
		table.insert(results, {target = br.target, tag = br.tag, offset = target - br.pos - 1 })
	end
	return results
end

-- ============================================================
-- Generate header for one source
-- ============================================================

local function generate_header(source_path, atoms_data)
	local basename = basename_no_ext(source_path)
	local guard    = to_alnum_underscore(to_upper(basename)) .. "_OFFSETS_H"

	local lines = {}
	local function add(s) table.insert(lines, s) end

	add("// Auto-generated by tape_atom_offset_gen.meta.lua — DO NOT EDIT")
	add("// Source: " .. source_path)
	add("#pragma once")
	add("")
	add("#pragma region " .. basename)
	add("")
	-- add("// Dispatch macro: token-pastes <tag>_<target> to the enum name")
	-- add("#undef atom_offset")
	-- add("#define atom_offset(tag, name)  atom_offset_##tag##_##name")
	add("")
	for _, atom in ipairs(atoms_data) do
		if #atom.offsets > 0 then
			add("// --- atom: " .. atom.name .. " (" .. atom.total_words .. " words) ---")
			add("")
			local consts = {}
			for _, r in ipairs(atom.offsets) do
				table.insert(consts, {
					macro_name = "_atom_offset_" .. r.tag .. "_" .. r.target,
					enum_name  = "atom_offset_"  .. r.tag .. "_" .. r.target,
					value      = r.offset
				})
			end
			for _, c in ipairs(consts) do add("#define " .. pad_right(c.macro_name, 44) .. "  " .. c.value .. "") end
			add("")
			add("enum {")
			for _, c in ipairs(consts) do add("    " .. c.enum_name .. " = " .. c.macro_name .. ",") end
			add("};")
			add("")
		end
	end
	add("#pragma endregion " .. basename)
	add("")
	return table.concat(lines, "\n") .. "\n"
end

-- ============================================================
-- Process one source
-- ============================================================

local function process_source(source_path, word_counts)
	local source    = read_file(source_path)
	local atoms_raw = find_atoms(source)

	if #atoms_raw == 0 then
		-- io.stderr:write("  note: no MipsAtom_ declarations in " .. source_path .. "\n")
		return
	end

	local atoms_data = {}
	for _, atom in ipairs(atoms_raw) do
		local labels, branches, total = scan_atom_body(atom.body, word_counts)
		local offsets = compute_offsets(labels, branches)
		table.insert(atoms_data, {
			name = atom.name,
			total_words = total,
			offsets = offsets
		})
	end

	local basename = basename_no_ext(source_path)
	local out_dir  = dirname(source_path) .. "/gen"
	ensure_dir(out_dir)
	local out_path = out_dir .. "/" .. basename .. ".offsets.h"
	write_file(out_path, generate_header(source_path, atoms_data))

	local total_branches = 0
	for _, a in ipairs(atoms_data) do total_branches = total_branches + #a.offsets end
	print("  " .. basename .. ": " .. #atoms_data .. " atom(s), " .. total_branches .. " branch(es)")
	for _, a in ipairs(atoms_data) do
		for _, r in ipairs(a.offsets) do
			print("    " .. a.name .. " -> " .. r.tag .. ":" .. r.target .. " : " .. r.offset)
		end
	end
end

-- ============================================================
-- Main
-- ============================================================

local function main(args)
	if #args < 2 then
		print("Usage: gen_atom_offsets.lua <metadata.h> <source1> [source2 ...]")
		os.exit(1)
	end
	local word_counts = load_word_counts(args[1])
	for i = 2, #args do process_source(args[i], word_counts) end
end

main({...})
