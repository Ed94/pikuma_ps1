--- passes/annotation.lua — Atom-annotation DSL validator.
---
--- Validates `MipsAtom_(name) atom_info(atom_bind(Binds_X), atom_reads(...), atom_writes(...)) { ... }` declarations in source files.
--- Also reads: `Binds_*` struct declarations (`typedef Struct_(Binds_X) { ... };`)
---
--- Writes:
---   - `<ctx.out_root>/<dir_basename>.errors.h` — one per module, with `#error` directives on findings (the C compile will surface the error)
---   - The annotations.txt report is rendered by `passes/report.lua` from the per-module results stashed in `ctx.flags._annot_results`
---
--- **Conventions**: tabs (1/level), EmmyLua annotations, no regex,
--- Lua 5.3 compatible

-- Bootstrap: same as entry scripts. See `ps1_meta.lua` for the rationale.
-- Bootstrap: load `scripts/duffle_paths.lua` (sets package.path + package.cpath).
-- Uses `debug.getinfo` to find this file's own directory, so it works
-- both standalone and when require'd from the orchestrator.
local _src = debug.getinfo(1, "S").source:sub(2)
local _dir = _src:match("(.*[/\\])") or "./"
dofile(_dir .. "../duffle_paths.lua")
local duffle = require("duffle")
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
local TAPE_ATOM_MACROS  = duffle.TAPE_ATOM_MACROS

local function is_wave_context_reg(n) return WAVE_CONTEXT_REGS[n] ~= nil  end

-- ════════════════════════════════════════════════════════════════════════════
-- Constants
-- ════════════════════════════════════════════════════════════════════════════

-- Atom declaration + annotation identifiers.
local ATOM_DECL        = "MipsAtom_"
local ATOM_INFO        = "atom_info"
local STRUCT_TYPE      = "Struct_"
local PRAGMA_IDENT     = "pragma"
local PRAGMA_OPERATOR  = "_Pragma"

-- Struct-name prefix + byte size of U4 fields.
local BINDS_PREFIX       = "Binds_"
local BINDS_PREFIX_LEN   = 6    -- = #BINDS_PREFIX
local U4_TYPE            = "U4"
local U4_BYTES           = 4    -- sizeof(U4)
local BINDS_FIELD_PREFIX = "R_"  -- wave-context register name prefix

-- TAPE_WORDS pragma keys (the third token after #pragma).
local WORDS_KEY             = "words"
local WORDS_KEY_PREFIX      = "words="   -- the per-macro `words=N` form
local WORDS_KEY_PREFIX_LEN  = 6          -- = #WORDS_KEY_PREFIX
local TAPE_ATOM_WORDS_KEY   = "tape_atom words"  -- the _Pragma form

-- ASCII byte values used in tokenization.
local BYTE_NEWLINE      = 10
local BYTE_SPACE        = 32
local BYTE_DQUOTE       = 34
local BYTE_EQUALS       = 61
local BYTE_OPEN_PAREN   = 40
local BYTE_OPEN_BRACE   = 123
local BYTE_OPEN_BRACK   = 91
local BYTE_CLOSE_PAREN  = 41
local BYTE_CLOSE_BRACE  = 125
local BYTE_CLOSE_BRACK  = 93
local BYTE_COMMA        = 44

-- ════════════════════════════════════════════════════════════════════════════
-- Type declarations
-- ════════════════════════════════════════════════════════════════════════════

--- @class SourceFile
--- @field path     string  -- absolute path to the source file
--- @field text     string  -- the full source text
--- @field dir      string  -- the directory containing the source
--- @field basename string  -- filename without extension

--- @class PassCtx
--- @field sources            SourceFile[]
--- @field metadata_path      string
--- @field shared             table
--- @field shared.word_counts table<string, integer>
--- @field out_root           string
--- @field project_root       string
--- @field upstream           table<string, table>
--- @field flags              table
--- @field flags._annot_results table[]   -- stashed by annotation pass; consumed by report.lua
--- @field dry_run            boolean
--- @field verbose            boolean

--- @class PassResult
--- @field outputs  table[]
--- @field errors   table[]
--- @field warnings table[]

--- @class Atom
--- @field line integer  -- source line of the MipsAtom_ declaration
--- @field name string  -- atom name (e.g. "cube_g4_face")

--- @class AtomAnnotation
--- @field line    integer       -- source line of the atom_info call
--- @field macro   string        -- the macro name (always "atom_info" in the new shape)
--- @field name    string        -- the atom name
--- @field kind    string        -- always "info"
--- @field binds   string|nil    -- Binds_X name if any
--- @field reads   string[]      -- R_* names (read targets)
--- @field writes  string[]      -- R_* names (write targets)
--- @field error   string|nil    -- error message if annotation was malformed
--- @field errors  string[]      -- nested errors from per-arg validation

--- @class BindsField
--- @field name   string   -- field name
--- @field offset integer  -- byte offset within the Binds_X struct

--- @class BindsStruct
--- @field name   string         -- struct name (e.g. "Binds_Floor")
--- @field line   integer        -- source line of the typedef
--- @field bytes  integer        -- total byte size
--- @field fields BindsField[]   -- the field list

--- @class MacroEntry
--- @field name  string   -- macro name (e.g. "mac_format_f3_color")
--- @field line  integer  -- source line of the TAPE_WORDS pragma
--- @field words integer  -- declared word count

--- @class Finding
--- @field line integer  -- source line (or 0 for pass-level)
--- @field msg  string   -- finding message

--- @class AnnotatedResult
--- @field atoms    Atom[]
--- @field annots   AtomAnnotation[]
--- @field macros   MacroEntry[]
--- @field binds    BindsStruct[]
--- @field errors   Finding[]
--- @field warnings Finding[]
--- @field info     Finding[]

--- ════════════════════════════════════════════════════════════════════════════
-- split helpers
-- ════════════════════════════════════════════════════════════════════════════

--- Split a string at top-level commas. Used inside TAPE_ATOM_* macro
--- bodies where nested parens/braces/brackets are possible.
--- @param s string
--- @return string[]
local function split_csv_top(s)
	local tokens   = {}
	local pos      = 1
	local chunk_a  = 1
	local depth    = 0
	local str_len  = #s
	while pos <= str_len do
		local ch = s:byte(pos)
		if ch == BYTE_OPEN_PAREN or ch == BYTE_OPEN_BRACE or ch == BYTE_OPEN_BRACK then
			depth = depth + 1
			pos   = pos   + 1
		elseif ch == BYTE_CLOSE_PAREN or ch == BYTE_CLOSE_BRACE or ch == BYTE_CLOSE_BRACK then
			depth = depth - 1
			pos   = pos   + 1
		elseif ch == BYTE_COMMA and depth == 0 then
			tokens[#tokens + 1] = s:sub(chunk_a, pos - 1)
			pos     = pos  + 1
			chunk_a = pos
		else
			pos = pos + 1
		end
	end
	local last = s:sub(chunk_a)
	if trim(last) ~= "" then tokens[#tokens + 1] = last end
	return tokens
end

--- Split a string into whitespace-separated tokens.
--- @param s string
--- @return string[]
local function split_ws(s)
	local tokens = {}
	local pos   = 1
	local n     = 1
	local len   = #s
	while pos <= len do
		-- Skip whitespace.
		while pos <= len and is_space(s:sub(pos, pos)) do pos = pos + 1 end
		if pos > len then break end
		local chunk_a = pos
		-- Take non-whitespace run.
		while pos <= len and not is_space(s:sub(pos, pos)) do pos = pos + 1 end
		tokens[n] = s:sub(chunk_a, pos - 1)
		n = n + 1
	end
	return tokens
end

-- ════════════════════════════════════════════════════════════════════════════
-- Parse TAPE_ATOM_ANNOT(...) calls
-- ════════════════════════════════════════════════════════════════════════════

-- Recognize a `atom_bind(...)`, `atom_reads(...)`, or `atom_writes(...)` sub-call embedded inside an atom_info arg list. 
-- Returns the kind ("atom_bind" / "atom_reads" / "atom_writes") and the inner content, or nil if the token isn't a recognized sub-call form. 
-- Flattened via a prefix lookup instead of a nested if/elseif chain.
local REGS_CALL_PREFIX = {
	["atom_writes("] = { kind = "atom_writes", inner_offset = 13 },
	["atom_reads("]  = { kind = "atom_reads",  inner_offset = 12 },
	["atom_bind("]   = { kind = "atom_bind",   inner_offset = 11, single_ident = true },
}

local function parse_regs_call(s)
	if s:sub(-1) ~= ")" then return nil end
	-- Try longest prefix first so "atom_writes(" wins over "atom_reads(" when both 12-char prefixes would otherwise match.
	-- Lengths:
	--   atom_writes(  = 12 chars, offset 13
	--   atom_reads(   = 11 chars, offset 12
	--   atom_bind(    = 10 chars, offset 11
	local spec = REGS_CALL_PREFIX[s:sub(1, 12)]
	if not spec then spec = REGS_CALL_PREFIX[s:sub(1, 11)] end
	if not spec then spec = REGS_CALL_PREFIX[s:sub(1, 10)] end
	if not spec then return nil end
	local inner = s:sub(spec.inner_offset, -2)
	if spec.single_ident then
		-- atom_bind takes a single Binds_* type ident. Trim and pass through.
		return spec.kind, trim(inner)
	end
	return spec.kind, inner
end

-- Parse a comma-separated inner content (e.g. inside atom_reads(...)) into a list of trimmed identifiers.
local function parse_regs_list(inner)
	local out = {}
	for _, r in ipairs(split_csv_top(inner)) do
		local trimmed = trim(r)
		if    trimmed ~= "" then out[#out + 1] = trimmed end
	end
	return out
end

-- Parse a single token (from split_csv_top) into an arg entry.
-- Three forms: register-list call, bare identifier, "other" (preserved as text).
local function parse_arg_token(s)
	local kind, inner = parse_regs_call(s)
	if kind then
		if kind == "atom_bind" then
			return { kind = kind, value = inner }  -- single ident, not a list
		end
		return { kind = kind, value = parse_regs_list(inner) }
	end
	local id = read_ident(s, 1)
	if id and trim(s) == id then
		return { kind = "ident", value = id }
	end
	return { kind = "other", value = s }
end

--- Extract identifier args from a parenthesized group. 
--- Returns a list of {kind, value} pairs where kind is one of:
---   "ident"        -- a bare identifier (e.g. a reserved token)
---   "atom_reads"   -- an atom_reads(...) call: value is the register list
---   "atom_writes"  -- an atom_writes(...) call: value is the register list
---   "other"        -- something we can't classify (preserved as text)
local function parse_atom_info_args(inner)
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

--- Skip preprocessor directives (lines starting with `#`).
--- Returns the position past the newline at the end of the line.
--- @param source string
--- @param pos integer
--- @return integer
local function skip_preprocessor_line(source, pos)
	local str_len = #source
	local scan    = pos
	while scan <= str_len and source:byte(scan) ~= BYTE_NEWLINE do
		scan = scan + 1
	end
	return scan + 1
end

--- Parse `_Pragma("mac_X tape_atom words=N")` (operator form).
--- @param source string
--- @param ident_pos integer  -- position of the `_Pragma` ident
--- @param after_ident integer -- position just past the ident
--- @return MacroEntry|nil, integer  -- (entry or nil, new source position)
local function parse_pragma_operator(source, ident_pos, after_ident)
	local open_paren = skip_ws_and_cmt(source, after_ident)
	if source:byte(open_paren) ~= BYTE_OPEN_PAREN then
		return nil, open_paren + 1
	end
	local str, str_end = read_parens(source, open_paren)
	-- scan: _Pragma(<string>)
	str = trim(str)
	if str:sub(1, 1) ~= '"' or str:sub(-1) ~= '"' then
		return nil, str_end
	end
	local inner = str:sub(2, -2)
	local space = find_byte(inner, BYTE_SPACE, 1)
	if not space then return nil, str_end end
	local name = inner:sub(1, space - 1)
	local rest = inner:sub(space + 1)
	local eq   = find_byte(rest, BYTE_EQUALS, 1)
	if not eq then return nil, str_end end
	local key = trim(rest:sub(1, eq - 1))
	local val = trim(rest:sub(eq + 1))
	if key ~= TAPE_ATOM_WORDS_KEY and key ~= WORDS_KEY then return nil, str_end end
	return {
		line  = source:sub(1, ident_pos) and 0 or 0,  -- see line_of below
		name  = name,
		words = tonumber(val) or 0,
	}, str_end
end

--- Parse `#pragma mac_X tape_atom words=N` (directive form).
--- @param source string
--- @param ident_pos integer  -- position of the `pragma` ident
--- @param after_ident integer -- position just past the ident
--- @return MacroEntry|nil, integer  -- (entry or nil, new source position)
local function parse_pragma_directive(source, ident_pos, after_ident)
	local str_len    = #source
	local rest_start = skip_ws_and_cmt(source, after_ident)
	local eol        = rest_start
	while eol <= str_len and source:byte(eol) ~= BYTE_NEWLINE do
		eol = eol + 1
	end
	local line_text = trim(source:sub(rest_start, eol - 1))
	-- scan: #pragma <mac_name> tape_atom words=<N>
	local tokens    = split_ws(line_text)
	local entry
	if #tokens >= 3 and tokens[2] == "tape_atom" and tokens[3]:sub(1, WORDS_KEY_PREFIX_LEN) == WORDS_KEY_PREFIX then
		entry = {
			name  = tokens[1],
			words = tonumber(tokens[3]:sub(WORDS_KEY_PREFIX_LEN + 1)) or 0,
		}
	elseif #tokens >= 2 and tokens[2]:sub(1, WORDS_KEY_PREFIX_LEN) == WORDS_KEY_PREFIX then
		entry = {
			name  = tokens[1],
			words = tonumber(tokens[2]:sub(WORDS_KEY_PREFIX_LEN + 1)) or 0,
		}
	end
	if entry then
		local line_of = duffle.LineIndex(source)
		entry.line    = line_of(ident_pos)
	end
	return entry, eol
end

--- Find every `TAPE_WORDS(mac_X, N)` pragma in source.
--- Accepts both forms:
---   `_Pragma("mac_X tape_atom words=N")`     (operator form)
---   `#pragma mac_X tape_atom words=N`        (directive form)
--- @param source string
--- @return MacroEntry[]
local function find_macro_word_annotations(source)
	local out     = {}
	local pos     = 1
	local str_len = #source
	while pos <= str_len do
		pos = skip_ws_and_cmt(source, pos)
		if pos > str_len then break end

		-- Skip preprocessor directives (lines starting with #).
		if source:byte(pos) == 35 then  -- '#'
			pos = skip_preprocessor_line(source, pos)
		else
		local ident, after_ident = read_ident(source, pos)
		-- scan: <ident>
		if not ident then
			pos = pos + 1
		elseif ident == PRAGMA_OPERATOR then
			-- scan: _Pragma(...)
			local entry, new_pos = parse_pragma_operator(source, pos, after_ident)
			if entry then
				local line_of = duffle.LineIndex(source)
				entry.line    = line_of(pos)
				out[#out + 1] = entry
			end
			pos = new_pos
		elseif ident == PRAGMA_IDENT then
			-- scan: #pragma <mac_name> tape_atom words=<N>
			local entry, new_pos = parse_pragma_directive(source, pos, after_ident)
			if entry then out[#out + 1] = entry end
			pos = new_pos
		else
			pos = after_ident
		end
		end
	end
	return out
end

-- ════════════════════════════════════════════════════════════════════════════
-- Parse `typedef Struct_(Binds_X) { ... };` declarations
-- ════════════════════════════════════════════════════════════════════════════

--- Walk a `Binds_X` body string and extract U4 fields (name + byte offset).
--- Only U4 fields are tracked (Binds_* are always word arrays in this
--- codebase -- pointers stored as U4, indices as U4, etc.).
--- @param body string  -- the brace-delimited body (without the braces)
--- @return BindsField[]  -- field list
--- @return integer       -- total byte size
local function parse_binds_body(body)
	local fields   = {}
	local byte_off = 0
	local pos      = 1
	local body_len = #body
	while pos <= body_len do
		pos = skip_ws_and_cmt(body, pos)
		if pos > body_len then break end
		local type_ident, type_after = read_ident(body, pos)
		if not type_ident then
			pos = pos + 1
		elseif type_ident == U4_TYPE then
			local field_after = skip_ws_and_cmt(body, type_after)
			local fid, fafter = read_ident(body, field_after)
			if fid then
				fields[#fields + 1] = { name = fid, offset = byte_off }
				byte_off = byte_off + U4_BYTES
			end
			pos = fafter or (type_after + 1)
		else
			pos = type_after + 1
		end
	end
	return fields, byte_off
end

--- Try to parse a `typedef Struct_(Binds_X) { ... };` declaration.
--- Returns the parsed BindsStruct (if the form matched) and the new source position.
--- If the form didn't match, returns nil + a position to continue scanning from.
--- @param source string
--- @param ident_pos integer  -- position of the `typedef` ident start
--- @param after_typedef integer -- position just past `typedef`
--- @param line_of fun(pos: integer): integer
--- @return BindsStruct|nil, integer
local function parse_typedef_binds(source, ident_pos, after_typedef, line_of)
	local after_type                   = skip_ws_and_cmt(source, after_typedef)
	local type_ident, after_type_ident = read_ident(source, after_type)
	-- scan: typedef <type_ident>
	if type_ident ~= STRUCT_TYPE then
		return nil, after_type_ident or (after_type + 1)
	end

	local open_paren = skip_ws_and_cmt(source, after_type_ident)
	if source:byte(open_paren) ~= BYTE_OPEN_PAREN then
		return nil, open_paren + 1
	end

	local inner, after_paren = read_parens(source, open_paren)
	-- scan: typedef Struct_(<name>)
	local name               = trim(inner)

	local brace = scan_to_char(source, "{", after_paren)
	-- scan: typedef Struct_(<name>) {
	if not brace then return nil, open_paren + 1 end

	local body, after_brace = read_braces(source, brace)
	-- scan: typedef Struct_(<name>) { <fields> }
	local fields, bytes     = parse_binds_body(body)

	-- Only emit Binds_* structs (other Struct_ typedefs are ignored).
	if name:sub(1, BINDS_PREFIX_LEN) ~= BINDS_PREFIX then
		return nil, after_brace
	end

	return {
		line   = line_of(ident_pos),
		name   = name,
		fields = fields,
		bytes  = bytes,
	}, after_brace
end

--- Find every `Binds_*` struct declaration.
--- @param source string
--- @return BindsStruct[]
local function find_binds_structs(source)
	local line_of = duffle.LineIndex(source)
	local out     = {}
	local pos     = 1
	local str_len = #source
	while pos <= str_len do
		pos = skip_ws_and_cmt(source, pos)
		if pos > str_len then break end

		if source:byte(pos) == 35 then  -- '#'
			pos = skip_preprocessor_line(source, pos)
		else
		local ident, after_ident = read_ident(source, pos)
		-- scan: <ident>
		if not ident then
			pos = pos + 1
		elseif ident == "typedef" then
			-- scan: typedef Struct_(<name>) { <fields> }
			local binds_struct, new_pos = parse_typedef_binds(source, pos, after_ident, line_of)
			if binds_struct then out[#out + 1] = binds_struct end
			pos = new_pos
		else
			pos = after_ident
		end
		end
	end
	return out
end

-- ════════════════════════════════════════════════════════════════════════════
-- Find every MipsAtom_(name) { ... } declaration in source
-- ════════════════════════════════════════════════════════════════════════════

--- Read the next identifier token from `s` starting at `pos`, where the identifier is a contiguous run of `[a-zA-Z0-9_]` 
--- characters (no underscore-starting alpha-only constraint). 
--- Returns the ident + the position just past it, or nil + pos if no identifier starts there.
--- @param s string
--- @param pos integer
--- @return string|nil, integer
local function read_alnum_ident(s, pos)
	local str_len = #s; while pos <= str_len and is_space(s:sub(pos, pos)) do pos = pos + 1 end
	local start = pos;  while pos <= str_len and is_alnum(s:sub(pos, pos)) do pos = pos + 1 end
	if pos == start then return nil, pos end
	return s:sub(start, pos - 1), pos
end

--- Find every `MipsAtom_(name)` declaration in source. 
--- (Just the name + source line; the body is parsed separately by `parse_mips_atom`.)
--- @param source string
--- @return Atom[]
local function find_atom_names(source)
	local line_of = duffle.LineIndex(source)
	local out     = {}
	local pos     = 1
	local str_len = #source
	while pos <= str_len do
		pos = skip_ws_and_cmt(source, pos)
		if pos > str_len then break end

		local ident, after_ident = read_ident(source, pos)
		-- scan: <ident>
		if not ident then
			pos = pos + 1
		elseif ident ~= ATOM_DECL then
			pos = after_ident
		else
			local open_paren = skip_ws_and_cmt(source, after_ident)
			if source:byte(open_paren) ~= BYTE_OPEN_PAREN then
				pos = open_paren + 1
			else
				local inner, after_paren = read_parens(source, open_paren)
				-- scan: MipsAtom_(<name>)
				local name, _            = read_alnum_ident(inner, 1)
				if name and name ~= "" then
					out[#out + 1] = { line = line_of(pos), name = name }
				end
				local brace = scan_to_char(source, "{", after_paren)
				-- scan: MipsAtom_(<name>) {
				if brace then
					local _, after_brace = read_braces(source, brace)
					-- scan: MipsAtom_(<name>) { <body> }
					pos                  = after_brace
				else
					pos = open_paren + 1
				end
			end
		end
	end
	return out
end

-- ════════════════════════════════════════════════════════════════════════════
-- Find atom annotations (atom_info + atom_bind / atom_reads / atom_writes)
-- ════════════════════════════════════════════════════════════════════════════

--- True iff the parsed arg is a register-list call (any recognized form).
local function is_regs_arg(a) return a and (a.kind == "atom_reads" or a.kind == "atom_writes" or a.kind == "regs") end

--- Per-macro arg-shape handlers. Each takes (entry, args) and mutates Per-atom_info sub-call dispatch. 
--- Each takes (entry, args) and mutates entry.{reads, writes, binds, errors}. 
--- All sub-calls are order-independent; each is dispatched on its `kind` (atom_bind / atom_reads / atom_writes) when parsed.
local ANNOT_ARG_HANDLERS = {}

-- atom_info(atom_bind(Binds_X), atom_reads(...), atom_writes(...))
function ANNOT_ARG_HANDLERS.info(entry, args)
	for _, arg in ipairs(args) do
		if     arg.kind == "atom_bind"   then entry.binds  = arg.value
		elseif arg.kind == "atom_reads"  then entry.reads  = arg.value
		elseif arg.kind == "atom_writes" then entry.writes = arg.value
		elseif arg.kind == "ident"       then
			-- Reserved for future use. Currently ignored.
		else
			entry.errors[#entry.errors + 1] = string.format("unexpected atom_info arg kind=%s value=%s", arg.kind, tostring(arg.value))
		end
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
		reads  = {},
		writes = {},
		errors = {},
	}
end

--- Try to parse an `atom_info(...)` call right after the `MipsAtom_(name)` parens.
--- Returns the annotation entry (if present) and the new source position past the atom_info call.
--- Returns nil if no atom_info follows.
--- @param source string
--- @param atom_name string
--- @param after_mipsatom_paren integer  -- position past the MipsAtom_(...) close paren
--- @param line_of fun(pos: integer): integer
--- @return AtomAnnotation|nil, integer  -- (entry or nil, new source position)
local function parse_atom_info_call(source, atom_name, after_mipsatom_paren, line_of)
	local lookahead              = skip_ws_and_cmt(source, after_mipsatom_paren)
	local look_ident, look_after = read_ident(source, lookahead)
	-- scan: MipsAtom_(<name>) <look_ident>
	if look_ident ~= ATOM_INFO then return nil, after_mipsatom_paren end

	local info_open = skip_ws_and_cmt(source, look_after)
	if source:byte(info_open) ~= BYTE_OPEN_PAREN then return nil, info_open + 1 end

	local info_inner, info_after = read_parens(source, info_open)
	-- scan: MipsAtom_(<name>) atom_info(<binds>, <reads>, <writes>)
	local args                   = parse_atom_info_args(info_inner)
	local entry                  = new_annot_entry(line_of(lookahead), ATOM_INFO, atom_name, "info")
	ANNOT_ARG_HANDLERS.info(entry, args)
	return entry, info_after
end

--- Find every `MipsAtom_(name) atom_info(...) { ... };` annotation in source.
--- Returns a list of annotation entries. Atoms without a following `atom_info(...)` call produce NO entry
--- (atoms without annotations are valid in the new minimal shape).
--- @param source string
--- @return AtomAnnotation[]
local function find_atom_annotations(source)
	local line_of = duffle.LineIndex(source)
	local annots  = {}
	local pos     = 1
	local str_len = #source
	while pos <= str_len do
		pos = skip_ws_and_cmt(source, pos)
		if pos > str_len then break end

		-- Skip preprocessor directives (lines starting with #).
		if source:byte(pos) == 35 then  -- '#'
			pos = skip_preprocessor_line(source, pos)
		else
			local ident, after_ident = read_ident(source, pos)
			-- scan: <ident>
			if not ident then
				pos = pos + 1
			elseif ident == ATOM_DECL then
				local open_paren = skip_ws_and_cmt(source, after_ident)
				if source:byte(open_paren) ~= BYTE_OPEN_PAREN then
					pos = open_paren + 1
				else
					local inner, after_paren = read_parens(source, open_paren)
					-- scan: MipsAtom_(<name>)
					local name, _ = read_alnum_ident(inner, 1)

					local entry, new_pos = parse_atom_info_call(source, name, after_paren, line_of)
					-- scan: MipsAtom_(<name>) atom_info(<binds>, <reads>, <writes>)
					if entry then annots[#annots + 1] = entry end
					pos = new_pos

					-- Skip past the body { ... } if present.
					local brace = scan_to_char(source, "{", pos)
					-- scan: MipsAtom_(<name>) atom_info(...) {
					if brace then
						local _, after_brace = read_braces(source, brace)
						-- scan: MipsAtom_(<name>) atom_info(...) { <body> }
						pos = after_brace
					end
				end
			else
				pos = after_ident
			end
		end
	end
	return annots
end

-- ════════════════════════════════════════════════════════════════════════════
-- Validation
-- ════════════════════════════════════════════════════════════════════════════

local function validate(ctx, src)
	local source = src.text

	local annots = find_atom_annotations(source)
	local macros = find_macro_word_annotations(source)
	local binds  = find_binds_structs(source)
	local atoms  = find_atom_names(source)

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

	-- 2. Every atom may have AT MOST ONE annotation (no duplicates). 
	-- (Atoms with ZERO annotations are valid in the new minimal shape.)
	local count_per_atom = {}
	for _, a in ipairs(annots) do
		if a.name and not a.error then
			count_per_atom[a.name] = (count_per_atom[a.name] or 0) + 1
		end
	end
	for name, n in pairs(count_per_atom) do
		if n > 1 then
			errors[#errors + 1] = {
				line = atom_index[name] and atom_index[name].line or 0,
				msg  = string.format("MipsAtom_(%s) has %d annotations (expected at most 1)", name, n),
			}
		end
	end

	-- 3. (Phase validity check DROPPED. Phases were removed from the annotation DSL. 
	-- They may be reintroduced later as sub-calls of atom_info, at which point ordering checks will go here.)

	-- 4. BIND atoms must reference a real Binds_* struct.
	for _, a in ipairs(annots) do
		if a.binds then
			if not binds_index[a.binds] then
				-- Demoted from error to warning (2026-07-10): the same condition is now caught by passes/static_analysis.lua's
				-- check_abi_handoff() as an error. Emitting a warning here keeps the annotation pass from being stop-on-error
				-- for the common test-fixture case, while still surfacing the issue in the report. 
				-- The static-analysis report remains the source of truth for build-stopping errors.
				warnings[#warnings + 1] = {
					line = a.line,
					msg  = string.format("'%s' binds '%s' but no Struct_(%s) { ... } declaration found (also flagged as an error by check_abi_handoff in the static-analysis pass)", a.name, a.binds, a.binds),
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

	-- 6. INFO reads should be wave-context registers (or R_TapePtr for rbind).
	for _, a in ipairs(annots) do
		for _, r in ipairs(a.reads) do
			if not is_wave_context_reg(r) and r ~= "R_TapePtr" then
				warnings[#warnings + 1] = {
					line = a.line,
					msg  = string.format("atom '%s' reads '%s' which is not a known wave-context register", a.name, r),
				}
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

	-- 8. Information summary.
	info[#info + 1] = {
		line = 0,
		msg  = string.format("scanned: %d atom(s), %d annotation(s), %d macro-word-decl(s), %d binds struct(s)",
			#atoms, #annots, #macros, #binds),
	}

	return {
		atoms    = atoms,
		annots   = annots,
		macros   = macros,
		binds    = binds,
		errors   = errors,
		warnings = warnings,
		info     = info,
	}
end

-- ════════════════════════════════════════════════════════════════════════════
-- Per-DIRECTORY (per-module) output: errors.h + annotations.txt
-- ════════════════════════════════════════════════════════════════════════════
--
-- Per-source reports were the old behavior; each source in the same directory produced its own <basename>.errors.h + <basename>.annotations.txt,
-- which flooded build/gen/ with one report per header. 
-- Aggregates per-DIRECTORY (one errors.h + one annotations.txt per module basename). 
-- Directories with zero atoms/annotations are skipped (no file emitted).

--- Render `<dir_basename>.errors.h` with `#error` directives for every error found across all sources in the directory. 
--- Empty directories (no errors, no atoms) produce no file.
local function emit_module_errors_h(ctx, dir_basename, atoms_count, errors, sources)
	if ctx.dry_run then return nil end
	if atoms_count == 0 and #errors == 0 then
		-- Skip dirs with nothing to report
		return nil
	end
	local out_path = ctx.out_root .. "/" .. dir_basename .. ".errors.h"
	local lines    = {
		"// Auto-generated by ps1_meta.lua (passes/annotation.lua) — DO NOT EDIT",
		string.format("// Module: %s   Sources: %d", dir_basename, #sources),
		"#pragma once",
		"",
	}
	if #errors == 0 then
		lines[#lines + 1] = "// annotation pass OK"
	else
		-- Prefix each error with the source basename for traceability
		-- in the C compile log.
		for _, e in ipairs(errors) do
			local src_tag = ""
			if e.source then
				local src_name = e.source:match("([^/\\]+)$") or e.source
				src_tag = src_name .. ": "
			end
			lines[#lines + 1] = string.format('#error "%s%s (line %d)"', src_tag, e.msg, e.line)
		end
	end
	ensure_dir(ctx.out_root)
	write_file(out_path, table.concat(lines, "\n") .. "\n")
	return out_path
end

--- Stash aggregated per-module results for the report pass to consume.
local function emit_module_annotations_stub(ctx, dir, dir_basename, atoms_count)
	ctx.flags         = ctx.flags or {}
	ctx.flags._annot_results = ctx.flags._annot_results or {}
	ctx.flags._annot_results[#ctx.flags._annot_results + 1] = {
		dir          = dir,
		dir_basename = dir_basename,
		atoms_count  = atoms_count,
	}
	-- annotations.txt is written by report.lua
end

-- ════════════════════════════════════════════════════════════════════════════
-- M.run — orchestrator entry
-- ════════════════════════════════════════════════════════════════════════════

--- @class M

local M = {}

-- Expose `validate` for downstream passes (e.g. report.lua) that need to re-render the per-source results into a per-MODULE report.
-- Keeping it as a single shared function avoids the duplication that an earlier version of report.lua had.
M.validate = validate

--- @param ctx PassCtx
--- @return PassResult
function M.run(ctx)
	local outputs  = {}
	local errors   = {}
	local warnings = {}

	-- Per-DIRECTORY (per-module) aggregation. Group sources by `src.dir`, validate every source in the dir, then emit ONE errors.h per dir 
	-- (skipping dirs with no atoms AND no errors). 
	-- The actual annotations.txt is rendered by passes/report.lua from the stashed per-module results below.
	local by_dir = {}
	for _, src in ipairs(ctx.sources) do
		by_dir[src.dir] = by_dir[src.dir] or {}
		table.insert(by_dir[src.dir], src)
	end

	for dir, dir_sources in pairs(by_dir) do
		-- Dir basename = last component of `dir` ("code/duffle" -> "duffle").
		local dir_basename = dir:match("([^/\\]+)$") or dir

		-- Aggregate validate() results across the directory.
		local dir_atoms    = 0
		local dir_errors   = {}
		local dir_warnings = {}
		for _, src in ipairs(dir_sources) do
			local result = validate(ctx, src)
			dir_atoms = dir_atoms + #result.atoms
			for _, e in ipairs(result.errors) do
				dir_errors[#dir_errors + 1] = { line = e.line, msg = e.msg, source = src.path }
				errors[#errors + 1] = { line = e.line, msg = e.msg }
			end
			for _, w in ipairs(result.warnings) do
				dir_warnings[#dir_warnings + 1] = { line = w.line, msg = w.msg }
				warnings[#warnings + 1] = { line = w.line, msg = w.msg }
			end
		end

		-- Emit one errors.h per dir.
		local err_path = emit_module_errors_h(ctx, dir_basename, dir_atoms, dir_errors, dir_sources)
		if err_path then
			table.insert(outputs, { errors_h = err_path })
		end

		-- Stash for report pass.
		emit_module_annotations_stub(ctx, dir, dir_basename, dir_atoms)
	end

	return { outputs = outputs, errors = errors, warnings = warnings }
end

return M
