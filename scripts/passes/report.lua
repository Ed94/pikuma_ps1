--- passes/report.lua — Per-MODULE annotation report renderer + project-wide summary writer.
---
--- Per-module markdown plus one project summary:
---   - `build/<dir_basename>.atom_meta_report.md` — one per source-directory containing atoms
---   - `build/<dir_basename>.atoms.md` — verbose source map
---   - `build/atom_meta_report.summary.md` — the project summary
---
--- The canonical `corpus.sources_by_dir` projection groups sources by directory.
--- This pass builds one ModuleView per directory and walks SECTION_RENDERERS.

-- ════════════════════════════════════════════════════════════════════════════
-- Module-scope requires + package.path setup
-- ════════════════════════════════════════════════════════════════════════════

-- Resolve `arg[0]` to an absolute-ish script directory so that `require("duffle")` resolves against `scripts/` regardless of CWD.
-- Bootstrap: See `ps1_meta.lua` for the rationale.
-- Bootstrap: Load `scripts/duffle_paths.lua` (sets package.path + package.cpath).
-- Uses `debug.getinfo` to find this file's own directory, so it works both standalone and when require'd from the orchestrator.
-- Bootstrap: Load `duffle_paths.lua` via `debug.getinfo(1, "S").source` (works both standalone + when require'd).
-- duffle_paths.lua sets package.path then returns `require("duffle")` at the bottom, so the dofile value IS the duffle module.
local _bootstrap_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./" ---@type string
local duffle         = dofile(_bootstrap_dir .. "../duffle_paths.lua")            ---@type DuffleExport

-- Load atoms_source_map for the `render_source_map` / `render_provenance` module functions (used by `render_module_atoms_md` to produce `<module>.atoms.md` without re-walking source tokens).
-- The pass itself emits no per-source files anymore; we only consume the two pure renderers here.
-- Defined BEFORE the renderer functions below so their upvalues resolve to this local (not the global `atoms_source_map`, which is nil).
local atoms_source_map = dofile(_bootstrap_dir .. "atoms_source_map.lua") ---@type AtomSourceMapPass

-- ════════════════════════════════════════════════════════════════════════════
-- Constants
-- ════════════════════════════════════════════════════════════════════════════

-- Section separators used in the rendered text reports.
-- The thin rules are hand-tuned to align with the per-section content width; do not change without also checking the section renderers below.
local RULE_THICK               = "========================================================"                                                                                                      ---@type string
local SECTION_HEADER_ATOMS     = "── Atoms ────────────────────────────────────────────────" ---@type string
local SECTION_HEADER_ANNOTS    = "── Annotations ──────────────────────────────────────────"             ---@type string
local SECTION_HEADER_BINDS     = "── Binds_* structs ──────────────────────────────────────"                     ---@type string
local SECTION_HEADER_MACROS    = "── Macro word-count declarations ─────────────────────────"                                              ---@type string
local SECTION_HEADER_ERRORS    = "── Errors ──────────────────────────────────────────────"      ---@type string
local SECTION_HEADER_WARNINGS  = "── Warnings ────────────────────────────────────────────"          ---@type string

-- Lua pattern that captures the basename (last path segment) of a forward- or back-slash separated path.
local BASENAME_PATTERN = "([^/\\]+)$" ---@type string

-- Debug flag name — set to truthy in `_G` to enable verbose logging.
local DEBUG_FLAG = "_DEBUG_REPORT" ---@type string

-- Pass identifier for log messages.
local PASS_NAME = "report" ---@type string

-- ════════════════════════════════════════════════════════════════════════════
-- Type declarations
-- ════════════════════════════════════════════════════════════════════════════

-- SourceFile: see duffle.lua
-- PassCtx, PassResult, PassFinding, PassOutputEntry: see ps1_meta.lua
-- AtomEntry, SourceScan, BindsEntry, AtomInfoEntry, AliasEntry,
-- AtomPhaseGroup, AtomViewEntry, AtomCtxEntry, CorpusCollision: see scan_source.lua
-- CheckFinding, AtomAnalysis: see static_analysis.lua
-- WordCounts: see word_count_eval.lua
-- ComponentBodyEntry: see duffle_emit.lua
-- AtomPaths, WordEvent: see emission_model.lua
-- GprAllocMap: see auto_reg.lua

-- Shapes produced by `passes/annotation.lua`'s `M.validate()`.

--- @class AnnotEntry
--- @field line    integer     -- Source line
--- @field macro   string      -- Macro name (e.g. "atom_reads")
--- @field name    string      -- Atom name (if a `name(...)` was given)
--- @field kind    string      -- "atom_info" | "atom_bind" | ...
--- @field binds   string|nil  -- Binds_X name if any
--- @field reads   string[]    -- R_* names (read targets)
--- @field writes  string[]    -- R_* names (write targets)
--- @field error   string|nil  -- Error message if annotation was malformed

--- @class BindsField
--- @field name   string   -- Field name
--- @field offset integer  -- Byte offset within the Binds_X struct

--- @class BindsStruct
--- @field name   string         -- Struct name (e.g. "Binds_Floor")
--- @field line   integer        -- Source line of the typedef
--- @field bytes  integer        -- Total byte size
--- @field fields BindsField[]   -- The field list

--- @class MacroEntry
--- @field name  string   -- Macro name (e.g. "WORD_COUNT(my_macro, 4)")
--- @field line  integer  -- Source line
--- @field words integer  -- Declared word count

--- @class AnnotationResult
--- @field source   string         -- Set by this pass; original source path
--- @field atoms    AtomEntry[]    -- Atom declarations in this source
--- @field annots   AnnotEntry[]   -- Annotation entries
--- @field macros   MacroEntry[]   -- Macro word-count declarations
--- @field binds    BindsStruct[]  -- Binds_* struct declarations
--- @field errors   PassFinding[]  -- Errors from validation
--- @field warnings PassFinding[]  -- Warnings from validation
--- @field info     PassFinding[]  -- Info summary (not rendered here)

--- @class ModuleEntry
--- @field dir          string   -- Absolute directory path
--- @field dir_basename string   -- Basename (e.g. "duffle", "gte_hello")
--- @field atoms_count  integer  -- Pre-counted atoms for filtering

--- @class ModuleReport
--- @field dir       string             -- Module directory
--- @field sources   SourceFile[]       -- Sources in this module
--- @field results   AnnotationResult[] -- Per-source validate() results

--- @class ProjectReport
--- @field results AnnotationResult[]  -- All per-source results

--- @class KindCounts
--- @field atom      integer
--- @field atom_proc integer
--- @field comp_bare integer
--- @field comp_proc integer

--- @class ProjectSummaryRow
--- @field module   string
--- @field atoms    integer
--- @field annots   integer
--- @field binds    integer
--- @field macros   integer
--- @field findings integer
--- @field errors   integer
--- @field warnings integer
--- @field info     integer

--- @class ProjectSummaryTotals
--- @field atoms    integer
--- @field annots   integer
--- @field binds    integer
--- @field macros   integer
--- @field findings integer
--- @field errors   integer
--- @field warnings integer
--- @field info     integer

--- @class ComponentReportRow
--- @field name  string
--- @field kind  string
--- @field args  string
--- @field words integer
--- @field map   string

--- @class AnnotReportRow
--- @field source string
--- @field line   integer
--- @field name   string
--- @field binds  string
--- @field reads  string
--- @field writes string
--- @field phase  string

--- @class CompAnnotReportRow
--- @field source string
--- @field line   integer
--- @field name   string
--- @field reads  string
--- @field writes string

--- @class RegUseSlot
--- @field name     string
--- @field aliases  string[]|nil
--- @field readonly boolean|nil

--- @class RegUseSchema
--- @field name  string|nil
--- @field slots RegUseSlot[]|nil

--- @class RegUseError
--- @field kind        string|nil
--- @field schema_name string|nil
--- @field source_file string|nil

--- @class GprLatticeSlot
--- @field kind  string|nil
--- @field value string|integer|nil

--- @class ForwardState
--- @field gpr_values table<string, GprLatticeSlot>|nil

--- @class AtomRelation
--- @field destination          string|nil
--- @field producer_destination string|nil
--- @field semantic             string|nil
--- @field producer_word        integer|nil
--- @field consumer_word        integer|nil

--- @class ModuleView
--- @field dir      string
--- @field sources  SourceFile[]
--- @field decls    AtomEntry[]
--- @field schemas  RegUseSchema[]
--- @field findings CheckFinding[]
--- @field corpus   Corpus

--- @class SectionRenderer
--- @field header string
--- @field render fun(add: fun(s: string): nil, view: ModuleView): nil

--- @class ReportRenderer
--- @field name     string
--- @field ext      string
--- @field basename fun(dir_basename: string): string
--- @field once     boolean
--- @field gather   fun(ctx: PassCtx, dir: string|nil, dir_sources: SourceFile[]|nil, all_modules: ProjectSummaryRow[]|nil): string

--- @class ReportPass
--- @field run fun(ctx: PassCtx): PassResult

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
--- @param all_results ProjectSummaryRow[]
--- @return string
local function render_project_summary(all_results)
	local lines = { ---@type string[]
		"# Project summary",
		"> Auto-generated by ps1_meta.lua (passes/report.lua).",
		"",
		"| module | atoms | annots | binds | macros | findings | errors | warnings | info |",
		"|--------|-------|--------|-------|--------|----------|--------|----------|------|",
	}
	local totals = { atoms = 0, annots = 0, binds = 0, macros = 0, findings = 0, errors = 0, warnings = 0, info = 0 } ---@type ProjectSummaryTotals
	for _, e in ipairs(all_results) do                                                                                ---@type integer, ProjectSummaryRow
		lines[#lines + 1] = string.format("| %s | %d | %d | %d | %d | %d | %d | %d | %d |"
			, e.module, e.atoms, e.annots, e.binds, e.macros, e.findings, e.errors, e.warnings, e.info)
		totals.atoms    = totals.atoms    + e.atoms
		totals.annots   = totals.annots   + e.annots
		totals.binds    = totals.binds    + e.binds
		totals.macros   = totals.macros   + e.macros
		totals.findings = totals.findings + e.findings
		totals.errors   = totals.errors   + e.errors
		totals.warnings = totals.warnings + e.warnings
		totals.info     = totals.info     + e.info
	end
	lines[#lines + 1] = string.format("| **TOTAL** | %d | %d | %d | %d | %d | %d | %d | %d |"
		, totals.atoms, totals.annots, totals.binds, totals.macros, totals.findings, totals.errors, totals.warnings, totals.info)
	return table.concat(lines, "\n") .. "\n"
end

--- Render the per-module verbose source-map markdown (`build/<module>.atoms.md`).
--- Per-source sub-section, per-atom stanza with sourcemap + provenance rows.
--- Pulls sourcemap + provenance from `atoms_source_map` (no second source walk).
--- @param dir         string
--- @param dir_sources SourceFile[]
--- @param wc          WordCounts
--- @return string
local function render_module_atoms_md(dir, dir_sources, wc)
	local dir_basename = source_basename(dir) ---@type string
	local lines        = {                    ---@type string[]
		"# " .. dir_basename .. " — atoms (verbose source map)",
		"> Per-word call-site + provenance. Auto-generated.",
		"",
	}
	for _, src in ipairs(dir_sources) do ---@type integer, SourceFile
		local src_name = source_basename(src.path) ---@type string
		lines[#lines + 1] = "## " .. src_name
		lines[#lines + 1] = ""
		-- For each atom with a projection, render its sourcemap + provenance.
		local atoms_list = {}                                  ---@type AtomEntry[]
		for _, atom in ipairs((src.scan or {}).atoms or {}) do ---@type integer, AtomEntry
			if atom.paths then atoms_list[#atoms_list + 1] = atom end
		end
		for _, atom in ipairs((src.scan or {}).raw_atoms or {}) do ---@type integer, AtomEntry
			if atom.paths then atoms_list[#atoms_list + 1] = atom end
		end
		if #atoms_list == 0 then
			lines[#lines + 1] = "_(no atom projections)_"
			lines[#lines + 1] = ""
		else
			-- Per-source forward-slash path (same one `emit_atom_stanza` / `emit_provenance_stanza` would derive;
			-- computed once per `## <source>` heading and reused by each atom's `WORD N CALL ...` field).
			local rel_path = src.path:gsub("\\\\", "/") ---@type string
			for _, atom in ipairs(atoms_list) do        ---@type integer, AtomEntry
				lines[#lines + 1] = string.format(
					"### atom: %s (line %d, %d words)",
					atom.name, atom.line or 0, #((atom.paths or {}).word_events or {}))
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

--- @param atom AtomEntry
--- @return integer
local function decl_words(atom)
	local p = atom.paths or {} ---@type AtomPaths
	return #(p.word_events or {})
end

--- @param decls AtomEntry[]|nil
--- @return KindCounts
local function count_kinds(decls)
	local n = { atom = 0, atom_proc = 0, comp_bare = 0, comp_proc = 0 } ---@type KindCounts
	for _, a in ipairs(decls or {}) do                                  ---@type integer, AtomEntry
		if n[a.kind] ~= nil then n[a.kind] = n[a.kind] + 1 end
	end
	return n
end

--- @param key string|nil
--- @return string|nil
local function slot_suffix(key)
	if type(key) ~= "string" or key:sub(1, 7) ~= "reguse:" then return nil end
	return key:match("([^:]+)$")
end

--- @param view ModuleView
--- @return table<string, boolean>
local function decl_names(view)
	local names = {}                        ---@type table<string, boolean>  -- bag: atom name -> true
	for _, a in ipairs(view.decls or {}) do ---@type integer, AtomEntry
		if a.name then names[a.name] = true end
	end
	return names
end

--- @param path string|nil
--- @param view ModuleView
--- @return boolean
local function path_in_module(path, view)
	if type(path) ~= "string" or path == "" then return false end
	local norm = path:gsub("\\", "/")             ---@type string
	local dir  = (view.dir or ""):gsub("\\", "/") ---@type string
	if dir ~= "" and (norm == dir or norm:sub(1, #dir + 1) == dir .. "/") then
		return true
	end
	for _, src in ipairs(view.sources or {}) do ---@type integer, SourceFile
		if (src.path or ""):gsub("\\", "/") == norm then return true end
	end
	return false
end

--- @param dir string
--- @param dir_sources SourceFile[]|nil
--- @param corpus Corpus
--- @return ModuleView
local function build_module_view(dir, dir_sources, corpus)
	local decls = {}                           ---@type AtomEntry[]
	for _, src in ipairs(dir_sources or {}) do ---@type integer, SourceFile
		for _, a in ipairs((src.scan and src.scan.atoms) or {}) do ---@type integer, AtomEntry
			if not a.source_path then a.source_path = src.path end
			decls[#decls + 1] = a
		end
	end
	local dir_basename = source_basename(dir)                             ---@type string
	local sa = (corpus.static_analysis_results or {})[dir_basename] or {} ---@type AtomAnalysis
	local schemas = {}                                                    ---@type RegUseSchema[]
	for name, schema in pairs(corpus.reg_use_schemas or {}) do            ---@type string, RegUseSchema
		for _, a in ipairs(decls) do ---@type integer, AtomEntry
			if a.reg_use_schema_name == name then
				schemas[#schemas + 1] = schema
				break
			end
		end
	end
	return {
		dir      = dir,
		sources  = dir_sources or {},
		decls    = decls,
		schemas  = schemas,
		findings = sa.findings or {},
		corpus   = corpus,
	}
end

--- @param add fun(s: string): nil
--- @param view ModuleView
--- @return nil
local function render_section_declarations(add, view)
	if #view.decls == 0 then add("_(none)_"); add(""); return end
	add("| kind | name | source | line | words | min | max | branches | paths |")
	add("|------|------|--------|------|-------|-----|-----|----------|-------|")
	for _, a in ipairs(view.decls) do ---@type integer, AtomEntry
		local p = a.paths or {} ---@type AtomPaths
		add(string.format("| %s | %s | %s | %d | %d | %s | %s | %s | %s |",
			a.kind or "?",
			a.name or "?",
			source_basename(a.source_path or ""),
			a.line or 0,
			decl_words(a),
			tostring(p.cycles_min or "—"),
			tostring(p.cycles_max or "—"),
			tostring(p.branches or "—"),
			tostring(p.paths or "—")))
	end
	add("")
end

--- @param add fun(s: string): nil
--- @param view ModuleView
--- @return nil
local function render_section_components(add, view)
	local rows = {}                                                        ---@type ComponentReportRow[]
	local index = (view.corpus and view.corpus.component_body_index) or {} ---@type table<string, ComponentBodyEntry>
	for _, a in ipairs(view.decls) do                                      ---@type integer, AtomEntry
		if a.kind == "comp_bare" or a.kind == "comp_proc" then
			local idx = index[a.name] or {}  ---@type ComponentBodyEntry
			local args = idx.arg_names or {} ---@type string[]
			rows[#rows + 1] = {
				name = a.name,
				kind = a.kind,
				args = table.concat(args, ", "),
				words = decl_words(a),
				map = a.map_command or "—",
			}
		end
	end
	if #rows == 0 then add("_(none)_"); add(""); return end
	add("| name | kind | arg_names | words | map |")
	add("|------|------|-----------|-------|-----|")
	for _, r in ipairs(rows) do ---@type integer, ComponentReportRow
		add(string.format("| %s | %s | %s | %d | %s |",
			r.name, r.kind, r.args ~= "" and r.args or "—", r.words, r.map))
	end
	add("")
end

--- @param add fun(s: string): nil
--- @param view ModuleView
--- @return nil
local function render_section_reguse(add, view)
	local wrote = false                            ---@type boolean
	for _, schema in ipairs(view.schemas or {}) do ---@type integer, RegUseSchema
		wrote = true
		add(string.format("### %s", schema.name or "?"))
		for _, slot in ipairs(schema.slots or {}) do ---@type integer, RegUseSlot
			local aliases = table.concat(slot.aliases or { slot.name }, ", ") ---@type string
			local ro = slot.readonly and " readonly" or ""                    ---@type string
			add(string.format("- slot `%s` aliases %s%s", slot.name, aliases, ro))
		end
		for _, a in ipairs(view.decls) do ---@type integer, AtomEntry
			if a.reg_use_schema_name == schema.name then
				add(string.format("- bound `%s` param `%s`", a.name, a.reg_use_param_name or "?"))
			end
		end
		add("")
	end
	local bound = {}                               ---@type table<string, boolean>  -- bag: schema name -> true
	for _, schema in ipairs(view.schemas or {}) do ---@type integer, RegUseSchema
		if schema.name then bound[schema.name] = true end
	end
	local errors = {}                                                           ---@type RegUseError[]
	for _, err in ipairs((view.corpus and view.corpus.reg_use_errors) or {}) do ---@type integer, RegUseError
		if bound[err.schema_name] or path_in_module(err.source_file, view) then
			errors[#errors + 1] = err
		end
	end
	if #errors > 0 then
		wrote = true
		add("### parse errors")
		for _, err in ipairs(errors) do ---@type integer, RegUseError
			add(string.format("- `%s` %s", err.kind or "?", err.schema_name or ""))
		end
		add("")
	end
	if not wrote then add("_(none)_"); add("") end
end

--- @param add fun(s: string): nil
--- @param view ModuleView
--- @return nil
local function render_section_annotations(add, view)
	local rows = {}                       ---@type AnnotReportRow[]
	for _, src in ipairs(view.sources) do ---@type integer, SourceFile
		for _, info in ipairs((src.scan and src.scan.atom_infos) or {}) do ---@type integer, AtomInfoEntry
			rows[#rows + 1] = {
				source = source_basename(src.path),
				line   = info.info_line or 0,
				name   = info.atom_name or "?",
				binds  = info.binds or "—",
				reads  = (#(info.reads or {}) > 0 and table.concat(info.reads, ",")) or "—",
				writes = (#(info.writes or {}) > 0 and table.concat(info.writes, ",")) or "—",
				phase  = info.phase or "—",
			}
		end
	end
	if #rows == 0 then add("_(none)_"); add(""); return end
	add("| source | line | name | binds | reads | writes | phase |")
	add("|--------|------|------|-------|-------|--------|-------|")
	for _, r in ipairs(rows) do ---@type integer, AnnotReportRow
		add(string.format("| %s | %d | %s | %s | %s | %s | %s |",
			r.source, r.line, r.name, r.binds, r.reads, r.writes, r.phase))
	end
	add("")
end

--- @param add fun(s: string): nil
--- @param view ModuleView
--- @return nil
local function render_section_component_annotations(add, view)
	local rows = {}                       ---@type CompAnnotReportRow[]
	for _, src in ipairs(view.sources) do ---@type integer, SourceFile
		for _, info in ipairs((src.scan and src.scan.component_atom_infos) or {}) do ---@type integer, AtomInfoEntry
			rows[#rows + 1] = {
				source = source_basename(src.path),
				line   = info.info_line or 0,
				name   = info.atom_name or "?",
				reads  = (#(info.reads or {}) > 0 and table.concat(info.reads, ",")) or "—",
				writes = (#(info.writes or {}) > 0 and table.concat(info.writes, ",")) or "—",
			}
		end
	end
	if #rows == 0 then add("_(none)_"); add(""); return end
	add("| source | line | name | reads | writes |")
	add("|--------|------|------|-------|--------|")
	for _, r in ipairs(rows) do ---@type integer, CompAnnotReportRow
		add(string.format("| %s | %d | %s | %s | %s |",
			r.source, r.line, r.name, r.reads, r.writes))
	end
	add("")
end

--- @param add fun(s: string): nil
--- @param view ModuleView
--- @return nil
local function render_section_binds(add, view)
	local wrote = false                   ---@type boolean
	for _, src in ipairs(view.sources) do ---@type integer, SourceFile
		for _, b in ipairs((src.scan and src.scan.binds) or {}) do ---@type integer, BindsEntry
			wrote = true
			add(string.format("### %s (%s:%s, %s bytes)",
				b.name, source_basename(src.path), tostring(b.line or 0), tostring(b.bytes or "—")))
			for _, f in ipairs(b.fields or {}) do ---@type integer, TypeField
				add(string.format("- `+%s %s`", tostring(f.offset or "?"), f.name or "?"))
			end
			add("")
		end
	end
	if not wrote then add("_(none)_"); add("") end
end

--- @param add fun(s: string): nil
--- @param view ModuleView
--- @return nil
local function render_section_phases(add, view)
	local corpus = view.corpus or {}                       ---@type Corpus
	local names  = decl_names(view)                        ---@type table<string, boolean>
	local wrote  = false                                   ---@type boolean
	for phase, entry in pairs(corpus.atom_phases or {}) do ---@type string, AtomPhaseGroup
		local here = {}                                  ---@type string[]
		for _, atom_name in ipairs(entry.atoms or {}) do ---@type integer, string
			if names[atom_name] then here[#here + 1] = atom_name end
		end
		if #here > 0 then
			wrote = true
			add(string.format("- phase `%s`: %s", phase, table.concat(here, ", ")))
		end
	end
	for name, entry in pairs(corpus.atom_views or {}) do ---@type string, AtomViewEntry
		if names[name] then
			wrote = true
			add(string.format("- view `%s` binds `%s`", name, entry.binds_name or "—"))
		end
	end
	for name, entry in pairs(corpus.atom_ctxs or {}) do ---@type string, AtomCtxEntry
		if names[name] then
			wrote = true
			add(string.format("- ctx `%s` rbind `%s`", name, entry.rbind_atom or "—"))
		end
	end
	if not wrote then add("_(none)_") end
	add("")
end

--- @param add fun(s: string): nil
--- @param view ModuleView
--- @return nil
local function render_section_aliases(add, view)
	local names = {}                            ---@type string[]
	local seen  = {}                            ---@type table<string, AliasEntry>
	for _, src in ipairs(view.sources or {}) do ---@type integer, SourceFile
		for name, entry in pairs((src.scan and src.scan.register_alias_registry) or {}) do ---@type string, AliasEntry
			if not seen[name] then
				seen[name] = entry
				names[#names + 1] = name
			end
		end
	end
	table.sort(names)
	if #names == 0 then add("_(none)_"); add(""); return end
	add("| alias | type |")
	add("|-------|------|")
	for _, name in ipairs(names) do ---@type integer, string
		local e = seen[name] ---@type AliasEntry|nil
		add(string.format("| %s | %s |", name, (e and e.default_type) or "—"))
	end
	add("")
end

--- @param add fun(s: string): nil
--- @param view ModuleView
--- @return nil
local function render_section_autoreg(add, view)
	local allowed = decl_names(view)                                              ---@type table<string, boolean>
	for phase, entry in pairs((view.corpus and view.corpus.atom_phases) or {}) do ---@type string, AtomPhaseGroup
		for _, atom_name in ipairs(entry.atoms or {}) do ---@type integer, string
			if allowed[atom_name] then allowed[phase] = true end
		end
	end
	local wrote = false ---@type boolean
	local seen  = {}    ---@type table<string, boolean>  -- bag: label\\0scope -> already dumped
	--- @param label string
	--- @param table_map table<string, GprAllocMap>|nil
	--- @return nil
	local function dump(label, table_map)
		local scopes = {}                      ---@type string[]
		for scope in pairs(table_map or {}) do ---@type string
			if allowed[scope] and not seen[label .. "\0" .. scope] then
				scopes[#scopes + 1] = scope
			end
		end
		table.sort(scopes)
		for _, scope in ipairs(scopes) do ---@type integer, string
			seen[label .. "\0" .. scope] = true
			wrote = true
			local syms = {}                                  ---@type string[]
			for sym, gpr in pairs(table_map[scope] or {}) do ---@type string, string
				if type(gpr) == "string" and gpr ~= sym then
					syms[#syms + 1] = string.format("%s → %s", sym, gpr)
				else
					syms[#syms + 1] = tostring(sym)
				end
			end
			table.sort(syms)
			add(string.format("- %s `%s`: %s", label, scope, table.concat(syms, ", ")))
		end
	end
	local corpus = view.corpus or {} ---@type Corpus
	dump("atom", corpus.atom_auto_regs)
	dump("phase", corpus.phase_auto_regs)
	for _, src in ipairs(view.sources or {}) do ---@type integer, SourceFile
		dump("atom", src.scan and src.scan.atom_auto_regs)
		dump("phase", src.scan and src.scan.phase_auto_regs)
	end
	if not wrote then add("_(none)_") end
	add("")
end

--- @param add fun(s: string): nil
--- @param view ModuleView
--- @return nil
local function render_section_collisions(add, view)
	local rows = {}                                                       ---@type CorpusCollision[]
	for _, c in ipairs((view.corpus and view.corpus.collisions) or {}) do ---@type integer, CorpusCollision
		local first = c.first_site or {}       ---@type CollisionSite
		local other = c.conflicting_site or {} ---@type CollisionSite
		if path_in_module(first.path, view) or path_in_module(other.path, view) then
			rows[#rows + 1] = c
		end
	end
	if #rows == 0 then add("_(none)_"); add(""); return end
	for _, c in ipairs(rows) do ---@type integer, CorpusCollision
		local first = c.first_site or {}       ---@type CollisionSite
		local other = c.conflicting_site or {} ---@type CollisionSite
		add(string.format("- `%s` `%s` first %s:%s conflict %s:%s",
			c.kind or "?", c.name or "?",
			tostring(first.path or "?"), tostring(first.line or "?"),
			tostring(other.path or "?"), tostring(other.line or "?")))
	end
	add("")
end

--- @param add fun(s: string): nil
--- @param view ModuleView
--- @return nil
local function render_section_findings(add, view)
	local by_atom = {}                         ---@type table<string, CheckFinding[]>
	for _, f in ipairs(view.findings or {}) do ---@type integer, CheckFinding
		local key = f.atom or "?" ---@type string
		by_atom[key] = by_atom[key] or {}
		by_atom[key][#by_atom[key] + 1] = f
	end
	if next(by_atom) == nil then add("_(none)_"); add(""); return end
	local seen = {} ---@type table<string, boolean>  -- bag: atom name already emitted
	--- @param name string
	--- @param fs CheckFinding[]
	--- @return nil
	local function emit(name, fs)
		add("### " .. name)
		for _, f in ipairs(fs) do ---@type integer, CheckFinding
			local msg = f.msg or ""                                       ---@type string
			local slot = slot_suffix(f.gpr_key or f.producer_destination) ---@type string|nil
			if slot and not msg:find("(slot ", 1, true) then
				msg = msg .. " (slot " .. slot .. ")"
			end
			add(string.format("- `[%s/%s] %s`", f.kind or "info", f.check or "?", msg))
		end
		add("")
	end
	for _, a in ipairs(view.decls) do ---@type integer, AtomEntry
		if by_atom[a.name] then
			seen[a.name] = true
			emit(a.name, by_atom[a.name])
		end
	end
	local leftovers = {}          ---@type string[]
	for name in pairs(by_atom) do ---@type string
		if not seen[name] then leftovers[#leftovers + 1] = name end
	end
	table.sort(leftovers)
	for _, name in ipairs(leftovers) do emit(name, by_atom[name]) end ---@type integer, string
end

--- @param add fun(s: string): nil
--- @param view ModuleView
--- @return nil
local function render_section_relations(add, view)
	local wrote = false               ---@type boolean
	for _, a in ipairs(view.decls) do ---@type integer, AtomEntry
		local rels = (a.paths and a.paths.relations) or {} ---@type AtomRelation[]
		if #rels > 0 then
			wrote = true
			add("### " .. a.name)
			for _, rel in ipairs(rels) do ---@type integer, AtomRelation
				local dest = rel.destination or rel.producer_destination or "—" ---@type string
				local slot = slot_suffix(dest)                                    ---@type string|nil
				local dest_s = tostring(dest)                                     ---@type string
				if slot then dest_s = dest_s .. " (slot " .. slot .. ")" end
				add(string.format("- `%s` words %s → %s dest %s",
					rel.semantic or "?",
					tostring(rel.producer_word or "?"),
					tostring(rel.consumer_word or "?"),
					dest_s))
			end
			add("")
		end
	end
	if not wrote then add("_(none)_"); add("") end
end

local HIDDEN_UNLESS_WRITTEN = { ---@type table<string, boolean>  -- bag: GPR key hidden unless an encoder wrote it
	R_AT = true, R_TapePtr = true, R_AtomJmp = true,
}

local PHYSICAL_GPR = { ---@type table<string, boolean>  -- bag: physical GPR alias -> true
	R_T0 = true, R_T1 = true, R_T2 = true, R_T3 = true,
	R_T4 = true, R_T5 = true, R_T6 = true, R_T7 = true,
	R_V0 = true, R_V1 = true,
}

--- @param atom AtomEntry
--- @param key string
--- @return boolean
local function encoder_wrote_key(atom, key)
	for _, ev in ipairs((atom.paths and atom.paths.word_events) or {}) do ---@type integer, WordEvent
		for _, dest in pairs(ev.gpr_keys or {}) do ---@type integer|string, string
			if dest == key then return true end
		end
	end
	return false
end

--- @param key string
--- @param atom AtomEntry
--- @return string
local function written_name_for(key, atom)
	local slot = key:match("^reguse:.+:(.+)$") ---@type string|nil
	if slot then
		local param = atom.reg_use_param_name ---@type string|nil
		if param and param ~= "" then return param .. "." .. slot end
		return slot
	end
	return key
end

--- @param key string
--- @param atom AtomEntry
--- @param view ModuleView
--- @return string
local function aliases_for_key(key, atom, view)
	local slot = key:match("^reguse:.+:(.+)$") ---@type string|nil
	if not slot then return "—" end
	local schema_name = atom.reg_use_schema_name                                                            ---@type string|nil
	local schema = view.corpus and view.corpus.reg_use_schemas and view.corpus.reg_use_schemas[schema_name] ---@type RegUseSchema|nil
	if not schema then return "—" end
	for _, s in ipairs(schema.slots or {}) do ---@type integer, RegUseSlot
		if s.name == slot then
			local names = {}                           ---@type string[]
			for _, alias in ipairs(s.aliases or {}) do ---@type integer, string
				if alias ~= slot then names[#names + 1] = alias end
			end
			if #names == 0 then
				if s.aliases and #s.aliases > 0 then return table.concat(s.aliases, ", ") end
				return "—"
			end
			return table.concat(names, ", ")
		end
	end
	return "—"
end

--- @param key string
--- @param atom AtomEntry
--- @param view ModuleView
--- @return string
local function physical_for_key(key, atom, view)
	if PHYSICAL_GPR[key] then return key end
	local corpus = view.corpus or {}                          ---@type Corpus
	local alias = (corpus.register_alias_registry or {})[key] ---@type AliasEntry|string|nil
	if type(alias) == "table" then
		local phys = alias.physical or alias.gpr or alias.code_name ---@type string|nil
		if type(phys) == "string" and PHYSICAL_GPR[phys] then return phys end
		if type(alias.name) == "string" and PHYSICAL_GPR[alias.name] then return alias.name end
	elseif type(alias) == "string" and PHYSICAL_GPR[alias] then
		return alias
	end
	local atom_map = (corpus.atom_auto_regs or {})[atom.name] ---@type GprAllocMap|nil
	if type(atom_map) == "table" then
		local slot = key:match("^reguse:.+:(.+)$") or key      ---@type string
		local bound = atom_map[slot] or atom_map["R_" .. slot] ---@type string|nil
		if type(bound) == "string" and PHYSICAL_GPR[bound] then return bound end
	end
	return "—"
end

--- @param key string
--- @param atom AtomEntry
--- @return string
local function last_relation_for(key, atom)
	local last = nil                                                     ---@type AtomRelation|nil
	for _, rel in ipairs((atom.paths and atom.paths.relations) or {}) do ---@type integer, AtomRelation
		local dest = rel.destination or rel.producer_destination ---@type string|nil
		if dest == key then last = rel end
	end
	if not last then return "—" end
	local sem = last.semantic or "?" ---@type string
	local a = last.producer_word     ---@type integer|nil
	local b = last.consumer_word     ---@type integer|nil
	if a and b then return string.format("%s w%s→%s", sem, tostring(a), tostring(b)) end
	return sem
end

--- @param add fun(s: string): nil
--- @param view ModuleView
--- @return nil
local function render_section_forward(add, view)
	local wrote = false               ---@type boolean
	for _, a in ipairs(view.decls) do ---@type integer, AtomEntry
		local gpr = a.paths and a.paths.forward_state and a.paths.forward_state.gpr_values ---@type table<string, GprLatticeSlot>|nil
		local keys = {}                                                                    ---@type string[]
		for k in pairs(gpr or {}) do                                                       ---@type string
			if k == "R_0" then
				-- hidden
			elseif HIDDEN_UNLESS_WRITTEN[k] and not encoder_wrote_key(a, k) then
				-- hidden
			else
				keys[#keys + 1] = k
			end
		end
		if #keys > 0 then
			wrote = true
			add("### " .. a.name)
			add("| written | aliases | physical | lattice | last relation |")
			add("|---|---|---|---|---|")
			table.sort(keys)
			for _, k in ipairs(keys) do ---@type integer, string
				local slot = gpr[k]   ---@type GprLatticeSlot|nil
				local lattice = "—" ---@type string
				if slot and slot.kind == "constant" then
					lattice = tostring(slot.value)
				end
				add(string.format("| `%s` | %s | %s | %s | %s |",
					written_name_for(k, a),
					aliases_for_key(k, a, view),
					physical_for_key(k, a, view),
					lattice,
					last_relation_for(k, a)))
			end
			add("")
		end
	end
	if not wrote then add("_(none)_"); add("") end
end

local SECTION_RENDERERS = { ---@type SectionRenderer[]
	{ header = "## Declarations",          render = render_section_declarations },
	{ header = "## Components",            render = render_section_components },
	{ header = "## RegUse schemas",        render = render_section_reguse },
	{ header = "## Annotations",           render = render_section_annotations },
	{ header = "## Component annotations", render = render_section_component_annotations },
	{ header = "## Binds_* structs",       render = render_section_binds },
	{ header = "## Phases / views / ctx",  render = render_section_phases },
	{ header = "## Register aliases",      render = render_section_aliases },
	{ header = "## Auto-reg",              render = render_section_autoreg },
	{ header = "## Collisions",            render = render_section_collisions },
	{ header = "## Findings",              render = render_section_findings },
	{ header = "## Relations",             render = render_section_relations },
	{ header = "## GPR model",             render = render_section_forward },
}

--- Render the consolidated per-module markdown (`build/<module>.atom_meta_report.md`).
--- One ModuleView from the corpus; SECTION_RENDERERS walks it.
--- @param view ModuleView
--- @return string
local function render_module_meta_report(view)
	local dir_basename = source_basename(view.dir) ---@type string
	local lines        = {                         ---@type string[]
		"# " .. dir_basename .. " — atom meta report",
		"> Auto-generated by ps1_meta.lua (passes/report.lua). Do not edit.",
		"",
	}
	--- @param s string
	--- @return nil
	local function add(s) lines[#lines + 1] = s end

	local kinds = count_kinds(view.decls)      ---@type KindCounts
	local n_annot, n_binds, n_macros = 0, 0, 0 ---@type integer, integer, integer
	for _, src in ipairs(view.sources) do      ---@type integer, SourceFile
		n_annot  = n_annot  + #((src.scan and src.scan.atom_infos) or {})
		n_binds  = n_binds  + #((src.scan and src.scan.binds) or {})
		n_macros = n_macros + #((src.scan and src.scan.macros) or {})
	end
	local n_err, n_warn, n_info = 0, 0, 0      ---@type integer, integer, integer
	for _, f in ipairs(view.findings or {}) do ---@type integer, CheckFinding
		if     f.kind == "error"   then n_err  = n_err  + 1
		elseif f.kind == "warning" then n_warn = n_warn + 1
		else                            n_info = n_info + 1
		end
	end

	add("## Module summary"); add("")
	add("| metric | value |"); add("|--------|-------|")
	add(string.format("| sources | %d |", #view.sources))
	add(string.format("| decls | %d (atom: %d, atom_proc: %d, comp_bare: %d, comp_proc: %d) |",
		#view.decls, kinds.atom, kinds.atom_proc, kinds.comp_bare, kinds.comp_proc))
	add(string.format("| annotations | %d |", n_annot))
	add(string.format("| binds structs | %d |", n_binds))
	add(string.format("| macro decls | %d |", n_macros))
	add(string.format("| findings | %d (errors: %d, warnings: %d, info: %d) |",
		#(view.findings or {}), n_err, n_warn, n_info))
	add("")

	add("## Sources"); add("")
	for _, s in ipairs(view.sources) do add("- `" .. s.path .. "`") end ---@type integer, SourceFile
	add("")

	for _, row in ipairs(SECTION_RENDERERS) do ---@type integer, SectionRenderer
		add(row.header); add("")
		row.render(add, view)
	end

	return table.concat(lines, "\n") .. "\n"
end

-- ════════════════════════════════════════════════════════════════════════════
-- REPORT_RENDERERS — data-driven report dispatch (one row per file kind)
-- ════════════════════════════════════════════════════════════════════════════
-- `once = true` means render once at the project level (not per-module).
-- `basename(dir_basename)` yields the file's basename for that kind.
-- `gather(ctx, dir, dir_sources [, all_modules])` returns the rendered string.
local REPORT_RENDERERS = { ---@type ReportRenderer[]
	{
		name     = "atom_meta_report",
		ext      = "md",
		--- @param dir_basename string
		--- @return string
		basename = function(dir_basename) return dir_basename .. ".atom_meta_report" end,
		once     = false,
		--- @param ctx PassCtx
		--- @param dir string
		--- @param dir_sources SourceFile[]
		--- @return string
		gather   = function(ctx, dir, dir_sources)
			local corpus = ctx.shared.corpus ---@type Corpus
			return render_module_meta_report(build_module_view(dir, dir_sources, corpus))
		end,
	},
	{
		name     = "atoms",
		ext      = "md",
		--- @param dir_basename string
		--- @return string
		basename = function(dir_basename) return dir_basename .. ".atoms" end,
		once     = false,
		--- @param ctx PassCtx
		--- @param dir string
		--- @param dir_sources SourceFile[]
		--- @return string
		gather   = function(ctx, dir, dir_sources)
			return render_module_atoms_md(dir, dir_sources,
				ctx.shared.corpus.word_counts or {})
		end,
	},
	{
		name     = "summary",
		ext      = "md",
		--- @param _dir_basename string
		--- @return string
		basename = function(_dir_basename) return "atom_meta_report.summary" end,
		once     = true,
		--- @param _ctx PassCtx
		--- @param _dir string|nil
		--- @param _dir_sources SourceFile[]|nil
		--- @param all_modules ProjectSummaryRow[]
		--- @return string
		gather   = function(_ctx, _dir, _dir_sources, all_modules)
			return render_project_summary(all_modules)
		end,
	},
}

-- ════════════════════════════════════════════════════════════════════════════
-- M — public pass surface
-- ════════════════════════════════════════════════════════════════════════════

local M = {} ---@type ReportPass

--- Run the report pass. Emits 1 `atom_meta_report.summary.md` per build + 2 `atom_meta_report.md` + 2 `atoms.md` files per module (duffle + gte_hello).
--- Reads `corpus.static_analysis_results` (added in Phase 1) to populate per-module findings without re-running validate().
--- @param ctx PassCtx
--- @return PassResult
function M.run(ctx)
	local outputs = {}                                       ---@type PassOutputEntry[]
	local corpus  = ctx.shared and ctx.shared.corpus         ---@type Corpus|nil
	local by_dir  = (corpus and corpus.sources_by_dir) or {} ---@type table<string, SourceFile[]>

	-- `out_path_root`: when the conventional `out_root` is `build/gen` (any spelling — relative, absolute, separator variants).
	-- Write the md files to `build/` (parent of `gen/`) instead of nested under `gen/`.
	-- Mirrors the `gdb_tape_atoms_runtime.gdb` relocation.
	--- @param p string|nil
	--- @return boolean
	local function ends_with_gen(p)
		return type(p) == "string" and (p:match("[/\\]gen[/\\]?$") ~= nil
			or p == "build/gen" or p == "build\\gen")
	end
	local out_root_effective = ends_with_gen(ctx.out_root) ---@type string
		and ctx.out_root:gsub("[/\\]gen[/\\]?$", "")
		or ctx.out_root

	duffle.ensure_dir(out_root_effective)

	-- Aggregator for the project-wide `once = true` summary renderer.
	local all_modules = {} ---@type ProjectSummaryRow[]

	for dir, dir_sources in pairs(by_dir) do ---@type string, SourceFile[]
		local dir_basename = dir:match("([^/\\]+)$") or dir ---@type string

		-- Per-renderer dispatch for the per-module renderers (once = false).
		for _, renderer in ipairs(REPORT_RENDERERS) do ---@type integer, ReportRenderer
			if not renderer.once then
				local body     = renderer.gather(ctx, dir, dir_sources)                                              ---@type string
				local out_path = out_root_effective .. "/" .. renderer.basename(dir_basename) .. "." .. renderer.ext ---@type string
				duffle.write_file(out_path, body)
				outputs[#outputs + 1] = { kind = renderer.name, path = out_path }
			end
		end

		local view = build_module_view(dir, dir_sources, corpus) ---@type ModuleView
		local n_annot, n_binds, n_macros = 0, 0, 0               ---@type integer, integer, integer
		for _, src in ipairs(dir_sources) do                     ---@type integer, SourceFile
			n_annot  = n_annot  + #((src.scan and src.scan.atom_infos) or {})
			n_binds  = n_binds  + #((src.scan and src.scan.binds) or {})
			n_macros = n_macros + #((src.scan and src.scan.macros) or {})
		end
		local n_err, n_warn, n_info = 0, 0, 0      ---@type integer, integer, integer
		for _, f in ipairs(view.findings or {}) do ---@type integer, CheckFinding
			if     f.kind == "error"   then n_err  = n_err  + 1
			elseif f.kind == "warning" then n_warn = n_warn + 1
			else                            n_info = n_info + 1
			end
		end
		all_modules[#all_modules + 1] = {
			module   = dir_basename,
			atoms    = #view.decls,
			annots   = n_annot,
			binds    = n_binds,
			macros   = n_macros,
			findings = #(view.findings or {}),
			errors   = n_err,
			warnings = n_warn,
			info     = n_info,
		}
	end

	-- Project-wide renderer (once = true): write the summary file.
	for _, renderer in ipairs(REPORT_RENDERERS) do ---@type integer, ReportRenderer
		if renderer.once then
			local body     = renderer.gather(ctx, nil, nil, all_modules)                               ---@type string
			local out_path = out_root_effective .. "/" .. renderer.basename("") .. "." .. renderer.ext ---@type string
			duffle.write_file(out_path, body)
			outputs[#outputs + 1] = { kind = renderer.name, path = out_path }
		end
	end

	return { outputs = outputs, errors = {}, warnings = {} }
end

return M
