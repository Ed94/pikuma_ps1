-- passes/report.lua
--
-- Render the per-project summary (build/gen/annotation_validation.txt)
-- + the per-source annotation reports (build/gen/<basename>.annotations.txt).
-- Aggregates errors + warnings from upstream annotation pass results.
--
-- The annotation pass stashes its per-source results in ctx.flags._annot_results
-- (set by passes/annotation.lua). This report pass renders them.
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
-- Per-source annotation report (ported from tape_atom_annotation_pass.lua:1411-1486)
-- ════════════════════════════════════════════════════════════════════════════

local function render_source_report(source_path, result)
	local lines = {}
	local function add(s) lines[#lines + 1] = s end

	add("========================================================")
	add("ANNOTATION PASS — " .. source_path)
	add("========================================================")
	add("")
	add(string.format("Atoms: %d   Annotations: %d   Pragmas: %d   Binds structs: %d   Macro decls: %d",
		#result.atoms, #result.annots,
		(result.pragmas and #result.pragmas or 0),
		#result.binds, #result.macros))
	add("")

	add("── Atoms ────────────────────────────────────────────────")
	for _, a in ipairs(result.atoms) do
		add(string.format("  MipsAtom_(%s)   line %d", a.name, a.line))
	end
	add("")

	add("── Annotations ──────────────────────────────────────────")
	for _, a in ipairs(result.annots) do
		if a.error then
			add(string.format("  ✗ line %d  %s  [ERROR: %s]", a.line, a.macro or "?", a.error))
		else
			local line = string.format("  %s  line %d  %s  phase=%s",
				a.kind == "work" and "●" or (a.kind == "bind" and "◆" or "○"),
				a.line, a.name, a.phase or a.kind)
			if a.binds then line = line .. "  binds=" .. a.binds end
			if #a.reads > 0 then line = line .. "  reads={" .. table.concat(a.reads, ",") .. "}" end
			if #a.writes > 0 then line = line .. "  writes={" .. table.concat(a.writes, ",") .. "}" end
			add(line)
		end
	end
	add("")

	add("── Binds_* structs ──────────────────────────────────────")
	for _, b in ipairs(result.binds) do
		add(string.format("  %s   line %d   %d bytes", b.name, b.line, b.bytes))
		for _, f in ipairs(b.fields) do
			add(string.format("    +%2d: %s", f.offset, f.name))
		end
	end
	add("")

	add("── Macro word-count declarations ─────────────────────────")
	for _, m in ipairs(result.macros) do
		add(string.format("  %s  line %d  words=%d", m.name, m.line, m.words))
	end
	add("")

	add("── Atom pragmas (resource / region / group / cadence / async) ─")
	if not result.pragmas or #result.pragmas == 0 then add("  (none)") end
	for _, p in ipairs(result.pragmas or {}) do
		local kvs = {}
		for k, v in pairs(p.attrs) do kvs[#kvs + 1] = k .. "=" .. v end
		table.sort(kvs)
		add(string.format("  ◇ line %d  %s  {%s}", p.line, p.name, table.concat(kvs, ", ")))
	end
	add("")

	add("── Errors ──────────────────────────────────────────────")
	if #result.errors == 0 then add("  (none)") end
	for _, e in ipairs(result.errors) do
		add(string.format("  ✗ line %d  %s", e.line, e.msg))
	end
	add("")

	add("── Warnings ────────────────────────────────────────────")
	if #result.warnings == 0 then add("  (none)") end
	for _, w in ipairs(result.warnings) do
		add(string.format("  ⚠ line %d  %s", w.line, w.msg))
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
				add(string.format("  %s : %d error(s)", r.source, #r.errors))
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

	-- The annotation pass stashes per-source results in ctx.flags._annot_results.
	-- Render each as build/gen/<basename>.annotations.txt and aggregate into
	-- build/gen/annotation_validation.txt.
	local annot_results = (ctx.flags and ctx.flags._annot_results) or {}

	-- Render per-source reports.
	for _, entry in ipairs(annot_results) do
		local src = entry.source
		local result = entry.result
		local out_path = ctx.out_root .. "/" .. src.basename .. ".annotations.txt"
		if not ctx.dry_run then
			ensure_dir(ctx.out_root)
			write_file(out_path, render_source_report(src.path, result))
		end
		table.insert(outputs, { annotations_txt = out_path })
	end

	-- Render project summary.
	if not ctx.dry_run then
		-- The project report references each source by its absolute path.
		-- Augment the entries with a .source field for the per-source error counts.
		local all_results = {}
		for _, entry in ipairs(annot_results) do
			entry.result.source = entry.source.path
			table.insert(all_results, entry.result)
		end
		ensure_dir(ctx.out_root)
		local summary_path = ctx.out_root .. "/annotation_validation.txt"
		write_file(summary_path, render_project_report(all_results))
		table.insert(outputs, { summary_txt = summary_path })
	end

	return { outputs = outputs, errors = errors, warnings = warnings }
end

return M