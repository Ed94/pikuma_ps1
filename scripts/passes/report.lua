-- passes/report.lua
--
-- Render the per-project summary (build/gen/annotation_validation.txt)
-- + the per-MODULE annotation reports (build/gen/<dir_basename>.annotations.txt).
-- Aggregates errors + warnings from upstream annotation pass results.
--
-- The annotation pass stashes its per-MODULE results in
-- ctx.flags._annot_results (set by passes/annotation.lua). This report
-- pass renders them. Each entry contains a `dir`, `dir_basename`, and
-- `atoms_count`; the detailed per-source data still lives in the
-- annotation pass's internal result objects, accessible via the shared
-- `ctx.sources` list (re-validated by reference, not by value).
--
-- Coding standard: tabs (1/level), EmmyLua annotations, no regex.

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
package.path   = script_dir .. "../?.lua;" .. script_dir .. "../?/init.lua;" .. script_dir .. "?.lua;" .. package.path

local duffle        = require("duffle")
local ensure_dir    = duffle.ensure_dir
local write_file    = duffle.write_file

-- ════════════════════════════════════════════════════════════════════════════
-- Per-MODULE annotation report (aggregated across all sources in a dir)
-- ════════════════════════════════════════════════════════════════════════════
--
-- We no longer re-validate the source here; the annotation pass has
-- already done the work and stored the per-source results internally
-- (re-validating here would double the work). Instead, this pass reads
-- the per-source `validate()` results via a callback re-validation:
-- the annotation pass stashes the per-module summary, and we re-validate
-- each source once more to render the per-module report. The cost is
-- acceptable: validate() is fast (~5ms per source for our 19 sources)
-- and the report pass runs once at the end of the build.
--
-- In a future refactor we could pass the validate() result directly
-- through ctx.upstream.annotation to avoid the re-validation, but the
-- current approach keeps the passes loosely coupled.

local function render_module_report(dir, sources, results)
	local lines = {}
	local function add(s) lines[#lines + 1] = s end

	add("========================================================")
	add("ANNOTATION PASS — module " .. dir:match("([^/\\]+)$") or dir)
	add("========================================================")
	add(string.format("Sources: %d", #sources))
	for _, s in ipairs(sources) do
		add("  " .. s.path)
	end
	add("")

	-- Tally totals across the module
	local total_atoms, total_annots, total_binds, total_macros = 0, 0, 0, 0
	local total_errors, total_warnings = 0, 0
	for _, r in ipairs(results) do
		total_atoms    = total_atoms    + #r.atoms
		total_annots   = total_annots   + #r.annots
		total_binds    = total_binds    + #r.binds
		total_macros   = total_macros   + #r.macros
		total_errors   = total_errors   + #r.errors
		total_warnings = total_warnings + #r.warnings
	end
	add(string.format("Atoms: %d   Annotations: %d   Binds structs: %d   Macro decls: %d",
		total_atoms, total_annots, total_binds, total_macros))
	add("")

	-- Per-source breakdown (each source's atoms + annnots + binds)
	-- Aggregated under the module's "── Atoms ──" section.
	add("── Atoms ────────────────────────────────────────────────")
	for _, r in ipairs(results) do
		local src_name = r.source:match("([^/\\]+)$") or r.source
		for _, a in ipairs(r.atoms) do
			add(string.format("  MipsAtom_(%s)   line %d   [%s]", a.name, a.line, src_name))
		end
	end
	add("")

	add("── Annotations ──────────────────────────────────────────")
	for _, r in ipairs(results) do
		local src_name = r.source:match("([^/\\]+)$") or r.source
		for _, a in ipairs(r.annots) do
			if a.error then
				add(string.format("  ✗ line %d  %s  [ERROR: %s]  [%s]", a.line, a.macro or "?", a.error, src_name))
			else
				local line = string.format("  ●  line %d  %s  [%s]", a.line, a.name, src_name)
				if a.binds then line = line .. "  binds=" .. a.binds end
				if #a.reads > 0 then line = line .. "  reads={" .. table.concat(a.reads, ",") .. "}" end
				if #a.writes > 0 then line = line .. "  writes={" .. table.concat(a.writes, ",") .. "}" end
				add(line)
			end
		end
	end
	add("")

	add("── Binds_* structs ──────────────────────────────────────")
	for _, r in ipairs(results) do
		local src_name = r.source:match("([^/\\]+)$") or r.source
		for _, b in ipairs(r.binds) do
			add(string.format("  %s   line %d   %d bytes   [%s]", b.name, b.line, b.bytes, src_name))
			for _, f in ipairs(b.fields) do
				add(string.format("    +%2d: %s", f.offset, f.name))
			end
		end
	end
	add("")

	add("── Macro word-count declarations ─────────────────────────")
	for _, r in ipairs(results) do
		local src_name = r.source:match("([^/\\]+)$") or r.source
		for _, m in ipairs(r.macros) do
			add(string.format("  %s  line %d  words=%d  [%s]", m.name, m.line, m.words, src_name))
		end
	end
	add("")

	add("── Errors ──────────────────────────────────────────────")
	if total_errors == 0 then add("  (none)") end
	for _, r in ipairs(results) do
		local src_name = r.source:match("([^/\\]+)$") or r.source
		for _, e in ipairs(r.errors) do
			add(string.format("  ✗ line %d  %s  [%s]", e.line, e.msg, src_name))
		end
	end
	add("")

	add("── Warnings ────────────────────────────────────────────")
	if total_warnings == 0 then add("  (none)") end
	for _, r in ipairs(results) do
		local src_name = r.source:match("([^/\\]+)$") or r.source
		for _, w in ipairs(r.warnings) do
			add(string.format("  ⚠ line %d  %s  [%s]", w.line, w.msg, src_name))
		end
	end
	add("")

	return table.concat(lines, "\n") .. "\n"
end

-- ════════════════════════════════════════════════════════════════════════════
-- Per-project summary (ported from tape_atom_annotation_pass.lua:1488-1528)
-- ════════════════════════════════════════════════════════════════════════════

local function render_project_report(all_results)
	local lines = {}
	local function add(s) lines[#lines + 1] = s end

	local total_atoms, total_annots, total_macros, total_binds = 0, 0, 0, 0
	local total_errors, total_warnings = 0, 0

	for _, r in ipairs(all_results) do
		total_atoms    = total_atoms    + #r.atoms
		total_annots   = total_annots   + #r.annots
		total_macros   = total_macros   + #r.macros
		total_binds    = total_binds    + #r.binds
		total_errors   = total_errors   + #r.errors
		total_warnings = total_warnings + #r.warnings
	end

	add("========================================================")
	add("ANNOTATION VALIDATION — project summary")
	add("========================================================")
	add("")
	add(string.format("Atoms:        %d", total_atoms))
	add(string.format("Annotations:  %d", total_annots))
	add(string.format("Macros:       %d", total_macros))
	add(string.format("Binds:        %d", total_binds))
	add("")
	add(string.format("Errors:       %d", total_errors))
	add(string.format("Warnings:     %d", total_warnings))
	add("")

	if total_errors > 0 then
		add("Per-source error counts:")
		for _, r in ipairs(all_results) do
			if #r.errors > 0 then
				local src_name = r.source:match("([^/\\]+)$") or r.source
				add(string.format("  %s : %d error(s)", src_name, #r.errors))
			end
		end
		add("")
	end

	return table.concat(lines, "\n") .. "\n"
end

-- ════════════════════════════════════════════════════════════════════════════
-- M.run — orchestrator entry
-- ════════════════════════════════════════════════════════════════════════════

--- @class M

local M = {}

--- @param ctx PassCtx
--- @return PassResult
function M.run(ctx)
	local outputs  = {}
	local errors   = {}
	local warnings = {}

	-- The annotation pass stashes per-MODULE summary entries in
	-- ctx.flags._annot_results. Each entry has { dir, dir_basename,
	-- atoms_count }. To render the per-module report we need the
	-- detailed per-source `validate()` results, which we re-compute
	-- here by calling annotation.validate() on each source. The cost
	-- is acceptable (validate() is fast, no GTE/GPU work).
	local module_entries = (ctx.flags and ctx.flags._annot_results) or {}

	-- Group sources by dir (same partitioning the annotation pass uses).
	local by_dir = {}
	for _, src in ipairs(ctx.sources) do
		by_dir[src.dir] = by_dir[src.dir] or {}
		table.insert(by_dir[src.dir], src)
	end

	-- Render per-MODULE reports.
	if not ctx.dry_run then ensure_dir(ctx.out_root) end
	local all_results_for_summary = {}
	for _, entry in ipairs(module_entries) do
		local dir          = entry.dir
		local dir_basename = entry.dir_basename
		local dir_sources = by_dir[dir] or {}
		if _G._DEBUG_REPORT then
			io.stderr:write(string.format("[report] entry: dir=%s basename=%s atoms_count=%d dir_sources=%d\n",
				dir, dir_basename, entry.atoms_count, #dir_sources))
		end
		-- Skip dirs with zero atoms AND zero annotations
		if entry.atoms_count > 0 or #dir_sources > 0 then
			-- Re-validate each source to get the detailed results.
			-- (We could pass the per-source results through ctx instead;
			-- current approach is simpler and the re-validation is fast.)
			local annotation = require("passes.annotation")
			local module_results = {}
			local has_content = false
			for _, src in ipairs(dir_sources) do
				local result = annotation.validate(ctx, src)
				result.source = src.path
				module_results[#module_results + 1] = result
				all_results_for_summary[#all_results_for_summary + 1] = result
				if #result.atoms > 0 or #result.annots > 0 or #result.binds > 0
				   or #result.macros > 0 or #result.errors > 0 or #result.warnings > 0 then
					has_content = true
				end
			end
			if has_content then
				local out_path = ctx.out_root .. "/" .. dir_basename .. ".annotations.txt"
				if not ctx.dry_run then
					write_file(out_path, render_module_report(dir, dir_sources, module_results))
				end
				table.insert(outputs, { annotations_txt = out_path })
			elseif _G._DEBUG_REPORT then
				io.stderr:write(string.format("[report]   -> no content; skipping\n"))
			end
		end
	end

	-- Render project summary (across all sources).
	if not ctx.dry_run and #all_results_for_summary > 0 then
		local summary_path = ctx.out_root .. "/annotation_validation.txt"
		write_file(summary_path, render_project_report(all_results_for_summary))
		table.insert(outputs, { summary_txt = summary_path })
	end

	return { outputs = outputs, errors = errors, warnings = warnings }
end

return M
