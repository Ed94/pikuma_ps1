-- passes/static_analysis.lua
--
-- [FUTURE] Per-atom static-analysis checks. Stub for now; the upcoming
-- static_analysis_atoms_20260708 track will deliver the 5 (+1) checks.

--- @class M

local M = {}

--- @param ctx PassCtx
--- @return PassResult
function M.run(ctx)
	return { outputs = {}, errors = {}, warnings = {} }
end

return M