--- passes/report.lua — Per-MODULE annotation report renderer +
--- project-wide summary writer.
---
--- Two output files per build:
---   - `build/gen/<dir_basename>.annotations.txt` — one per source-directory containing atoms; aggregates across all sources in the directory.
---   - `build/gen/annotation_validation.txt` — the project summary.
---
--- The annotation pass emits `errors.h` files per module and the canonical `corpus.sources_by_dir` projection groups sources by directory.
--- This pass iterates the canonical dir projection directly and re-validates each source via `annotation.validate()` to get the detailed per-source results.

-- ════════════════════════════════════════════════════════════════════════════
-- Module-scope requires + package.path setup
-- ════════════════════════════════════════════════════════════════════════════

-- Resolve `arg[0]` to an absolute-ish script directory so that `require("duffle")` resolves against `scripts/` regardless of CWD.
-- Bootstrap: see `ps1_meta.lua` for the rationale.
-- Bootstrap: load `scripts/duffle_paths.lua` (sets package.path + package.cpath).
-- Uses `debug.getinfo` to find this file's own directory, so it works both standalone and when require'd from the orchestrator.
-- Bootstrap: load `duffle_paths.lua` via `debug.getinfo(1, "S").source` (works both standalone + when require'd).
-- duffle_paths.lua sets package.path then returns `require("duffle")` at the bottom, so the dofile value IS the duffle module.
local _bootstrap_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local duffle         = dofile(_bootstrap_dir .. "../duffle_paths.lua")

-- Load the annotation pass so we can re-validate each source against the canonical corpus projection.
-- The annotation pass exposes `M.validate`, which returns the per-source AnnotationResult (atoms / annots / macros / binds / errors / warnings)
-- that the report pass renders into the per-module `<dir_basename>.annotations.txt` output.
local annotation = dofile(_bootstrap_dir .. "annotation.lua")

-- Load atoms_source_map for the `render_source_map` / `render_provenance` module functions (used by `render_module_atoms_md` to produce `<module>.atoms.md` without re-walking source tokens).
-- The pass itself emits no per-source files anymore; we only consume the two pure renderers here.
-- Defined BEFORE the renderer functions below so their upvalues resolve to this local (not the global `atoms_source_map`, which is nil).
local atoms_source_map = dofile(_bootstrap_dir .. "atoms_source_map.lua")

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

-- Lua pattern that captures the basename (last path segment) of a forward- or back-slash separated path.
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
--- @field sources            SourceFile[]         -- all source files in the build
--- @field metadata_path      string               -- path to word_count.metadata.h
--- @field shared             table                -- cross-pass shared state
--- @field out_root           string               -- output root (e.g. "build/gen")
--- @field project_root       string               -- project root (e.g. "code/")
--- @field upstream           table<string, table> -- per-pass upstream outputs
--- @field flags              table                -- CLI flags + per-pass stash
--- @field verbose            boolean              -- if true, log diagnostic info

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

--- Extract the basename (last path segment) of a forward- or back-slash separated path. Returns the input unchanged if no separator is found.
--- @param path string
--- @return string
local function source_basename(path)
	return path:match(BASENAME_PATTERN) or path
end

-- ════════════════════════════════════════════════════════════════════════════
-- Markdown renderers (consolidated-report-files refactor, 2026-07-26)
-- ════════════════════════════════════════════════════════════════════════════

--- Render the thin project-wide summary (`build/atom_meta_report.summary.md`).
--- @param all_results { module:string, atoms:integer, annots:integer, binds:integer,
---                       macros:integer, findings:integer, errors:integer,
---                       warnings:integer, info:integer }[]
--- @return string
local function render_project_summary(all_results)
	local lines = {
		"# Project summary",
		"> Auto-generated by ps1_meta.lua (passes/report.lua).",
		"",
		"| module | atoms | annots | binds | macros | findings | errors | warnings | info |",
		"|--------|-------|--------|-------|--------|----------|--------|----------|------|",
	}
	local totals = { atoms = 0, annots = 0, binds = 0, macros = 0,
		findings = 0, errors = 0, warnings = 0, info = 0 }
	for _, e in ipairs(all_results) do
		lines[#lines + 1] = string.format(
			"| %s | %d | %d | %d | %d | %d | %d | %d | %d |",
			e.module, e.atoms, e.annots, e.binds, e.macros,
			e.findings, e.errors, e.warnings, e.info)
		totals.atoms    = totals.atoms    + e.atoms
		totals.annots   = totals.annots   + e.annots
		totals.binds    = totals.binds    + e.binds
		totals.macros   = totals.macros   + e.macros
		totals.findings = totals.findings + e.findings
		totals.errors   = totals.errors   + e.errors
		totals.warnings = totals.warnings + e.warnings
		totals.info     = totals.info     + e.info
	end
	lines[#lines + 1] = string.format(
		"| **TOTAL** | %d | %d | %d | %d | %d | %d | %d | %d |",
		totals.atoms, totals.annots, totals.binds, totals.macros,
		totals.findings, totals.errors, totals.warnings, totals.info)
	return table.concat(lines, "\n") .. "\n"
end

--- Render the per-module verbose source-map markdown (`build/<module>.atoms.md`).
--- Per-source sub-section, per-atom stanza with sourcemap + provenance rows.
--- Pulls sourcemap + provenance from `atoms_source_map` (no second source walk).
--- @param dir string
--- @param dir_sources SourceFile[]
--- @param wc table<string, integer>
--- @return string
local function render_module_atoms_md(dir, dir_sources, wc)
	local dir_basename = source_basename(dir)
	local lines = {
		"# " .. dir_basename .. " — atoms (verbose source map)",
		"> Per-word call-site + provenance. Auto-generated.",
		"",
	}
	for _, src in ipairs(dir_sources) do
		local src_name = source_basename(src.path)
		lines[#lines + 1] = "## " .. src_name
		lines[#lines + 1] = ""
		-- For each atom with a projection, render its sourcemap + provenance.
		local atoms_list = {}
		for _, atom in ipairs((src.scan or {}).atoms or {}) do
			if atom.paths then atoms_list[#atoms_list + 1] = atom end
		end
		for _, atom in ipairs((src.scan or {}).raw_atoms or {}) do
			if atom.paths then atoms_list[#atoms_list + 1] = atom end
		end
		if #atoms_list == 0 then
			lines[#lines + 1] = "_(no atom projections)_"
			lines[#lines + 1] = ""
		else
			-- Per-source forward-slash path (same one `emit_atom_stanza` / `emit_provenance_stanza` would derive;
			-- computed once per `## <source>` heading and reused by each atom's `WORD N CALL ...` field).
			local rel_path = src.path:gsub("\\\\", "/")
			for _, atom in ipairs(atoms_list) do
				lines[#lines + 1] = string.format(
					"### atom: %s (line %d, %d words)",
					atom.name, atom.line or 0, #(atom.paths.items or {}))
				lines[#lines + 1] = ""
				lines[#lines + 1] = "**Sourcemap** — per-word call site:"
				lines[#lines + 1] = "```"
				-- Per-atom invariant: call the per-atom renderers, NOT the per-source ones.
				-- The per-source renderers enumerate every atom in `src`;
				-- calling them in a per-atom loop would repeat the whole source under every `### atom:` heading.
				lines[#lines + 1] = atoms_source_map.render_atom_source_map(atom):gsub("\n+$", "")
				lines[#lines + 1] = "```"
				lines[#lines + 1] = ""
				lines[#lines + 1] = "**Provenance** — per-word definition + body:"
				lines[#lines + 1] = "```"
				lines[#lines + 1] = atoms_source_map.render_atom_provenance(atom, wc, rel_path):gsub("\n+$", "")
				lines[#lines + 1] = "```"
				lines[#lines + 1] = ""
			end
		end
	end
	return table.concat(lines, "\n") .. "\n"
end

--- Render the consolidated per-module markdown (`build/<module>.atom_meta_report.md`).
--- Aggregates annotation + static-analysis content across all sources in `dir`.
--- Annotations come from re-running `annotation.validate()` per source (the existing pattern);
--- static-analysis comes from `corpus.static_analysis_results[dir_basename]` (populated by `static_analysis.lua` — no second corpus_pipe_ctx build).
--- @param dir string
--- @param dir_sources SourceFile[]
--- @param annot_results AnnotationResult[]
--- @param sa_results table                 -- corpus.static_analysis_results[dir_basename]
--- @return string
local function render_module_meta_report(dir, dir_sources, annot_results, sa_results)
	local dir_basename = source_basename(dir)
	local lines = {
		"# " .. dir_basename .. " — atom meta report",
		"> Auto-generated by ps1_meta.lua (passes/report.lua). Do not edit.",
		"",
	}
	local function add(s) lines[#lines + 1] = s end

	-- Module summary table.
	local n_atoms        = 0
	local n_annot        = 0
	local n_binds        = 0
	local n_macros       = 0
	local n_bare, n_proc = 0, 0
	for _, r in ipairs(annot_results) do
		n_atoms  = n_atoms  + #r.atoms
		n_annot  = n_annot  + #r.annots
		n_binds  = n_binds  + #r.binds
		n_macros = n_macros + #r.macros
	end
	for _, a in ipairs(sa_results.atoms or {}) do
		if     a.kind == "comp_bare" then n_bare = n_bare + 1
		elseif a.kind == "comp_proc" then n_proc = n_proc + 1
		end
	end

	add("## Module summary"); add("")
	add("| metric | value |"); add("|--------|-------|")
	add(string.format("| sources | %d |", #dir_sources))
	add(string.format("| atoms | %d (atoms: %d, comp_bare: %d, comp_proc: %d) |",
		#(sa_results.atoms or {}),
		#(sa_results.atoms or {}) - n_bare - n_proc, n_bare, n_proc))
	add(string.format("| annotations | %d |", n_annot))
	add(string.format("| binds structs | %d |", n_binds))
	add(string.format("| macro decls | %d |", n_macros))
	add(string.format("| findings | %d (errors: %d, warnings: %d, info: %d) |",
		#(sa_results.findings or {}),
		#(sa_results.errors   or {}),
		#(sa_results.warnings or {}),
		#(sa_results.info     or {})))
	add("")

	-- Sources
	add("## Sources"); add("")
	for _, s in ipairs(dir_sources) do add("- `" .. s.path .. "`") end
	add("")

	-- Atoms (annotation)
	add("## Atoms"); add("")
	add("| kind | name | source | line |"); add("|------|------|--------|------|")
	for _, r in ipairs(annot_results) do
		local src_name = source_basename(r.source)
		for _, a in ipairs(r.atoms) do
			add(string.format("| atom | %s | %s | %d |", a.name, src_name, a.line))
		end
	end
	add("")

	-- Annotations
	add("## Annotations"); add("")
	if #annot_results == 0 then
		add("_(none)_")
	else
		add("| source | line | name | binds | reads | writes |")
		add("|--------|------|------|-------|-------|--------|")
		for _, r in ipairs(annot_results) do
			local src_name = source_basename(r.source)
			for _, a in ipairs(r.annots) do
				local binds  = a.binds  or "—"
				local reads  = (#a.reads  > 0 and table.concat(a.reads,  ",")) or "—"
				local writes = (#a.writes > 0 and table.concat(a.writes, ",")) or "—"
				add(string.format("| %s | %d | %s | %s | %s | %s |",
					src_name, a.line, a.name, binds, reads, writes))
			end
		end
	end
	add("")

	-- Binds_* structs
	add("## Binds_* structs"); add("")
	if #annot_results == 0 then
		add("_(none)_")
	else
		for _, r in ipairs(annot_results) do
			local src_name = source_basename(r.source)
			for _, b in ipairs(r.binds) do
				add(string.format("### %s (%s:%d, %d bytes)",
					b.name, src_name, b.line, b.bytes))
				for _, f in ipairs(b.fields) do
					add(string.format("- `+%d %s`", f.offset, f.name))
				end
				add("")
			end
		end
	end

	-- Macro decls
	add("## Macro word-count declarations"); add("")
	if #annot_results == 0 then
		add("_(none)_")
	else
		add("| source | line | macro declaration |")
		add("|--------|------|-------------------|")
		for _, r in ipairs(annot_results) do
			local src_name = source_basename(r.source)
			for _, m in ipairs(r.macros) do
				add(string.format("| %s | %d | %s |",
					src_name, m.line, m.name))
			end
		end
	end
	add("")

	-- Findings by atom (static-analysis)
	add("## Static analysis — findings by atom"); add("")
	local by_atom = {}
	for _, f in ipairs(sa_results.findings or {}) do
		by_atom[f.atom] = by_atom[f.atom] or {}
		by_atom[f.atom][#by_atom[f.atom] + 1] = f
	end
	if next(by_atom) == nil then
		add("_(no findings)_")
	else
		for _, a in ipairs(sa_results.atoms or {}) do
			local fs = by_atom[a.name]
			if fs then
				add(string.format("### %s", a.name))
				for _, f in ipairs(fs) do
					add(string.format("- `[%s] %s`", f.check, f.msg))
				end
				add("")
			end
		end
	end

	-- Errors / Warnings / Info
	local function add_findings(label, entries)
		add(string.format("## %s", label))
		if #entries == 0 then
			add("_(none)_")
		else
			for _, e in ipairs(entries) do
				add(string.format("- line %d  %s", e.line, e.msg))
			end
		end
		add("")
	end
	add_findings("Errors",   sa_results.errors   or {})
	add_findings("Warnings", sa_results.warnings or {})
	add_findings("Info",     sa_results.info     or {})

	-- Per-atom cycle counts (path-aware)
	add("## Per-atom cycle counts (path-aware, best case, no stalls)"); add("")
	add("| atom | source | min | max | branches | paths | notes |")
	add("|------|--------|-----|-----|----------|-------|-------|")
	local sorted = {}
	for _, a in ipairs(sa_results.atoms or {}) do sorted[#sorted + 1] = a end
	table.sort(sorted, function(x, y)
		return ((x.paths or {}).cycles_max or 0) > ((y.paths or {}).cycles_max or 0)
	end)
	for _, a in ipairs(sorted) do
		local p        = a.paths or {}
		local src_name = a.source_path and source_basename(a.source_path) or ""
		local notes   = ""
		if p.has_loops then notes = notes .. " [loop!]" end
		if p.unknown_macros and #p.unknown_macros > 0 then
			notes = notes .. " [unknown: " .. table.concat(p.unknown_macros, ", ") .. "]"
		end
		add(string.format("| %s | %s | %d | %d | %d | %d | %s |",
			a.name, src_name,
			p.cycles_min or 0, p.cycles_max or 0,
			p.branches or 0, p.paths or 0, notes))
	end
	add("")

	-- Per-source scan summary
	add("## Per-source scan summary"); add("")
	for _, src in ipairs(dir_sources) do
		local src_atoms = {}
		for _, a in ipairs(sa_results.atoms or {}) do
			if a.source_path == src.path then src_atoms[#src_atoms + 1] = a end
		end
		if #src_atoms > 0 then
			local mn, mx = math.huge, -1
			for _, a in ipairs(src_atoms) do
				local p = a.paths or {}
				if (p.cycles_min or 0) < mn then mn = p.cycles_min or 0 end
				if (p.cycles_max or 0) > mx then mx = p.cycles_max or 0 end
			end
			local path_str
			if mx > 0 then
				path_str = string.format("  cycles=%d..%d", mn, mx)
			else
				path_str = string.format("  %d cycles", mn)
			end
			add(string.format("- `%s` — %d atom%s%s",
				src.basename, #src_atoms,
				#src_atoms == 1 and "" or "s", path_str))
		end
	end
	add("")

	return table.concat(lines, "\n") .. "\n"
end

-- ════════════════════════════════════════════════════════════════════════════
-- REPORT_RENDERERS — data-driven report dispatch (one row per file kind)
-- ════════════════════════════════════════════════════════════════════════════
-- `once = true` means render once at the project level (not per-module).
-- `basename(dir_basename)` yields the file's basename for that kind.
-- `gather(ctx, dir, dir_sources [, all_modules])` returns the rendered string.
local REPORT_RENDERERS = {
	{
		name     = "atom_meta_report",
		ext      = "md",
		basename = function(dir_basename) return dir_basename .. ".atom_meta_report" end,
		once     = false,
		gather   = function(ctx, dir, dir_sources)
			-- Annotations: re-run `annotation.validate()` per source (the existing pattern).
			local annot_results = {}
			for _, src in ipairs(dir_sources) do
				if src.scan then
					local r = annotation.validate(ctx, src, nil)
					r.source = src.path
					annot_results[#annot_results + 1] = r
				end
			end
			-- Static-analysis: read stashed projection (no re-validate).
			local dir_basename = dir:match("([^/\\]+)$") or dir
			local sa_results   = (ctx.shared.corpus.static_analysis_results or {})[dir_basename] or {}
			return render_module_meta_report(dir, dir_sources, annot_results, sa_results)
		end,
	},
	{
		name     = "atoms",
		ext      = "md",
		basename = function(dir_basename) return dir_basename .. ".atoms" end,
		once     = false,
		gather   = function(ctx, dir, dir_sources)
			return render_module_atoms_md(dir, dir_sources,
				ctx.shared.corpus.word_counts or {})
		end,
	},
	{
		name     = "summary",
		ext      = "md",
		basename = function(_dir_basename) return "atom_meta_report.summary" end,
		once     = true,
		gather   = function(_ctx, _dir, _dir_sources, all_modules)
			return render_project_summary(all_modules)
		end,
	},
}

-- ════════════════════════════════════════════════════════════════════════════
-- M — public pass surface
-- ════════════════════════════════════════════════════════════════════════════

local M = {}

--- Run the report pass. Emits 1 `atom_meta_report.summary.md` per build + 2 `atom_meta_report.md` + 2 `atoms.md` files per module (duffle + gte_hello).
--- Reads `corpus.static_analysis_results` (added in Phase 1) to populate per-module findings without re-running validate().
--- @param ctx PassCtx
--- @return PassResult
function M.run(ctx)
	local outputs = {}
	local corpus  = ctx.shared and ctx.shared.corpus
	local by_dir  = (corpus and corpus.sources_by_dir) or {}

	-- `out_path_root`: when the conventional `out_root` is `build/gen` (any spelling — relative, absolute, separator variants).
	-- Write the md files to `build/` (parent of `gen/`) instead of nested under `gen/`.
	-- Mirrors the `gdb_tape_atoms_runtime.gdb` relocation.
	local function ends_with_gen(p)
		return type(p) == "string" and (p:match("[/\\]gen[/\\]?$") ~= nil
			or p == "build/gen" or p == "build\\gen")
	end
	local out_root_effective = ends_with_gen(ctx.out_root)
		and ctx.out_root:gsub("[/\\]gen[/\\]?$", "")
		or ctx.out_root

	duffle.ensure_dir(out_root_effective)

	-- Aggregator for the project-wide `once = true` summary renderer.
	local all_modules = {}

	for dir, dir_sources in pairs(by_dir) do
		local dir_basename = dir:match("([^/\\]+)$") or dir

		-- Per-renderer dispatch for the per-module renderers (once = false).
		for _, renderer in ipairs(REPORT_RENDERERS) do
			if not renderer.once then
				local body     = renderer.gather(ctx, dir, dir_sources)
				local out_path = out_root_effective .. "/" .. renderer.basename(dir_basename) .. "." .. renderer.ext
				duffle.write_file(out_path, body)
				outputs[#outputs + 1] = { kind = renderer.name, path = out_path }
			end
		end

		-- For the summary, compute per-module totals once (re-validating annotations per source — same pattern as the meta_report renderer).
		local annot_results = {}
		for _, src in ipairs(dir_sources) do
			if src.scan then
				local r = annotation.validate(ctx, src, nil)
				r.source = src.path
				annot_results[#annot_results + 1] = r
			end
		end
		local n_annot, n_binds, n_macros = 0, 0, 0
		for _, r in ipairs(annot_results) do
			n_annot  = n_annot  + #r.annots
			n_binds  = n_binds  + #r.binds
			n_macros = n_macros + #r.macros
		end
		local sa_results = (corpus.static_analysis_results or {})[dir_basename] or {}
		all_modules[#all_modules + 1] = {
			module   = dir_basename,
			atoms    = #(sa_results.atoms or {}),
			annots   = n_annot,
			binds    = n_binds,
			macros   = n_macros,
			findings = #(sa_results.findings or {}),
			errors   = #(sa_results.errors   or {}),
			warnings = #(sa_results.warnings or {}),
			info     = #(sa_results.info     or {}),
		}
	end

	-- Project-wide renderer (once = true): write the summary file.
	for _, renderer in ipairs(REPORT_RENDERERS) do
		if renderer.once then
			local body     = renderer.gather(ctx, nil, nil, all_modules)
			local out_path = out_root_effective .. "/" .. renderer.basename("") .. "." .. renderer.ext
			duffle.write_file(out_path, body)
			outputs[#outputs + 1] = { kind = renderer.name, path = out_path }
		end
	end

	return { outputs = outputs, errors = {}, warnings = {} }
end

return M
