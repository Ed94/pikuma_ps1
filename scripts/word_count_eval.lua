--- word_count_eval.lua — Word-counting logic for the tape-atom metaprogram
--- pipeline.
---
--- Three responsibilities:
---   1. **Public utilities** (used by `passes/components.lua`,
---      `passes/offsets.lua`, `passes/annotation.lua`):
---        - `M.count_token_words(token, wc)` — words emitted by one token
---        - `M.scan_dir(dir, suffix)` — glob walk for *.macs.h
---        - `M.count_body_words(body, wc)` — words emitted by an atom body
---   2. **Pass entry** `M.run(ctx)` — loads metadata.h + *.macs.h into
---      `ctx.shared.word_counts` for downstream passes.
---   3. **Internal helpers** for the body scanner.
---
--- **Conventions**: tabs (1/level), EmmyLua annotations, no regex,
--- Lua 5.3 compatible. See
--- `C:\projects\Pikuma\ps1-ai\conductor\code_styleguides\lua.md`.

-- ════════════════════════════════════════════════════════════════════════════
-- Module-scope requires + package.path setup
-- ════════════════════════════════════════════════════════════════════════════

-- Resolve `arg[0]` to an absolute-ish script directory so that
-- `require("duffle")` resolves against `scripts/` regardless of CWD.
-- Note: this boilerplate is duplicated in 6 other entry scripts; a
-- Phase-6 extraction target (`duffle.setup_package_path()`).
local script_path = arg and arg[0] or "?"
local last_sep = 0
for sep_pos = 1, #script_path do
	local ch = script_path:sub(sep_pos, sep_pos)
	if ch == "/" or ch == "\\" then last_sep = sep_pos end
end
local script_dir = last_sep == 0 and "./" or script_path:sub(1, last_sep)
package.path   = script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. package.path
package.cpath = "C:\\projects\\Pikuma\\ps1\\toolchain\\luajit-2.1\\lib\\lua\\5.1\\?.dll;" .. package.cpath

local duffle = require("duffle")

-- ════════════════════════════════════════════════════════════════════════════
-- Constants
-- ════════════════════════════════════════════════════════════════════════════

-- Windows separator chars — used to convert `dir /b /s` output (which uses
-- `\`) into POSIX paths (which our scripts expect).
local PATH_SEP_BACKSLASH = "\\"
local PATH_SEP_FORWARD   = "/"

-- Glob command for Windows directory walk. `dir /b /s` lists all matching
-- files recursively with bare paths (no headers); `2>nul` discards the
-- "file not found" stderr when nothing matches.
local DIR_GLOB_CMD = 'dir /b /s "%s\\%s" 2>nul'

-- ════════════════════════════════════════════════════════════════════════════
-- Type declarations
-- ════════════════════════════════════════════════════════════════════════════

--- @class WordCounts
--- @field [string] integer  -- macro name -> word count

--- @class SourceFile
--- @field path     string  -- absolute path to the source file
--- @field text     string  -- the full source text
--- @field dir      string  -- the directory containing the source
--- @field basename string  -- filename without extension

--- @class PassCtx
--- @field sources            SourceFile[]  -- all source files in the build
--- @field metadata_path      string        -- path to word_count.metadata.h
--- @field shared             table         -- cross-pass shared state
--- @field shared.word_counts WordCounts    -- populated by this pass
--- @field out_root           string        -- output root (e.g. "build/gen")
--- @field project_root       string        -- project root (e.g. "code/")
--- @field upstream           table<string, table>  -- per-pass upstream outputs
--- @field flags              table         -- CLI flags
--- @field dry_run            boolean       -- if true, compute but don't write
--- @field verbose            boolean       -- if true, log diagnostic info

--- @class PassResult
--- @field outputs  table[]  -- {kind=, path=} entries describing emit files
--- @field errors   table[]  -- {line=, msg=} entries; build-stops
--- @field warnings table[]  -- {line=, msg=} entries; build-succeeds

-- ════════════════════════════════════════════════════════════════════════════
-- Module exports
-- ════════════════════════════════════════════════════════════════════════════

local M = {}

-- ┌────────────────────────────────────────────────────────────────────┐
-- │ Shared utility: count_token_words                                  │
-- └────────────────────────────────────────────────────────────────────┘

--- Count words emitted by a single comma-separated token inside an atom body.
--- For most tokens (regular MIPS instructions) this returns 1.
--- For `mac_X(...)` calls, this returns the resolved word count from `wc`
--- (recursively if needed). For `nop2` etc., returns wc[name].
--- For unknown macros, returns 1 and (optionally) warns.
---
--- @param token string        -- a single token from split_top_level_commas
--- @param wc WordCounts       -- the shared word-count table
--- @return integer
function M.count_token_words(token, wc)
	local s = duffle.trim(token)
	if s == "" then return 0 end
	local name, after = duffle.read_ident(s, 1)
	if not name then return 1 end
	if wc[name] then return wc[name] end
	local paren_pos = duffle.skip_ws_and_cmt(s, after)
	if s:sub(paren_pos, paren_pos) == "(" then
		io.stderr:write("  warning: unknown macro '" .. name .. "', assuming 1 word\n")
	end
	return 1
end

-- ┌────────────────────────────────────────────────────────────────────┐
-- │ Shared utility: scan_dir                                           │
-- └────────────────────────────────────────────────────────────────────┘

--- Recursively scan a directory for files matching a glob suffix.
--- No regex per the no_regex constraint — uses plain byte matching
--- via `dir /b /s` on Windows.
---
--- @param dir string        -- directory to scan (absolute or relative)
--- @param suffix string     -- file pattern, e.g. "*.macs.h"
--- @return string[]
function M.scan_dir(dir, suffix)
	local results = {}
	local pipe = io.popen(DIR_GLOB_CMD:format(dir, suffix))
	if not pipe then return results end
	for raw_line in pipe:lines() do
		local path = raw_line:gsub(PATH_SEP_BACKSLASH, PATH_SEP_FORWARD)
		results[#results + 1] = path
	end
	pipe:close()
	return results
end

-- ┌────────────────────────────────────────────────────────────────────┐
-- │ Shared utility: count_body_words                                   │
-- └────────────────────────────────────────────────────────────────────┘

--- Count words emitted by an entire atom body (a brace-delimited block).
--- Splits by top-level commas; for each token, delegates to count_token_words.
--- Handles `atom_label(name)` / `atom_offset(tag, name)` markers (record at
--- current pos, do NOT advance pos; if the marker call bundles an instruction
--- after it, count that instruction too).
---
--- @param body string         -- brace-delimited atom body (without braces)
--- @param wc WordCounts       -- the shared word-count table
--- @return integer            -- total words
function M.count_body_words(body, wc)
	local total = 0
	for _, tok in ipairs(duffle.split_top_level_commas(body)) do
		local pos     = 1
		local tok_len = #tok
		while pos <= tok_len and duffle.is_space(tok:sub(pos, pos)) do
			pos = pos + 1
		end
		local leading_ident = duffle.read_ident(tok, pos)
		local is_marker = leading_ident == "atom_label" or leading_ident == "atom_offset"
		if is_marker then
			-- Marker call: record at current pos, do NOT advance pos.
			-- But the source pattern may bundle the marker with the next
			-- instruction on a new line (no top-level comma between them).
			-- In that case, the rest of `tok` after the marker call is
			-- a real instruction that must still be counted.
			local marker_end = M.find_marker_call_end(tok)
			if marker_end > 0 and marker_end < #tok then
				local rest = duffle.trim(tok:sub(marker_end + 1))
				if rest ~= "" then
					total = total + M.count_token_words(rest, wc)
				end
			end
		else
			total = total + M.count_token_words(tok, wc)
		end
	end
	return total
end

--- Find the end position (just past the closing ')') of the first
--- atom_label/atom_offset call in `tok`. Returns 0 if no such call.
--- Internal helper for count_body_words.
---
--- @param tok string
--- @return integer  -- 0 if no marker call found
function M.find_marker_call_end(tok)
	local pos     = 1
	local tok_len = #tok
	while pos <= tok_len do
		pos = duffle.skip_ws_and_cmt(tok, pos)
		if pos > tok_len then break end
		local ch = tok:sub(pos, pos)
		if duffle.is_space(ch) then
			pos = pos + 1
		elseif ch == "/" then
			-- comment — skip past it (delegated to duffle.skip_str_or_cmt)
			local nx = duffle.skip_str_or_cmt(tok, pos)
			pos = (nx > pos) and nx or (pos + 1)
		else
			local ident, after_ident = duffle.read_ident(tok, pos)
			local marker_end = find_marker_end(tok, ident, after_ident)
			if marker_end > 0 then return marker_end end
			pos = after_ident or (pos + 1)
		end
	end
	return 0
end

-- (internal) If `ident` is `atom_label`/`atom_offset` followed by `(...)`,
-- return the position just past the closing ')'. Otherwise 0.
-- @param tok string
-- @param ident string|nil
-- @param after_ident integer
-- @return integer
local function find_marker_end(tok, ident, after_ident)
	if ident ~= "atom_label" and ident ~= "atom_offset" then return 0 end
	local open_paren = duffle.skip_ws_and_cmt(tok, after_ident)
	if tok:sub(open_paren, open_paren) ~= "(" then return 0 end
	local _, end_paren = duffle.read_parens(tok, open_paren)
	return end_paren - 1
end

-- ┌────────────────────────────────────────────────────────────────────┐
-- │ Pass entry: M.run(ctx) — "word-counts" pass                        │
-- └────────────────────────────────────────────────────────────────────┘

--- Load metadata.h + scan for existing *.macs.h files into
--- ctx.shared.word_counts. Loading the .macs.h files is idempotent:
--- entries from later (current-build) .macs.h files override
--- metadata.h entries of the same name.
---
--- @param ctx PassCtx
--- @return PassResult
function M.run(ctx)
	local wc = {}

	-- 1. Load metadata.h (the encoding-macro source of truth).
	local meta_counts = duffle.load_word_counts(ctx.metadata_path)
	for name, count in pairs(meta_counts) do wc[name] = count end

	-- 2. Scan project_root recursively for *.macs.h files (component-macro source).
	local macs_files = M.scan_dir(ctx.project_root, "*.macs.h")
	for _, macs_path in ipairs(macs_files) do
		local ok, mc = pcall(duffle.load_word_counts, macs_path)
		if not ok then
			io.stderr:write(string.format("[word_count_eval] parse error in '%s': %s\n", macs_path, tostring(mc)))
		elseif type(mc) ~= "table" then
			io.stderr:write(string.format("[word_count_eval] '%s' did not return a table (got %s)\n", macs_path, type(mc)))
		else
			for name, count in pairs(mc) do wc[name] = count end
		end
	end

	ctx.shared.word_counts = wc

	return { outputs = {}, errors = {}, warnings = {} }
end

return M
