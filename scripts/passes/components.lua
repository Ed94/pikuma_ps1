--- passes/components.lua — Component-macro header generator.
---
--- Reads the pre-scanned SourceScan payload (produced once upstream by `duffle.scan_source`)
--- for `MipsAtomComp_(ac_X)` and `MipsAtomComp_Proc_(ac_X, { body })` declarations, then does per-source backward lookups
--- for the function-args string (from the preceding `FI_ MipsAtom ac_X(...)` function declaration)
--- and the preceding comment block (for LSP/IntelliSense signature docs).
---
--- Emits a per-directory `<dir_basename>.macs.h` containing one `#define mac_X(sig) \` macro per component + `WORD_COUNT(mac_X, N)`
--- entries for downstream offset computation.
---
--- **Conventions**: tabs (1/level), EmmyLua annotations, no regex,
--- Lua 5.3 compatible.

-- ════════════════════════════════════════════════════════════════════════════
-- Module-scope requires + package.path setup
-- ════════════════════════════════════════════════════════════════════════════

-- Bootstrap: same as entry scripts. See `ps1_meta.lua` for the rationale.
-- Bootstrap: load `scripts/duffle_paths.lua` (sets package.path + package.cpath).
-- Uses `debug.getinfo` to find this file's own directory, so it works both standalone and when require'd from the orchestrator.
-- Bootstrap: load `duffle_paths.lua` via `debug.getinfo(1, "S").source` (works both standalone + when require'd).
-- duffle_paths.lua sets package.path then returns `require("duffle")` at the bottom, so the dofile value IS the duffle module.
local _bootstrap_dir  = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local duffle          = dofile(_bootstrap_dir .. "../duffle_paths.lua")

-- ════════════════════════════════════════════════════════════════════════════
-- Constants
-- ════════════════════════════════════════════════════════════════════════════

-- Atom component declaration identifiers.
local ATOM_COMP_PROC  = "MipsAtomComp_Proc_"
local MIPS_ATOM       = "MipsAtom"  -- prefix on the function declaration that wraps an AtomComp_Proc_

-- Component-name prefixes.
local AC_PREFIX       = "ac_"  -- arg to MipsAtomComp_(ac_X); the X is the atom name
local AC_PREFIX_LEN   = 3
local MAC_PREFIX      = "mac_" -- prefix on generated macros; the rest is the atom name
local MAC_PREFIX_LEN  = 4

-- ASCII byte values used in tokenization.
local BYTE_NEWLINE    = 10
local BYTE_SLASH      = 47

-- Source dir basename used as the output `.macs.h` filename.
local GEN_SUBDIR      = "gen"

-- ════════════════════════════════════════════════════════════════════════════
-- Type declarations
-- ════════════════════════════════════════════════════════════════════════════

--- @class SourceFile
--- @field path     string  -- absolute path to the source file
--- @field text     string  -- the full source text
--- @field dir      string  -- the directory containing the source
--- @field basename string  -- filename without extension
--- @field scan     table   -- pre-scanned SourceScan payload (from duffle.scan_source)

--- @class PassCtx
--- @field sources            SourceFile[]           -- all source files in the build
--- @field metadata_path      string                 -- path to word_count.metadata.h
--- @field shared             table                  -- cross-pass shared state
--- @field shared.word_counts table<string, integer> -- populated by word-counts + components
--- @field out_root           string                 -- output root (e.g. "build/gen")
--- @field project_root       string                 -- project root (e.g. "code/")
--- @field upstream           table<string, table>   -- per-pass upstream outputs
--- @field flags              table                  -- CLI flags
--- @field verbose            boolean                -- log diagnostic info

--- @class PassResult
--- @field outputs  table[]  -- {kind=, path=} entries describing emit files
--- @field errors   table[]  -- {line=, msg=} entries; build-stops
--- @field warnings table[]  -- {line=, msg=} entries; build-succeeds

--- @class Component
--- @field name    string     -- atom name (without `ac_` prefix)
--- @field body    string     -- brace-delimited body (without the braces)
--- @field args    string|nil -- function-args string (function form only)
--- @field line    integer    -- source line of the declaration
--- @field comment string|nil -- preceding `/* */` or `//` comment block (signature doc)

-- ════════════════════════════════════════════════════════════════════════════
-- Local helpers (file I/O + path normalization)
-- ════════════════════════════════════════════════════════════════════════════

local M = {}

-- ════════════════════════════════════════════════════════════════════════════
-- Back-walk helpers (composed into the 2 entry points below: find_function_args_for + preceding_comment_block)
-- ════════════════════════════════════════════════════════════════════════════

--- Find the args of the function declaration that immediately precedes a `MipsAtomComp_Proc_` invocation of the given name.
--- Returns the args string (e.g., `"U4 off, U4 code, U1 r, U1 g, U1 b"`) or nil if no function declaration is found.
---
--- Convention: function form is
---   `FI_ MipsAtom ac_X(args) MipsAtomComp_Proc_(ac_X, { body })`
--- We find the LAST occurrence of `"ac_X("` before `before_pos` and extract the args from inside the parens.
--- We then verify the preceding context ends with `MipsAtom`
--- (the function-decl keyword with possible qualifiers between).
---
--- @param source     string
--- @param name       string
--- @param before_pos integer
--- @return string|nil
local function find_function_args_for(source, name, before_pos)
	-- Find the LAST occurrence of `name + "("` in `source[1..before_pos]`.
	local name_open  = name .. "("
	local last_idx   = nil
	local scan_pos   = 1
	while true do
		-- Pass `before_pos + 1` so string.find only returns positions < before_pos + 1
		-- (string.find's 4th arg `plain` is true; we use the 3rd arg `init` for the upper bound).
		local found = source:find(name_open, scan_pos, true)
		if not found or found >= before_pos then break end
		last_idx = found
		scan_pos = found + #name_open
	end
	if not last_idx then return nil end

	-- Verify the preceding context ends with "MipsAtom" (with possible qualifiers between).
	local before   = source:sub(1, last_idx - 1)
	local trimmed  = duffle.trim(before)
	if trimmed:sub(-#MIPS_ATOM) ~= MIPS_ATOM then
		-- Preceding context is not a function declaration.
		return nil
	end

	local open_paren = last_idx + #name  -- position of "("
	-- scan: MipsAtom ac_X(
	local inner      = duffle.read_parens(source, open_paren)
	-- scan: MipsAtom ac_X(<args>)
	if not inner then return nil end
	return inner
end

--- Find the contiguous comment block immediately preceding `pos` in `source`.
--- Returns the comment text (with the `/* */` or `//` markers preserved) or an empty string if no comment is adjacent.
---
--- Used to copy signature comments from the source declaration (`MipsAtomComp_` / `MipsAtomComp_Proc_` / function decl)
--- over to the generated `mac_X` macro, so LSP/IntelliSense displays the args doc.
--- @param source string
--- @param pos    integer
--- @return string
local function preceding_comment_block(source, pos)
	local scan_pos = pos
	local pieces   = {}
	while true do
		-- Skip whitespace (space/tab/newline/CR) backward from `scan_pos`,
		-- returning the position of the first non-whitespace char.
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

		local is_block_close = non_ws >= 2 and source:sub(non_ws - 1, non_ws) == "*/"
		local is_line_end    = source:sub(non_ws, non_ws) == "\n" or source:sub(non_ws, non_ws) == "\r"

		if is_block_close then
			-- Find the opening `/*` for a block comment whose `*/` ends at `non_ws`.
			-- Walk back from `non_ws` over `/*` candidates.
			local prefix  = source:sub(1, non_ws - 1)
			local open_at = nil
			for scan = #prefix - 1, 1, -1 do
				if prefix:sub(scan, scan + 1) == "/*" then
					open_at = scan
					break
				end
			end
			if not open_at then break end
			-- Walk back from `open_at` over leading spaces + tabs to include the indentation before the `/*`.
			local block_start = open_at
			while block_start > 1 do
				local ch = source:sub(block_start - 1, block_start - 1)
				if ch == " " or ch == "\t" then
					block_start = block_start - 1
				else
					break
				end
			end
			table.insert(pieces, 1, source:sub(block_start, non_ws))
			scan_pos = block_start
		elseif is_line_end then
			-- Walk back from `non_ws` to the start of the source line (the most recent `\n` or position 1).
			local line_start = non_ws
			while line_start > 1 and source:sub(line_start - 1, line_start - 1) ~= "\n" do
				line_start = line_start - 1
			end
			local line = source:sub(line_start, non_ws)
			if line:sub(1, 2) == "//" then
				table.insert(pieces, 1, line)
				scan_pos = line_start - 1
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

-- ════════════════════════════════════════════════════════════════════════════
-- Argument-name extraction
-- ════════════════════════════════════════════════════════════════════════════

--- Extract just the parameter NAMES from a function-args string (stripping type annotations). E.g.,
---   `"U4 off, U4 code, U1 r, U1 g, U1 b"`  ->  `{"off", "code", "r", "g", "b"}`
---   `"U4 *ptr"`                            ->  `{"ptr"}`
---   `""`                                   ->  nil
--- @param args_str string|nil
--- @return string[]|nil
local function extract_arg_names(args_str)
	if not args_str or args_str == "" then return nil end
	local names  = {}
	local tokens = duffle.split_top_level_commas(args_str)
	for _, tok in ipairs(tokens) do
		local trimmed = duffle.trim(tok)
		if trimmed ~= "" then
			-- Find the identifier at the end: walk back over trailers (whitespace + `*` + `[]`),
			-- then walk back over the identifier chars (alnum + `_`).
			local ident_end = #trimmed
			while ident_end > 0 do
				local ch = trimmed:sub(ident_end, ident_end)
				if ch == " " or ch == "\t" or ch == "*" or ch == "]" or ch == "[" then
					ident_end = ident_end - 1
				else
					break
				end
			end
			local ident_start = ident_end
			while ident_start > 0 do
				local ch = trimmed:sub(ident_start, ident_start)
				if duffle.is_alnum_byte(string.byte(ch)) or ch == "_" then
					ident_start = ident_start - 1
				else
					break
				end
			end
			ident_start = ident_start + 1
			local name = trimmed:sub(ident_start, ident_end)
			if name ~= "" then names[#names + 1] = name end
		end
	end
	if #names == 0 then return nil end
	return names
end

-- ════════════════════════════════════════════════════════════════════════════
-- Component projection (read from pre-scanned SourceScan)
-- ════════════════════════════════════════════════════════════════════════════

--- Project pre-scanned MipsAtomComp_ / MipsAtomComp_Proc_ entries into Component shape.
--- Does per-source backward lookups for args (preceding function decl) and comment (preceding comment block).
--- Carries `body_tokens` forward from scan-source so word_count_rec reads from the precomputed table instead of calling duffle.tokenize_body again.
--- @param source string  -- the full source text (needed for backward lookups)
--- @param scan   table   -- SourceScan from duffle.scan_source
--- @return Component[]
local function project_components(source, scan)
	local out = {}
	for _, a in ipairs(scan.atoms) do
		if a.kind == "comp_bare" or a.kind == "comp_proc" then
			local args    = find_function_args_for(source, a.raw_name, a.ident_pos)
			local comment = preceding_comment_block(source, a.ident_pos)
			out[#out + 1] = {
				line        = a.line,
				name        = a.name,
				body        = a.body,
				body_off    = a.body_off,
				body_tokens = a.body_tokens,
				args        = args,
				comment     = comment,
				kind        = a.kind,  -- "comp_bare" | "comp_proc"; provenance emitter reads this.
			}
		end
	end
	return out
end

-- ════════════════════════════════════════════════════════════════════════════
-- Line-comment → block-comment conversion
-- ════════════════════════════════════════════════════════════════════════════

-- Convert `//` line comments to `/* */` block comments in a token.
-- C macros use `\` line-continuations; a `//` comment before `\` would consume the continuation,
-- breaking the macro. We convert `//` to `/* */` so the multi-line macro structure is preserved.
--
-- Skips `//` sequences that are inside string or character literals
-- (a rough heuristic — sufficient for component bodies which don't have those constructs).
--
--- @param s string
--- @return string
local function convert_line_comments_to_block(s)
	local result = s
	local pos    = 1
	local len    = #result
	while pos <= len do
		local is_double_slash = result:byte(pos) == BYTE_SLASH
			and pos + 1 <= len and result:byte(pos + 1) == BYTE_SLASH
		if not is_double_slash then
			pos = pos + 1
		else
			-- Find end of line.
			local eol = pos
			while eol <= len and result:byte(eol) ~= BYTE_NEWLINE do
				eol = eol + 1
			end
			local before  = result:sub(1, pos - 1)
			local comment = result:sub(pos + 2, eol - 1)  -- skip the `//`
			local after
			if eol <= len and result:byte(eol) == BYTE_NEWLINE then
				after = " */" .. result:sub(eol)  -- keep the newline
			else
				after = " */"
			end
			result = before .. "/*" .. comment .. after
			pos = #before + 2 + #comment + 3  -- skip past converted comment
		end
	end
	return result
end

-- ════════════════════════════════════════════════════════════════════════════
-- Word-count computation (memoized recursive lookup)
-- ════════════════════════════════════════════════════════════════════════════

--- Strip the `mac_` prefix from a component-call ident so we can look it up against the components-by-name table. 
--- Returns the ident unchanged if it doesn't start with the prefix 
--- (so a non-component ident like `mask_upper` falls through to the wc-table branch).
--- @param ident string|nil
--- @return string|nil
local function strip_mac_prefix(ident)
	if not ident then return nil end
	if ident:sub(1, MAC_PREFIX_LEN) == MAC_PREFIX then
		return ident:sub(MAC_PREFIX_LEN + 1)
	end
	return ident
end

--- (internal) Recursive word-count lookup. `cache` is the memoization table shared across all components
--- in a single source's `count_all_components` pass; the in-progress -1 sentinel detects cycles (A -> B -> A).
--- @param name         string -- the component name (without `mac_`)
--- @param comp_by_name table<string, Component>
--- @param wc           table<string, integer>
--- @param cache        table<string, integer>
--- @return integer
local function word_count_rec(name, comp_by_name, wc, cache)
	if cache[name] ~= nil then return cache[name] end
	cache[name] = -1  -- mark in-progress (cycle detection)
	local cc = comp_by_name[name]
	local n
	if cc then
		n = 0
		local tokens = cc.body_tokens
		for _, t in ipairs(tokens) do
			local trimmed = t.tok
			if trimmed ~= "" then
				local lookup = strip_mac_prefix(duffle.read_ident(trimmed, 1))
				if lookup and comp_by_name[lookup] then
					-- It's a `mac_X(...)` call. Recurse.
					n = n + word_count_rec(lookup, comp_by_name, wc, cache)
				elseif lookup and wc and wc[lookup] then
					-- Encoding macro or pseudo-instruction (e.g. mask_upper = 2, nop2 = 2).
					n = n + wc[lookup]
				else
					-- Unrecognized token. Fall back to 1 word.
					n = n + 1
				end
			end
		end
	else
		-- Not a known component: assume 1 word (regular instruction).
		n = 1
	end
	cache[name] = n
	return n
end

--- Compute word counts for every component in `components` in a single pass.
--- The name-lookup table + memoization cache are built ONCE (per source) instead of per-component,
--- so the cache survives across siblings and a component's recursive `mac_Y(...)` 
--- references hit memoized values instead of re-walking the body.
--- Cycle detection (A -> B -> A) is preserved via the in-progress `-1` sentinel in `cache`.
--- @param components Component[]
--- @param wc         table<string, integer>
--- @return table<string, integer>  -- map of component name (without `mac_`) -> word count
local function count_all_components(components, wc)
	local comp_by_name = {}
	for _, cc in ipairs(components) do comp_by_name[cc.name] = cc end
	local cache        = {}
	local counts       = {}
	for _, c in ipairs(components) do
		counts[c.name] = word_count_rec(c.name, comp_by_name, wc, cache)
	end
	return counts
end

-- ════════════════════════════════════════════════════════════════════════════
-- Per-component emit logic
-- ════════════════════════════════════════════════════════════════════════════

--- Split a (possibly multi-line) comment into per-line entries.
--- Hand-rolled (no regex patterns used).
--- @param s string
--- @return string[]
local function split_comment_lines(s)
	local out  = {}
	local pos  = 1
	local s_len = #s
	while pos <= s_len do
		local nl = s:find("\n", pos, true)
		if not nl then
			out[#out + 1] = s:sub(pos)
			break
		end
		out[#out + 1] = s:sub(pos, nl - 1)
		pos = nl + 1
	end
	return out
end

--- Determine the macro signature: function-args list (function form) or variadic-ignored (bare form).
--- @param args_str string|nil
--- @return string
local function signature_from_args(args_str)
	local arg_names = extract_arg_names(args_str)
	if    arg_names and #arg_names > 0 then
		return table.concat(arg_names, ", ")
	end
	return "..."
end

--- Strip the trailing `" \"` (space + backslash) line continuation from the last body line.
--- The last 2 chars are always that pair.
local function strip_trailing_continuation(lines)
	local last = lines[#lines]
	if    last:sub(-2) == " \\" then
		lines[#lines] = last:sub(1, -3)
	end
end

--- Emit the `#define mac_X(sig) \<newline>\t<tok1> \<newline>,\t<tok2> ...` block.
--- Converts `//` line comments to `/* */` block comments in each token so they don't break the C macro `\` line continuations.
local function emit_macro_body(lines, c, sig, tokens)
	for tok_idx = 1, #tokens do
		tokens[tok_idx] = convert_line_comments_to_block(tokens[tok_idx])
	end
	lines[#lines + 1] = "#define mac_" .. c.name .. "(" .. sig .. ") \\"
	lines[#lines + 1] = "\t" .. tokens[1] .. " \\"
	for tok_idx = 2, #tokens do
		lines[#lines + 1] = ",\t" .. tokens[tok_idx] .. " \\"
	end
	strip_trailing_continuation(lines)
end

--- Build the list of lines for one component
--- (signature comment, `#define mac_X(...)` line with backslash-continued tokens, then `WORD_COUNT(mac_X, N)` entry).
--- @param c          Component
--- @param components Component[]
--- @param wc         table<string, integer>
--- @return string[]  -- list of lines for this component
local function build_component_lines(c, counts)
	local lines = {}

	if c.comment and c.comment ~= "" then
		for _, line in ipairs(split_comment_lines(c.comment)) do
			lines[#lines + 1] = line
		end
	end

	local tokens = duffle.split_top_level_commas(c.body)
	for i = 1, #tokens do tokens[i] = duffle.trim(tokens[i]) end
	local sig    = signature_from_args(c.args)
	-- Direct lookup against the per-source precomputed `counts` table (built once by count_all_components).
	local n      = counts[c.name]

	if n > 0 then
		emit_macro_body(lines, c, sig, tokens)
	end

	-- Emit the WORD_COUNT(mac_<X>, N) entry.
	lines[#lines + 1] = "WORD_COUNT(mac_" .. c.name .. ", " .. n .. ")"
	lines[#lines + 1] = ""

	return lines
end

-- ════════════════════════════════════════════════════════════════════════════
-- Per-source emit logic
-- ════════════════════════════════════════════════════════════════════════════

--- Build the boilerplate header lines (the `#ifdef INTELLISENSE_DIRECTIVES` block,
--- the `// Auto-generated` comment, the `// Source:` line, and the self-contained `WORD_COUNT` macro definition).
--- @param src SourceFile
--- @return string[]
local function header_boilerplate(src)
	return {
		-- #pragma once wrapped in #ifdef INTELLISENSE_DIRECTIVES, matching the convention in lottes_tape.h.
		-- The build does manual unity includes (the user controls include order), so the pragma is only active for IDE/tooling.
		"#ifdef INTELLISENSE_DIRECTIVES",
		"#pragma once",
		"#endif",
		"// Auto-generated by ps1_meta.lua — DO NOT EDIT",
		"// Source: " .. duffle.to_absolute_path(src.path),
		"// Component atoms (MipsAtomComp_(ac_*)) -> macro variants (mac_*)",
		"",
		-- Self-contained: define WORD_COUNT if not already defined.
		-- We use the same definition here so the auto-generated entries below expand
		-- to compile-time constants whether the metadata file is included first or not.
		"#ifndef WORD_COUNT",
		"#define WORD_COUNT(name, count)  enum { words_##name = (count) };",
		"#endif",
		"",
	}
end

--- Compute the output path for one source's `.macs.h` file.
--- The pre-rework convention uses the *directory* basename (not the source file basename)
---  e.g. `code/duffle/lottes_tape.h` produces `code/duffle/gen/duffle.macs.h`.
--- This matches what the C codebase #includes.
--- @param src SourceFile
--- @return string  -- the output directory
--- @return string  -- the full output path
local function compute_macs_h_path(src)
	local  out_dir  = src.dir .. "/" .. GEN_SUBDIR
	local  out_path = out_dir .. "/" .. duffle.basename_no_ext(src.dir) .. ".macs.h"
	return out_dir, out_path
end

--- Emit a per-source `.macs.h` header with the `mac_X` macros + `WORD_COUNT` entries. 
--- Writes in BINARY mode so LF line endings are preserved (the git blob is LF; Windows text-mode would emit CRLF and break the byte-identical diff).
--- @param ctx        PassCtx
--- @param src        SourceFile
--- @param components Component[]
--- @param counts     table<string, integer>  -- precomputed word counts (from count_all_components)
--- @return string|nil  -- path to the written file (nil if no components)
local function emit_component_macros_h(ctx, src, components, counts)
	if #components == 0 then return nil end
	local out_dir, out_path = compute_macs_h_path(src)
	local lines             = header_boilerplate(src)

	for _, c in ipairs(components) do
		for _, l in ipairs(build_component_lines(c, counts)) do
			lines[#lines + 1] = l
		end
	end

	local content = table.concat(lines, "\n") .. "\n"
	duffle.ensure_dir(out_dir)
	duffle.write_file_lf(out_path, content)
	print(string.format("  -> %s", out_path))
	return out_path
end

-- ════════════════════════════════════════════════════════════════════════════
-- Pass entry
-- ════════════════════════════════════════════════════════════════════════════

--- (internal) Extend the canonical `corpus.word_counts` with this source's component macros so offsets sees them without re-reading the file.
--- First declaration wins: a later caller's count is dropped (the existing entry from the first source is preserved).
--- @param corpus     table  -- the canonical corpus
--- @param components Component[]
--- @param counts     table<string, integer>  -- precomputed word counts (from count_all_components)
local function update_canonical_word_counts(corpus, components, counts)
	local wc = corpus.word_counts
	for _, c in ipairs(components) do
		local key = "mac_" .. c.name
		if wc[key] == nil then
			wc[key] = counts[c.name]
		end
	end
end

--- @class ComponentDef
--- @field name string  -- bare name (without ac_/mac_ prefix)
--- @field line integer -- definition source line (line of `MipsAtomComp_(ac_X)` / `MipsAtomComp_Proc_(ac_X, ...)`)
--- @field path string  -- absolute source path of the definition
--- @field kind string  -- "comp_bare" | "comp_proc"

--- (internal) Populate the canonical `corpus.components` projection with this source's components-by-name map.
--- First declaration wins; later declarations of the same bare name are dropped and recorded as a collision via `corpus.collisions` (kind = "component").
--- The pass does NOT write to `ctx.shared.components` (ownership follows the canonical contract).
--- @param corpus     table  -- the canonical corpus
--- @param src        SourceFile
--- @param components Component[]
local function update_canonical_components(corpus, src, components)
	local rel_path = src.path:gsub("\\", "/")
	for _, c in ipairs(components) do
		-- Keyed by bare name (e.g. `yield`, `load_tri_indices`).
		-- The atoms_source_map pass looks up components by bare name from the canonical corpus;
		-- `mac_` prefix lives at the call-site identifier and is stripped before lookup.
		if corpus.components[c.name] == nil then
			corpus.components[c.name] = {
				name = c.name,
				line = c.line,
				path = rel_path,
				kind = c.kind or "comp_bare",
			}
		else
			-- A second declaration of the same bare name: record a typed collision so static-analysis + the report can surface it.
			-- Identical-shape declarations (same path + line) do NOT record a collision (the first-wins entry already covers the case).
			local existing = corpus.components[c.name]
			if existing.path ~= rel_path or existing.line ~= c.line then
				local kind     = c.kind or "comp_bare"
				local first_kind = existing.kind or "comp_bare"
				corpus.collisions[#corpus.collisions + 1] = {
					kind              = "component",
					name              = c.name,
					first_site        = { path = existing.path, line = existing.line },
					conflicting_site  = { path = rel_path,       line = c.line },
					first_shape       = "kind=" .. first_kind,
					conflicting_shape = "kind=" .. kind,
				}
			end
		end
	end
end

--- (internal) Populate the canonical `corpus.component_body_index` projection with this source's body index entries.
--- First declaration wins; later declarations are dropped (no separate collision record: the components collision is already surfaced by `update_canonical_components`).
--- The pass does NOT write to `ctx.shared.component_body_index` (the corpus owns this projection).
--- @param corpus     table  -- the canonical corpus
--- @param src        SourceFile
--- @param components Component[]
--- @param scan       table  -- the SourceScan payload (for line_of)
local function update_canonical_component_body_index(corpus, src, components, scan)
	local line_of = scan and scan.line_of
	for _, c in ipairs(components) do
		if corpus.component_body_index[c.name] == nil then
			corpus.component_body_index[c.name] = {
				body_tokens = c.body_tokens,
				body_off    = c.body_off,
				line_of     = line_of,
				source      = src.path,
				declaration = c.line,
				kind        = c.kind,
			}
		end
	end
end

--- @param ctx PassCtx
--- @return PassResult
function M.run(ctx)
	local outputs  = {}
	local errors   = {}
	local warnings = {}

	-- Canonical-corpus ownership gate.
	local corpus = ctx.shared and ctx.shared.corpus
	if type(corpus) ~= "table" then
		error("components.run requires ctx.shared.corpus (canonical corpus).", 0)
	end
	if type(corpus.source_order) ~= "table" then
		error("components.run requires ctx.shared.corpus.source_order (canonical corpus).", 0)
	end
	if type(corpus.word_counts) ~= "table" then
		error("components.run requires ctx.shared.corpus.word_counts; "
			.. "word_count_eval.run must run before components.run "
			.. "(see PASSES deps).", 0)
	end

	-- Canonical projection ownership:
	--   * `corpus.word_counts["mac_"..name]` — current component count
	--   * `corpus.components[name]`         — bare-name component definition
	--   * `corpus.component_body_index[name]` — body / line_of / source index
	-- The pass does NOT mutate `ctx.shared.components` or `ctx.shared.component_body_index`
	-- (ownership follows the canonical corpus; consumers read from the corpus directly).

	for _, src in ipairs(corpus.source_order) do
		-- project_components reads from src.scan + does backward lookups on src.text
		local components = project_components(src.text, src.scan)
		if #components > 0 then
			-- Compute all component word counts once per source.
			-- Use `corpus.word_counts` (the canonical count table) so the recursive lookup sees both authored-metadata entries
			-- (loaded by word_count_eval.run) AND same-source component entries (populated earlier in this loop by `update_canonical_word_counts`).
			local counts = count_all_components(components, corpus.word_counts)
			local macs_path = emit_component_macros_h(ctx, src, components, counts)
			if macs_path then
				outputs[#outputs + 1] = { macs_h = macs_path }
				-- Populate the canonical projections AFTER disk emission (so the byte-identical `.macs.h` contract is preserved before any current-count mutation).
				update_canonical_word_counts(corpus, components, counts)
				update_canonical_components(corpus, src, components)
				update_canonical_component_body_index(corpus, src, components, src.scan)
			end
		end
	end

	return { outputs = outputs, errors = errors, warnings = warnings }
end

return M
