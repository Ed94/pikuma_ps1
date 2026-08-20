--- duffle_emit.lua — project_emission + decl finders.
local scan = require("duffle_scan")     ---@type DuffleScan
local isa  = require("duffle_isa")      ---@type DuffleIsa
local M = {}                            ---@type DuffleEmit
for k, v in pairs(scan) do M[k] = v end ---@type string, any
for k, v in pairs(isa)  do M[k] = v end ---@type string, any

-- Section 8: Cross-source component-body index + word-event expansion
-- ════════════════════════════════════════════════════════════════════════════
--
-- Shared, memoized helpers: a single emitted-word event stream that every downstream pass reads from,
-- built once from the pre-tokenized bodies.

--- @class EmissionWalkCtx
--- @field components      table<string, Component>
--- @field word_counts     WordCounts
--- @field reg_use_schema  RegUseSchema|nil
--- @field reg_use_param   string|nil
--- @field atom_name       AtomName|nil
--- @field schema_name     string|nil
--- @field visiting        table<string, boolean>|nil  -- bag: component name on DFS stack
--- @field root_call_path  string|nil
--- @field root_call_line  integer|nil

--- @class RegUseCtx
--- @field reg_use_schema RegUseSchema|nil
--- @field reg_use_param  string|nil
--- @field atom_name      AtomName|nil
--- @field schema_name    string|nil

-- Finding: see ps1_meta.lua

--- @class DuffleEmit


-- The cross-source component row is owned by the corpus (`corpus.components`, populated by `passes/components.lua`).
-- Consumers (`passes/static_analysis.lua`, `passes/emission_model.lua`) read it directly; per-pass memoization helpers stay out of scope.

-- ASCII byte constants used by split_call_args (kept local to keep Section 8 self-contained).
local E_BYTE_OPEN_PAREN  = 0x28 ---@type integer
local E_BYTE_OPEN_BRACE  = 0x7B ---@type integer
local E_BYTE_OPEN_BRACK  = 0x5B ---@type integer
local E_BYTE_DQUOTE      = 0x22 ---@type integer
local E_BYTE_SQUOTE      = 0x27 ---@type integer
local E_BYTE_COMMA       = 0x2C ---@type integer

-- Map an open-delimiter byte to its matching close string for read_balanced.
local E_OPEN_CLOSE = { ---@type table<integer, string>  -- bag: open-delimiter byte -> close string
	[E_BYTE_OPEN_PAREN] = ")",
	[E_BYTE_OPEN_BRACE] = "}",
	[E_BYTE_OPEN_BRACK] = "]",
}

--- Split the INSIDE of a `f(...)` call on top-level commas.
--- Honors nested parens / braces / brackets and skips strings / comments.
--- Returns a list of trimmed argument strings in source order.
--- (Mirrors split_top_level_commas but for paren-body args; intentionally distinct so a caller's brace-body split isn't confused with an arg list.)
--- @param inner string
--- @return string[]
local function split_call_args(inner)
	local args = {} ---@type string[]
	if not inner or inner == "" then return args end
	local pos   = 1      ---@type integer
	local len   = #inner ---@type integer
	local start = 1      ---@type integer
	while pos <= len do
		local c     = inner:byte(pos) ---@type integer
		local close = E_OPEN_CLOSE[c] ---@type string|nil
		if close then
			local _, after = M.read_balanced(inner, string.char(c), close, pos) ---@type integer, integer
			pos = after
		elseif c == E_BYTE_DQUOTE or c == E_BYTE_SQUOTE then
			pos = M.skip_str_or_cmt(inner, pos)
		elseif c == E_BYTE_COMMA then
			args[#args + 1] = M.trim(inner:sub(start, pos - 1))
			start = pos + 1
			pos   = pos + 1
		else
			pos = pos + 1
		end
	end
	if start <= len then args[#args + 1] = M.trim(inner:sub(start, len)) end
	return args
end

--- Extract the leading identifier + top-level args list from a token string.
--- Returns (ident, args). For tokens without a `(...)` call, args is `{}`.
--- @param tok string
--- @return string, string[]
local function token_ident_and_args(tok)
	local  ident, after = M.read_ident(tok, 1) ---@type string|nil, integer
	if not ident then return "?", {} end
	local paren_pos = M.skip_ws_and_cmt(tok, after) ---@type integer
	if tok:sub(paren_pos, paren_pos) ~= "(" then return ident, {} end
	local  inner = M.read_parens(tok, paren_pos) ---@type string|nil
	if not inner then return ident, {} end
	return ident, split_call_args(inner)
end

-- The macro-name prefix that marks a `mac_X(...)` component invocation.
local E_MAC_PREFIX     = "mac_" ---@type string
local E_MAC_PREFIX_LEN = 4      ---@type integer

--- Expand a body entry into the flat sequence of emitted machine-word events.
---
--- Semantics (one event per emitted machine word):
---   * Direct one-word encoders `load_word`, `add_ui`, `nop`, `gte_lw`, ...: One event with `ident` = leading ident, `args` = parsed top-level args.
---   * `nop2` (2-word pseudo-instruction): Two events, both with `ident = "nop"` so the recognized "this slot is a no-op" semantic is visible to downstream analyses.
---   * Any other N-word token in `word_counts`: N events sharing the same `ident` + `args` so useful CPU words retire slots in the cycle budget.
---   * Known `mac_X(...)` calls: Recursively expand the indexed component body, including nested components. Every event from the expansion carries:
---     - `source` / `line` = the COMPONENT'S source path + the line of the token within the component body (i.e. "definition site").
---     - `call_source` / `call_line` = the ROOT atom's source path + call-site line, PRESERVED across recursion so nested events still point at the original root.
---   * Unknown `mac_X` (not in `components`): fall back to `word_counts[ident]` if present; otherwise emit one opaque event so the cycle budget accounts for the word.
---   * Marker Tokens (`atom_label(...)` / `atom_offset(...)`): Zero events (they are pure metaprogram hints).
---
--- Cycle protection: a per-expansion `visiting` set tracks components currently on the expansion stack;
--- a re-entry produces a deterministic `{check = "cycle", ...}` error and aborts that branch (does NOT hang, does NOT recurse).
---
--- Pure: reads `body_entry` / `components` / `word_counts`. Memoization is the caller's responsibility.
--- Callers wanting `word_events` / `word_event_errors` precomputed for many atoms should memoize them per atom.
--- @param body_entry   Component
--- @param components   table<string, Component>
--- @param word_counts  WordCounts
--- @return WordEvent[], Finding[]

-- ════════════════════════════════════════════════════════════════════════════
-- Section 11: project_emission (per-atom emission projection)
-- ════════════════════════════════════════════════════════════════════════════
--
-- Per-atom emission projection is owned by `passes/emission_model.lua`.
-- The projection is built from the root atom body only; invocation ancestry recursively expands nested components.
-- The items stream is the single ordered source of truth; `word_events` and `markers` are dense views over it.
--
-- The helper below operates on a body string (not a body_entry) so the pass can call it without depending on the older SourceScan / body_off conventions.
-- `components` is the recursive expansion map (`corpus.components`).
-- word_counts table is authored-metadata + current-component count table.

--- @class EmissionProjection
--- @field items       EmissionItem[]
--- @field word_events WordEvent[]
--- @field markers     EmissionMarker[]
--- @field invocations InvocationRecord[] -- dense view of items where kind == "invoke_begin"|"invoke_end"
--- @field errors      Finding[]
--- @field warnings    Finding[]

--- @class InvocationRecord
--- Lives at `atom.paths.invocations[*]`. Constructed once at the single invocation-construction site
--- (`emit_invoke_begin` inside `_project_emission_inner`); `invoke_begin` / `invoke_end` markers in the items stream share the same `id`.
--- @field id              integer  -- 1-based, monotonic per-atom invocation id (0 is reserved for "no open invocation")
--- @field parent_id       integer  -- 0 for the outermost (root) call; otherwise the id of the immediately enclosing invocation
--- @field kind            string   -- "comp_bare" | "comp_proc" (component form that triggered the expansion)
--- @field component_name  string   -- Bare component name without the `mac_` prefix
--- @field call_text       string   -- Immediate `mac_X(...)` token text (or root call text for the outermost entry)
--- @field root_call_text  string   -- IMMUTABLE outermost `mac_X(...)` token text for every word emitted in this call's expansion
--- @field call_path       string   -- Source path of the call site (root atom source for direct calls, component source for nested expansions)
--- @field call_line       integer  -- Source line of the call site
--- @field def_path        string   -- Source path of the component definition
--- @field def_line        integer  -- Source line of the component declaration
--- @field start_pos       integer  -- 0-based emitted-word position of the FIRST word inside this invocation (the value of `word_idx` AT `emit_invoke_begin` time, BEFORE the first word is emitted). Words emitted inside this invocation occupy `start_pos..start_pos+#body_lines-1` (inclusive, 0-based). Downstream DWARF/provenance consumers MUST read this; do NOT reconstruct it from `start_word` (which is the 1-based items index including `invoke_begin`/`invoke_end` markers).
--- @field end_pos         integer  -- 0-based position of the LAST word inside this invocation (set by `emit_invoke_end` to `word_idx - 1` AFTER all body words are emitted).
--- @field start_word      integer  -- 1-based items index of the `invoke_begin` item
--- @field end_word        integer  -- 1-based items index of the `invoke_end` item (set by `emit_invoke_end`)
--- @field word_count      integer  -- Number of `word` items emitted between `start_word` and `end_word` (inclusive)
--- @field debug_skip      boolean  -- `debug_skip` stamp; true iff `corpus.components[name].debug_skip` is true at construction. Always boolean (never `nil`).
--- @field errors          Finding[]

-- Internal recursive walker. The items stream holds every emitted event in order; `word_events`, `markers`,
-- `invocations`, `errors`, `warnings` are dense views / side outputs appended alongside.
--
-- Output rules:
--   * `word` items record: `invocation_ids` (innermost last) and `outermost_invocation_id` (0 if no invocation is open).
--   * `invoke_begin` / `invoke_end` items are zero-width at the current word index; the same `word_index` is recorded on both.
--   * `root_call_text` is the outermost `mac_X(...)` token text for every word emitted inside a component expansion;
--     it is `nil` for direct words emitted from the root atom body.
--   * `call_text` is the IMMEDIATE top-level token spelling for the word (for nested words this is the inner `mac_X(...)` token; 
--     for direct words it is the trimmed encoder token).
--   * `def_path` / `def_line` are the definition site of the current body (component source for nested words; root atom source for direct words, filled in by the pass caller).
--   * Unknown uncounted macros emit one opaque word + one warning. Unknown metadata-backed macros (entry in `word_counts`) emit the declared word count, no warning.
--   * Cycle detection uses an active DFS stack (`visiting`); a cycle appends a construction error to BOTH the projection errors and the cycle invocation's own errors,
--     then breaks out without recursing (the cycle entry still receives an invocation ID + paired `invoke_begin` / `invoke_end` items, so the boundary invariant is preserved).
--   * Component declared-count mismatch (declared vs. measured) is a construction error (check = "count_mismatch"); recorded on the invocation record and pass-level errors list.
--   * Final boundary check: if any invocation is still open at end of walk, surface a "unbalanced" construction error.
--- @param root_body_entry Component
--- @param ctx_table EmissionWalkCtx
--- @return EmissionProjection
local function _project_emission_inner(root_body_entry, ctx_table)
	local items       = {} ---@type EmissionItem[]
	local word_events = {} ---@type WordEvent[]
	local markers     = {} ---@type EmissionMarker[]
	local invocations = {} ---@type InvocationRecord[]
	local errors      = {} ---@type Finding[]
	local warnings    = {} ---@type Finding[]

	local word_idx         = 0  ---@type integer
	local invocation_stack = {} ---@type InvocationRecord[] -- stack of currently-open invocation records
	local next_inv_id      = 0  ---@type integer

	local reg_use_schema = ctx_table.reg_use_schema ---@type RegUseSchema|nil
	local reg_use_param  = ctx_table.reg_use_param  ---@type string|nil
	local atom_name      = ctx_table.atom_name      ---@type AtomName|nil

	local slot_readonly = {} ---@type table<string, boolean>  -- bag: slot name -> readonly
	if reg_use_schema then
		for _, slot in ipairs(reg_use_schema.slots or {}) do ---@type integer, RegUseSlot
			slot_readonly[slot.name] = slot.readonly == true
		end
	end

--- @param sub_map table<string, string>|nil
--- @param operand string|any
--- @return any
	local function apply_sub(sub_map, operand)
		if not (sub_map and type(operand) == "string") then return operand end
		if sub_map[operand] then return sub_map[operand] end
		local dot = operand:find(".", 1, true) ---@type integer|nil
		if dot then
			local head = operand:sub(1, dot - 1) ---@type string
			local mapped = sub_map[head]         ---@type string|nil
			if type(mapped) == "string" then
				return mapped .. operand:sub(dot)
			end
		end
		return operand
	end

--- @param operand string|any
--- @return string|nil, string|nil, string|nil
	local function resolve_gpr_key(operand)
		if type(operand) ~= "string" then return nil end
		if operand:sub(1, 2) == "R_" then return operand end
		if not (reg_use_schema and reg_use_param) then return nil end
		local prefix = reg_use_param .. "." ---@type string
		if operand:sub(1, #prefix) ~= prefix then return nil end
		local member_path = operand:sub(#prefix + 1)                  ---@type string
		local  slot       = reg_use_schema.alias_to_slot[member_path] ---@type string|nil
		if not slot then return nil, member_path end
		return "reguse:" .. atom_name .. ":" .. slot, nil, slot
	end

--- @return integer[]
	local function open_invocation_ids_snapshot()
		local ids = {}                            ---@type integer[]
		for _, inv in ipairs(invocation_stack) do ---@type integer, InvocationRecord
			ids[#ids + 1] = inv.id
		end
		return ids
	end

--- @param encoder string
--- @param args string[]|nil
--- @param line integer
--- @param word_call_text string|nil
--- @param def_source_now string|nil
--- @param def_line_now integer|nil
--- @param immediate_call_text string|nil
--- @param root_call_text_w string|nil
--- @param sub_map table<string, string>|nil
--- @return nil
	local function emit_word(encoder, args, line, word_call_text, def_source_now, def_line_now, immediate_call_text, root_call_text_w, sub_map)
		local inv_ids   = open_invocation_ids_snapshot() ---@type integer[]
		local outermost = inv_ids[1] or 0                ---@type integer
		-- For words emitted at the root atom body, `immediate_call_text` is nil and the walker's `word_call_text` (the word's own token, e.g. "nop") becomes the effective call_text.
		-- For words emitted inside a component expansion, `immediate_call_text` is the immediate outer `mac_X(...)` token text;
		-- The call that triggered the body expansion we're currently walking.
		local eff_call_text      = immediate_call_text or word_call_text ---@type string|nil
		local eff_root_call_text = root_call_text_w                      ---@type string|nil
		local gpr_keys           = nil                                   ---@type string[]|nil
		if reg_use_schema or sub_map then
			gpr_keys = {}
			for pos, arg in ipairs(args or {}) do ---@type integer, string
				local effective = apply_sub(sub_map, arg)                ---@type any
				local key, unresolved, slot = resolve_gpr_key(effective) ---@type string|nil, string|nil, string|nil
				gpr_keys[pos] = key
				if unresolved then
					errors[#errors + 1] = {
						kind  = "error",
						check = "reguse_unresolved",
						line  = line,
						msg   = string.format("RegUse operand %q does not resolve in schema %q",
							effective, (reg_use_schema and reg_use_schema.name) or "?"),
					}
				end
				if key and slot and slot_readonly[slot] then
					local row = M.instr(encoder) ---@type InstructionRow|nil
					if row and row.writes then
						for _, wpos in ipairs(row.writes) do ---@type integer, integer
							if wpos == pos then
								errors[#errors + 1] = {
									kind  = "error",
									check = "reguse_const_write",
									line  = line,
									msg   = string.format("RegUse slot %q is Reg const; %s writes it",
										slot, encoder),
								}
							end
						end
					end
				end
			end
		end
		if not reg_use_schema then
			gpr_keys = nil
		end
		local isa       = M.instr(encoder)                                           ---@type InstructionRow|nil
		local isa_kind  = isa and isa.kind or "unknown"                              ---@type string
		local nop_words = (encoder == "nop" and 1) or (encoder == "nop2" and 2) or 0 ---@type integer
		local is_yield  = (encoder == "mac_yield" or encoder == "mac_yield_tail")    ---@type boolean
		local gp0_shape = type(encoder) == "string"                                  ---@type string|nil
			and encoder:match("^mac_format_([%w_]+)_color$")
			or nil
		local is_load               = (isa_kind == "load")                                                       ---@type boolean
		local is_branch             = (isa_kind == "branch")                                                     ---@type boolean
		local is_unconditional_jump = (encoder == "jump" or encoder == "call_addr")                              ---@type boolean
		local is_terminal_jump      = (encoder == "jump_reg" or encoder == "call_reg" or encoder == "jump_link") ---@type boolean
		items[#items + 1] = {
			kind                     = "word",
			encoder                  = encoder,
			args                     = args,
			i                        = word_idx,
			word_count               = 1,
			line                     = line,
			call_text                = eff_call_text,
			root_call_text           = eff_root_call_text,
			invocation_ids           = inv_ids,
			outermost_invocation_id  = outermost,
			gpr_keys                 = gpr_keys,
			ident                    = encoder,
			isa_kind                 = isa_kind,
			nop_words                = nop_words,
			is_yield                 = is_yield,
			is_load                  = is_load,
			is_branch                = is_branch,
			is_unconditional_jump    = is_unconditional_jump,
			is_terminal_jump         = is_terminal_jump,
			gp0_shape                = gp0_shape,
		}
		word_events[#word_events + 1] = {
			i                        = word_idx,
			encoder                  = encoder,
			args                     = args,
			def_path                 = def_source_now or "",
			def_line                 = def_line_now or 0,
			call_text                = eff_call_text,
			root_call_text           = eff_root_call_text,
			invocation_ids           = inv_ids,
			outermost_invocation_id  = outermost,
			word_count               = 1,
			gpr_keys                 = gpr_keys,
			ident                    = encoder,
			kind                     = isa_kind,
			nop_words                = nop_words,
			is_yield                 = is_yield,
			is_load                  = is_load,
			is_branch                = is_branch,
			is_unconditional_jump    = is_unconditional_jump,
			is_terminal_jump         = is_terminal_jump,
			gp0_shape                = gp0_shape,
		}
		word_idx = word_idx + 1
	end

--- @param kind string
--- @param name string
--- @param target string|nil
--- @param line integer
--- @param immediate_call_text string|nil
--- @param root_call_text_w string|nil
--- @param consuming_encoder string|nil
--- @param consuming_arg_pos integer|nil
--- @return nil
	local function emit_marker(kind, name, target, line,
		immediate_call_text, root_call_text_w,
		consuming_encoder, consuming_arg_pos)
		local inv_ids   = open_invocation_ids_snapshot() ---@type integer[]
		local outermost = inv_ids[1] or 0                ---@type integer
		-- Markers carry the open invocation stack snapshot. `call_text` / `root_call_text` belong to words, not markers — markers are zero-width and skip per-word call-site attribution.
		-- `consuming_encoder` + `consuming_arg_pos` carry the surrounding control-transfer instruction context
		-- (e.g. `branch_le_zero` consuming its 3rd argument, or `jump` / `call_addr` consuming their only argument).
		-- `passes/offsets.lua` reads these to dispatch per-consuming-instruction offset encoding.
		-- Offset markers require a real consuming encoder. A lone top-level `atom_offset` is not emitted.
		-- Label and delay markers may have a nil encoder (they are not consumed as immediates).
		if kind == "offset" and (consuming_encoder == nil or consuming_encoder == "") then
			return
		end
		local it = { ---@type EmissionItem
			kind                    = kind,
			name                    = name,
			line                    = line,
			word_index              = word_idx,
			invocation_ids          = inv_ids,
			outermost_invocation_id = outermost,
		}
		if target ~= nil then it.target = target end
		if consuming_encoder then it.consuming_encoder = consuming_encoder end
		if consuming_arg_pos  then it.consuming_arg_pos  = consuming_arg_pos  end
		items[#items + 1] = it
		markers[#markers + 1] = {
			kind              = kind,
			name              = name,
			line              = line,
			word_index        = word_idx,
			target            = target,
			consuming_encoder = consuming_encoder,
			consuming_arg_pos = consuming_arg_pos,
		}
	end

	-- Count top-level commas in `tok` between position `from_pos` (inclusive) and `to_pos` (exclusive).
	-- Tracks paren depth so commas inside nested () don't count. Skips string literals + comments.
	-- Used by `emit_embedded_markers` to compute `consuming_arg_pos` for each embedded marker.
--- @param tok string
--- @param from_pos integer
--- @param to_pos integer
--- @return integer
	local function count_top_level_commas(tok, from_pos, to_pos)
		local depth  = 0        ---@type integer
		local count  = 0        ---@type integer
		local i      = from_pos ---@type integer
		while i < to_pos do
			local c = tok:sub(i, i) ---@type string
			if c == "'" or c == '"' then
				local next_pos = M.skip_str_or_cmt(tok, i) ---@type integer
				i = (next_pos > i) and next_pos or (i + 1)
			elseif c == "/" and tok:sub(i + 1, i + 1) == "/" then
				-- line comment: skip to end of line
				local nl = tok:find("\n", i, true) ---@type integer|nil
				i = (nl and nl + 1) or (#tok + 1)
			elseif c == "/" and tok:sub(i + 1, i + 1) == "*" then
				-- block comment: skip to matching */
				local close = tok:find("*/", i + 2, true) ---@type integer|nil
				i = (close and close + 2) or (#tok + 1)
			elseif c == "(" then
				depth = depth + 1
				i = i + 1
			elseif c == ")" then
				depth = depth - 1
				i = i + 1
			elseif c == "," and depth == 0 then
				count = count + 1
				i = i + 1
			else
				i = i + 1
			end
		end
		return count
	end

	-- Find the position of the consuming instruction's open paren (the `(` that starts the consuming instruction's argument list).
	-- Returns nil if the token's leading text isn't an ident followed by `(` (e.g. the ident is at the start of a non-instruction token).
--- @param tok string
--- @return integer|nil
	local function find_consuming_paren(tok)
		local i = 1 ---@type integer
		while i <= #tok do
			local c = tok:sub(i, i) ---@type string
			if    c == "(" then return i end
			if not c:match("[%w_]") and c ~= " " then return nil end
			i = i + 1
		end
		return nil
	end

--- @param tok string
--- @param tok_line integer
--- @param consuming_encoder string|nil
--- @return nil
	local function emit_embedded_markers(tok, tok_line, consuming_encoder)
		-- When called with a non-nil `consuming_encoder`, the marker is nested inside that instruction's argument list.
		-- We compute each marker's arg position by counting top-level commas between the consuming instruction's `(` and the marker's start.
		local consuming_paren = nil ---@type integer|nil
		if consuming_encoder then consuming_paren = find_consuming_paren(tok) end
		local pos = 1 ---@type integer
		while pos <= #tok do
			-- Trim leading whitespace and comments before each scan.
			pos = M.skip_ws_and_cmt(tok, pos)
			if pos > #tok then break end
			local  ident, after = M.read_ident(tok, pos) ---@type string|nil, integer
			if not ident then
				-- Not an ident: token is a string or comment; skip or one-step.
				local next_pos = M.skip_str_or_cmt(tok, pos) ---@type integer
				pos = (next_pos > pos) and next_pos or (pos + 1)
				goto continue_loop
			end
			if M.DELAY_MARKERS[ident] then
				local arg_pos = nil ---@type integer|nil
				if consuming_encoder and consuming_paren then
					arg_pos = count_top_level_commas(tok, consuming_paren + 1, pos) + 1
				end
				emit_marker("delay", ident, nil, tok_line, nil, nil, consuming_encoder, arg_pos)
				pos = after
				goto continue_loop
			end
			if ident ~= "atom_label" and ident ~= "atom_offset" then
				-- Ordinary ident; nothing to emit, step past the ident only.
				pos = after
				goto continue_loop
			end
			-- Marker ident: parse the (...) arguments.
			local open               = M.skip_ws_and_cmt(tok, after) ---@type integer
			local inner, after_paren = M.read_parens(tok, open)      ---@type string|nil, integer
			if not inner then
				-- (...) Unreadable: fall back to non-marker behavior.
				pos = after
				goto continue_loop
			end
			-- Commit: label takes 1 arg, offset takes 2.
			-- For embedded markers, propagate the consuming_encoder + the marker's arg position
			-- (1-based) so `passes/offsets.lua` can dispatch per-consuming-instruction offset encoding.
			-- Offset markers are emitted only when a consuming encoder is present.
			local arg_pos = nil ---@type integer|nil
			if consuming_encoder and consuming_paren then
				arg_pos = count_top_level_commas(tok, consuming_paren + 1, pos) + 1
			end
			local args = split_call_args(inner) ---@type string[]
			if ident == "atom_label" then emit_marker("label",  args[1] or "", nil,           tok_line, nil, nil, consuming_encoder, arg_pos)
			elseif consuming_encoder then emit_marker("offset", args[1] or "", args[2] or "", tok_line, nil, nil, consuming_encoder, arg_pos)
			end
			pos = after_paren
			::continue_loop::
		end
	end

--- @param inv_kind string
--- @param component_name string
--- @param call_text string
--- @param root_call_text string|nil
--- @param call_path string
--- @param call_line integer
--- @return InvocationRecord
	local function emit_invoke_begin(inv_kind, component_name, call_text,
		root_call_text, call_path, call_line)
		next_inv_id = next_inv_id + 1
		-- Invocation-level debug_skip stamp: Emission pass owns `atom.paths.invocations[*].debug_skip`.
		-- The stamp is resolved from the `corpus.components[name]` registry (passed in via `ctx_table.components` by `emission_model.run`), 
		-- Unmarked components stamp `false` (not `nil`) so consumers can dispatch on the boolean without nil checks.
		--
		-- The walker has already found the component body in `ctx_table.components[component_name]`.
		-- A missing entry is a corpus-plumbing bug; we fail loudly here rather than silently stamp `false` and mask the regression.
		local  components    = ctx_table.components                             ---@type table<string, Component>|nil
		local  component_def = components and components[component_name] or nil ---@type Component|nil
		if not component_def then
			error("duffle.emit_invoke_begin: component " .. string.format("%q", component_name)
				.. " is present in the walk (the walker matched a `mac_" .. component_name .. "()` call) but absent from `components` (the canonical corpus.components registry). "
				.. "This is a corpus-plumbing bug — the components pass must populate corpus.components[name] for every expanded component. "
				.. "The emission pass refuses to silently stamp `debug_skip = false` for a missing registry entry."
				, 0
			)
		end
		local debug_skip_stamp = component_def.debug_skip == true ---@type boolean
		local inv = {                                             ---@type InvocationRecord
			id              = next_inv_id,
			parent_id       = 0,         -- patched below by caller
			kind            = inv_kind,
			component_name  = component_name,
			call_text       = call_text,
			root_call_text  = root_call_text,
			call_path       = call_path,
			call_line       = call_line,
			def_path        = nil,       -- patched below after component lookup
			def_line        = nil,
			-- 0-based emitted-word position. `word_idx` is the monotonic 0-based counter of `word` items emitted so far in this walk — 
			-- BEFORE this invocation's first word is emitted, it equals the position of the first word inside the invocation. 
			-- `start_word` (1-based items index of `invoke_begin`) is kept for items-walking consumers (Annotation pass bounds checks),
			-- but DWARF / provenance rows MUST read `start_pos` because those rows are 1-based over the dense `word_events` stream (which has no `invoke_begin` items).
			start_pos       = word_idx,
			start_word      = #items + 1, -- 1-based items index of invoke_begin
			end_pos         = nil,        -- patched by emit_invoke_end
			end_word        = nil,        -- patched by emit_invoke_end
			word_count      = 0,
			debug_skip      = debug_skip_stamp,
			errors          = {},
		}
		invocations[#invocations + 1] = inv
		items      [#items       + 1] = {
			kind           = "invoke_begin",
			invocation_id  = inv.id,
			word_index     = word_idx,
			invocation_ids = open_invocation_ids_snapshot(),
		}
		invocation_stack[#invocation_stack + 1] = inv
		return inv
	end

--- @param inv InvocationRecord
--- @return nil
	local function emit_invoke_end(inv)
		-- 0-based emitted-word position of the LAST word inside this invocation.
		-- After the last body word was emitted, `word_idx` was incremented past it, so `word_idx - 1` is the 0-based position of the last word.
		inv.end_pos  = word_idx - 1
		inv.end_word = #items   + 1  -- 1-based items index of invoke_end
		items[#items + 1] = {
			kind           = "invoke_end",
			invocation_id  = inv.id,
			word_index     = word_idx,
			invocation_ids = open_invocation_ids_snapshot(),
		}
		for i = #invocation_stack, 1, -1 do ---@type integer
			if invocation_stack[i] == inv then
				table.remove(invocation_stack, i)
				break
			end
		end
	end

	-- Resolve the per-token word count. If unresolved, surface ONE warning
	-- and fall back to 1 opaque word so the cycle budget still accounts for the slot.
--- @param ident string
--- @param tok_line integer
--- @return integer
	local function resolve_count(ident, tok_line)
		local wc = ctx_table.word_counts ---@type WordCounts|nil
		if    wc and wc[ident] then return wc[ident] end
		local canon = M.gte_canon(ident) ---@type string
		if    canon ~= ident and wc and wc[canon] then return wc[canon] end
		warnings[#warnings + 1] = {
			kind  = "warning",
			check = "uncounted",
			line  = tok_line,
			msg   = string.format("project_emission: opaque word emitted for %q (no entry in word_counts or components)", 
			ident),
		}
		return 1
	end

	-- Recursive walker: walk one body entry, possibly descending into components.
	-- walk_parent_inv_id:       Invocation ID of the enclosing call (0 for the root call).
	-- walk_root_call_text:      Outermost `mac_X(...)` token text (preserved across recursion).
	-- walk_immediate_call_text: IMMEDIATE outer `mac_X(...)` token text for words emitted in this body — nil for the root atom body.
	-- Two trackers are propagated as separate parameters so words deep inside nested expansions correctly identify both their immediate call site and the outermost call site.
--- @param body_entry Component
--- @param walk_parent_inv_id integer
--- @param walk_root_call_text string|nil
--- @param walk_immediate_call_text string|nil
--- @param sub_map table<string, string>|nil
--- @return nil
	local function walk_body_entry(body_entry, walk_parent_inv_id,
		walk_root_call_text, walk_immediate_call_text, sub_map)
		local tokens     = body_entry.body_tokens or {}          ---@type BodyToken[]
		local body_off   = body_entry.body_off or 0              ---@type integer
		local line_of    = body_entry.line_of or M.LineIndex("") ---@type LineIndexFn
		local def_source = body_entry.source or ""               ---@type string
		local def_line   = body_entry.line or 0                  ---@type integer
		-- Per-token dispatch: each matched branch returns; only the fall-through
		-- "opaque word" emit handles direct encoders + mac_X-without-component.
--- @param bt BodyToken
--- @return nil
		local function process_token(bt)
			local tok = M.trim(bt.tok or "") ---@type string
			-- Substituted MipsCode args can carry // comments from the call site.
			while tok ~= "" do
				if tok:sub(1, 2) == "//" then
					local nl = tok:find("\n") ---@type integer|nil
					tok = M.trim(nl and tok:sub(nl + 1) or "")
				elseif tok:sub(1, 2) == "/*" then
					local close = tok:find("*/", 3, true) ---@type integer|nil
					tok = M.trim(close and tok:sub(close + 2) or "")
				else
					break
				end
			end
			if tok == "" then return end
			local ident, after = M.read_ident(tok, 1) ---@type string|nil, integer
			if not ident then ident = "?" end
			local _, args  = token_ident_and_args(tok)       ---@type string, string[]
			local tok_line = line_of(body_off + bt.rel) or 0 ---@type integer
			if M.DELAY_MARKERS[ident] then
				emit_marker("delay", ident, nil, tok_line)
				local rest = tok:sub(after or (#tok + 1)) ---@type string
				while true do
					rest = M.trim(rest)
					if rest:sub(1, 2) == "//" then
						local nl = rest:find("\n") ---@type integer|nil
						rest = nl and rest:sub(nl + 1) or ""
					elseif rest:sub(1, 2) == "/*" then
						local close = rest:find("*/", 3, true) ---@type integer|nil
						if not close then rest = ""; break end
						rest = rest:sub(close + 2)
					else
						break
					end
				end
				if rest ~= "" then
					process_token({ tok = rest, rel = bt.rel })
				end
				return
			end
			-- embedded markers live only in non-marker tokens.
			-- Pass `ident` as the consuming instruction so `emit_embedded_markers` can compute each marker's arg position + record the consuming_encoder for the offsets pass.
			-- Canonicalize `jump_rel` to `branch_equal` (its preprocessor-expanded form) so the `consuming_encoder` metadata in marker records is canonical. 
			-- `jump_rel`: unconditional jump alias from `code/duffle/mips.h`.
			local consuming_encoder_for_markers = (ident == "jump_rel") and "branch_equal" or ident ---@type string
			if ident ~= "atom_label" and ident ~= "atom_offset" then
				emit_embedded_markers(tok, tok_line, consuming_encoder_for_markers)
			end
			-- atom_label / atom_offset: terminal markers, no further descent.
			-- A lone top-level atom_label is an anchor and is emitted with no consuming encoder.
			-- A lone top-level atom_offset has no consuming encoder and is not emitted.
			if     ident == "atom_label"  then emit_marker("label", args[1] or "", nil, tok_line); return
			elseif ident == "atom_offset" then return
			end
			-- MipsCode formals (nop_slot1, …): the ident is a sub_map key.
			-- Re-process the replacement token so load_word(...) becomes a real encoder.
			if sub_map and type(sub_map[ident]) == "string" and sub_map[ident] ~= ident then
				local repl = M.trim(sub_map[ident]) ---@type string
				if repl ~= "" then
					process_token({ tok = repl, rel = bt.rel })
					return
				end
			end
			if ident:sub(1, 4) == "mac_" then
				local bare = ident:sub(5)                 ---@type string
				local comp = ctx_table.components[bare]   ---@type Component|nil
				if comp then
					local invocation_root_call_text = walk_root_call_text or tok ---@type string
					if ctx_table.visiting[bare] then
						-- Cycle: still allocate inv_id, emit zero-width begin/end, record the cycle error; do NOT recurse.
						local inv = emit_invoke_begin(comp.kind or "comp_bare", bare, tok, invocation_root_call_text, def_source, tok_line) ---@type InvocationRecord
						inv.parent_id = walk_parent_inv_id
						inv.call_text = tok
						local err = { ---@type Finding
							kind   = "error",
							check  = "cycle",
							msg    = string.format("project_emission: component cycle detected: %q", bare),
							source = def_source,
							line   = tok_line,
						}
						inv.errors[#inv.errors + 1] = err
						errors    [#errors     + 1] = err
						emit_invoke_end(inv)
						return
					end
					-- First visit: descend + count + count_mismatch-check below.
					ctx_table.visiting[bare] = true
					local inv = emit_invoke_begin(comp.kind or "comp_bare", bare, tok, invocation_root_call_text, def_source, tok_line) ---@type InvocationRecord
					inv.parent_id = walk_parent_inv_id
					inv.call_text = tok
					inv.def_path  = comp.source
					inv.def_line  = comp.line
					-- Propagate trackers into the recursive walk:
					--   immediate_call_text = this call's tok (the IMMEDIATE outer call for words emitted in this body)
					--   root_call_text      = the OUTERMOST call (immutable across the recursion)
					--   child_map           = per-invocation formal substitution; stays on the walk stack
					local formal_names = comp.arg_names ---@type string[]|nil
					local child_map = nil               ---@type table<string, string>|nil
					if formal_names then
						child_map = {}
						for i, fname in ipairs(formal_names) do ---@type integer, string
							child_map[fname] = apply_sub(sub_map, args[i])
						end
					end
					walk_body_entry(comp,
						inv.id,
						invocation_root_call_text,
						tok,
						child_map)
					ctx_table.visiting[bare] = nil
					emit_invoke_end(inv)
					-- Count `word` items inside [start_word, end_word].
					local wc_inside = 0                     ---@type integer
					for i = inv.start_word, inv.end_word do ---@type integer
						local it = items[i] ---@type EmissionItem|nil
						if it and it.kind == "word" then
							wc_inside = wc_inside + 1
						end
					end
					inv.word_count = wc_inside
					-- count_mismatch is a construction error: word_counts["mac_X"] is the declared count populated by the components pass; 
					-- We compare against the measured word count.
					local declared = ctx_table.word_counts["mac_" .. bare] ---@type integer|nil
					if declared and wc_inside ~= declared then
						local err = { ---@type Finding
							kind   = "error",
							check  = "count_mismatch",
							msg    = string.format("project_emission: mac_%s declared=%d measured=%d", bare, declared, wc_inside),
							source = def_source,
							line   = tok_line,
						}
						inv.errors[#inv.errors + 1] = err
						errors    [#errors     + 1] = err
					end
					return
				end
				-- mac_X NOT in components: fall through to opaque emit.
			end
			-- Direct encoder, or mac_X-without-component: resolve count + emit n words.
			-- Resolve_count may emit a warning if the count is unresolved.
			local n         = resolve_count(ident, tok_line)       ---@type integer
			local out_ident = (ident == "nop2") and "nop" or ident ---@type string
			for _ = 1, n do                                        ---@type integer
				emit_word(out_ident, args, tok_line, tok, def_source, def_line, walk_immediate_call_text, walk_root_call_text, sub_map)
			end
		end
		
		for _, bt in ipairs(tokens) do ---@type integer, BodyToken
			process_token(bt)
		end
	end

	-- Initialize the per-walk mutable context.
	-- `visiting` is the active DFS component stack; `root_call_path` / `root_call_line` are preserved across recursion so nested words always point at the
	-- ORIGINAL root atom call site.
	ctx_table.visiting       = ctx_table.visiting        or {}
	ctx_table.root_call_path = ctx_table.root_call_path  or ""
	ctx_table.root_call_line = ctx_table.root_call_line  or 0

	-- Walk first; the pass caller stamps the root call site for direct words after the projection returns.
	-- For nested words the def_path / def_line already point at the component source and MUST be preserved (the stamping helper checks for that).
	walk_body_entry(root_body_entry, 0, nil, nil, nil)

	-- Boundary check: every invoke_begin must have a matching invoke_end.
	-- If anything is still open, surface a hard error.
	if #invocation_stack > 0 then
		errors[#errors + 1] = {
			kind  = "error",
			check = "unbalanced",
			msg   = string.format("project_emission: invocation boundaries not balanced (%d unclosed invocation(s) at end of walk)", #invocation_stack),
		}
	end

	return {
		items       = items,
		word_events = word_events,
		markers     = markers,
		invocations = invocations,
		errors      = errors,
		warnings    = warnings,
	}
end

--- Project a body string into the per-atom emission projection.
---
--- Semantics:
---   * Direct one-word tokens (`nop`, `add_ui`, ...): one `word` item, encoder = ident, word_count = 1.
---   * Metadata-backed N-word tokens (`nop2`, `mask_upper`, ...): N `word` items, all sharing the same encoder + word_count = 1.
---     `nop2` is normalized to encoder `nop` (per the spec).
---   * `atom_label(F)` markers: one `label` item with `name = "F"`, `word_index = current word_idx`; zero-width (does NOT advance word_idx).
---   * `atom_offset(B, T)` nested in a consuming instruction: one `offset` item with `name = "B"`, `target = "T"`, `word_index = current word_idx`; zero-width.
---     A lone top-level `atom_offset` is not emitted.
---   * Delay markers (`GteDelay_` / `LdSlot_` / `BdSlot_` / `DmaSlot_`): one `delay` item; zero-width. The following encoder is the next token.
---   * `mac_X(...)` calls: emit `invoke_begin` (zero-width), recurse into the component body, emit `invoke_end` (zero-width).
---     The component body's words land between the begin/end pair; one invocation record is allocated per call (monotonic ID per atom).
---   * Unknown uncounted macros emit 1 opaque word + one warning per occurrence.
---   * Tokens whose count cannot be resolved (e.g. `mac_unknown` not in word_counts and not in components) surface one
---     warning; cycle + count-mismatch + boundary violations are construction errors on `pass.errors`.
---
--- Every emitted `word` carries: `i` (0-based word index), `encoder`, `args` (top-level args), `def_path`, `def_line`,
--- `call_text` (the immediate token spelling), `root_call_text` (outermost `mac_X(...)` text), `word_count` (always 1),
--- `invocation_ids` (innermost last), `outermost_invocation_id`.
--- Markers carry: `kind`, `name`, `line`, `word_index`, `target` (only for offset kind), plus `invocation_ids` / `outermost_invocation_id`
--- for the open invocation stack at that word.
---
--- @param body_text       string  -- the raw atom body string
--- @param component_index table<string, Component>
--- @param word_counts     WordCounts
--- @param components      table<string, Component>
---                                   `invocation.debug_skip`. A missing or non-table `components` raises a fail-loud error rather than silently falling back.
--- @return EmissionProjection
--- @param reg_use_ctx RegUseCtx|nil
function M.project_emission(body_text, component_index, word_counts, components, reg_use_ctx)
	-- The recursive walk delegates to `_project_emission_inner` so component bodies
	-- (the `corpus.components` row: body_tokens / body_off / line_of / source / line)
	-- re-enter the same walker with the same shared output state.
	--
	-- The walker is body-relative: it builds `line_of` from `body_text` and stamps body-relative line numbers (1..N)
	-- into `item.line` and `invocation.call_line`. `passes/emission_model.lua::stamp_root_provenance` performs the single
	-- conversion from body-relative to physical source line at the close site, using the source's `line_of` closure that
	-- the pass forwarded. One owner of the line state.
	if type(components) ~= "table" then
		error("duffle.project_emission: `components` is required "
			.. "(bare-name -> component definition, e.g. corpus.components); "
			.. "got " .. type(components) .. ". "
			.. "The emission pass MUST forward the corpus registry "
			.. "so the invocation-construction site can stamp `debug_skip` "
			.. "without a second pass, source parse, or parallel lookup.",
			0)
	end

	if type(body_text) ~= "string" or body_text == "" then
		-- Empty body: still return a valid (empty) projection.
		return {
			items       = {},
			word_events = {},
			markers     = {},
			invocations = {},
			errors      = {},
			warnings    = {},
		}
	end

	local tokens = M.tokenize_body(body_text) ---@type BodyToken[]
	local comps  = components or component_index or {} ---@type table<string, Component>
	return _project_emission_inner({
		body_tokens = tokens,
		body_off    = 0,
		line_of     = M.LineIndex(body_text),
		source      = "",
		line        = 0,
	},
	{
		components      = comps,
		word_counts     = word_counts     or {},
		reg_use_schema  = reg_use_ctx and reg_use_ctx.reg_use_schema,
		reg_use_param   = reg_use_ctx and reg_use_ctx.reg_use_param,
		atom_name       = reg_use_ctx and reg_use_ctx.atom_name,
		schema_name     = reg_use_ctx and reg_use_ctx.schema_name,
	})
end

-------------------------------------------------------------------------------
-- find_function_decl_for — backward walk for MipsAtomComp_Proc_ name extraction.
--
-- After the `sym` arg was dropped from MipsAtomComp_Proc_, the component name is derived from the preceding
-- `FI_ Slice_MipsCode ac_X(args)` function declaration. This function walks backward from `before_pos` to find it.
--
-- Returns (raw_name, args_inner) or (nil, nil).
--   raw_name   — e.g. "ac_load_word_imm"
--   args_inner — e.g. "AtomBuilder_R ab, Reg dst, U4 imm"
--
-- The walk finds the LAST "Slice_MipsCode" before before_pos, then skips whitespace + qualifiers
-- (FI_, atom_dbg_skip, comments) until it finds an ident followed by "(".
-- That ident is the function name; the parens contents are the args.
-------------------------------------------------------------------------------
--- @param source string
--- @param before_pos integer
--- @param slice_mips_code_len integer
--- @return string|nil, string|nil
function M.find_function_decl_for(source, before_pos, slice_mips_code_len)
	local search_pos = 1   ---@type integer
	local last_match = nil ---@type integer|nil
	while true do
		local found = source:find("Slice_MipsCode", search_pos, true) ---@type integer|nil
		if not found or found >= before_pos then break end
		last_match = found
		search_pos = found + slice_mips_code_len
	end
	if not last_match then return nil, nil end

	local pos = last_match + slice_mips_code_len ---@type integer
	while pos < before_pos do
		-- skip whitespace
		while pos <= #source do
			local c = source:sub(pos, pos) ---@type string
			if c == " " or c == "\t" or c == "\n" or c == "\r" then
				pos = pos + 1
			else
				break
			end
		end
		if pos > #source then break end
		-- skip line comments
		if source:sub(pos, pos + 1) == "//" then
			while pos <= #source and source:sub(pos, pos) ~= "\n" do pos = pos + 1 end
			pos = pos + 1
			goto continue
		end
		-- skip block comments
		if source:sub(pos, pos + 1) == "/*" then
			local  close = source:find("*/", pos + 2, true) ---@type integer|nil
			if not close then break end
			pos = close + 2
			goto continue
		end
		-- try to read an ident
		local  ident, ident_end = M.read_ident(source, pos) ---@type string|nil, integer
		if not ident then break end
		-- check if the next non-ws char after ident is "("
		local next_pos = M.skip_ws_and_cmt(source, ident_end) ---@type integer
		if source:sub(next_pos, next_pos) == "(" then
			local inner = M.read_parens(source, next_pos) ---@type string|nil
			if inner then
				return ident, inner
			end
		end
		-- ident not followed by "(" — it's a qualifier (FI_, atom_dbg_skip, etc); skip it
		pos = ident_end
		::continue::
	end
	return nil, nil
end

-------------------------------------------------------------------------------
-- find_atom_proc_decl_for — backward walk for MipsAtom_Proc_ name extraction.
--
-- The atom name is the preceding `MipsAtom* ident(args)` function ident.
-- This function walks backward from `before_pos` to find it.
--
-- Returns (raw_name, args_inner, func_ident, after_paren) or (nil, nil).
--   raw_name    — the function ident as written
--   args_inner  — e.g. "AtomArena_R aa, U4 r_scratch, ..."
--   after_paren — source position after the function `)`
--
-- The walk finds the LAST "MipsAtom*" before before_pos, then skips whitespace + qualifiers (internal, I_, FI_, comments)
-- until it finds an ident followed by "(".
-------------------------------------------------------------------------------
--- @param source string
--- @param before_pos integer
--- @param mips_atom_ptr_len integer
--- @return string|nil, string|nil, string|nil, integer|nil
function M.find_atom_proc_decl_for(source, before_pos, mips_atom_ptr_len)
	local search_pos = 1   ---@type integer
	local last_match = nil ---@type integer|nil
	while true do
		-- plain=true: "*" is literal, no escaping needed
		local  found = source:find("MipsAtom*", search_pos, true) ---@type integer|nil
		if not found or found >= before_pos then break end
		last_match = found
		search_pos = found + mips_atom_ptr_len
	end
	if not last_match then return nil, nil end

	local pos = last_match + mips_atom_ptr_len ---@type integer
	while pos < before_pos do
		-- skip whitespace
		while pos <= #source do
			local c = source:sub(pos, pos) ---@type string
			if c == " " or c == "\t" or c == "\n" or c == "\r" then
				pos = pos + 1
			else
				break
			end
		end
		if pos > #source then break end
		-- skip line comments
		if source:sub(pos, pos + 1) == "//" then
			while pos <= #source and source:sub(pos, pos) ~= "\n" do pos = pos + 1 end
			pos = pos + 1
			goto continue
		end
		-- skip block comments
		if source:sub(pos, pos + 1) == "/*" then
			local  close = source:find("*/", pos + 2, true) ---@type integer|nil
			if not close then break end
			pos = close + 2
			goto continue
		end
		-- try to read an ident
		local  ident, ident_end = M.read_ident(source, pos) ---@type string|nil, integer
		if not ident then break end
		-- check if the next non-ws char after ident is "("
		local next_pos = M.skip_ws_and_cmt(source, ident_end) ---@type integer
		if source:sub(next_pos, next_pos) == "(" then
			local inner, after_paren = M.read_parens(source, next_pos) ---@type string|nil, integer
			if inner then
				return ident, inner, ident, after_paren
			end
		end
		-- ident not followed by "(" — it's a qualifier; skip it
		pos = ident_end
		::continue::
	end
	return nil, nil
end

return M

