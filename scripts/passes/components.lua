-- passes/components.lua
--
-- Generate <module>/gen/<basename>.macs.h from MipsAtomComp_ declarations
-- in source files. Ported from tape_atom_annotation_pass.lua:773-1079
-- (find_component_atoms, preceding_comment_block, extract_arg_names,
-- convert_line_comments_to_block, compute_component_word_count,
-- emit_component_macros_h).
--
-- Coding standard: tabs (1/level), EmmyLua annotations, no regex.

--- @class M

local M = {}

--- @param ctx PassCtx
--- @return PassResult
function M.run(ctx)
	-- PORT NOTE: copy find_component_atoms, find_function_args_for,
	-- preceding_comment_block, extract_arg_names, find_component_atoms
	-- (body parser), convert_line_comments_to_block, emit_component_macros_h
	-- from tape_atom_annotation_pass.lua lines 604-1079.
	-- Adaptations:
	--   - Replace word_counts usage with word_count_eval.count_body_words
	--   - Pass ctx.out_root / ctx.dry_run / ctx.verbose through
	--   - Return { outputs, errors, warnings } shape
	--
	-- For each src in ctx.sources:
	--   1. find_component_atoms(src.text) -> [{name, body, args, line, comment}]
	--   2. for each component, compute its word count (recursively via
	--      word_count_eval.count_body_words)
	--   3. emit "#define mac_X(args) body" + "WORD_COUNT(mac_X, N)" to
	--      <src.dir>/gen/<src.basename>.macs.h
	--   4. Extend ctx.shared.word_counts with the computed counts
	--   5. Add {macs_h = path} to result.outputs
	error("passes.components.run: implement by porting from " ..
		"tape_atom_annotation_pass.lua:773-1079")
end

return M