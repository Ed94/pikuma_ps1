--- passes/report.lua — Per-MODULE annotation report renderer +
--- project-wide summary writer.
---
--- Two output files per build:
---   - `build/gen/<dir_basename>.annotations.txt` — one per source-directory containing atoms; aggregates across all sources in the directory.
---   - `build/gen/annotation_validation.txt` — the project summary.
---
--- The annotation pass stashes per-MODULE summary entries in `ctx.flags._annot_results` (set by `passes/annotation.lua`). 
--- This pass re-validates each source via `annotation.validate()` to get the detailed per-source results needed for the report. 
---
--- **Conventions**: tabs (1/level), EmmyLua annotations, no regex,
--- Lua 5.3 compatible.

-- ════════════════════════════════════════════════════════════════════════════
-- Module-scope requires + package.path setup
-- ════════════════════════════════════════════════════════════════════════════

-- Resolve `arg[0]` to an absolute-ish script directory so that `require("duffle")` resolves against `scripts/` regardless of CWD.
-- Note: this boilerplate is duplicated in 6 other entry scripts; a Phase-6 extraction target (`duffle.setup_package_path()`).
-- Bootstrap: see `ps1_meta.lua` for the rationale.
-- Bootstrap: load `scripts/duffle_paths.lua` (sets package.path + package.cpath).
-- Uses `debug.getinfo` to find this file's own directory, so it works
-- both standalone and when require'd from the orchestrator.
-- Bootstrap: load `duffle_paths.lua` via `debug.getinfo(1, "S").source` (works both standalone + when require'd).
-- duffle_paths.lua sets package.path then returns `require("duffle")` at the bottom, so the dofile value IS the duffle module.
local _bootstrap_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local duffle        = dofile(_bootstrap_dir .. "../duffle_paths.lua")

-- ════════════════════════════════════════════════════════════════════════════
-- Constants
-- ════════════════════════════════════════════════════════════════════════════

-- Section separators used in the rendered text reports.
-- The thin rules are hand-tuned to align with the per-section content width; do not change without also checking the section renderers below.
local RULE_THICK = "========================================================"
local SECTION_HEADER_ATOMS     = "── Atoms ────────────────────────────────────────────────"
local SECTION_HEADER_ANNOTS    = "── Annotations ──────────────────────────────────────────"
local SECTION_HEADER_BINDS     = "── Binds_* structs ──────────────────────────────────────"
local SECTION_HEADER_MACROS    = "── Macro word-count declarations ─────────────────────────"
local SECTION_HEADER_ERRORS    = "── Errors ──────────────────────────────────────────────"
local SECTION_HEADER_WARNINGS  = "── Warnings ────────────────────────────────────────────"

-- Lua pattern that captures the basename (last path segment) of a
-- forward- or back-slash separated path.
local BASENAME_PATTERN = "([^/\\]+)$"

-- Debug flag name — set to truthy in `_G` to enable verbose logging.
local DEBUG_FLAG = "_DEBUG_REPORT"

-- Pass identifier for log messages.
local PASS_NAME = "report"

-- ════════════════════════════════════════════════════════════════════════════
-- Type declarations
-- ════════════════════════════════════════════════════════════════════════════

--- @class SourceFile
--- @field path     string  -- absolute path to the source file
--- @field text     string  -- the full source text
--- @field dir      string  -- the directory containing the source
--- @field basename string  -- filename without extension

--- @class PassCtx
--- @field sources            SourceFile[]            -- all source files in the build
--- @field metadata_path      string                  -- path to word_count.metadata.h
--- @field shared             table                   -- cross-pass shared state
--- @field out_root           string                  -- output root (e.g. "build/gen")
--- @field project_root       string                  -- project root (e.g. "code/")
--- @field upstream           table<string, table>    -- per-pass upstream outputs
--- @field flags              table                   -- CLI flags + per-pass stash
--- @field flags._annot_results ModuleEntry[]         -- stashed by annotation pass
--- @field dry_run            boolean                 -- if true, compute but don't write
--- @field verbose            boolean                 -- if true, log diagnostic info

--- @class PassResult
--- @field outputs  table[]  -- {kind=, path=} entries describing emit files
--- @field errors   table[]  -- {line=, msg=} entries; build-stops
--- @field warnings table[]  -- {line=, msg=} entries; build-succeeds

-- Shapes produced by `passes/annotation.lua`'s `M.validate()`.

--- @class AtomEntry
--- @field name string   -- atom name (e.g. "cube_g4_face")
--- @field line integer  -- source line of the atom declaration

--- @class AnnotEntry
--- @field line    integer  -- source line
--- @field macro   string   -- the macro name (e.g. "atom_reads")
--- @field name    string   -- the atom name (if a `name(...)` was given)
--- @field kind    string   -- "atom_info" | "atom_bind" | ...
--- @field binds   string|nil  -- Binds_X name if any
--- @field reads   string[]    -- R_* names (read targets)
--- @field writes  string[]    -- R_* names (write targets)
--- @field error   string|nil  -- error message if annotation was malformed

--- @class BindsField
--- @field name   string   -- field name
--- @field offset integer  -- byte offset within the Binds_X struct

--- @class BindsStruct
--- @field name   string         -- struct name (e.g. "Binds_Floor")
--- @field line   integer        -- source line of the typedef
--- @field bytes  integer        -- total byte size
--- @field fields BindsField[]   -- the field list

--- @class MacroEntry
--- @field name  string   -- macro name (e.g. "WORD_COUNT(my_macro, 4)")
--- @field line  integer  -- source line
--- @field words integer  -- declared word count

--- @class Finding
--- @field line integer  -- source line
--- @field msg  string   -- finding message

--- @class AnnotationResult
--- @field source   string         -- set by this pass; original source path
--- @field atoms    AtomEntry[]    -- atom declarations in this source
--- @field annots   AnnotEntry[]   -- annotation entries
--- @field macros   MacroEntry[]   -- macro word-count declarations
--- @field binds    BindsStruct[]  -- Binds_* struct declarations
--- @field errors   Finding[]      -- errors from validation
--- @field warnings Finding[]      -- warnings from validation
--- @field info     table          -- info summary (not rendered here)

--- @class ModuleEntry
--- @field dir          string   -- absolute directory path
--- @field dir_basename string   -- basename (e.g. "duffle", "gte_hello")
--- @field atoms_count  integer  -- pre-counted atoms for filtering

--- @class ModuleReport
--- @field dir       string             -- module directory
--- @field sources   SourceFile[]       -- sources in this module
--- @field results   AnnotationResult[] -- per-source validate() results

--- @class ProjectReport
--- @field results AnnotationResult[]  -- all per-source results

-- ════════════════════════════════════════════════════════════════════════════
-- Per-MODULE annotation report (aggregated across all sources in a dir)
-- ════════════════════════════════════════════════════════════════════════════

-- Extract the basename (last path segment) of a forward- or back-slash separated path. Returns the input unchanged if no separator is found.
-- @param path string
-- @return string
local function source_basename(path)
	return path:match(BASENAME_PATTERN) or path
end

-- (internal) Format a single annotation entry as one rendered line.
-- @param a AnnotEntry
-- @param src_name string
-- @return string
local function format_annot_line(a, src_name)
	if a.error then
		return string.format("  ✗ line %d  %s  [ERROR: %s]  [%s]", a.line, a.macro or "?", a.error, src_name)
	end
	local line = string.format("  ●  line %d  %s  [%s]", a.line, a.name, src_name)
	if a.binds               then line = line .. "  binds=" .. a.binds end
	if #a.reads > 0          then line = line .. "  reads={" .. table.concat(a.reads, ",") .. "}" end
	if #a.writes > 0         then line = line .. "  writes={" .. table.concat(a.writes, ",") .. "}" end
	return line
end

-- (internal) Tally totals across all results in a module.
-- @param results AnnotationResult[]
-- @return integer, integer, integer, integer, integer, integer
local function tally_module_totals(results)
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
	return total_atoms, total_annots, total_binds, total_macros, total_errors, total_warnings
end

-- (internal) Section renderer: per-source atom declarations.
local function render_module_atoms_section(add, results)
	add(SECTION_HEADER_ATOMS)
	for _, r in ipairs(results) do
		local src_name = source_basename(r.source)
		for _, a in ipairs(r.atoms) do
			add(string.format("  MipsAtom_(%s)   line %d   [%s]", a.name, a.line, src_name))
		end
	end
	add("")
end

-- (internal) Section renderer: per-source annotation entries.
local function render_module_annots_section(add, results)
	add(SECTION_HEADER_ANNOTS)
	for _, r in ipairs(results) do
		local src_name = source_basename(r.source)
		for _, a in ipairs(r.annots) do
			add(format_annot_line(a, src_name))
		end
	end
	add("")
end

-- (internal) Section renderer: per-source Binds_* struct declarations.
local function render_module_binds_section(add, results)
	add(SECTION_HEADER_BINDS)
	for _, r in ipairs(results) do
		local src_name = source_basename(r.source)
		for _, b in ipairs(r.binds) do
			add(string.format("  %s   line %d   %d bytes   [%s]", b.name, b.line, b.bytes, src_name))
			for _, f in ipairs(b.fields) do
				add(string.format("    +%2d: %s", f.offset, f.name))
			end
		end
	end
	add("")
end

-- (internal) Section renderer: per-source macro word-count declarations.
local function render_module_macros_section(add, results)
	add(SECTION_HEADER_MACROS)
	for _, r in ipairs(results) do
		local src_name = source_basename(r.source)
		for _, m in ipairs(r.macros) do
			add(string.format("  %s  line %d  words=%d  [%s]", m.name, m.line, m.words, src_name))
		end
	end
	add("")
end

-- (internal) Section renderer: per-source errors (one-line + "(none)" if empty).
local function render_module_errors_section(add, results, total_errors)
	add(SECTION_HEADER_ERRORS)
	if total_errors == 0 then
		add("  (none)")
	else
		for _, r in ipairs(results) do
			local src_name = source_basename(r.source)
			for _, e in ipairs(r.errors) do
				add(string.format("  ✗ line %d  %s  [%s]", e.line, e.msg, src_name))
			end
		end
	end
	add("")
end

-- (internal) Section renderer: per-source warnings (one-line + "(none)" if empty).
local function render_module_warnings_section(add, results, total_warnings)
	add(SECTION_HEADER_WARNINGS)
	if total_warnings == 0 then
		add("  (none)")
	else
		for _, r in ipairs(results) do
			local src_name = source_basename(r.source)
			for _, w in ipairs(r.warnings) do
				add(string.format("  ⚠ line %d  %s  [%s]", w.line, w.msg, src_name))
			end
		end
	end
	add("")
end

--- Render the per-MODULE annotation report (one `<dir_basename>.annotations.txt`).
--- @param dir string                  -- module directory path
--- @param sources SourceFile[]        -- sources in this module
--- @param results AnnotationResult[]  -- per-source validate() results
--- @return string                     -- the rendered report text
local function render_module_report(dir, sources, results)
	local lines = {}
	local function add(s) lines[#lines + 1] = s end

	add(RULE_THICK)
	add("ANNOTATION PASS — module " .. source_basename(dir))
	add(RULE_THICK)
	add(string.format("Sources: %d", #sources))
	for _, s in ipairs(sources) do add("  " .. s.path) end
	add("")

	local total_atoms, total_annots, total_binds, total_macros, total_errors, total_warnings = tally_module_totals(results)
	add(string.format("Atoms: %d   Annotations: %d   Binds structs: %d   Macro decls: %d",
		total_atoms, total_annots, total_binds, total_macros))
	add("")

	render_module_atoms_section(add, results)
	render_module_annots_section(add, results)
	render_module_binds_section(add, results)
	render_module_macros_section(add, results)
	render_module_errors_section(add, results, total_errors)
	render_module_warnings_section(add, results, total_warnings)

	return table.concat(lines, "\n") .. "\n"
end

-- ════════════════════════════════════════════════════════════════════════════
-- Per-project summary
-- ════════════════════════════════════════════════════════════════════════════

--- Render the per-project summary (`build/gen/annotation_validation.txt`).
--- Aggregates totals across all sources; lists per-source error counts if any source has errors.
--- @param all_results AnnotationResult[]
--- @return string
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

	add(RULE_THICK)
	add("ANNOTATION VALIDATION — project summary")
	add(RULE_THICK)
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
				local src_name = source_basename(r.source)
				add(string.format("  %s : %d error(s)", src_name, #r.errors))
			end
		end
		add("")
	end

	return table.concat(lines, "\n") .. "\n"
end

-- ════════════════════════════════════════════════════════════════════════════
-- Orchestration helpers
-- ════════════════════════════════════════════════════════════════════════════

-- (internal) Pull per-source validate() results from the annotation pass's stash.
-- The annotation pass runs first in the dep chain and caches results in `ctx.flags._annot_source_results`; we read from there instead of re-validating each source.
-- Returns the list of module results + the flat list of all results (for the project-wide summary).
-- @param ctx PassCtx
-- @param dir_sources SourceFile[]
-- @return AnnotationResult[], AnnotationResult[]
local function lookup_module_results(ctx, dir_sources)
	local src_cache      = (ctx.flags and ctx.flags._annot_source_results) or {}
	local module_results = {}
	local all_results    = {}
	for _, src in ipairs(dir_sources) do
		local result = src_cache[src.path]
		if result then
			result.source = src.path                                    -- defensive (annotation tags it too; this guards against cache misses from earlier iterations)
			module_results[#module_results + 1] = result
			all_results[#all_results + 1] = result
		end
	end
	return module_results, all_results
end

-- (internal) Does this module's results contain anything worth emitting?
-- @param module_results AnnotationResult[]
-- @return boolean
local function module_has_content(module_results)
	for _, r in ipairs(module_results) do
		if #r.atoms  > 0 or #r.annots > 0 or #r.binds    > 0
		or #r.macros > 0 or #r.errors > 0 or #r.warnings > 0 then
			return true
		end
	end
	return false
end

-- (internal) Log a debug message if `_G[DEBUG_FLAG]` is truthy.
-- @param fmt string
local function debug_log(fmt, ...)
	if _G[DEBUG_FLAG] then
		io.stderr:write(string.format("[%s] " .. fmt, PASS_NAME, ...))
	end
end

-- ════════════════════════════════════════════════════════════════════════════
-- M — module exports
-- ════════════════════════════════════════════════════════════════════════════

local M = {}

--- Run the report pass. 
--- Renders one `<dir_basename>.annotations.txt` per source-directory that has content, plus the project-wide `annotation_validation.txt` summary.
--- @param ctx PassCtx
--- @return PassResult
function M.run(ctx)
	local outputs  = {}
	local errors   = {}
	local warnings = {}

	local module_entries = (ctx.flags and ctx.flags._annot_results) or {}
	local by_dir         = ctx.by_dir or duffle.group_sources_by_dir(ctx.sources)

	if not ctx.dry_run then duffle.ensure_dir(ctx.out_root) end

	local all_results_for_summary = {}
	for _, entry in ipairs(module_entries) do
		debug_log("entry: dir=%s basename=%s atoms_count=%d dir_sources=%d\n", entry.dir, entry.dir_basename, entry.atoms_count, #(by_dir[entry.dir] or {}))

		if entry.atoms_count > 0 or #(by_dir[entry.dir] or {}) > 0 then
			local dir_sources                 = by_dir[entry.dir] or {}
			local module_results, all_results = lookup_module_results(ctx, dir_sources)
			for _, r in ipairs(all_results) do
				all_results_for_summary[#all_results_for_summary + 1] = r
			end

			if module_has_content(module_results) then
				local out_path = ctx.out_root .. "/" .. entry.dir_basename .. ".annotations.txt"
				if not ctx.dry_run then
					duffle.write_file(out_path, render_module_report(entry.dir, dir_sources, module_results))
				end
				outputs[#outputs + 1] = { annotations_txt = out_path }
			else
				debug_log("  -> no content; skipping\n")
			end
		end
	end

	if not ctx.dry_run and #all_results_for_summary > 0 then
		local summary_path = ctx.out_root .. "/annotation_validation.txt"
		duffle.write_file(summary_path, render_project_report(all_results_for_summary))
		outputs[#outputs + 1] = { summary_txt = summary_path }
	end

	return { outputs = outputs, errors = errors, warnings = warnings }
end

return M
