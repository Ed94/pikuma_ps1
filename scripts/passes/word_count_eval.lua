--- word_count_eval.lua — Word-counting logic for the tape-atom metaprogram pipeline.
---
--- Two responsibilities:
---   1. **Public utility** `M.count_token_words(token, wc)`: Used by `passes/offsets.lua`, `passes/annotation.lua`, and other passes.
---   2. **Pass entry** `M.run(ctx)`: Loads the authored `word_count.metadata.h` into `ctx.shared.corpus.word_counts` for downstream passes.
---      The generated `.macs.h` files are OUTPUT artifacts and are NOT inputs to this pass;
---      Current component counts are owned by `passes/components.lua` (which populates `corpus.word_counts` and `corpus.component_body_index`
---      AFTER computing each current count from the just-built body + `corpus.word_counts`).
---
--- **Canonical contract**:
---   * `ctx.shared.corpus.word_counts` is the count table.
---   * `corpus.word_counts` is the sole count table. Consumers read `corpus.word_counts` directly.
---   * `ctx.shared.components` and `ctx.shared.component_body_index` are NOT created by this pass (projections only).
---   * No `.macs.h` recursive discovery (no `scan_dir`, no scan cache, no `_invalidate_scan_cache`).
---
--- **Conventions**: tabs (1/level), EmmyLua annotations, no regex,
--- Lua 5.3 compatible.

-- ════════════════════════════════════════════════════════════════════════════
-- Module-scope requires + package.path setup
-- ════════════════════════════════════════════════════════════════════════════

-- Bootstrap: load `scripts/duffle_paths.lua` (sets package.path + package.cpath).
-- Uses `debug.getinfo` to find this file's own directory, so it works both standalone and when require'd from the orchestrator.
-- duffle_paths.lua sets package.path then returns `require("duffle")` at the bottom, so the dofile value IS the duffle module.
local _bootstrap_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./" ---@type string
local duffle         = dofile(_bootstrap_dir .. "../duffle_paths.lua")            ---@type DuffleExport

-- ════════════════════════════════════════════════════════════════════════════
-- Type declarations
-- ════════════════════════════════════════════════════════════════════════════

--- @class WordCounts
--- @field [string] integer  -- bag: macro name -> word count

--- @class WordCountEval
--- @field count_token_words fun(token: string, wc: WordCounts): integer
--- @field run               fun(ctx: PassCtx): PassResult

-- SourceFile, PassCtx, PassResult: see ps1_meta.lua
-- DuffleExport: see duffle.lua (facade returned by duffle_paths.lua)

-- ════════════════════════════════════════════════════════════════════════════
-- Module exports
-- ════════════════════════════════════════════════════════════════════════════

local M = {} ---@type WordCountEval

-- ┌────────────────────────────────────────────────────────────────────┐
-- │ Shared utility: count_token_words                                  │
-- └────────────────────────────────────────────────────────────────────┘

--- Count words emitted by a single comma-separated token inside an atom body.
--- For most tokens (regular MIPS instructions) this returns 1.
--- For `mac_X(...)` calls, this returns the resolved word count from `wc` (recursively if needed). For `nop2` etc., returns wc[name].
--- For unknown macros, returns 1 and (optionally) warns.
--- @param token string     -- a single token from split_top_level_commas
--- @param wc    WordCounts -- the shared word-count table
--- @return integer
function M.count_token_words(token, wc)
	local s = duffle.trim(token) ---@type string
	if    s == "" then return 0 end
	local name, after = duffle.read_ident(s, 1) ---@type string|nil, integer
	if not name then return 1 end
	if wc[name] then return wc[name] end
	local paren_pos = duffle.skip_ws_and_cmt(s, after) ---@type integer
	if s:sub(paren_pos, paren_pos) == "(" then
		io.stderr:write("  warning: unknown macro '" .. name .. "', assuming 1 word\n")
	end
	return 1
end

-- ┌────────────────────────────────────────────────────────────────────┐
-- │ Pass entry: M.run(ctx) — "word-counts" pass                        │
-- └────────────────────────────────────────────────────────────────────┘

--- Load the authored `word_count.metadata.h` into `ctx.shared.corpus.word_counts`.
--- Generated `.macs.h` files are OUTPUT artifacts and are NOT scanned as inputs.
--- Current component counts are computed and inserted by `passes/components.lua`
--- after the components pass iterates `corpus.source_order` and writes each source-directory's `gen/macs.h` file.
---
--- Contract:
---   * `ctx.shared.corpus` MUST exist (canonical corpus ownership).
---   * `ctx.metadata_path` MUST be a readable file path to the authored `word_count.metadata.h`.
---   * The pass assigns exactly one table to `corpus.word_counts`.
---     Consumers read the corpus-owned table directly.
---     Consumers must read `corpus.word_counts` directly.
--- @param ctx PassCtx
--- @return PassResult
function M.run(ctx)
	-- 1. Canonical-corpus ownership gate.
	local corpus = ctx.shared and ctx.shared.corpus ---@type Corpus|nil
	if type(corpus) ~= "table" then
		error("word_count_eval.run requires ctx.shared.corpus (canonical corpus). The fixture must install the corpus before running this pass.", 0)
	end

	-- 2. metadata_path gate.
	if type(ctx.metadata_path) ~= "string" or ctx.metadata_path == "" then
		error("word_count_eval.run requires ctx.metadata_path (path to the authored word_count.metadata.h).", 0)
	end

	-- 3. Load authored metadata. Generated .macs.h files are NOT scanned
	--    (the pass computes their counts from the just-built bodies after disk emission; see passes/components.lua).
	local wc = duffle.load_word_counts(ctx.metadata_path) ---@type WordCounts

	-- 4. Assign the count table. ONE assignment, no copy. The assignment creates no secondary alias.
	corpus.word_counts = wc

	return { outputs = {}, errors = {}, warnings = {} }
end

return M
