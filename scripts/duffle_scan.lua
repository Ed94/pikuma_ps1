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
		local server      = input:sub(server_start, server_end - 1)
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
		elseif byte == BYTE_BACKSLASH and source:byte(pos + 1) == BYTE_CR and source:byte(pos + 2) == BYTE_NEWLINE then
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

return M
