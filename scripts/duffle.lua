--- duffle.lua — facade over duffle_scan / duffle_isa / duffle_emit.
local scan = require("duffle_scan")
local isa  = require("duffle_isa")
local emit = require("duffle_emit")
local M    = {}

local function merge(src, label)
	for k, v in pairs(src) do
		if M[k] ~= nil and M[k] ~= v then
			error("duffle facade name collision on " .. tostring(k) .. " from " .. label, 0)
		end
		M[k] = v
	end
end

merge(scan, "duffle_scan")
merge(isa,  "duffle_isa")
merge(emit, "duffle_emit")

function M.corpus_view(ctx)
	local  corpus = ctx and ctx.shared and ctx.shared.corpus
	if not corpus then error("requires ctx.shared.corpus", 0) end
	return {
		register_alias_registry = corpus.register_alias_registry or {},
		type_name_registry      = corpus.type_name_registry      or {},
		atom_views              = corpus.atom_views              or {},
		atom_ctxs               = corpus.atom_ctxs               or {},
		atom_phases             = corpus.atom_phases             or {},
		binds_by_name           = corpus.binds_by_name           or {},
		atoms_by_name           = corpus.atoms_by_name           or {},
		atom_infos              = corpus.atom_infos              or {},
		components              = corpus.components              or {},
		component_atom_infos    = corpus.component_atom_infos    or {},
		component_body_index    = corpus.component_body_index    or {},
		tape_chains             = corpus.tape_chains             or {},
		source_order            = corpus.source_order            or {},
		collisions              = corpus.collisions              or {},
	}
end

function M.run_check_rules(rules, phase, item, pipe_ctx, findings)
	for _, rule in ipairs(rules) do
		local fn = rule[phase]
		if    fn then fn(item, pipe_ctx, findings) end
	end
end

return M
