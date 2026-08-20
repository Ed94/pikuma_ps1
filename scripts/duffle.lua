--- duffle.lua — facade over duffle_scan / duffle_isa / duffle_emit.

--- @class DuffleExport
--- bag: open module-export keys from duffle_scan / duffle_isa / duffle_emit

--- @type DuffleExport
local scan = require("duffle_scan")
--- @type DuffleExport
local isa  = require("duffle_isa")
--- @type DuffleExport
local emit = require("duffle_emit")
--- @type DuffleExport
local M    = {}

--- @alias Path string
--- @alias LineNum integer
--- @alias ByteOff integer
--- @alias MacroName string
--- @alias AtomName string
--- @alias Severity string

--- @class SourceFile
--- @field path Path
--- @field text string
--- @field dir string
--- @field basename string
--- @field scan SourceScan|nil

--- @class CorpusView
--- @field register_alias_registry table<string, AliasEntry>
--- @field type_name_registry      table<string, TypeNameEntry>
--- @field atom_views              table<AtomName, AtomViewEntry>
--- @field atom_ctxs               table<AtomName, AtomCtxEntry>
--- @field atom_phases             table<string, AtomPhaseGroup>
--- @field binds_by_name           table<string, BindsEntry>
--- @field atoms_by_name           table<AtomName, AtomEntry>
--- @field atom_infos              AtomInfoEntry[]
--- @field components              table<string, ComponentDef>
--- @field component_atom_infos    AtomInfoEntry[]|nil
--- @field component_body_index    table<string, ComponentBodyEntry>
--- @field tape_chains             table<string, TapeChain>|nil
--- @field source_order            SourceFile[]
--- @field collisions              CorpusCollision[]

--- @param src DuffleExport
--- @param label string
--- @return nil
local function merge(src, label)
	--- @type string, any
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

--- @param ctx PassCtx
--- @return CorpusView
function M.corpus_view(ctx)
	--- @type Corpus
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

--- @param rules CheckRule[]
--- @param phase string
--- @param item AtomEntry|SourceFile
--- @param pipe_ctx PipeCtx
--- @param findings CheckFinding[]
--- @return nil
function M.run_check_rules(rules, phase, item, pipe_ctx, findings)
	--- @type integer, CheckRule
	for _, rule in ipairs(rules) do
		--- @type (fun(item: AtomEntry|SourceFile, pipe_ctx: PipeCtx, findings: CheckFinding[]): nil)|nil
		local fn = rule[phase]
		if    fn then fn(item, pipe_ctx, findings) end
	end
end

return M
