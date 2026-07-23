--- duffle.lua — Shared primitives + domain tables for the tape-atom
--- metaprograms.
---
--- This module is the source for:
---   - **Character classification** (`is_space`, `is_alpha`, `is_alnum`, `is_digit`, plus the byte-fast `_byte` variants).
---   - **String primitives** (`trim`, `dirname`, `basename_no_ext`, `find_byte`).
---   - **I/O primitives** (`read_file`, `write_file`, `ensure_dir`).
---   - **C-language scanner** (`skip_ws_and_cmt`, `skip_str_or_cmt`, `read_ident`, `read_parens`, `read_braces`, `read_brackets`, `read_balanced`, `scan_to_char`, `split_top_level_commas`).
---   - **Word-count loader** (`load_word_counts` for `WORD_COUNT(...)` metadata files).
---   - **Line lookup** (`LineIndex` returns an O(log N) `line_of(pos)` closure for source-mapping).
---   - **Domain tables** (`TAPE_ATOM_MACROS`, `GTE_PIPELINE_LATENCY`, `GP0_CMD_SIZE`, `GP0_CMD_BY_SHAPE`, `GP0_MACRO_CONTRIB`, `INSTRUCTION_LATENCY`).
---
--- **Conventions**: tabs (1/level), EmmyLua annotations, no regex.

local M = {}

-- Required native extension: lfs (LuaFileSystem). Built by `update_deps.ps1` to `toolchain/lfs/lfs.dll` and wired into package.cpath by `scripts/duffle_paths.lua`.
-- If lfs is missing, `require` throws — fail loud per the build-tool convention.
local lfs = require("lfs")

-- ════════════════════════════════════════════════════════════════════════════
-- Cross-file type aliases
-- ════════════════════════════════════════════════════════════════════════════

--- @alias Path        string   -- absolute or CWD-relative file path
--- @alias LineNum     integer  -- 1-indexed source line number
--- @alias ByteOff     integer  -- 0-indexed byte offset within a source string
--- @alias MacroName   string   -- lower_snake_case macro identifier (e.g. "mac_yield")
--- @alias AtomName    string   -- lower_snake_case atom name (e.g. "cube_g4_face")
--- @alias Severity    string   -- "error" | "warning" | "info"

--- @class SourceFile
--- @field path     Path      -- absolute path to the source file
--- @field text     string    -- the full source text
--- @field dir      string    -- the directory containing the source
--- @field basename string    -- filename without extension

-- ════════════════════════════════════════════════════════════════════════════
-- ASCII byte constants
-- ════════════════════════════════════════════════════════════════════════════

local BYTE_SPACE      = 0x20    -- ' '
local BYTE_TAB        = 0x09    -- '\t'
local BYTE_NEWLINE    = 0x0A    -- '\n'
local BYTE_CR         = 0x0D    -- '\r'
local BYTE_VT         = 0x0B    -- '\v'
local BYTE_FF         = 0x0C    -- '\f'

local BYTE_UNDERSCORE = 0x5F    -- '_'
local BYTE_DOT        = 0x2E    -- '.'
local BYTE_SLASH      = 0x2F    -- '/'
local BYTE_BACKSLASH  = 0x5C    -- '\\'
local BYTE_STAR       = 0x2A    -- '*'
local BYTE_DQUOTE     = 0x22    -- '"'
local BYTE_SQUOTE     = 0x27    -- '\''
local BYTE_COMMA      = 0x2C    -- ','
local BYTE_SEMI       = 0x3B    -- ';'

local BYTE_OPEN_PAREN  = 0x28   -- '('
local BYTE_OPEN_BRACE  = 0x7B   -- '{'
local BYTE_OPEN_BRACK  = 0x5B   -- '['

local BYTE_LOWER_A = 0x61       -- 'a'
local BYTE_LOWER_Z = 0x7A       -- 'z'
local BYTE_UPPER_A = 0x41       -- 'A'
local BYTE_UPPER_Z = 0x5A       -- 'Z'

local BYTE_DIGIT_0 = 0x30       -- '0'
local BYTE_DIGIT_9 = 0x39       -- '9'

-- ════════════════════════════════════════════════════════════════════════════
-- Section -1: Bootstrap (path-setup at module load)
-- ════════════════════════════════════════════════════════════════════════════
--
-- Path setup is done by `scripts/duffle_paths.lua`, which derives the repo root from `debug.getinfo(1, "S").source` (NO subprocess, ~0ms) and then calls `require("duffle")`.
-- The prior `io.popen("git rev-parse ...")` approach in this section was removed during F'' because:
--   1. Every entry script + every passes script now uses `dofile("duffle_paths.lua")` (14 call sites; verified via grep).
--      The `find_repo_root` / `setup_package_path` defined here was dead code in practice.
--   2. `git rev-parse` costs ~100-180ms per subprocess spawn on Windows.
--      `debug.getinfo` is <1ms. There's no reason to keep the slow path even as a "fallback".
--
-- If a future use case ever needs to load `duffle.lua` WITHOUT going through `duffle_paths.lua`, set `package.path` manually before `require`.
-- See `docs/guide_metaprogram_ssdl.md` §"I/O primitives" for the pattern.

-- ════════════════════════════════════════════════════════════════════════════
-- Section 0: LPeg patterns (compiled once at module load)
-- ════════════════════════════════════════════════════════════════════════════
--
-- LPeg is a required dependency (PEG library, no regex). 
-- It's loaded via `package.cpath` (configured by `duffle_paths.lua` to find `toolchain/lpeg/lpeg.dll`).
-- There's no hand-rolled fallback. The original two-tier design added complexity for a 5-10x speedup that's
-- only relevant at the high-level scanner stage; the byte-by-byte helpers in Section 1 are sufficient for the classification primitives.
--
-- If the require fails, fail loud with an actionable message. The build script (`update_deps.ps1`) builds lpeg.dll into `toolchain/lpeg/`; 
-- if it's missing, run `update_deps.ps1`.
local lpeg_ok, lpeg = pcall(require, "lpeg")
if not lpeg_ok then
	io.stderr:write("[duffle] require('lpeg') failed: ", lpeg, "\n")
	io.stderr:write("[duffle] lpeg.dll not found on package.cpath.\n")
	io.stderr:write("[duffle] Run 'scripts/update_deps.ps1' to build it into toolchain/lpeg/.\n")
	os.exit(1)
end
local P, S, R = lpeg.P, lpeg.S, lpeg.R

-- Character class patterns
local alpha_pat  = R("AZ", "az") + P("_")
local digit_pat  = R("09")
local lpeg_alnum_pat  = alpha_pat + digit_pat

-- Identifier: alpha followed by zero+ alnum. Capture as a string.
local lpeg_alpha_pat = alpha_pat
local lpeg_ident_pat = lpeg.C(alpha_pat * lpeg_alnum_pat^0)

-- String literal: "..." with backslash escapes.
local lpeg_str_pat = P('"') * (P(1) - S('"\\') + P('\\') * P(1))^0 * P('"')
-- Char literal: '...' with backslash escapes.
local lpeg_chr_pat = P("'") * (P(1) - S("'\\") + P('\\') * P(1))^0 * P("'")
-- Line comment: // ... to end-of-line.
local lpeg_line_cmt_pat = P("//") * (P(1) - S("\n"))^0
-- Block comment: /* ... */ (no nesting per C standard).
local lpeg_block_cmt_pat = P("/*") * (P(1) - P("*/"))^0 * P("*/")
-- String or comment (any of the four forms).
local lpeg_str_or_cmt_pat = lpeg_str_pat + lpeg_chr_pat + lpeg_line_cmt_pat + lpeg_block_cmt_pat

-- Whitespace + comment skipper: zero+ (whitespace run | string | comment).
local ws_pat              = S(" \t\n\r\v\f")
local lpeg_ws_and_cmt_pat = (ws_pat + lpeg_str_or_cmt_pat)^0

-- Generic "skip until target, but step over balanced groups" matcher.
-- Used by scan_to_char for non-ident / non-bracket chars.
-- We accept any single char except the target.
-- The balanced-group stepping is handled by the caller (via read_balanced).
local lpeg_scan_to_target_pat = function(target) return (P(1) - P(target))^0  end

-- ════════════════════════════════════════════════════════════════════════════
-- Section 1: character classification (byte-based for hot loops)
-- ════════════════════════════════════════════════════════════════════════════
-- Byte-based versions (accept a single-byte INTEGER).
-- Used in all hot loops because they avoid the string allocation per s:sub(pos, pos) call.

-- Whitespace characters per C locale.
function M.is_space_byte(b) return b == BYTE_SPACE or b == BYTE_TAB or b == BYTE_NEWLINE or b == BYTE_CR or b == BYTE_VT  or b == BYTE_FF end

-- Letters (a-z, A-Z) and underscore.
function M.is_alpha_byte(b)
	if not b then return false end
	if     b >= BYTE_LOWER_A and b <= BYTE_LOWER_Z then return true end  -- 'a'..'z'
	if     b >= BYTE_UPPER_A and b <= BYTE_UPPER_Z then return true end  -- 'A'..'Z'
	return b == BYTE_UNDERSCORE
end

-- Single digit.
function M.is_digit_byte(b) return b and b >= BYTE_DIGIT_0 and b <= BYTE_DIGIT_9 end

-- Letter OR digit OR underscore.
function M.is_alnum_byte(b) return M.is_alpha_byte(b) or M.is_digit_byte(b) end

-- String-based wrappers (kept for callers that already have a single-char string;
-- the byte versions are what the hot loops should call).
function M.is_space(c)
	if type(c) == "number" then return M.is_space_byte(c) end
	return c == " "  or c == "\t" or c == "\n" or c == "\r" or c == "\v" or c == "\f"
end
function M.is_alpha(c)
	if type(c) == "number" then return M.is_alpha_byte(c) end
	if not c or #c == 0 then return false end
	if     c >= "a" and c <= "z" then return true  end
	if     c >= "A" and c <= "Z" then return true  end
	return c == "_"
end
function M.is_digit(c)
	if type(c) == "number" then return M.is_digit_byte(c) end
	return c and c >= "0" and c <= "9"
end
function M.is_alnum(c) return M.is_alpha(c) or M.is_digit(c) end

-- ════════════════════════════════════════════════════════════════════════════
-- Section 2: string primitives
-- ════════════════════════════════════════════════════════════════════════════

-- Trim leading and trailing whitespace from a string.
function M.trim(s)
	local a = 1;  while a <= #s and M.is_space_byte(s:byte(a)) do a = a + 1 end
	local b = #s; while b >= a  and M.is_space_byte(s:byte(b)) do b = b - 1 end
	return s:sub(a, b)
end

-- Linear-search for a single-byte target in a string.
-- @param haystack string
-- @param target integer  -- byte value
-- @param start integer   -- optional 1-indexed start (default 1)
-- @return integer|nil
function M.find_byte(haystack, target, start)
	for pos = start or 1, #haystack do
		if haystack:byte(pos) == target then return pos end
	end
	return nil
end

-- Returns the directory portion of a path.
function M.dirname(path)
	local last_sep = 0
	for pos = 1, #path do
		local b = path:byte(pos)
		if    b == BYTE_SLASH or b == BYTE_BACKSLASH then last_sep = pos end
	end
	if last_sep == 0 then return "." end
	return path:sub(1, last_sep - 1)
end

-- Returns the basename of a path, with the file extension stripped.
function M.basename_no_ext(path)
	local last_sep = 0
	for pos = 1, #path do
		local b = path:byte(pos)
		if    b == BYTE_SLASH or b == BYTE_BACKSLASH then last_sep = pos end
	end
	local a        = last_sep + 1
	local last_dot = #path + 1
	for pos = #path, a, -1 do
		if path:byte(pos) == BYTE_DOT then last_dot = pos; break end
	end
	return path:sub(a, last_dot - 1)
end

-- ════════════════════════════════════════════════════════════════════════════
-- Section 3: I/O primitives
-- ════════════════════════════════════════════════════════════════════════════

-- File contents intentionally use io.open below. LuaFileSystem handles path 
-- metadata, directory iteration, the current directory, and mkdir; it does not
-- expose file-content read/write streams.
function M.read_file(path)
	local  f = io.open(path, "r")
	if not f then error("Cannot open " .. path) end
	local content = f:read("*a"); f:close()
	return content
end

function M.write_file(path, content)
	local  f = io.open(path, "w")
	if not f then error("Cannot write " .. path) end
	f:write(content); f:close()
end

-- Write content to disk in binary mode so LF line endings are preserved on Windows
-- (text mode would convert LF -> CRLF, breaking byte-identical diffs against git-tracked gen/*.h files which are stored as LF).
-- @param path string
-- @param content string
function M.write_file_lf(path, content)
	local  f = io.open(path, "wb")
	if not f then error("Cannot write " .. path) end
	f:write(content); f:close()
end

-- Return `{path, ...}` for files in `out_root` whose basename matches `pattern` (Lua pattern, NOT regex — `%.` not `\.`).
-- Empty list if `out_root` doesn't exist or matches nothing.
-- @param out_root Path
-- @param pattern string  -- Lua pattern matched against basename only
-- @return string[]
function M.list_dir(out_root, pattern)
	local files = {}
	if lfs.attributes(out_root, "mode") ~= "directory" then return files end
	for entry in lfs.dir(out_root) do
		if entry:match(pattern) then
			files[#files + 1] = out_root .. "\\" .. entry
		end
	end
	return files
end

-- Convert a (possibly relative) path to an absolute path, using CWD if needed.
-- Normalizes forward slashes to backslashes on Windows.
-- Used for byte-identical emit: the // Source: comment line uses the absolute path.
--
-- The CWD is memoized on first call.
-- @param path string
-- @return string
local _absolute_path_cache = {}

function M.to_absolute_path(path)
	if _absolute_path_cache[path] then return _absolute_path_cache[path] end
	if #path >= 2 and path:sub(2, 2) == ":" then
		-- Already absolute; normalize slashes for consistency.
		local result = (path:gsub("/", "\\"))
		_absolute_path_cache[path] = result
		return result
	end
	local  cwd = lfs.currentdir()
	if not cwd then _absolute_path_cache[path] = path; return path end
	cwd = cwd:gsub("/", "\\")
	local tail   = (path:gsub("/", "\\"))
	local result = cwd .. "\\" .. tail
	_absolute_path_cache[path] = result
	return result
end

-- Cache of directories already verified to exist in this process.
local _ensured_dirs = {}

function M.ensure_dir(path)
	if _ensured_dirs[path] then return end
	_ensured_dirs[path] = true
	-- lfs.attributes + lfs.mkdir: ~0ms when dir exists, ~2ms when creating. No shell spawn.
	-- Falls through silently if lfs.mkdir fails (e.g. permission denied); the subsequent write_file will surface the error.
	if lfs.attributes(path, "mode") ~= "directory" then lfs.mkdir(path) end
end

-- Test helper: clear the cache (used by tests + between process runs).
-- Not normally needed since Lua state is per-process.
function M._reset_ensured_dirs() _ensured_dirs = {} end

-- Group a list of `SourceFile`-shaped records by their `dir` field.
-- Used by the annotation / static-analysis / report passes to partition sources into per-DIRECTORY (per-module) buckets
-- before emitting per-module reports. Insertion order preserved within each bucket (matches source order in `ctx.sources`).
-- @param sources table[]          -- list of source records (each having a `dir` string field)
-- @return table<string, table[]>  -- map of `dir` -> sources in that dir
function M.group_sources_by_dir(sources)
	local by_dir = {}
	for _, src in ipairs(sources) do
		by_dir[src.dir] = by_dir[src.dir] or {}
		table.insert(by_dir[src.dir], src)
	end
	return by_dir
end

-- ════════════════════════════════════════════════════════════════════════════
-- Section 4: C-language scanner primitives
-- ════════════════════════════════════════════════════════════════════════════

-- Skip a string or C-style comment starting at position `pos`.
-- Returns the position just past the construct, or `pos` unchanged if no string/comment starts there.
function M.skip_str_or_cmt(s, pos) return lpeg.match(lpeg_str_or_cmt_pat, s, pos) or pos end

-- Skip whitespace AND C-style comments starting at position `pos`.
-- LPeg-backed; ~5-10x faster than a hand-rolled byte-by-byte walker.
function M.skip_ws_and_cmt(s, pos) return lpeg.match(lpeg_ws_and_cmt_pat, s, pos) or pos end

-- Read a C-style identifier (alpha followed by zero+ alnum) starting at position `pos`. 
-- Returns the identifier string + the position just past it, or nil + pos if no identifier starts here.
function M.read_ident(s, pos)
	local result = lpeg.match(lpeg_ident_pat, s, pos)
	if    result then return result, pos + #result end
	return nil, pos
end

-- Read a balanced-delimited group (parens, braces, or brackets) starting at position `pos`.
-- Returns the inner content (between the delimiters) + the position
-- just past the closing delimiter, or nil + pos if `s[pos]` isn't `open_char`.
function M.read_balanced(s, open_char, close_char, pos)
	local open_byte = open_char:byte()
	if s:byte(pos) ~= open_byte then return nil, pos end
	-- scan: <open_char>
	pos = pos + 1
	-- scan: <open_char> <inner...>
	local len   = #s
	local depth = 1
	local a     = pos
	while pos <= len and depth > 0 do
		local c = s:byte(pos)
		if c == open_byte then
			depth = depth + 1
			pos = pos + 1
			-- scan: <open_char> <inner...> <open_char> (depth=depth)
		elseif c == close_char:byte() then
			depth = depth - 1
			if depth == 0 then break end
			pos = pos + 1
			-- scan: <open_char> <inner...> <close_char> (depth=depth)
		else
			local nx = M.skip_str_or_cmt(s, pos)
			if nx > pos then
				-- scan: <open_char> <inner...> <str|cmt>
				pos = nx
			else
				pos = pos + 1
			end
		end
	end
	-- scan: <open_char> <inner> <close_char>
	return s:sub(a, pos - 1), pos + 1
end

-- Convenience specializations of read_balanced.
M.read_parens   = function(s, pos) return M.read_balanced(s, "(", ")", pos) end
M.read_braces   = function(s, pos) return M.read_balanced(s, "{", "}", pos) end
M.read_brackets = function(s, pos) return M.read_balanced(s, "[", "]", pos) end

-- Scan forward from position `start` until we find a specific single byte `target`, 
-- transparently stepping over balanced parens/braces/brackets.
-- Returns the position of `target`, or nil if not found.
function M.scan_to_char(s, target, start)
	local target_byte = target:byte()
	local pos = start
	while pos <= #s do
		local   c = s:byte(pos)
		if      c == target_byte      then return pos end                                          -- scan: ... <target found> | <skipping to target>
		if      c == BYTE_OPEN_PAREN  then local _, a = M.read_balanced(s, "(", ")", pos); pos = a -- scan: ... ( <balanced> ) ...
		elseif  c == BYTE_OPEN_BRACE  then local _, a = M.read_balanced(s, "{", "}", pos); pos = a -- scan: ... { <balanced> } ...
		elseif  c == BYTE_OPEN_BRACK  then local _, a = M.read_balanced(s, "[", "]", pos); pos = a -- scan: ... [ <balanced> ] ...
		else
			local nx = M.skip_str_or_cmt(s, pos)
			pos      = (nx > pos) and nx or (pos + 1)
			-- scan: ... <str|cmt skipped> ...
		end
	end
	return nil
end

-- If `s[pos]` is `#`, skip to the end of the preprocessor directive line (past the newline).
-- Returns the position past the newline, or nil if `s[pos]` is not `#`.
-- scan: #<directive>\n -> past the newline
function M.skip_preprocessor_line(s, pos)
	if s:byte(pos) ~= 35 then return nil end  -- '#'
	local scan = pos
	local len = #s
	while scan <= len and s:byte(scan) ~= BYTE_NEWLINE do
		scan = scan + 1
	end
	return scan + 1
end

-- Split a brace-body into top-level comma-separated tokens. Honors nested parens/braces/brackets and skips strings/comments.
--
-- FIX (2026-07-09): split at top-level NEWLINES and SEMICOLONS too, AND emit a token break after a top-level comment/string. 
-- Previous behavior glued the macro call after a comment into the same token, so `word_count_of_token` only saw the 
-- leading ident (often nil after stripping the comment), undercounting the body.
-- Pure-comment / pure-string chunks (which now appear between real statements) are filtered out so they contribute 0 words instead of 1.
function M.split_top_level_commas(body)
	local tokens      = {}
	local pos         = 1
	local body_len    = #body
	local token_start = 1

	-- True iff `chunk` contains any non-whitespace, non-comment, non-string content 
	-- (i.e., real token material). Walks through ws + comments individually so a chunk like "  /* trailing */ shift_lleft(...)" 
	-- is correctly classified as having real content (the macro call).
	local function has_real_content(chunk)
		local scan = 1
		local len  = #chunk
		while scan <= len do
			if M.is_space(chunk:sub(scan, scan)) then
				scan = scan + 1
			else
				local nx = M.skip_str_or_cmt(chunk, scan)
				if nx > scan then
					scan = nx  -- skipped a comment or string
				else
					return true  -- found real content
				end
			end
		end
		return false
	end

	local function emit(end_pos)
		if end_pos >= token_start then
			local chunk = body:sub(token_start, end_pos)
			if M.trim(chunk) ~= "" then
				if has_real_content(chunk) then
					tokens[#tokens + 1] = chunk
				elseif #tokens > 0 then
					-- Pure comment/string chunk at top level (no preceding instruction content within this chunk).
					-- APPEND it to the LAST token so emit-context callers (components.lua build_component_lines) 
					-- can convert `// trailing comment` to `/* */` and emit it with the macro body.
					-- For word counting, count_token_words only inspects the leading ident, so a trailing comment doesn't affect the count.
					--
					-- This is the second-half fix to commit 98e27c2: the first fix correctly broke top-level comments 
					-- off from the NEXT statement (fixing macro-call word counts); 
					-- This fix preserves them on the PREVIOUS statement (restoring the comments in the emitted .macs.h output).
					tokens[#tokens] = tokens[#tokens] .. chunk
				end
			end
			token_start = end_pos + 1
		end
	end

	while pos <= body_len do
		local  c = body:byte(pos)
		if     c == BYTE_OPEN_PAREN then local _, a = M.read_parens(body, pos);   pos = a -- scan: ... ( <balanced> ...
		elseif c == BYTE_OPEN_BRACE then local _, a = M.read_braces(body, pos);   pos = a -- scan: ... { <balanced> ...
		elseif c == BYTE_OPEN_BRACK then local _, a = M.read_brackets(body, pos); pos = a -- scan: ... ( <balanced> ...
		elseif c == BYTE_COMMA then
			-- scan: ... <token> , <next> ...
			emit(pos - 1)
			pos         = pos + 1
			token_start = pos
		elseif c == BYTE_SEMI then
			-- scan: ... <token> ; <next> ...
			emit(pos - 1)
			pos         = pos + 1
			token_start = pos
		elseif c == BYTE_NEWLINE then
			-- scan: ... <token> \n <next> ...
			emit(pos - 1)
			pos         = pos + 1
			token_start = pos
		else
			local nx = M.skip_str_or_cmt(body, pos)
			if nx > pos then
				-- scan: ... <str|cmt> ...
				-- Skipped a comment or string at top level: emit token break.
				pos = nx
				emit(pos - 1)
			else
				pos = pos + 1
			end
		end
	end
	-- scan: <token> , <token> , ... <token>
	emit(body_len)
	return tokens
end

-- ════════════════════════════════════════════════════════════════════════════
-- Section 4: tokenize_body + build_body_line_index (shared, memoized)
-- ════════════════════════════════════════════════════════════════════════════

local _tokenize_body_cache   = {}
local _body_line_index_cache = {}

--- Tokenize the body inner-text into a flat list of `{tok, rel}` pairs.
--- `tok` is the trimmed token string; `rel` is the byte offset within `body`.
--- Memoized on the body string — first call pays O(body_len), subsequent calls return cached.
--- @param body string
--- @return table[]  -- {{tok=string, rel=integer}, ...}
function M.tokenize_body(body)
	if _tokenize_body_cache[body] ~= nil then return _tokenize_body_cache[body] end
	local out = {}
	local len = #body
	local rel = 1
	while rel <= len do
		local ws_end = M.skip_ws_and_cmt(body, rel)
		if ws_end > rel then rel = ws_end end
		if rel    > len then break end

		local scan = rel
		while scan <= len do
			local c = body:byte(scan)
			-- Terminator bytes (delimit a token at the top level): ',' = 0x2C, '\n' = 0x0A, ';' = 0x3B.
			-- These also appear as separators between argument lists inside the parens/braces/brackets, 
			-- so we stop the scan when we hit any of them.
			if     c == BYTE_COMMA   then break end
			if     c == BYTE_NEWLINE then break end
			if     c == BYTE_SEMI    then break end
			-- Group opener bytes (consume the balanced group via the matching reader): '(' = 0x28, '{' = 0x7B, '[' = 0x5B.
			if     c == BYTE_OPEN_PAREN then local _, a = M.read_parens   (body, scan); scan = a
			elseif c == BYTE_OPEN_BRACE then local _, a = M.read_braces   (body, scan); scan = a
			elseif c == BYTE_OPEN_BRACK then local _, a = M.read_brackets (body, scan); scan = a
			-- String-literal byte ('"' = 0x22 or '\'' = 0x27): skip past the quoted region in one shot.
			elseif c == BYTE_DQUOTE or c == BYTE_SQUOTE then
				scan = M.skip_str_or_cmt(body, scan) + 1
			else
				scan = scan + 1
			end
		end
		local tok = M.trim(body:sub(rel, scan - 1))
		if tok ~= "" then out[#out + 1] = { tok = tok, rel = rel } end
		if scan <= len then
			scan = scan + 1
			local w = M.skip_ws_and_cmt(body, scan)
			if w > scan then scan = w end
		end
		rel = scan
	end
	_tokenize_body_cache[body] = out
	return out
end

--- Build a line-index: count `\n` chars from offset 1 up to the offset; that count + 1 is the line number (1-based).
--- Memoized on the body string.
--- @param body string
--- @return table  -- index[pos] = line_number
function M.build_body_line_index(body)
	if _body_line_index_cache[body] ~= nil then return _body_line_index_cache[body] end
	local index = {}
	local len   = #body
	local newline_count = 0
	for pos = 1, len do
		if pos > 1 then
			index[pos] = newline_count + 1
		end
		-- Newline byte = 0x0A (BYTE_NEWLINE). Counts line boundaries so the
		-- index maps each source-byte offset → its 1-based line number.
		if body:byte(pos) == BYTE_NEWLINE then
			newline_count = newline_count + 1
		end
	end
	index[len + 1] = newline_count + 1
	_body_line_index_cache[body] = index
	return index
end

--- Find the end of a marker call (`atom_label(...)` or `atom_offset(...)`).
--- Returns the position past the closing `)`, or nil if the token isn't a marker call.
--- @param tok string
--- @return integer|nil
function M.find_marker_call_end(tok)
	local  ident, after = M.read_ident(tok, 1)
	if not ident then return nil end
	if ident ~= "atom_label" and ident ~= "atom_offset" then return nil end
	local paren_pos = M.skip_ws_and_cmt(tok, after)
	if tok:sub(paren_pos, paren_pos) ~= "(" then return nil end
	local _, close = M.read_parens(tok, paren_pos)
	return close
end

--- True iff `tok` is an atom-label or atom-offset marker call.
--- Sibling helper to M.find_marker_call_end; uses the same string constants.
--- @param tok string
--- @return boolean
function M.is_marker_token(tok)
	local  leading = M.read_ident(tok, 1)
	return leading == "atom_label" or leading == "atom_offset"
end

--- Count words contributed by the non-marker portion of `tok` (after the marker's closing `)`).
--- Returns 0 if `tok` isn't a marker call or has no trailing content.
---
--- `count_token_words_fn` is injected by the caller rather than imported here because the dependency arrow already points the other way:
--- `passes/offsets.lua` and `passes/atoms_source_map.lua` both `require("word_count_eval")` and pass its `count_token_words` as the 3rd argument to this function,
--- while `word_count_eval` itself loads `duffle` via `duffle_paths.lua` (see `passes/word_count_eval.lua` near the top of the file)
--- and calls `duffle.trim` / `duffle.read_ident` / `duffle.skip_ws_and_cmt` from `M.count_token_words`. Importing `word_count_eval` 
--- from this module would reverse that direction and form a recursive require cycle.
--- The callback keeps the marker-syntax helpers (`find_marker_call_end`, `is_marker_token`, this function)
--- shared in `duffle` without making the foundational utility depend on a pass module.
--- @param tok string
--- @param word_counts table
--- @param count_token_words_fn fun(tok: string, wc: table): integer
--- @return integer
function M.count_marker_rest(tok, word_counts, count_token_words_fn)
	local marker_end = M.find_marker_call_end(tok)
	if not marker_end or marker_end >= #tok then return 0 end
	local rest = M.trim(tok:sub(marker_end))
	if rest == "" then return 0 end
	return count_token_words_fn(rest, word_counts)
end

-- ════════════════════════════════════════════════════════════════════════════
-- Section 5: load_word_counts
-- ════════════════════════════════════════════════════════════════════════════

function M.load_word_counts(metadata_path)
	local counts  = {}
	local content = M.read_file(metadata_path)
	local len     = #content
	local pos     = 1
	local prefix  = "WORD_COUNT("
	while pos <= len do
		local nl       = M.find_byte(content, BYTE_NEWLINE, pos)
		local line_end = nl or (len + 1)
		local line     = content:sub(pos, line_end - 1)
		-- scan: WORD_COUNT(<name>, <N>)
		local trimmed  = M.trim(line)
		if trimmed:sub(1, #prefix) == prefix and trimmed:sub(-1) == ")" then
			local inner = trimmed:sub(#prefix + 1, #trimmed - 1)
			local comma = M.find_byte(inner, BYTE_COMMA, 1)
			if comma then
				counts[M.trim(inner:sub(1, comma - 1))] =
					tonumber(M.trim(inner:sub(comma + 1)))
			end
		end
		pos = line_end + 1
	end
	return counts
end

-- ══════════════════════════════════════════════════
-- Section 6: LineIndex (perf fix — replaces the per-call rescan line_of)
-- ══════════════════════════════════════════════════

function M.LineIndex(source)
	local positions = {}
	local n         = 0
	for pos = 1, #source do
		if source:byte(pos) == BYTE_NEWLINE then
			n = n + 1
			positions[n] = pos
		end
	end
	-- (internal) Binary-search for the line number containing query_pos.
	local function line_of(query_pos)
		local lo,   hi = 1, n
		while lo <= hi do
			local mid = math.floor((lo + hi) / 2)
			if positions[mid] <= query_pos then lo = mid + 1
			else                                hi = mid - 1 end
		end
		return hi + 1
	end
	return line_of
end

-- Section 7: domain tables
-- ════════════════════════════════════════════════════════════════════════════

-- The annotation DSL has been reduced to a single annotation macro: atom_info(atom_bind(Binds_X), atom_reads(...), atom_writes(...))
-- All phase / region / cadence / async / resource / group tokens have been dropped.
-- They may be reintroduced later as optional sub-calls of atom_info;
-- For now, the parser only recognizes atom_info + its three sub-calls (atom_bind, atom_reads, atom_writes).
M.TAPE_ATOM_MACROS = {
	["atom_info"] = { kind = "info", binds = false },
}

-- GTE command-alias resolution table.
--
-- Maps each GTE command macro that may appear in source to its CANONICAL short form.
-- Both forms resolve to the same PSX-SPX-documented pipeline semantics; the canonical
-- name is the only one that appears in `GTE_COMMAND_INPUTS` and the per-check producer / consumer reports.
-- Aliases resolve exactly once; unknown idents (e.g. an MVMVA with a custom `(sf, mx, v, cv, lm)` payload that is not on this list)
-- are reported as "command unknown" by the check, not silently treated as 0-cycle.
--
-- Source conventions (per `code/duffle/gte.h`): The C source ships both short canonical macros
-- (`gte_cmdw_rtps`, `gte_cmdw_rtpt`, `gte_cmdw_nclip`, `gte_cmdw_avsz3`, `gte_cmdw_avsz4`, `gte_cmdw_mvmva`, `gte_cmdw_op`)
-- and human-readable aliases (`gte_cmdw_rotate_translate_perspective_*`, `gte_cmdw_avg_sort_z3`, etc.).
-- Every alias row maps source ident -> canonical short ident.
M.GTE_COMMAND_ALIASES = {
	-- Canonical -> canonical (identity).
	["gte_cmdw_rtps"]                              = "gte_cmdw_rtps",
	["gte_cmdw_rtpt"]                              = "gte_cmdw_rtpt",
	["gte_cmdw_nclip"]                             = "gte_cmdw_nclip",
	["gte_cmdw_mvmva"]                             = "gte_cmdw_mvmva",
	["gte_cmdw_op"]                                = "gte_cmdw_op",
	["gte_cmdw_avsz3"]                             = "gte_cmdw_avsz3",
	["gte_cmdw_avsz4"]                             = "gte_cmdw_avsz4",
	-- Aliases -> canonical.
	["gte_cmdw_rotate_translate_perspective_single"] = "gte_cmdw_rtps",
	["gte_cmdw_rotate_translate_perspective_triple"] = "gte_cmdw_rtpt",
	["gte_cmdw_avg_sort_z3"]                       = "gte_cmdw_avsz3",
	["gte_cmdw_avg_sort_z4"]                       = "gte_cmdw_avsz4",
	["gte_cmdw_outer_product"]                     = "gte_cmdw_op",
	["gte_cmdw_wedge"]                             = "gte_cmdw_op",
	-- Bare-name aliases (no `gte_cmdw_` prefix; used in atom bodies directly):
	-- gte_avg_sort_z3 / gte_avg_sort_z4 are the duffle-side aliases for AVSZ3/4.
	-- alias-to-canonical resolution lives in `check_gte_write_retire` (via
	-- `M.GTE_COMMAND_ALIASES`); see static_analysis.lua :: check_gte_write_retire.
	["gte_avg_sort_z3"]                            = "gte_cmdw_avsz3",
	["gte_avg_sort_z4"]                            = "gte_cmdw_avsz4",
}

-- GTE command input-set table.
--
-- For each canonical command, the set of C2 registers whose recent CPU-to-COP2 write
-- must retire before the command can issue. Per PSX-SPX `docs/psx-spx/docs/cpuspecifications.md:407-419`:
--   * A store to COP2 registers (mtc2/ctc2) has a delay of 2..3 clock cycles.
--   * In most cases the delay is 2 cycles; special cases like writes to IRGB
--     (which additionally affect IR1/IR2/IR3) take 3 cycles.
--   * "Store delays are counted in numbers of clock cycles (not in numbers of opcodes).
--    For 3 cycle delay, one must usually insert 3 cached opcodes (or one uncached opcode)."
--
-- Per PSX-SPX `docs/psx-spx/docs/gtepipelinetimings.md` 
-- (the per-instruction input-latch measurement, which is the SAME phenomenon modeled from the command side), the values are: 
--   rtps:  every data register, every control register (RT/TR/OFX/OFY/H/DQA/DQB)
--   rtpt:  same superset (rtpt reads V0..V2, the RT matrix, the TR vector, OFX/OFY, H, DQA, DQB)
--   nclip: SXY0, SXY1, SXY2 (no RT/TR/OFX inputs)
--   mvmva: variable (depends on the chosen mx / v / cv selector); treated conservatively as the union of all RT + TR + BK + IR columns (the data inputs the command can read).
--   op:    IR1, IR2, IR3 (cross-product output, atomic; consumers treat as fan-out only)
--   avsz3/avsz4: SZ0..SZ3 + ZSF3/ZSF4
--
-- We model the data-register + control-register superset. 
-- Per PSX-SPX `gtepipelinetimings.md`, every relevant input is in this set;
-- the per-input latching values listed there are the SAME number's command-side view
-- (a recent mtc2/ctc2 to that register must retire the same number of cycles before the command issues).
-- Anything not in the set is safe to clobber immediately after a prior command.
M.GTE_COMMAND_INPUTS = {
	-- RTPS / RTPT: every data + every rotation/translation control + screen offset + projection.
	["gte_cmdw_rtps"] = {
		-- Data register file (entire)
		"C2_VXY0", "C2_VZ0", "C2_VXY1", "C2_VZ1", "C2_VXY2", "C2_VZ2",
		"C2_RGB",  "C2_OTZ",
		"C2_IR0",  "C2_IR1",  "C2_IR2", "C2_IR3",
		"C2_SZ0",  "C2_SZ1",  "C2_SZ2", "C2_SZ3",
		-- Rotation matrix (RT) + translation (TR).
		"gte_cr_RT11", "gte_cr_RT12", "gte_cr_RT13",
		"gte_cr_RT21", "gte_cr_RT22", "gte_cr_RT23",
		"gte_cr_RT31", "gte_cr_RT32", "gte_cr_RT33",
		"gte_cr_TRX",  "gte_cr_TRY",  "gte_cr_TRZ",
		-- Screen offset + projection plane distance.
		"gte_cr_OFX",   "gte_cr_OFY",   "gte_cr_H",
		-- Depth queuing parameters (consumed by the depth-cue path inside the perspective op).
		"gte_cr_DQA",   "gte_cr_DQB",
	},
	["gte_cmdw_rtpt"] = {
		-- Same superset as rtps; rtpt repeats rtps three times, so every rtps input also applies here.
		"C2_VXY0", "C2_VZ0", "C2_VXY1", "C2_VZ1", "C2_VXY2", "C2_VZ2",
		"C2_RGB",  "C2_OTZ",
		"C2_IR0",  "C2_IR1",  "C2_IR2", "C2_IR3",
		"C2_SZ0",  "C2_SZ1",  "C2_SZ2", "C2_SZ3",
		"gte_cr_RT11", "gte_cr_RT12", "gte_cr_RT13",
		"gte_cr_RT21", "gte_cr_RT22", "gte_cr_RT23",
		"gte_cr_RT31", "gte_cr_RT32", "gte_cr_RT33",
		"gte_cr_TRX",  "gte_cr_TRY",  "gte_cr_TRZ",
		"gte_cr_OFX",   "gte_cr_OFY",   "gte_cr_H",
		"gte_cr_DQA",   "gte_cr_DQB",
	},
	-- NCLIP: reads SXY0/SXY1/SXY2 only (per PSX-SPX gtepipelinetimings.md §12.6).
	["gte_cmdw_nclip"] = {
		"C2_SXY0", "C2_SXY1", "C2_SXY2",
	},
	-- MVMVA: variable (depends on the chosen mx / v / cv selector).
	--  We Conservatively treats the command's input set as the union of every potential matrix + translation + background-color input.
	-- Any recent write to one of these registers must retire.
	["gte_cmdw_mvmva"] = {
		"C2_VXY0", "C2_VZ0", "C2_VXY1", "C2_VZ1", "C2_VXY2", "C2_VZ2",
		"C2_IR1",  "C2_IR2",  "C2_IR3",
		"gte_cr_RT11", "gte_cr_RT12", "gte_cr_RT13",
		"gte_cr_RT21", "gte_cr_RT22", "gte_cr_RT23",
		"gte_cr_RT31", "gte_cr_RT32", "gte_cr_RT33",
		"gte_cr_TRX",  "gte_cr_TRY",  "gte_cr_TRZ",
	},
	-- OP (outer product): atomic, no inputs that need retiring (the command reads IR1..IR3 but they are local accumulators not driven by the CPU).
	-- The dependency window is the IRGB fan-out (3 cycles) on the OUTPUT side, not the input side.
	["gte_cmdw_op"] = {},
	-- AVSZ3 / AVSZ4: read SZ0..SZ3 + ZSF3/ZSF4.
	["gte_cmdw_avsz3"] = {
		"C2_SZ0", "C2_SZ1", "C2_SZ2", "C2_SZ3",
		"gte_cr_ZSF3",
	},
	["gte_cmdw_avsz4"] = {
		"C2_SZ0", "C2_SZ1", "C2_SZ2", "C2_SZ3",
		"gte_cr_ZSF4",
	},
}

-- COP2 write-retire slot table.
--
-- Number of cached instruction slots required for a recent CPU-to-COP2 write to retire before the next dependent command can issue.
-- Per PSX-SPX `cpuspecifications.md:407-419` and `gtepipelinetimings.md`
-- (every per-input N for a recent mtc2/ctc2, with two cached instructions being the common case and three for IRGB / ORGB writes).
--
-- The model is intentionally small:
--   cpu_to_cop2 -- default for any mtc2 / ctc2 / lwc2 / swc2 to a COP2 register
--   cpu_to_irgb -- override for writes to the IRGB / ORGB control registers (the documented 3-cycle fan-out)
--
-- The downstream check (`check_gte_write_retire`) resolves the per-event class from the C2 destination
-- and the write kind (gte_mv_to_data_r vs. gte_mv_to_ctrl_r + control-register index).
-- A future pass can introduce command-specific per-input-N tables; the structural place to add them is here.
M.COP2_WRITE_RETIRE_SLOTS = {
	cpu_to_cop2 = 2,
	cpu_to_irgb = 3,
}

-- Operand-class table for the COP2->GPR load-delay check.
--
-- Maps each emitting-token ident to the SET of GPR operand positions it READS (not writes).
-- Covers the current encoder vocabulary (`code/duffle/mips.h` + `code/duffle/gte.h`);
-- expand by adding rows here as new encoders land.
--
-- Semantics:
--   * A "GPR operand position" is the textual slot in the macro's argument list,
--     1-based; e.g. `load_word(rt, base, off)` has positional operands 1 (rt), 2 (base), 3 (off);
--     The table reads operands 1 + 2 + 3 to find what GPRs the macro touches.
--   * The check tracks one entry per destination GPR per MFC2/CFC2 event.
--     A subsequent event is considered a "use" iff any of its READ operand positions reference that destination GPR's ident (e.g. `R_T0`).
--   * Branch delay slots are out of scope (MIPS control-flow; tracked separately).
M.OPERAND_READ_POSITIONS = {
	-- CPU ALU with one or two GPR operands. Reads every GPR operand.
	["add_ui"]                 = {1, 2},
	["add_ui_self"]            = {1},
	["add_si"]                 = {1, 2},
	["add_u"]                  = {1, 2, 3},
	["add_u_self"]             = {1, 2},
	["sub_s"]                  = {1, 2, 3},
	["sub_u"]                  = {1, 2, 3},
	["and_i"]                  = {1, 2},
	["and_u"]                  = {1, 2, 3},
	["or_i"]                   = {1, 2},
	["or_i_self"]              = {1},
	["or_u"]                   = {1, 2, 3},
	["or_u_self"]              = {1, 2},
	["xor_i"]                  = {1, 2},
	["xor_u"]                  = {1, 2, 3},
	["slt_s"]                  = {1, 2, 3},
	["slt_u"]                  = {1, 2, 3},
	["slt_si"]                 = {1, 2},
	["slt_ui"]                 = {1, 2},
	["mult_s"]                 = {1, 2},
	["mult_u"]                 = {1, 2},
	["div_s"]                  = {1, 2},
	["div_u"]                  = {1, 2},
	-- Shifts: shift_lleft(rd, rt, shamt); the rt operand is the value, rd is dest.
	["shift_lleft"]            = {1, 2},
	["shift_lright"]           = {1, 2},
	["shift_aright"]           = {1, 2},
	["shift_lleft_self"]       = {1},
	-- Loads: load_word(rt, base, off); the rt operand is the destination (so it's WRITTEN, not read) and base + off are non-GPR operands.
	-- Treat load_* as NOT reading any GPR operand position (the rt WRITE is not a read for our purposes).
	-- The single operand in the table for `load_*` is `rt`, but the check treats it as a write, so we leave the read-positions table empty.
	["load_word"]              = {},
	["load_half_u"]            = {},
	["load_byte_u"]            = {},
	["load_half"]              = {},
	["load_byte"]              = {},
	["load_upper_i"]           = {},
	["load_ui"]                = {},
	-- Stores write to memory; base + rt operands are non-read for load-delay purposes.
	["store_word"]             = {},
	["store_half"]             = {},
	["store_byte"]             = {},
	-- Branches read rs (+ rt for beq/bne). The branch delay slot is out of scope.
	["branch_equal"]           = {1, 2},
	["branch_ne"]              = {1, 2},
	["branch_le_zero"]         = {1},
	["branch_lt_zero"]         = {1},
	["branch_ge_zero"]         = {1},
	["branch_gt_zero"]         = {1},
	-- Jumps / link: jr / jalr read rs only (the target). RD is the destination link.
	["jump_reg"]               = {1},
	["jump_link"]              = {1},
	["call_reg"]               = {1},
	["call_addr"]              = {},
	["jump"]                   = {},
	-- mask_upper is a 2-word macro: shift_lleft then shift_lright. The first reads rt.
	["mask_upper"]             = {1, 2},
	-- move from/to HI/LO.
	["mov_from_high"]          = {},
	["mov_from_low"]           = {},
	["mov_to_high"]            = {1},
	["mov_to_low"]             = {1},
	-- GTE transfers / loads / stores / commands: the relevant table values live in the check itself
	-- (gte_mv_to_* writes its rt operand, gte_mv_from_* writes its rt operand, and `gte_*` commands are atomic-from-the-CPU-POV once they issue. 
	-- They don't trigger load-delay violations because the CPU holds until the command completes).
	["gte_mv_from_data_r"]     = {},
	["gte_mv_from_ctrl_r"]     = {},
	["gte_mv_to_data_r"]       = {},
	["gte_mv_to_ctrl_r"]       = {},
	["gte_lw"]                 = {},
	["gte_sw"]                 = {},
}

-- GP0 packet sizes (total words including the 1-word tag) per GP0 cmd byte.
-- Per PSX-SPX `docs/psx-spx/docs/graphicsprocessingunitgpu.md` §"GPU Render Polygon Commands":
--   Each polygon command's word count = 1 (tag/cmd) + per-vertex (vertex + optional color + optional UV).
--   F3:  cmd + 3 vertices = 4 words; +1 tag = 5
--   F4:  cmd + 4 vertices = 5 words; +1 tag = 6
--   G3:  cmd + 3×(color + vertex) = 6 words; +1 tag = 7
--   G4:  cmd + 4×(color + vertex) = 8 words; +1 tag = 9
--   FT3: cmd + tpage + clut + 3×(vertex + UV) = 7 words; +1 tag = 8
--   FT4: cmd + tpage + clut + 4×(vertex + UV) = 9 words; +1 tag = 10
--   GT3: cmd + tpage + clut + 3×(color + vertex + UV) = 9 words; +1 tag = 10
--   GT4: cmd + tpage + clut + 4×(color + vertex + UV) = 12 words; +1 tag = 13
--
-- Cross-checked against code/duffle/gp.h struct sizes + the set_poly_* macros
-- (which encode "len" = "words after tag"):
--   set_poly_f3(p)   -> set_len(p, 4)   ->  5 total GP0 0x20
--   set_poly_ft3(p)  -> set_len(p, 7)   ->  8 total GP0 0x24
--   set_poly_f4(p)   -> set_len(p, 5)   ->  6 total GP0 0x28
--   set_poly_ft4(p)  -> set_len(p, 9)   -> 10 total GP0 0x2C
--   set_poly_g3(p)   -> set_len(p, 6)   ->  7 total GP0 0x30
--   set_poly_gt3(p)  -> set_len(p, 9)   -> 10 total GP0 0x34
--   set_poly_g4(p)   -> set_len(p, 8)   ->  9 total GP0 0x38
--   set_poly_gt4(p)  -> set_len(p, 12)  -> 13 total GP0 0x3C
M.GP0_CMD_SIZE = {
	[0x20] =  5,  -- Poly_F3
	[0x24] =  8,  -- Poly_FT3
	[0x28] =  6,  -- Poly_F4
	[0x2C] = 10,  -- Poly_FT4
	[0x30] =  7,  -- Poly_G3
	[0x34] = 10,  -- Poly_GT3
	[0x38] =  9,  -- Poly_G4
	[0x3C] = 13,  -- Poly_GT4
}

-- Shape suffix (after `ac_format_` / `mac_format_` prefix) -> GP0 cmd byte.
-- Lets the static-analysis check derive the cmd byte from a macro name like `mac_format_g4_color` -> `g4` -> 0x38 -> 9 expected words.
M.GP0_CMD_BY_SHAPE = {
	["f3"]  = 0x20, ["ft3"] = 0x24,
	["f4"]  = 0x28, ["ft4"] = 0x2C,
	["g3"]  = 0x30, ["gt3"] = 0x34,
	["g4"]  = 0x38, ["gt4"] = 0x3C,
}

-- Per-macro prim-buffer contribution 
-- (NOT .text instruction count this is "how many 32-bit words does this macro write to the primitive being built in main RAM"). 
-- Sum across `mac_format_X_color` + `mac_gte_store_X_post_*` + `mac_insert_ot_tag_X` calls in an atom body must equal GP0_CMD_SIZE[GP0_CMD_BY_SHAPE[shape]].
M.GP0_MACRO_CONTRIB = {
	["mac_format_f3_color"]                         = 1,
	["mac_format_g3_color"]                         = 3,
	["mac_format_g4_color"]                         = 4,
	["mac_gte_store_f3_post_rtpt"]                  = 3,
	["mac_gte_store_g3_post_rtpt"]                  = 3,
	["mac_gte_store_g4_p012_post_rtpt_pre_rtps"]    = 3,
	["mac_gte_store_g4_p3_post_rtps"]               = 1,
	["mac_insert_ot_tag_f3"]                        = 1,
	["mac_insert_ot_tag_g4"]                        = 1,
}

-- Per-macro cycle cost (best-case, no stalls). Used by the static-analysis pass to emit per-atom cycle budgets.
-- The counts cover the EXPANDED instruction sequence the macro emits (NOT just the token it appears as in source).
-- For example:
--   mac_pack_color_word(off, cmd, r, g, b) emits:
--     load_upper_i(R_AT, (cmd << 8) | b)        -- 1 cycle
--     or_i_self(R_AT, (g << 8) | r)             -- 1 cycle
--     store_word(R_AT, R_PrimCursor, off)       -- 1 cycle
--                                              = 3 cycles total
--
--   mac_yield emits a control-transfer sequence (load_word, add_ui_self, jump_reg, nop)
--   which "yields control" the atom body's cycle budget doesn't include the yield's cost (we model it as 0;
--   runtime cost becomes part of the NEXT atom's prologue).
--
-- GTE command values are the GTE instruction's intrinsic cycles (the latency AFTER any pre-cmd `nop2` has retired).
-- When the source emits `nop2, gte_cmdw_X` the nops' cycles are added separately (1+1) plus the gte_cmdw_X value here:
--   rtpt  = 23 + 2 nops = 25 total cycles  (PSX-SPX says 23 cycles for the cmd itself; the nops are pre-fill)
--   rtps  = 15 + 2 nops = 17 total
--   nclip =  8 + 2 nops = 10 total
--   avsz3 =  5 + 2 nops =  7 total
--   avsz4 =  6 + 2 nops =  8 total
--   mvmva =  8 + 2 nops = 10 total
--   op    =  6 (no pre-cmd nops required; atomic)
--
-- Note: the "total" above is the pre-fill nops + the GTE intrinsic cycles. PSX-SPX documents the GTE
-- intrinsic cycles as the total execution time of the command itself (rtpt=23, rtps=15, nclip=8, etc.).
-- The pre-fill nops are a codebase convention for retiring preceding C2 writes, not part of the GTE's
-- own execution time. See `docs/psx-spx/docs/geometrytransformationenginegte.md` for the canonical
-- per-command cycle counts and `docs/psx-spx/docs/gtepipelinetimings.md` for the hardware-verified
-- input-latch boundaries (which show most inputs are safe to clobber after just 0-4 cycles).
M.INSTRUCTION_LATENCY = {
	-- CPU ALU (single-cycle R3000A ops)
	["nop"]                 = 1,
	["nop2"]                = 2,
	["add_ui"]              = 1,  ["add_ui_self"]       = 1,
	["add_s"]               = 1,  ["add_si"]            = 1,
	["add_u"]               = 1,  ["add_u_self"]        = 1,
	["sub_u"]               = 1,  ["sub_s"]             = 1,
	["and_i"]               = 1,  ["and_u"]             = 1,
	["or_i"]                = 1,  ["or_i_self"]         = 1,
	["or_u"]                = 1,  ["or_u_self"]         = 1,
	["xor_i"]               = 1,  ["xor_u"]             = 1,
	["nor_u"]               = 1,
	["shift_lleft"]         = 1,  ["shift_lleft_self"]  = 1,
	["shift_lright"]        = 1,
	["shift_aright"]        = 1,
	["mask_upper"]          = 1,
	["mov_from_high"]       = 2,  -- mfhi: 2 cycles
	["mov_from_low"]        = 2,  -- mflo: 2 cycles
	["mov_to_high"]         = 1,  -- mthi: 1 cycle
	["mov_to_low"]          = 1,  -- mtlo: 1 cycle
	-- Set-on-condition (SLT family)
	["set_lt_u"]            = 1,  ["set_lt_ui"]   = 1,
	["set_lt_s"]            = 1,  ["set_lt_si"]   = 1,
	-- Multiply / divide (no hardware multiplier; software via inline asm)
	["mult_u"]              = 12, ["mult_s"]      = 12,
	["div_u"]               = 35, ["div_s"]       = 35,
	-- Loads (1 cycle + load-delay slot; the delay is typically absorbed by
	-- the next instruction in a well-pipelined sequence, so we count 1)
	["load_word"]           = 1,
	["load_half_u"]         = 1,  ["load_half"]   = 1,
	["load_byte_u"]         = 1,  ["load_byte"]   = 1,
	["load_upper_i"]        = 1,
	-- 2-word loads (lui + ori) used for >16-bit immediates
	["load_imm"]            = 2,
	["load_imm_1w"]         = 1,
	["load_imm_1w_s0"]      = 1,
	["load_imm_2w"]         = 2,
	["load_imm_2w_addi_forced"] = 2,
	["load_imm_2w_ori_forced"]  = 2,
	-- Stores (1 cycle each)
	["store_word"]          = 1,
	["store_half"]          = 1,
	["store_byte"]          = 1,
	-- Branches (branch + BD slot nop = 2 cycles; the BD slot's nop is
	-- counted as part of the branch's cost)
	["branch_equal"]        = 2,  ["branch_ne"]          = 2,
	["branch_le_zero"]      = 2,  ["branch_lt_zero"]     = 2,
	["branch_ge_zero"]      = 2,  ["branch_gt_zero"]     = 2,
	-- Jumps (jump + BD slot nop = 2 cycles)
	["jump"]                = 2,  ["jump_reg"]           = 2,
	["jump_link"]           = 2,  ["call_reg"]           = 2,
	["call_addr"]           = 2,
	-- COP2 transfers (mtc2/mfc2/ctc2/cfc2 = 1 cycle + COP2 latency; the
	-- COP2 latency is usually absorbed by subsequent nops or by the next
	-- GTE command's pre-fill nops, so we count 1)
	["gte_mv_to_data_r"]    = 1,
	["gte_mv_from_data_r"]  = 1,
	["gte_mv_to_ctrl_r"]    = 1,
	["gte_mv_from_ctrl_r"]  = 1,
	["gte_lw"]              = 1,  ["gte_lwc2"]           = 1,
	["gte_sw"]              = 1,  ["gte_swc2"]           = 1,
	-- COP2 commands (intrinsic cycles per PSX-SPX, 
	-- EXCLUDING the 2 pre-cmd nops that the source typically emits as `nop2, gte_cmdw_X`; 
	-- those nops are counted separately via the `nop2` entry above)
	["gte_cmdw_rtpt"]          = 23,  -- RTPT: 23 cycles (PSX-SPX)
	["gte_cmdw_rtps"]          = 15,  -- RTPS: 15 cycles (PSX-SPX)
	["gte_cmdw_nclip"]         = 8,   -- NCLIP: 8 cycles (PSX-SPX)
	["gte_cmdw_avsz3"]         = 5,   -- AVSZ3: 5 cycles (PSX-SPX)
	["gte_cmdw_avsz4"]         = 6,   -- AVSZ4: 6 cycles (PSX-SPX)
	["gte_cmdw_mvmva"]         = 8,   -- MVMVA: 8 cycles (PSX-SPX)
	["gte_cmdw_op"]            = 6,   -- OP: 6 cycles (PSX-SPX)
	["gte_cmdw_outer_product"] = 6,   -- alias for OP
	["gte_cmdw_wedge"]         = 6,   -- alias for OP
	-- Long-form aliases (same cost as canonical)
	["gte_cmdw_rotate_translate_perspective_single"] = 15,  -- alias for rtps
	["gte_cmdw_rotate_translate_perspective_triple"] = 23,  -- alias for rtpt
	["gte_cmdw_avg_sort_z4"]                         = 6,   -- alias for avsz4
	-- Non-cmdw aliases from gte.h (these are `#define gte_X gte_cmdw_Y`):
	["gte_avg_sort_z3"]                              = 5,   -- alias for avsz3
	["gte_avg_sort_z4"]                              = 6,   -- alias for avsz4
	["gte_rtps"]                                     = 15,  -- alias for rtps
	["gte_rtpt"]                                     = 23,  -- alias for rtpt
	["gte_nclip"]                                    = 8,   -- alias for nclip
	["gte_avsz3"]                                    = 5,
	["gte_avsz4"]                                    = 6,
	-- Single-cycle store helpers (gte_stotz, gte_stsxy3 are 1 cycle)
	["gte_stotz"]           = 1,
	["gte_stsxy3"]          = 1,
	-- High-level GTE helpers (gte_load_v0/v1/v2 do multiple lwc2s)
	["gte_load_v0"]         = 2,  -- 1 lwc2 for VXY0 + 1 for VZ0
	["gte_load_v1"]         = 2,
	["gte_load_v2"]         = 2,
	["gte_load_v0v1v2"]     = 6,
	-- mac_* helpers (cycle cost = sum of the expanded instructions)
	-- mac_yield transfers control; cycle budget is 0 (the next atom absorbs the cost).
	["mac_yield"]                                = 0,
	["mac_pack_color_word"]                      = 3,  -- lui + ori + sw
	["mac_format_f3_color"]                      = 3,  -- = mac_pack_color_word
	["mac_format_g4_color"]                      = 12, -- 4 x mac_pack_color_word
	["mac_load_tri_indices"]                     = 3, -- 3 x lhu
	["mac_gte_load_tri_verts"]                   = 18, -- 3 x {sll, addu, lw, lw, mtc2, mtc2}
	["mac_gte_store_f3_post_rtpt"]               = 3,
	["mac_gte_store_g3_post_rtpt"]               = 3,
	["mac_gte_store_g4_p012_post_rtpt_pre_rtps"] = 3,
	["mac_gte_store_g4_p3_post_rtps"]            = 1,
	["mac_insert_ot_tag_f3"]                     = 11,  -- 11 .word slots in the macro body
	["mac_insert_ot_tag_g4"]                     = 11,
	-- Annotation markers (emit no code; pure metaprogram hints)
	["atom_label"]          = 0,
	["atom_offset"]         = 0,
	["atom_info"]           = 0,
	["atom_bind"]           = 0,
	["atom_reads"]          = 0,
	["atom_writes"]         = 0,
}

-- Default cycle cost for unknown macros.
-- The static-analysis pass adds 1 cycle per unknown token and emits a "new macro; update INSTRUCTION_LATENCY"
-- advisory so the cycle budget stays accurate as the codebase grows.
M.UNKNOWN_INSTRUCTION_CYCLES = 1

-- Control-transfer (branch/jump/call) delay-slot policy table.
--
-- Used by the emitted-word delay-slot check to identify which emitted machine-word idents 
-- are control transfers whose next emitted word is the hardware delay slot.
-- One table row per emitted encoder; the `family` field is informational (informational only; 
-- the check matches by `event.ident` against the row keys).
-- `suppress_arg1` (when present) lists first-arg values that should NOT emit a finding even when the next emitted word is 
-- `nop` or absent — e.g. the fixed `mac_yield()` handshake uses `jump_reg(R_AtomJmp), nop` and is intentionally suppressed.
--
-- Consumers:
--   * passes/static_analysis.lua::check_control_transfer_delay_slot_use
-- No other pass consumes this table as of 2026-07-23.
M.CONTROL_TRANSFER_DELAY_SLOT_POLICIES = {
	branch_equal    = { family = "branch" },
	branch_ne       = { family = "branch" },
	branch_lt_zero  = { family = "branch" },
	branch_ge_zero  = { family = "branch" },
	branch_le_zero  = { family = "branch" },
	branch_gt_zero  = { family = "branch" },
	jump            = { family = "jump" },
	jump_reg        = {
		family = "jump",
		-- The fixed `mac_yield()` 4-word handshake (defined in `lottes_tape.h`) ends in `jump_reg(R_AtomJmp), nop`. 
		-- The `nop` is structural, not an optimization opportunity — suppress it so the check stays signal-only.
		suppress_arg1 = { R_AtomJmp = "fixed mac_yield handshake" },
	},
	jump_link       = { family = "call" },
	call_reg        = { family = "call" },
	call_addr       = { family = "call" },
}

-- ════════════════════════════════════════════════════════════════════════════
-- Section 8: Cross-source component-body index + word-event expansion
-- ════════════════════════════════════════════════════════════════════════════
--
-- Two pure helpers that supersede the per-pass local component-body builders (`atoms_source_map.build_cross_source_component_body_index`)
-- and provide the shared, memoized "semantic emitted-word event stream" every downstream pass can read from without re-walking the pre-tokenized bodies.

--- @class ComponentBodyEntry
--- @field body_tokens    table        -- pre-tokenized {{tok=string, rel=integer}, ...}
--- @field body_off       integer      -- byte offset of body[1] in `source`
--- @field line_of        fun(pos:integer):integer  -- byte-offset → 1-based line number in `source`
--- @field source         string       -- absolute path of the source containing the declaration
--- @field declaration    integer      -- 1-based line number of the MipsAtomComp_(ac_X) declaration
--- @field kind           string       -- "comp_bare" | "comp_proc"

--- @class WordEvent
--- @field word           integer      -- 0-based word index across the entire expansion (root atom + recursed bodies)
--- @field ident          string       -- leading identifier of the emitting token (for nop2 → "nop")
--- @field args           string[]     -- top-level comma-split args of the emitting token (trimmed)
--- @field source         string       -- where the token is defined (component source for recursed; atom source for root)
--- @field line           integer      -- source line of the token (within `source`)
--- @field call_source    string       -- always the ROOT atom's source path (preserved across recursion)
--- @field call_line      integer      -- root atom's call-site line (preserved across recursion)

--- @class WordEventError
--- @field kind           string       -- "cycle" (currently the only error kind)
--- @field msg            string       -- deterministic human-readable description
--- @field source         string       -- path of the source containing the offending token
--- @field line           integer      -- 1-based line of the offending token within `source`

--- Build (and memoize) the cross-source component-body index keyed by the BARE component name (`gte_load_tri_verts`, NOT `ac_gte_load_tri_verts`).
---
--- Components are declared in one source (the header holding `MipsAtomComp_(ac_X)` or `MipsAtomComp_Proc_(ac_X, { ... })`) but invoked from any source that calls `mac_X(...)`. 
--- Body-offsets + body_tokens + line_of live with the declaration, so a per-source index misses invocations from other sources
--- (this is the bug class that motivated moving the index to duffle).
---
--- Only `comp_bare` / `comp_proc` declarations contribute (a `mac_X(...)` invocation can only resolve to one of those).
--- First declaration wins; subsequent redeclarations would collide, but today's sources declare each component exactly once.
---
--- The memoized table is stored at `ctx.shared.component_body_index` so callers can detect "already built" without re-scanning every source. Idempotent:
--- safe to call from multiple passes within the same build.
--- @param ctx table -- the PassCtx; reads `ctx.sources` + writes `ctx.shared.component_body_index`
--- @return table<string, ComponentBodyEntry>
function M.get_component_body_index(ctx)
	local shared = ctx.shared or {}
	if shared.component_body_index ~= nil then return shared.component_body_index end
	local index = {}
	for _, src in ipairs(ctx.sources or {}) do
		if src.scan and src.scan.atoms then
			local line_of = src.scan.line_of
			for _, atom in ipairs(src.scan.atoms) do
				if atom.kind == "comp_bare" or atom.kind == "comp_proc" then
					-- Prefer `atom.name` (the bare identifier, stripped of `ac_`); fall back to `raw_name`
					-- only if the stripped name is absent (defensive — current scan-source always sets both).
					local name = atom.name or atom.raw_name
					if name and not index[name] then
						index[name] = {
							body_tokens = atom.body_tokens,
							body_off    = atom.body_off,
							line_of     = line_of,
							source      = src.path,
							declaration = atom.line,
							kind        = atom.kind,
						}
					end
				end
			end
		end
	end
	shared.component_body_index = index
	ctx.shared  = shared
	return index
end

-- ASCII byte constants used by split_top_level_args (kept local to keep Section 8 self-contained).
local E_BYTE_OPEN_PAREN  = 0x28
local E_BYTE_OPEN_BRACE  = 0x7B
local E_BYTE_OPEN_BRACK  = 0x5B
local E_BYTE_DQUOTE      = 0x22
local E_BYTE_SQUOTE      = 0x27
local E_BYTE_COMMA       = 0x2C

-- Map an open-delimiter byte to its matching close string for read_balanced.
local E_OPEN_CLOSE = {
	[E_BYTE_OPEN_PAREN] = ")",
	[E_BYTE_OPEN_BRACE] = "}",
	[E_BYTE_OPEN_BRACK] = "]",
}

-- Split the INSIDE of a `f(...)` call on top-level commas.
-- Honors nested parens / braces / brackets and skips strings / comments.
-- Returns a list of trimmed argument strings in source order.
-- (Mirrors split_top_level_commas but for paren-body args; intentionally distinct so a caller's brace-body split isn't confused with an arg list.)
-- @param inner string
-- @return string[]
local function split_top_level_args(inner)
	local args = {}
	if not inner or inner == "" then return args end
	local pos   = 1
	local len   = #inner
	local start = 1
	while pos <= len do
		local c     = inner:byte(pos)
		local close = E_OPEN_CLOSE[c]
		if close then
			local _, after = M.read_balanced(inner, string.char(c), close, pos)
			pos = after
		elseif c == E_BYTE_DQUOTE or c == E_BYTE_SQUOTE then
			pos = M.skip_str_or_cmt(inner, pos)
		elseif c == E_BYTE_COMMA then
			args[#args + 1] = M.trim(inner:sub(start, pos - 1))
			start = pos + 1
			pos   = pos + 1
		else
			pos = pos + 1
		end
	end
	if start <= len then args[#args + 1] = M.trim(inner:sub(start, len)) end
	return args
end

-- Extract the leading identifier + top-level args list from a token string.
-- Returns (ident, args). For tokens without a `(...)` call, args is `{}`.
-- @param tok string
-- @return string, string[]
local function token_ident_and_args(tok)
	local ident, after = M.read_ident(tok, 1)
	if not ident then return "?", {} end
	local paren_pos = M.skip_ws_and_cmt(tok, after)
	if tok:sub(paren_pos, paren_pos) ~= "(" then return ident, {} end
	local inner = M.read_parens(tok, paren_pos)
	if not inner then return ident, {} end
	return ident, split_top_level_args(inner)
end

-- The macro-name prefix that marks a `mac_X(...)` component invocation.
local E_MAC_PREFIX     = "mac_"
local E_MAC_PREFIX_LEN = 4

--- Expand a body entry into the flat sequence of emitted machine-word events.
---
--- Semantics (one event per emitted machine word):
---   * **Direct one-word encoders** (`load_word`, `add_ui`, `nop`, `gte_lw`, ...): one event with `ident` = leading ident, `args` = parsed top-level args.
---   * **`nop2`** (2-word pseudo-instruction): two events, BOTH with `ident = "nop"` so the canonical "this slot is a no-op" semantic is visible to downstream analyses.
---   * **Any other N-word token** in `word_counts` (e.g. `mask_upper` = 2, `load_imm_2w` = 2): N events sharing the same `ident` + `args` so useful CPU words retire slots in the cycle budget.
---   * **Known `mac_X(...)` calls**: recursively expand the indexed component body, including nested components. Every event from the expansion carries:
---     - `source` / `line` = the COMPONENT'S source path + the line of the token within the component body (i.e. "definition site").
---     - `call_source` / `call_line` = the ROOT atom's source path + call-site line, PRESERVED across recursion (nested-nested events still point at the original root, not at an intermediate component).
---   * **Unknown `mac_X`** (not in `component_index`): fall back to `word_counts[ident]` if present; otherwise emit exactly one opaque event so the cycle budget still accounts for the word.
---   * **Marker tokens** (`atom_label(...)` / `atom_offset(...)`): zero events (they are pure metaprogram hints, not emitted machine words).
---
--- Cycle protection: a per-expansion `visiting` set tracks components currently on the expansion stack; a re-entry produces a deterministic `{kind = "cycle", ...}` error and aborts that branch (does NOT hang, does NOT recurse).
---
--- Pure: does NOT mutate `body_entry`, `component_index`, or `word_counts`. Memoization is the caller's responsibility (callers that want it precomputed for many atoms should memoize `word_events` / `word_event_errors` per atom).
--- @param body_entry       table        -- `{body_tokens, body_off, line_of, source, declaration}` (declaration = root atom's atom.line)
--- @param component_index  table        -- the bare-name → ComponentBodyEntry map from M.get_component_body_index
--- @param word_counts      table        -- macro name → emitted-word count (from `ctx.shared.word_counts`)
--- @return WordEvent[], WordEventError[]
function M.expand_word_events(body_entry, component_index, word_counts)
	local events = {}
	local errors = {}

	-- `word_idx` is 0-based across the entire expansion (root atom body + every recursed component body).
	-- Each emitted machine word consumes one slot.
	local word_idx = 0

	local root_call_source = body_entry.source
	local root_call_line   = body_entry.declaration or 0

	local function expand(tokens, body_off, line_of, def_source, call_source, call_line, visiting)
		for _, bt in ipairs(tokens) do
			local tok = M.trim(bt.tok or "")
			if tok ~= "" then
				local ident, args = token_ident_and_args(tok)
				local tok_line    = (line_of and line_of(body_off + bt.rel)) or 0

				if ident == "atom_label" or ident == "atom_offset" then
					-- Marker: zero events.
				else
					-- Strip the `mac_` prefix to look up the component by its BARE name.
					local bare = nil
					if ident:sub(1, E_MAC_PREFIX_LEN) == E_MAC_PREFIX then
						bare = ident:sub(E_MAC_PREFIX_LEN + 1)
					end

					if bare and component_index and component_index[bare] then
						if visiting[bare] then
							-- Cycle: this component is already on the expansion stack.
							errors[#errors + 1] = {
								kind   = "cycle",
								msg    = string.format("component cycle detected involving %q", bare),
								source = def_source,
								line   = tok_line,
							}
						else
							visiting[bare] = true
							local inner = component_index[bare]
							-- `call_source` / `call_line` (the ROOT atom site) are PRESERVED — we do NOT update them when recursing.
							-- Nested events keep pointing at the original root atom.
							expand(inner.body_tokens, inner.body_off, inner.line_of,
								inner.source, call_source, call_line, visiting)
							visiting[bare] = nil
						end
					else
						-- Direct token (or unknown `mac_X` falling back). Emit `n` events.
						local n = 1
						if word_counts and word_counts[ident] then n = word_counts[ident] end
						local out_ident = (ident == "nop2") and "nop" or ident
						for _ = 1, n do
							word_idx = word_idx + 1
							events[#events + 1] = {
								word        = word_idx - 1,
								ident       = out_ident,
								args        = args,
								source      = def_source,
								line        = tok_line,
								call_source = call_source,
								call_line   = call_line,
							}
						end
					end
				end
			end
		end
	end

	-- Initial call: the root atom body. `def_source` and `call_source` both start at the atom's source;
	-- `call_line` starts at the atom's declaration line (every event from the root body inherits this).
	expand(
		body_entry.body_tokens,
		body_entry.body_off or 0,
		body_entry.line_of,
		body_entry.source,
		root_call_source,
		root_call_line,
	{})

	return events, errors
end

return M
