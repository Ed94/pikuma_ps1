--- passes/annotation.lua — Atom-annotation DSL validator.
---
--- Validates `MipsAtom_(name) atom_info(atom_bind(Binds_X), atom_reads(...), atom_writes(...)) { ... }` declarations in source files.
--- Also reads `Binds_*` struct declarations (`typedef Struct_(Binds_X) { ... };`).
---
--- `duffle.scan_source()` scans each source once upstream; `ps1_meta.lua` stores that result in `src.scan`.
---
--- Ownership: the canonical `ctx.shared.corpus` supplies cross-source registries, while each `src.scan` supplies its source's declarations and bodies.
--- A context without `ctx.shared.corpus` is rejected with an explicit canonical-corpus message.
---
--- Writes `<ctx.out_root>/<dir_basename>.errors.h` once per module, with `#error` directives for findings that the C compile surfaces.
--- `passes/report.lua` renders annotations.txt from `corpus.sources_by_dir`, re-validating each source through `M.validate()`.
---
--- **Conventions**: tabs (1/level), EmmyLua annotations, no regex, Lua 5.3 compatible.

-- Bootstrap follows the entry scripts; `scripts/duffle_paths.lua` sets package.path and package.cpath. See `ps1_meta.lua` for the rationale.
-- `debug.getinfo(1, "S").source` locates this file for standalone and orchestrated runs, then `duffle_paths.lua` returns the loaded `duffle` module.
local _bootstrap_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local duffle         = dofile(_bootstrap_dir .. "../duffle_paths.lua")
local write_file     = duffle.write_file
local ensure_dir     = duffle.ensure_dir

-- The annotation pass reads the source-derived registries from scan_source:
--   * pipe_ctx.register_alias_registry — for atom_dbg_reg_default(R_X, ...) and atom_reg_types(R_X, ...) member-identity checks
--   * pipe_ctx.type_name_registry      — for atom_dbg_reg_default(<T>, ...) and atom_reg_types(<T>, ...) type-identity checks

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

--- @class DebugSkipMarker  -- sub-shape of scan_source.lua's @class DebugSkipMarker
--- @field marker_kind    string                 -- exact marker ident read from source. Only "atom_dbg_skip" (bare) is positive.
--- @field marker_line    integer
--- @field args           string|nil             -- trimmed text inside the parens (nil when has_parens is false)
--- @field has_parens     boolean
--- @field is_bare        boolean                -- true iff marker_kind == "atom_dbg_skip" AND has_parens == false (the only positive form)
--- @field pending        boolean                -- true while awaiting the following declaration
--- @field superseded_by_marker_line integer|nil -- set on a marker that was bumped out of the pending slot
--- @field target_kind    string|nil             -- "atom" | "comp_bare" | "comp_proc" | "unrelated" once observed

--- @class Finding
--- @field line integer -- source line (or 0 for pass-level)
--- @field msg  string  -- finding message

--- @class Findings
--- @field errors   Finding[]
--- @field warnings Finding[]
--- @field info     Finding[]

--- @class PipeCtx
--- @field atom_index     table<string, AtomAnnotation> -- name -> AtomAnnotation (only kind=="atom")
--- @field binds_index    table<string, BindsStruct>    -- name -> BindsStruct
--- @field annot_counts   table<string, integer>        -- name -> annotation count (for unique_annotation check)
--- @field types          table<string, RegTypeDefault> -- from scan_source
--- @field atom_views     table<string, AtomViewEntry>  -- from scan_source
--- @field seen_defaults  table<string, integer>        -- duplicate atom_dbg_reg_default detection
--- @field seen_field     table<string, integer>        -- Binds_* -> count of fields (set/checked by check_binds_no_duplicate_fields)
--- @field _scan          SourceScan                    -- full scan payload (typed-view sub-calls live here) 

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
--- The dispatcher in `validate()` routes each result by convention: existence checks write errors[] and shape checks write warnings[].
--- `macro_word_drift` writes errors[] for missing or mismatched metadata and info[] for a match.

--- Check: every annotated atom must have a matching MipsAtom_(name) declaration.
--- @param a        AtomAnnotation
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
--- I keep this as a warning so the annotation pass can report the common test-fixture case; `check_abi_handoff` in static analysis supplies the build-stopping error.
--- @param a        AtomAnnotation
--- @param pipe_ctx PipeCtx
--- @param findings Findings
local function check_binds_struct_exists(a, pipe_ctx, findings)
	if not a.binds                   then return end
	if pipe_ctx.binds_index[a.binds] then return end
	findings.warnings[#findings.warnings + 1] = {
		line = a.line,
		msg  = string.format("'%s' binds '%s' but no Struct_(%s) { ... } " 
			.. "declaration found (also flagged as an error by check_abi_handoff in the static-analysis pass)"
			, a.name, a.binds, a.binds),
	}
end

--- Check: TAPE_WORDS(mac_X, N) ↔ WORD_COUNT(mac_X, N) drift.
--- Three outcomes: missing (error), mismatch (error), match (info).
--- @param m  MacroEntry
--- @param wc table<string, integer> -- the shared word-count table (from ctx.shared.word_counts)
--- @param findings Findings
local function check_macro_word_drift(m, wc, findings)
	local  declared = wc[m.name]
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

--- Check: atom_dbg_reg_default(R_X, <type>) targets an alias in `pipe_ctx.register_alias_registry` and a type in `pipe_ctx.type_name_registry`.
--- Pointer depth remains bounded to 0 or 1, and duplicate defaults remain errors.
--- @param _src     SourceFile -- unused (kept for the per_source shape)
--- @param pipe_ctx PipeCtx
--- @param findings Findings
local function check_semantic_reg_defaults(_src, pipe_ctx, findings)
	-- Detect duplicate defaults using the ordered occurrence list (the out.types hash only retains the last declaration).
	local seen_first_line = {}
	for _, occ in ipairs(pipe_ctx.type_occurrences or {}) do
		if seen_first_line[occ.reg] == nil then
			seen_first_line[occ.reg] = occ.source_line
		else
			findings.errors[#findings.errors + 1] = {
				line = occ.source_line,
				msg  = string.format(
					"duplicate atom_dbg_reg_default for %q at line %d (first declared at line %d); one default per register",
					occ.reg, occ.source_line, seen_first_line[occ.reg]),
			}
		end
	end
	local reg_registry  = pipe_ctx.register_alias_registry or {}
	local type_registry = pipe_ctx.type_name_registry      or {}
	for reg, def in pairs(pipe_ctx.types or {}) do
		if not reg_registry[reg] then
			findings.errors[#findings.errors + 1] = {
				line = def.source_line,
				msg  = string.format(
					"atom_dbg_reg_default at line %d references unknown register %q (not in register_alias_registry)",
					def.source_line, reg),
			}
		end
		if def.pointer_depth == nil or def.pointer_depth < 0 or def.pointer_depth > 1 then
			findings.errors[#findings.errors + 1] = {
				line = def.source_line,
				msg  = string.format(
					"atom_dbg_reg_default at line %d for %q has unsupported pointer depth %d (expected 0 or 1)",
					def.source_line, reg, def.pointer_depth or -1),
			}
		end
		if not def.type_name or not type_registry[def.type_name] then
			findings.errors[#findings.errors + 1] = {
				line = def.source_line,
				msg  = string.format(
					"atom_dbg_reg_default at line %d for %q uses unknown type %q (not in type_name_registry)",
					def.source_line, reg, tostring(def.type_name)),
			}
		end
	end
end

--- Check: atom_reg_types(R_X, <type>) entries target an alias in `pipe_ctx.register_alias_registry` and a type in `pipe_ctx.type_name_registry`.
--- A bare `atom_reg` marker opts the `R_<n>` alias into GPR identity; references to R_T0..R_T3 require the same explicit marker.
--- @param _src     SourceFile
--- @param pipe_ctx PipeCtx
--- @param findings Findings
local function check_atom_reg_types(_src, pipe_ctx, findings)
	local reg_registry  = pipe_ctx.register_alias_registry or {}
	local type_registry = pipe_ctx.type_name_registry      or {}
	for _, ai in ipairs(pipe_ctx.atom_infos_list or {}) do
		if ai.reg_type_overrides then
			for reg, ov in pairs(ai.reg_type_overrides) do
				if not reg_registry[reg] then
					findings.errors[#findings.errors + 1] = {
						line = ai.info_line,
						msg  = string.format(
							"atom '%s' has atom_reg_types for %q; compute-register types are restricted to opt-in aliases (%q not in register_alias_registry)",
							ai.atom_name, reg, reg),
					}
				end
				if not ov.type_name or not type_registry[ov.type_name] then
					findings.errors[#findings.errors + 1] = {
						line = ai.info_line,
						msg  = string.format(
							"atom '%s' atom_reg_types for %q uses unknown compute type %q (not in type_name_registry)",
							ai.atom_name, reg, tostring(ov.type_name)),
					}
				end
			end
		end
	end
end

--- Check: atom_view(Binds_X) entries reference a Binds_* struct with at least one field.
--- @param _src     SourceFile
--- @param pipe_ctx PipeCtx
--- @param findings Findings
local function check_atom_view_layout(_src, pipe_ctx, findings)
	for atom_name, view in pairs(pipe_ctx.atom_views or {}) do
		if not view.binds_name then
			-- The atom had atom_reg_types but no atom_view; no layout check needed.
		else
			local bs = pipe_ctx.binds_index[view.binds_name]
			if not bs then
				findings.errors[#findings.errors + 1] = {
					line = view.info_line,
					msg  = string.format(
						"atom '%s' has atom_view(%s) but no Struct_(%s) { ... } declaration was found",
						atom_name, view.binds_name, view.binds_name),
				}
			elseif not bs.fields or #bs.fields == 0 then
				findings.errors[#findings.errors + 1] = {
					line = bs.line,
					msg  = string.format(
						"atom '%s' has atom_view(%s) but that struct declares zero typed fields",
						atom_name, view.binds_name),
				}
			end
		end
	end
end

--- Check: Binds_* structs require unique field names because atom_view uses those names for typed-field lookup in gdb.
--- @param _src SourceFile
--- @param pipe_ctx PipeCtx
--- @param findings Findings
local function check_binds_no_duplicate_fields(_src, pipe_ctx, findings)
	for _, bs in ipairs(pipe_ctx.binds_list or {}) do
		local seen = {}
		for _, f in ipairs(bs.fields or {}) do
			seen[f.name] = (seen[f.name] or 0) + 1
		end
		for name, count in pairs(seen) do
			if count > 1 then
				findings.errors[#findings.errors + 1] = {
					line = bs.line,
					msg  = string.format(
						"%s has duplicate field name %q (count %d); the typed-view contract requires unique field names",
						bs.name, name, count),
				}
			end
		end
	end
end

-- Check: debug-skip markers must satisfy shape + placement constraints.
--- Walks the priority list once; each marker produces at most one error, so one source defect yields one finding.
--- Priority order (first defect wins):
---   1. marker_kind ~= "atom_dbg_skip" -> legacy/renamed spelling (use `atom_dbg_skip`)
---   2. marker_kind == "atom_dbg_skip" AND has_parens -> parenthesized form (the marker is bare-only)
---   3. args  ~= ""                 -> takes no arguments
---   4. superseded_by_marker_line   -> duplicate marker (cite superseding line)
---   5. pending + no target_kind    -> dangling (no following declaration)
---   6. unsupported target_kind     -> marker precedes an unrelated declaration
--- Valid markers stamp `debug_skip` on whole-atom, bare-component, and proc-component declaration records in scan_source.lua.
--- @param marker DebugSkipMarker
--- @param _pipe_ctx PipeCtx     -- unused today; kept for plex-shape consistency with per_annot
--- @param findings Findings
local function check_skip_marker(marker, _pipe_ctx, findings)
	local kind = marker.marker_kind
	local line = marker.marker_line

	-- Tasks 6+7 left `scan.debug_skip_markers` with production records for `atom_dbg_skip` only; other identifiers take the walker's unrelated branch.

	if marker.has_parens then
		findings.errors[#findings.errors + 1] = {
			line = line,
			msg  = string.format("%s marker at line %d must be bare; the parenthesized form is no longer accepted (use `atom_dbg_skip MipsAtom_(name) { ... }`)",
				kind, line),
		}
		return
	end

	if marker.args ~= nil and marker.args ~= "" then
		findings.errors[#findings.errors + 1] = {
			line = line,
			msg  = string.format("%s marker at line %d takes no arguments; found %q", kind, line, marker.args),
		}
		return
	end

	if marker.superseded_by_marker_line then
		findings.errors[#findings.errors + 1] = {
			line = line,
			msg  = string.format("duplicate %s marker at line %d; superseded by another %s marker at line %d"
				, kind, line, kind, marker.superseded_by_marker_line),
		}
		return
	end

	if marker.pending and not marker.target_kind then
		findings.errors[#findings.errors + 1] = {
			line = line,
			msg  = string.format("dangling %s marker at line %d: no following MipsAtom_/MipsAtomComp_/MipsAtomComp_Proc_ declaration"
				, kind, line),
		}
		return
	end

	if marker.target_kind
		and marker.target_kind ~= "atom"
		and marker.target_kind ~= "comp_bare"
		and marker.target_kind ~= "comp_proc" then
		findings.errors[#findings.errors + 1] = {
			line = line,
			msg  = string.format("%s marker at line %d must precede MipsAtom_, MipsAtomComp_, or MipsAtomComp_Proc_; found an unrelated declaration"
				, kind, line),
		}
	end
end

--- Warn when a source references an unregistered alias.
---
--- R_TapePtr, R_AtomJmp, R_PrimCursor, R_FaceCursor, R_VertBase, and R_OtBase opt in through `#define atom_reg` in lottes_tape.h.
--- When a source uses an unregistered R_X, this check emits one pass-level info entry for that source and directs C-ABI register names to explicit alias registration.
--- @param _src     SourceFile
--- @param pipe_ctx PipeCtx
--- @param findings Findings
local function check_wave_context_migration(_src, pipe_ctx, findings)
	if not (pipe_ctx.types and next(pipe_ctx.types)) then return end
	if not (pipe_ctx.atom_infos_list) then return end
	local reg_registry = pipe_ctx.register_alias_registry or {}
	for _, ai in ipairs(pipe_ctx.atom_infos_list) do
		if ai.reg_type_overrides then
			for reg, _ in pairs(ai.reg_type_overrides) do
				if not reg_registry[reg] then
					findings.warnings[#findings.warnings + 1] = {
						line = 0,
						msg  = "wave-context removed; opt in via #define atom_reg in mips.h "
							.. "(every R_<alias> that should be visible to the annotation pass "
							.. "must be enum-declared with the bare atom_reg marker)",
					}
					return
				end
			end
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
-- CHECK_RULES — data-driven check dispatch (the plex pattern)
-- ════════════════════════════════════════════════════════════════════════════
--
-- Each rule entry picks one of four "shapes" of dispatch:
--   per_annot(annot, pipe_ctx, findings)        -- runs once per AtomAnnotation
--   post(pipe_ctx, findings)                    -- runs once after all per_annot calls complete (full-corpus aggregation)
--   per_macro(macro, wc, findings)              -- runs once per TAPE_WORDS / _Pragma macro declaration
--   per_skip_marker(marker, pipe_ctx, findings) -- runs once per src.scan.debug_skip_markers entry
--
-- Adding a new check = 1 row here + 1 function above. The `validate()` dispatch loop never needs editing.

local CHECK_RULES = {
	{ name = "atom_decl_exists",          per_annot       = check_atom_decl_exists          },
	{ name = "binds_struct_exists",       per_annot       = check_binds_struct_exists       },
	{ name = "unique_annotation",         post            = check_unique_annotation         },
	{ name = "macro_word_drift",          per_macro       = check_macro_word_drift          },
	{ name = "skip_marker_validation",    per_skip_marker = check_skip_marker               },
	{ name = "semantic_reg_defaults",     per_source      = check_semantic_reg_defaults     },
	{ name = "atom_reg_types",            per_source      = check_atom_reg_types            },
	{ name = "atom_view_layout",          per_source      = check_atom_view_layout          },
	{ name = "binds_no_duplicate_fields", per_source      = check_binds_no_duplicate_fields },
	{ name = "wave_context_migration",    per_source      = check_wave_context_migration    },
}

-- ════════════════════════════════════════════════════════════════════════════
-- Validation
-- ════════════════════════════════════════════════════════════════════════════
--
-- Pure check: read from src.scan, run validations, emit findings. The scan was done once upstream.

--- Builds one pass-wide pipe_ctx from the merged `corpus.*` registries and source-ordered `corpus.atom_infos`; per-source declarations and bodies remain in `src.scan`.
--- The module ownership contract above requires callers to construct `ctx.shared.corpus` through `build_ctx`; the error message below enforces that gate.
--- @param ctx PassCtx
--- @return PipeCtx
local function build_corpus_pipe_ctx(ctx)
	local corpus = ctx.shared and ctx.shared.corpus
	if not corpus then
		error("annotation requires ctx.shared.corpus "
			.. "(the canonical corpus is the source of truth; "
			.. "no per-source fallback is supported)", 0)
	end

	-- `corpus.atom_infos` preserves source order and duplicates; I precompute counts here for `check_unique_annotation` and the per-source checks.
	local annot_counts = {}
	for _, info in ipairs(corpus.atom_infos or {}) do
		if info and info.atom_name then
			annot_counts[info.atom_name] = (annot_counts[info.atom_name] or 0) + 1
		end
	end

	-- Every consumer of these fields observes mutations via the canonical corpus without independently mutable registry construction.
	return {
		-- Cross-source lookup tables from corpus.
		register_alias_registry  = corpus.register_alias_registry or {},
		type_name_registry       = corpus.type_name_registry      or {},
		atom_views               = corpus.atom_views              or {},
		atom_ctxs                = corpus.atom_ctxs               or {},
		atom_phases              = corpus.atom_phases             or {},
		binds_by_name            = corpus.binds_by_name           or {},
		atoms_by_name            = corpus.atoms_by_name           or {},
		-- Corpus-wide ordered list of atom_info records (source-order + duplicates).
		atom_infos_list          = corpus.atom_infos              or {},
		-- Corpus-wide annotation count aggregation (post-rule consumes this).
		annot_counts             = annot_counts,
		-- Corpus-wide collisions (recorded by scan_source.merge_corpus_registries).
		collisions               = corpus.collisions              or {},
		-- `check_macro_word_drift` reads `corpus.word_counts`, populated by word_count_eval.run.
		word_counts              = corpus.word_counts or {},
	}
end

--- Validate one source against its pre-scanned SourceScan payload + the corpus-wide pipe_ctx.
--- @param ctx             PassCtx
--- @param src             SourceFile
--- @param corpus_pipe_ctx PipeCtx|nil  -- built once per pass from corpus registries; nil builds the same projection here.
--- @return AnnotatedResult
local function validate(ctx, src, corpus_pipe_ctx)
	corpus_pipe_ctx = corpus_pipe_ctx or build_corpus_pipe_ctx(ctx)
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

	-- Build a per-source pipe_ctx: shared lookups come from `corpus_pipe_ctx`, while declarations, bodies, types, views, defaults, and occurrences come from `src.scan`.
	local seen_defaults = {}
	for reg, _ in pairs(scan.types or {}) do
		seen_defaults[reg] = (seen_defaults[reg] or 0) + 1
	end
	local atom_infos_list = {}
	for _, ai in ipairs(scan.atom_infos or {}) do
		atom_infos_list[#atom_infos_list + 1] = ai
	end

	local pipe_ctx = {
		atom_index               = {},
		binds_index              = {},
		annot_counts             = corpus_pipe_ctx.annot_counts,
		types                    = scan.types or {},
		type_occurrences         = scan.type_occurrences or {},
		atom_views               = scan.atom_views or {},
		seen_defaults            = seen_defaults,
		atom_infos_list          = atom_infos_list,
		binds_list               = scan.binds or {},
		-- See the module ownership contract; these shared lookup tables come from corpus_pipe_ctx.
		register_alias_registry  = corpus_pipe_ctx.register_alias_registry,
		type_name_registry       = corpus_pipe_ctx.type_name_registry,
	}
	for _, a in ipairs(atoms)      do pipe_ctx.atom_index [a.name] = a end
	for _, b in ipairs(scan.binds) do pipe_ctx.binds_index[b.name] = b end

	-- Findings live in a single struct with three lists (errors / warnings / info).
	-- Each check writes to the list appropriate for its severity.
	local findings = { errors = {}, warnings = {}, info = {} }

	-- Lift parse-time errors already recorded in scan_source's atom_info payload into this pass's findings list.
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

	-- scan_source records each marker in scan.debug_skip_markers; this loop validates each record independently and emits at most one error per marker.
	-- Valid markers stamp `debug_skip = true` on the following atom or component declaration, which downstream consumers read directly.
	local skip_markers = scan.debug_skip_markers or {}
	for _, marker in ipairs(skip_markers) do
		for _, rule in ipairs(CHECK_RULES) do
			if rule.per_skip_marker then rule.per_skip_marker(marker, pipe_ctx, findings) end
		end
	end

	-- Per-macro rules (TAPE_WORDS vs WORD_COUNT drift).
	local wc = corpus_pipe_ctx.word_counts
	for _, m in ipairs(scan.macros) do
		for _, rule in ipairs(CHECK_RULES) do
			if rule.per_macro then rule.per_macro(m, wc, findings) end
		end
	end

	-- Per-source rules (reg defaults, atom_view layout, compute-register type overrides, Binds_* field uniqueness).
	-- Each per_source rule sees the full scan payload via pipe_ctx.
	for _, rule in ipairs(CHECK_RULES) do
		if rule.per_source then rule.per_source(src, pipe_ctx, findings) end
	end

	-- Information summary (always emitted).
	findings.info[#findings.info + 1] = {
		line = 0,
		msg  = string.format("scanned: %d atom(s), %d annotation(s), %d macro-word-decl(s), %d binds struct(s)"
			, #atoms, #annots, #scan.macros, #scan.binds),
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

	-- Build the shared pipe_ctx once for this run; every validate() call sees the same cross-source registries.
	-- The corpus owns the canonical cross-source registries; per-source scans retain body / declaration ownership.
	local corpus_pipe_ctx = build_corpus_pipe_ctx(ctx)
	local corpus = ctx.shared.corpus

	-- Group `corpus.sources_by_dir` by module, validate every source in each bucket, and emit one errors.h per directory.
	local by_dir = (corpus and corpus.sources_by_dir) or {}

	for dir, dir_sources in pairs(by_dir) do
		local dir_basename = dir:match("([^/\\]+)$") or dir
		local dir_atoms    = 0
		local dir_errors   = {}
		local dir_warnings = {}
		for _, src in ipairs(dir_sources) do
			local result  = validate(ctx, src, corpus_pipe_ctx)
			result.source = src.path                           -- tag for downstream rendering
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
	end

	return { outputs = outputs, errors = errors, warnings = warnings }
end

return M
