-- word_count_eval.lua
--
-- Word-counting logic for the tape-atom metaprogram pipeline.
-- Used by:
--   - passes/components.lua (compute_component_word_count)
--   - passes/offsets.lua    (scan_atom_body)
--   - passes/annotation.lua (TAPE_WORDS <-> WORD_COUNT drift check)
--
-- This module ALSO exposes M.run(ctx) — the "word-counts" pass entry in
-- the PASSES table — which loads metadata.h + scans for existing
-- *.macs.h files into ctx.shared.word_counts.
--
-- Coding standard: tabs (1/level), EmmyLua annotations, no regex,
-- Lua 5.3 compatible.

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
package.path   = script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. package.path
package.cpath = "C:\\projects\\Pikuma\\ps1\\toolchain\\luajit-2.1\\lib\\lua\\5.1\\?.dll;" .. package.cpath

local duffle = require("duffle")
local trim              = duffle.trim
local read_ident        = duffle.read_ident
local skip_ws_and_cmt   = duffle.skip_ws_and_cmt
local load_word_counts  = duffle.load_word_counts
local split_top_level_commas = duffle.split_top_level_commas
local is_space          = duffle.is_space

-- ════════════════════════════════════════════════════════════════════════════
-- Type declarations
-- ════════════════════════════════════════════════════════════════════════════

--- @class WordCounts
--- @field [string] integer  -- macro name -> word count

--- @class PassCtx
--- @field sources            SourceFile[]
--- @field metadata_path      string
--- @field shared             table
--- @field shared.word_counts WordCounts
--- @field out_root           string
--- @field project_root       string
--- @field upstream           table<string, table>
--- @field flags              table
--- @field dry_run            boolean
--- @field verbose            boolean

--- @class PassResult
--- @field outputs  table[]
--- @field errors   table[]
--- @field warnings table[]

--- @class SourceFile
--- @field path     string
--- @field text     string
--- @field dir      string
--- @field basename string

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
	local s = trim(token)
	if s == "" then return 0 end
	local name, after = read_ident(s, 1)
	if not name then return 1 end
	if wc[name] then return wc[name] end
	local j = skip_ws_and_cmt(s, after)
	if s:sub(j, j) == "(" then
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
	local p = io.popen('dir /b /s "' .. dir .. '\\' .. suffix .. '" 2>nul')
	if not p then return results end
	for raw_line in p:lines() do
		local path = raw_line:gsub("\\", "/")
		results[#results + 1] = path
	end
	p:close()
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
	local pos = 0
	for _, tok in ipairs(split_top_level_commas(body)) do
		local k    = 1
		local tlen = #tok
		while k <= tlen and is_space(tok:sub(k, k)) do k = k + 1 end
		local leading_ident = read_ident(tok, k)
		if leading_ident == "atom_label" or leading_ident == "atom_offset" then
			-- Marker call: record at current pos, do NOT advance pos.
			-- But the source pattern may bundle the marker with the next
			-- instruction on a new line (no top-level comma between them).
			-- In that case, the rest of `tok` after the marker call is
			-- a real instruction that must still be counted.
			local marker_end = M.find_marker_call_end(tok)
			if marker_end > 0 and marker_end < #tok then
				local rest = trim(tok:sub(marker_end + 1))
				if rest ~= "" then
					local rest_words = M.count_token_words(rest, wc)
					pos = pos + rest_words
				end
			end
		else
			pos = pos + M.count_token_words(tok, wc)
		end
	end
	return pos
end

--- Find the end position (just past the closing ')') of the first
--- atom_label/atom_offset call in `tok`. Returns 0 if no such call.
--- Internal helper for count_body_words.
---
--- @param tok string
--- @return integer  -- 0 if no marker call found
function M.find_marker_call_end(tok)
	local i   = 1
	local len = #tok
	while i <= len do
		i = skip_ws_and_cmt(tok, i)
		if i > len then break end
		local c = tok:sub(i, i)
		if is_space(c) then
			i = i + 1
		elseif c == "/" then
			-- comment — skip past it (delegated to duffle.skip_str_or_cmt)
			local nx = duffle.skip_str_or_cmt(tok, i)
			if nx > i then i = nx else i = i + 1 end
		else
			local ident, after = read_ident(tok, i)
			if ident == "atom_label" or ident == "atom_offset" then
				local j = skip_ws_and_cmt(tok, after)
				if tok:sub(j, j) == "(" then
					local _, end_paren = duffle.read_parens(tok, j)
					return end_paren - 1
				end
				return 0
			end
			i = after or (i + 1)
		end
	end
	return 0
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
	local meta_counts = load_word_counts(ctx.metadata_path)
	for name, count in pairs(meta_counts) do wc[name] = count end

	-- 2. Scan project_root recursively for *.macs.h files (component-macro source).
	local macs_files = M.scan_dir(ctx.project_root, "*.macs.h")
	for _, macs_path in ipairs(macs_files) do
		local ok, mc = pcall(load_word_counts, macs_path)
		if ok and type(mc) == "table" then
			for name, count in pairs(mc) do wc[name] = count end
		end
	end

	ctx.shared.word_counts = wc

	return { outputs = {}, errors = {}, warnings = {} }
end

return M