--- duffle.lua — shared primitives + domain tables for the tape-atom metaprograms.
---   * Character classification: `is_space`, `is_alpha`, `is_alnum`, `is_digit`, plus the byte-fast `_byte` variants.
---   * String / path primitives: `trim`, `dirname`, `basename_no_ext`, `normalize_path`, `canonical_path_key`, `find_byte`.
---   * I/O primitives:           `read_file`, `write_file`, `ensure_dir`.
---   * Corpus resolution:        `parse_direct_quoted_includes`, `resolve_source_corpus`.
---   * C-language scanner:       `skip_ws_and_cmt`, `skip_str_or_cmt`, `read_ident`, `read_parens`, `read_braces`, `read_brackets`, `read_balanced`, `scan_to_char`, `split_top_level_commas`.
---   * Word-count loader:        `load_word_counts` for `WORD_COUNT(...)` metadata files.
---   * Line lookup:              `LineIndex` returns an O(log N) `line_of(pos)` closure for source-mapping.
---   * Domain tables:            `TAPE_ATOM_MACROS`, `GTE_PIPELINE_LATENCY`, `GP0_CMD_SIZE`, `GP0_CMD_BY_SHAPE`, `INSTRUCTION_LATENCY`.

local M = {}

-- Required native extension: lfs (LuaFileSystem). Built by `update_deps.ps1` to `toolchain/lfs/lfs.dll` and wired into package.cpath by `scripts/duffle_paths.lua`.
-- If lfs is missing, `require` throws — fail loud per the build-tool convention.
local lfs = require("lfs")

-- ════════════════════════════════════════════════════════════════════════════
-- Cross-file type aliases
-- ════════════════════════════════════════════════════════════════════════════

--- @alias Path        string   -- Absolute or CWD-relative file path
--- @alias LineNum     integer  -- 1-indexed source line number
--- @alias ByteOff     integer  -- 0-indexed byte offset within a source string
--- @alias MacroName   string   -- lower_snake_case macro identifier (e.g. "mac_yield")
--- @alias AtomName    string   -- lower_snake_case atom name (e.g. "cube_g4_face")
--- @alias Severity    string   -- "error" | "warning" | "info"

--- @class SourceFile
--- @field path     Path      -- Absolute path to the source file
--- @field text     string    -- Full source text
--- @field dir      string    -- Directory containing the source
--- @field basename string    -- Filename without extension

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

-- ════════════════════════════════════════════════════════════════════════════
-- Section 0: LPeg patterns (compiled once at module load)
-- ════════════════════════════════════════════════════════════════════════════
--
-- LPeg is a required dependency (PEG library). It's loaded via `package.cpath` — `duffle_paths.lua` wires the path to `toolchain/lpeg/lpeg.dll`.
-- LPeg handles the high-level scanner; the byte-by-byte helpers in Section 1 handle classification primitives that LPeg's CPython-level cost would dominate.
--
-- If the require fails, fail loud with an actionable message. The build script (`update_deps.ps1`) builds lpeg.dll into `toolchain/lpeg/`; run it when the dll is missing.
local lpeg_ok, lpeg = pcall(require, "lpeg")
if not lpeg_ok then
	io.stderr:write("[duffle] require('lpeg') failed: ", lpeg, "\n")
	io.stderr:write("[duffle] lpeg.dll not found on package.cpath.\n")
	io.stderr:write("[duffle] Run 'scripts/update_deps.ps1' to build it into toolchain/lpeg/.\n")
	os.exit(1)
end
local P, S, R = lpeg.P, lpeg.S, lpeg.R

-- Character class patterns
local alpha_pat      = R("AZ", "az") + P("_")
local digit_pat      = R("09")
local lpeg_alnum_pat = alpha_pat + digit_pat

-- Identifier: alpha followed by zero+ alnum. Capture as a string.
local lpeg_alpha_pat = alpha_pat
local lpeg_ident_pat = lpeg.C(alpha_pat * lpeg_alnum_pat^0)

local lpeg_str_pat        = P('"') * (P(1) - S('"\\') + P('\\') * P(1))^0 * P('"') -- String literal: "..." with backslash escapes.
local lpeg_chr_pat        = P("'") * (P(1) - S("'\\") + P('\\') * P(1))^0 * P("'") -- Char literal: '...' with backslash escapes.
local lpeg_line_cmt_pat   = P("//") * (P(1) - S("\n"))^0                           -- Line comment: // ... to end-of-line.
local lpeg_block_cmt_pat  = P("/*") * (P(1) - P("*/"))^0 * P("*/")                 -- Block comment: /* ... */ (no nesting per C standard).
local lpeg_str_or_cmt_pat = lpeg_str_pat + lpeg_chr_pat + lpeg_line_cmt_pat + lpeg_block_cmt_pat -- String or comment (any of the four forms).

-- Whitespace + comment skipper: zero+ (whitespace run | string | comment).
local ws_pat              = S(" \t\n\r\v\f")
local lpeg_ws_and_cmt_pat = (ws_pat + lpeg_str_or_cmt_pat)^0

-- Generic "skip until target, but step over balanced groups" matcher.
-- Used by scan_to_char for non-ident / non-bracket chars. We accept any single char except the target.
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

-- String-based wrappers (kept for callers that already have a single-char string; the byte versions are what the hot loops should call).
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

--- Linear-search for a single-byte target in a string.
--- @param haystack string
--- @param target   integer  -- byte value
--- @param start    integer  -- optional 1-indexed start (default 1)
--- @return integer|nil
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

--- Parse the lexical root without changing display spelling.
--- UNC server/share names are part of the immutable root; drive-relative paths remain distinct from drive-absolute paths.
local function parse_path_root(input)
	local drive = input:match("^(%a:)")
	if drive then
		if input:sub(3, 3) == "/" then
			local rest = input:sub(4)
			while rest:sub(1, 1) == "/" do rest = rest:sub(2) end
			return { kind = "drive_absolute", prefix = drive .. "/", rest = rest, anchored = true }
		end
		return { kind = "drive_relative", prefix = drive, rest = input:sub(3), anchored = false }
	end

	if input:sub(1, 2) == "//" then
		local server_start = 3
		local server_end   = M.find_byte(input, BYTE_SLASH, server_start)
		if not server_end or server_end == server_start then
			error("UNC path requires //server/share: " .. input, 3)
		end
		local server = input:sub(server_start, server_end - 1)
		local share_start = server_end + 1
		while input:sub(share_start, share_start) == "/" do
			share_start = share_start + 1
		end
		local share_end = M.find_byte(input, BYTE_SLASH, share_start) or (#input + 1)
		if share_end == share_start then
			error("UNC path requires //server/share: " .. input, 3)
		end
		local share = input:sub(share_start, share_end - 1)
		local rest  = input:sub(share_end + 1)
		while rest:sub(1, 1) == "/" do rest = rest:sub(2) end
		return {
			kind     = "unc_absolute",
			prefix   = "//" .. server .. "/" .. share,
			rest     = rest,
			anchored = true,
		}
	end

	if input:sub(1, 1) == "/" then
		local rest = input:sub(2)
		while rest:sub(1, 1) == "/" do rest = rest:sub(2) end
		return { kind = "posix_absolute", prefix = "/", rest = rest, anchored = true }
	end
	return { kind = "relative", prefix = "", rest = input, anchored = false }
end

--- Normalize path separators and collapse lexical `.` / `..` segments.
--- Display spelling is preserved; case-folding belongs only in `canonical_path_key`.
--- @param path Path
--- @return Path
function M.normalize_path(path)
	if type(path) ~= "string" then error("normalize_path requires a string path", 2) end
	if path == "" then return "" end

	local root     = parse_path_root(path:gsub("\\", "/"))
	local segments = {}
	for segment in root.rest:gmatch("[^/]+") do
		if segment == "." then
			-- no-op
		elseif segment == ".." then
			if #segments > 0 and segments[#segments] ~= ".." then
				segments[#segments] = nil
			elseif not root.anchored then
				segments[#segments + 1] = segment
			end
		else
			segments[#segments + 1] = segment
		end
	end

	local tail = table.concat(segments, "/")
	if root.kind == "relative"       then return tail ~= "" and tail or "." end
	if root.kind == "drive_relative" then return root.prefix .. tail end
	if root.kind == "unc_absolute"   then return tail ~= "" and (root.prefix .. "/" .. tail) or root.prefix end
	return root.prefix .. tail
end

local function absolute_normalized_path(path)
	local normalized = M.normalize_path(path)
	local root       = parse_path_root(normalized)
	if root.kind == "drive_relative" then
		error("drive-relative path cannot be resolved without a per-drive cwd: " .. normalized, 3)
	end
	if root.anchored then return normalized end
	return M.normalize_path(lfs.currentdir() .. "/" .. normalized)
end

--- Return the normalized absolute, Windows-case-folded comparison key for a path.
--- Ordinary relative paths resolve against the process cwd. Drive-relative paths are rejected because LuaFileSystem does not expose Windows per-drive current directories.
--- @param path Path
--- @return string
function M.canonical_path_key(path)
	local normalized = M.normalize_path(path)
	local root       = parse_path_root(normalized)
	if root.kind == "drive_relative" then
		error("canonical_path_key cannot compare drive-relative path: " .. normalized, 2)
	end
	local key = absolute_normalized_path(normalized):lower()
	if #key > 3 and key:sub(-1) == "/" then key = key:sub(1, -2) end
	return key
end

-- ════════════════════════════════════════════════════════════════════════════
-- Section 3: I/O primitives
-- ════════════════════════════════════════════════════════════════════════════

-- File contents intentionally use io.open below.
-- LuaFileSystem handles path metadata, directory iteration, the current directory, and mkdir;
-- it does not expose file-content read/write streams.
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

--- Write content to disk in binary mode so LF line endings are preserved on Windows
--- (text mode would convert LF -> CRLF, breaking byte-identical diffs against git-tracked gen/*.h files which are stored as LF).
--- @param path string
--- @param content string
function M.write_file_lf(path, content)
	local  f = io.open(path, "wb")
	if not f then error("Cannot write " .. path) end
	f:write(content); f:close()
end

local _absolute_path_cache = {}

--- Convert a (possibly relative) path to an absolute path, using CWD if needed.
--- Normalizes forward slashes to backslashes on Windows.
--- Used for byte-identical emit: the // Source: comment line uses the absolute path.
--- The CWD is memoized on first call.
--- @param path string
--- @return string
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

--- Group a list of `SourceFile`-shaped records by their `dir` field.
--- Used by the annotation / static-analysis / report passes to partition sources into per-DIRECTORY (per-module) buckets before emitting per-module reports.
--- Insertion order is preserved within each bucket (matches source order in `corpus.source_order`).
--- @param sources table[]          -- list of source records (each having a `dir` string field)
--- @return table<string, table[]>  -- map of `dir` -> sources in that dir
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
-- Returns the inner content (between the delimiters) + the position just past the closing delimiter, or nil + pos if `s[pos]` isn't `open_char`.
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
			pos   = pos   + 1
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

-- Scan forward from position `start` until we find a specific single byte `target`, transparently stepping over balanced parens/braces/brackets.
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
	local len  = #s
	while scan <= len and s:byte(scan) ~= BYTE_NEWLINE do scan = scan + 1 end
	return scan + 1
end

local function is_horizontal_space(byte)
	return byte == BYTE_SPACE or byte == BYTE_TAB or byte == BYTE_CR or byte == BYTE_VT or byte == BYTE_FF
end

local function segment_has_newline(source, first, after_last)
	for pos = first, after_last - 1 do 
		if source:byte(pos) == BYTE_NEWLINE then return true end 
	end
	return false
end

local function skip_directive_space(source, pos)
	while pos <= #source do
		local byte = source:byte(pos)
		if is_horizontal_space(byte) then
			pos = pos + 1
		elseif byte == BYTE_SLASH and source:byte(pos + 1) == BYTE_STAR then
			local after = M.skip_str_or_cmt(source, pos)
			if after == pos or segment_has_newline(source, pos, after) then return nil end
			pos = after
		elseif byte == BYTE_SLASH and source:byte(pos + 1) == BYTE_SLASH then
			return nil
		else
			break
		end
	end
	return pos
end

--- Apply C line splicing once for the include scanner.
--- Every retained logical byte maps back to its original physical byte offset and one-based physical line so diagnostics preserve source-as-written evidence.
local function splice_c_lines(source)
	local logical_bytes = {}
	local physical_pos  = {}
	local physical_line = {}
	local pos            = 1
	local line           = 1
	while pos <= #source do
		local byte = source:byte(pos)
		local splice_len = nil
		if byte == BYTE_BACKSLASH and source:byte(pos + 1) == BYTE_NEWLINE then
			splice_len = 2
		elseif byte == BYTE_BACKSLASH and source:byte(pos + 1) == BYTE_CR
			and source:byte(pos + 2) == BYTE_NEWLINE then
			splice_len = 3
		end

		if splice_len then
			pos  = pos + splice_len
			line = line + 1
		else
			local logical_pos = #logical_bytes + 1
			logical_bytes[logical_pos] = source:sub(pos, pos)
			physical_pos [logical_pos] = pos
			physical_line[logical_pos] = line
			if byte == BYTE_NEWLINE then line = line + 1 end
			pos = pos + 1
		end
	end
	return table.concat(logical_bytes), physical_pos, physical_line
end

--- Parse direct quoted preprocessor includes from one source buffer.
--- Line splicing occurs ahead of comment, string, and directive processing.
--- Interpreted records retain original physical include text and line numbers.
--- Angle includes and include-like text inside comments/strings are ignored.
--- @param source_text string
--- @return table[] -- ordered `{path, include_path, include_text, line}` records
function M.parse_direct_quoted_includes(source_text)
	if type(source_text) ~= "string" then
		error("parse_direct_quoted_includes requires source text", 2)
	end

	-- Each arm's effect on (pos, line_leading) is annotated at the branch site.
	-- Arm order: newline / horiz-space / '//' / '/*' / '"' / '\'' / '#' / default.
	local logical_text, physical_pos, physical_line = splice_c_lines(source_text)
	local includes     = {}
	local pos          = 1
	local line_leading = true
	while pos <= #logical_text do
		local byte = logical_text:byte(pos)
		if    byte == BYTE_NEWLINE then
			-- line break; refresh leading-whitespace state for next line.
			line_leading = true
			pos          = pos + 1
		elseif is_horizontal_space(byte) then
			-- ordinary inter-token whitespace; preserve current leading-ness.
			pos = pos + 1
		elseif byte == BYTE_SLASH and logical_text:byte(pos + 1) == BYTE_SLASH then
			-- '//' line comment: skip_str_or_cmt walks to EOL on its own, so no separate newline scan is needed here.
			local after = M.skip_str_or_cmt(logical_text, pos)
			-- pos := after when the skipper agrees, else single-byte advance.
			pos = (after > pos) and after or (pos + 1)
		elseif byte == BYTE_SLASH and logical_text:byte(pos + 1) == BYTE_STAR then
			-- '/*' block comment.
			local after = M.skip_str_or_cmt(logical_text, pos)
			if after <= pos then
				-- skipper refused (unterminated /*). Treat this byte as ordinary content: step one, mark non-leading.
				line_leading = false
				pos          = pos + 1
			else
				-- jump past the closing '*/'. The span may cross lines, so rescan for embedded '\n' to refresh line_leading.
				for scan = pos, after - 1 do
					if logical_text:byte(scan) == BYTE_NEWLINE then line_leading = true end
				end
				pos = after
			end
		elseif byte == BYTE_DQUOTE or byte == BYTE_SQUOTE then
			-- enter + leave the string literal in one skip; literal bodies cannot contain a directive regardless of what they look like.
			line_leading = false
			local after  = M.skip_str_or_cmt(logical_text, pos)
			pos          = (after > pos) and after or (pos + 1)
		elseif byte == 35 and line_leading then -- '#' at line head
			-- Sequential pre-checks; any one failing falls through to ::not_include:: (single-byte advance).
			-- Full success pushes the record and jumps to ::directive_done:: without ever entering the not-include path.
			-- (All locals are pre-declared at the top of this arm because Lua forbids a goto from crossing a local declaration into its scope.)
			local hash_pos, directive_line, scan, ident, after_ident, after_quote
			local include_path, physical_first, physical_last
			hash_pos       = pos
			directive_line = physical_line[hash_pos] or 1
			scan           = skip_directive_space(logical_text, pos + 1)
			if not scan then goto not_include end
			ident, after_ident = M.read_ident(logical_text, scan)
			if ident ~= "include" then goto not_include end
			scan = skip_directive_space(logical_text, after_ident)
			if not scan then goto not_include end
			if logical_text:byte(scan) ~= BYTE_DQUOTE then goto not_include end
			after_quote = M.skip_str_or_cmt(logical_text, scan)
			if not (after_quote > scan and logical_text:byte(after_quote - 1) == BYTE_DQUOTE) then
				goto not_include
			end
			-- success: build the include record; pos jumps past closing '"'.
			include_path   = logical_text:sub(scan + 1, after_quote - 2)
			physical_first = physical_pos[hash_pos]
			physical_last  = physical_pos[after_quote - 1]
			includes[#includes + 1] = {
				path         = include_path,
				include_path = include_path,
				include_text = M.trim(source_text:sub(physical_first, physical_last)),
				line         = directive_line,
			}
			pos = after_quote
			goto directive_done

			::not_include::
			-- any pre-check failure: '#' is ordinary content; advance one.
			pos = pos + 1

			::directive_done::
			-- '#' at line head clears the leading-whitespace state.
			line_leading = false

		else
			-- ordinary source character; mark non-leading, advance one.
			line_leading = false
			pos          = pos + 1
		end
	end
	return includes
end

local function path_has_segment(path, wanted)
	for segment in M.normalize_path(path):gmatch("[^/]+") do
		if segment:lower() == wanted then return true end
	end
	return false
end

local function canonical_key_is_within(candidate_key, root_key)
	if candidate_key == root_key then return true end
	local prefix = root_key .. "/"
	return candidate_key:sub(1, #prefix) == prefix
end

local function load_source_record(path)
	local normalized = absolute_normalized_path(path)
	return {
		path     = normalized,
		text     = M.read_file(normalized),
		dir      = M.dirname(normalized),
		basename = M.basename_no_ext(normalized),
	}
end

--- Resolve a unity source corpus without recursive discovery.
--- The root is loaded first; only its direct quoted includes are considered, in source order.
--- Candidate A is root-directory relative and candidate B is `<project_root>/code` relative.
--- @param options table -- `{unity_root=Path, project_root=Path}`
--- @return table
function M.resolve_source_corpus(options)
	if type(options) ~= "table" then error("resolve_source_corpus requires options", 2) end
	if type(options.unity_root) ~= "string" or options.unity_root == "" then
		error("resolve_source_corpus requires options.unity_root", 2)
	end
	if type(options.project_root) ~= "string" or options.project_root == "" then
		error("resolve_source_corpus requires options.project_root", 2)
	end

	local project_root    = absolute_normalized_path(options.project_root)
	local code_root       = M.normalize_path(project_root .. "/code")
	local code_root_key   = M.canonical_path_key(code_root)
	local root            = load_source_record(options.unity_root)
	local source_order    = { root }
	local sources_by_path = { [M.canonical_path_key(root.path)] = root, }
	local resolver = {
		resolved = {
			{
				include_path = nil,
				include_text = nil,
				root_source  = root.path,
				root_line    = 1,
				candidate_a  = root.path,
				candidate_b  = nil,
				selected_path = root.path,
				disposition  = "root",
			},
		},
		skipped  = {},
		shadowed = {},
	}

	for _, include in ipairs(M.parse_direct_quoted_includes(root.text)) do
		local candidate_a = absolute_normalized_path(root.dir .. "/" .. include.path)
		local candidate_b = absolute_normalized_path(code_root .. "/" .. include.path)
		local key_a       = M.canonical_path_key(candidate_a)
		local key_b       = M.canonical_path_key(candidate_b)
		local inside_a    = canonical_key_is_within(key_a, code_root_key)
		local inside_b    = canonical_key_is_within(key_b, code_root_key)
		local evidence = {
			include_path = include.path,
			include_text = include.include_text,
			root_source  = root.path,
			root_line    = include.line,
			candidate_a  = candidate_a,
			candidate_b  = candidate_b,
			candidate_a_in_code_root = inside_a,
			candidate_b_in_code_root = inside_b,
			selected_path = nil,
			disposition   = nil,
		}

		if not inside_a and not inside_b then
			evidence.disposition = "skipped"
			evidence.reason      = "outside_code_root"
			resolver.skipped[#resolver.skipped + 1] = evidence
		elseif (inside_a and path_has_segment(candidate_a, "gen"))
			or   (inside_b and path_has_segment(candidate_b, "gen")) then
			evidence.disposition = "skipped"
			evidence.reason      = "gen_segment"
			resolver.skipped[#resolver.skipped + 1] = evidence
		else
			-- Boundary checks above deliberately precede every filesystem probe.
			local exists_a = inside_a and lfs.attributes(candidate_a, "mode") == "file"
			local exists_b = inside_b and ((key_b == key_a and exists_a) or lfs.attributes(candidate_b, "mode") == "file")
			local selected     = nil
			local selected_key = nil
			local disposition  = nil
			if exists_a then
				selected     = candidate_a
				selected_key = key_a
				disposition  = "resolved_local"
			elseif exists_b then
				selected     = candidate_b
				selected_key = key_b
				disposition  = "resolved_code"
			end

			if exists_a and exists_b and key_a ~= key_b then
				resolver.shadowed[#resolver.shadowed + 1] = {
					include_path   = include.path,
					include_text   = include.include_text,
					root_source    = root.path,
					root_line      = include.line,
					candidate_a    = candidate_a,
					candidate_b    = candidate_b,
					selected_path  = candidate_a,
					alternate_path = candidate_b,
					disposition   = "local_candidate_selected",
				}
			end

			if not selected then
				evidence.disposition = "skipped"
				evidence.reason      = "unresolved"
				resolver.skipped[#resolver.skipped + 1] = evidence
			else
				evidence.selected_path = selected
				if sources_by_path[selected_key] then
					evidence.disposition  = "duplicate"
					evidence.reason       = "duplicate"
					evidence.duplicate_of = sources_by_path[selected_key].path
					resolver.skipped[#resolver.skipped + 1] = evidence
				else
					local source = load_source_record(selected)
					evidence.disposition                      = disposition
					source_order[#source_order + 1]           = source
					sources_by_path[selected_key]             = source
					resolver.resolved[#resolver.resolved + 1] = evidence
				end
			end
		end
	end

	return {
		unity_root      = root.path,
		project_root    = project_root,
		code_root       = code_root,
		source_order    = source_order,
		sources_by_path = sources_by_path,
		sources_by_dir  = M.group_sources_by_dir(source_order),
		resolver        = resolver,
	}
end

-- Split a brace-body into top-level comma-separated tokens. Honors nested parens/braces/brackets and skips strings/comments.
-- Splits at top-level NEWLINES and SEMICOLONS too, AND emits a token break after a top-level comment/string.
-- Pure-comment / pure-string chunks contribute 0 words.
function M.split_top_level_commas(body)
	local tokens      = {}
	local pos         = 1
	local body_len    = #body
	local token_start = 1

	-- True iff `chunk` contains any non-whitespace, non-comment, non-string content (i.e., real token material).
	-- Walks through ws + comments individually so a chunk like "  /* trailing */ shift_lleft(...)" is correctly classified as having real content (the macro call).
	local function has_real_content(chunk)
		local scan = 1
		local len  = #chunk
		while scan <= len do
			if M.is_space_byte(chunk:byte(scan)) then
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
					-- comment/string chunk at top level.
					-- Append it to the LAST token so emit-context callers (components.lua build_component_lines) can convert
					-- `// trailing comment` to `/* */` and emit it with the macro body.
					-- count_token_words only inspects the leading ident, so a trailing comment does not affect the count.
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
			-- These also appear as separators between argument lists inside the parens/braces/brackets, so we stop the scan when we hit any of them.
			if     c == BYTE_COMMA   then break end
			if     c == BYTE_NEWLINE then break end
			if     c == BYTE_SEMI    then break end
			-- Line-comment '// ... \n' (0x2F 0x2F): skip to (and past) the next newline, or to end-of-body.
			if     c == BYTE_SLASH and body:byte(scan + 1) == BYTE_SLASH then
				local nl = M.find_byte(body, BYTE_NEWLINE, scan)
				scan = nl and (nl + 1) or (len + 1)
			-- Block-comment '/* ... */' (0x2F 0x2A): skip to (and past) the matching '*/', or to end-of-body.
			elseif c == BYTE_SLASH and body:byte(scan + 1) == BYTE_STAR then
				local close = body:find("*/", scan + 2, true)
				scan = close and (close + 2) or (len + 1)
			-- Group opener bytes (consume the balanced group via the matching reader): '(' = 0x28, '{' = 0x7B, '[' = 0x5B.
			elseif c == BYTE_OPEN_PAREN then local _, a = M.read_parens   (body, scan); scan = a
			elseif c == BYTE_OPEN_BRACE then local _, a = M.read_braces   (body, scan); scan = a
			elseif c == BYTE_OPEN_BRACK then local _, a = M.read_brackets (body, scan); scan = a
			-- String-literal byte ('"' = 0x22 or '\'' = 0x27): skip past the quoted region in one shot.
			elseif c == BYTE_DQUOTE or c == BYTE_SQUOTE then
				scan = (M.skip_str_or_cmt(body, scan) or scan) + 1
			else
				scan = scan + 1
			end
		end
		local tok = M.trim(body:sub(rel, scan - 1))
		if tok ~= "" then out[#out + 1] = { tok = tok, rel = rel } end
		if scan <= len then
			scan = scan + 1
			local w = M.skip_ws_and_cmt(body, scan)
			if    w > scan then scan = w end
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
	for  pos = 1, len do
		if pos > 1 then
			index[pos] = newline_count + 1
		end
		-- Newline byte = 0x0A (BYTE_NEWLINE). 
		-- Counts line boundaries so the index maps each source-byte offset → its 1-based line number.
		if body:byte(pos) == BYTE_NEWLINE then
			newline_count = newline_count + 1
		end
	end
	index[len + 1] = newline_count + 1
	_body_line_index_cache[body] = index
	return index
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
-- Section 6: LineIndex (constant-time line lookup)
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
-- Maps every source-side GTE command macro to its canonical short ident.
-- Both forms run the same PSX-SPX-documented pipeline semantics.
-- Aliases resolve exactly once; an unknown ident (an MVMVA with a custom `(sf, mx, v, cv, lm)` payload that is not on this list) lands as
-- "command unknown" from the check rather than being silently treated as 0-cycle.
--
-- Source conventions (per `code/duffle/gte.h`): the C source ships short idents (`gte_cmdw_rtps`, `gte_cmdw_rtpt`, `gte_cmdw_nclip`,
-- `gte_cmdw_avsz3`, `gte_cmdw_avsz4`, `gte_cmdw_mvmva`, `gte_cmdw_op`) and human-readable aliases
-- (`gte_cmdw_rotate_translate_perspective_*`, `gte_cmdw_avg_sort_z3`, etc.). Each alias row maps the source ident to its short form.
M.GTE_COMMAND_ALIASES = {
	-- Identity rows: short form resolves to itself.
	["gte_cmdw_rtps"]                                = "gte_cmdw_rtps",
	["gte_cmdw_rtpt"]                                = "gte_cmdw_rtpt",
	["gte_cmdw_nclip"]                               = "gte_cmdw_nclip",
	["gte_cmdw_mvmva"]                               = "gte_cmdw_mvmva",
	["gte_cmdw_op"]                                  = "gte_cmdw_op",
	["gte_cmdw_avsz3"]                               = "gte_cmdw_avsz3",
	["gte_cmdw_avsz4"]                               = "gte_cmdw_avsz4",
	-- Long-form aliases resolve to the short form.
	["gte_cmdw_rotate_translate_perspective_single"] = "gte_cmdw_rtps",
	["gte_cmdw_rotate_translate_perspective_triple"] = "gte_cmdw_rtpt",
	["gte_cmdw_avg_sort_z3"]                         = "gte_cmdw_avsz3",
	["gte_cmdw_avg_sort_z4"]                         = "gte_cmdw_avsz4",
	["gte_cmdw_outer_product"]                       = "gte_cmdw_op",
	["gte_cmdw_wedge"]                               = "gte_cmdw_op",
	-- Bare-name aliases (no `gte_cmdw_` prefix; used in atom bodies directly):
	-- gte_avg_sort_z3 / gte_avg_sort_z4 are the duffle-side aliases for AVSZ3/4.
	["gte_avg_sort_z3"]                              = "gte_cmdw_avsz3",
	["gte_avg_sort_z4"]                              = "gte_cmdw_avsz4",
	["gte_cmdw_sqr"]                                 = "gte_cmdw_sqr",
	["gte_cmdw_gpf"]                                 = "gte_cmdw_gpf",
}

-- GTE command input-set table.
--
-- For each command, the set of C2 registers whose recent CPU-to-COP2 write must retire before the command can issue.
-- Per PSX-SPX `docs/psx-spx/docs/cpuspecifications.md:407-419`:
--   * A store to COP2 registers (mtc2/ctc2) has a delay of 2..3 clock cycles.
--   * In most cases the delay is 2 cycles; special cases like writes to IRGB (which additionally affect IR1/IR2/IR3) take 3 cycles.
--   * "Store delays are counted in numbers of clock cycles (not in numbers of opcodes).
--    For 3 cycle delay, one must usually insert 3 cached opcodes (or one uncached opcode)."
--
-- Per PSX-SPX `docs/psx-spx/docs/gtepipelinetimings.md` (the per-instruction input-latch measurement, which is the same phenomenon modeled from the command side), 
-- the values are:
--   rtps:  every data register, every control register (RT / TR / OFX / OFY / H / DQA / DQB)
--   rtpt:  same superset (rtpt reads V0..V2, the RT matrix, the TR vector, OFX / OFY, H, DQA, DQB)
--   nclip: SXY0, SXY1, SXY2 (no RT / TR / OFX inputs)
--   mvmva: variable (depends on the chosen mx / v / cv selector); treated conservatively as the union of all RT + TR + BK + IR columns
--          (the data inputs the command can read).
--   op:    IR1, IR2, IR3 (cross-product output, atomic; consumers treat as fan-out only)
--   avsz3 / avsz4: SZ0..SZ3 + ZSF3/ZSF4
--
-- We model the data-register + control-register superset. Every relevant input is in this set per PSX-SPX `gtepipelinetimings.md`;
-- The per-input latching values there describe the same number's command-side view
-- (a recent mtc2/ctc2 to that register must retire the same number of cycles before the command issues).
-- Anything outside this set is safe to clobber immediately after a prior command.
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
	-- NCLIP: reads SXY0 / SXY1 / SXY2 only (per PSX-SPX gtepipelinetimings.md §12.6).
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
	-- SQR: reads IR1..IR3 (per PSX-SPX gte.md SQR section; libgte disassembly 0x800160b0).
	["gte_cmdw_sqr"] = {
		"C2_IR1", "C2_IR2", "C2_IR3",
	},
	-- GPF: reads IR0 + IR1..IR3 (per PSX-SPX gte.md GPF section; libgte disassembly 0x8001613c).
	["gte_cmdw_gpf"] = {
		"C2_IR0", "C2_IR1", "C2_IR2", "C2_IR3",
	},
}

-- GTE command output-set + semantic role table.
-- For each command, the set of C2 data registers the command writes as outputs, paired with the SEMANTIC ROLE of each output.
-- The semantic role is the basis for the `_post_<cmd>` contract validation.
-- The contract says "after <cmd>, the latest screen-XY is C2_SXY2" (C2_SXY0 is wrong; the FIFO side effects leave SXY0 as an older FIFO entry, never the newest).
--
-- Per PSX-SPX `docs/psx-spx/docs/geometrytransformationenginegte.md`:
--   * RTPS: writes VXY/VZ -> MAC results; the single projected screen coordinate is written to C2_SXY2 (the IRGB -> SXY2 path via the perspective divide).
--     C2_SXY0 and C2_SXY1 are untouched.
--   * RTPT: writes three projected screen coordinates into SXY0, SXY1, SXY2 in pipeline order.
--     The last projection lives in C2_SXY2; a reader that wants "the last RTPT result" reads C2_SXY2.
--   * NCLIP: writes a single MAC result into C2_SZ3 (the inner-product sum); no screen XY output.
--   * AVSZ3 / AVSZ4: write average Z into C2_OTZ (single output).
--   * OP:    writes C2_IR1, C2_IR2, C2_IR3 (cross-product result; no projection).
--   * MVMVA: writes C2_IR1, C2_IR2, C2_IR3 (single MAC result; same shape as OP from the role perspective).
--
-- Role taxonomy (closed set):
--   * "latest_screen_xy" : newest projected screen X/Y pair
--   * "latest_screen_z"  : newest projected screen Z
--   * "latest_color"     : newest IRGB / IR fan-out result
--   * "screen_xy[N]"     : Nth projection in a batched sequence
--   * "screen_z"         : Z projection (avsz / otz)
--   * "otz"              : ordered-table Z (avsz output)
--   * "mac_result"       : generic MAC output (nclip, op, mvmva)
--
-- Consumers:
--   * passes/static_analysis.lua::analyze_hardware_relations (the walker reads this after a GTE command to update `forward_state.post_command_roles` for `gte_role_mismatch`).
--   * passes/static_analysis.lua::check_gte_role_mismatch (per-atom CHECK_RULES reader; renders role mismatches).
-- This table is consumed by the hardware-relation analyzer and the gte_role_mismatch check.
M.GTE_COMMAND_OUTPUTS = {
	-- RTPS: writes one screen coordinate (the perspective-divide result) into C2_SXY2.
	-- The FIFO side effects leave SXY0 / SXY1 untouched, so `latest_screen_xy` is C2_SXY2.
	["gte_cmdw_rtps"] = {
		{ register = "C2_SXY2", role = "latest_screen_xy" },
		{ register = "C2_SZ2",  role = "latest_screen_z"  },
		{ register = "C2_OTZ",  role = "otz"              },
		{ register = "C2_IR0",  role = "latest_color"     },
	},
	-- RTPT: writes three screen coordinates; the last projection lands in C2_SXY2 (`latest_screen_xy`).
	-- C2_SXY0 / C2_SXY1 carry the earlier projections of the batched triple.
	["gte_cmdw_rtpt"] = {
		{ register = "C2_SXY0", role = "screen_xy[0]"     },
		{ register = "C2_SXY1", role = "screen_xy[1]"     },
		{ register = "C2_SXY2", role = "latest_screen_xy" },
		{ register = "C2_SZ3",  role = "latest_screen_z"  },
		{ register = "C2_OTZ",  role = "otz"              },
	},
	-- NCLIP: single MAC result; written to C2_SZ3 (the inner-product sum). No screen XY output.
	["gte_cmdw_nclip"] = {
		{ register = "C2_SZ3", role = "mac_result" },
	},
	-- AVSZ3 / AVSZ4: average Z written to C2_OTZ.
	["gte_cmdw_avsz3"] = {
		{ register = "C2_OTZ", role = "otz" },
	},
	["gte_cmdw_avsz4"] = {
		{ register = "C2_OTZ", role = "otz" },
	},
	-- OP (outer product): writes IR1 / IR2 / IR3 (color-conversion fan-out).
	["gte_cmdw_op"] = {
		{ register = "C2_IR1", role = "latest_color" },
		{ register = "C2_IR2", role = "latest_color" },
		{ register = "C2_IR3", role = "latest_color" },
	},
	-- MVMVA: same shape as OP from the role perspective; the single
	-- MAC result is written to C2_IR1 / IR2 / IR3.
	["gte_cmdw_mvmva"] = {
		{ register = "C2_IR1", role = "latest_color" },
		{ register = "C2_IR2", role = "latest_color" },
		{ register = "C2_IR3", role = "latest_color" },
	},
	["gte_cmdw_sqr"] = {
		{ register = "C2_MAC1", role = "mac_result" },
		{ register = "C2_MAC2", role = "mac_result" },
		{ register = "C2_MAC3", role = "mac_result" },
		{ register = "C2_IR1",  role = "latest_color" },
		{ register = "C2_IR2",  role = "latest_color" },
		{ register = "C2_IR3",  role = "latest_color" },
	},
	["gte_cmdw_gpf"] = {
		{ register = "C2_MAC1", role = "mac_result" },
		{ register = "C2_MAC2", role = "mac_result" },
		{ register = "C2_MAC3", role = "mac_result" },
		{ register = "C2_IR1",  role = "latest_color" },
		{ register = "C2_IR2",  role = "latest_color" },
		{ register = "C2_IR3",  role = "latest_color" },
	},
}

-- GTE command/post-command latch-window table.
--
-- Per PSX-SPX `docs/psx-spx/docs/gtepipelinetimings.md`, a GTE command emits outputs that latch into the pipeline for a measured number of emitted words.
-- A subsequent MTC2/CTC2 overwrite of one of those outputs before the latch window expires is a hazard:
-- the latched value in the pipeline gets overwritten by the CPU before the pipeline consumes it.
--
-- This relation is the command -> register direction (the command is the producer; MTC2 / CTC2 is the consumer).
-- It is the inverse of the MTC2 -> command input propagation (register -> command direction), which is staged by the producer step of `analyze_hardware_relations`.
--
-- The schema mirrors the producer-side relations (`direction`, `evidence`, `violation_kind`); 
-- `required` counts the emitted words strictly between the command's last output word and the overwrite.
-- `required = 0` permits the immediately following overwrite; `required = 4` requires four intervening words.
--
-- Per PSX-SPX `gtepipelinetimings.md` the per-command input latching measurements are the same numbers inverted.
-- They describe when a recent MTC2 / CTC2 must retire before the command issues. 
-- This table describes when a recent command's outputs latch into the pipeline before a later MTC2/CTC2 overwrites them.
--
-- Consumers:
--   * passes/static_analysis.lua::analyze_hardware_relations (stages post-command latch relations in `pending` after a GTE command).
--   * passes/static_analysis.lua::check_gte_input_latch      (per-atom CHECK_RULES reader; renders the over-the-boundary findings).
-- This table is consumed by the hardware-relation analyzer and input-latch check.
M.GTE_COMMAND_LATCH_WINDOWS = {
	-- RTPS output latches: a subsequent MTC2 to SXY0 within 4 emitted words overwrites the latched result.
	-- (PSX-SPX §"RTPS" lists the measured boundary; the exact number is from  `gtepipelinetimings.md`.)
	["gte_cmdw_rtps"] = {
		{ register = "C2_SXY2", required = 4 },
		{ register = "C2_SZ2",  required = 4 },
		{ register = "C2_OTZ",  required = 4 },
		{ register = "C2_IR0",  required = 4 },
	},
	-- RTPT: same latching as RTPS (the LAST projection in SXY2 is the newest one; the earlier SXY0 / SXY1 entries are part of the batched triple).
	["gte_cmdw_rtpt"] = {
		{ register = "C2_SXY0", required = 4 },
		{ register = "C2_SXY1", required = 4 },
		{ register = "C2_SXY2", required = 4 },
		{ register = "C2_SZ3",  required = 4 },
		{ register = "C2_OTZ",  required = 4 },
	},
	-- NCLIP output (SZ3): latches for 4 emitted words.
	["gte_cmdw_nclip"] = {
		{ register = "C2_SZ3", required = 4 },
	},
	-- AVSZ3/4: OTZ output latches for 4 emitted words.
	["gte_cmdw_avsz3"] = {
		{ register = "C2_OTZ", required = 4 },
	},
	["gte_cmdw_avsz4"] = {
		{ register = "C2_OTZ", required = 4 },
	},
	-- OP / MVMVA: IR1 / IR2 / IR3 latch for 4 emitted words.
	["gte_cmdw_op"] = {
		{ register = "C2_IR1", required = 4 },
		{ register = "C2_IR2", required = 4 },
		{ register = "C2_IR3", required = 4 },
	},
	["gte_cmdw_mvmva"] = {
		{ register = "C2_IR1", required = 4 },
		{ register = "C2_IR2", required = 4 },
		{ register = "C2_IR3", required = 4 },
	},
	["gte_cmdw_sqr"] = {
		{ register = "C2_MAC1", required = 4 },
		{ register = "C2_MAC2", required = 4 },
		{ register = "C2_MAC3", required = 4 },
		{ register = "C2_IR1",  required = 4 },
		{ register = "C2_IR2",  required = 4 },
		{ register = "C2_IR3",  required = 4 },
	},
	["gte_cmdw_gpf"] = {
		{ register = "C2_MAC1", required = 4 },
		{ register = "C2_MAC2", required = 4 },
		{ register = "C2_MAC3", required = 4 },
		{ register = "C2_IR1",  required = 4 },
		{ register = "C2_IR2",  required = 4 },
		{ register = "C2_IR3",  required = 4 },
	},
}

-- Operand-class table for the COP2->GPR load-delay check.
-- Maps each emitting-token ident to the set of GPR operand positions it reads.
-- Covers the current encoder vocabulary (`code/duffle/mips.h` + `code/duffle/gte.h`); add rows here as new encoders land.
--
-- Semantics:
--   * A "GPR operand position" is the textual slot in the macro's argument list, 1-based; e.g. `load_word(rt, base, off)` has
--     positional operands 1 (rt), 2 (base), 3 (off). The table reads operands 1 + 2 + 3 to find what GPRs the macro touches.
--   * The check tracks one entry per destination GPR per MFC2 / CFC2 event.
--     A subsequent event counts as a "use" iff any of its read operand positions reference that destination GPR's ident (e.g. `R_T0`).
--   * Branch delay slots are out of scope (MIPS control-flow; tracked separately).
M.OPERAND_READ_POSITIONS = {
	-- CPU ALU with one or two GPR operands. Reads every GPR operand.
	["add_ui"]                 = {1, 2},
	["li_s"]                   = {1, 2},  -- rt (write), imm16 (immediate)
	["add_ui_self"]            = {1},
	["add_si"]                 = {1, 2},
	["add_u"]                  = {1, 2, 3},
	["add_u_self"]             = {1, 2},
	["sub_s"]                  = {1, 2, 3},
	["sub_u"]                  = {1, 2, 3},
	["and_i"]                  = {1, 2},
	["and"]                    = {1, 2, 3},
	["or_i"]                   = {1, 2},
	["or_i_self"]              = {1},
	["or"]                     = {1, 2, 3},
	["or_self"]                = {1, 2},
	["xor_i"]                  = {1, 2},
	["xor"]                    = {1, 2, 3},
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
	-- Loads: load_word(rt, base, off); the rt operand is the destination (it's written, not read) and base + off are non-GPR operands.
	-- The check treats the rt operand as a write, so the read-positions table for `load_*` is empty.
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
	-- GTE transfers / loads / stores / commands: the relevant table values live in the check itself.
	-- `gte_mv_to_*` writes its rt operand; `gte_mv_from_*` writes its rt operand; `gte_*` commands are atomic-from-the-CPU-POV
	-- once they issue (the CPU holds until the command completes, so load-delay violations don't surface here).
	["gte_mv_from_data_r"]     = {},
	["gte_mv_from_ctrl_r"]     = {},
	["gte_mv_to_data_r"]       = {},
	["gte_mv_to_ctrl_r"]       = {},
	["gte_lw"]                 = {},
	["gte_sw"]                 = {},
	["shift_lleft_var"]        = {1, 2, 3},  -- rd, rt, rs (variable shift amount)
	["shift_aright_var"]       = {1, 2, 3},
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

-- Per-instruction cycle cost (best-case, no stalls). Used by the static-analysis pass to emit per-atom cycle budgets.
-- GTE command values are the GTE instruction's intrinsic cycles — the latency after any pre-cmd `nop2` has retired.
-- When the source emits `nop2, gte_cmdw_X`, the nops' cycles are added separately (1+1) plus the gte_cmdw_X value here:
--   rtpt  = 23 + 2 nops = 25 total cycles  (PSX-SPX says 23 cycles for the cmd itself; the nops are pre-fill)
--   rtps  = 15 + 2 nops = 17 total
--   nclip =  8 + 2 nops = 10 total
--   avsz3 =  5 + 2 nops =  7 total
--   avsz4 =  6 + 2 nops =  8 total
--   mvmva =  8 + 2 nops = 10 total
--   op    =  6 (no pre-cmd nops required; atomic)
--
-- PSX-SPX reports the GTE intrinsic cycles as the total execution time of the command itself (rtpt=23, rtps=15, nclip=8, etc.).
-- The pre-fill nops are a codebase convention for retiring preceding C2 writes.
-- See `docs/psx-spx/docs/geometrytransformationenginegte.md` for per-command cycle counts and
-- `docs/psx-spx/docs/gtepipelinetimings.md` for the hardware-verified input-latch boundaries
-- (most inputs become safe to clobber after 0-4 cycles).
--
-- Per-macro cycle costs (`mac_yield`, `mac_pack_color_word`, ...) and per-macro prim-buffer contributions
-- (`mac_format_*_color`, `mac_gte_store_*`, `mac_insert_ot_tag_*`) are NOT hardcoded here.
-- `passes/components.lua::compute_components_metadata` derives both from each `MipsAtomComp_(ac_X)` body in
-- `code/duffle/lottes_tape.h`, stores the values on `corpus.components[name].cycle_cost` and
-- `corpus.components[name].gp0_contrib`, and `passes/static_analysis.lua` reads those fields directly.
-- The `mac_yield` cost is 0 by convention (the runtime cost lands in the next atom's prologue).
M.INSTRUCTION_LATENCY = {
	-- CPU ALU (single-cycle R3000A ops)
	["nop"]                 = 1,
	["nop2"]                = 2,
	["add_ui"]              = 1,  ["add_ui_self"]     = 1,
	["add_s"]               = 1,  ["add_si"]          = 1,
	["add_u"]               = 1,  ["add_u_self"]      = 1,
	["sub_u"]               = 1,  ["sub_s"]           = 1,
	["and_i"]               = 1,  ["and"]             = 1,
	["or_i"]                = 1,  ["or_i_self"]       = 1,
	["or_u"]                = 1,  ["or_u_self"]       = 1,
	["xor_i"]               = 1,  ["xor_u"]           = 1,
	["nor_u"]               = 1,
	["shift_lleft"]         = 1,  ["shift_lleft_self"]  = 1,
	["shift_lleft_var"]     = 1,  -- sllv: 1 cycle
	["shift_lright"]        = 1,
	["shift_aright"]        = 1,
	["shift_aright_var"]    = 1,  -- srav: 1 cycle
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
	["li_s"]                = 1,  -- aliased to add_ui(rt, R_0, imm); 1 cycle
	-- 2-word loads (lui + ori) used for >16-bit immediates
	["load_imm"]                = 2,
	["load_imm_1w"]             = 1,
	["load_imm_1w_s0"]          = 1,
	["load_imm_2w"]             = 2,
	["load_imm_2w_addi_forced"] = 2,
	["load_imm_2w_ori_forced"]  = 2,
	-- Stores (1 cycle each)
	["store_word"]          = 1,
	["store_half"]          = 1,
	["store_byte"]          = 1,
	-- Branches (branch + BD slot nop = 2 cycles; the BD slot's nop is counted as part of the branch's cost)
	["branch_equal"]        = 2,  ["branch_ne"]          = 2,
	["branch_le_zero"]      = 2,  ["branch_lt_zero"]     = 2,
	["branch_ge_zero"]      = 2,  ["branch_gt_zero"]     = 2,
	-- `jump_rel(off)` is the within-atom-safe unconditional-jump alias for `branch_equal(R_0, R_0, off)` (see `code/duffle/mips.h`).
	-- Same cost as the underlying branch (1 instruction + 1 mandatory BD-slot nop = 2 cycles).
	["jump_rel"]            = 2,
	-- Jumps (jump + BD slot nop = 2 cycles)
	["jump"]                = 2,  ["jump_reg"]           = 2,
	["jump_link"]           = 2,  ["call_reg"]           = 2,
	["call_addr"]           = 2,
	-- COP2 transfers (mtc2/mfc2/ctc2/cfc2 = 1 cycle + COP2 latency; 
	-- The COP2 latency is usually absorbed by subsequent nops or by the next
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
	["gte_cmdw_sqr"]           = 5,   -- SQR(sf): 5 cycles (PSX-SPX); +2 nops for pre-fill if sf=0/1
	["gte_cmdw_gpf"]           = 5,   -- GPF(sf,lm): 5 cycles (PSX-SPX); +2 nops for pre-fill if needed
	-- Long-form aliases (same cycle cost as their short form)
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

-- Hardware-relation policy table.
--
-- The forward walker in `passes/static_analysis.lua::analyze_hardware_relations` reads every emitted word_event, matches its `encoder` against `row.token`, and:
--   * stages the event as a producer in `atom.paths.forward_state`; or
--   * matches it as a consumer against pending producers and records a hazard on `atom.paths.hazards` when the gap is below `visibility.required`.
--
-- Each row is the contract for one CPU-to-coprocessor transfer semantic (the coprocessor-to-CPU path mirrors the same shape).
-- The `reads` / `writes` sub-tables carry the argument positions the analyzer inspects:
--   * `writes.arg` is the destination operand (the producer's effect); the analyzer stages this register as a pending producer.
--   * `reads` (when present) lists the operand positions the same token reads back from hardware; for MTC2 / CTC2 the producer reads the GPR source it is loading from.
--     The `fanout_to` field (MTC2-IRGB row only) tells the consumer-match logic which downstream COP2 registers are transitively updated by the write.
--
-- Visibility semantics:
--   * `kind = "post_producer_words"` means the consumer observes the producer's effect after `required` independent emitted words that are
--     strictly between the producer and the consumer. The producer's own emitted slot is implicit (it counts as the slot of issue, not toward
--     `required`) — per the PSX-SPX rule: "Store delays are counted in numbers of clock cycles (not in numbers of opcodes). For 3 cycle delay,
--     one must usually insert 3 cached opcodes (or one uncached opcode)."
--   * `required` is the minimum count of intervening emitted words between producer and consumer.
--     `required = 0` permits the consumer on the very next slot; `required < 0` would place the consumer on the same slot as the producer
--     and is reserved for future "self-retires" relations.
--
-- Evidence:
--   * `evidence.confidence` is one of `"exact"`, `"conservative"`, `"unknown"`. The severity comes from `violation_kind`;
--     A hardware measurement that the vendor caveats may still classify as `"conservative"` even when the underlying timing is numerically known.
--   * `evidence.source` is the upstream reference (file + line range) the row is sourced from. New rows must carry this citation.
--
-- Consumers:
--   * passes/static_analysis.lua::analyze_hardware_relations          (forward walker).
--   * passes/static_analysis.lua::transfer_hazards CHECK_RULES reader (renders hazards onto `findings`).
-- This table is consumed by the hardware-relation analyzer and hazard renderer.
M.HARDWARE_RELATIONS = {
	-- CPU → COP2 data register (MTC2). The ordinary default is 2 cached words between producer and consumer (cpuspecifications.md:407-419).
	{
		id             = "mtc2_gpr_visibility",
		semantic       = "MTC2",
		token          = "gte_mv_to_data_r",
		direction      = "gpr_to_cop2_data",
		reads          = { domain = "gpr",       arg = 1 },
		writes         = { domain = "cop2.data", arg = 2 },
		visibility     = { kind = "post_producer_words", required = 2 },
		evidence       = {
			confidence = "exact",
			source     = "cpuspecifications.md:407-419",
		},
		violation_kind = "error",
	},
	-- CPU → COP2 data register when the destination is C2_IRGB (data 28).
	-- C2_IRGB drives the IR1/IR2/IR3 color-conversion fan-out, which extends the propagation delay to 3 cached words.
	-- `destination_match = "C2_IRGB"` is the row's filter; the analyzer consults this when the producer's destination operand equals "C2_IRGB".
	-- C2_ORGB (data 29) is read-only and is never classified as a writable fan-out destination.
	{
		id              = "mtc2_irgb_visibility",
		semantic        = "MTC2",
		token           = "gte_mv_to_data_r",
		direction       = "gpr_to_cop2_data",
		reads           = { domain = "gpr",       arg = 1 },
		writes          = { domain = "cop2.data", arg = 2 },
		destination_match = "C2_IRGB",
		fanout_to       = { "C2_IR1", "C2_IR2", "C2_IR3" },
		visibility      = { kind = "post_producer_words", required = 3 },
		evidence        = {
			confidence = "exact",
			source     = "cpuspecifications.md:407-419",
		},
		violation_kind  = "error",
	},
	-- CPU → COP2 control register (CTC2). Ordinary minimum 2;
	-- no IRGB-style fan-out exists for control registers (per spec §3.6: only C2_IRGB has the 3-cycle fan-out on the data side).
	{
		id             = "ctc2_gpr_visibility",
		semantic       = "CTC2",
		token          = "gte_mv_to_ctrl_r",
		direction      = "gpr_to_cop2_control",
		reads          = { domain = "gpr",        arg = 1 },
		writes         = { domain = "cop2.ctrl",  arg = 2 },
		visibility     = { kind = "post_producer_words", required = 2 },
		evidence       = {
			confidence = "exact",
			source     = "cpuspecifications.md:407-419",
		},
		violation_kind = "error",
	},
	-- COP2 data → GPR (MFC2). One cached slot between the transfer and the first GPR consumer;
	-- the GPR is not updated until the instruction AFTER the MFC2 completes (geometrytransformationenginegte.md:29-32).
	{
		id             = "mfc2_gpr_visibility",
		semantic       = "MFC2",
		token          = "gte_mv_from_data_r",
		direction      = "cop2_data_to_gpr",
		reads          = { domain = "cop2.data",  arg = 2 },
		writes         = { domain = "gpr",        arg = 1 },
		visibility     = { kind = "post_producer_words", required = 1 },
		evidence       = {
			confidence = "exact",
			source     = "geometrytransformationenginegte.md:29-32",
		},
		violation_kind = "error",
	},
	-- COP2 control → GPR (CFC2). Same delay as MFC2 (cpuspecifications.md treats the two load-from-COP2 paths symmetrically).
	{
		id             = "cfc2_gpr_visibility",
		semantic       = "CFC2",
		token          = "gte_mv_from_ctrl_r",
		direction      = "cop2_control_to_gpr",
		reads          = { domain = "cop2.ctrl",  arg = 2 },
		writes         = { domain = "gpr",        arg = 1 },
		visibility     = { kind = "post_producer_words", required = 1 },
		evidence       = {
			confidence = "exact",
			source     = "cpuspecifications.md:382-419",
		},
		violation_kind = "error",
	},
	-- COP0 control → GPR (MFC0).
	-- One cached slot; the analyzer treats `sys_mov_from_cop0(rt, 12)` (the SR/CU2 transfer) as the same shape as the COP2 load-delay path.
	-- The semantic-level SR/CU2 transition models the load delay;
	-- SR.CU2 bounded-value propagation is modeled separately).
	{
		id             = "mfc0_gpr_visibility",
		semantic       = "MFC0",
		token          = "sys_mov_from_cop0",
		direction      = "cop0_control_to_gpr",
		reads          = { domain = "cop0.ctrl",  arg = 2 },
		writes         = { domain = "gpr",        arg = 1 },
		visibility     = { kind = "post_producer_words", required = 1 },
		evidence       = {
			confidence = "exact",
			source     = "cpuspecifications.md:171-178",
		},
		violation_kind = "error",
	},
	-- Memory -> COP2 data register (LWC2).
	-- The memory-side timing is not measured by the vendored GTE latch experiment, so this relation has no numeric retirement threshold.
	-- The LWC2 destination has TWO retirement regimes (per PSX-SPX):
	--   * GTE-command consumer (`gte_cmdw_*`): the GTE pipeline LATCHES the LWC2 result, so a `gte_cmdw_*`
	--     in the very next slot uses the latched value. Gap = 0 is allowed. (Per `docs/psx-spx/docs/gtepipelinetimings.md:271-274`.)
	--   * Any other consumer: standard MIPS load delay applies. Gap = 1 required. (Per `docs/psx-spx/docs/cpuspecifications.md:407-419`.)
	-- Two separate relations so the walker can dispatch by consumer type and emit different severities
	-- (the GTE-command path is `info` because the latch is intentional; the non-GTE-consumer path is `error` because the missing nop is a real bug).
	{
		id             = "lwc2_to_gte_command",
		semantic       = "LWC2_to_GTE",
		token          = "gte_lw",
		direction      = "memory_to_cop2_data",
		reads          = { domain = "memory",    arg = 2 },
		writes         = { domain = "cop2.data", arg = 1 },
		required       = 0,  -- GTE-command consumer: gap = 0 OK (latched).
		evidence       = {
			confidence = "measured",
			source     = "gtepipelinetimings.md:271-274",
		},
		violation_kind = "info",
		clear_on_consumer = true,
	},
	{
		id             = "lwc2_to_other_consumer",
		semantic       = "LWC2_to_other",
		token          = "gte_lw",
		direction      = "memory_to_cop2_data",
		reads          = { domain = "memory",    arg = 2 },
		writes         = { domain = "cop2.data", arg = 1 },
		required       = 1,  -- Non-GTE-consumer: standard MIPS load delay.
		evidence       = {
			confidence = "inferred",
			source     = "cpuspecifications.md:407-419",
		},
		violation_kind = "error",
		clear_on_consumer = true,
	},
	-- COP2 data register -> memory (SWC2). A read of C2 state, not a CPU-to-COP2 write.
	-- The policy row stays in for direction/provenance; staging it as a later command-input producer is suppressed.
	{
		id             = "swc2_memory_write",
		semantic       = "SWC2",
		token          = "gte_sw",
		direction      = "cop2_data_to_memory",
		reads          = { domain = "cop2.data", arg = 1 },
		writes         = { domain = "memory",    arg = 2 },
		visibility     = { kind = "none", required = 0 },
		evidence       = {
			confidence = "exact",
			source     = "cpuspecifications.md:79",
		},
		violation_kind = "info",
		stage          = false,
	},
	-- MTC0 Status/SR.CU2. The ordinary COP0 store has no general store-delay relation;
	-- this row feeds the dedicated CU2 transition logic in the same forward walk and is therefore not staged in `pending`.
	{
		id             = "mtc0_cu2_visibility",
		semantic       = "MTC0",
		token          = "sys_mov_to_cop0",
		direction      = "gpr_to_cop0_status",
		reads          = { domain = "gpr",          arg = 1 },
		writes         = { domain = "cop0.status",  arg = 2 },
		status_register = 12,
		visibility     = { kind = "post_producer_words", required = 2 },
		evidence       = {
			confidence = "conservative",
			source     = "cpuspecifications.md:543,625-628",
		},
		violation_kind = "warning",
		stage          = false,
		cu2_transition = true,
	},
 }

-- Bounded Status/SR.CU2 transition policy.
-- The value lattice and the transition consumer both read this immutable row; no second value pass is permitted.
-- The source says the enable/disable transition takes "2 clock cycles or so", so the boundary is conservative rather than exact.
M.CU2_TRANSITION_POLICY = {
	status_register = 12,
	enable_bit      = 0x40000000,
	required        = 2,
	visibility_kind = "post_producer_words",
	evidence        = {
		confidence = "conservative",
		source     = "cpuspecifications.md:543,625-628",
	},
}

-- Instruction GPR read/write effects table.
--
-- Maps every CPU/GTE encoder used in production atoms and the focused transfer-hazard tests to its actual GPR operand effects.
-- The analyzer applies this table to `atom.paths.forward_state.gpr_values`:
--   * a write to a GPR invalidates its constant;
--   * a constant-producing transform re-establishes a constant when its inputs are constant
--     (the `gpr_values` lattice is closed: `{kind="unknown"}` and `{kind="constant", value=<U4>}`).
--
-- Schema:
--   reads  = {pos1, pos2, ...}   -- 1-based argument positions that are GPR reads.
--   writes = {pos1, pos2, ...}   -- 1-based argument positions that are GPR writes.
-- The argument positions refer to `word_event.args` (the top-level comma-split args of the emitting token, parsed by `tokenize_body`).
-- Numeric literals, `0x` hex literals, and `U4`/`S4` type keywords are not GPR operand positions.
--
-- Encoders absent from this table are treated as "unknown writers" for every GPR they touch. Unknown writers invalidate
-- `forward_state.gpr_values` for those operands — the analyzer cannot assume the result is a constant.
-- The shape is deliberately conservative: a row missing for a writer means "we do not know what value the GPR now holds".
--
-- Consumers:
--   * passes/static_analysis.lua::analyze_hardware_relations (forward walker).
-- This table is consumed by the hardware-relation analyzer.
M.INSTRUCTION_GPR_EFFECTS = {
	-- CPU ALU with one or two GPR operands. Reads every GPR operand position.
	add_ui                  = { reads = {1, 2}, writes = {1} },
	li_s                    = { reads = {1, 2}, writes = {1} },  -- RMW: rt is both read + written
	add_ui_self             = { reads = {1},    writes = {1} },
	add_si                  = { reads = {1, 2}, writes = {1} },
	add_u                   = { reads = {2, 3}, writes = {1} },
	add_u_self              = { reads = {1, 2}, writes = {1} },
	sub_s                   = { reads = {2, 3}, writes = {1} },
	sub_u                   = { reads = {2, 3}, writes = {1} },
	and_i                   = { reads = {1, 2}, writes = {1} },
	and_u                   = { reads = {2, 3}, writes = {1} },
	or_i                    = { reads = {1, 2}, writes = {1} },
	or_i_self               = { reads = {1},    writes = {1} },
	or_u                    = { reads = {2, 3}, writes = {1} },
	or_u_self               = { reads = {1, 2}, writes = {1} },
	xor_i                   = { reads = {1, 2}, writes = {1} },
	xor_u                   = { reads = {2, 3}, writes = {1} },
	slt_s                   = { reads = {2, 3}, writes = {1} },
	slt_u                   = { reads = {2, 3}, writes = {1} },
	slt_si                  = { reads = {1, 2}, writes = {1} },
	slt_ui                  = { reads = {1, 2}, writes = {1} },
	mult_s                  = { reads = {1, 2}, writes = {}  },
	mult_u                  = { reads = {1, 2}, writes = {}  },
	div_s                   = { reads = {1, 2}, writes = {}  },
	div_u                   = { reads = {1, 2}, writes = {}  },
	-- Shifts: shift_lleft(rd, rt, shamt). rd is destination (write); rt is source (read).
	shift_lleft             = { reads = {2},    writes = {1} },
	shift_lleft_self        = { reads = {1},    writes = {1} },
	shift_lright            = { reads = {2},    writes = {1} },
	shift_aright            = { reads = {2},    writes = {1} },
	-- Loads: load_word(rt, base, off). rt is destination (write); base is source (read).
	load_word               = { reads = {2},    writes = {1} },
	load_half_u             = { reads = {2},    writes = {1} },
	load_byte_u             = { reads = {2},    writes = {1} },
	load_half               = { reads = {2},    writes = {1} },
	load_byte               = { reads = {2},    writes = {1} },
	-- 2-word loads for > 16-bit immediates.
	load_upper_i            = { reads = {},     writes = {1} },
	load_ui                 = { reads = {},     writes = {1} },
	load_imm                = { reads = {},     writes = {1} },
	load_imm_1w             = { reads = {},     writes = {1} },
	load_imm_1w_s0          = { reads = {},     writes = {1} },
	load_imm_2w             = { reads = {},     writes = {1} },
	load_imm_2w_addi_forced = { reads = {},     writes = {1} },
	load_imm_2w_ori_forced  = { reads = {},     writes = {1} },
	-- Stores: store_word(base, rt, off). base + rt are both GPR reads.
	store_word              = { reads = {1, 2}, writes = {}  },
	store_half              = { reads = {1, 2}, writes = {}  },
	store_byte              = { reads = {1, 2}, writes = {}  },
	-- Branches: branch_equal(rs, rt, label). rs + rt are GPR reads.
	branch_equal            = { reads = {1, 2}, writes = {}  },
	branch_ne               = { reads = {1, 2}, writes = {}  },
	branch_le_zero          = { reads = {1},    writes = {}  },
	branch_lt_zero          = { reads = {1},    writes = {}  },
	branch_ge_zero          = { reads = {1},    writes = {}  },
	branch_gt_zero          = { reads = {1},    writes = {}  },
	-- Jumps / link / call: jump_reg(rs) reads rs. RD is the destination link.
	jump                    = { reads = {},     writes = {}  },
	jump_reg                = { reads = {1},    writes = {}  },
	jump_link               = { reads = {1},    writes = {2} },
	call_reg                = { reads = {1},    writes = {2} },
	call_addr               = { reads = {},     writes = {1} },
	-- mask_upper is a 2-word macro: shift_lleft then shift_lright. First reads rt.
	mask_upper              = { reads = {1, 2}, writes = {1} },
	-- move from/to HI/LO.
	mov_from_high           = { reads = {},     writes = {1} },
	mov_from_low            = { reads = {},     writes = {1} },
	mov_to_high             = { reads = {1},    writes = {}  },
	mov_to_low              = { reads = {1},    writes = {}  },
	-- Set-on-condition (SLT family).
	set_lt_u                = { reads = {2, 3}, writes = {1} },
	set_lt_ui               = { reads = {1, 2}, writes = {1} },
	set_lt_s                = { reads = {2, 3}, writes = {1} },
	set_lt_si               = { reads = {1, 2}, writes = {1} },
	-- COP2 transfers: gte_mv_*_r(rt, c2reg).
	--   to_data_r / to_ctrl_r: rt is the GPR source (read); c2reg is the COP2 destination (hardware, not a GPR).
	--   from_data_r / from_ctrl_r: rt is the GPR destination (write); c2reg is the COP2 source (hardware, not a GPR).
	gte_mv_to_data_r        = { reads = {1},    writes = {}  },
	gte_mv_to_ctrl_r        = { reads = {1},    writes = {}  },
	gte_mv_from_data_r      = { reads = {},     writes = {1} },
	gte_mv_from_ctrl_r      = { reads = {},     writes = {1} },
	-- COP2 lw/sw: gte_lw(c2reg, base, off) / gte_sw(c2reg, base, off). base is GPR source; c2reg is COP2 hardware.
	-- LWC2 uses an unknown dependency edge; the GPR effects are unchanged.
	gte_lw                  = { reads = {2},    writes = {}  },
	gte_sw                  = { reads = {2},    writes = {}  },
	-- COP0 transfers: sys_mov_from_cop0(rt, creg) / sys_mov_to_cop0(rt, creg).
	--   from_cop0: rt is the GPR destination (write); creg is the COP0 source.
	--   to_cop0:   rt is the GPR source (read); creg is the COP0 destination.
	-- The SR.CU2 transition uses bounded-value rules.
	sys_mov_from_cop0       = { reads = {},     writes = {1} },
	sys_mov_to_cop0         = { reads = {1},    writes = {}  },
	-- GTE commands / aliases: the encoder is atomic from the CPU's POV once it
	-- issues (the CPU holds until the command completes). No GPR reads/writes.
	gte_cmdw_rtps           = { reads = {},     writes = {}  },
	gte_cmdw_rtpt           = { reads = {},     writes = {}  },
	gte_cmdw_nclip          = { reads = {},     writes = {}  },
	gte_cmdw_avsz3          = { reads = {},     writes = {}  },
	gte_cmdw_avsz4          = { reads = {},     writes = {}  },
	gte_cmdw_mvmva          = { reads = {},     writes = {}  },
	gte_cmdw_op             = { reads = {},     writes = {}  },
	-- High-level GTE helpers (CPU-side load/store wrappers around gte_lw/gte_sw).
	gte_stotz               = { reads = {},     writes = {}  },
	gte_stsxy3              = { reads = {},     writes = {}  },
	gte_load_v0             = { reads = {2},    writes = {}  },
	gte_load_v1             = { reads = {2},    writes = {}  },
	gte_load_v2             = { reads = {2},    writes = {}  },
	gte_load_v0v1v2         = { reads = {2},    writes = {}  },
	-- nop / nop2: zero GPR effects (nop2 = two nop halves in emission-model).
	nop                     = { reads = {},     writes = {}  },
	nop2                    = { reads = {},     writes = {}  },
	-- Annotation markers: zero GPR effects; pure metaprogram hints.
	atom_label              = { reads = {},     writes = {}  },
	atom_offset             = { reads = {},     writes = {}  },
	atom_info               = { reads = {},     writes = {}  },
	atom_bind               = { reads = {},     writes = {}  },
	atom_reads              = { reads = {},     writes = {}  },
	atom_writes             = { reads = {},     writes = {}  },
	-- mac_yield transfers control to the next atom; zero GPR effects.
	mac_yield               = { reads = {},     writes = {}  },
	shift_lleft_var         = { reads = {2, 3}, writes = {1} },
	shift_aright_var        = { reads = {2, 3}, writes = {1} },
}

-- Bounded GPR-value rules consumed by the same forward event walk as `INSTRUCTION_GPR_EFFECTS`.
-- A rule describes a literal/constant-producing transform; if its required inputs are not constant, the destination is invalidated rather than carrying a stale value.
-- The lattice is deliberately closed to `{kind = "unknown"}` and `{kind = "constant", value = <U4>}`.
--
-- Consumers:
--   * passes/static_analysis.lua::apply_gpr_effects
-- No second `bounded_value_pass` is permitted.
M.GPR_VALUE_RULES = {
	load_upper_i     = { op = "load_upper_i", dest = 1,             immediate = 2, },
	add_ui           = { op = "add_ui",       dest = 1, source = 2, immediate = 3, },
	li_s             = { op = "add_ui",       dest = 1, source = 2, immediate = 3 },  -- R_0 + sign-ext(imm) folds into a constant
	or_i             = { op = "or_i",         dest = 1, source = 2, immediate = 3, },
	and_i            = { op = "and_i",        dest = 1, source = 2, immediate = 3, },
	xor_i            = { op = "xor_i",        dest = 1, source = 2, immediate = 3, },
	add_ui_self      = { op = "add_ui",       dest = 1, source = 1, immediate = 2, },
	or_i_self        = { op = "or_i",         dest = 1, source = 1, immediate = 2, },
	-- Present register-form self variants. They are included here so a
	-- known value is not needlessly lost when these encoders are used.
	add_u_self       = { op = "add_u",        dest = 1, sources = {1, 2}, },
	or_u_self        = { op = "or",           dest = 1, sources = {1, 2}, },
	shift_lleft_self = { op = "shift_lleft",  dest = 1, source = 1, immediate = 2, },
}

-- Control-transfer (branch/jump/call) delay-slot policy table.
--
-- Used by the emitted-word delay-slot check to identify which emitted machine-word idents are control transfers whose next emitted word is the hardware delay slot.
-- One table row per emitted encoder; the `family` field is informational. The check matches by `event.ident` against the row keys.
-- `suppress_arg1` (when present) lists first-arg values that suppress the finding even when the next emitted word is `nop` or absent
-- — for example, the fixed `mac_yield()` handshake uses `jump_reg(R_AtomJmp), nop` and is suppressed so the check stays signal-only.
--
-- Consumers:
--   * passes/static_analysis.lua::check_control_transfer_delay_slot_use

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
-- Shared, memoized helpers: a single emitted-word event stream that every downstream pass reads from,
-- built once from the pre-tokenized bodies.

--- @class ComponentBodyEntry
--- @field body_tokens    table        -- pre-tokenized {{tok=string, rel=integer}, ...}
--- @field body_off       integer      -- byte offset of body[1] in `source`
--- @field line_of        fun(pos:integer):integer  -- byte-offset → 1-based line number in `source`
--- @field source         string       -- absolute path of the source containing the declaration
--- @field declaration    integer      -- 1-based line number of the MipsAtomComp_(ac_X) declaration
--- @field kind           string       -- "comp_bare" | "comp_proc"

-- The cross-source component-body index is owned by the corpus (`corpus.component_body_index`, populated by `passes/components.lua`).
-- Consumers (`passes/static_analysis.lua`, `passes/emission_model.lua`) read it directly; per-pass memoization helpers stay out of scope.

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

--- Split the INSIDE of a `f(...)` call on top-level commas.
--- Honors nested parens / braces / brackets and skips strings / comments.
--- Returns a list of trimmed argument strings in source order.
--- (Mirrors split_top_level_commas but for paren-body args; intentionally distinct so a caller's brace-body split isn't confused with an arg list.)
--- @param inner string
--- @return string[]
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

--- Extract the leading identifier + top-level args list from a token string.
--- Returns (ident, args). For tokens without a `(...)` call, args is `{}`.
--- @param tok string
--- @return string, string[]
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
---   * Direct one-word encoders `load_word`, `add_ui`, `nop`, `gte_lw`, ...: One event with `ident` = leading ident, `args` = parsed top-level args.
---   * `nop2` (2-word pseudo-instruction): Two events, both with `ident = "nop"` so the recognized "this slot is a no-op" semantic is visible to downstream analyses.
---   * Any other N-word token in `word_counts`: N events sharing the same `ident` + `args` so useful CPU words retire slots in the cycle budget.
---   * Known `mac_X(...)` calls: Recursively expand the indexed component body, including nested components. Every event from the expansion carries:
---     - `source` / `line` = the COMPONENT'S source path + the line of the token within the component body (i.e. "definition site").
---     - `call_source` / `call_line` = the ROOT atom's source path + call-site line, PRESERVED across recursion so nested events still point at the original root.
---   * Unknown `mac_X` (not in `component_index`): fall back to `word_counts[ident]` if present; otherwise emit one opaque event so the cycle budget accounts for the word.
---   * Marker Tokens (`atom_label(...)` / `atom_offset(...)`): Zero events (they are pure metaprogram hints).
---
--- Cycle protection: a per-expansion `visiting` set tracks components currently on the expansion stack; a re-entry produces a deterministic `{kind = "cycle", ...}` error and aborts that branch (does NOT hang, does NOT recurse).
---
--- Pure: reads `body_entry` / `component_index` / `word_counts`. Memoization is the caller's responsibility.
--- Callers wanting `word_events` / `word_event_errors` precomputed for many atoms should memoize them per atom.
--- @param body_entry       table        -- `{body_tokens, body_off, line_of, source, declaration}` (declaration = root atom's atom.line)
--- @param component_index  table        -- the bare-name → ComponentBodyEntry map from M.get_component_body_index
--- @param word_counts      table        -- macro name → emitted-word count (from `ctx.shared.word_counts`)
--- @return WordEvent[], WordEventError[]

-- ════════════════════════════════════════════════════════════════════════════
-- Section 11: project_emission (per-atom emission projection)
-- ════════════════════════════════════════════════════════════════════════════
--
-- Per-atom emission projection is owned by `passes/emission_model.lua`.
-- The projection is built from the root atom body only; invocation ancestry recursively expands nested components.
-- The items stream is the single ordered source of truth; `word_events` and `markers` are dense views over it.
--
-- The helper below operates on a body string (not a body_entry) so the pass can call it without depending on the older SourceScan / body_off conventions.
-- component_index argument is reserved for recursive component expansion.
-- word_counts table is authored-metadata + current-component count table.

--- @class EmissionProjection
--- @field items       table[] -- Ordered stream of word|label|offset|invoke_begin|invoke_end
--- @field word_events table[] -- Dense view of items where kind == "word"
--- @field markers     table[] -- Dense view of items where kind == "label"|"offset"
--- @field invocations InvocationRecord[] -- dense view of items where kind == "invoke_begin"|"invoke_end"
--- @field errors      table[] -- Token-resolution failures surfaced without fail-loud
--- @field warnings    table[] -- Opaque warnings (e.g. unknown uncounted macro)

--- @class InvocationRecord
--- Lives at `atom.paths.invocations[*]`. Constructed once at the single invocation-construction site
--- (`emit_invoke_begin` inside `_project_emission_inner`); `invoke_begin` / `invoke_end` markers in the items stream share the same `id`.
--- @field id              integer  -- 1-based, monotonic per-atom invocation id (0 is reserved for "no open invocation")
--- @field parent_id       integer  -- 0 for the outermost (root) call; otherwise the id of the immediately enclosing invocation
--- @field kind            string   -- "comp_bare" | "comp_proc" (component form that triggered the expansion)
--- @field component_name  string   -- Bare component name without the `mac_` prefix
--- @field call_text       string   -- Immediate `mac_X(...)` token text (or root call text for the outermost entry)
--- @field root_call_text  string   -- IMMUTABLE outermost `mac_X(...)` token text for every word emitted in this call's expansion
--- @field call_path       string   -- Source path of the call site (root atom source for direct calls, component source for nested expansions)
--- @field call_line       integer  -- Source line of the call site
--- @field def_path        string   -- Source path of the component definition
--- @field def_line        integer  -- Source line of the component declaration
--- @field start_pos       integer  -- 0-based emitted-word position of the FIRST word inside this invocation (the value of `word_idx` AT `emit_invoke_begin` time, BEFORE the first word is emitted). Words emitted inside this invocation occupy `start_pos..start_pos+#body_lines-1` (inclusive, 0-based). Downstream DWARF/provenance consumers MUST read this; do NOT reconstruct it from `start_word` (which is the 1-based items index including `invoke_begin`/`invoke_end` markers).
--- @field end_pos         integer  -- 0-based position of the LAST word inside this invocation (set by `emit_invoke_end` to `word_idx - 1` AFTER all body words are emitted).
--- @field start_word      integer  -- 1-based items index of the `invoke_begin` item
--- @field end_word        integer  -- 1-based items index of the `invoke_end` item (set by `emit_invoke_end`)
--- @field word_count      integer  -- Number of `word` items emitted between `start_word` and `end_word` (inclusive)
--- @field debug_skip      boolean  -- `debug_skip` stamp; true iff `corpus.components[name].debug_skip` is true at construction. Always boolean (never `nil`).
--- @field errors          table[]  -- Per-invocation construction errors (cycle / count_mismatch); does not include pass-level errors

-- Internal recursive walker. The items stream holds every emitted event in order; `word_events`, `markers`,
-- `invocations`, `errors`, `warnings` are dense views / side outputs appended alongside.
--
-- Output rules:
--   * `word` items record: `invocation_ids` (innermost last) and `outermost_invocation_id` (0 if no invocation is open).
--   * `invoke_begin` / `invoke_end` items are zero-width at the current word index; the same `word_index` is recorded on both.
--   * `root_call_text` is the outermost `mac_X(...)` token text for every word emitted inside a component expansion;
--     it is `nil` for direct words emitted from the root atom body.
--   * `call_text` is the IMMEDIATE top-level token spelling for the word (for nested words this is the inner `mac_X(...)` token; 
--     for direct words it is the trimmed encoder token).
--   * `def_path` / `def_line` are the definition site of the current body (component source for nested words; root atom source for direct words, filled in by the pass caller).
--   * Unknown uncounted macros emit one opaque word + one warning. Unknown metadata-backed macros (entry in `word_counts`) emit the declared word count, no warning.
--   * Cycle detection uses an active DFS stack (`visiting`); a cycle appends a construction error to BOTH the projection errors and the cycle invocation's own errors,
--     then breaks out without recursing (the cycle entry still receives an invocation ID + paired `invoke_begin` / `invoke_end` items, so the boundary invariant is preserved).
--   * Component declared-count mismatch (declared vs. measured) is a construction error (kind = "count_mismatch"); recorded on the invocation record and pass-level errors list.
--   * Final boundary check: if any invocation is still open at end of walk, surface a "unbalanced" construction error.
local function _project_emission_inner(root_body_entry, ctx_table)
	local items       = {}
	local word_events = {}
	local markers     = {}
	local invocations = {}
	local errors      = {}
	local warnings    = {}

	local word_idx         = 0
	local invocation_stack = {}   -- stack of currently-open invocation records
	local next_inv_id      = 0

	local function open_invocation_ids_snapshot()
		local ids = {}
		for _, inv in ipairs(invocation_stack) do
			ids[#ids + 1] = inv.id
		end
		return ids
	end

	local function emit_word(encoder, args, line, word_call_text,
		def_source_now, def_line_now,
		immediate_call_text, root_call_text_w)
		local inv_ids   = open_invocation_ids_snapshot()
		local outermost = inv_ids[1] or 0
		-- For words emitted at the root atom body, `immediate_call_text` is nil and the walker's `word_call_text` (the word's own token, e.g. "nop") becomes the effective call_text.
		-- For words emitted inside a component expansion, `immediate_call_text` is the immediate outer `mac_X(...)` token text;
		-- The call that triggered the body expansion we're currently walking.
		local eff_call_text      = immediate_call_text or word_call_text
		local eff_root_call_text = root_call_text_w
		items[#items + 1] = {
			kind                     = "word",
			encoder                  = encoder,
			args                     = args,
			i                        = word_idx,
			word_count               = 1,
			line                     = line,
			call_text                = eff_call_text,
			root_call_text           = eff_root_call_text,
			invocation_ids           = inv_ids,
			outermost_invocation_id  = outermost,
		}
		word_events[#word_events + 1] = {
			i                        = word_idx,
			encoder                  = encoder,
			args                     = args,
			def_path                 = def_source_now or "",
			def_line                 = def_line_now or 0,
			call_text                = eff_call_text,
			root_call_text           = eff_root_call_text,
			invocation_ids           = inv_ids,
			outermost_invocation_id  = outermost,
			word_count               = 1,
		}
		word_idx = word_idx + 1
	end

	local function emit_marker(kind, name, target, line,
		immediate_call_text, root_call_text_w,
		consuming_encoder, consuming_arg_pos)
		local inv_ids   = open_invocation_ids_snapshot()
		local outermost = inv_ids[1] or 0
		-- Markers carry the open invocation stack snapshot. `call_text` / `root_call_text` belong to words, not markers — markers are zero-width and skip per-word call-site attribution.
		-- `consuming_encoder` + `consuming_arg_pos` carry the surrounding control-transfer instruction context
		-- (e.g. `branch_le_zero` consuming its 3rd argument, or `jump` / `call_addr` consuming their only argument).
		-- `passes/offsets.lua` reads these to dispatch per-consuming-instruction offset encoding.
		-- nil for top-level markers (where the marker is the entire token — no surrounding consuming instruction).
		local it = {
			kind                     = kind,
			name                     = name,
			line                     = line,
			word_index               = word_idx,
			invocation_ids           = inv_ids,
			outermost_invocation_id  = outermost,
		}
		if target ~= nil then it.target = target end
		if consuming_encoder then it.consuming_encoder = consuming_encoder end
		if consuming_arg_pos  then it.consuming_arg_pos  = consuming_arg_pos  end
		items[#items + 1] = it
		markers[#markers + 1] = {
			kind              = kind,
			name              = name,
			line              = line,
			word_index        = word_idx,
			target            = target,
			consuming_encoder = consuming_encoder,
			consuming_arg_pos = consuming_arg_pos,
		}
	end

	-- Count top-level commas in `tok` between position `from_pos` (inclusive) and `to_pos` (exclusive).
	-- Tracks paren depth so commas inside nested () don't count. Skips string literals + comments.
	-- Used by `emit_embedded_markers` to compute `consuming_arg_pos` for each embedded marker.
	local function count_top_level_commas(tok, from_pos, to_pos)
		local depth  = 0
		local count  = 0
		local i      = from_pos
		while i < to_pos do
			local c = tok:sub(i, i)
			if c == "'" or c == '"' then
				local next_pos = M.skip_str_or_cmt(tok, i)
				i = (next_pos > i) and next_pos or (i + 1)
			elseif c == "/" and tok:sub(i + 1, i + 1) == "/" then
				-- line comment: skip to end of line
				local nl = tok:find("\n", i, true)
				i = (nl and nl + 1) or (#tok + 1)
			elseif c == "/" and tok:sub(i + 1, i + 1) == "*" then
				-- block comment: skip to matching */
				local close = tok:find("*/", i + 2, true)
				i = (close and close + 2) or (#tok + 1)
			elseif c == "(" then
				depth = depth + 1
				i = i + 1
			elseif c == ")" then
				depth = depth - 1
				i = i + 1
			elseif c == "," and depth == 0 then
				count = count + 1
				i = i + 1
			else
				i = i + 1
			end
		end
		return count
	end

	-- Find the position of the consuming instruction's open paren (the `(` that starts the consuming instruction's argument list).
	-- Returns nil if the token's leading text isn't an ident followed by `(` (e.g. the ident is at the start of a non-instruction token).
	local function find_consuming_paren(tok)
		local i = 1
		while i <= #tok do
			local c = tok:sub(i, i)
			if    c == "(" then return i end
			if not c:match("[%w_]") and c ~= " " then return nil end
			i = i + 1
		end
		return nil
	end

	local function emit_embedded_markers(tok, tok_line, consuming_encoder)
		-- When called with a non-nil `consuming_encoder`, the marker is nested inside that instruction's argument list.
		-- We compute each marker's arg position by counting top-level commas between the consuming instruction's `(` and the marker's start.
		local consuming_paren = nil
		if consuming_encoder then consuming_paren = find_consuming_paren(tok) end
		local pos = 1
		while pos <= #tok do
			-- Trim leading whitespace and comments before each scan.
			pos = M.skip_ws_and_cmt(tok, pos)
			if pos > #tok then break end
			local  ident, after = M.read_ident(tok, pos)
			if not ident then
				-- Not an ident: token is a string or comment; skip or one-step.
				local next_pos = M.skip_str_or_cmt(tok, pos)
				pos = (next_pos > pos) and next_pos or (pos + 1)
				goto continue_loop
			end
			if ident ~= "atom_label" and ident ~= "atom_offset" then
				-- Ordinary ident; nothing to emit, step past the ident only.
				pos = after
				goto continue_loop
			end
			-- Marker ident: parse the (...) arguments.
			local open               = M.skip_ws_and_cmt(tok, after)
			local inner, after_paren = M.read_parens(tok, open)
			if not inner then
				-- (...) Unreadable: fall back to non-marker behavior.
				pos = after
				goto continue_loop
			end
			-- Commit: label takes 1 arg, offset takes 2.
			-- For embedded markers, propagate the consuming_encoder + the marker's arg position
			-- (1-based) so `passes/offsets.lua` can dispatch per-consuming-instruction offset encoding.
			-- Top-level markers (no consuming_encoder) get nil for both — the offsets pass treats
			-- them as branch-equivalent for backward compatibility.
			local arg_pos = nil
			if consuming_encoder and consuming_paren then
				arg_pos = count_top_level_commas(tok, consuming_paren + 1, pos) + 1
			end
			local args = split_top_level_args(inner)
			if ident == "atom_label" then emit_marker("label",  args[1] or "", nil,           tok_line, nil, nil, consuming_encoder, arg_pos)
			else                          emit_marker("offset", args[1] or "", args[2] or "", tok_line, nil, nil, consuming_encoder, arg_pos)
			end
			pos = after_paren
			::continue_loop::
		end
	end

	local function emit_invoke_begin(inv_kind, component_name, call_text,
		root_call_text, call_path, call_line)
		next_inv_id = next_inv_id + 1
		-- Invocation-level debug_skip stamp: Emission pass owns `atom.paths.invocations[*].debug_skip`.
		-- The stamp is resolved from the `corpus.components[name]` registry (passed in via `ctx_table.components` by `emission_model.run`), 
		-- Unmarked components stamp `false` (not `nil`) so consumers can dispatch on the boolean without nil checks.
		--
		-- The walker has already found the component body in `ctx_table.component_index[component_name]`, so the matching entry MUST exist in `ctx_table.components[component_name]`
		-- (both registries are populated from the same source by the components pass).
		-- A missing entry is a corpus-plumbing bug; we fail loudly here rather than silently stamp `false` and mask the regression.
		local  components    = ctx_table.components
		local  component_def = components and components[component_name] or nil
		if not component_def then
			error("duffle.emit_invoke_begin: component " .. string.format("%q", component_name)
				.. " is present in `component_index` (the walker matched a `mac_" .. component_name .. "()` call) but absent from `components` (the canonical corpus.components registry). "
				.. "This is a corpus-plumbing bug — the components pass must populate corpus.components[name] for every component it puts in corpus.component_body_index[name]. " 
				.. "The emission pass refuses to silently stamp `debug_skip = false` for a missing registry entry."
				, 0
			)
		end
		local debug_skip_stamp = component_def.debug_skip == true
		local inv = {
			id              = next_inv_id,
			parent_id       = 0,         -- patched below by caller
			kind            = inv_kind,
			component_name  = component_name,
			call_text       = call_text,
			root_call_text  = root_call_text,
			call_path       = call_path,
			call_line       = call_line,
			def_path        = nil,       -- patched below after component lookup
			def_line        = nil,
			-- 0-based emitted-word position. `word_idx` is the monotonic 0-based counter of `word` items emitted so far in this walk — 
			-- BEFORE this invocation's first word is emitted, it equals the position of the first word inside the invocation. 
			-- `start_word` (1-based items index of `invoke_begin`) is kept for items-walking consumers (Annotation pass bounds checks),
			-- but DWARF / provenance rows MUST read `start_pos` because those rows are 1-based over the dense `word_events` stream (which has no `invoke_begin` items).
			start_pos       = word_idx,
			start_word      = #items + 1, -- 1-based items index of invoke_begin
			end_pos         = nil,        -- patched by emit_invoke_end
			end_word        = nil,        -- patched by emit_invoke_end
			word_count      = 0,
			debug_skip      = debug_skip_stamp,
			errors          = {},
		}
		invocations[#invocations + 1] = inv
		items      [#items       + 1] = {
			kind           = "invoke_begin",
			invocation_id  = inv.id,
			word_index     = word_idx,
			invocation_ids = open_invocation_ids_snapshot(),
		}
		invocation_stack[#invocation_stack + 1] = inv
		return inv
	end

	local function emit_invoke_end(inv)
		-- 0-based emitted-word position of the LAST word inside this invocation.
		-- After the last body word was emitted, `word_idx` was incremented past it, so `word_idx - 1` is the 0-based position of the last word.
		inv.end_pos  = word_idx - 1
		inv.end_word = #items   + 1  -- 1-based items index of invoke_end
		items[#items + 1] = {
			kind           = "invoke_end",
			invocation_id  = inv.id,
			word_index     = word_idx,
			invocation_ids = open_invocation_ids_snapshot(),
		}
		for i = #invocation_stack, 1, -1 do
			if invocation_stack[i] == inv then
				table.remove(invocation_stack, i)
				break
			end
		end
	end

	-- Resolve the per-token word count. If unresolved, surface ONE warning
	-- and fall back to 1 opaque word so the cycle budget still accounts for the slot.
	local function resolve_count(ident, tok_line)
		local wc = ctx_table.word_counts
		if    wc and wc[ident] then return wc[ident] end
		if M.GTE_COMMAND_ALIASES then
			local seen   = { [ident] = true }
			local target = M.GTE_COMMAND_ALIASES[ident]
			while target and not seen[target] do
				seen[target] = true
				if wc and wc[target] then return wc[target] end
				target = M.GTE_COMMAND_ALIASES[target]
			end
		end
		warnings[#warnings + 1] = {
			kind = "uncounted",
			line = tok_line,
			msg  = string.format("project_emission: opaque word emitted for %q (no entry in word_counts or component_index)", 
			ident),
		}
		return 1
	end

	-- Recursive walker: walk one body entry, possibly descending into components.
	-- walk_parent_inv_id:       Invocation ID of the enclosing call (0 for the root call).
	-- walk_root_call_text:      Outermost `mac_X(...)` token text (preserved across recursion).
	-- walk_immediate_call_text: IMMEDIATE outer `mac_X(...)` token text for words emitted in this body — nil for the root atom body.
	-- Two trackers are propagated as separate parameters so words deep inside nested expansions correctly identify both their immediate call site and the outermost call site.
	local function walk_body_entry(body_entry, walk_parent_inv_id,
		walk_root_call_text, walk_immediate_call_text)
		local tokens     = body_entry.body_tokens or {}
		local body_off   = body_entry.body_off or 0
		local line_of    = body_entry.line_of or M.LineIndex("")
		local def_source = body_entry.source or ""
		local def_line   = body_entry.declaration or 0
		-- Per-token dispatch: each matched branch returns; only the fall-through
		-- "opaque word" emit handles direct encoders + mac_X-without-component.
		local function process_token(bt)
			local tok = M.trim(bt.tok or "")
			if tok == "" then return end
			local ident    = M.read_ident(tok, 1) or "?"
			local _, args  = token_ident_and_args(tok)
			local tok_line = line_of(body_off + bt.rel) or 0
			-- embedded markers live only in non-marker tokens.
			-- Pass `ident` as the consuming instruction so `emit_embedded_markers` can compute each marker's arg position + record the consuming_encoder for the offsets pass.
			-- Canonicalize `jump_rel` to `branch_equal` (its preprocessor-expanded form) so the `consuming_encoder` metadata in marker records is canonical. 
			-- `jump_rel`: unconditional jump alias from `code/duffle/mips.h`.
			local consuming_encoder_for_markers = (ident == "jump_rel") and "branch_equal" or ident
			if ident ~= "atom_label" and ident ~= "atom_offset" then
				emit_embedded_markers(tok, tok_line, consuming_encoder_for_markers)
			end
			-- atom_label / atom_offset: terminal markers, no further descent.
			-- Top-level markers (the marker IS the entire token) have no consuming instruction;
			-- nil for both `consuming_encoder` and `consuming_arg_pos`.
			-- The offsets pass treats these as branch-equivalent for backward compatibility.
			-- TODO(Ed): Review this don't want legacy cruft here..
			if     ident == "atom_label"  then emit_marker("label",  args[1] or "", nil,           tok_line); return
			elseif ident == "atom_offset" then emit_marker("offset", args[1] or "", args[2] or "", tok_line); return
			end
			if ident:sub(1, 4) == "mac_" then
				local bare = ident:sub(5)
				local comp = ctx_table.component_index[bare]
				if comp then
					local invocation_root_call_text = walk_root_call_text or tok
					if ctx_table.visiting[bare] then
						-- Cycle: still allocate inv_id, emit zero-width begin/end, record the cycle error; do NOT recurse.
						local inv = emit_invoke_begin(comp.kind or "comp_bare", bare, tok, invocation_root_call_text, def_source, tok_line)
						inv.parent_id = walk_parent_inv_id
						inv.call_text = tok
						local err = {
							kind   = "cycle",
							msg    = string.format("project_emission: component cycle detected: %q", bare),
							source = def_source,
							line   = tok_line,
						}
						inv.errors[#inv.errors + 1] = err
						errors    [#errors     + 1] = err
						emit_invoke_end(inv)
						return
					end
					-- First visit: descend + count + count_mismatch-check below.
					ctx_table.visiting[bare] = true
					local inv = emit_invoke_begin(comp.kind or "comp_bare", bare, tok, invocation_root_call_text, def_source, tok_line)
					inv.parent_id = walk_parent_inv_id
					inv.call_text = tok
					inv.def_path  = comp.source
					inv.def_line  = comp.declaration
					-- Propagate trackers into the recursive walk:
					--   immediate_call_text = this call's tok (the IMMEDIATE outer call for words emitted in this body)
					--   root_call_text      = the OUTERMOST call (immutable across the recursion)
					walk_body_entry({
							body_tokens = comp.body_tokens or {},
							body_off    = comp.body_off or 0,
							line_of     = comp.line_of,
							source      = comp.source,
							declaration = comp.declaration,
						},
						inv.id,
						invocation_root_call_text,
						tok)
					ctx_table.visiting[bare] = nil
					emit_invoke_end(inv)
					-- Count `word` items inside [start_word, end_word].
					local wc_inside = 0
					for i = inv.start_word, inv.end_word do
						local it = items[i]
						if it and it.kind == "word" then
							wc_inside = wc_inside + 1
						end
					end
					inv.word_count = wc_inside
					-- count_mismatch is a construction error: word_counts["mac_X"] is the declared count populated by the components pass; 
					-- We compare against the measured word count.
					local declared = ctx_table.word_counts["mac_" .. bare]
					if declared and wc_inside ~= declared then
						local err = {
							kind   = "count_mismatch",
							msg    = string.format("project_emission: mac_%s declared=%d measured=%d", bare, declared, wc_inside),
							source = def_source,
							line   = tok_line,
						}
						inv.errors[#inv.errors + 1] = err
						errors    [#errors     + 1] = err
					end
					return
				end
				-- mac_X NOT in component_index: fall through to opaque emit.
			end
			-- Direct encoder, or mac_X-without-component: resolve count + emit n words.
			-- Resolve_count may emit a warning if the count is unresolved.
			local n         = resolve_count(ident, tok_line)
			local out_ident = (ident == "nop2") and "nop" or ident
			for _ = 1, n do
				emit_word(out_ident, args, tok_line, tok, def_source, def_line, walk_immediate_call_text, walk_root_call_text)
			end
		end
		
		for _, bt in ipairs(tokens) do
			process_token(bt)
		end
	end

	-- Initialize the per-walk mutable context.
	-- `visiting` is the active DFS component stack; `root_call_path` / `root_call_line` are preserved across recursion so nested words always point at the
	-- ORIGINAL root atom call site.
	ctx_table.visiting       = ctx_table.visiting        or {}
	ctx_table.root_call_path = ctx_table.root_call_path  or ""
	ctx_table.root_call_line = ctx_table.root_call_line  or 0

	-- Walk first; the pass caller stamps the root call site for direct words after the projection returns.
	-- For nested words the def_path / def_line already point at the component source and MUST be preserved (the stamping helper checks for that).
	walk_body_entry(root_body_entry, 0, nil, nil)

	-- Boundary check: every invoke_begin must have a matching invoke_end.
	-- If anything is still open, surface a hard error.
	if #invocation_stack > 0 then
		errors[#errors + 1] = {
			kind = "unbalanced",
			msg  = string.format("project_emission: invocation boundaries not balanced (%d unclosed invocation(s) at end of walk)", #invocation_stack),
		}
	end

	return {
		items       = items,
		word_events = word_events,
		markers     = markers,
		invocations = invocations,
		errors      = errors,
		warnings    = warnings,
	}
end

--- Project a body string into the per-atom emission projection.
---
--- Semantics:
---   * Direct one-word tokens (`nop`, `add_ui`, ...): one `word` item, encoder = ident, word_count = 1.
---   * Metadata-backed N-word tokens (`nop2`, `mask_upper`, ...): N `word` items, all sharing the same encoder + word_count = 1.
---     `nop2` is normalized to encoder `nop` (per the spec).
---   * `atom_label(F)` markers: one `label` item with `name = "F"`, `word_index = current word_idx`; zero-width (does NOT advance word_idx).
---   * `atom_offset(B, T)` markers: one `offset` item with `name = "B"`, `target = "T"`, `word_index = current word_idx`; zero-width.
---   * `mac_X(...)` calls: emit `invoke_begin` (zero-width), recurse into the component body, emit `invoke_end` (zero-width).
---     The component body's words land between the begin/end pair; one invocation record is allocated per call (monotonic ID per atom).
---   * Unknown uncounted macros emit 1 opaque word + one warning per occurrence.
---   * Tokens whose count cannot be resolved (e.g. `mac_unknown` not in word_counts and not in component_index) surface one
---     warning; cycle + count-mismatch + boundary violations are construction errors on `pass.errors`.
---
--- Every emitted `word` carries: `i` (0-based word index), `encoder`, `args` (top-level args), `def_path`, `def_line`,
--- `call_text` (the immediate token spelling), `root_call_text` (outermost `mac_X(...)` text), `word_count` (always 1),
--- `invocation_ids` (innermost last), `outermost_invocation_id`.
--- Markers carry: `kind`, `name`, `line`, `word_index`, `target` (only for offset kind), plus `invocation_ids` / `outermost_invocation_id`
--- for the open invocation stack at that word.
---
--- @param body_text       string  -- the raw atom body string
--- @param component_index table   -- bare-name → component record (corpus.component_body_index)
--- @param word_counts     table   -- macro name → emitted word count
--- @param components      table   -- bare-name → component definition (corpus.components); REQUIRED — consumed at the invocation-construction site to stamp
---                                   `invocation.debug_skip`. A missing or non-table `components` raises a fail-loud error rather than silently falling back.
--- @return EmissionProjection
function M.project_emission(body_text, component_index, word_counts, components)
	-- The recursive walk delegates to `_project_emission_inner` so component bodies (which arrive as
	-- `{body_tokens, body_off, line_of, source, declaration}` records from `corpus.component_body_index`)
	-- re-enter the same walker with the same shared output state.
	--
	-- The walker is body-relative: it builds `line_of` from `body_text` and stamps body-relative line numbers (1..N)
	-- into `item.line` and `invocation.call_line`. `passes/emission_model.lua::stamp_root_provenance` performs the single
	-- conversion from body-relative to physical source line at the close site, using the source's `line_of` closure that
	-- the pass forwarded. One owner of the line state.
	if type(components) ~= "table" then
		error("duffle.project_emission: `components` is required "
			.. "(bare-name -> component definition, e.g. corpus.components); "
			.. "got " .. type(components) .. ". "
			.. "The emission pass MUST forward the corpus registry "
			.. "so the invocation-construction site can stamp `debug_skip` "
			.. "without a second pass, source parse, or parallel lookup.",
			0)
	end

	if type(body_text) ~= "string" or body_text == "" then
		-- Empty body: still return a valid (empty) projection.
		return {
			items       = {},
			word_events = {},
			markers     = {},
			invocations = {},
			errors      = {},
			warnings    = {},
		}
	end

	local tokens = M.tokenize_body(body_text)
	return _project_emission_inner({
		body_tokens = tokens,
		body_off    = 0,
		line_of     = M.LineIndex(body_text),
		source      = "",
		declaration = 0,
	},
	{
		component_index = component_index or {},
		word_counts     = word_counts     or {},
		components      = components,
	})
end

return M
