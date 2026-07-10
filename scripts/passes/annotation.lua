-- passes/annotation.lua
--
-- Validate atom annotation DSL usage in source files. Reads:
--   - atom_annot / atom_init / atom_setup / atom_commit / atom_bind
--     / atom_terminate / atom_label / atom_offset / TAPE_WORDS
--   - atom_resource / atom_region / atom_group / atom_cadence / atom_async
--   - Binds_* struct declarations
-- Writes:
--   - <ctx.out_root>/<basename>.errors.h         (with #error directives on findings)
--   - <ctx.out_root>/<basename>.annotations.txt  (human-readable summary)
-- Ported from scripts/tape_atom_annotation_pass.lua:78-545 + 1081-1407
-- (validation only — NOT rendering, which goes to passes/report.lua).
--
-- Coding standard: tabs (1/level), EmmyLua annotations, no regex.

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
local is_space            = duffle.is_space
local is_alpha            = duffle.is_alpha
local is_alnum            = duffle.is_alnum
local trim                = duffle.trim
local find_byte           = duffle.find_byte
local read_file           = duffle.read_file
local write_file          = duffle.write_file
local ensure_dir          = duffle.ensure_dir
local dirname             = duffle.dirname
local basename_no_ext     = duffle.basename_no_ext
local skip_str_or_cmt     = duffle.skip_str_or_cmt
local skip_ws_and_cmt     = duffle.skip_ws_and_cmt
local read_ident          = duffle.read_ident
local read_parens         = duffle.read_parens
local read_braces         = duffle.read_braces
local scan_to_char        = duffle.scan_to_char
local split_top_level_commas = duffle.split_top_level_commas

-- Domain tables (single source of truth in duffle.lua).
local WAVE_CONTEXT_REGS = duffle.WAVE_CONTEXT_REGS
local MACRO_EXPANSION   = duffle.MACRO_EXPANSION
local KNOWN_PHASES      = duffle.KNOWN_PHASES
local TAPE_ATOM_MACROS  = duffle.TAPE_ATOM_MACROS
local ATOM_PRAGMA_KINDS = duffle.ATOM_PRAGMA_KINDS

local function valid_phase(p)          return KNOWN_PHASES[p]      or false end
local function is_wave_context_reg(n) return WAVE_CONTEXT_REGS[n] ~= nil  end

-- ════════════════════════════════════════════════════════════════════════════
-- Hand-rolled split helpers (no regex patterns used)
-- ════════════════════════════════════════════════════════════════════════════

--- Split a string at top-level commas. Used inside TAPE_ATOM_* macro
--- bodies where nested parens/braces/brackets are possible.
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

--- Split a string into whitespace-separated tokens.
--- Hand-rolled (no regex patterns).
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

-- ════════════════════════════════════════════════════════════════════════════
-- Parse TAPE_ATOM_ANNOT(...) calls
-- ════════════════════════════════════════════════════════════════════════════

-- Recognize a `atom_reads(...)` or `atom_writes(...)` register-list
-- call embedded inside an annotation arg list. Returns the kind
-- ("atom_reads" / "atom_writes") and the inner content, or nil if the
-- token isn't a recognized register-list form. Flattened via a
-- prefix lookup instead of a nested if/elseif chain.
local REGS_CALL_PREFIX = {
	["atom_reads("]  = { kind = "atom_reads",  inner_offset = 12 },
	["atom_writes("] = { kind = "atom_writes", inner_offset = 13 },
}

local function parse_regs_call(s)
	if s:sub(-1) ~= ")" then return nil end
	local spec = REGS_CALL_PREFIX[s:sub(1, 12)]  -- longest prefix first wins
	if not spec then return nil end
	-- The 12-char prefix "atom_reads(" also matches "atom_writes("
	-- would be ambiguous; the table order above handles it.
	-- (atom_reads prefix is 11 chars, atom_writes is 12; the 12-char
	-- lookup matches atom_writes first.)
	return spec.kind, s:sub(spec.inner_offset, -2)
end

-- Resolve any phase_* / R_* alias macros in a register list.
local function resolve_reg_aliases(regs)
	for i, r in ipairs(regs) do
		if MACRO_EXPANSION[r] then regs[i] = MACRO_EXPANSION[r] end
	end
	return regs
end

-- Parse a comma-separated inner content (e.g. inside atom_reads(...))
-- into a list of trimmed identifiers with aliases resolved.
local function parse_regs_list(inner)
	local out = {}
	for _, r in ipairs(split_csv_top(inner)) do
		local trimmed = trim(r)
		if trimmed ~= "" then out[#out + 1] = trimmed end
	end
	return resolve_reg_aliases(out)
end

-- Parse a single token (from split_csv_top) into an arg entry.
-- Three forms: register-list call, bare identifier (with alias),
-- "other" (preserved as text).
local function parse_arg_token(s)
	local kind, inner = parse_regs_call(s)
	if kind then
		return { kind = kind, value = parse_regs_list(inner) }
	end
	local id = read_ident(s, 1)
	if id and trim(s) == id then
		local v = id
		if MACRO_EXPANSION[v] then v = MACRO_EXPANSION[v] end
		return { kind = "ident", value = v }
	end
	return { kind = "other", value = s }
end

--- Extract identifier args from a parenthesized group. Returns a list
--- of {kind, value} pairs where kind is one of:
---   "ident"        -- a bare identifier (e.g. phase_work)
---   "atom_reads"   -- an atom_reads(...) call: value is the register list
---   "atom_writes"  -- an atom_writes(...) call: value is the register list
---   "other"        -- something we can't classify (preserved as text)
local function parse_atom_annot_args(inner)
	local args = {}
	for _, tok in ipairs(split_csv_top(inner)) do
		local s = trim(tok)
		if s ~= "" then
			args[#args + 1] = parse_arg_token(s)
		end
	end
	return args
end

-- ════════════════════════════════════════════════════════════════════════════
-- Parse TAPE_WORDS(mac_X, N) pragma directives
-- ════════════════════════════════════════════════════════════════════════════

--- Find every TAPE_WORDS(mac_X, N) pragma in source.
--- Accepts both forms:
---   _Pragma("mac_X tape_atom words=N")     (operator form)
---   #pragma mac_X tape_atom words=N        (directive form)
local function find_macro_word_annotations(source)
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
			elseif ident == "_Pragma" then
				local open = skip_ws_and_cmt(source, after)
				if source:sub(open, open) == "(" then
					local str, str_end = read_parens(source, open)
					str = trim(str)
					if str:sub(1, 1) == '"' and str:sub(-1) == '"' then
						local inner = str:sub(2, -2)
						local space = find_byte(inner, " ", 1)
						if space then
							local name = inner:sub(1, space - 1)
							local rest = inner:sub(space + 1)
							local eq = find_byte(rest, "=", 1)
							if eq then
								local key  = trim(rest:sub(1, eq - 1))
								local val  = trim(rest:sub(eq + 1))
								if key == "tape_atom words" or key == "words" then
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
				local j = rest_start
				while j <= len and source:sub(j, j) ~= "\n" do j = j + 1 end
				local line_text = trim(source:sub(rest_start, j - 1))
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

-- ════════════════════════════════════════════════════════════════════════════
-- Parse `atom_<...>` Pragma / _Pragma annotations
-- ════════════════════════════════════════════════════════════════════════════

local ATOM_ATTR_MACROS = {
	["atom_resource"] = "resource",
	["atom_region"]   = "region",
	["atom_group"]    = "group",
	["atom_cadence"]  = "cadence",
	["atom_async"]    = "async",
}

--- Parse macro form: `atom_<key>(atom_name, value, ...)`.
--- Returns (true, entry, str_end) on success, (false) on no match.
local function try_parse_atom_attr_macro(source, i, line_of)
	local ident, after = read_ident(source, i)
	if not ident then return false end
	local key = ATOM_ATTR_MACROS[ident]
	if not key then return false end
	local open = skip_ws_and_cmt(source, after)
	if source:sub(open, open) ~= "(" then return false end

	local body, body_end = read_parens(source, open)
	local first, after_name = read_ident(body, 1)
	if not first then return false end

	local j = after_name
	while j <= #body and is_space(body:sub(j, j)) do j = j + 1 end
	if body:sub(j, j) ~= "," then return false end
	j = j + 1
	while j <= #body and is_space(body:sub(j, j)) do j = j + 1 end

	local value
	if body:sub(j, j) == '"' then
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
							local sp1 = find_byte(inner, " ", 1)
							if sp1 and trim(inner:sub(1, sp1 - 1)) == "atom" then
								local rest = trim(inner:sub(sp1 + 1))
								local sp2 = find_byte(rest, " ", 1)
								if sp2 then
									local name = trim(rest:sub(1, sp2 - 1))
									local attrs_str = trim(rest:sub(sp2 + 1))
									local attrs = {}
									local got_any = false
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

-- ════════════════════════════════════════════════════════════════════════════
-- Parse `typedef Struct_(Binds_X) { ... };` declarations
-- ════════════════════════════════════════════════════════════════════════════

--- Find every Binds_* struct declaration.
--- Returns a list of {line, name, fields = {{name, byte_offset}, ...}}.
local function find_binds_structs(source)
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
							-- Only emit Binds_* structs.
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

-- ════════════════════════════════════════════════════════════════════════════
-- Find every MipsAtom_(name) { ... } declaration in source
-- ════════════════════════════════════════════════════════════════════════════

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

-- ════════════════════════════════════════════════════════════════════════════
-- Find atom annotations (atom_annot / atom_init / atom_setup / atom_commit
-- / atom_bind / atom_terminate)
-- ════════════════════════════════════════════════════════════════════════════

--- True iff the parsed arg is a register-list call (any recognized form).
local function is_regs_arg(a)
	return a and (a.kind == "atom_reads" or a.kind == "atom_writes" or a.kind == "regs")
end

--- Per-macro arg-shape handlers. Each takes (entry, args) and mutates
--- entry.{reads, writes, phase, binds, errors}. Replaces the 5-way
--- `if/elseif/elseif/elseif/elseif` chain inside find_atom_annotations.
local ANNOT_ARG_HANDLERS = {}

-- atom_bind(name, Binds_Struct, writes)
function ANNOT_ARG_HANDLERS.bind(entry, args)
	if #args >= 2 and args[2].kind == "ident" then
		entry.binds = args[2].value
	end
	if #args >= 3 and is_regs_arg(args[3]) then
		entry.writes = args[3].value
	end
end

-- atom_init(name) / atom_terminate(name): name only, no extra slots.
ANNOT_ARG_HANDLERS.init      = function() end
ANNOT_ARG_HANDLERS.terminate = function() end

-- Macro name -> handler key. Replaces the `macro_def.binds` check
-- plus the 4-way ident elseif chain.
local MACRO_HANDLER_KEY = {
	["atom_bind"]      = "bind",
	["atom_annot"]     = "annot",
	["atom_setup"]     = "reads_only",
	["atom_commit"]    = "reads_only",
	["atom_init"]      = "init",
	["atom_terminate"] = "terminate",
}

-- atom_setup(name, reads) / atom_commit(name, reads): reads from slot 2.
function ANNOT_ARG_HANDLERS.reads_only(entry, args)
	if #args >= 2 and is_regs_arg(args[2]) then
		entry.reads = args[2].value
	end
end

-- atom_annot(name, phase, reads, writes)
function ANNOT_ARG_HANDLERS.annot(entry, args)
	if #args >= 2 and args[2].kind == "ident" then
		entry.phase = MACRO_EXPANSION[args[2].value] or args[2].value
	end
	if #args >= 3 and is_regs_arg(args[3]) then
		if args[3].kind == "atom_writes" then
			entry.errors[#entry.errors + 1] = "reads slot has atom_writes — swap order?"
		end
		entry.reads = args[3].value
	end
	if #args >= 4 and is_regs_arg(args[4]) then
		if args[4].kind == "atom_reads" then
			entry.errors[#entry.errors + 1] = "writes slot has atom_reads — swap order?"
		end
		entry.writes = args[4].value
	end
end

-- Build a new annotation entry with the standard shape.
local function new_annot_entry(line, ident, name, kind)
	return {
		line   = line,
		macro  = ident,
		name   = name,
		kind   = kind,
		binds  = nil,
		phase  = nil,
		reads  = {},
		writes = {},
		errors = {},
	}
end

--- Find every TAPE_ATOM_* macro call in source and convert it to a
--- normalized annotation entry. Dispatches per-macro arg-shape via
--- ANNOT_ARG_HANDLERS (lookup table; no nested if/elseif chain).
local function find_atom_annotations(source)
	local line_of = duffle.LineIndex(source)
	local annots = {}
	local len = #source
	local i   = 1
	while i <= len do
		i = skip_ws_and_cmt(source, i); if i > len then break end
		-- Skip preprocessor directives (lines starting with #).
		-- Without this guard, `#define atom_init(name) ...` macro
		-- definitions get misinterpreted as annotation calls with
		-- the literal placeholder "name" as the atom name.
		if source:sub(i, i) == "#" then
			local j = i
			while j <= len and source:sub(j, j) ~= "\n" do j = j + 1 end
			i = j + 1
			goto continue
		end

		local ident, after = read_ident(source, i)
		if not ident then
			i = i + 1
		elseif TAPE_ATOM_MACROS[ident] then
			local open = skip_ws_and_cmt(source, after)
			if source:sub(open, open) ~= "(" then
				i = open + 1
			else
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
					local entry = new_annot_entry(line_of(i), ident, args[1].value, macro_def.kind)
					local handler = ANNOT_ARG_HANDLERS[MACRO_HANDLER_KEY[ident]]
					if handler then handler(entry, args) end
					annots[#annots + 1] = entry
				end
				i = after_paren
			end
		else
			i = after
		end
		::continue::
	end
	return annots
end

-- ════════════════════════════════════════════════════════════════════════════
-- Validation (ported from tape_atom_annotation_pass.lua:1193-1405)
-- ════════════════════════════════════════════════════════════════════════════

local function validate(ctx, src)
	local source = src.text

	local annots      = find_atom_annotations(source)
	local macros     = find_macro_word_annotations(source)
	local pragmas    = find_atom_pragmas(source)
	local binds      = find_binds_structs(source)
	local atoms      = find_atom_names(source)

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
				msg  = string.format("annotation for '%s' has no matching MipsAtom_(%s) { ... }", a.name, a.name),
			}
		end
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
				msg  = string.format("MipsAtom_(%s) has no TAPE_ATOM_* annotation", atom.name),
			}
		elseif n > 1 then
			errors[#errors + 1] = {
				line = atom.line,
				msg  = string.format("MipsAtom_(%s) has %d annotations (expected 1)", atom.name, n),
			}
		end
	end

	-- 3. Phase validity.
	for _, a in ipairs(annots) do
		if a.name and not a.error and a.phase and not valid_phase(a.phase) then
			errors[#errors + 1] = {
				line = a.line,
				msg  = string.format("'%s' has unknown phase '%s' (expected one of init/bind/setup/work/commit/terminate)", a.name, a.phase),
			}
		end
	end

	-- 4. BIND atoms must reference a real Binds_* struct.
	for _, a in ipairs(annots) do
		if a.binds then
			if not binds_index[a.binds] then
				errors[#errors + 1] = {
					line = a.line,
					msg  = string.format("'%s' binds '%s' but no Struct_(%s) { ... } declaration found", a.name, a.binds, a.binds),
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

			for _, f in ipairs(bs.fields) do
				local candidate = "R_" .. f.name
				if not is_wave_context_reg(candidate) then
					warnings[#warnings + 1] = {
						line = bs.line,
						msg  = string.format("%s field '%s' doesn't match a known wave-context register (candidate '%s')", a.binds, f.name, candidate),
					}
				end
			end

			for _, w in ipairs(a.writes) do
				if not is_wave_context_reg(w) then
					warnings[#warnings + 1] = {
						line = a.line,
						msg  = string.format("%s writes '%s' which is not a known wave-context register", a.name, w),
					}
				end
			end
		end
	end

	-- 6. WORK reads should be a subset of BIND writes (the wave contract).
	for _, a in ipairs(annots) do
		if a.kind == "work" then
			for _, r in ipairs(a.reads) do
				if not is_wave_context_reg(r) and r ~= "R_TapePtr" then
					warnings[#warnings + 1] = {
						line = a.line,
						msg  = string.format("work atom '%s' reads '%s' which is not a known wave-context register", a.name, r),
					}
				end
			end
		end
	end

	-- 7. TAPE_WORDS(mac_X, N) ↔ WORD_COUNT(mac_X, N) drift.
	--    Three outcomes: missing (error), mismatch (error), match (info).
	--    Flattened via early-return-style helper instead of 3-way elseif.
	local function check_macro_drift(m, declared)
		if not declared then
			errors[#errors + 1] = {
				line = m.line,
				msg  = string.format("TAPE_WORDS(%s, %d) but '%s' is not in metadata.h", m.name, m.words, m.name),
			}
			return
		end
		if declared ~= m.words then
			errors[#errors + 1] = {
				line = m.line,
				msg  = string.format("DRIFT: TAPE_WORDS(%s, %d) but metadata.h declares WORD_COUNT(%s, %d)", m.name, m.words, m.name, declared),
			}
			return
		end
		info[#info + 1] = {
			line = m.line,
			msg  = string.format("OK: %s = %d words", m.name, m.words),
		}
	end
	for _, m in ipairs(macros) do
		check_macro_drift(m, ctx.shared.word_counts[m.name])
	end

	-- 8. atom_<...> _Pragma validation: resource/region/group/cadence/async
	for _, p in ipairs(pragmas) do
		if not atom_index[p.name] then
			errors[#errors + 1] = {
				line = p.line,
				msg  = string.format("pragma references unknown atom '%s'", p.name),
			}
		end

		for k, v in pairs(p.attrs) do
			local spec = ATOM_PRAGMA_KINDS[k]
			if not spec then
				errors[#errors + 1] = {
					line = p.line,
					msg  = string.format("'%s' has unknown pragma key '%s' (allowed: resource/region/group/cadence/async)", p.name, k),
				}
			elseif spec.allowed and not spec.allowed[v] then
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

	-- 9. CADENCE_ONDEMAND requires async=true. Flattened as a guard
	--    (single condition, no nested if).
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
			#atoms, #annots, #pragmas, #macros, #binds),
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

-- ════════════════════════════════════════════════════════════════════════════
-- Per-source output: errors.h + annotations.txt
-- ════════════════════════════════════════════════════════════════════════════

--- Render <basename>.errors.h with #error directives for any structural issues.
local function emit_errors_h(ctx, src, result)
	local out_path = ctx.out_root .. "/" .. src.basename .. ".errors.h"
	local lines = {
		"// Auto-generated by ps1_meta.lua (passes/annotation.lua) — DO NOT EDIT",
		"#pragma once",
		"",
	}
	for _, e in ipairs(result.errors) do
		lines[#lines + 1] = string.format('#error "annotation: %s (line %d)"', e.msg, e.line)
	end
	if #result.errors == 0 then
		lines[#lines + 1] = "// annotation pass OK"
	end
	if ctx.dry_run then return nil end
	ensure_dir(ctx.out_root)
	write_file(out_path, table.concat(lines, "\n") .. "\n")
	return out_path
end

--- Render <basename>.annotations.txt human-readable summary.
--- Implementation lives in passes/report.lua (extracted to keep this
--- file focused on validation). We delegate via a callback set on ctx.
local function emit_annotations_txt(ctx, src, result)
	-- The annotation pass emits a structured result; the report pass
	-- renders it. To avoid a circular dep, the M.run below packs the
	-- result into ctx.upstream.annotation for the report pass to
	-- consume via ctx.flags._annot_results.
	ctx.flags         = ctx.flags or {}
	ctx.flags._annot_results = ctx.flags._annot_results or {}
	ctx.flags._annot_results[#ctx.flags._annot_results + 1] = {
		source = src,
		result = result,
	}
	return nil  -- annotations.txt is written by report.lua
end

-- ════════════════════════════════════════════════════════════════════════════
-- M.run — orchestrator entry
-- ════════════════════════════════════════════════════════════════════════════

--- @class M

local M = {}

--- @param ctx PassCtx
--- @return PassResult
function M.run(ctx)
	local outputs  = {}
	local errors   = {}
	local warnings = {}

	for _, src in ipairs(ctx.sources) do
		local result = validate(ctx, src)
		local err_path = emit_errors_h(ctx, src, result)
		if err_path then
			table.insert(outputs, { errors_h = err_path })
		end
		-- Stash result for report pass.
		emit_annotations_txt(ctx, src, result)

		for _, e in ipairs(result.errors) do
			errors[#errors + 1] = { line = e.line, msg = e.msg }
		end
		for _, w in ipairs(result.warnings) do
			warnings[#warnings + 1] = { line = w.line, msg = w.msg }
		end
	end

	return { outputs = outputs, errors = errors, warnings = warnings }
end

return M