--- passes/auto_reg.lua — Per-phase automatic GPR allocator + gen/auto_reg.h emitter.
---
--- Reads the per-source + corpus-level `atom_auto_regs` + `phase_auto_regs` registries populated by `passes/scan_source.lua`.
--- Runs a deterministic first-fit allocator in the `R_T0..R_T7 + R_V0..R_V1` pool (10 physical GPRs).
--- Emits one `#define R_<Sym>_Code R_Tn_Code` per marker into per-directory `gen/auto_reg.h`.
---
--- User-pinned GPRs : The corpus's `register_alias_registry` is consulted to exclude GPRs the user has pinned via 
--- `atom_reg` + `_Code` defs (e.g. carriers like `R_ResolveScratch = R_T4 atom_reg`). 
--- These GPRs are unavailable to EVERY atom's source pool.
--- Carriers are preserved across atoms by context discipline and must never be reallocated.
--- Per-atom body parsing also catches alias references (R_<Alias>) and hardcoded R_Tn references,
--- so the user can write either `R_T4` or `R_ResolveScratch` in an atom body and the pass will exclude R_T4 from that atom's pool.
---
--- Conflict detection: If the user hardcodes `R_Tn` in an atom body that shares a phase with an auto-reg that picked `R_Tn`,
--- emit `phase_register_clash` as an info finding (no build stop).
--- Should be unreachable after the user-pinning + body-parsing fix above; kept as a defensive safety net.
---
--- Pool exhaustion: If a phase declares more `R_<Sym>` mappings than the 10-register pool can hold,
--- emit `phase_register_pool_exhausted` as a build-stopping error.

--- @alias GprIdent string

--- @class GprAllocMap
--- @field [string] GprIdent  -- bag: auto-reg symbol -> physical GPR

--- @class AutoRegOutput
--- @field auto_reg_h string

--- @class AutoRegResult
--- @field outputs  AutoRegOutput[]
--- @field errors   PassFinding[]
--- @field warnings PassFinding[]

--- @class AutoRegPass
--- @field run  fun(ctx: PassCtx): AutoRegResult
--- @field POOL GprIdent[]

local _bootstrap_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./" ---@type string
local duffle         = dofile(_bootstrap_dir .. "../duffle_paths.lua")            ---@type DuffleExport

--- ════════════════════════════════════════════════════════════════════════════
--- THE GPR ALLOCATION POOL — what's allocatable, and (more importantly) WHY
--- ════════════════════════════════════════════════════════════════════════════
---
--- The auto-reg pass picks physical GPRs for `atom_auto_reg(...)` / `phase_auto_reg(...)` markers.
--- The 24-register pool covers R2-R25 (the user/atom allocatable surface):
---   R_T0..R_T7, R_V0..R_V1, R_A0..A3, R_S0..S7, R_T8..T9.
--- Excluded (and never added to the pool):
---   R_0          (code 0)   — Hardwired zero. Cannot be written.
---   R_AT         (code 1)   — Assembler temporary. Reserved by the MIPS O32 ABI.
---   R_A0..A3                — Explicitly omitted above even though their integer codes map to POOL entries;
---                             the pool-construction loop below only references the POOL string literals, never the integer codes, so they are NOT auto-allocated by default.
---                             (A0-A3 become available when the user adds them to POOL or hardcodes an R_A0 reference in the atom body.)
---   R_K0/K1       (codes 26-27) — Kernel / interrupt handler reserves. Never touched by user code.
---   R_GP/SP/FP/RA (codes 28-31) — R_SP/R_FP/R_RA are tape-runtime carriers between tape_enter and tape_exit; R_GP stays the host global pointer.
---
local POOL = { ---@type GprIdent[]
	"R_V0", "R_V1",
	"R_T0", "R_T1", "R_T2", "R_T3",
	"R_T4", "R_T5", "R_T6", "R_T7",
	"R_A0", "R_A1", "R_A2", "R_A3",
	"R_S0", "R_S1", "R_S2", "R_S3",
	"R_S4", "R_S5", "R_S6", "R_S7",
	"R_T8", "R_T9",
}

-- Map from integer MIPS GPR code (the `code` field on AliasEntry) to the physical GPR ident in POOL.
-- The standard MIPS O32 ABI register numbering matches mips.h's R_*_Code #defines (mips.h).
-- Only the POOL entries matter for auto_reg — non-pool aliases
-- (R_AT=1, R_A0..A3=4..7, R_T8=24, R_T9=25, R_K0/K1=26..27, R_GP/SP/FP/RA=28..31) 
-- are deliberately omitted — see the comment block above for the WHY of each exclusion.
local INT_CODE_TO_POOL_GPR = { ---@type table<integer, GprIdent>  -- bag: MIPS GPR code -> POOL ident
	[2]  = "R_V0", [3]  = "R_V1",
	[4]  = "R_A0", [5]  = "R_A1", [6]  = "R_A2", [7]  = "R_A3",
	[8]  = "R_T0", [9]  = "R_T1", [10] = "R_T2", [11] = "R_T3",
	[12] = "R_T4", [13] = "R_T5", [14] = "R_T6", [15] = "R_T7",
	[16] = "R_S0", [17] = "R_S1", [18] = "R_S2", [19] = "R_S3",
	[20] = "R_S4", [21] = "R_S5", [22] = "R_S6", [23] = "R_S7",
	[24] = "R_T8", [25] = "R_T9",
}

-- Stable sort for deterministic allocation order.
--- @param tbl table<string, string>  -- bag: key set only; values unused
--- @return string[]
local function stable_sort_keys(tbl)
	local keys = {}                                ---@type string[]
	for k in pairs(tbl) do keys[#keys + 1] = k end ---@type string
	table.sort(keys)
	return keys
end

-- Allocate one phase's auto-reg mappings.
-- Returns (allocated_map, errors). On pool exhaustion, errors is populated and the function halts.
--- @param phase_label string
--- @param decls table<string, string>  -- bag: auto-reg symbol -> decl payload
--- @return GprAllocMap
--- @return PassFinding[]
local function allocate_phase(phase_label, decls)
	-- Deep-copy POOL into a fresh sequence table. The original `table.unpack and table.unpack(POOL) or { unpack(POOL) }`
	-- idiom wraps the unpacked values in a single inner table under LuaJIT 5.1 (`table.unpack` is nil; the `or` returns one value),
	-- which corrupts the pool into `{ {R_T0, R_T1, ...} }` — making `table.remove(pool, 1)` return the inner table on iteration.
	local pool   = {}                                ---@type GprIdent[]
	for i = 1, #POOL do pool[i] = POOL[i] end        ---@type integer
	local result = {}                                ---@type GprAllocMap
	local errors = {}                                ---@type PassFinding[]
	for _, sym in ipairs(stable_sort_keys(decls)) do ---@type integer, string
		local next_gpr = table.remove(pool, 1) ---@type GprIdent|nil
		if not next_gpr then
			errors[#errors + 1] = {
				line = 0,
				msg  = string.format("phase_register_pool_exhausted: "
					.. "phase '%s' requested symbol '%s' but the pool has no remaining registers "
					.. "(max 24 per phase: R_T0..R_T7 + R_V0..R_V1 + R_A0..R_A3 + R_S0..R_S7 + R_T8..R_T9). Split the phase or use hardcoded GPRs."
					, phase_label, sym),
			}
			return result, errors
		end
		result[sym] = next_gpr
	end
	return result, errors
end

-- Build two projections from corpus.register_alias_registry:
--   user_pinned   -- { [physical_gpr_ident] = true } -- GPRs unavailable to auto_reg globally (wave-context carriers, file-scope pinned aliases)
--   alias_to_gpr  -- { [alias_ident]        = physical_gpr_ident } -- for body parsing
-- Both projections are derived from the same set of entries: every AliasEntry in register_alias_registry has `has_atom_reg = true` 
-- (only those entries are added to the registry; see passes/scan_source.lua parse_enum_entry).
-- Each entry's `code` is the integer MIPS GPR number (0..31); INT_CODE_TO_POOL_GPR translates it back to the physical GPR ident.
-- Aliases whose `code` points to a non-POOL GPR (e.g. R_S0, R_T8, R_K1) are ignored — 
-- they don't affect the auto_reg pool, and they're already excluded from POOL above.
--- @param corpus Corpus
--- @return table<GprIdent, boolean>
--- @return table<string, GprIdent>
local function build_user_pins(corpus)
	local user_pinned  = {} ---@type table<GprIdent, boolean>  -- bag: pinned physical GPR -> true
	local alias_to_gpr = {} ---@type table<string, GprIdent>  -- bag: alias ident -> physical GPR
	if not corpus.register_alias_registry then return user_pinned, alias_to_gpr end
	for alias_name, alias_entry in pairs(corpus.register_alias_registry) do ---@type string, AliasEntry
		if alias_entry.has_atom_reg and alias_entry.code then
			local gpr = INT_CODE_TO_POOL_GPR[alias_entry.code] ---@type GprIdent|nil
			if gpr then
				user_pinned[gpr]         = true
				alias_to_gpr[alias_name] = gpr
			end
		end
	end
	return user_pinned, alias_to_gpr
end

--- Find every physical GPR referenced in the atom body, via EITHER:
---   (a) A hardcoded physical GPR ident (R_T\d+|R_V\d+|R_A\d+|R_S\d+) — the existing regex;
---   (b) An alias ident (R_<Alias>) resolved via alias_to_gpr back to its physical GPR ident.
--- Returns { [physical_gpr_ident] = count }.
--- Clash-detection and source-pool-exclusion logic only needs the presence of each GPR (boolean test), 
--- but keeping count preserves the original find_hardcoded_rn shape so callers can switch without churn.
--- The alias pattern is sorted lexicographically to keep the regex deterministic.
--- @param body_text string
--- @param alias_to_gpr table<string, GprIdent>  -- bag: alias ident -> physical GPR
--- @return table<GprIdent, integer>
local function find_used_gprs(body_text, alias_to_gpr)
	local found = {} ---@type table<GprIdent, integer>  -- bag: physical GPR -> hit count
	-- (a) Hardcoded physical GPRs (R_T0..R_T7, R_V0..R_V1, R_A0..R_A3, R_S0..R_S7).
	for gpr in body_text:gmatch("(R_T%d+|R_V%d+|R_A%d+|R_S%d+)") do ---@type GprIdent
		found[gpr] = (found[gpr] or 0) + 1
	end
	-- (b) Alias references (R_<Alias>) resolved to physical GPRs via the registry.
	--      Sorted by name so the regex is byte-stable across runs.
	if alias_to_gpr and next(alias_to_gpr) then
		local aliases = {}                       ---@type string[]
		for alias_name in pairs(alias_to_gpr) do ---@type string
			aliases[#aliases + 1] = alias_name
		end
		table.sort(aliases)
		local pattern = "(" .. table.concat(aliases, "|") .. ")" ---@type string
		for alias_name in body_text:gmatch(pattern) do           ---@type string
			local gpr = alias_to_gpr[alias_name] ---@type GprIdent|nil
			if gpr and not found[gpr] then
				found[gpr] = 1
			end
		end
	end
	return found
end

-- Emit one gen/auto_reg.h header per directory.
--- @param out_dir string
--- @param dir string
--- @param sources SourceFile[]
--- @param mappings GprAllocMap
--- @return string|nil
local function emit_auto_reg_h(out_dir, dir, sources, mappings)
	if not mappings or next(mappings) == nil then return end
	local out_path = out_dir .. "/" .. "auto_reg.h" ---@type string
	duffle.ensure_dir(out_dir)
	local lines = { ---@type string[]
		"#ifdef INTELLISENSE_DIRECTIVES",
		"#pragma once",
		"#endif",
		"// Auto-generated by ps1_meta.lua (passes/auto_reg.lua) — DO NOT EDIT",
		"// Directory: " .. dir:gsub("/", "\\"),
	}
	for _, src in ipairs(sources) do ---@type integer, SourceFile
		lines[#lines + 1] = "//   source: " .. src.path
	end
	lines[#lines + 1] = "// Per-phase register allocations resolved by the lua pass."
	lines[#lines + 1] = "// R_<Sym>_Code = <chosen GPR's _Code constant> for every marker in this directory."
	lines[#lines + 1] = ""
	for _, sym in ipairs(stable_sort_keys(mappings)) do ---@type integer, string
		local gpr         = mappings[sym]  ---@type GprIdent
		local gpr_code    = gpr .. "_Code" ---@type string
		lines[#lines + 1] = "#define " .. sym .. "_Code " .. gpr_code
	end
	lines[#lines + 1] = ""
	duffle.write_file_lf(out_path, table.concat(lines, "\n") .. "\n")
	print("  -> " .. out_path)
	return out_path
end

-- ════════════════════════════════════════════════════════════════════════════
-- Pass entry
-- ════════════════════════════════════════════════════════════════════════════

local M = {} ---@type AutoRegPass

--- @param ctx PassCtx
--- @return AutoRegResult
function M.run(ctx)
	local outputs  = {} ---@type AutoRegOutput[]
	local errors   = {} ---@type PassFinding[]
	local warnings = {} ---@type PassFinding[]

	local corpus = ctx.shared and ctx.shared.corpus ---@type Corpus|nil
	if type(corpus) ~= "table" then
		error("auto_reg.run requires ctx.shared.corpus", 0)
	end

	-- 0. Build the user-pinned GPR exclusion set + alias-to-GPR resolution map.
	--  Wave-context carriers (e.g. `R_ResolveScratch = R_T4 atom_reg` in hello_camera.atom.c)
	--  MUST NOT be allocated to any auto-reg marker — they're preserved across atoms by the wave-context discipline.
	--  The corpus's register_alias_registry is the source of truth for these opt-in pins.
	--  Body references to those aliases (via alias_to_gpr) are also excluded on a per-atom basis in step 2 below.
	local user_pinned, alias_to_gpr = build_user_pins(corpus) ---@type table<GprIdent, boolean>, table<string, GprIdent>

	-- 1. Allocate phase pools first (phase declarations take precedence over per-atom declarations).
	local phase_allocations = {}                                     ---@type table<string, GprAllocMap>  -- bag: phase_label -> alloc map
	for phase_label, decls in pairs(corpus.phase_auto_regs or {}) do ---@type string, table<string, string>
		local mapping, errs = allocate_phase(phase_label, decls) ---@type GprAllocMap, PassFinding[]
		for sym, gpr in pairs(mapping) do                        ---@type string, GprIdent
			phase_allocations[phase_label]      = phase_allocations[phase_label] or {}
			phase_allocations[phase_label][sym] = gpr
		end
		for _, e in ipairs(errs) do ---@type integer, PassFinding
			errors[#errors + 1] = e
		end
	end

	-- 2. Allocate per-atom auto-regs. If the atom scope matches a phase, reuse the phase pool.
	-- Otherwise, allocate a private pool for the atom.
	-- The phase membership is in `corpus.atom_phases[phase_label].atoms` (an array of atom names declared via `atom_phase(<phase>)`
	-- in the atom's `atom_info` line). Build a reverse map `atom_name -> phase_label` so the lookup is O(1) per atom scope.
	local atom_name_to_phase = {}                                ---@type table<AtomName, string>  -- bag: atom name -> phase label
	for phase_label, entry in pairs(corpus.atom_phases or {}) do ---@type string, AtomPhaseGroup
		for _, atom_name in ipairs(entry.atoms or {}) do ---@type integer, AtomName
			atom_name_to_phase[atom_name] = phase_label
		end
	end

	local atom_allocations = {}                                    ---@type table<AtomName, GprAllocMap>  -- bag: atom scope -> alloc map
	for atom_scope, decls in pairs(corpus.atom_auto_regs or {}) do ---@type AtomName, table<string, string>
		local phase_label = atom_name_to_phase[atom_scope] ---@type string|nil
		-- Build the atom's source pool: start with the full POOL, subtract:
		--   (a) every GPR already committed (phase allocations + prior atom allocations)
		--   (b) every USER-PINNED GPR (wave-context carriers + file-scope pinned aliases)
		--   (c) every GPR referenced in the atom's body — either hardcoded R_X or alias R_Xxx
		--       (the latter resolved via alias_to_gpr; this catches cases where the user wrote R_ResolveScratch instead of R_T4 directly)
		-- Atoms whose scope matches a phase share the global pool with the phase allocations;
		-- the original `source_pool = phase_allocations[phase_label]` form used the phase
		-- allocation MAP as a pool, but that map has no array part, so `table.remove(source_pool, 1)`
		-- returned nil and every atom-with-phase marker errored with `phase_register_pool_exhausted`.
		local used = {}                                                                            ---@type table<GprIdent, boolean>  -- bag: committed or body-referenced GPR -> true
		for _, m in pairs(phase_allocations) do for _, gpr in pairs(m) do used[gpr] = true end end ---@type integer, GprAllocMap
		for _, m in pairs(atom_allocations)  do for _, gpr in pairs(m) do used[gpr] = true end end ---@type integer, GprAllocMap
		-- (c) Body references — scan the atom body for hardcoded + alias-resolved GPRs.
		--     Folded into `used` so the source_pool exclusion is a single check.
		local atom = corpus.atoms_by_name and corpus.atoms_by_name[atom_scope] ---@type AtomEntry|nil
		if atom and atom.body then
			local body_used = find_used_gprs(atom.body, alias_to_gpr) ---@type table<GprIdent, integer>
			for gpr in pairs(body_used) do used[gpr] = true end       ---@type GprIdent
		end
		local source_pool = {}        ---@type GprIdent[]
		for _, gpr in ipairs(POOL) do ---@type integer, GprIdent
			-- Exclude (a) prior commitments, (b) USER-PINNED GPRs (wave-context carriers declared via atom_reg + _Code defs, preserved across atoms globally).
			if not used[gpr] and not user_pinned[gpr] then
				source_pool[#source_pool + 1] = gpr
			end
		end
		local result = {}                                ---@type GprAllocMap
		for _, sym in ipairs(stable_sort_keys(decls)) do ---@type integer, string
			local next_gpr = table.remove(source_pool, 1) ---@type GprIdent|nil
			if not next_gpr then
				errors[#errors + 1] = {
					line = 0,
					msg  = string.format("phase_register_pool_exhausted: atom '%s' requested symbol '%s' "
						.. "but no free registers remain in its scope pool."
						, atom_scope, sym),
				}
			else
				result[sym] = next_gpr
			end
		end
		atom_allocations[atom_scope] = result
	end

	-- 3. Conflict-with-hardcoded detection (defensive — should be unreachable now).
	-- The source_pool exclusion in step 2 (b) + (c) already accounts for both user-pinned GPRs
	-- and body-referenced GPRs (hardcoded R_Tn OR alias R_<Alias>).
	-- An auto-reg allocation that matched an existing body reference would be impossible by construction.
	-- This warning is kept as a defensive safety net for cases the body scanner might miss
	-- (e.g. macros that expand to register references the scanner cannot resolve).
	-- For each resolved (scope, sym) -> R_Tn mapping, scan the atom body source for used GPRs.
	for atom_scope, decls in pairs(atom_allocations) do ---@type AtomName, GprAllocMap
		local atom = corpus.atoms_by_name and corpus.atoms_by_name[atom_scope] ---@type AtomEntry|nil
		if    atom and atom.body then
			local used_in_body = find_used_gprs(atom.body, alias_to_gpr) ---@type table<GprIdent, integer>
			for sym, allocated_gpr in pairs(decls) do                    ---@type string, GprIdent
				if used_in_body[allocated_gpr] and used_in_body[allocated_gpr] > 0 then
					warnings[#warnings + 1] = {
						line  = atom.line or 0,
						msg   = string.format("phase_register_clash: atom '%s' has hardcoded '%s' in its body AND an auto-reg marker '%s' "
							.. "that was allocated to '%s' (same phase). Resolve by removing the hardcoded reference or renaming the auto-reg."
							, atom_scope, allocated_gpr, sym, allocated_gpr),
					}
				end
			end
		end
	end

	-- 4. Emit per-directory gen/auto_reg.h.
	-- For each source directory that has atom_auto_regs or phase_auto_regs entries, emit one header.
	local sources_by_dir = corpus.sources_by_dir or {} ---@type table<string, SourceFile[]>
	for dir, sources in pairs(sources_by_dir) do       ---@type string, SourceFile[]
		local per_dir_mappings = {}      ---@type GprAllocMap
		for _, src in ipairs(sources) do ---@type integer, SourceFile
			-- Collect every (sym -> gpr) entry that originated from a source in this directory.
			-- `src.scan.atom_auto_regs` is keyed by ATOM SCOPE NAME; `pairs(t)` iterates KEYS so `scope_name` here is the scope ident (e.g. "cube_g4_face").
			-- The previous `for _, scan_atom_auto` form silently assigned the VALUE (a `{sym = sym}` table) to the variable,
			-- which made `atom_allocations[scan_atom_auto]` a table-indexed lookup that never resolved.
			for scope_name in pairs(src.scan and src.scan.atom_auto_regs or {}) do ---@type string
				for sym, gpr in pairs(atom_allocations[scope_name] or {}) do ---@type string, GprIdent
					per_dir_mappings[sym] = gpr
				end
			end
			for scope_name in pairs(src.scan and src.scan.phase_auto_regs or {}) do ---@type string
				for sym, gpr in pairs(phase_allocations[scope_name] or {}) do ---@type string, GprIdent
					per_dir_mappings[sym] = gpr
				end
			end
		end
		local out_dir  = dir .. "/gen"                                            ---@type string
		local out_path = emit_auto_reg_h(out_dir, dir, sources, per_dir_mappings) ---@type string|nil
		if out_path then outputs[#outputs + 1] = { auto_reg_h = out_path } end
	end
	return { outputs = outputs, errors = errors, warnings = warnings }
end

M.POOL = POOL

return M
