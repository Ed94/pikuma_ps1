-- passes/offsets.lua
--
-- Generate <module>/gen/<basename>.offsets.h with branch offset
-- immediates for every atom_offset(F, T) reference in atom bodies.
-- Ported from scripts/tape_atom.offset_gen.meta.lua:148-389.
--
-- The branch offset regression we just fixed in commit 98e27c2 must
-- NOT return. The fix was in duffle.lua's split_top_level_commas +
-- tape_atom_annotation_pass.lua's compute_component_word_count.
-- word_count_eval.count_token_words (Task 1) preserves the fix.
--
-- Coding standard: tabs (1/level), EmmyLua annotations, no regex.

--- @class M

local M = {}

--- @param ctx PassCtx
--- @return PassResult
function M.run(ctx)
	-- PORT NOTE: copy find_atoms, scan_atom_body, compute_offsets,
	-- generate_header, process_source from tape_atom.offset_gen.meta.lua
	-- lines 245-389.
	-- Adaptations:
	--   - Replace local word_count_of_token with word_count_eval.count_token_words
	--   - Take (ctx, src) instead of (source_path, word_counts) — read
	--     word counts from ctx.shared.word_counts
	--   - Return { outputs, errors, warnings } shape
	--   - Convert indentation from 8-space to tabs
	--
	-- For each src in ctx.sources:
	--   1. Find MipsAtom_ declarations in src.text (find_atoms)
	--   2. For each atom body, scan_atom_body to count words + find
	--      atom_label/atom_offset markers
	--   3. compute_offsets (target_word - branch_word - 1 per pair)
	--   4. generate_header emits "#define atom_offset__F__T  (N)" +
	--      "enum { atom_offset__F__T = N, ... }" to <src.dir>/gen/<src.basename>.offsets.h
	--   5. Add {offsets_h = path} to result.outputs
	error("passes.offsets.run: implement by porting from " ..
		"tape_atom.offset_gen.meta.lua:245-389")
end

return M