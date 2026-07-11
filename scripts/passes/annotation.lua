--- passes/annotation.lua — Atom-annotation DSL validator.
---
--- Validates `MipsAtom_(name) atom_info(atom_bind(Binds_X), atom_reads(...), atom_writes(...)) { ... }` declarations in source files.
--- Also reads: `Binds_*` struct declarations (`typedef Struct_(Binds_X) { ... };`)
---
--- Source scanning: done ONCE upstream by `duffle.scan_source()` (ps1_meta.lua pre-scans each
--- source and stashes the result in `src.scan`). This pass is pure: read from the scan, run
--- checks, emit findings. No source re-walking.
---
--- Writes:
---   - `<ctx.out_root>/<dir_basename>.errors.h` — one per module, with `#error` directives on findings (the C compile will surface the error)
---   - The annotations.txt report is rendered by `passes/report.lua` from the per-module results stashed in `ctx.flags._annot_results`
---
--- **Conventions**: tabs (1/level), EmmyLua annotations, no regex,
--- Lua 5.3 compatible

-- Bootstrap: same as entry scripts. See `ps1_meta.lua` for the rationale.
-- Bootstrap: load `scripts/duffle_paths.lua` (sets package.path + package.cpath).
-- Uses `debug.getinfo` to find this file's own directory, so it works
-- both standalone and when require'd from the orchestrator.
-- Bootstrap: load `duffle_paths.lua` via `debug.getinfo(1, "S").source` (works both standalone + when require'd).
-- duffle_paths.lua sets package.path then returns `require("duffle")` at the bottom, so the dofile value IS the duffle module.
local _bootstrap_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local duffle        = dofile(_bootstrap_dir .. "../duffle_paths.lua")
local write_file          = duffle.write_file
local ensure_dir          = duffle.ensure_dir

-- Domain tables (single source of truth in duffle.lua).
local WAVE_CONTEXT_REGS = duffle.WAVE_CONTEXT_REGS
local TAPE_ATOM_MACROS  = duffle.TAPE_ATOM_MACROS

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

--- @class Finding
--- @field line integer  -- source line (or 0 for pass-level)
--- @field msg  string   -- finding message

--- @class AnnotatedResult
--- @field atoms    AtomEntry[]
--- @field annots   AtomAnnotation[]
--- @field macros   MacroEntry[]
--- @field binds    BindsEntry[]
--- @field errors   Finding[]
--- @field warnings Finding[]
--- @field info     Finding[]

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
			errors = {},
		}
	end

	-- Index atoms by name for lookup.
	local atom_index = {}
	for _, a in ipairs(atoms) do atom_index[a.name] = a end

	-- Index binds by name for lookup.
	local binds_index = {}
	for _, b in ipairs(scan.binds) do binds_index[b.name] = b end

	local errors   = {}
	local warnings = {}
	local info     = {}

	-- 1. Every annotated atom must exist as a real MipsAtom_ declaration.
	for _, a in ipairs(annots) do
		if not atom_index[a.name] then
			errors[#errors + 1] = {
				line = a.line,
				msg  = string.format("annotation for '%s' has no matching MipsAtom_(%s) { ... }", a.name, a.name),
			}
		end
		if a.errors then
			for _, msg in ipairs(a.errors) do
				errors[#errors + 1] = {line = a.line, msg = string.format("'%s': %s", a.name, msg)}
			end
		end
	end

	-- 2. Every atom may have AT MOST ONE annotation (no duplicates).
	-- (Atoms with ZERO annotations are valid in the new minimal shape.)
	local count_per_atom = {}
	for _, a in ipairs(annots) do
		if a.name then
			count_per_atom[a.name] = (count_per_atom[a.name] or 0) + 1
		end
	end
	for name, n in pairs(count_per_atom) do
		if n > 1 then
			errors[#errors + 1] = {
				line = atom_index[name] and atom_index[name].line or 0,
				msg  = string.format("MipsAtom_(%s) has %d annotations (expected at most 1)", name, n),
			}
		end
	end

	-- 3. (Phase validity check DROPPED. Phases were removed from the annotation DSL.)

	-- 4. BIND atoms must reference a real Binds_* struct.
	for _, a in ipairs(annots) do
		if a.binds then
			if not binds_index[a.binds] then
				-- Demoted from error to warning (2026-07-10): the same condition is now caught by passes/static_analysis.lua's
				-- check_abi_handoff() as an error. Emitting a warning here keeps the annotation pass from being stop-on-error
				-- for the common test-fixture case, while still surfacing the issue in the report.
				-- The static-analysis report remains the source of truth for build-stopping errors.
				warnings[#warnings + 1] = {
					line = a.line,
					msg  = string.format("'%s' binds '%s' but no Struct_(%s) { ... } declaration found (also flagged as an error by check_abi_handoff in the static-analysis pass)", a.name, a.binds, a.binds),
				}
			end
		end
	end

	-- 5. BIND writes must be wave-context registers that match Binds_ fields.
	for _, a in ipairs(annots) do
		if a.binds and binds_index[a.binds] then
			local bs = binds_index[a.binds]

			for _, f in ipairs(bs.fields) do
				local candidate = "R_" .. f.name
				if not is_wave_context_reg(candidate) then
					warnings[#warnings + 1] = {
						line = bs.line,
						msg  = string.format("%s field '%s' doesn't match a known wave-context register (candidate '%s')", a.binds, f.name, candidate),
					}
				end
			end

			for _, w in ipairs(a.writes) do
				if not is_wave_context_reg(w) then
					warnings[#warnings + 1] = {
						line = a.line,
						msg  = string.format("%s writes '%s' which is not a known wave-context register", a.name, w),
					}
				end
			end
		end
	end

	-- 6. INFO reads should be wave-context registers (or R_TapePtr for rbind).
	for _, a in ipairs(annots) do
		for _, r in ipairs(a.reads) do
			if not is_wave_context_reg(r) and r ~= "R_TapePtr" then
				warnings[#warnings + 1] = {
					line = a.line,
					msg  = string.format("atom '%s' reads '%s' which is not a known wave-context register", a.name, r),
				}
			end
		end
	end

	-- 7. TAPE_WORDS(mac_X, N) ↔ WORD_COUNT(mac_X, N) drift.
	--    Three outcomes: missing (error), mismatch (error), match (info).
	local function check_macro_drift(m, declared)
		if not declared then
			errors[#errors + 1] = {
				line = m.line,
				msg  = string.format("TAPE_WORDS(%s, %d) but '%s' is not in metadata.h", m.name, m.words, m.name),
			}
			return
		end
		if declared ~= m.words then
			errors[#errors + 1] = {
				line = m.line,
				msg  = string.format("DRIFT: TAPE_WORDS(%s, %d) but metadata.h declares WORD_COUNT(%s, %d)", m.name, m.words, m.name, declared),
			}
			return
		end
		info[#info + 1] = {
			line = m.line,
			msg  = string.format("OK: %s = %d words", m.name, m.words),
		}
	end
	for _, m in ipairs(scan.macros) do
		check_macro_drift(m, ctx.shared.word_counts[m.name])
	end

	-- 8. Information summary.
	info[#info + 1] = {
		line = 0,
		msg  = string.format("scanned: %d atom(s), %d annotation(s), %d macro-word-decl(s), %d binds struct(s)",
			#atoms, #annots, #scan.macros, #scan.binds),
	}

	return {
		atoms    = atoms,
		annots   = annots,
		macros   = scan.macros,
		binds    = scan.binds,
		errors   = errors,
		warnings = warnings,
		info     = info,
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
	ctx.flags         = ctx.flags or {}
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
	local by_dir = duffle.group_sources_by_dir(ctx.sources)

	for dir, dir_sources in pairs(by_dir) do
		local dir_basename = dir:match("([^/\\]+)$") or dir

		local dir_atoms    = 0
		local dir_errors   = {}
		local dir_warnings = {}
		for _, src in ipairs(dir_sources) do
			local result = validate(ctx, src)
			dir_atoms = dir_atoms + #result.atoms
			for _, e in ipairs(result.errors) do
				dir_errors[#dir_errors + 1] = { line = e.line, msg = e.msg, source = src.path }
				errors[#errors + 1] = { line = e.line, msg = e.msg }
			end
			for _, w in ipairs(result.warnings) do
				dir_warnings[#dir_warnings + 1] = { line = w.line, msg = w.msg }
				warnings[#warnings + 1] = { line = w.line, msg = w.msg }
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
