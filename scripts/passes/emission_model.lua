--- passes/emission_model.lua: Per-atom emission projection.
---
--- The `emission-model` pass owns `atom.paths` (the canonical per-atom mutable surface)
--- for every atom-with-body and every raw atom-with-body declared in `ctx.shared.corpus.source_order`.
--- For each such atom, the pass invokes `duffle.project_emission(body_text, component_index, word_counts)`
--- and stores the ordered `items` stream plus the dense `word_events` / `markers` / `invocations` views on `atom.paths`.
---
--- Public boundary:
---   * `M.run(ctx)` is the only entry point.
---   * The pass returns `{outputs = {}, errors = ..., warnings = ...}`.
---     Pass kind = `validation` → `PASS_KIND_STOP_ON_ERROR.validation` keeps build-stopping semantics (no policy change in this task).
---
--- Source-order discipline:
---   * `corpus.source_order` is the canonical ordering of source records.
---   * For each source, the pass iterates `src.scan.atoms` and `src.scan.raw_atoms` IN SOURCE ORDER, preserving declaration order.
---
--- Per-atom projection fields on `atom.paths`:
---   `tokens`, `line_in_body`, `items`, `word_events`, `markers`, `invocations`, `errors`, `warnings`.
---   The dense views are built from `items` only; the pass never re-walks source text or tokens.
---
--- Component expansion and construction validation:
---   * known `mac_X(...)` calls recursively expand component bodies;
---   * invocation records retain monotonic IDs, parent IDs, immediate call text, and the immutable outermost root call text;
---   * component cycles retain balanced invocation boundaries and emit a `cycle` construction error without recursing indefinitely;
---   * declared-vs-measured component word counts emit `count_mismatch` construction errors; opaque uncounted macros emit warnings.
---
--- The pass does NOT consult `_code_macros` / `_code_macro_bodies`. Those private tables are owned by `passes.scan_source` and stripped before this pass runs.

local M = {}

-- ─────────────────────────────────────────────────────────────────────────
-- Bootstrap: load `duffle_paths.lua` via debug.getinfo so the module works standalone (run as `luajit passes/emission_model.lua`) and when require'd from the orchestrator.
-- ─────────────────────────────────────────────────────────────────────────
local _bootstrap_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local duffle         = dofile(_bootstrap_dir .. "../duffle_paths.lua")

-- ─────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────

-- Convert the recursive walk's body-relative line numbers into physical source lines once.
-- Consumers read these canonical fields rather than rebuilding line state or tokenizing source again.
local function stamp_root_provenance(projection, atom_record, src, corpus)
	local root_line_of   = src.scan and src.scan.line_of
	local root_body_line = root_line_of and root_line_of((atom_record.body_off or 1) - 1)
		or atom_record.line or 0
	local component_index = corpus.component_body_index or {}
	local word_items = {}

	for _, item in ipairs(projection.items) do
		if item.kind == "word" then word_items[#word_items + 1] = item end
	end

	local function body_line_for(event, item)
		local body_line_of = root_line_of
		local body_off     = atom_record.body_off or 0
		local ids          = event.invocation_ids or {}
		local inner_id     = ids[#ids]
		local inner_inv    = inner_id and projection.invocations[inner_id]
		if inner_inv then
			local component = component_index[inner_inv.component_name]
			if    component and component.line_of then
				-- Component-body walkers already receive the declaration source's full line index, so their item.line is physical.
				return item.line or 0
			end
		end
		local first_line = body_line_of and body_line_of(math.max(1, body_off - 1)) or root_body_line
		return (first_line or 0) + (item.line or 1) - 1
	end

	-- Stamp root-source path onto invocation records whose `call_path` was left empty by the walker.
	-- The walker passes `body_entry.source` to `emit_invoke_begin` as the call_path argument; for the root body_entry created by `M.project_emission` that source is ""
	-- (the caller passes only the body text).
	-- After this stamp every invocation record has a physical call_path that matches what `passes/atoms_source_map.lua` matches the in-memory provenance projection.
	local root_path = src.path or ""
	for _, inv in ipairs(projection.invocations) do
		if inv.call_path == nil or inv.call_path == "" then
			inv.call_path = root_path
		end
	end

	for index, we in ipairs(projection.word_events) do
		local item      = word_items[index] or {}
		local body_line = body_line_for(we, item)
		item.line    = body_line
		we.body_line = body_line

		local call_line = body_line
		local outer_id  = we.outermost_invocation_id or 0
		local outer_inv = projection.invocations[outer_id]
		if outer_inv then call_line = (root_body_line or 0) + (outer_inv.call_line or 1) - 1 end
		we.call_line = call_line

		if we.def_path  == nil or we.def_path  == "" then we.def_path  = src.path         or "" end
		if we.def_line  == nil or we.def_line  == 0  then we.def_line  = atom_record.line or 0  end
		if we.call_path == nil or we.call_path == "" then we.call_path = src.path         or "" end
	end
end

-- Project one atom record into `atom.paths`.
-- Mutates the atom record in-place and returns the projection (for pass-level error/warning accumulation).
local function project_atom(atom_record, src, corpus)
	local body  = atom_record.body or ""
	local wc    = corpus.word_counts or {}
	local cbi   = corpus.component_body_index or {}
	local proj  = duffle.project_emission(body, cbi, wc)
	local paths = {
		tokens       = atom_record.body_tokens or {},
		line_in_body = duffle.build_body_line_index(body),
		items        = proj.items,
		word_events  = proj.word_events,
		markers      = proj.markers,
		invocations  = proj.invocations,
		errors       = proj.errors,
		warnings     = proj.warnings,
	}
	stamp_root_provenance(proj, atom_record, src, corpus)
	atom_record.paths = paths
	return proj
end

-- ─────────────────────────────────────────────────────────────────────────
-- Run the emission-model pass.
-- ─────────────────────────────────────────────────────────────────────────

--- @param ctx PassCtx  -- { shared = { corpus = ... }, out_root, ... }
--- @return PassResult
function M.run(ctx)
	local outputs  = {}
	local errors   = {}
	local warnings = {}

	local corpus = ctx and ctx.shared and ctx.shared.corpus
	if type(corpus)              ~= "table" then error("emission_model: ctx.shared.corpus is required (canonical projection)", 0) end
	if type(corpus.source_order) ~= "table" then error("emission_model: ctx.shared.corpus.source_order is required", 0) end

	-- Walk every source in canonical source order; for each source, iterate atoms.
	-- Atom declarations (`kind == "atom"` / `"raw_atom"`) AND component declarations
	-- (`comp_bare` / `comp_proc`) each receive the canonical `atom.paths` projection.
	-- Components are macros inlined into atom bodies; focused tests and isolated
	-- component analyses read them from `atom.paths` on the component record.
	-- The per-atom emission projection is produced by `duffle.project_emission` (this pass).
	-- Test-only fixtures may consume `atom.paths.word_events` directly from the emission-model pass output.
	for _, src in ipairs(corpus.source_order) do
		local scan = src.scan or {}
		for _, atom in ipairs(scan.atoms or {}) do
			if atom and atom.body and (
				atom.kind == "atom"      or
				atom.kind == "raw_atom"  or
				atom.kind == "comp_bare" or
				atom.kind == "comp_proc"
			) then
				local proj = project_atom(atom, src, corpus)
				for _, e in ipairs(proj.errors) do
					-- Preserve `kind` (cycle / count_mismatch / unbalanced) so readers can dispatch on the diagnostic class without re-parsing the message string.
					errors[#errors + 1] = {
						kind   = e.kind,
						line   = e.line,
						msg    = e.msg,
						source = e.source or src.path,
					}
				end
				for _, w in ipairs(proj.warnings) do
					warnings[#warnings + 1] = {
						kind = w.kind,
						line = w.line,
						msg  = w.msg,
					}
				end
			end
		end
		for _, atom in ipairs(scan.raw_atoms or {}) do
			if atom and atom.body then
				local proj = project_atom(atom, src, corpus)
				for _, e in ipairs(proj.errors) do
					errors[#errors + 1] = {
						kind   = e.kind,
						line   = e.line,
						msg    = e.msg,
						source = e.source or src.path,
					}
				end
				for _, w in ipairs(proj.warnings) do
					warnings[#warnings + 1] = {
						kind = w.kind,
						line = w.line,
						msg  = w.msg,
					}
				end
			end
		end
	end

	return {
		outputs  = outputs,
		errors   = errors,
		warnings = warnings,
	}
end

return M
