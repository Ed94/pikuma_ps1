--- passes/annotation.lua — Atom-annotation DSL validator.
---
--- Validates `MipsAtom_(name) atom_info(atom_bind(Binds_X), atom_reads(...), atom_writes(...)) { ... }` declarations in source files.
--- Also reads: `Binds_*` struct declarations (`typedef Struct_(Binds_X) { ... };`)
---
--- Source scanning: done ONCE upstream by `duffle.scan_source()` (ps1_meta.lua pre-scans each source and stashes the result in `src.scan`). 
---
--- Writes:
---   - `<ctx.out_root>/<dir_basename>.errors.h` — one per module, with `#error` directives on findings (the C compile will surface the error)
---   - The annotations.txt report is rendered by `passes/report.lua` from the per-module results stashed in `ctx.flags._annot_results`
---
--- **Conventions**: tabs (1/level), EmmyLua annotations, no regex, Lua 5.3 compatible

-- Bootstrap: same as entry scripts. See `ps1_meta.lua` for the rationale.
-- Bootstrap: load `scripts/duffle_paths.lua` (sets package.path + package.cpath).
-- Uses `debug.getinfo` to find this file's own directory, so it works
-- both standalone and when require'd from the orchestrator.
-- Bootstrap: load `duffle_paths.lua` via `debug.getinfo(1, "S").source` (works both standalone + when require'd).
-- duffle_paths.lua sets package.path then returns `require("duffle")` at the bottom, so the dofile value IS the duffle module.
local _bootstrap_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local duffle         = dofile(_bootstrap_dir .. "../duffle_paths.lua")
local write_file     = duffle.write_file
local ensure_dir     = duffle.ensure_dir

-- Domain tables (single source of truth in duffle.lua).
local WAVE_CONTEXT_REGS = duffle.WAVE_CONTEXT_REGS

local function is_wave_context_reg(n) return WAVE_CONTEXT_REGS[n] ~= nil  end

-- ════════════════════════════════════════════════════════════════════════════
-- Type declarations
-- ════════════════════════════════════════════════════════════════════════════

--- @class SourceFile
--- @field path     string  -- absolute path to the source file
--- @field text     string  -- the full source text
--- @field dir      string  -- the directory containing the source
--- @field basename string  -- filename without extension
--- @field scan     table   -- pre-scanned SourceScan payload (from duffle.scan_source)

--- @class PassCtx
--- @field sources            SourceFile[]
--- @field metadata_path      string
--- @field shared             table
--- @field shared.word_counts table<string, integer>
--- @field out_root           string
--- @field project_root       string
--- @field upstream           table<string, table>
--- @field flags              table
--- @field flags._annot_results table[]   -- stashed by annotation pass; consumed by report.lua
--- @field dry_run            boolean
--- @field verbose            boolean

--- @class PassResult
--- @field outputs  table[]
--- @field errors   table[]
--- @field warnings table[]

--- @class AtomAnnotation
--- @field line    integer       -- source line of the atom_info call
--- @field macro   string        -- the macro name (always "atom_info" in the new shape)
--- @field name    string        -- the atom name
--- @field kind    string        -- always "info"
--- @field binds   string|nil    -- Binds_X name if any
--- @field reads   string[]      -- R_* names (read targets)
--- @field writes  string[]      -- R_* names (write targets)
--- @field errors  string[]|nil  -- parse-time errors from scan_source (atom_info body malformed)

--- @class Finding
--- @field line integer  -- source line (or 0 for pass-level)
--- @field msg  string   -- finding message

--- @class Findings
--- @field errors   Finding[]
--- @field warnings Finding[]
--- @field info     Finding[]

--- @class PipeCtx
--- @field atom_index   table<string, AtomAnnotation>  -- name -> AtomAnnotation (only kind=="atom")
--- @field binds_index  table<string, BindsStruct>     -- name -> BindsStruct
--- @field annot_counts table<string, integer>          -- name -> annotation count (for unique_annotation check)

--- @class AnnotatedResult
--- @field atoms    AtomEntry[]
--- @field annots   AtomAnnotation[]
--- @field macros   MacroEntry[]
--- @field binds    BindsEntry[]
--- @field errors   Finding[]
--- @field warnings Finding[]
--- @field info     Finding[]

-- ════════════════════════════════════════════════════════════════════════════
-- Per-check functions (the CHECK_RULES table's payload)
-- ════════════════════════════════════════════════════════════════════════════
--
-- Each check has a uniform `append_to_findings` shape (errors[] / warnings[] / info[]).
-- The dispatcher in `validate()` decides which findings list each check writes to — by convention,
-- "existence" checks (declaration must exist, struct must exist) write errors[]; "shape" checks
-- (writes/reads must be wave-context) write warnings[]. The `macro_word_drift` check writes
-- both errors[] (missing/mismatch) and info[] (match).

--- Check: every annotated atom must have a matching MipsAtom_(name) declaration.
--- @param a AtomAnnotation
--- @param pipe_ctx PipeCtx
--- @param findings Findings
local function check_atom_decl_exists(a, pipe_ctx, findings)
	if not pipe_ctx.atom_index[a.name] then
		findings.errors[#findings.errors + 1] = {
			line = a.line,
			msg  = string.format("annotation for '%s' has no matching MipsAtom_(%s) { ... }", a.name, a.name),
		}
	end
end

--- Check: every atom may have AT MOST ONE annotation.
--- Post-loop: needs full-corpus `annot_counts` from pipe_ctx.
--- @param pipe_ctx PipeCtx
--- @param findings Findings
local function check_unique_annotation(pipe_ctx, findings)
	for name, n in pairs(pipe_ctx.annot_counts) do
		if n > 1 then
			findings.errors[#findings.errors + 1] = {
				line = pipe_ctx.atom_index[name] and pipe_ctx.atom_index[name].line or 0,
				msg  = string.format("MipsAtom_(%s) has %d annotations (expected at most 1)", name, n),
			}
		end
	end
end

--- Check: BIND atoms must reference a real Binds_* struct.
--- Demoted from error to warning (2026-07-10): the same condition is now caught by passes/static_analysis.lua's
--- check_abi_handoff() as an error. Emitting a warning here keeps the annotation pass from being stop-on-error
--- for the common test-fixture case, while still surfacing the issue in the report.
--- The static-analysis report remains the source of truth for build-stopping errors.
--- @param a AtomAnnotation
--- @param pipe_ctx PipeCtx
--- @param findings Findings
local function check_binds_struct_exists(a, pipe_ctx, findings)
	if not a.binds then return end
	if pipe_ctx.binds_index[a.binds] then return end
	findings.warnings[#findings.warnings + 1] = {
		line = a.line,
		msg  = string.format("'%s' binds '%s' but no Struct_(%s) { ... } " 
			.. "declaration found (also flagged as an error by check_abi_handoff in the static-analysis pass)"
			, a.name, a.binds, a.binds),
	}
end

--- Check: Binds_* struct fields must correspond to known wave-context registers.
--- Also checks that all `atom_writes(...)` entries are wave-context registers.
--- @param a AtomAnnotation
--- @param pipe_ctx PipeCtx
--- @param findings Findings
local function check_binds_field_wave_context(a, pipe_ctx, findings)
	if not (a.binds and pipe_ctx.binds_index[a.binds]) then return end
	local bs = pipe_ctx.binds_index[a.binds]

	for _, f in ipairs(bs.fields) do
		local candidate = "R_" .. f.name
		if not is_wave_context_reg(candidate) then
			findings.warnings[#findings.warnings + 1] = {
				line = bs.line,
				msg  = string.format("%s field '%s' doesn't match a known wave-context register (candidate '%s')", a.binds, f.name, candidate),
			}
		end
	end

	for _, w in ipairs(a.writes) do
		if not is_wave_context_reg(w) then
			findings.warnings[#findings.warnings + 1] = {
				line = a.line,
				msg  = string.format("%s writes '%s' which is not a known wave-context register", a.name, w),
			}
		end
	end
end

--- Check: atom_reads(...) entries should be wave-context registers (or R_TapePtr for rbind).
--- @param a AtomAnnotation
--- @param pipe_ctx PipeCtx
--- @param findings Findings
local function check_reads_wave_context(a, pipe_ctx, findings)
	for _, r in ipairs(a.reads) do
		if not is_wave_context_reg(r) and r ~= "R_TapePtr" then
			findings.warnings[#findings.warnings + 1] = {
				line = a.line,
				msg  = string.format("atom '%s' reads '%s' which is not a known wave-context register", a.name, r),
			}
		end
	end
end

--- Check: TAPE_WORDS(mac_X, N) ↔ WORD_COUNT(mac_X, N) drift.
--- Three outcomes: missing (error), mismatch (error), match (info).
--- @param m MacroEntry
--- @param wc table<string, integer>  -- the shared word-count table (from ctx.shared.word_counts)
--- @param findings Findings
local function check_macro_word_drift(m, wc, findings)
	local declared = wc[m.name]
	if not declared then
		findings.errors[#findings.errors + 1] = {
			line = m.line,
			msg  = string.format("TAPE_WORDS(%s, %d) but '%s' is not in metadata.h", m.name, m.words, m.name),
		}
		return
	end
	if declared ~= m.words then
		findings.errors[#findings.errors + 1] = {
			line = m.line,
			msg  = string.format("DRIFT: TAPE_WORDS(%s, %d) but metadata.h declares WORD_COUNT(%s, %d)", m.name, m.words, m.name, declared),
		}
		return
	end
	findings.info[#findings.info + 1] = {
		line = m.line,
		msg  = string.format("OK: %s = %d words", m.name, m.words),
	}
end

-- ════════════════════════════════════════════════════════════════════════════
-- CHECK_RULES — data-driven check dispatch (the plex pattern)
-- ════════════════════════════════════════════════════════════════════════════
--
-- Each rule entry picks one of three "shapes" of dispatch:
--   per_annot(annot, pipe_ctx, findings) — runs once per AtomAnnotation
--   post(pipe_ctx, findings)             — runs once after all per_annot calls complete (full-corpus aggregation)
--   per_macro(macro, wc, findings)       — runs once per TAPE_WORDS / _Pragma macro declaration
--
-- Adding a new check = 1 row here + 1 function above. The `validate()` dispatch loop never needs editing.

local CHECK_RULES = {
	{ name = "atom_decl_exists",         per_annot = check_atom_decl_exists         },
	{ name = "binds_struct_exists",      per_annot = check_binds_struct_exists      },
	{ name = "binds_field_wave_context", per_annot = check_binds_field_wave_context },
	{ name = "reads_wave_context",       per_annot = check_reads_wave_context       },
	{ name = "unique_annotation",        post      = check_unique_annotation        },
	{ name = "macro_word_drift",         per_macro = check_macro_word_drift         },
}

-- ════════════════════════════════════════════════════════════════════════════
-- Validation
-- ════════════════════════════════════════════════════════════════════════════
--
-- Pure check: read from src.scan, run validations, emit findings.
-- No source walking; no parsing. The scan was done once upstream.

--- Validate one source against its pre-scanned SourceScan payload.
--- @param ctx PassCtx
--- @param src SourceFile
--- @return AnnotatedResult
local function validate(ctx, src)
	local scan = src.scan

	-- Project the pre-scanned atoms to the AtomEntry shape this pass needs.
	local atoms = {}
	for _, a in ipairs(scan.atoms) do
		if a.kind == "atom" then
			atoms[#atoms + 1] = { line = a.line, name = a.raw_name }
		end
	end

	-- Project the pre-scanned atom_infos to AtomAnnotation shape.
	local annots = {}
	for _, info in ipairs(scan.atom_infos) do
		annots[#annots + 1] = {
			line   = info.info_line,
			macro  = "atom_info",
			name   = info.atom_name,
			kind   = "info",
			binds  = info.binds,
			reads  = info.reads or {},
			writes = info.writes or {},
			errors = info.errors,
		}
	end

	-- Build pipe_ctx (Fleury: expose structure). Pre-compute everything the per-check functions need.
	-- Single source of truth for atom / binds / annotation-count lookups.
	local pipe_ctx = {
		atom_index   = {},
		binds_index  = {},
		annot_counts = {},
	}
	for _, a in ipairs(atoms)      do pipe_ctx.atom_index [a.name] = a end
	for _, b in ipairs(scan.binds) do pipe_ctx.binds_index[b.name] = b end
	for _, a in ipairs(annots)     do
		if a.name then
			pipe_ctx.annot_counts[a.name] = (pipe_ctx.annot_counts[a.name] or 0) + 1
		end
	end

	-- Findings live in a single struct with three lists (errors / warnings / info).
	-- Each check writes to the list appropriate for its severity.
	local findings = { errors = {}, warnings = {}, info = {} }

	-- Propagate parse-time errors from scan_source's atom_info parsing.
	-- These are errors found in the atom_info(...) body itself (e.g., malformed args).
	-- They are pre-existing in the scan payload — we just lift them into our findings list.
	for _, a in ipairs(annots) do
		if a.errors then
			for _, msg in ipairs(a.errors) do
				findings.errors[#findings.errors + 1] = {
					line = a.line,
					msg  = string.format("'%s': %s", a.name, msg),
				}
			end
		end
	end

	-- THE per-annotation pipeline. ONE loop. CHECK_RULES dispatches per_annot rules.
	for _, a in ipairs(annots) do
		for _, rule in ipairs(CHECK_RULES) do
			if rule.per_annot then rule.per_annot(a, pipe_ctx, findings) end
		end
	end

	-- Post-loop rules (one-shot checks that need full-corpus aggregation in pipe_ctx).
	for _, rule in ipairs(CHECK_RULES) do
		if rule.post then rule.post(pipe_ctx, findings) end
	end

	-- Per-macro rules (TAPE_WORDS vs WORD_COUNT drift).
	local wc = ctx.shared.word_counts
	for _, m in ipairs(scan.macros) do
		for _, rule in ipairs(CHECK_RULES) do
			if rule.per_macro then rule.per_macro(m, wc, findings) end
		end
	end

	-- Information summary (always emitted).
	findings.info[#findings.info + 1] = {
		line = 0,
		msg  = string.format("scanned: %d atom(s), %d annotation(s), %d macro-word-decl(s), %d binds struct(s)",
			#atoms, #annots, #scan.macros, #scan.binds),
	}

	return {
		atoms    = atoms,
		annots   = annots,
		macros   = scan.macros,
		binds    = scan.binds,
		errors   = findings.errors,
		warnings = findings.warnings,
		info     = findings.info,
	}
end

-- ════════════════════════════════════════════════════════════════════════════
-- Per-DIRECTORY (per-module) output: errors.h + annotations.txt
-- ════════════════════════════════════════════════════════════════════════════

--- Render `<dir_basename>.errors.h` with `#error` directives for every error found across all sources in the directory.
--- Empty directories (no errors, no atoms) produce no file.
local function emit_module_errors_h(ctx, dir_basename, atoms_count, errors, sources)
	if ctx.dry_run then return nil end
	if atoms_count == 0 and #errors == 0 then
		return nil
	end
	local out_path = ctx.out_root .. "/" .. dir_basename .. ".errors.h"
	local lines    = {
		"// Auto-generated by ps1_meta.lua (passes/annotation.lua) — DO NOT EDIT",
		string.format("// Module: %s   Sources: %d", dir_basename, #sources),
		"#pragma once",
		"",
	}
	if #errors == 0 then
		lines[#lines + 1] = "// annotation pass OK"
	else
		for _, e in ipairs(errors) do
			local src_tag = ""
			if e.source then
				local src_name = e.source:match("([^/\\]+)$") or e.source
				src_tag = src_name .. ": "
			end
			lines[#lines + 1] = string.format('#error "%s%s (line %d)"', src_tag, e.msg, e.line)
		end
	end
	ensure_dir(ctx.out_root)
	write_file(out_path, table.concat(lines, "\n") .. "\n")
	return out_path
end

--- Stash aggregated per-module results for the report pass to consume.
local function emit_module_annotations_stub(ctx, dir, dir_basename, atoms_count)
	ctx.flags                = ctx.flags                or {}
	ctx.flags._annot_results = ctx.flags._annot_results or {}
	ctx.flags._annot_results[#ctx.flags._annot_results + 1] = {
		dir          = dir,
		dir_basename = dir_basename,
		atoms_count  = atoms_count,
	}
end

-- ════════════════════════════════════════════════════════════════════════════
-- M.run — orchestrator entry
-- ════════════════════════════════════════════════════════════════════════════

--- @class M

local M = {}

-- Expose `validate` for downstream passes (e.g. report.lua) that need to re-render the per-source results into a per-MODULE report.
M.validate = validate

--- @param ctx PassCtx
--- @return PassResult
function M.run(ctx)
	local outputs  = {}
	local errors   = {}
	local warnings = {}

	-- Per-DIRECTORY (per-module) aggregation. Group sources by `src.dir`,
	-- validate every source in the dir, then emit ONE errors.h per dir.
	-- `ctx.by_dir` is pre-computed in build_ctx (shared across all passes).
	local by_dir = ctx.by_dir or duffle.group_sources_by_dir(ctx.sources)

	for dir, dir_sources in pairs(by_dir) do
		local dir_basename = dir:match("([^/\\]+)$") or dir

		local dir_atoms    = 0
		local dir_errors   = {}
		local dir_warnings = {}
		-- Per-source validate() results, cached for the report pass (it reads from this instead of re-validating each source).
		ctx.flags                       = ctx.flags                       or {}
		ctx.flags._annot_source_results = ctx.flags._annot_source_results or {}
		for _, src in ipairs(dir_sources) do
			local result  = validate(ctx, src)
			result.source = src.path                                  -- tag for downstream rendering
			ctx.flags._annot_source_results[src.path] = result          -- stash so report.lua reads from cache instead of re-running validate()
			dir_atoms = dir_atoms + #result.atoms
			for _, e in ipairs(result.errors) do
				dir_errors[#dir_errors + 1] = { line = e.line, msg = e.msg, source = src.path }
				errors    [#errors     + 1] = { line = e.line, msg = e.msg }
			end
			for _, w in ipairs(result.warnings) do
				dir_warnings[#dir_warnings + 1] = { line = w.line, msg = w.msg }
				warnings    [#warnings     + 1] = { line = w.line, msg = w.msg }
			end
		end

		local err_path = emit_module_errors_h(ctx, dir_basename, dir_atoms, dir_errors, dir_sources)
		if err_path then
			table.insert(outputs, { errors_h = err_path })
		end

		emit_module_annotations_stub(ctx, dir, dir_basename, dir_atoms)
	end

	return { outputs = outputs, errors = errors, warnings = warnings }
end

return M
