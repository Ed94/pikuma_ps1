-- passes/annotation.lua
--
-- Validate atom annotation DSL usage in source files. Reads:
--   - atom_annot / atom_init / atom_setup / atom_commit / atom_bind
--     / atom_terminate / atom_label / atom_offset / TAPE_WORDS
--   - atom_resource / atom_region / atom_group / atom_cadence / atom_async
--   - Binds_* struct declarations
-- Writes:
--   - build/gen/<basename>.errors.h         (with #error directives on findings)
--   - build/gen/<basename>.annotations.txt  (human-readable summary)
-- Ported from scripts/tape_atom_annotation_pass.lua:78-545 + 1081-1407
-- (validation only — NOT rendering, which goes to passes/report.lua).
--
-- Coding standard: tabs (1/level), EmmyLua annotations, no regex.

--- @class M

local M = {}

--- @param ctx PassCtx
--- @return PassResult
function M.run(ctx)
	error("passes.annotation.run: implement by porting " ..
		"find_atom_names, find_atom_annotations, find_macro_word_annotations, " ..
		"find_atom_pragmas, find_binds_structs, validate from " ..
		"tape_atom_annotation_pass.lua:78-1407")
end

return M