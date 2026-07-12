--- ps1_meta.lua — Orchestrator entry point for the tape-atom metaprogram pipeline.
---
--- Dispatches to pass modules under `scripts/passes/`, resolving
--- dependencies topologically (Kahn's algorithm + cycle detection).
--- Single CLI surface (`--<pass>` flags + auto-dep expansion + --dry-run).
---
--- **Architecture**:
---   - **PASSES table** — declarative dep graph (data, not code).
---   - **FLAG_HANDLERS table** — per-flag CLI dispatchers (handler-map pattern; replaces an 8-way if/elseif chain).
---   - **parse_args** → **build_ctx** (just opens + reads source files; no inline scanning) → **topo_sort** → **dispatch_passes**.
---   - The first pass in the dep graph is `scan-source` (see `passes/scan_source.lua`). 
---     It calls `duffle.scan_source` once per source to produce the fat `SourceScan` payload, which is attached to each `src.scan`. 
---     Every other pass that reads source structure depends on `scan-source` and consumes `src.scan` as a read-only payload. 
---
--- **Conventions**: tabs (1/level), EmmyLua annotations, no regex,
--- Lua 5.3 compatible.
---
-- ════════════════════════════════════════════════════════════════════════════
-- Module-scope requires + package.path setup
-- ════════════════════════════════════════════════════════════════════════════

-- Bootstrap: load `duffle_paths.lua` via `arg[0]` (this script's own path).
-- That single statement: (a) sets `package.path` + `package.cpath` (via cached `git rev-parse`),
-- (b) at the bottom returns `require("duffle")`. So the dofile's return value is the duffle module.
local duffle = dofile((arg[0]:match("(.*[/\\])") or "./") .. "duffle_paths.lua")

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
--- @field kind   string       -- "shared" | "header-output" | "validation" | "report"
--- @field deps   string[]     -- names of upstream passes
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
--- @field sources            SourceFile[]           -- all source files in the build
--- @field metadata_path      string                 -- path to word_count.metadata.h
--- @field shared             table                  -- cross-pass shared state
--- @field shared.word_counts table<string, integer> -- populated by word-counts pass
--- @field out_root           string                 -- output root (e.g. "build/gen")
--- @field project_root       string                 -- project root (e.g. "code/")
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
--- @field requested_set string[]  -- pass names to run (explicit --all expanded)
--- @field sources       string[]  -- --source values
--- @field metadata      string    -- --metadata value
--- @field out_root      string    -- --out-root value (default "build/gen")
--- @field project_root  string    -- --project-root value (default dirname(metadata))
--- @field dry_run       boolean   -- if true, compute but don't write
--- @field verbose       boolean   -- if true, log diagnostic info

-- ════════════════════════════════════════════════════════════════════════════
-- PASSES table (data, not code) — the orchestrator's dep graph
-- ════════════════════════════════════════════════════════════════════════════

local PASSES = {
	["scan-source"] = {
		module = "passes.scan_source",
		kind   = "shared",
		deps   = {},
		desc   = "Walk each source once; produce the fat SourceScan payload for downstream passes",
		out    = {},
	},
	["word-counts"] = {
		module = "passes.word_count_eval",
		kind   = "shared",
		deps   = {},
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
		deps   = {"scan-source", "word-counts", "components"},
		desc   = "Compute branch offsets for atom_label / atom_offset",
		out    = { { kind = "header", path_template = "<source_dir>/gen/<basename>.offsets.h" } },
	},
	["static-analysis"] = {
		module = "passes.static_analysis",
		kind   = "validation",
		deps   = {"scan-source", "word-counts", "components"},
		desc   = "[FUTURE] GTE pipeline-fill, mac_yield uniformity, etc.",
		out    = { { kind = "report", path_template = "<out_root>/<basename>.static_analysis.txt" } },
	},
	["atoms-source-map"] = {
		module = "passes.atoms_source_map",
		kind   = "header-output",
		deps   = {"word-counts", "components"},
		desc   = "Emit gen/<basename>.atoms.sourcemap.txt (per-.word C source line map for gdb debugging)",
		out    = { { kind = "header", path_template = "<source_dir>/gen/<basename>.atoms.sourcemap.txt" } },
	},
	["dwarf-injection"] = {
		module = "passes.dwarf_injection",
		kind   = "shared",
		deps   = {"atoms-source-map"},
		desc   = "Inject per-atom .debug_line + .debug_aranges into the ELF (post-link; writes section .bin blobs for objcopy splice)",
		out    = {
			{ kind = "report", path_template = "<out_root>/<basename>.dwarf_line.bin" },
			{ kind = "report", path_template = "<out_root>/<basename>.dwarf_aranges.bin" },
			{ kind = "report", path_template = "<out_root>/<basename>.dwarf_rnglists.bin" },
		},
	},
	report = {
		module = "passes.report",
		kind   = "report",
		deps   = {"annotation", "static-analysis"},
		desc   = "Render the per-project summary",
		out    = { { kind = "report", path_template = "<out_root>/annotation_validation.txt" } },
	},
}

-- Pass-kind taxonomy: which kinds stop the build on errors?
local PASS_KIND_STOP_ON_ERROR = {
	["shared"]        = false,
	["header-output"] = true,
	["validation"]    = true,
	["report"]        = false,
}

-- Closed set of CLI flags -> pass names.
local PASS_FLAG_TO_NAME = {
	["--word-counts"]       = "word-counts",
	["--components"]        = "components",
	["--validate"]          = "annotation",
	["--offsets"]           = "offsets",
	["--static-analysis"]   = "static-analysis",
	["--atoms-source-map"]  = "atoms-source-map",
	["--dwarf-injection"]   = "dwarf-injection",
	["--report"]            = "report",
	["--scan-source"]       = "scan-source",
	["--all"]               = ALL_PASSES_SENTINEL,
}

local ALL_PASS_NAMES = {
	"scan-source", "word-counts", "components", "annotation",
	"offsets", "static-analysis", "atoms-source-map", "dwarf-injection", "report",
}

--- Append every pass name to args.requested_set. Used by --all and by the "default to --all if no pass flags were given" fallback.
--- @param args ParsedArgs
local function request_all_passes(args)
	for _, n in ipairs(ALL_PASS_NAMES) do
		args.requested_set[#args.requested_set + 1] = n
	end
end

-- Per-flag handlers. Each handler takes (args, argv, arg_idx) and returns the new arg_idx (so multi-arg flags like --source FILE advance it). 
-- Returning nil + os.exit() handles termination flags (--help). This replaces the 8-way `if/elseif/elseif...` chain that nested 4 levels deep 
-- and made the dispatch logic hard to scan.
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

PASS_FLAGS (pick one or more, or use --all):
  --word-counts         Load metadata.h + scan for existing .macs.h
  --components          Generate <module>/gen/<basename>.macs.h
  --validate            Run atom annotation DSL validation
  --offsets             Generate <module>/gen/<basename>.offsets.h
  --atoms-source-map    Generate <basename>.atoms.sourcemap.txt per source
  --dwarf-injection     Inject per-atom .debug_line + .debug_aranges (post-link, requires --elf)
  --static-analysis     [FUTURE] GTE pipeline-fill, mac_yield uniformity
  --report              Render per-project summary
  --all                 Equivalent to all 6 flags above (default)

COMMON_FLAGS:
  --source FILE         Source file to process (repeatable)
  --metadata PATH       Path to metadata.h (required)
  --out-root DIR        Output root for reports (default: build/gen)
  --project-root DIR    Project root for .macs.h scan (default: dirname(metadata))
  --gdb-runtime         Also emit <out_root>/gdb_tape_atoms_runtime.gdb (post-link, requires --elf)
  --dwarf-injection     Opt in to DWARF injection (writes <basename>.dwarf_*.bin blobs for objcopy splice; requires --elf)
  --elf PATH            Path to linked .elf (for --gdb-runtime / --dwarf-injection)
  --dry-run             Print dep order + ASCII graph; exit 0 without running
  --verbose             Print per-pass debug output
  --help                Show this help and exit

EXIT CODES:
  0  All requested passes succeeded
  1  Validation errors found
  2  Metaprogram internal error

EXAMPLE:
  ps1_meta.lua --all --metadata metadata.h --source code/foo.c --source code/bar.c
]])
end

-- Per-flag handlers. Each takes (args, argv, arg_idx) and returns the new arg_idx (so multi-arg flags like --source FILE advance it).
-- Termination flags like --help call os.exit() instead.
-- This replaces the 8-way `if/elseif/elseif...` chain that nested 4 levels deep and made the dispatch logic hard to scan.
--
-- Populated AFTER print_help so the --help handler can reference it as an upvalue (Lua resolves locals at closure-call time, 
-- but if the closure is defined before the local, it falls back to _G). 
FLAG_HANDLERS["--help"] = function(args)
	print_help()
	os.exit(0)
end

FLAG_HANDLERS["--dry-run"]      = function(args) args.dry_run = true end
FLAG_HANDLERS["--verbose"]      = function(args) args.verbose = true end
FLAG_HANDLERS["--source"]       = function(args, argv, arg_idx) args.sources[#args.sources + 1] = argv[arg_idx + 1]; return arg_idx + 1 end
FLAG_HANDLERS["--metadata"]     = function(args, argv, arg_idx) args.metadata                   = argv[arg_idx + 1]; return arg_idx + 1 end
FLAG_HANDLERS["--out-root"]     = function(args, argv, arg_idx) args.out_root                   = argv[arg_idx + 1]; return arg_idx + 1 end
FLAG_HANDLERS["--project-root"] = function(args, argv, arg_idx) args.project_root               = argv[arg_idx + 1]; return arg_idx + 1 end

-- Per-pass stash flags. Read by `passes/atoms_source_map.lua` to opt into the
-- post-link gdb-runtime emission. Same shape as the existing per-flag handlers:
-- mutates `args.flags` (which propagates into `ctx.flags`).
FLAG_HANDLERS["--gdb-runtime"]  = function(args) args.flags                       = args.flags or {}; args.flags.gdb_runtime = true end
FLAG_HANDLERS["--elf"]          = function(args, argv, arg_idx) args.flags       = args.flags or {}; args.flags.elf_path  = argv[arg_idx + 1]; return arg_idx + 1 end
-- F' track: enable DWARF injection (default OFF; opt-in via .vscode/launch.json or ps1_meta CLI).
FLAG_HANDLERS["--dwarf-injection"] = function(args)
	args.flags = args.flags or {}
	args.flags.dwarf_injection = true
	args.requested_set[#args.requested_set + 1] = "dwarf-injection"
end

-- Pass-flag handler. Reads the closed-set table, expands --all, appends to requested_set. Single-statement, no nesting.
FLAG_HANDLERS[PASS_FLAG_DISPATCH_KEY] = function(args, a)
	local name = PASS_FLAG_TO_NAME[a]
	if name == ALL_PASSES_SENTINEL then
		request_all_passes(args)
		return
	end
	args.requested_set[#args.requested_set + 1] = name
end

--- Parse argv into a structured table. Validates against a closed enum.
---
--- @param argv string[]
--- @return ParsedArgs
local function parse_args(argv)
	local args = {
		requested_set = {},
		sources       = {},
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

	-- Default: --all if no explicit pass flags.
	if #args.requested_set == 0 then request_all_passes(args) end

	-- Defaults: project_root = dirname(metadata).
	if args.metadata and not args.project_root then
		local d = duffle.dirname(args.metadata)
		if   #d > 0 and (d:sub(-1) == "/" or d:sub(-1) == "\\") then
			d = d:sub(1, -2)
		end
		args.project_root = duffle.dirname(d)
	end

	if not args.metadata then
		io.stderr:write("ps1_meta: --metadata PATH is required\n")
		os.exit(EXIT_INTERNAL_ERROR)
	end
	if #args.sources == 0 then
		io.stderr:write("ps1_meta: at least one --source FILE is required\n")
		os.exit(EXIT_INTERNAL_ERROR)
	end

	return args
end

-- ════════════════════════════════════════════════════════════════════════════
-- Build ctx from parsed args
-- ════════════════════════════════════════════════════════════════════════════

--- Build the PassCtx from parsed args. Reads each source file once at startup;
--- passes consume `src.text`, not the path (path is preserved for error reporting).
---
--- @param args ParsedArgs
--- @return PassCtx
local function build_ctx(args)
	local sources = {}
	for _, path in ipairs(args.sources) do
		local  f = io.open(path, "r")
		if not f then
			io.stderr:write("ps1_meta: cannot open --source " .. path .. "\n")
			os.exit(EXIT_INTERNAL_ERROR)
		end
		local text = f:read("*a")
		f:close()

		local dir      = duffle.dirname(path)
		local basename = duffle.basename_no_ext(path)
		if #dir > 0 and (dir:sub(-1) == "/" or dir:sub(-1) == "\\") then
			dir = dir:sub(1, -2)
		end

		-- src.scan is populated by the "scan-source" pass (the first pass in the
		-- dep graph). build_ctx just opens + reads the files; the scan itself
		-- happens in the pass module, not inline in the orchestrator.
		sources[#sources + 1] = {
			path     = path,
			text     = text,
			dir      = dir,
			basename = basename,
		}
	end

	-- Pre-compute the per-directory grouping once (Fleury: expose structure).
	-- Three passes (annotation, report, static-analysis) call group_sources_by_dir with the same ctx.sources;
	-- computing it here and stashing on ctx.by_dir eliminates 2 redundant calls.
	local by_dir = duffle.group_sources_by_dir(sources)

	return {
		sources       = sources,
		by_dir        = by_dir,
		metadata_path = args.metadata,
		shared        = {},
		upstream      = {},
		out_root      = args.out_root,
		project_root  = args.project_root,
		flags         = args.flags or {},
		dry_run       = args.dry_run,
		verbose       = args.verbose,
	}
end

-- ════════════════════════════════════════════════════════════════════════════
-- Topological sort (Kahn's algorithm + cycle detection)
-- ════════════════════════════════════════════════════════════════════════════

--- Compute the dep-closure of `requested_set`: include every pass name transitively required by the requested set.
---
--- @param passes table<string, PassDescriptor>
--- @param requested_set string[]
--- @return table<string, boolean>  -- set of pass names needed (including transitive deps)
local function dep_closure(passes, requested_set)
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
	return needed
end

--- Count entries in a hash table (Lua's `#t` doesn't work for hash tables).
--- @param t table
--- @return integer
local function count_entries(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

--- Compute in-degrees for the Kahn sort: for each pass in `needed`, the number of its deps that are also in `needed`.
---
--- @param passes table<string, PassDescriptor>
--- @param needed table<string, boolean>
--- @return table<string, integer>
local function compute_in_degrees(passes, needed)
	local in_degree = {}
	for name, _ in pairs(needed) do in_degree[name] = 0 end
	for name, _ in pairs(needed) do
		for _, dep in ipairs(passes[name].deps) do
			if needed[dep] then
				in_degree[name] = in_degree[name] + 1
			end
		end
	end
	return in_degree
end

--- Seed the Kahn ready queue with passes whose in-degree is 0, sorted alphabetically for deterministic execution order.
---
--- @param in_degree table<string, integer>
--- @return string[]
local function seed_ready_queue(in_degree)
	local ready = {}
	for name, deg in pairs(in_degree) do
		if deg == 0 then ready[#ready + 1] = name end
	end
	table.sort(ready)
	return ready
end

-- (internal) Pop the next ready pass, decrement the in-degree of every remaining pass that depended on it
-- (inserting newly-zero-degree passes back into the ready queue), and append to `order`. Keeps `ready` sorted.
-- @param passes table<string, PassDescriptor>
-- @param needed table<string, boolean>
-- @param in_degree table<string, integer>
-- @param ready string[]
-- @param order string[]
local function process_next_ready(passes, needed, in_degree, ready, order)
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

--- Topologically sort the requested pass set, augmented with all transitive deps.
--- Detects cycles and errors out with details.
---
--- @param passes table<string, PassDescriptor>
--- @param requested_set string[]
--- @return string[]  -- execution order
local function topo_sort(passes, requested_set)
	local needed    = dep_closure(passes, requested_set)
	local in_degree = compute_in_degrees(passes, needed)
	local ready     = seed_ready_queue(in_degree)

	local order = {}
	while #ready > 0 do
		process_next_ready(passes, needed, in_degree, ready, order)
	end

	-- Cycle detection: if order doesn't include all needed passes, some are stuck with in_degree > 0 (the cycle closed on itself
	-- before Kahn could process them). Without this check, a fully-closed cycle (e.g. A -> B -> A) would silently return an emspty order list, 
	-- leaving the orchestrator to dispatch nothing.
	if #order ~= count_entries(needed) then
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

--- Render the dep graph as ASCII art. Output width capped at 78 columns.
--- Falls back to the simpler "Resolved dependency order" list only if graph width exceeds terminal width.
---
--- @param passes table<string, PassDescriptor>
--- @param requested string[]  -- originally-requested passes (subset of closed)
--- @param closed string[]     -- dep-closed execution order
--- @return string
local function render_dep_graph(passes, requested, closed)
	local lines = {}
	local function add(s) lines[#lines + 1] = s end

	add("[ps1_meta] Resolved dependency order (closed under deps):")
	for pass_idx, name in ipairs(closed) do
		local p = passes[name]
		local deps_str = (#p.deps == 0) and "(no deps)" or
			"(deps: " .. table.concat(p.deps, ", ") .. ")"
		add(string.format("  %d. %-22s %-45s [%s]",
			pass_idx, name, deps_str, p.kind))
	end
	add("")

	-- Data-driven ASCII graph built from the actual PASSES table.
	-- Shows the source -> scan_source -> pass chain. Each pass is
	-- shown once; edges are "feeds into" arrows based on deps.
	add("[ps1_meta] Pass graph (read top-to-bottom; edges = 'feeds into'):")
	add("")

	-- Compute which passes feed which other passes (reverse of deps).
	local feeds = {}  -- feeds[X] = list of passes that X feeds into
	for _, name in ipairs(closed) do feeds[name] = {} end
	for name, p in pairs(passes) do
		for _, dep in ipairs(p.deps) do
			if feeds[dep] then feeds[dep][#feeds[dep] + 1] = name end
		end
	end

	-- Layout: source -> scan_source -> word-counts -> {components, annotation, offsets, static-analysis} -> report
	-- Outputs are listed under each pass.
	local outputs_for = function(name)
		local p = passes[name]
		if not p or not p.out or #p.out == 0 then return "" end
		local outs = {}
		for _, o in ipairs(p.out) do outs[#outs + 1] = o.path_template end
		return table.concat(outs, ", ")
	end

	add("   +-----------+   +-------------------+    +-----------------+")
	add("   |  source   |-->|  scan_source      |--->|   word-counts   |")
	add("   |  files    |   | (scan_source.lua) |    |   (load)        |")
	add("   +-----------+   +-------------------+    +-----------------+")
	add("                          (single walk)         |")
	add("                                                |")
	add("        +-------------------+-------------------+-----------+")
	add("        v                   v                   v           v")
	add("   +--------------+   +--------------+   +--------------+   +---------------+")
	add("   | components   |   | annotation   |   |   offsets    |   |static-analysis|")
	add("   +--------------+   +--------------+   +--------------+   +---------------+")
	add("   |<src>/gen/    |   |build/gen/    |   |<src>/gen/    |   |build/gen/     |")
	add("   |<base>.macs.h |   |<base>.errors |   |<base>.offsets|   |<base>.static  |")
	add("   |   (header)   |   |  .h          |   |  .h          |   |  _analysis    |")
	add("   +------+-------+   |  +annot.txt  |   |  (header)    |   |  .txt         |")
	add("          |           +--+-----------+   +--------------+   +------+--------+")
	add("          v              v                                         v")
	add("   +------+----------------+  +------+-------+                     |")
	add("   |offsets|static-analysis|  |report|       |<--------------------+")
	add("   |       |               |  +------+-------+")
	add("   +-------+---------------+")

	return table.concat(lines, "\n") .. "\n"
end

-- ════════════════════════════════════════════════════════════════════════════
-- Main orchestrator
-- ════════════════════════════════════════════════════════════════════════════

-- (internal) Push a pass's outputs + warnings into `ctx.upstream[name]` for downstream passes to consume.
-- @param ctx PassCtx
-- @param pass_name string
-- @param result PassResult
local function accumulate_pass_result(ctx, pass_name, result)
	ctx.upstream[pass_name] = ctx.upstream[pass_name] or {}
	for _, out in ipairs(result.outputs or {}) do
		table.insert(ctx.upstream[pass_name], out)
	end
	for _, warn in ipairs(result.warnings or {}) do
		table.insert(ctx.upstream[pass_name], warn)
	end
end

-- (internal) If the pass's kind is in PASS_KIND_STOP_ON_ERROR and it reported errors, write each error to stderr.
-- Returns true if any validation errors were reported.
-- @param pass_name string
-- @param pass PassDescriptor
-- @param result PassResult
-- @return boolean
local function report_validation_errors(pass_name, pass, result)
	local   has_errors = result.errors and #result.errors > 0
	if not (has_errors and PASS_KIND_STOP_ON_ERROR[pass.kind]) then
		return false
	end
	for _, e in ipairs(result.errors) do
		io.stderr:write(string.format("[%s] line %d: %s\n",
			pass_name, e.line or 0, e.msg or ""))
	end
	return true
end

-- (internal) Run each pass in `order` in topological sequence.
--
-- @param ctx PassCtx
-- @param order string[]
-- @return boolean  -- true if any validation errors were reported
local function dispatch_passes(ctx, order)
	ctx.shared = {}
	local had_errors = false
	for _, pass_name in ipairs(order) do
		local pass   = PASSES[pass_name]
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

		-- --dry-run: print dep order + ASCII graph, exit OK.
		if args.dry_run then
			io.write(render_dep_graph(PASSES, requested, closed))
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

main({...})
