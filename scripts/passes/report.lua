-- passes/report.lua
--
-- Render the per-project summary (build/gen/annotation_validation.txt).
-- Aggregates errors + warnings from upstream passes.
--
-- Coding standard: tabs (1/level), EmmyLua annotations, no regex.

--- @class M

local M = {}

--- @param ctx PassCtx
--- @return PassResult
function M.run(ctx)
	-- PORT NOTE: copy render_source_report + render_project_report
	-- from tape_atom_annotation_pass.lua lines 1411-1528.
	-- Adaptations:
	--   - Read errors/warnings from ctx.upstream[pass_name].outputs/errors
	--     (orchestrator-collected)
	--   - Write to <ctx.out_root>/annotation_validation.txt (was
	--     build/gen/annotation_validation.txt — same path)
	--   - Return { outputs = {{summary_txt = path}}, errors = {}, warnings = {} }
	--
	-- The summary renders a per-atom table + error count + warning count,
	-- matching the pre-rework format. See the spec's "Report" pass
	-- description for the expected output.
	error("passes.report.run: implement by porting render_source_report + " ..
		"render_project_report from tape_atom_annotation_pass.lua:1411-1528")
end

return M