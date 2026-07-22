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

-- Required native extension: lfs (LuaFileSystem). Built by `update_deps.ps1` to
-- `toolchain/lfs/lfs.dll` and wired into package.cpath by `scripts/duffle_paths.lua`.
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
--- TODO(Ed): Review this "not imported" assertion. Why do we have this if its not imported or is it actually?
--- `count_token_words_fn` is passed in (not imported) to keep this module free of pass-module dependencies.
--- Both call sites already import `word_count_eval.count_token_words`; they pass it as the 3rd arg.
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

-- The annotation DSL has been reduced to a single annotation macro:
--   atom_info(atom_bind(Binds_X), atom_reads(...), atom_writes(...))
-- All phase / region / cadence / async / resource / group tokens have been dropped.
-- They may be reintroduced later as optional sub-calls of atom_info; 
-- for now, the parser only recognizes atom_info + its three sub-calls (atom_bind, atom_reads, atom_writes).
M.TAPE_ATOM_MACROS = {
	["atom_info"] = { kind = "info", binds = false },
}

-- GTE pipeline-fill latency table.
--
-- For each `gte_cmdw_*` macro in code/duffle/gte.h, the minimum number of consecutive COP2 "nop" words that MUST appear
-- before the command issues so that any preceding `lwc2`/`swc2`/C2 state writes have retired before the GTE starts reading its input registers.
--
-- The check (`scripts/passes/static_analysis.lua :: check_gte_pipeline_fill`) walks each atom body,
-- counts the consecutive nop words before every `gte_cmdw_*` invocation, and reports a finding if the count is below this minimum.
--
-- PRE-FILL vs POST-FILL: this table models PRE-cmdw nops (retiring preceding C2 writes).
-- The PSX-SPX pipeline timings doc (`docs/psx-spx/docs/gtepipelinetimings.md`) measures a DIFFERENT number:
-- the smallest N nops between `cop2` and `mtc2` to a specific input register at which the write no longer affects the output.
-- For nearly all instructions, inputs latch in the first 0-4 cycles — the GTE snapshots its input register file early and works
--  from internal pipeline storage afterward. 
-- The documented total cycle count is NOT the "do not touch inputs" window; the actual read window is much shorter.
--
-- The `gte_rtpt()` / `gte_nclip()` wrapper macros in gte.h emit the pre-cmd nops internally (asm_words(nop, nop, ...)),
-- but THOSE WRAPPERS ARE NOT USED INSIDE ATOM BODIES in this codebase.
-- Every MipsAtom_(name) body uses raw `nop2, gte_cmdw_<X>, ...` form instead — that `nop2,` is the pre-fill this check validates.
-- So values here reflect the source-level convention, NOT the wrapper-internal pre-fill.
--
-- Cycle counts from PSX-SPX `docs/psx-spx/docs/geometrytransformationenginegte.md`:
--   cmd      PSX-SPX cycles  min pre-nops  rationale
--   rtps         15              2         8c per perspective divide + 6c for IR1..4 + mac write
--   rtpt         23              2         3x rtps worth of pipeline depth (per-vertex pipeline fill)
--   nclip         8              2         MAC0 write + 5c for sign computation
--   avsz3         5              2         5c to compute average + write OTZ (all inputs latch at N=0)
--   avsz4         6              2         avsz3 + 1c extra for 4th vertex
--   mvmva         8              2         IR1..4 write + matrix work (8c regardless of mx/v/cv selection)
--   op            6              0         cross product; output to IR1..3 only (atomic 6c calc, no pre-fill needed)
--
-- The pre-nop values (2 for most commands) are conservative: PSX-SPX pipeline timings show most inputs latch at N=0-1
-- relative to a preceding mtc2, but 2 nops is the gte.h convention for retiring preceding lwc2/swc2 + C2 state.
-- OP is set to 0 because it's a short atomic op with no input that needs a long retire window.
--
-- Aliases are listed separately because source code may use either the alias or the canonical name.
M.GTE_PIPELINE_LATENCY = {
	-- Minimum number of consecutive `nop` words that must appear IMMEDIATELY BEFORE a `gte_cmdw_<X>` invocation
	-- to retire any preceding `lwc2` / `swc2` / pre-existing C2 state writes before the GTE pipeline starts reading
	-- from V0/V1/V2 or MAC0..3 / OTZ / IR0..3 at the command's issue cycle.
	--
	-- Values are from the doxygen comments in code/duffle/gte.h and cross-checked against
	-- PSX-SPX `docs/psx-spx/docs/geometrytransformationenginegte.md` (cycle counts) and
	-- `docs/psx-spx/docs/gtepipelinetimings.md` (input-latch boundaries).

	-- Canonical macros (from code/duffle/gte.h)
	["gte_cmdw_rtps"]   = 2,  -- RTPS: 15 cycles (PSX-SPX)
	["gte_cmdw_rtpt"]   = 2,  -- RTPT: 23 cycles (PSX-SPX)
	["gte_cmdw_nclip"]  = 2,  -- NCLIP: 8 cycles (PSX-SPX)
	["gte_cmdw_op"]     = 0,  -- OP: 6 cycles, atomic (PSX-SPX)
	["gte_cmdw_mvmva"]  = 2,  -- MVMVA: 8 cycles (PSX-SPX)
	["gte_cmdw_avsz3"]  = 2,  -- AVSZ3: 5 cycles (PSX-SPX)
	["gte_cmdw_avsz4"]  = 2,  -- AVSZ4: 6 cycles (PSX-SPX)

	-- Aliases (must have the same value as their canonical target)
	["gte_cmdw_rotate_translate_perspective_single"] = 2,
	["gte_cmdw_rotate_translate_perspective_triple"] = 2,
	["gte_cmdw_avg_sort_z4"]                         = 2,

	-- Outer product aliases (same canonical op, 0 pre-fill nops).
	-- gte_cmdw_op            = canonical GTE-internal short form
	-- gte_cmdw_outer_product = NOCASH / SDK-readable form
	-- gte_cmdw_wedge         = geometric-algebra (exterior-product) form
	["gte_cmdw_outer_product"] = 0,
	["gte_cmdw_wedge"]         = 0,
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
	["mult_u"]              = 12, ["mult_s"]              = 12,
	["div_u"]               = 35, ["div_s"]               = 35,
	-- Loads (1 cycle + load-delay slot; the delay is typically absorbed by
	-- the next instruction in a well-pipelined sequence, so we count 1)
	["load_word"]           = 1,
	["load_half_u"]         = 1,  ["load_half"]           = 1,
	["load_byte_u"]         = 1,  ["load_byte"]           = 1,
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
	-- COP2 commands (intrinsic cycles per PSX-SPX, EXCLUDING the 2 pre-cmd nops that
	-- the source typically emits as `nop2, gte_cmdw_X`; those nops are counted
	-- separately via the `nop2` entry above)
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
	-- mac_yield transfers control; cycle budget is 0 (the next atom
	-- absorbs the cost).
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

return M
