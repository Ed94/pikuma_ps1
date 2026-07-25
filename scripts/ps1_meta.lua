--- ps1_meta.lua — Orchestrator entry point for the tape-atom metaprogram.
---
--- Dispatches to pass modules under `scripts/passes/`, resolving dependencies topologically (Kahn's algorithm + cycle detection).
---
--- **Architecture**:
---   - **PASSES table** — declarative dep graph (data, not code).
---   - **FLAG_HANDLERS table** — maps CLI flags to handlers.
---   - **parse_args** → **build_ctx** (resolves unity/direct includes or exact sources; no semantic scanning) → **topo_sort** → **dispatch_passes**.
---   - The first pass in the dep graph is `scan-source` (see `passes/scan_source.lua`).
---     It calls `duffle.scan_source` once per source to produce the fat `SourceScan` payload, which is attached to each `src.scan`. 
---     Every other pass that reads source structure depends on `scan-source` and consumes `src.scan` as a read-only. 
---
--- **Conventions**: tabs (1/level), EmmyLua annotations, no regex,
--- Lua 5.3 compatible.
---
-- ════════════════════════════════════════════════════════════════════════════
-- Module-scope requires + package.path setup
-- ════════════════════════════════════════════════════════════════════════════

-- Bootstrap: load `duffle_paths.lua` via this script's own path.
-- Use `arg[0]` when this file is the entry script (`arg[0]` ends in "ps1_meta.lua");
-- fall back to `debug.getinfo(1, "S").source` when this file is being dofile()'d or require()'d (in which case `arg[0]` is the *caller's* path, not ours).
-- That single statement: (a) sets `package.path` + `package.cpath` (via cached `git rev-parse`), (b) at the bottom returns `require("duffle")`.
-- So the dofile's return value is the duffle module.
local _is_entry_script = arg and arg[0] and arg[0]:match("ps1_meta%.lua$") ~= nil
local _bootstrap_src
if _is_entry_script then
	_bootstrap_src = arg[0]
else
	-- debug.getinfo(1, "S").source returns "@<path>" for the current chunk;
	-- strip the leading "@" so the directory match works in both cases.
	_bootstrap_src = debug.getinfo(1, "S").source:sub(2)
end
local duffle = dofile((_bootstrap_src:match("(.*[/\\])") or "./") .. "duffle_paths.lua")

-- ════════════════════════════════════════════════════════════════════════════
-- Constants
-- ════════════════════════════════════════════════════════════════════════════

-- Exit codes (per the --help text and the post-build summary convention).
local EXIT_OK                  = 0
local EXIT_VALIDATION_ERRORS   = 1
local EXIT_INTERNAL_ERROR      = 2

-- Default --out-root value if not provided.
local DEFAULT_OUT_ROOT         = "build/gen"

-- Sentinel for "all passes" in `PASS_FLAG_TO_NAME`. Distinguishes `--all` from the per-pass flags (which map to individual pass names).
local ALL_PASSES_SENTINEL      = "__all__"

-- Sentinel key for the pass-flag dispatcher in `FLAG_HANDLERS`. 
-- The actual pass names are looked up via `PASS_FLAG_TO_NAME`, not direct dispatch, so this key never matches a real flag.
local PASS_FLAG_DISPATCH_KEY   = "__pass__"

-- ════════════════════════════════════════════════════════════════════════════
-- Type declarations
-- ════════════════════════════════════════════════════════════════════════════

--- @class PassDescriptor
--- @field module string       -- module name passed to require()
--- @field kind   string       -- "shared" | "header-output" | "validation" | "diagnostic" | "report"
---                            -- Report severity is independent from process exit policy (see PASS_KIND_STOP_ON_ERROR).
--- @field deps   string[]     -- names of upstream passes
--- @field groups string[]?    -- OPTIONAL build-phase groups this pass is a root of
---                            -- (e.g. { "pre-link" }, { "post-link" }); absent ⇒ dependency-only
--- @field desc   string       -- human description (used by --help + ASCII graph)
--- @field out    PassOutput[] -- output paths (used by --dry-run + report)

--- @class PassOutput
--- @field kind          string  -- "header" | "report"
--- @field path_template string  -- e.g. "<source_dir>/gen/<basename>.macs.h"

--- @class SourceFile
--- @field path     string  -- absolute path to the source file
--- @field text     string  -- the full source text
--- @field dir      string  -- the directory containing the source
--- @field basename string  -- filename without extension

--- @class PassCtx
--- @field metadata_path      string                 -- path to word_count.metadata.h
--- @field shared             table                  -- cross-pass shared state
--- @field shared.corpus      table                  -- canonical authored-source/project projection
--- @field out_root           string                 -- output root (e.g. "build/gen")
--- @field project_root       string                 -- PS1 repository root
--- @field upstream           table<string, table>   -- per-pass output accumulator
--- @field flags              table                  -- CLI flags + per-pass stash
--- @field dry_run            boolean                -- if true, compute but don't write
--- @field verbose            boolean                -- if true, log diagnostic info

--- @class PassOutputEntry
--- @field [string] string  -- dynamic shape; key is the output kind
	-- (e.g. "macs_h", "offsets_h", "errors_h", "annotations_txt", "static_analysis_txt", "summary_txt"), value is the path

--- @class Finding
--- @field line integer  -- source line (or 0 for pass-level)
--- @field msg  string   -- finding message

--- @class PassResult
--- @field outputs  PassOutputEntry[] -- emitted file paths
--- @field errors   Finding[]         -- build-stops (per-pass kind policy)
--- @field warnings Finding[]         -- informational

--- @class ParsedArgs
--- @field requested_set string[]   -- pass names to run (explicit --all expanded)
--- @field sources       string[]   -- exact --source values, retained in CLI order
--- @field unity_root    string|nil -- --unity-root value; mutually exclusive with sources
--- @field metadata      string     -- --metadata value
--- @field out_root      string     -- --out-root value (default "build/gen")
--- @field project_root  string     -- PS1 repository root (derived from metadata by default)
--- @field dry_run       boolean    -- if true, compute but don't write
--- @field verbose       boolean    -- if true, log diagnostic info

-- ════════════════════════════════════════════════════════════════════════════
-- PASSES Table
-- ════════════════════════════════════════════════════════════════════════════

-- Build-phase groups: Each PASSES row may declare membership in one or more named groups via `groups = { ... }`.
-- The CLI flags --pre-link and --post-link request the *roots* of their group; topo_sort then closes transitive dependencies from those roots,
-- and dispatch_passes runs every pass in the resulting closure without phase-filtering.
--
-- A row without a `groups` entry is dependency-only: it runs only when a transitive dep requests it, 
-- but it remains directly requestable through its explicit CLI flag (e.g. --atoms-source-map, --scan-source).

local PASSES = {
	["scan-source"] = {
		module = "passes.scan_source",
		kind   = "shared", deps = {},
		desc   = "Walk each source once; produce the fat SourceScan payload for downstream passes",
		out    = {},
	},
	["word-counts"] = {
		module = "passes.word_count_eval",
		kind   = "shared", deps = {},
		desc   = "Build the shared metadata table (metadata.h + .macs.h)",
		out    = {},
	},
	components = {
		module = "passes.components",
		kind   = "header-output",
		deps   = {"scan-source", "word-counts"},
		desc   = "Emit mac_X macros from MipsAtomComp_ declarations",
		out    = { { kind = "header", path_template = "<source_dir>/gen/<basename>.macs.h" } },
	},
	["emission-model"] = {
		module = "passes.emission_model",
		kind   = "validation",
		deps   = {"components"},
		desc   = "Build canonical per-atom words, markers, and invocation ancestry",
		out    = {},
	},
	annotation = {
		module = "passes.annotation",
		kind   = "validation",
		deps   = {"scan-source", "word-counts"},
		desc   = "Validate atom DSL usage; emit errors.h + annotations.txt",
		out    = {
			{ kind = "report", path_template = "<out_root>/<basename>.errors.h" },
			{ kind = "report", path_template = "<out_root>/<basename>.annotations.txt" },
		},
	},
	offsets = {
		module = "passes.offsets",
		kind   = "header-output",
		deps   = {"scan-source", "word-counts", "components", "emission-model"},
		groups = { "pre-link" },
		desc   = "Compute branch offsets for atom_label / atom_offset",
		out    = { { kind = "header", path_template = "<source_dir>/gen/<basename>.offsets.h" } },
	},
	["static-analysis"] = {
		module = "passes.static_analysis",
		-- "diagnostic" — every `error`/`warning` finding is written to the report file;
		-- the orchestrator does NOT exit non-zero on these findings (see PASS_KIND_STOP_ON_ERROR).
		-- Report severity is independent from process exit policy.
		kind   = "diagnostic",
		deps   = {"scan-source", "word-counts", "components", "emission-model"},
		desc   = "Static analysis: GTE pipeline-fill, mac_yield uniformity, ABI handoff, GPU port-store shape, per-atom cycle budget, type consistency",
		out    = { { kind = "report", path_template = "<out_root>/<basename>.static_analysis.txt" } },
	},
	["atoms-source-map"] = {
		module = "passes.atoms_source_map",
		kind   = "header-output",
		deps   = {"word-counts", "components", "emission-model"},
		desc   = "Emit gen/<basename>.atoms.sourcemap.txt (per-.word C source line map for gdb debugging) AND gen/<basename>.atoms.provenance.txt (per-.word provenance; each word tagged with its call-site file:line and, when emitted by a mac_X(...) component invocation, the component's definition file:line). Consumed by passes/dwarf_injection.lua to synthesize DW_TAG_inlined_subroutine instances for source-level Step Into on component invocations.",
		out    = {
			{ kind = "report", path_template = "<out_root>/<basename>.atoms.sourcemap.txt"   },
			{ kind = "report", path_template = "<out_root>/<basename>.atoms.provenance.txt" },
		},
	},
	["dwarf-injection"] = {
		module = "passes.dwarf_injection",
		kind   = "shared",
		deps   = {"scan-source", "atoms-source-map"},
		groups = { "post-link" },
		desc   = "Inject per-atom .debug_line + .debug_aranges (F') + per-atom .debug_info subprogram + per-wave-context-reg .debug_info variables (G') into the ELF (post-link; writes 7 section .bin blobs plus one deterministic .gdbinit sidecar). (rbind composite) reads ctx.sources[i].scan to find atom_bind(Binds_X) atoms + their Binds_X struct fields; emits per-Binds_X DW_TAG_structure_type DIEs + per-rbind-atom DW_TAG_variable 'bind_args' DIEs with piece-chain DW_OP_bregN/DW_OP_piece location expressions.",
		out    = {
			{ kind = "report", path_template = "<out_root>/<basename>.dwarf_line.bin"     },
			{ kind = "report", path_template = "<out_root>/<basename>.dwarf_aranges.bin"  },
			{ kind = "report", path_template = "<out_root>/<basename>.dwarf_rnglists.bin" },
			{ kind = "report", path_template = "<out_root>/<basename>.dwarf_abbrev.bin"   },
			{ kind = "report", path_template = "<out_root>/<basename>.dwarf_info.bin"     },
			{ kind = "report", path_template = "<out_root>/<basename>.dwarf_str.bin"      },
			{ kind = "report", path_template = "<out_root>/<basename>.dwarf_loc.bin"      },
			{ kind = "report", path_template = "<out_root>/<basename>.gdbinit"            },
		},
	},
	report = {
		module = "passes.report",
		kind   = "report",
		deps   = {"annotation", "static-analysis"},
		groups = { "pre-link" },
		desc   = "Render the per-project summary",
		out    = { { kind = "report", path_template = "<out_root>/annotation_validation.txt" } },
	},
}

-- ────────────────────────────────────────────────────────────────────────────
-- Phase-root selection: derive the sorted set of roots belonging to a named build-phase group, then append them to `args.requested_set`.
-- topo_sort closes the transitive deps from there; dispatch_passes runs every resolved pass without phase-filtering.
-- ────────────────────────────────────────────────────────────────────────────

--- @param group_name string  -- the build-phase group ("pre-link" | "post-link")
--- @return string[]          -- sorted root pass names belonging to that group
local function roots_for_group(group_name)
	local names = {}
	for name, pass in pairs(PASSES) do
		if pass.groups then
			for _, g in ipairs(pass.groups) do
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
--- @param args ParsedArgs
--- @param group_name string
local function request_roots_for_group(args, group_name)
	local roots = roots_for_group(group_name)
	if #roots == 0 then
		error(string.format("ps1_meta: build-phase group %q has zero roots in PASSES; check PASSES rows for a `groups = { %q }` field"
			, group_name, group_name))
	end
	for _, name in ipairs(roots) do
		args.requested_set[#args.requested_set + 1] = name
	end
end

-- Pass-kind taxonomy: Which kinds stop the build on errors?
--
-- Report severity is independent from process exit policy. A "diagnostic" pass still writes every `error`/`warning` finding into its report file,
-- but `report_validation_errors` returns early for non-stopping kinds, so nothing is printed to stderr and the orchestrator does not exit non-zero.
-- Adding a new pass kind requires listing it here explicitly; an unknown kind must not silently fall back to "true".
local PASS_KIND_STOP_ON_ERROR = {
	["shared"]        = false,
	["header-output"] = true,
	["validation"]    = true,
	["diagnostic"]    = false,
	["report"]        = false,
}

-- Closed set of CLI flags -> pass names.
-- Per-pass flags (e.g. --word-counts) live here; phase flags (--pre-link, --post-link, --all)
-- live in FLAG_HANDLERS because they own side effects or invoke group-derivation logic.
-- dwarf-injection is *also* a per-pass opt-in flag, but its selection + opt-in state are both owned by the explicit FLAG_HANDLERS entry below
-- (it sets args.flags.dwarf_injection and appends "dwarf-injection" to requested_set), so it is intentionally absent from this table.
local PASS_FLAG_TO_NAME = {
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
local function request_all_passes(args)
	local names = {}
	for name in pairs(PASSES) do names[#names + 1] = name end
	table.sort(names)
	for _, n in ipairs(names) do
		args.requested_set[#args.requested_set + 1] = n
	end
end

-- Per-flag handlers. Each handler takes (args, argv, arg_idx) and returns the new arg_idx (so multi-arg flags like --source FILE advance it). 
-- Returning nil + os.exit() handles termination flags (--help). 

local FLAG_HANDLERS = {}

-- ════════════════════════════════════════════════════════════════════════════
-- CLI parsing
-- ════════════════════════════════════════════════════════════════════════════

--- Print the CLI usage to stdout and exit 0.
local function print_help()
	io.write([[
ps1_meta.lua - Tape-atom metaprogram orchestrator

USAGE:
  ps1_meta.lua [PASS_FLAGS] [COMMON_FLAGS]

PASS_FLAGS:
  Pick a phase or one-or-more individual passes:
    --pre-link            [phase; default] Run the pre-link group + transitive deps.
                         The root set is data-driven from each PASSES row's
                         `groups` field; no parallel name list is maintained.
    --post-link           [phase] Run the post-link group + transitive deps.
                         Requires --elf. Sets --gdb-runtime and --dwarf-injection
                         opt-in flags as well.
    --all                 Select every row of the PASSES table. Pass-local opt-in
                         guards remain active, so --dwarf-injection still requires
                         --elf and --gdb-runtime still requires a runtime emission.
  Or pick any subset:
    --scan-source         Scan sources into the fat SourceScan payload
    --word-counts         Load metadata.h + scan for existing .macs.h
    --components          Generate <module>/gen/<basename>.macs.h
    --validate            Run atom annotation DSL validation
    --offsets             Generate <module>/gen/<basename>.offsets.h
    --atoms-source-map    Generate <basename>.atoms.sourcemap.txt per source
    --dwarf-injection     [opt-in] Select the post-link dwarf-injection pass + set the
                         opt-in flag. Requires --elf.
    --static-analysis     Static analysis: GTE pipeline-fill, mac_yield, ABI handoff, cycle budget
    --report              Render per-project summary

COMMON_FLAGS:
  --unity-root FILE     Unity source root: load root + direct quoted authored
                        includes only. Mutually exclusive with --source.
  --source FILE         Exact source file to process (repeatable, never expands
                        includes). Mutually exclusive with --unity-root.
  --metadata PATH       Path to metadata.h (required)
  --out-root DIR        Output root for reports (default: build/gen)
  --project-root DIR    PS1 repository root (default: derived from
                        <repo>/code/duffle/word_count.metadata.h)
  --gdb-runtime         Also emit <out_root>/gdb_tape_atoms_runtime.gdb (post-link, requires --elf)
  --elf PATH            Path to linked .elf (for --gdb-runtime / --dwarf-injection)
  --dry-run             Print dep order (alphabetical); exit 0 without running
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

local FLAG_VALUE_NAMES = {
	["--source"]       = "FILE",
	["--unity-root"]   = "FILE",
	["--metadata"]     = "PATH",
	["--out-root"]     = "DIR",
	["--project-root"] = "DIR",
	["--elf"]          = "PATH",
}

local function require_flag_value(argv, arg_idx, flag)
	local value      = argv[arg_idx + 1]
	local next_known = type(value) == "string"
		and (FLAG_HANDLERS[value] ~= nil or PASS_FLAG_TO_NAME[value] ~= nil)
	if value == nil or next_known then
		io.stderr:write("ps1_meta: " .. flag .. " requires "
			.. FLAG_VALUE_NAMES[flag] .. "\n")
		os.exit(EXIT_INTERNAL_ERROR)
	end
	return value, arg_idx + 1
end

-- Per-flag handlers. Each takes (args, argv, arg_idx) and returns the new arg_idx (so multi-arg flags like --source FILE advance it).
-- Termination flags like --help call os.exit() instead.
-- Populated AFTER print_help so the --help handler can reference it as an upvalue (Lua resolves locals at closure-call time, 
-- but if the closure is defined before the local, it falls back to _G). 
FLAG_HANDLERS["--help"] = function(args)
	print_help()
	os.exit(0)
end

FLAG_HANDLERS["--dry-run"] = function(args) args.dry_run = true end
FLAG_HANDLERS["--verbose"] = function(args) args.verbose = true end
FLAG_HANDLERS["--source"] = function(args, argv, arg_idx)
	local value, value_idx = require_flag_value(argv, arg_idx, "--source")
	args.sources[#args.sources + 1] = value
	return value_idx
end
FLAG_HANDLERS["--unity-root"] = function(args, argv, arg_idx)
	local value, value_idx = require_flag_value(argv, arg_idx, "--unity-root")
	args.unity_root = value
	return value_idx
end
FLAG_HANDLERS["--metadata"] = function(args, argv, arg_idx)
	local value, value_idx = require_flag_value(argv, arg_idx, "--metadata")
	args.metadata = value
	return value_idx
end
FLAG_HANDLERS["--out-root"] = function(args, argv, arg_idx)
	local value, value_idx = require_flag_value(argv, arg_idx, "--out-root")
	args.out_root = value
	return value_idx
end
FLAG_HANDLERS["--project-root"] = function(args, argv, arg_idx)
	local value, value_idx = require_flag_value(argv, arg_idx, "--project-root")
	args.project_root = value
	return value_idx
end

-- Per-pass stash flags. Read by `passes/atoms_source_map.lua` to opt into the post-link gdb-runtime emission.
-- Same shape as the existing per-flag handlers. mutates `args.flags` (which propagates into `ctx.flags`).
FLAG_HANDLERS["--gdb-runtime"] = function(args)
	args.flags = args.flags or {}
	args.flags.gdb_runtime = true
end
FLAG_HANDLERS["--elf"] = function(args, argv, arg_idx)
	local value, value_idx = require_flag_value(argv, arg_idx, "--elf")
	args.flags = args.flags or {}
	args.flags.elf_path = value
	return value_idx
end
-- Enable DWARF injection (default OFF). Opts in to the post-link pass and sets the flag in one shot.
-- The explicit handler below owns both selection and opt-in state, so --dwarf-injection is intentionally absent from PASS_FLAG_TO_NAME.
FLAG_HANDLERS["--dwarf-injection"] = function(args)
	args.flags                 = args.flags or {}
	args.flags.dwarf_injection = true
	args.requested_set[#args.requested_set + 1] = "dwarf-injection"
end
-- Build-phase flags: --pre-link and --post-link request the roots of their declared groups (see roots_for_group).
-- topo_sort closes transitive deps from those roots; dispatch_passes runs every pass in the resolved closure without phase-filtering.
FLAG_HANDLERS["--pre-link"] = function(args)
	request_roots_for_group(args, "pre-link")
end
-- Batch post-link phase: gdb-runtime + dwarf-injection in one luajit cold start.
-- Sets the same opt-in flags as --gdb-runtime + --dwarf-injection and selects the post-link build-phase group.
-- elf is required; parse_args enforces it after all flags are parsed.
FLAG_HANDLERS["--post-link"]      = function(args)
	args.flags = args.flags or {}
	args.flags.gdb_runtime     = true
	args.flags.dwarf_injection = true
	request_roots_for_group(args, "post-link")
end

-- `--dwarf-injection` also emits atom-local debug data.

-- Pass-flag handler. Reads the closed-set table, expands --all, appends to requested_set.
FLAG_HANDLERS[PASS_FLAG_DISPATCH_KEY] = function(args, a)
	local name = PASS_FLAG_TO_NAME[a]
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
	local args = {
		requested_set = {},
		sources       = {},
		unity_root    = nil,
		metadata      = nil,
		out_root      = DEFAULT_OUT_ROOT,
		project_root  = nil,
		dry_run       = false,
		verbose       = false,
	}

	local pos = 1
	while pos <= #argv do
		local a       = argv[pos]
		local handler = FLAG_HANDLERS[a]
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
		local metadata_dir = duffle.dirname(duffle.normalize_path(args.metadata))
		local code_root    = duffle.dirname(metadata_dir)
		args.project_root  = duffle.dirname(code_root)
	else
		args.project_root = duffle.normalize_path(args.project_root)
	end

	local has_unity = type(args.unity_root) == "string" and args.unity_root ~= ""
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
	local flags      = args.flags or {}
	local elf_path   = flags.elf_path
	local has_elf    = type(elf_path) == "string" and #elf_path > 0
	local post_links = flags.gdb_runtime or flags.dwarf_injection
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
	local normalized_project_root = duffle.normalize_path(args.project_root)
	local project_root            = normalized_project_root
	local project_root_is_absolute = normalized_project_root:match("^%a:/")
		or normalized_project_root:sub(1, 2) == "//"
		or normalized_project_root:sub(1, 1) == "/"
	if not project_root_is_absolute then
		-- canonical_path_key validates ordinary relative paths and rejects
		-- drive-relative paths before the legacy display-path helper is used.
		duffle.canonical_path_key(normalized_project_root)
		project_root = duffle.normalize_path(duffle.to_absolute_path(normalized_project_root))
	else
		-- Do not route POSIX/UNC/drive-absolute paths through to_absolute_path.
		duffle.canonical_path_key(project_root)
	end
	local resolution
	if args.unity_root then
		local ok_resolve, resolved = pcall(duffle.resolve_source_corpus, {
			unity_root   = args.unity_root,
			project_root = project_root,
		})
		if not ok_resolve then
			io.stderr:write("ps1_meta: cannot resolve --unity-root "
				.. tostring(args.unity_root) .. ": " .. tostring(resolved) .. "\n")
			os.exit(EXIT_INTERNAL_ERROR)
		end
		resolution = resolved
	else
		local source_order    = {}
		local sources_by_path = {}
		local resolver = {
			resolved = {},
			skipped  = {},
			shadowed = {},
		}
		for _, input_path in ipairs(args.sources) do
			local path = duffle.normalize_path(input_path)
			local key_ok, key_or_error = pcall(duffle.canonical_path_key, path)
			if not key_ok then
				error("ps1_meta: invalid --source " .. input_path .. ": "
					.. tostring(key_or_error), 0)
			end
			local file = io.open(path, "r")
			if not file then
				io.stderr:write("ps1_meta: cannot open --source " .. input_path .. "\n")
				os.exit(EXIT_INTERNAL_ERROR)
			end
			local text = file:read("*a")
			file:close()

			local source = {
				path     = path,
				text     = text,
				dir      = duffle.dirname(path),
				basename = duffle.basename_no_ext(path),
			}
			source_order[#source_order + 1] = source
			local key = key_or_error
			if not sources_by_path[key] then sources_by_path[key] = source end
			resolver.resolved[#resolver.resolved + 1] = {
				include_path  = path,
				include_text  = nil,
				root_source   = nil,
				root_line     = nil,
				candidate_a   = path,
				candidate_b   = nil,
				selected_path = path,
				disposition   = "exact",
			}
		end
		resolution = {
			unity_root      = nil,
			project_root    = project_root,
			code_root       = duffle.normalize_path(project_root .. "/code"),
			source_order    = source_order,
			sources_by_path = sources_by_path,
			sources_by_dir  = duffle.group_sources_by_dir(source_order),
			resolver        = resolver,
		}
	end

	local corpus = {
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
		component_body_index    = {},
		collisions              = {},
		resolver                = resolution.resolver,
	}
	local ctx = {
		metadata_path = args.metadata,
		shared        = { corpus = corpus },
		upstream      = {},
		out_root      = args.out_root,
		project_root  = corpus.project_root,
		flags         = args.flags or {},
		dry_run       = args.dry_run,
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
	local needed = {}
	for _, name in ipairs(requested_set) do needed[name] = true end
	local changed = true
	while changed do
		changed = false
		for name, _ in pairs(needed) do
			local pass = passes[name]
			if not pass then
				error("unknown pass '" .. name .. "' requested")
			end
			for _, dep in ipairs(pass.deps) do
				if not needed[dep] then
					needed[dep] = true
					changed = true
				end
			end
		end
	end

	-- In-degree calculation: count each needed pass's needed dependencies.
	local in_degree = {}
	for name, _ in pairs(needed) do in_degree[name] = 0 end
	for name, _ in pairs(needed) do
		for _, dep in ipairs(passes[name].deps) do
			if needed[dep] then
				in_degree[name] = in_degree[name] + 1
			end
		end
	end

	-- Ready-queue seeding: add zero-in-degree passes in deterministic order.
	local ready = {}
	for name, deg in pairs(in_degree) do
		if deg == 0 then ready[#ready + 1] = name end
	end
	table.sort(ready)

	-- Ready-queue drain: decrement dependents when each pass is emitted.
	-- Newly-zero-degree passes are inserted back into the ready queue (kept sorted).
	local order = {}
	while #ready > 0 do
		local just_finished = table.remove(ready, 1)
		order[#order + 1] = just_finished
		for name, _ in pairs(needed) do
			if name ~= just_finished then
				for _, dep in ipairs(passes[name].deps) do
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
	local needed_count = 0
	for _ in pairs(needed) do needed_count = needed_count + 1 end  -- count hash entries; Lua's #t doesn't work
	if #order ~= needed_count then
		for name, deg in pairs(in_degree) do
			if deg > 0 then
				error("dependency cycle detected involving pass '" .. name .. "'")
			end
		end
	end

	return order
end

-- ════════════════════════════════════════════════════════════════════════════
-- ASCII dep graph renderer (Decision 6 in the spec)
-- ════════════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════════════
-- Topological dep-order printer (used by --dry-run).
-- Re-render the PASSES graph manually in `docs/guide_metaprogram_ssdl.md` if you need an updated visual;
-- The canonical ASCII view there is regenerated by hand whenever PASSES rows change.
-- ════════════════════════════════════════════════════════════════════════════
local function render_dep_order(passes, closed)
	local lines = {}
	lines[#lines + 1] = "[ps1_meta] Resolved dependency order (closed under deps):"
	for pass_idx, name in ipairs(closed) do
		local p        = passes[name]
		local deps_str = (#p.deps == 0) and "(no deps)" or
			"(deps: " .. table.concat(p.deps, ", ") .. ")"
		lines[#lines + 1] = string.format("  %d. %-22s %-45s [%s]",
			pass_idx, name, deps_str, p.kind)
	end
	return table.concat(lines, "\n") .. "\n"
end

-- ════════════════════════════════════════════════════════════════════════════
-- Main Orchestrator
-- ════════════════════════════════════════════════════════════════════════════

--- (internal) Push a pass's outputs + warnings into `ctx.upstream[name]` for downstream passes to consume.
--- @param ctx       PassCtx
--- @param pass_name string
--- @param result PassResult
local function accumulate_pass_result(ctx, pass_name, result)
	ctx.upstream[pass_name] = ctx.upstream[pass_name] or {}
	for _, out  in ipairs(result.outputs  or {}) do table.insert(ctx.upstream[pass_name], out)  end
	for _, warn in ipairs(result.warnings or {}) do table.insert(ctx.upstream[pass_name], warn) end
end

--- (internal) If the pass's kind is in PASS_KIND_STOP_ON_ERROR and it reported errors, write each error to stderr.
--- Returns true if any validation errors were reported.
--- @param pass_name string
--- @param pass      PassDescriptor
--- @param result    PassResult
--- @return boolean
local function report_validation_errors(pass_name, pass, result)
	local   has_errors = result.errors and #result.errors > 0
	if not (has_errors and PASS_KIND_STOP_ON_ERROR[pass.kind]) then return false end
	for _, e in ipairs(result.errors) do
		io.stderr:write(string.format("[%s] line %d: %s\n", pass_name, e.line or 0, e.msg or ""))
	end
	return true
end

--- (internal) Run each pass in `order` in topological sequence.
--- @param ctx   PassCtx
--- @param order string[]
--- @return boolean  -- true if any validation errors were reported
local function dispatch_passes(ctx, order)
	ctx.shared = ctx.shared or {}
	local had_errors = false
	for _, pass_name in ipairs(order) do
		local pass   = PASSES[pass_name]
		-- io.stderr:write(string.format("[ps1_meta] %-22s running\n", pass_name))
		local mod    = require(pass.module)
		local result = mod.run(ctx)
		accumulate_pass_result(ctx, pass_name, result)
		if report_validation_errors(pass_name, pass, result) then
			had_errors = true
		end
	end
	return had_errors
end

--- Main entry point. Runs the requested passes in dep-topological order.
--- @param argv string[]
local function main(argv)
	local ok, err = pcall(function()
		local args = parse_args(argv)
		local ctx  = build_ctx(args)

		local requested = args.requested_set
		local closed    = topo_sort(PASSES, requested)

		-- --dry-run: print the closed dep order and exit OK.
		-- (The hand-rendered PASSES graph lives in docs/guide_metaprogram_ssdl.md; see Decision 6.)
		if args.dry_run then
			io.write(render_dep_order(PASSES, closed))
			os.exit(EXIT_OK)
		end

		local had_errors = dispatch_passes(ctx, closed)
		if had_errors then os.exit(EXIT_VALIDATION_ERRORS) end
	end)

	if not ok then
		io.stderr:write("[ps1_meta] internal error: " .. tostring(err) .. "\n")
		os.exit(EXIT_INTERNAL_ERROR)
	end

	os.exit(EXIT_OK)
end

-- Module export for in-process consumers (tests that dofile this script).
-- The closed dep-order printer + the `PASSES` table are exposed so a test can observe the resolved dep order for synthetic PASSES tables without spawning a subprocess.
-- The conditional `main(...)` call below only fires when this file is invoked as the entry script (arg[0] ends in "ps1_meta.lua");
-- in dofile() mode (test's arg[0] does not match), main() is skipped and the chunk returns `_M` to the caller.
local _M = {
	render_dep_order         = render_dep_order,
	PASSES                   = PASSES,
	PASS_KIND_STOP_ON_ERROR  = PASS_KIND_STOP_ON_ERROR,
	parse_args               = parse_args,
	build_ctx                = build_ctx,
}

if arg and arg[0] and arg[0]:match("ps1_meta%.lua$") then
	main({...})
end

return _M
