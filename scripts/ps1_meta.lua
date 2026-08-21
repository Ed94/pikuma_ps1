--- ps1_meta.lua — Orchestrator entry point for the tape-atom metaprogram.
---
--- Dispatches to pass modules under `scripts/passes/`, resolving dependencies topologically (Kahn's algorithm + cycle detection).
---
--- Architecture:
---   - PASSES table: Declarative dep graph (data, not code).
---   - FLAG_HANDLERS table: Maps CLI flags to handlers.
---   - parse_args → build_ctx (resolves unity/direct includes or exact sources) → topo_sort → dispatch_passes.
---   - The first pass in the dep graph is `scan-source` (see `passes/scan_source.lua`).
---     It calls `duffle.scan_source` once per source to produce the fat `SourceScan` payload, which is attached to each `src.scan`. 
---     Every other pass that reads source structure depends on `scan-source` and consumes `src.scan` as a read-only. 
---
-- ════════════════════════════════════════════════════════════════════════════
-- Module-scope requires + package.path setup
-- ════════════════════════════════════════════════════════════════════════════

-- Bootstrap: load `duffle_paths.lua` via this script's own path.
-- Use `arg[0]` when this file is the entry script (`arg[0]` ends in "ps1_meta.lua");
-- fall back to `debug.getinfo(1, "S").source` when this file is being dofile()'d or require()'d (in which case `arg[0]` is the *caller's* path).
-- That single statement: (a) sets `package.path` + `package.cpath`, (b) at the bottom returns `require("duffle")`.
-- So the dofile's return value is the duffle module.
local _is_entry_script = arg and arg[0] and arg[0]:match("ps1_meta%.lua$") ~= nil ---@type boolean
local _bootstrap_src                                                              ---@type string
if _is_entry_script then
	_bootstrap_src = arg[0]
else
	-- debug.getinfo(1, "S").source returns "@<path>" for the current chunk;
	-- strip the leading "@" so the directory match works in both cases.
	_bootstrap_src = debug.getinfo(1, "S").source:sub(2)
end
local duffle = dofile((_bootstrap_src:match("(.*[/\\])") or "./") .. "duffle_paths.lua") ---@type DuffleExport

-- ════════════════════════════════════════════════════════════════════════════
-- Constants
-- ════════════════════════════════════════════════════════════════════════════

-- Exit codes (per the --help text and the post-build summary convention).
local EXIT_OK                  = 0 ---@type integer
local EXIT_VALIDATION_ERRORS   = 1 ---@type integer
local EXIT_INTERNAL_ERROR      = 2 ---@type integer

-- Default --out-root value if not provided.
local DEFAULT_OUT_ROOT         = "build/gen" ---@type string

-- Sentinel for "all passes" in `PASS_FLAG_TO_NAME`. Distinguishes `--all` from the per-pass flags (which map to individual pass names).
local ALL_PASSES_SENTINEL      = "__all__" ---@type string

-- Sentinel key for the pass-flag dispatcher in `FLAG_HANDLERS`. 
-- The actual pass names are looked up via `PASS_FLAG_TO_NAME`, not direct dispatch, so this key never matches a real flag.
local PASS_FLAG_DISPATCH_KEY   = "__pass__" ---@type string

-- ════════════════════════════════════════════════════════════════════════════
-- Type declarations
-- ════════════════════════════════════════════════════════════════════════════

--- @class PassDescriptor
--- @field module string       -- Module name passed to require()
--- @field kind   string       -- "shared" | "header-output" | "validation" | "diagnostic" | "report"
---                            -- Report severity is independent from process exit policy (see PASS_KIND_STOP_ON_ERROR).
--- @field deps   string[]     -- Names of upstream passes
--- @field groups string[]?    -- OPTIONAL build-phase groups this pass is a root of (e.g. { "pre-link" }, { "post-link" }); absent ⇒ dependency-only

--- @class Corpus
--- @field unity_root              string|nil
--- @field project_root            string
--- @field code_root               string
--- @field source_order            SourceFile[]
--- @field sources_by_path         table<Path, SourceFile>
--- @field sources_by_dir          table<string, SourceFile[]>
--- @field atoms_by_name           table<AtomName, AtomEntry>
--- @field binds_by_name           table<string, BindsEntry>
--- @field atom_infos              AtomInfoEntry[]
--- @field register_alias_registry table<string, AliasEntry>
--- @field type_name_registry      table<string, TypeNameEntry>
--- @field atom_views              table<AtomName, AtomViewEntry>
--- @field atom_ctxs               table<AtomName, AtomCtxEntry>
--- @field atom_phases             table<string, AtomPhaseGroup>
--- @field word_counts             WordCounts
--- @field components              table<string, Component>
--- @field atom_bundles            table<string, AtomBundle>|nil
--- @field collisions              CorpusCollision[]
--- @field resolver                SourceResolver
--- @field component_atom_infos    AtomInfoEntry[]|nil
--- @field atom_auto_regs          table<AtomName, table<string, string>>|nil
--- @field phase_auto_regs         table<string, table<string, string>>|nil
--- @field reg_use_schemas         table<string, RegUseSchema>|nil
--- @field reg_use_errors          RegUseError[]|nil
--- @field static_analysis_results table<string, AtomAnalysis>|nil
--- @field tape_chains             table<string, TapeChain>|nil

--- @class PassShared
--- @field corpus Corpus

--- @class PassFlags
--- @field gdb_runtime     boolean|nil
--- @field dwarf_injection boolean|nil
--- @field elf_path        string|nil

--- @class PassCtx
--- @field metadata_path string                 -- Path to word_count.metadata.h
--- @field shared        PassShared             -- Cross-pass shared state
--- @field out_root      string                 -- Output root (e.g. "build/gen")
--- @field project_root  string                 -- PS1 repository root
--- @field flags         PassFlags              -- CLI flags + per-pass stash
--- @field verbose       boolean                -- If true, log diagnostic info

--- CheckName: see static_analysis.lua. AtomName: see duffle.lua.
--- @class Finding
--- @field line         integer
--- @field msg          string
--- @field kind         string|nil     -- error | warning | info
--- @field atom         AtomName|nil
--- @field check        CheckName|nil
--- @field source       string|nil     -- optional; emit/reguse path
--- @field schema_name  string|nil     -- optional; emit/reguse

--- @class PassScratch
--- @field corpus                   Corpus|nil
--- @field info_by_atom             table<string, AtomInfoEntry>|nil
--- @field binds_index              table<string, BindsEntry>|nil
--- @field atom_index               table<string, AtomEntry>|nil
--- @field annot_counts             table<string, integer>|nil  -- bag
--- @field types                    table<string, RegTypeDefault>|nil
--- @field atom_views               table<string, AtomViewEntry>|nil
--- @field seen_defaults            table<string, integer>|nil  -- bag
--- @field seen_field               table<string, integer>|nil  -- bag
--- @field _scan                    SourceScan|nil
--- @field word_counts              WordCounts|nil
--- @field register_alias_registry  table<string, AliasEntry>|nil
--- @field type_name_registry       table<string, TypeNameEntry>|nil
--- @field type_occurrences         RegTypeOccurrence[]|nil
--- @field atom_infos_list          AtomInfoEntry[]|nil
--- @field binds_list               BindsEntry[]|nil
--- @field unknown_seen             table<string, integer>|nil  -- bag
--- @field atoms                    AtomEntry[]|nil
--- @field components_by_name       table<string, Component>|nil
--- @field atoms_by_name            table<string, AtomEntry>|nil
--- @field tape_chains              table<string, string[]>|nil
--- @field source_order             SourceFile[]|nil
--- @field component_atom_infos     AtomInfoEntry[]|nil
--- @field atom_infos_all           AtomInfoEntry[]|nil
--- @field gte_cr_alias_groups      GteCrAliasGroup[]|nil
--- @field line_for_word_event      (fun(ev: WordEvent): integer)|nil

--- @class PassOutputEntry
--- @field kind string
--- @field path string

--- @class PassResult
--- @field outputs  PassOutputEntry[]
--- @field errors   Finding[]         -- Build-stops (per-pass kind policy)
--- @field warnings Finding[]         -- Informational
--- @field info     Finding[]|nil     -- static_analysis only

--- @class ParsedArgs
--- @field requested_set string[]       -- Pass names to run (explicit --all expanded)
--- @field sources       string[]       -- Exact --source values, retained in CLI order
--- @field unity_root    string|nil     -- --unity-root value; mutually exclusive with sources
--- @field metadata      string         -- --metadata value
--- @field out_root      string         -- --out-root value (default "build/gen")
--- @field project_root  string         -- PS1 repository root (derived from metadata by default)
--- @field verbose       boolean        -- If true, log diagnostic info
--- @field flags         PassFlags|nil  -- Per-pass stash; copied onto PassCtx.flags

--- @alias FlagHandler fun(args: ParsedArgs, argv: string[]|nil, arg_idx: integer|nil): integer|nil

--- @class PassModule
--- @field run fun(ctx: PassCtx): PassResult

--- @class Ps1MetaMod
--- @field PASSES                  table<string, PassDescriptor>
--- @field PASS_KIND_STOP_ON_ERROR table<string, boolean>
--- @field parse_args              fun(argv: string[]): ParsedArgs
--- @field build_ctx               fun(args: ParsedArgs): PassCtx

-- ════════════════════════════════════════════════════════════════════════════
-- PASSES Table
-- ════════════════════════════════════════════════════════════════════════════

-- Build-phase groups: Each PASSES row may declare membership in one or more named groups via `groups = { ... }`.
-- The CLI flags --pre-link and --post-link request the *roots* of their group; topo_sort then closes transitive dependencies from those roots,
-- and dispatch_passes runs every pass in the resulting closure without phase-filtering.
--
-- A row without a `groups` entry is dependency-only: it runs only when a transitive dep requests it, 
-- but it remains directly requestable through its explicit CLI flag (e.g. --atoms-source-map, --scan-source).

local PASSES = { ---@type table<string, PassDescriptor>
	["scan-source"] = {
		module = "passes.scan_source",
		kind   = "shared", deps = {},
	},
	["word-counts"] = {
		module = "passes.word_count_eval",
		kind   = "shared", deps = {},
	},
	components = {
		module = "passes.components",
		kind   = "header-output",
		deps   = {"scan-source", "word-counts"},
	},
	auto_reg = {
		module = "passes.auto_reg",
		kind   = "header-output",
		deps   = {"components"},
		groups = { "pre-link" },
	},
	["emission-model"] = {
		module = "passes.emission_model",
		kind   = "validation",
		deps   = {"components"},
	},
	annotation = {
		module = "passes.annotation",
		kind   = "validation",
		deps   = {"scan-source", "word-counts"},
	},
	offsets = {
		module = "passes.offsets",
		kind   = "header-output",
		deps   = {"scan-source", "word-counts", "components", "emission-model"},
		groups = { "pre-link" },
	},
	["static-analysis"] = {
		module = "passes.static_analysis",
		-- "diagnostic" — every `error`/`warning` finding is written to the report file.
		-- Report severity is independent from process exit policy.
		kind   = "diagnostic",
		deps   = {"scan-source", "word-counts", "components", "emission-model"},
	},
	["atoms-source-map"] = {
		module = "passes.atoms_source_map",
		kind   = "header-output",
		deps   = {"word-counts", "components", "emission-model"},
	},
	["dwarf-injection"] = {
		module = "passes.dwarf_injection",
		kind   = "shared",
		deps   = {"scan-source", "atoms-source-map"},
		groups = { "post-link" },
	},
	report = {
		module = "passes.report",
		kind   = "report",
		deps   = {"annotation", "static-analysis", "atoms-source-map"},  -- +atoms-source-map (consolidated-report-files refactor, 2026-07-26)
		groups = { "pre-link" },
	},
}

-- ────────────────────────────────────────────────────────────────────────────
-- Phase-root selection: Derive the sorted set of roots belonging to a named build-phase group, then append them to `args.requested_set`.
-- topo_sort closes the transitive deps from there; dispatch_passes runs every resolved pass without phase-filtering.
-- ────────────────────────────────────────────────────────────────────────────

--- @param group_name string  -- Build-phase group ("pre-link" | "post-link")
--- @return string[]          -- Sorted root pass names belonging to that group
local function roots_for_group(group_name)
	local names = {}                   ---@type string[]
	for name, pass in pairs(PASSES) do ---@type string, PassDescriptor
		if pass.groups then
			for _, g in ipairs(pass.groups) do ---@type integer, string
				if g == group_name then
					names[#names + 1] = name
					break
				end
			end
		end
	end
	table.sort(names)
	return names
end

--- Append every root belonging to `group_name` to `args.requested_set`.
--- Errors loudly if no PASSES row declares the group, so a typo'd or future-removed group name
--- cannot silently fall through to pre-link (or any other default) and dispatch nothing.
--- @param args       ParsedArgs
--- @param group_name string
--- @return nil
local function request_roots_for_group(args, group_name)
	local roots = roots_for_group(group_name) ---@type string[]
	if #roots == 0 then
		error(string.format("ps1_meta: build-phase group %q has zero roots in PASSES; check PASSES rows for a `groups = { %q }` field"
			, group_name, group_name))
	end
	for _, name in ipairs(roots) do ---@type integer, string
		args.requested_set[#args.requested_set + 1] = name
	end
end

-- Pass-kind taxonomy: findings always print. No pass kind stops the build.
-- Report severity is independent from process exit policy.
-- Adding a new pass kind requires listing it here explicitly; an unknown kind must not silently fall back to "true".
local PASS_KIND_STOP_ON_ERROR = { ---@type table<string, boolean>  -- bag: pass kind -> stop-on-error
	["shared"]        = false,
	["header-output"] = false,
	["validation"]    = false,
	["diagnostic"]    = false,
	["report"]        = false,
}

-- Closed set of CLI flags -> pass names.
-- Per-pass flags (e.g. --word-counts); phase flags (--pre-link, --post-link, --all) are within FLAG_HANDLERS because they own side effects or invoke group-derivation logic.
-- dwarf-injection is *also* a per-pass opt-in flag, but its selection + opt-in state are both owned by the explicit FLAG_HANDLERS entry below
-- (it sets args.flags.dwarf_injection and appends "dwarf-injection" to requested_set), so it is intentionally absent from this table.
local PASS_FLAG_TO_NAME = { ---@type table<string, string>  -- bag: CLI flag -> pass name or ALL_PASSES_SENTINEL
	["--word-counts"]       = "word-counts",
	["--components"]        = "components",
	["--validate"]          = "annotation",
	["--offsets"]           = "offsets",
	["--static-analysis"]   = "static-analysis",
	["--atoms-source-map"]  = "atoms-source-map",
	["--report"]            = "report",
	["--scan-source"]       = "scan-source",
	["--all"]               = ALL_PASSES_SENTINEL,
}

--- Append every pass name to args.requested_set.
--- Names are derived from PASSES (no parallel name list); used by --all and by any caller that wants the full closure.
--- @param args ParsedArgs
--- @return nil
local function request_all_passes(args)
	local names = {}                                          ---@type string[]
	for name in pairs(PASSES) do names[#names + 1] = name end ---@type string
	table.sort(names)
	for _, n in ipairs(names) do ---@type integer, string
		args.requested_set[#args.requested_set + 1] = n
	end
end

-- Per-flag handlers. Each handler takes (args, argv, arg_idx) and returns the new arg_idx (so multi-arg flags like --source FILE advance it). 
-- Returning nil + os.exit() handles termination flags (--help). 
local FLAG_HANDLERS = {} ---@type table<string, FlagHandler>

-- ════════════════════════════════════════════════════════════════════════════
-- CLI parsing
-- ════════════════════════════════════════════════════════════════════════════

--- Print the CLI usage to stdout and exit 0.
--- @return nil
local function print_help()
	io.write([[
ps1_meta.lua - Tape-atom metaprogram orchestrator

USAGE:
  ps1_meta.lua [PASS_FLAGS] [COMMON_FLAGS]

PASS_FLAGS:
  Pick a phase or one-or-more individual passes:
    --pre-link           [phase; default] Run the pre-link group + transitive deps.
                         The root set is data-driven from each PASSES row's groups` field; no parallel name list is maintained.
    --post-link          [phase] Run the post-link group + transitive deps.
                         Requires --elf. Sets --gdb-runtime and --dwarf-injection opt-in flags as well.
    --all                Select every row of the PASSES table. Pass-local opt-in guards remain active, so --dwarf-injection still requires
                         --elf and --gdb-runtime still requires a runtime emission.
  Or pick any subset:
    --scan-source         Scan sources into the fat SourceScan payload
    --word-counts         Load metadata.h + scan for existing .macs.h
    --components          Generate <srcdir>/gen/macs.h (per-directory aggregation)
    --validate            Run atom annotation DSL validation
    --offsets             Generate <srcdir>/gen/offsets.h (per-directory aggregation)
    --atoms-source-map    Generate <basename>.atoms.sourcemap.txt per source
    --dwarf-injection     [opt-in] Select the post-link dwarf-injection pass + set the opt-in flag. Requires --elf.
    --static-analysis     Static analysis: GTE pipeline-fill, mac_yield, ABI handoff, cycle budget
    --report              Render per-project summary

COMMON_FLAGS:
  --unity-root FILE     Unity source root: load root + direct quoted authored includes only. Mutually exclusive with --source.
  --source FILE         Exact source file to process (repeatable, never expands includes). Mutually exclusive with --unity-root.
  --metadata PATH       Path to metadata.h (required)
  --out-root DIR        Output root for reports (default: build/gen)
  --project-root DIR    PS1 repository root (default: derived from <repo>/code/duffle/word_count.metadata.h)
  --gdb-runtime         Also emit <out_root>/gdb_tape_atoms_runtime.gdb (post-link, requires --elf)
  --elf PATH            Path to linked .elf (for --gdb-runtime / --dwarf-injection)
  --verbose             Print per-pass debug output
  --help                Show this help and exit

EXIT CODES:
  0  All requested passes succeeded
  1  Validation errors found
  2  Metaprogram internal error

EXAMPLES:
  ps1_meta.lua --pre-link  --metadata code/duffle/word_count.metadata.h --unity-root code/gte_hello/hello_gte.c
  ps1_meta.lua --post-link --metadata code/duffle/word_count.metadata.h --unity-root code/gte_hello/hello_gte.c --elf build/hello_gte.elf
  ps1_meta.lua --all       --metadata metadata.h --source code/foo.c --source code/bar.c
]])
end

local FLAG_VALUE_NAMES = { ---@type table<string, string>  -- bag: flag -> value metavar
	["--source"]       = "FILE",
	["--unity-root"]   = "FILE",
	["--metadata"]     = "PATH",
	["--out-root"]     = "DIR",
	["--project-root"] = "DIR",
	["--elf"]          = "PATH",
}

--- @param argv    string[]
--- @param arg_idx integer
--- @param flag    string
--- @return string
--- @return integer
local function require_flag_value(argv, arg_idx, flag)
	local value      = argv[arg_idx + 1]       ---@type string|nil
	local next_known = type(value) == "string" ---@type boolean
		and (FLAG_HANDLERS[value] ~= nil or PASS_FLAG_TO_NAME[value] ~= nil)
	if value == nil or next_known then
		io.stderr:write("ps1_meta: " .. flag .. " requires " .. FLAG_VALUE_NAMES[flag] .. "\n")
		os.exit(EXIT_INTERNAL_ERROR)
	end
	return value, arg_idx + 1
end

-- Per-flag handlers. Each takes (args, argv, arg_idx) and returns the new arg_idx (so multi-arg flags like --source FILE advance it).
-- Termination flags like --help call os.exit() instead.
-- Populated AFTER print_help so the --help handler can reference it as an upvalue (Lua resolves locals at closure-call time, 
-- but if the closure is defined before the local, it falls back to _G). 

--- @param args ParsedArgs
--- @return nil
FLAG_HANDLERS["--help"]    = function(args) print_help(); os.exit(0) end
--- @param args ParsedArgs
--- @return nil
FLAG_HANDLERS["--verbose"] = function(args) args.verbose = true      end

--- @param args    ParsedArgs
--- @param argv    string[]
--- @param arg_idx integer
--- @return integer
FLAG_HANDLERS["--source"] = function(args, argv, arg_idx)
	local value, value_idx = require_flag_value(argv, arg_idx, "--source") ---@type string, integer
	args.sources[#args.sources + 1] = value
	return value_idx
end
--- @param args    ParsedArgs
--- @param argv    string[]
--- @param arg_idx integer
--- @return integer
FLAG_HANDLERS["--unity-root"] = function(args, argv, arg_idx)
	local value, value_idx = require_flag_value(argv, arg_idx, "--unity-root") ---@type string, integer
	args.unity_root = value
	return value_idx
end
--- @param args    ParsedArgs
--- @param argv    string[]
--- @param arg_idx integer
--- @return integer
FLAG_HANDLERS["--metadata"] = function(args, argv, arg_idx)
	local value, value_idx = require_flag_value(argv, arg_idx, "--metadata") ---@type string, integer
	args.metadata = value
	return value_idx
end
--- @param args    ParsedArgs
--- @param argv    string[]
--- @param arg_idx integer
--- @return integer
FLAG_HANDLERS["--out-root"] = function(args, argv, arg_idx)
	local value, value_idx = require_flag_value(argv, arg_idx, "--out-root") ---@type string, integer
	args.out_root = value
	return value_idx
end
--- @param args    ParsedArgs
--- @param argv    string[]
--- @param arg_idx integer
--- @return integer
FLAG_HANDLERS["--project-root"] = function(args, argv, arg_idx)
	local value, value_idx = require_flag_value(argv, arg_idx, "--project-root") ---@type string, integer
	args.project_root = value
	return value_idx
end

-- Per-pass stash flags. Read by `passes/atoms_source_map.lua` to opt into the post-link gdb-runtime emission.
-- Same shape as the existing per-flag handlers. mutates `args.flags` (which propagates into `ctx.flags`).
--- @param args ParsedArgs
--- @return nil
FLAG_HANDLERS["--gdb-runtime"] = function(args)
	args.flags = args.flags or {}
	args.flags.gdb_runtime = true
end
--- @param args    ParsedArgs
--- @param argv    string[]
--- @param arg_idx integer
--- @return integer
FLAG_HANDLERS["--elf"] = function(args, argv, arg_idx)
	local value, value_idx = require_flag_value(argv, arg_idx, "--elf") ---@type string, integer
	args.flags = args.flags or {}
	args.flags.elf_path = value
	return value_idx
end
-- Enable DWARF injection (default OFF). Opts in to the post-link pass and sets the flag in one shot.
-- The explicit handler below owns both selection and opt-in state, so --dwarf-injection is intentionally absent from PASS_FLAG_TO_NAME.
--- @param args ParsedArgs
--- @return nil
FLAG_HANDLERS["--dwarf-injection"] = function(args)
	args.flags                 = args.flags or {}
	args.flags.dwarf_injection = true
	args.requested_set[#args.requested_set + 1] = "dwarf-injection"
end
-- Build-phase flags: --pre-link and --post-link request the roots of their declared groups (see roots_for_group).
-- topo_sort closes transitive deps from those roots; dispatch_passes runs every pass in the resolved closure without phase-filtering.
--- @param args ParsedArgs
--- @return nil
FLAG_HANDLERS["--pre-link"] = function(args)
	request_roots_for_group(args, "pre-link")
end
-- Batch post-link phase: gdb-runtime + dwarf-injection in one luajit cold start.
-- Sets the same opt-in flags as --gdb-runtime + --dwarf-injection and selects the post-link build-phase group.
-- elf is required; parse_args enforces it after all flags are parsed.
--- @param args ParsedArgs
--- @return nil
FLAG_HANDLERS["--post-link"]      = function(args)
	args.flags = args.flags or {}
	args.flags.gdb_runtime     = true
	args.flags.dwarf_injection = true
	request_roots_for_group(args, "post-link")
end

-- `--dwarf-injection` also emits atom-local debug data.

-- Pass-flag handler. Reads the closed-set table, expands --all, appends to requested_set.
--- @param args ParsedArgs
--- @param a    string
--- @return nil
FLAG_HANDLERS[PASS_FLAG_DISPATCH_KEY] = function(args, a)
	local name = PASS_FLAG_TO_NAME[a] ---@type string|nil
	if name == ALL_PASSES_SENTINEL then
		request_all_passes(args)
		return
	end
	args.requested_set[#args.requested_set + 1] = name
end

--- Parse argv into a structured table. Validates against a closed enum.
--- @param argv string[]
--- @return ParsedArgs
local function parse_args(argv)
	local args = { ---@type ParsedArgs
		requested_set = {},
		sources       = {},
		unity_root    = nil,
		metadata      = nil,
		out_root      = DEFAULT_OUT_ROOT,
		project_root  = nil,
		verbose       = false,
	}

	local pos = 1 ---@type integer
	while pos <= #argv do
		local a       = argv[pos]        ---@type string
		local handler = FLAG_HANDLERS[a] ---@type FlagHandler|nil
		if handler then
			pos = handler(args, argv, pos) or pos
		elseif PASS_FLAG_TO_NAME[a] then
			FLAG_HANDLERS[PASS_FLAG_DISPATCH_KEY](args, a)
		else
			io.stderr:write("ps1_meta: unknown flag '" .. a .. "'\n")
			io.stderr:write("Run with --help for usage.\n")
			os.exit(EXIT_INTERNAL_ERROR)
		end
		pos = pos + 1
	end

	-- Default: --pre-link if no explicit pass flags were given.
	-- The first invocation of a build is always pre-link, so this avoids silently also invoking post-link work in builds without an ELF artifact.
	if #args.requested_set == 0 then request_roots_for_group(args, "pre-link") end

	if not args.metadata then
		io.stderr:write("ps1_meta: --metadata PATH is required\n")
		os.exit(EXIT_INTERNAL_ERROR)
	end

	-- `<repo>/code/duffle/word_count.metadata.h` is the canonical metadata location. 
	-- `project_root` names `<repo>`; the resolver derives `<project_root>/code` separately.
	if not args.project_root then
		local metadata_dir = duffle.dirname(duffle.normalize_path(args.metadata)) ---@type string
		local code_root    = duffle.dirname(metadata_dir)                         ---@type string
		args.project_root  = duffle.dirname(code_root)
	else
		args.project_root = duffle.normalize_path(args.project_root)
	end

	local has_unity = type(args.unity_root) == "string" and args.unity_root ~= "" ---@type boolean
	if has_unity and #args.sources > 0 then
		io.stderr:write("ps1_meta: --unity-root FILE and --source FILE are mutually exclusive\n")
		os.exit(EXIT_INTERNAL_ERROR)
	end
	if not has_unity and #args.sources == 0 then
		io.stderr:write("ps1_meta: either --unity-root FILE or at least one --source FILE is required\n")
		os.exit(EXIT_INTERNAL_ERROR)
	end

	-- Post-link opt-ins (--gdb-runtime, --dwarf-injection) write output that depends on the linked ELF.
	-- Without --elf the metaprogram can't satisfy those requests, so refuse loud and early.
	-- This covers the explicit --post-link batch, --dwarf-injection by itself, and --gdb-runtime by itself.
	local flags      = args.flags or {}                             ---@type PassFlags
	local elf_path   = flags.elf_path                               ---@type string|nil
	local has_elf    = type(elf_path) == "string" and #elf_path > 0 ---@type boolean
	local post_links = flags.gdb_runtime or flags.dwarf_injection   ---@type boolean
	if post_links and not has_elf then
		io.stderr:write("ps1_meta: --elf PATH is required for post-link output\n")
		os.exit(EXIT_INTERNAL_ERROR)
	end

	return args
end

-- ════════════════════════════════════════════════════════════════════════════
-- Build ctx from parsed args
-- ════════════════════════════════════════════════════════════════════════════

--- Build the PassCtx from parsed args. Exact mode opens only the repeated `--source` inputs;
--- unity mode delegates direct-include resolution to duffle.resolve_source_corpus`. 
--- Scanning remains pass-owned (`src.scan`).
--- @param args ParsedArgs
--- @return PassCtx
local function build_ctx(args)
	local normalized_project_root  = duffle.normalize_path(args.project_root) ---@type string
	local project_root             = normalized_project_root                  ---@type string
	local project_root_is_absolute = normalized_project_root:match("^%a:/")   ---@type boolean
		or normalized_project_root:sub(1, 2) == "//"
		or normalized_project_root:sub(1, 1) == "/"
	if not project_root_is_absolute then
		-- canonical_path_key validates ordinary relative paths and rejects drive-relative paths before the absolute-path rewrite is performed.
		duffle.canonical_path_key(normalized_project_root)
		project_root = duffle.normalize_path(duffle.to_absolute_path(normalized_project_root))
	else
		-- Do not route POSIX/UNC/drive-absolute paths through to_absolute_path.
		duffle.canonical_path_key(project_root)
	end
	local resolution ---@type Corpus
	if args.unity_root then
		local ok_resolve, resolved = pcall(duffle.resolve_source_corpus, { ---@type boolean, Corpus|string
			unity_root   = args.unity_root,
			project_root = project_root,
		})
		if not ok_resolve then
			io.stderr:write("ps1_meta: cannot resolve --unity-root " .. tostring(args.unity_root) .. ": " .. tostring(resolved) .. "\n")
			os.exit(EXIT_INTERNAL_ERROR)
		end
		resolution = resolved
	else
		local ok_exact, exact = pcall(duffle.resolve_exact_sources, { ---@type boolean, Corpus|string
			sources      = args.sources,
			project_root = project_root,
		})
		if not ok_exact then
			io.stderr:write("ps1_meta: cannot resolve --source: " .. tostring(exact) .. "\n")
			os.exit(EXIT_INTERNAL_ERROR)
		end
		resolution = exact
	end

	local corpus = { ---@type Corpus
		unity_root              = resolution.unity_root,
		project_root            = resolution.project_root,
		code_root               = resolution.code_root,
		source_order            = resolution.source_order,
		sources_by_path         = resolution.sources_by_path,
		sources_by_dir          = resolution.sources_by_dir,
		atoms_by_name           = {},
		binds_by_name           = {},
		atom_infos              = {},
		register_alias_registry = {},
		type_name_registry      = {},
		atom_views              = {},
		atom_ctxs               = {},
		atom_phases             = {},
		word_counts             = {},
		components              = {},
		atom_bundles            = {},
		collisions              = {},
		resolver                = resolution.resolver,
	}
	local ctx = { ---@type PassCtx
		metadata_path = args.metadata,
		shared        = { corpus = corpus },
		out_root      = args.out_root,
		project_root  = corpus.project_root,
		flags         = args.flags or {},
		verbose       = args.verbose,
	}

	-- Source records and directory buckets are owned by the corpus.
	-- Consumers read `corpus.source_order` and `corpus.sources_by_dir` directly.
	-- The corpus is the sole source of truth for source records and module grouping; `ctx` only holds per-pass execution state.
	return ctx
end

-- ════════════════════════════════════════════════════════════════════════════
-- Topological sort (Kahn's algorithm + cycle detection)
-- ════════════════════════════════════════════════════════════════════════════

--- Topologically sort the requested pass set, augmented with all transitive deps.
--- Detects cycles and errors out with details.
--- @param passes        table<string, PassDescriptor>
--- @param requested_set string[]
--- @return string[]  -- execution order
---
--- Dependency closure, in-degree calculation, queue seeding, and sorting are local blocks.
--- Keeping these blocks local makes the topological sort self-contained.
local function topo_sort(passes, requested_set)
	-- Dependency closure: include every pass transitively required by `requested_set`.
	local needed = {}                                               ---@type table<string, boolean>  -- bag: pass name -> needed
	for _, name in ipairs(requested_set) do needed[name] = true end ---@type integer, string
	local changed = true                                            ---@type boolean
	while changed do
		changed = false
		for name, _ in pairs(needed) do ---@type string, boolean
			local pass = passes[name] ---@type PassDescriptor
			if not pass then error("unknown pass '" .. name .. "' requested") end
			for _, dep in ipairs(pass.deps) do ---@type integer, string
				if not needed[dep] then
					needed[dep] = true
					changed = true
				end
			end
		end
	end

	-- In-degree calculation: count each needed pass's needed dependencies.
	local in_degree = {}                                    ---@type table<string, integer>  -- bag: pass name -> in-degree
	for name, _ in pairs(needed) do in_degree[name] = 0 end ---@type string, boolean
	for name, _ in pairs(needed) do                         ---@type string, boolean
		for _, dep in ipairs(passes[name].deps) do ---@type integer, string
			if needed[dep] then
				in_degree[name] = in_degree[name] + 1
			end
		end
	end

	-- Ready-queue seeding: add zero-in-degree passes in deterministic order.
	local ready = {}                     ---@type string[]
	for name, deg in pairs(in_degree) do ---@type string, integer
		if deg == 0 then ready[#ready + 1] = name end
	end
	table.sort(ready)

	-- Ready-queue drain: decrement dependents when each pass is emitted.
	-- Newly-zero-degree passes are inserted back into the ready queue (kept sorted).
	local order = {} ---@type string[]
	while #ready > 0 do
		local just_finished = table.remove(ready, 1) ---@type string
		order[#order + 1] = just_finished
		for name, _ in pairs(needed) do ---@type string, boolean
			if name ~= just_finished then
				for _, dep in ipairs(passes[name].deps) do ---@type integer, string
					if dep == just_finished then
						in_degree[name] = in_degree[name] - 1
						if in_degree[name] == 0 then
							ready[#ready + 1] = name
							table.sort(ready)
						end
					end
				end
			end
		end
	end

	-- Cycle detection: if `order` doesn't include all needed passes, some are stuck with in_degree > 0
	-- (the cycle closed on itself before Kahn could process them).
	-- Without this check, a fully-closed cycle (e.g. A -> B -> A) would silently return an empty order list, leaving the orchestrator to dispatch nothing.
	local needed_count = 0                                        ---@type integer
	for _ in pairs(needed) do needed_count = needed_count + 1 end ---@type string -- count hash entries; Lua's #t doesn't work
	if #order ~= needed_count then
		for name, deg in pairs(in_degree) do ---@type string, integer
			if deg > 0 then
				error("dependency cycle detected involving pass '" .. name .. "'")
			end
		end
	end

	return order
end

-- ════════════════════════════════════════════════════════════════════════════
-- Main Orchestrator
-- ════════════════════════════════════════════════════════════════════════════

--- (internal) Write every pass error to stderr.
--- Returns true only when the pass kind still stops the build.
--- @param pass_name string
--- @param pass      PassDescriptor
--- @param result    PassResult
--- @return boolean
local function report_validation_errors(pass_name, pass, result)
	local has_errors = result.errors and #result.errors > 0 ---@type boolean
	if not has_errors then return false end
	for _, e in ipairs(result.errors) do ---@type integer, Finding
		io.stderr:write(string.format("[%s] line %d: %s\n", pass_name, e.line or 0, e.msg or ""))
	end
	return PASS_KIND_STOP_ON_ERROR[pass.kind] == true
end

--- (internal) Run each pass in `order` in topological sequence.
--- @param ctx   PassCtx
--- @param order string[]
--- @return boolean  -- true if any validation errors were reported
local function dispatch_passes(ctx, order)
	local had_errors = false             ---@type boolean
	for _, pass_name in ipairs(order) do ---@type integer, string
		local pass   = PASSES[pass_name]    ---@type PassDescriptor
		local mod    = require(pass.module) ---@type PassModule
		local result = mod.run(ctx)         ---@type PassResult
		if report_validation_errors(pass_name, pass, result) then
			had_errors = true
		end
	end
	return had_errors
end

--- Main entry point. Runs the requested passes in dep-topological order.
--- @param argv string[]
--- @return nil
local function main(argv)
	local ok, err = pcall(function() ---@type boolean, string|nil
		local args = parse_args(argv) ---@type ParsedArgs
		local ctx  = build_ctx(args)  ---@type PassCtx
		
		local requested = args.requested_set           ---@type string[]
		local closed    = topo_sort(PASSES, requested) ---@type string[]

		local had_errors = dispatch_passes(ctx, closed) ---@type boolean
		if had_errors then os.exit(EXIT_VALIDATION_ERRORS) end
	end)

	if not ok then
		io.stderr:write("[ps1_meta] internal error: " .. tostring(err) .. "\n")
		os.exit(EXIT_INTERNAL_ERROR)
	end

	os.exit(EXIT_OK)
end

-- Module export for in-process consumers (tests that dofile this script).
-- The conditional `main(...)` call below only fires when this file is invoked as the entry script (arg[0] ends in "ps1_meta.lua");
-- in dofile() mode (test's arg[0] does not match), main() is skipped and the chunk returns `_M` to the caller.
local _M = { ---@type Ps1MetaMod
	PASSES                   = PASSES,
	PASS_KIND_STOP_ON_ERROR  = PASS_KIND_STOP_ON_ERROR,
	parse_args               = parse_args,
	build_ctx                = build_ctx,
}

if arg and arg[0] and arg[0]:match("ps1_meta%.lua$") then
	main({...})
end

return _M
