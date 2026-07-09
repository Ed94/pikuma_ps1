-- ps1_meta.lua
--
-- Orchestrator entry point for the tape-atom metaprogram pipeline.
-- Dispatches to pass modules under scripts/passes/, resolving dependencies
-- topologically. Single CLI surface (`--<pass>` flags + auto-dep + --dry-run).
--
-- Coding standard: tabs (1/level), EmmyLua annotations, no regex,
-- Lua 5.3 compatible.

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
package.path   = script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. package.path
package.cpath = "C:\\projects\\Pikuma\\ps1\\toolchain\\luajit-2.1\\lib\\lua\\5.1\\?.dll;" .. package.cpath

local duffle = require("duffle")
local dirname          = duffle.dirname
local basename_no_ext  = duffle.basename_no_ext

-- ════════════════════════════════════════════════════════════════════════════
-- Type declarations
-- ════════════════════════════════════════════════════════════════════════════

--- @class PassDescriptor
--- @field module   string         -- module name passed to require()
--- @field kind     string         -- "shared" | "header-output" | "validation" | "report"
--- @field deps     string[]       -- names of upstream passes
--- @field desc     string         -- human description (used by --help + ASCII graph)
--- @field out      PassOutput[]   -- output paths (used by --dry-run + report)

--- @class PassOutput
--- @field kind          string  -- "header" | "report"
--- @field path_template string  -- e.g. "<source_dir>/gen/<basename>.macs.h"

--- @class SourceFile
--- @field path     string
--- @field text     string
--- @field dir      string
--- @field basename string

--- @class PassCtx
--- @field sources            SourceFile[]
--- @field metadata_path      string
--- @field shared             table
--- @field shared.word_counts table<string, integer>
--- @field out_root           string
--- @field project_root       string
--- @field upstream           table<string, table>
--- @field flags              table
--- @field dry_run            boolean
--- @field verbose            boolean

--- @class PassResult
--- @field outputs  table[]
--- @field errors   table[]
--- @field warnings table[]

--- @class ParsedArgs
--- @field requested_set string[]    -- pass names to run (explicit --all expanded)
--- @field sources       string[]    -- --source values
--- @field metadata      string      -- --metadata value
--- @field out_root      string      -- --out-root value (default "build/gen")
--- @field project_root  string      -- --project-root value (default dirname(metadata))
--- @field dry_run       boolean
--- @field verbose       boolean

-- ════════════════════════════════════════════════════════════════════════════
-- PASSES table (data, not code) — the orchestrator's dep graph
-- ════════════════════════════════════════════════════════════════════════════

local PASSES = {
	["word-counts"] = {
		module = "word_count_eval",
		kind   = "shared",
		deps   = {},
		desc   = "Build the shared metadata table (metadata.h + .macs.h)",
		out    = {},
	},
	components = {
		module = "passes.components",
		kind   = "header-output",
		deps   = {"word-counts"},
		desc   = "Emit mac_X macros from MipsAtomComp_ declarations",
		out    = { { kind = "header", path_template = "<source_dir>/gen/<basename>.macs.h" } },
	},
	annotation = {
		module = "passes.annotation",
		kind   = "validation",
		deps   = {"word-counts"},
		desc   = "Validate atom DSL usage; emit errors.h + annotations.txt",
		out    = {
			{ kind = "report", path_template = "<out_root>/<basename>.errors.h" },
			{ kind = "report", path_template = "<out_root>/<basename>.annotations.txt" },
		},
	},
	offsets = {
		module = "passes.offsets",
		kind   = "header-output",
		deps   = {"word-counts", "components"},
		desc   = "Compute branch offsets for atom_label / atom_offset",
		out    = { { kind = "header", path_template = "<source_dir>/gen/<basename>.offsets.h" } },
	},
	["static-analysis"] = {
		module = "passes.static_analysis",
		kind   = "validation",
		deps   = {"word-counts", "components"},
		desc   = "[FUTURE] GTE pipeline-fill, mac_yield uniformity, etc.",
		out    = { { kind = "report", path_template = "<out_root>/<basename>.static_analysis.txt" } },
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
	["--word-counts"]     = "word-counts",
	["--components"]      = "components",
	["--validate"]        = "annotation",
	["--offsets"]         = "offsets",
	["--static-analysis"] = "static-analysis",
	["--report"]          = "report",
	["--all"]             = "__all__",
}

local ALL_PASS_NAMES = {
	"word-counts", "components", "annotation",
	"offsets", "static-analysis", "report",
}

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
  --static-analysis     [FUTURE] GTE pipeline-fill, mac_yield uniformity
  --report              Render per-project summary
  --all                 Equivalent to all 6 flags above (default)

COMMON_FLAGS:
  --source FILE         Source file to process (repeatable)
  --metadata PATH       Path to metadata.h (required)
  --out-root DIR        Output root for reports (default: build/gen)
  --project-root DIR    Project root for .macs.h scan (default: dirname(metadata))
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

--- Parse argv into a structured table. Validates against a closed enum.
---
--- @param argv string[]
--- @return ParsedArgs
local function parse_args(argv)
	local args = {
		requested_set = {},
		sources       = {},
		metadata      = nil,
		out_root      = "build/gen",
		project_root  = nil,
		dry_run       = false,
		verbose       = false,
	}

	local i = 1
	while i <= #argv do
		local a = argv[i]
		if a == "--help" then
			print_help()
			os.exit(0)
		elseif a == "--dry-run" then
			args.dry_run = true
		elseif a == "--verbose" then
			args.verbose = true
		elseif a == "--source" then
			i = i + 1
			args.sources[#args.sources + 1] = argv[i]
		elseif a == "--metadata" then
			i = i + 1
			args.metadata = argv[i]
		elseif a == "--out-root" then
			i = i + 1
			args.out_root = argv[i]
		elseif a == "--project-root" then
			i = i + 1
			args.project_root = argv[i]
		elseif PASS_FLAG_TO_NAME[a] then
			local name = PASS_FLAG_TO_NAME[a]
			if name == "__all__" then
				for _, n in ipairs(ALL_PASS_NAMES) do
					args.requested_set[#args.requested_set + 1] = n
				end
			else
				args.requested_set[#args.requested_set + 1] = name
			end
		else
			io.stderr:write("ps1_meta: unknown flag '" .. a .. "'\n")
			io.stderr:write("Run with --help for usage.\n")
			os.exit(2)
		end
		i = i + 1
	end

	-- Default: --all if no explicit pass flags.
	if #args.requested_set == 0 then
		for _, n in ipairs(ALL_PASS_NAMES) do
			args.requested_set[#args.requested_set + 1] = n
		end
	end

	-- Defaults: project_root = dirname(metadata).
	if args.metadata and not args.project_root then
		local d = dirname(args.metadata)
		if #d > 0 and (d:sub(-1) == "/" or d:sub(-1) == "\\") then
			d = d:sub(1, -2)
		end
		args.project_root = dirname(d)
	end

	if not args.metadata then
		io.stderr:write("ps1_meta: --metadata PATH is required\n")
		os.exit(2)
	end
	if #args.sources == 0 then
		io.stderr:write("ps1_meta: at least one --source FILE is required\n")
		os.exit(2)
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
		local f = io.open(path, "r")
		if not f then
			io.stderr:write("ps1_meta: cannot open --source " .. path .. "\n")
			os.exit(2)
		end
		local text = f:read("*a")
		f:close()

		local dir      = dirname(path)
		local basename = basename_no_ext(path)
		if #dir > 0 and (dir:sub(-1) == "/" or dir:sub(-1) == "\\") then
			dir = dir:sub(1, -2)
		end

		sources[#sources + 1] = {
			path     = path,
			text     = text,
			dir      = dir,
			basename = basename,
		}
	end

	return {
		sources       = sources,
		metadata_path = args.metadata,
		shared        = {},
		upstream      = {},
		out_root      = args.out_root,
		project_root  = args.project_root,
		flags         = {},
		dry_run       = args.dry_run,
		verbose       = args.verbose,
	}
end

-- ════════════════════════════════════════════════════════════════════════════
-- Topological sort (Kahn's algorithm + cycle detection)
-- ════════════════════════════════════════════════════════════════════════════

--- Topologically sort the requested pass set, augmented with all transitive deps.
--- Detects cycles and errors out with details.
---
--- @param passes table<string, PassDescriptor>
--- @param requested_set string[]
--- @return string[]  -- execution order
local function topo_sort(passes, requested_set)
	-- Step 1: dep-closure.
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

	-- Step 2: Kahn's algorithm.
	local in_degree = {}
	for name, _ in pairs(needed) do in_degree[name] = 0 end
	for name, _ in pairs(needed) do
		for _, dep in ipairs(passes[name].deps) do
			if needed[dep] then
				in_degree[name] = (in_degree[name] or 0) + 1
			end
		end
	end

	-- Seed with passes that have no unmet deps. Sort for determinism.
	local ready = {}
	for name, deg in pairs(in_degree) do
		if deg == 0 then ready[#ready + 1] = name end
	end
	table.sort(ready)

	local order = {}
	while #ready > 0 do
		local n = table.remove(ready, 1)
		order[#order + 1] = n
		for name, _ in pairs(needed) do
			if name ~= n then
				for _, dep in ipairs(passes[name].deps) do
					if dep == n then
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

	-- Cycle detection: if order doesn't include all needed passes,
	-- some are stuck with in_degree > 0 (the cycle closed on itself
	-- before Kahn could process them). Without this check, a fully-
	-- closed cycle (e.g. A -> B -> A) would silently return an empty
	-- order list, leaving the orchestrator to dispatch nothing.
	--
	-- Note: `#needed` returns 0 for hash tables (needed is a set,
	-- not a sequence), so we count entries explicitly.
	local needed_count = 0
	for _ in pairs(needed) do needed_count = needed_count + 1 end
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

--- Render the dep graph as ASCII art. Output width capped at 78 columns.
--- Falls back to the simpler "Resolved dependency order" list only if
--- graph width exceeds terminal width.
---
--- @param passes table<string, PassDescriptor>
--- @param requested string[]  -- originally-requested passes (subset of closed)
--- @param closed string[]     -- dep-closed execution order
--- @return string
local function render_dep_graph(passes, requested, closed)
	local lines = {}
	local function add(s) lines[#lines + 1] = s end

	add("[ps1_meta] Resolved dependency order (closed under deps):")
	for i, name in ipairs(closed) do
		local p = passes[name]
		local deps_str = (#p.deps == 0) and "(no deps)" or
			"(deps: " .. table.concat(p.deps, ", ") .. ")"
		add(string.format("  %d. %-22s %-45s [%s]",
			i, name, deps_str, p.kind))
	end
	add("")

	add("[ps1_meta] Pass graph (read top-to-bottom):")
	add("")
	add("                       metadata.h")
	add("                           |")
	add("                           v")
	add("   +-----------+   +-----------------+   +-----------------+")
	add("   |   word-   |-->|    components   |-->|     offsets     |")
	add("   |   counts  |   +-----------------+   +-----------------+")
	add("   |   (load)  |            |                      ^")
	add("   +-----------+            |                      |")
	add("        |                   v                      |")
	add("        |  code/<module>/gen/<basename>.macs.h     |")
	add("        |     (header - co-located for #include)   |")
	add("        |                                            |")
	add("        |           +-----------------+              |")
	add("        +---------->|    annotation   |--------------+")
	add("        |           +-----------------+              |")
	add("        |                   |                        |")
	add("        |                   v                        |")
	add("        |       build/gen/<basename>.errors.h        |")
	add("        |       build/gen/<basename>.annotations.txt |")
	add("        |         (report - NOT #included)            |")
	add("        |                                            |")
	add("        |           +-----------------+              |")
	add("        +---------->| static-analysis |--------------+")
	add("                    +-----------------+")
	add("                            |")
	add("                            v")
	add("                    +---------------+")
	add("                    |    report     |")
	add("                    +---------------+")
	add("                            |")
	add("                            v")
	add("                    build/gen/annotation_validation.txt")
	add("                      (project summary)")

	return table.concat(lines, "\n") .. "\n"
end

-- ════════════════════════════════════════════════════════════════════════════
-- Main orchestrator
-- ════════════════════════════════════════════════════════════════════════════

--- Main entry point. Runs the requested passes in dep-topological order.
--- @param argv string[]
local function main(argv)
	local ok, err = pcall(function()
		local args = parse_args(argv)
		local ctx  = build_ctx(args)

		-- 1. Compute requested set + dep-closed set.
		local requested = args.requested_set
		local closed    = topo_sort(PASSES, requested)

		-- 2. --dry-run: print dep order + ASCII graph, exit 0.
		if args.dry_run then
			io.write(render_dep_graph(PASSES, requested, closed))
			os.exit(0)
		end

		-- 3. Run passes in topological order.
		ctx.shared = {}
		for _, pass_name in ipairs(closed) do
			local pass  = PASSES[pass_name]
			local mod   = require(pass.module)
			local result = mod.run(ctx)

			-- Collect outputs + warnings into ctx.upstream.
			ctx.upstream[pass_name] = ctx.upstream[pass_name] or {}
			for _, out in ipairs(result.outputs or {}) do
				table.insert(ctx.upstream[pass_name], out)
			end
			for _, warn in ipairs(result.warnings or {}) do
				table.insert(ctx.upstream[pass_name], warn)
			end

			-- Stop on errors (unless this is a non-stopping pass like report).
			if (result.errors and #result.errors > 0) and PASS_KIND_STOP_ON_ERROR[pass.kind] then
				for _, e in ipairs(result.errors) do
					io.stderr:write(string.format("[%s] line %d: %s\n",
						pass_name, e.line or 0, e.msg or ""))
				end
				os.exit(1)
			end
		end
	end)

	if not ok then
		io.stderr:write("[ps1_meta] internal error: " .. tostring(err) .. "\n")
		os.exit(2)
	end

	os.exit(0)
end

main({...})