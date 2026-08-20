--- passes/emission_model.lua: Per-atom emission projection.
---
--- The `emission-model` pass owns `atom.paths`, the canonical per-atom mutable surface for atoms and raw atoms with bodies in `ctx.shared.corpus.source_order`.
--- For each atom, the pass invokes `duffle.project_emission(body_text, component_index, word_counts, components)`.
--- It stores the ordered `items` stream plus the dense `word_events` / `markers` / `invocations` views on `atom.paths`.
---
--- Public boundary:
---   * `M.run(ctx)` is the only entry point.
---   * The pass returns `{outputs = {}, errors = ..., warnings = ...}`.
---     Pass kind = `validation`. Findings record on the result; the orchestrator does not exit non-zero.
---
--- Source-order discipline:
---   * `corpus.source_order` sets the source-record order.
---   * Within each source, the pass visits `src.scan.atoms` and `src.scan.raw_atoms` in declaration order.
---
--- Per-atom projection fields on `atom.paths`:
---   `tokens`, `line_in_body`, `items`, `word_events`, `markers`, `invocations`, `errors`, `warnings`.
---   The construction walk appends `items` and derives each dense view from that ordered stream.
---
--- Component expansion and construction validation:
---   * known `mac_X(...)` calls recursively expand component bodies;
---   * invocation records retain monotonic IDs, parent IDs, immediate call text, and the immutable outermost root call text;
---   * invocation construction stamps `debug_skip` from `corpus.components[name].debug_skip` at the construction site (no second pass, no source parse, no parallel lookup);
---   * component cycles close balanced invocation boundaries and emit a `cycle` construction error at the recursive edge;
---   * declared-vs-measured component word counts emit `count_mismatch` construction errors; opaque uncounted macros emit warnings.
---
--- `passes.scan_source` strips its private `_code_macros` / `_code_macro_bodies` tables before this pass runs.

--- @class BodyToken
--- @field tok string
--- @field rel integer

--- @class EmissionItem
--- @field kind                    string
--- @field encoder                 string|nil
--- @field args                    string[]|nil
--- @field i                       integer|nil
--- @field word_count              integer|nil
--- @field line                    integer|nil
--- @field call_text               string|nil
--- @field root_call_text          string|nil
--- @field invocation_ids          integer[]|nil
--- @field outermost_invocation_id integer|nil
--- @field gpr_keys                string[]|nil
--- @field ident                   string|nil
--- @field isa_kind                string|nil
--- @field nop_words               integer|nil
--- @field is_yield                boolean|nil
--- @field is_load                 boolean|nil
--- @field is_branch               boolean|nil
--- @field is_unconditional_jump   boolean|nil
--- @field is_terminal_jump        boolean|nil
--- @field gp0_shape               string|nil
--- @field name                    string|nil
--- @field target                  string|nil
--- @field word_index              integer|nil
--- @field consuming_encoder       string|nil
--- @field consuming_arg_pos       integer|nil
--- @field invocation_id           integer|nil

--- @class WordEvent
--- @field i                       integer
--- @field encoder                 string
--- @field args                    string[]
--- @field def_path                string
--- @field def_line                integer
--- @field call_text               string|nil
--- @field root_call_text          string|nil
--- @field invocation_ids          integer[]
--- @field outermost_invocation_id integer
--- @field word_count              integer
--- @field gpr_keys                string[]|nil
--- @field ident                   string
--- @field kind                    string
--- @field nop_words               integer
--- @field is_yield                boolean
--- @field is_load                 boolean
--- @field is_branch               boolean
--- @field is_unconditional_jump   boolean
--- @field is_terminal_jump        boolean
--- @field gp0_shape               string|nil
--- @field body_line               integer|nil
--- @field call_line               integer|nil
--- @field call_path               string|nil

--- @class EmissionMarker
--- @field kind              string
--- @field name              string
--- @field line              integer
--- @field word_index        integer
--- @field target            string|nil
--- @field consuming_encoder string|nil
--- @field consuming_arg_pos integer|nil

--- @class EmitError
--- @field kind        string
--- @field line        integer|nil
--- @field msg         string
--- @field source      string|nil
--- @field schema_name string|nil

--- @class EmitWarning
--- @field kind string
--- @field line integer|nil
--- @field msg  string

--- @class AtomPaths
--- @field tokens       BodyToken[]
--- @field line_in_body table<integer, integer>  -- bag: body byte offset -> 1-based line
--- @field items        EmissionItem[]
--- @field word_events  WordEvent[]
--- @field markers      EmissionMarker[]
--- @field invocations  InvocationRecord[]
--- @field errors       EmitError[]
--- @field warnings     EmitWarning[]

--- @class EmissionModelPass
--- @field run fun(ctx: PassCtx): PassResult

--- @type EmissionModelPass
local M = {}

-- ─────────────────────────────────────────────────────────────────────────
-- Bootstrap: load `duffle_paths.lua` via debug.getinfo so the module works standalone (run as `luajit passes/emission_model.lua`) and when require'd from the orchestrator.
-- ─────────────────────────────────────────────────────────────────────────
--- @type string
local _bootstrap_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
--- @type DuffleExport
local duffle         = dofile(_bootstrap_dir .. "../duffle_paths.lua")

-- ─────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────

-- Convert the recursive walk's body-relative line numbers into physical source lines once.
-- The walker builds `line_of` from `body_text` and stamps body-relative line numbers (1..N) into `item.line` and `invocation.call_line`.
-- This function converts those values to physical source lines at the close site with the forwarded source `line_of` closure.
-- `call_line` discipline:
--   * ROOT invocations (`inv.parent_id == 0`) receive body-relative `call_line` values directly from `M.LineIndex(body_text)` in the walker.
--     The source `line_of` closure supplies physical lines at the close site, so this function converts each root value exactly once.
--   * INNER invocations (`inv.parent_id ~= 0`) receive physical `call_line` values directly from the COMPONENT's `line_of` in the walker.
--     Recursive descent forwards that closure through `corpus.component_body_index[name].line_of`; those values arrive physical and remain unchanged.
--
-- After this function, every `inv.call_line` is physical. DWARF and provenance output read it directly.
-- The word-event loop forwards the already-physical `outer_inv.call_line` into `we.call_line` for words inside an invocation.
--- @param projection EmissionProjection
--- @param atom_record AtomEntry
--- @param src SourceFile
--- @param corpus Corpus
--- @return nil
local function stamp_root_provenance(projection, atom_record, src, corpus)
	--- @type (fun(pos: integer): integer)|nil
	local root_line_of   = src.scan and src.scan.line_of
	assert(type(root_line_of) == "function"
		, "emission_model: src.scan.line_of is required (canonical LineIndex closure over the source text) to stamp physical provenance")
	assert(type(atom_record.body_off) == "number"
		, "emission_model: atom_record.body_off (byte offset of the body's first byte in source) is required to derive `root_body_line`. The scanner must populate body_off for every atom record.")
	-- `root_body_line` is the physical source line of the ATOM HEADER byte containing the opening `{`; that byte is one byte BEFORE `atom_record.body_off`.
	-- The walker assigns line 2 to the body's first content line because line 1 is the trailing `\n` after `{`. Body-text line k therefore maps to `root_body_line + (k - 1)`.
	-- `body_off - 1` points at the opening `{`, whose line index identifies the header line. `body_off` points after `{` and would shift every word row forward by one line.
	--- @type integer
	local root_body_line  = root_line_of(atom_record.body_off - 1) or atom_record.line or 0
	--- @type table<string, ComponentBodyEntry>
	local component_index = corpus.component_body_index or {}
	--- @type EmissionItem[]
	local word_items      = {}

	--- @type integer, EmissionItem
	for _, item in ipairs(projection.items) do
		if item.kind == "word" then word_items[#word_items + 1] = item end
	end

	-- Resolve one word's physical body line, where the byte containing that word appears in source.
	--   * Component expansions carry `invocation_ids`; the component's full-file `line_of` leaves `item.line` physical.
	--   * Raw tokens in the root atom body carry an empty `invocation_ids` list and a body-relative `item.line`; convert them here.
	--- @param event WordEvent
	--- @param item EmissionItem
	--- @return integer
	local function body_line_for(event, item)
		--- @type integer[]
		local ids = event.invocation_ids or {}
		-- The innermost open invocation identifies which line index the walker used.
		-- A component `line_of` makes `item.line` physical; the atom's `body_text` line index makes it body-relative.
		if ids and #ids > 0 then
			--- @type integer
			local inner_id  = ids[#ids]
			--- @type InvocationRecord|nil
			local inner_inv = inner_id and projection.invocations[inner_id]
			if inner_inv then
				--- @type ComponentBodyEntry|nil
				local component = component_index[inner_inv.component_name]
				if component and component.line_of then
					-- Walker used `comp.line_of`, which is the source's physical LineIndex. item.line is already physical.
					return item.line or 0
				end
			end
		end
		-- RAW root-body word: item.line is body-text's 1-based line number (the first content line is line 2 because line 1 is the trailing `\n` after `{`).
		-- Convert body-text-relative → physical using `root_body_line + (item.line - 1)`.
		return (root_body_line or 0) + (item.line or 1) - 1
	end

	-- Stamp the root source path onto invocation records whose `call_path` the walker left empty.
	-- The walker passes `body_entry.source` to `emit_invoke_begin`; `M.project_emission` creates the root `body_entry` with source `""`, leaving its `call_path` empty.
	-- This stamp gives every invocation a physical `call_path` matching `passes/atoms_source_map.lua`'s in-memory provenance projection.
	--- @type string
	local root_path = src.path or ""
	--- @type integer, InvocationRecord
	for _, inv in ipairs(projection.invocations) do
		if inv.call_path == nil or inv.call_path == "" then
			inv.call_path = root_path
		end
	end

	-- Normalize `inv.call_line` to a physical source line.
	--   * ROOT  invocations (`parent_id == 0`) carry body-relative `call_line` values from `M.LineIndex(body_text)`; convert them once with `root_body_line`.
	--   * INNER invocations (`parent_id ~= 0`) carry physical `call_line` values from the component's `line_of`; retain them unchanged.
	--- @type integer, InvocationRecord
	for _, inv in ipairs(projection.invocations) do
		if inv.parent_id == 0 then
			inv.call_line = (root_body_line or 0) + (inv.call_line or 1) - 1
		end
	end

	-- Build `body_lines` for each invocation.
	-- `atoms_source_map` and `dwarf_injection` read `inv.body_lines[k]` directly from the invocation record created here.
	-- Component words already carry physical `item.line` values from the walker's COMPONENT line index, so `body_line_for` returns them unchanged.
	--- @type integer, InvocationRecord
	for _, inv in ipairs(projection.invocations) do
		--- @type integer
		local sw  = inv.start_word
		--- @type integer
		local ew  = inv.end_word
		--- @type integer[]
		local bls = {}
		--- @type integer
		for i = sw, ew do
			--- @type EmissionItem|nil
			local it = projection.items and projection.items[i]
			if    it and it.kind == "word" then
				--- @type WordEvent
				local fake_event = { invocation_ids = { inv.id } }
				bls[#bls + 1]    = body_line_for(fake_event, it) or 0
			end
		end
		inv.body_lines = bls
	end

	-- Resolve each `word_event`'s physical `body_line` and `call_line`.
	-- For words inside an invocation, `we.call_line` identifies the OUTER atom source line containing the `mac_X(...)` token that triggered expansion.
	-- The root-invocation conversion above makes every `inv.call_line` physical; forward it directly and use each raw word's `body_line` as the fallback.
	--- @type integer, WordEvent
	for index, we in ipairs(projection.word_events) do
		--- @type EmissionItem
		local item      = word_items[index] or {}
		--- @type integer
		local body_line = body_line_for(we, item)
		item.line    = body_line
		we.body_line = body_line

		--- @type integer
		local call_line = body_line
		--- @type integer
		local outer_id  = we.outermost_invocation_id or 0
		--- @type InvocationRecord|nil
		local outer_inv = projection.invocations[outer_id]
		if outer_inv then
			-- `outer_inv.call_line` is physical after the conversion loop above, so use it directly.
			call_line = outer_inv.call_line
		end
		we.call_line = call_line

		if we.def_path  == nil or we.def_path  == "" then we.def_path  = src.path         or "" end
		if we.def_line  == nil or we.def_line  == 0  then we.def_line  = atom_record.line or 0  end
		if we.call_path == nil or we.call_path == "" then we.call_path = src.path         or "" end
	end
end

-- Project one atom record into `atom.paths`.
-- Mutates the atom record in-place and returns the projection (for pass-level error/warning accumulation).
--- @param atom_record AtomEntry
--- @param src SourceFile
--- @param corpus Corpus
--- @return EmissionProjection
local function project_atom(atom_record, src, corpus)
	--- @type string
	local body  = atom_record.body or ""
	--- @type WordCounts
	local wc    = corpus.word_counts or {}
	--- @type table<string, ComponentBodyEntry>
	local cbi   = corpus.component_body_index or {}
	--- @type RegUseSchema|nil
	local schema = nil
	if atom_record.reg_use_schema_name then
		schema = corpus.reg_use_schemas and corpus.reg_use_schemas[atom_record.reg_use_schema_name]
	end
	-- That construction site stamps `invocation.debug_skip` while appending each record to `proj.invocations`.
	--- @type EmissionProjection
	local proj  = duffle.project_emission(body, cbi, wc, corpus.components, {
		reg_use_schema = schema,
		reg_use_param  = atom_record.reg_use_param_name,
		atom_name      = atom_record.name,
		schema_name    = atom_record.reg_use_schema_name,
	})
	if atom_record.reg_use_schema_name and not schema then
		proj.errors[#proj.errors + 1] = {
			kind = "reguse_missing_schema",
			msg  = string.format("RegUse schema %q is missing", atom_record.reg_use_schema_name),
		}
	end
	--- @type integer, EmitError
	for _, err in ipairs(corpus.reg_use_errors or {}) do
		if err.schema_name == atom_record.reg_use_schema_name then
			proj.errors[#proj.errors + 1] = err
		end
	end
	--- @type AtomPaths
	local paths = {
		tokens       = atom_record.body_tokens or {},
		line_in_body = duffle.build_body_line_index(body),
		items        = proj.items,
		word_events  = proj.word_events,
		markers      = proj.markers,
		invocations  = proj.invocations,
		errors       = proj.errors,
		warnings     = proj.warnings,
	}
	stamp_root_provenance(proj, atom_record, src, corpus)
	atom_record.paths = paths
	return proj
end

-- ─────────────────────────────────────────────────────────────────────────
-- Run the emission-model pass.
-- ─────────────────────────────────────────────────────────────────────────

--- @param ctx PassCtx  -- { shared = { corpus = ... }, out_root, ... }
--- @return PassResult
function M.run(ctx)
	--- @type PassOutputEntry[]
	local outputs  = {}
	--- @type EmitError[]
	local errors   = {}
	--- @type EmitWarning[]
	local warnings = {}

	--- @type Corpus|nil
	local corpus = ctx and ctx.shared and ctx.shared.corpus
	if type(corpus)              ~= "table" then error("emission_model: ctx.shared.corpus is required (canonical projection)", 0) end
	if type(corpus.source_order) ~= "table" then error("emission_model: ctx.shared.corpus.source_order is required", 0) end

	-- Project once, collect errors + warnings for one atom.
	-- Kind must be one of: atom | atom_proc | raw_atom | comp_bare | comp_proc.
	--- @param atom AtomEntry
	--- @param src SourceFile
	--- @return nil
	local function process_atom(atom, src)
		if not (atom and atom.body) then return end
		--- @type string
		local kind = atom.kind
		if kind ~= "atom" and kind ~= "atom_proc" and kind ~= "raw_atom" and kind ~= "comp_bare" and kind ~= "comp_proc" then
			return
		end
		--- @type EmissionProjection
		local proj = project_atom(atom, src, corpus)
		--- @type integer, EmitError
		for _, e in ipairs(proj.errors) do
			-- Preserve `kind` (cycle / count_mismatch / unbalanced) so readers dispatch on the diagnostic class and leave the message string as display text.
			errors[#errors + 1] = {
				kind   = e.kind,
				line   = e.line,
				msg    = e.msg,
				source = e.source or src.path,
			}
		end
		--- @type integer, EmitWarning
		for _, w in ipairs(proj.warnings) do
			warnings[#warnings + 1] = {
				kind = w.kind,
				line = w.line,
				msg  = w.msg,
			}
		end
	end

	-- Walk `corpus.source_order`; within each source, visit atoms followed by raw_atoms.
	-- Recognized kinds (atom | atom_proc | raw_atom | comp_bare | comp_proc) each receive the atom.paths projection via duffle.project_emission.
	-- Components are macros inlined into atom bodies; focused tests and isolated component analyses consume atom.paths directly.
	--- @type integer, SourceFile
	for _, src in ipairs(corpus.source_order) do
		--- @type SourceScan
		local scan = src.scan or {}
		--- @type integer, AtomEntry
		for _, atom in ipairs(scan.atoms or {}) do
			process_atom(atom, src)
		end
		--- @type integer, AtomEntry
		for _, atom in ipairs(scan.raw_atoms or {}) do
			process_atom(atom, src)
		end
	end

	return {
		outputs  = outputs,
		errors   = errors,
		warnings = warnings,
	}
end

return M
