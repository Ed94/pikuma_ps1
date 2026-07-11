--- word_count_eval.lua — Word-counting logic for the tape-atom metaprogram pipeline.
---
--- Three responsibilities:
---   1. **Public utilities** (used by `passes/components.lua`, `passes/offsets.lua`, `passes/annotation.lua`):
---        - `M.count_token_words(token, wc)` — words emitted by one token
---        - `M.scan_dir(dir, suffix)` — glob walk for *.macs.h
---        - `M.count_body_words(body, wc)` — words emitted by an atom body
---   2. **Pass entry** `M.run(ctx)` — loads metadata.h + *.macs.h into `ctx.shared.word_counts` for downstream passes.
---   3. **Internal helpers** for the body scanner.
---
--- **Conventions**: tabs (1/level), EmmyLua annotations, no regex,
--- Lua 5.3 compatible.

-- ════════════════════════════════════════════════════════════════════════════
-- Module-scope requires + package.path setup
-- ════════════════════════════════════════════════════════════════════════════

-- Resolve `arg[0]` to an absolute-ish script directory so that `require("duffle")` resolves against `scripts/` regardless of CWD.
-- Note: this boilerplate is duplicated in 6 other entry scripts; a Phase-6 extraction target (`duffle.setup_package_path()`).
-- Bootstrap: see `ps1_meta.lua` for the rationale.
-- Bootstrap: load `scripts/duffle_paths.lua` (sets package.path + package.cpath).
-- Uses `debug.getinfo` to find this file's own directory, so it works both standalone and when require'd from the orchestrator.
-- Bootstrap: load `duffle_paths.lua` via `debug.getinfo(1, "S").source` (works both standalone + when require'd).
-- duffle_paths.lua sets package.path then returns `require("duffle")` at the bottom, so the dofile value IS the duffle module.
local _bootstrap_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local duffle        = dofile(_bootstrap_dir .. "../duffle_paths.lua")

-- ════════════════════════════════════════════════════════════════════════════
-- Constants
-- ════════════════════════════════════════════════════════════════════════════

-- Windows separator chars — used to convert `dir` output (which uses `\`) into POSIX paths (which our scripts expect).
local PATH_SEP_BACKSLASH = "\\"
local PATH_SEP_FORWARD   = "/"

-- Fallback glob command (subprocess). Used when `lfs` (LuaFileSystem) is not available.
-- Scoped to `code\` to avoid walking `.git/`, `toolchain/`, `build/`, etc.
local DIR_GLOB_CMD = 'dir /b /s "%s\\code\\%s" 2>nul'

-- Try to load lfs (LuaFileSystem). If available, scan_dir uses native directory enumeration (~2ms)
-- instead of spawning `dir /b /s` as a subprocess (~56ms). Built by update_deps.ps1 into toolchain/lfs/lfs.dll.
local lfs = pcall(require, "lfs") and require("lfs") or nil

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
--- For `mac_X(...)` calls, this returns the resolved word count from `wc` (recursively if needed). For `nop2` etc., returns wc[name].
--- For unknown macros, returns 1 and (optionally) warns.
---
--- @param token string        -- a single token from split_top_level_commas
--- @param wc WordCounts       -- the shared word-count table
--- @return integer
function M.count_token_words(token, wc)
	local s = duffle.trim(token)
	if    s == "" then return 0 end
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
--- No regex per the no_regex constraint — uses plain byte matching via `dir /b /s` on Windows.
---
--- The `.macs.h` files produced by the components pass always live at `<project_root>/<module>/gen/`.
--- We can shortcut the `dir /b /s` walk by listing modules first (one `dir /b /ad`), then walking each `<module>/gen/`
--- (one `dir /b` per module, no recursion). 
--- For projects with 2 modules and 0 .macs.h files, this drops the cost from ~52ms 
--- (full recursive walk of the entire project tree) to ~5ms.
---
--- @param dir string        -- directory to scan (absolute or relative)
--- @param suffix string     -- file pattern, e.g. "*.macs.h"
--- @return string[]
-- Cache the scan_dir result per (dir, suffix) in package.loaded. 
-- Each `io.popen` call on Windows is ~50-100ms of subprocess overhead, so caching the result saves a fixed cost on every build.
-- The cache persists for the lifetime of the Lua process (cleared when ps1_meta.lua exits).
-- If a build removes/creates .macs.h files mid-process, the caller can invalidate by calling `M._invalidate_scan_cache()`.
local SCAN_CACHE_KEY = "__word_count_eval_scan_cache__"

--- Scan `code/` for files matching `suffix` (e.g. `*.macs.h`).
--- Uses `lfs` (LuaFileSystem) when available — native directory enumeration at ~2ms.
--- Falls back to `dir /b /s` subprocess (~56ms) when `lfs` is not compiled.
---
--- @param dir string        -- project root directory
--- @param suffix string     -- file pattern, e.g. "*.macs.h"
--- @return string[]
function M.scan_dir(dir, suffix)
	local key = dir .. "\0" .. suffix

	local cache = package.loaded[SCAN_CACHE_KEY]
	if    cache and cache[key] then return cache[key] end

	local results = {}

	if lfs then
		-- Native walk: list code/<module>/gen/ for matching files. Zero subprocess spawns.
		local code_dir = dir .. "/code"
		if lfs.attributes(code_dir, "mode") == "directory" then
			for mod_name in lfs.dir(code_dir) do
				if mod_name ~= "." and mod_name ~= ".." then
					local gen_path = code_dir .. "/" .. mod_name .. "/gen"
					if lfs.attributes(gen_path, "mode") == "directory" then
						for fname in lfs.dir(gen_path) do
							if fname:match("%.macs%.h$") then
								results[#results + 1] = gen_path .. "/" .. fname
							end
						end
					end
				end
			end
		end
	else
		-- Fallback: single `dir /b /s` subprocess scoped to code\.
		local pipe = io.popen(DIR_GLOB_CMD:format(dir, suffix))
		if pipe then
			for raw_line in pipe:lines() do
				results[#results + 1] = raw_line:gsub(PATH_SEP_BACKSLASH, PATH_SEP_FORWARD)
			end
			pipe:close()
		end
	end

	-- Cache the result (including empty results).
	cache      = cache or {}
	cache[key] = results
	package.loaded[SCAN_CACHE_KEY] = cache

	return results
end

--- Invalidate the scan cache (call after creating new .macs.h files in the same Lua process — usually not needed).
function M._invalidate_scan_cache() package.loaded[SCAN_CACHE_KEY] = nil end

-- ┌────────────────────────────────────────────────────────────────────┐
-- │ Shared utility: count_body_words                                   │
-- └────────────────────────────────────────────────────────────────────┘

--- Count words emitted by an entire atom body (a brace-delimited block).
--- Splits by top-level commas; for each token, delegates to count_token_words.
--- Handles `atom_label(name)` / `atom_offset(tag, name)` markers 
--- (record at current pos, do NOT advance pos; if the marker call bundles an instruction after it, count that instruction too).
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
			-- But the source pattern may bundle the marker with the next instruction on a new line (no top-level comma between them).
			-- In that case, the rest of `tok` after the marker call is a real instruction that must still be counted.
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

--- Find the end position (just past the closing ')') of the first atom_label/atom_offset call in `tok`. Returns 0 if no such call.
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
			pos      = (nx > pos) and nx or (pos + 1)
		else
			local ident, after_ident = duffle.read_ident(tok, pos)
			local marker_end         = find_marker_end(tok, ident, after_ident)
			if marker_end > 0 then return marker_end end
			pos = after_ident or (pos + 1)
		end
	end
	return 0
end

-- (internal) If `ident` is `atom_label`/`atom_offset` followed by `(...)`, return the position just past the closing ')'. 
-- Otherwise 0.
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

--- Load metadata.h + scan for existing *.macs.h files into ctx.shared.word_counts.
--- Loading the .macs.h files is idempotent: entries from later (current-build) .macs.h files override metadata.h entries of the same name.
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
