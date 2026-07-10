-- duffle.lua
--
-- Shared primitives + domain tables for the tape-atom metaprograms.
--
-- 5.3-compatible Lua (no 5.4/5.5-only features):
--   - no <close> / <toclose>
--   - no continue keyword
--   - no string.dump improvements
--   - LuaJIT 5.1+extensions model is the primary target
--
-- No :match / :gmatch regex use anywhere; all delimiter-splitting is
-- hand-rolled or via LPeg (the regex-free PEG library).
--
-- Phase 3: the hot lexer primitives are LPeg-backed where it pays off.
-- The hand-rolled variants remain for callers that need a fallback.

local M = {}

-- ════════════════════════════════════════════════════════════════════════════
-- Section 0: LPeg patterns (compiled once at module load)
-- ════════════════════════════════════════════════════════════════════════════
--
-- LPeg is a PEG library (no regex). All patterns below are first-class
-- pattern values; they're cheap to build and reuse.
--
-- Note: lpeg is required lazily because Lua 5.5 may not have it on its
-- cpath at the same location as LuaJIT. We attempt the require and fall
-- back to the hand-rolled implementations if it fails.

local lpeg_ok, lpeg = pcall(require, "lpeg")
local lpeg_lib = nil
local lpeg_alpha_pat, lpeg_alnum_pat, lpeg_ident_pat
local lpeg_str_or_cmt_pat, lpeg_ws_and_cmt_pat
local lpeg_scan_to_target_pat  -- generic "anything but target or balanced group" matcher

if lpeg_ok then
    lpeg_lib = lpeg
    local P, S, R = lpeg.P, lpeg.S, lpeg.R

    -- Character class patterns
    local alpha_pat = R("AZ", "az") + P("_")
    local digit_pat = R("09")
    lpeg_alnum_pat = alpha_pat + digit_pat

    -- Identifier: alpha followed by zero+ alnum. Capture as a string.
    lpeg_alpha_pat = alpha_pat
    lpeg_ident_pat = lpeg.C(alpha_pat * lpeg_alnum_pat^0)

    -- String literal: "..." with backslash escapes.
    local lpeg_str_pat = P('"') * (P(1) - S('"\\') + P('\\') * P(1))^0 * P('"')
    -- Char literal: '...' with backslash escapes.
    local lpeg_chr_pat = P("'") * (P(1) - S("'\\") + P('\\') * P(1))^0 * P("'")
    -- Line comment: // ... to end-of-line.
    local lpeg_line_cmt_pat = P("//") * (P(1) - S("\n"))^0
    -- Block comment: /* ... */ (no nesting per C standard).
    local lpeg_block_cmt_pat = P("/*") * (P(1) - P("*/"))^0 * P("*/")
    -- String or comment (any of the four forms).
    lpeg_str_or_cmt_pat = lpeg_str_pat + lpeg_chr_pat + lpeg_line_cmt_pat + lpeg_block_cmt_pat

    -- Whitespace + comment skipper: zero+ (whitespace run | string | comment).
    local ws_pat = S(" \t\n\r\v\f")
    lpeg_ws_and_cmt_pat = (ws_pat + lpeg_str_or_cmt_pat)^0

    -- Generic "skip until target, but step over balanced groups" matcher.
    -- Used by scan_to_char for non-ident / non-bracket chars.
    -- We accept any single char except the target.
    -- The balanced-group stepping is handled by the caller (via read_balanced).
    lpeg_scan_to_target_pat = function(target)
        return (P(1) - P(target))^0
    end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Section 1: character classification (byte-based for hot loops)
-- ════════════════════════════════════════════════════════════════════════════
--
-- Two APIs:
--   is_space(c), is_alpha(c), etc. — accept a single-char STRING (legacy)
--   is_space_byte(b), is_alpha_byte(b), etc. — accept a single-byte INTEGER
--
-- The byte-based versions are 5-10x faster in tight loops because they
-- avoid the string allocation per s:sub(i, i) call.

-- Whitespace characters per C locale.
function M.is_space_byte(b)
    return b == 32  or b == 9 or b == 10 or b == 13 or b == 11 or b == 12
end

-- Letters (a-z, A-Z) and underscore.
function M.is_alpha_byte(b)
    if not b then return false end
    if b >= 97 and b <= 122 then return true  end  -- 'a'..'z'
    if b >= 65 and b <= 90  then return true  end  -- 'A'..'Z'
    return b == 95                                    -- '_'
end

-- Single digit.
function M.is_digit_byte(b) return b and b >= 48 and b <= 57 end

-- Letter OR digit OR underscore.
function M.is_alnum_byte(b) return M.is_alpha_byte(b) or M.is_digit_byte(b) end

-- String-based wrappers (kept for callers that already have a single-char
-- string; the byte versions are what the hot loops should call).
function M.is_space(c)
    if type(c) == "number" then return M.is_space_byte(c) end
    return c == " "  or c == "\t" or c == "\n" or c == "\r" or c == "\v" or c == "\f"
end
function M.is_alpha(c)
    if type(c) == "number" then return M.is_alpha_byte(c) end
    if not c or #c == 0 then return false end
    if c >= "a" and c <= "z" then return true  end
    if c >= "A" and c <= "Z" then return true  end
    return c == "_"
end
function M.is_digit(c)
    if type(c) == "number" then return M.is_digit_byte(c) end
    return c and c >= "0" and c <= "9"
end
function M.is_alnum(c) return M.is_alpha(c) or M.is_digit(c) end

-- ════════════════════════════════════════════════════════════════════════════
-- Section 2: string primitives
-- ════════════════════════════════════════════════════════════════════════════

-- Trim leading and trailing whitespace from a string.
function M.trim(s)
    local a = 1
    while a <= #s and M.is_space_byte(s:byte(a)) do a = a + 1 end
    local b = #s
    while b >= a and M.is_space_byte(s:byte(b)) do b = b - 1 end
    return s:sub(a, b)
end

-- Linear-search for a single-byte target in a string.
-- (Phase 3 retained this for places where LPeg is overkill.)
function M.find_byte(haystack, target, start)
    for i = start or 1, #haystack do
        if haystack:byte(i) == target then return i end
    end
    return nil
end

-- Returns the directory portion of a path.
function M.dirname(path)
    local last_sep = 0
    for i = 1, #path do
        if path:byte(i) == 47 or path:byte(i) == 92 then last_sep = i end  -- '/' or '\\'
    end
    if last_sep == 0 then return "." end
    return path:sub(1, last_sep - 1)
end

-- Returns the basename of a path, with the file extension stripped.
function M.basename_no_ext(path)
    local last_sep = 0
    for i = 1, #path do
        if path:byte(i) == 47 or path:byte(i) == 92 then last_sep = i end
    end
    local a = last_sep + 1
    local last_dot = #path + 1
    for i = #path, a, -1 do
        if path:byte(i) == 46 then last_dot = i; break end  -- '.'
    end
    return path:sub(a, last_dot - 1)
end

-- ════════════════════════════════════════════════════════════════════════════
-- Section 3: I/O primitives
-- ════════════════════════════════════════════════════════════════════════════

function M.read_file(path)
    local f = io.open(path, "r")
    if not f then error("Cannot open " .. path) end
    local content = f:read("*a")
    f:close()
    return content
end

function M.write_file(path, content)
    local f = io.open(path, "w")
    if not f then error("Cannot write " .. path) end
    f:write(content)
    f:close()
end

-- Cache of directories already verified to exist in this process. Each
-- ensure_dir() call may otherwise spawn a `cmd.exe mkdir` (50-100ms
-- per call on Windows) — calling it inside per-source loops added 1.5+
-- seconds to the report pass. Cache makes ensure_dir idempotent within
-- the process lifetime (safe across passes; the dir state doesn't change).
local _ensured_dirs = {}

function M.ensure_dir(path)
    if _ensured_dirs[path] then return end
    _ensured_dirs[path] = true
    local is_win = package.config:sub(1, 1) == "\\"
    os.execute(is_win and ('if not exist "' .. path .. '" mkdir "' .. path .. '"')
                  or ('mkdir -p "' .. path .. '" 2>/dev/null'))
end

-- Test helper: clear the cache (used by tests + between process runs).
-- Not normally needed since Lua state is per-process.
function M._reset_ensured_dirs() _ensured_dirs = {} end

-- ════════════════════════════════════════════════════════════════════════════
-- Section 4: C-language scanner primitives
-- ════════════════════════════════════════════════════════════════════════════

-- LPeg-backed skipper when LPeg is available, hand-rolled fallback otherwise.
-- Returns position just past the construct, or `i` unchanged if no
-- string/comment starts at position i.
function M.skip_str_or_cmt(s, i)
    if lpeg_ok then
        local new_pos = lpeg.match(lpeg_str_or_cmt_pat, s, i)
        if new_pos then return new_pos end
        return i
    end
    -- Hand-rolled fallback (kept for builds where LPeg isn't available).
    local c = s:byte(i)
    if c == 34 or c == 39 then  -- '"' or '\''
        i = i + 1
        while i <= #s do
            local b = s:byte(i)
            if b == 92 then i = i + 2  -- '\\'
            elseif b == c then return i + 1
            else i = i + 1 end
        end
        return #s + 1
    elseif c == 47 then  -- '/'
        local nx = s:byte(i + 1)
        if nx == 47 then  -- '//'
            while i <= #s and s:byte(i) ~= 10 do i = i + 1 end
            return i
        elseif nx == 42 then  -- '/*'
            i = i + 2
            while i <= #s - 1 do
                if s:byte(i) == 42 and s:byte(i + 1) == 47 then  -- '*/'
                    return i + 2
                end
                i = i + 1
            end
            return #s + 1
        end
    end
    return i
end

-- Skip whitespace AND C-style comments starting at position i.
-- LPeg-backed when available; ~5-10x faster than the hand-rolled version.
function M.skip_ws_and_cmt(s, i)
    if lpeg_ok then
        local new_pos = lpeg.match(lpeg_ws_and_cmt_pat, s, i)
        if new_pos then return new_pos end
        return i
    end
    -- Hand-rolled fallback.
    local len = #s
    while i <= len do
        if M.is_space_byte(s:byte(i)) then
            i = i + 1
        else
            local nx = M.skip_str_or_cmt(s, i)
            if nx > i then i = nx else break end
        end
    end
    return i
end

-- Read a C-style identifier (alpha followed by zero+ alnum) starting at
-- position i. Returns the identifier string + the position just past it,
-- or nil + i if no identifier starts here.
function M.read_ident(s, i)
    if lpeg_ok then
        local result = lpeg.match(lpeg_ident_pat, s, i)
        if result then return result, i + #result end
        return nil, i
    end
    -- Hand-rolled fallback.
    if not M.is_alpha_byte(s:byte(i)) then return nil, i end
    local a = i
    i = i + 1
    while i <= #s and M.is_alnum_byte(s:byte(i)) do i = i + 1 end
    return s:sub(a, i - 1), i
end

-- Read a balanced-delimited group (parens, braces, or brackets) starting
-- at position i. Returns the inner content (between the delimiters) +
-- the position just past the closing delimiter, or nil + i if `s[i]`
-- isn't `open_char`.
--
-- (Hand-rolled; the depth counting makes pure LPeg awkward here.)
function M.read_balanced(s, open_char, close_char, i)
    local open_byte = open_char:byte()
    if s:byte(i) ~= open_byte then return nil, i end
    i = i + 1
    local len   = #s
    local depth = 1
    local a     = i
    while i <= len and depth > 0 do
        local c = s:byte(i)
        if c == open_byte then
            depth = depth + 1
            i = i + 1
        elseif c == close_char:byte() then
            depth = depth - 1
            if depth == 0 then break end
            i = i + 1
        else
            local nx = M.skip_str_or_cmt(s, i)
            if nx > i then i = nx else i = i + 1 end
        end
    end
    return s:sub(a, i - 1), i + 1
end

-- Convenience specializations of read_balanced.
M.read_parens   = function(s, i) return M.read_balanced(s, "(", ")", i) end
M.read_braces   = function(s, i) return M.read_balanced(s, "{", "}", i) end
M.read_brackets = function(s, i) return M.read_balanced(s, "[", "]", i) end

-- Scan forward from position `start` until we find a specific single byte
-- `target`, transparently stepping over balanced parens/braces/brackets.
-- Returns the position of `target`, or nil if not found.
function M.scan_to_char(s, target, start)
    local target_byte = target:byte()
    local i = start
    while i <= #s do
        local c = s:byte(i)
        if c == target_byte then return i end
        if c == 40 then local _, a = M.read_balanced(s, "(", ")", i); i = a  -- '('
        elseif c == 123 then local _, a = M.read_balanced(s, "{", "}", i); i = a  -- '{'
        elseif c == 91 then local _, a = M.read_balanced(s, "[", "]", i); i = a  -- '['
        else
            local nx = M.skip_str_or_cmt(s, i)
            if nx > i then i = nx else i = i + 1 end
        end
    end
    return nil
end

-- Split a brace-body into top-level comma-separated tokens. Honors nested
-- parens/braces/brackets and skips strings/comments.
--
-- FIX (2026-07-09): split at top-level NEWLINES and SEMICOLONS too, AND
-- emit a token break after a top-level comment/string. Previous behavior
-- glued the macro call after a comment into the same token, so
-- `word_count_of_token` only saw the leading ident (often nil after
-- stripping the comment), undercounting the body. See Phase 1 of the
-- branch-offset regression investigation. Pure-comment / pure-string
-- chunks (which now appear between real statements) are filtered out so
-- they contribute 0 words instead of 1.
function M.split_top_level_commas(body)
    local tokens = {}
    local i = 1
    local len = #body
    local token_start = 1

    -- True iff `chunk` contains any non-whitespace, non-comment, non-string
    -- content (i.e., real token material). Walks through ws + comments
    -- individually so a chunk like "  /* trailing */ shift_lleft(...)"
    -- is correctly classified as having real content (the macro call).
    local function has_real_content(chunk)
        local k = 1
        local klen = #chunk
        while k <= klen do
            if M.is_space(chunk:sub(k, k)) then
                k = k + 1
            else
                local nx = M.skip_str_or_cmt(chunk, k)
                if nx > k then
                    k = nx  -- skipped a comment or string
                else
                    return true  -- found real content
                end
            end
        end
        return false
    end

    local function emit(end_pos)
        if end_pos >= token_start then
            local chunk = body:sub(token_start, end_pos)
            if M.trim(chunk) ~= "" then
                if has_real_content(chunk) then
                    tokens[#tokens + 1] = chunk
                elseif #tokens > 0 then
                    -- Pure comment/string chunk at top level (no
                    -- preceding instruction content within this chunk).
                    -- APPEND it to the LAST token so emit-context
                    -- callers (components.lua build_component_lines)
                    -- can convert `// trailing comment` to `/* */`
                    -- and emit it with the macro body. For word
                    -- counting, count_token_words only inspects the
                    -- leading ident, so a trailing comment doesn't
                    -- affect the count.
                    --
                    -- This is the second-half fix to commit 98e27c2:
                    -- the first fix correctly broke top-level comments
                    -- off from the NEXT statement (fixing macro-call
                    -- word counts); this fix preserves them on the
                    -- PREVIOUS statement (restoring the comments in
                    -- the emitted .macs.h output).
                    tokens[#tokens] = tokens[#tokens] .. chunk
                end
            end
            token_start = end_pos + 1
        end
    end

    while i <= len do
        local c = body:byte(i)
        if c == 40 then                              -- '('
            local _, a = M.read_parens(body, i); i = a
        elseif c == 123 then                          -- '{'
            local _, a = M.read_braces(body, i); i = a
        elseif c == 91 then                           -- '['
            local _, a = M.read_brackets(body, i); i = a
        elseif c == 44 then                           -- ','
            emit(i - 1)
            i = i + 1
            token_start = i
        elseif c == 59 then                           -- ';'
            emit(i - 1)
            i = i + 1
            token_start = i
        elseif c == 10 then                           -- '\n'
            emit(i - 1)
            i = i + 1
            token_start = i
        else
            local nx = M.skip_str_or_cmt(body, i)
            if nx > i then
                -- Skipped a comment or string at top level: emit token break.
                i = nx
                emit(i - 1)
            else
                i = i + 1
            end
        end
    end
    emit(len)
    return tokens
end

-- ════════════════════════════════════════════════════════════════════════════
-- Section 5: load_word_counts
-- ════════════════════════════════════════════════════════════════════════════

function M.load_word_counts(metadata_path)
    local counts  = {}
    local content = M.read_file(metadata_path)
    local len     = #content
    local i       = 1
    local prefix  = "WORD_COUNT("
    while i <= len do
        local nl       = M.find_byte(content, 10, i)  -- '\n'
        local line_end = nl or (len + 1)
        local line     = content:sub(i, line_end - 1)
        local trimmed  = M.trim(line)
        if trimmed:sub(1, #prefix) == prefix and trimmed:sub(-1) == ")" then
            local inner = trimmed:sub(#prefix + 1, #trimmed - 1)
            local comma = M.find_byte(inner, 44, 1)  -- ','
            if comma then
                counts[M.trim(inner:sub(1, comma - 1))] =
                    tonumber(M.trim(inner:sub(comma + 1)))
            end
        end
        i = line_end + 1
    end
    return counts
end

-- ════════════════════════════════════════════════════════════════════════════
-- Section 6: LineIndex (perf fix — replaces the per-call rescan line_of)
-- ════════════════════════════════════════════════════════════════════════════

function M.LineIndex(source)
    local positions = {}
    local n = 0
    for i = 1, #source do
        if source:byte(i) == 10 then  -- '\n'
            n = n + 1
            positions[n] = i
        end
    end
    local function line_of(pos)
        local lo, hi = 1, n
        while lo <= hi do
            local mid = math.floor((lo + hi) / 2)
            if positions[mid] <= pos then
                lo = mid + 1
            else
                hi = mid - 1
            end
        end
        return hi + 1
    end
    return line_of
end

-- ════════════════════════════════════════════════════════════════════════════
-- Section 7: domain tables
-- ════════════════════════════════════════════════════════════════════════════

M.WAVE_CONTEXT_REGS = {
    ["R_PrimCursor"] = { alias = "R_T7", size = 4, role = "output cursor (prim arena)" },
    ["R_FaceCursor"] = { alias = "R_T4", size = 4, role = "input cursor (face array)" },
    ["R_VertBase"]   = { alias = "R_T5", size = 4, role = "base pointer (vertex array)" },
    ["R_OtBase"]     = { alias = "R_T6", size = 4, role = "base pointer (ordering table)" },
}

-- The annotation DSL has been reduced to a single annotation macro:
--   atom_info(atom_bind(Binds_X), atom_reads(...), atom_writes(...))
-- All phase / region / cadence / async / resource / group tokens have
-- been dropped. They may be reintroduced later as optional sub-calls
-- of atom_info; for now, the parser only recognizes atom_info + its
-- three sub-calls (atom_bind, atom_reads, atom_writes).
M.TAPE_ATOM_MACROS = {
    ["atom_info"] = { kind = "info", binds = false },
}

-- GTE pipeline-fill latency table (static-analysis Phase 1).
--
-- For each `gte_cmdw_*` macro in code/duffle/gte.h, the minimum number
-- of consecutive COP2 "nop" words that MUST appear before any other
-- COP2 read or non-nop instruction (so the GTE pipeline latency is
-- fully retired).  Latencies are sourced from the doxygen comments
-- in gte.h (e.g. `* @brief Rotate, Translate and Perspective Triple
-- (23 cycles)` with body `Two nop words fill the COP2 pipeline
-- latency`).
--
-- The check (`scripts/passes/static_analysis.lua ::
-- check_gte_pipeline_fill`) walks each atom body, counts the
-- consecutive nop words after every `gte_cmdw_*` invocation, and
-- reports a finding if the count is below this minimum.  Aliases
-- are dereferenced before lookup (gté_cmdw_rtps_alias ->
-- gte_cmdw_rtps -> 2).
--
-- Values verified against PSX-SPX gte.txt (rtpt 23cy / 8cy per divide
-- => 2 nops; nclip 8cy => 2 nops; avsz3/avsz4 14cy => 2 nops; op
-- single-cycle atomic => 0 nops; mvmva 8cy matrix-vector => 2 nops).
M.GTE_PIPELINE_LATENCY = {
    -- Minimum number of consecutive `nop` words that must appear
    -- IMMEDIATELY BEFORE a `gte_cmdw_<X>` invocation -- to retire
    -- any preceding `lwc2` / `swc2` / pre-existing C2 state writes
    -- before the GTE pipeline starts reading from V0/V1/V2 or
    -- MAC0..3 / OTZ / IR0..3 at the command's issue cycle.
    --
    -- Values are from the doxygen comments in code/duffle/gte.h and
    -- cross-checked against PSX-SPX `geometrytransformationenginegte.md`:
    --
    --   cmd      cycles  min pre-nops  rationale
    --   rtps        14      2         8c per perspective divide + 6c for IR1..4 + mac write
    --   rptt        22      2         3x rtps worth of pipeline depth
    --   nclip        7      2         MAC0 write + 5c for sign
    --   avsz3       14      2         14c to compute average + write OTZ
    --   avsz4       16      2         avsz3 + 2c extra for avg over 4
    --   mvmva        8      2         IR1..4 write + matrix work
    --   op          5      0         output to MAC0 only (atomic 5c calc)
    --
    -- The `gte_rtpt()` / `gte_nclip()` / `gte_avsz3()` wrapper macros in
    -- gte.h emit the pre-cmd nops internally (asm_words(nop, nop, ...)),
    -- but THOSE WRAPPERS ARE NOT USED INSIDE ATOM BODIES in this
    -- codebase. Every MipsAtom_(name) body uses raw `nop2,
    -- gte_cmdw_<X>, ...` form instead -- that `nop2,` is the pre-fill
    -- this check validates. So values here must reflect the source-level
    -- convention, NOT the wrapper-internal pre-fill (which is invisible
    -- at the source level).
    --
    -- Existing clean-atom bodies (cube_g4_face, floor_f3_face,
    -- diag_gte) all emit `nop2,` before every `gte_cmdw_<X>` (which
    -- matches values >= 2). The check passes them all.
    --
    -- Aliases are listed separately because source code may use either
    -- the alias or the canonical name. The check looks up the EXACT
    -- macro text, so both forms must be in the table.

    -- Canonical macros (from code/duffle/gte.h)
    ["gte_cmdw_rtps"]   = 2,
    ["gte_cmdw_rtpt"]   = 2,
    ["gte_cmdw_nclip"]  = 2,
    ["gte_cmdw_op"]     = 0,
    ["gte_cmdw_mvmva"]  = 2,
    ["gte_cmdw_avsz3"]  = 2,
    ["gte_cmdw_avsz4"]  = 2,

    -- Aliases (must have the same value as their canonical target)
    ["gte_cmdw_rotate_translate_perspective_single"] = 2,
    ["gte_cmdw_rotate_translate_perspective_triple"] = 2,
    ["gte_cmdw_avg_sort_z4"]                          = 2,

    -- Outer product aliases (same canonical op, 0 pre-fill nops).
    -- gte_cmdw_op          = canonical GTE-internal short form
    -- gte_cmdw_outer_product = NOCASH / SDK-readable form
    -- gte_cmdw_wedge         = geometric-algebra (exterior-product) form
    ["gte_cmdw_outer_product"] = 0,
    ["gte_cmdw_wedge"]        = 0,
}

-- GP0 packet sizes (total words including the 1-word tag) per GP0 cmd byte.
-- Verified against code/duffle/gp.h struct sizes + the set_poly_* macros
-- (which encode "len" = "words after tag"):
--   set_poly_f3(p)   -> set_len(p, 4)   -> 5 total  GP0 0x20
--   set_poly_ft3(p)  -> set_len(p, 7)   -> 8 total  GP0 0x24
--   set_poly_f4(p)   -> set_len(p, 5)   -> 6 total  GP0 0x28
--   set_poly_ft4(p)  -> set_len(p, 9)   -> 10 total GP0 0x2C
--   set_poly_g3(p)   -> set_len(p, 6)   -> 7 total  GP0 0x30
--   set_poly_gt3(p)  -> set_len(p, 9)   -> 10 total GP0 0x34
--   set_poly_g4(p)   -> set_len(p, 8)   -> 9 total  GP0 0x38
--   set_poly_gt4(p)  -> set_len(p, 12)  -> 13 total GP0 0x3C
M.GP0_CMD_SIZE = {
    [0x20] =  5,  -- Poly_F3
    [0x24] =  8,  -- Poly_FT3
    [0x28] =  6,  -- Poly_F4
    [0x2C] = 10,  -- Poly_FT4
    [0x30] =  7,  -- Poly_G3
    [0x34] = 10,  -- Poly_GT3
    [0x38] =  9,  -- Poly_G4
    [0x3C] = 13,  -- Poly_GT4
}

-- Shape suffix (after `ac_format_` / `mac_format_` prefix) -> GP0 cmd byte.
-- Lets the static-analysis check derive the cmd byte from a macro name
-- like `mac_format_g4_color` -> `g4` -> 0x38 -> 9 expected words.
M.GP0_CMD_BY_SHAPE = {
    ["f3"]  = 0x20, ["ft3"] = 0x24,
    ["f4"]  = 0x28, ["ft4"] = 0x2C,
    ["g3"]  = 0x30, ["gt3"] = 0x34,
    ["g4"]  = 0x38, ["gt4"] = 0x3C,
}

-- Per-macro prim-buffer contribution (NOT .text instruction count --
-- this is "how many 32-bit words does this macro write to the primitive
-- being built in main RAM"). Sum across `mac_format_X_color` +
-- `mac_gte_store_X_post_*` + `mac_insert_ot_tag_X` calls in an atom body
-- must equal GP0_CMD_SIZE[GP0_CMD_BY_SHAPE[shape]].
M.GP0_MACRO_CONTRIB = {
    ["mac_format_f3_color"]                         = 1,
    ["mac_format_g3_color"]                         = 3,
    ["mac_format_g4_color"]                         = 4,
    ["mac_gte_store_f3_post_rtpt"]                  = 3,
    ["mac_gte_store_g3_post_rtpt"]                  = 3,
    ["mac_gte_store_g4_p012_post_rtpt_pre_rtps"]    = 3,
    ["mac_gte_store_g4_p3_post_rtps"]               = 1,
    ["mac_insert_ot_tag_f3"]                        = 1,
    ["mac_insert_ot_tag_g4"]                        = 1,
}

-- Per-macro cycle cost (best-case, no stalls). Used by the static-analysis
-- `count_atom_cycles` pass (Phase 3) to emit per-atom cycle budgets. The
-- counts cover the EXPANDED instruction sequence the macro emits (NOT just
-- the token it appears as in source). For example:
--
--   mac_pack_color_word(off, cmd, r, g, b) emits:
--     load_upper_i(R_AT, (cmd << 8) | b)        -- 1 cycle
--     or_i_self(R_AT, (g << 8) | r)             -- 1 cycle
--     store_word(R_AT, R_PrimCursor, off)       -- 1 cycle
--                                              = 3 cycles total
--
--   mac_yield emits a control-transfer sequence (load_word, add_ui_self,
--   jump_reg, nop) which "yields control" -- the atom body's cycle budget
--   doesn't include the yield's cost (we model it as 0; runtime cost
--   becomes part of the NEXT atom's prologue).
--
-- GTE command values are the GTE instruction's intrinsic cycles (the
-- latency AFTER any pre-cmd `nop2` has retired). When the source emits
-- `nop2, gte_cmdw_X` the nops' cycles are added separately (1+1) plus
-- the gte_cmdw_X value here:
--   rtpt = 21 + 2 nops = 23 total cycles  (matches PSX-SPX)
--   rtps = 12 + 2 nops = 14 total
--   nclip = 6 + 2 nops = 8 total
--   avsz3 = 12 + 2 nops = 14 total
--   avsz4 = 14 + 2 nops = 16 total
--   mvmva = 6 + 2 nops = 8 total
--   op    = 5 (no pre-cmd nops required; single-cycle atomic)
M.INSTRUCTION_LATENCY = {
    -- CPU ALU (single-cycle R3000A ops)
    ["nop"]                 = 1,
    ["nop2"]                = 2,
    ["add_ui"]              = 1,  ["add_ui_self"]       = 1,
    ["add_s"]               = 1,  ["add_si"]            = 1,
    ["add_u"]               = 1,  ["add_u_self"]        = 1,
    ["sub_u"]               = 1,  ["sub_s"]             = 1,
    ["and_i"]               = 1,  ["and_u"]             = 1,
    ["or_i"]                = 1,  ["or_i_self"]         = 1,
    ["or_u"]                = 1,  ["or_u_self"]         = 1,
    ["xor_i"]               = 1,  ["xor_u"]             = 1,
    ["nor_u"]               = 1,
    ["shift_lleft"]         = 1,  ["shift_lleft_self"]  = 1,
    ["shift_lright"]        = 1,
    ["shift_aright"]        = 1,
    ["mask_upper"]          = 1,
    ["mov_from_high"]       = 2,  -- mfhi: 2 cycles
    ["mov_from_low"]        = 2,  -- mflo: 2 cycles
    ["mov_to_high"]         = 1,  -- mthi: 1 cycle
    ["mov_to_low"]          = 1,  -- mtlo: 1 cycle
    -- Set-on-condition (SLT family)
    ["set_lt_u"]            = 1,  ["set_lt_ui"]   = 1,
    ["set_lt_s"]            = 1,  ["set_lt_si"]   = 1,
    -- Multiply / divide (no hardware multiplier; software via inline asm)
    ["mult_u"]              = 12, ["mult_s"]              = 12,
    ["div_u"]               = 35, ["div_s"]               = 35,
    -- Loads (1 cycle + load-delay slot; the delay is typically absorbed by
    -- the next instruction in a well-pipelined sequence, so we count 1)
    ["load_word"]           = 1,
    ["load_half_u"]         = 1,  ["load_half"]           = 1,
    ["load_byte_u"]         = 1,  ["load_byte"]           = 1,
    ["load_upper_i"]        = 1,
    -- 2-word loads (lui + ori) used for >16-bit immediates
    ["load_imm"]            = 2,
    ["load_imm_1w"]         = 1,
    ["load_imm_1w_s0"]      = 1,
    ["load_imm_2w"]         = 2,
    ["load_imm_2w_addi_forced"] = 2,
    ["load_imm_2w_ori_forced"]  = 2,
    -- Stores (1 cycle each)
    ["store_word"]          = 1,
    ["store_half"]          = 1,
    ["store_byte"]          = 1,
    -- Branches (branch + BD slot nop = 2 cycles; the BD slot's nop is
    -- counted as part of the branch's cost)
    ["branch_equal"]        = 2,  ["branch_ne"]          = 2,
    ["branch_le_zero"]      = 2,  ["branch_lt_zero"]     = 2,
    ["branch_ge_zero"]      = 2,  ["branch_gt_zero"]     = 2,
    -- Jumps (jump + BD slot nop = 2 cycles)
    ["jump"]                = 2,  ["jump_reg"]           = 2,
    ["jump_link"]           = 2,  ["call_reg"]           = 2,
    ["call_addr"]           = 2,
    -- COP2 transfers (mtc2/mfc2/ctc2/cfc2 = 1 cycle + COP2 latency; the
    -- COP2 latency is usually absorbed by subsequent nops or by the next
    -- GTE command's pre-fill nops, so we count 1)
    ["gte_mv_to_data_r"]    = 1,
    ["gte_mv_from_data_r"]  = 1,
    ["gte_mv_to_ctrl_r"]    = 1,
    ["gte_mv_from_ctrl_r"]  = 1,
    ["gte_lw"]              = 1,  ["gte_lwc2"]           = 1,
    ["gte_sw"]              = 1,  ["gte_swc2"]           = 1,
    -- COP2 commands (intrinsic cycles, EXCLUDING the 2 pre-cmd nops that
    -- the source typically emits as `nop2, gte_cmdw_X`; those nops are
    -- counted separately via the `nop2` entry above)
    ["gte_cmdw_rtpt"]       = 21,
    ["gte_cmdw_rtps"]       = 12,
    ["gte_cmdw_nclip"]      = 6,
    ["gte_cmdw_avsz3"]      = 12,
    ["gte_cmdw_avsz4"]      = 14,
    ["gte_cmdw_mvmva"]      = 6,
    ["gte_cmdw_op"]         = 5,
    ["gte_cmdw_outer_product"] = 5,
    ["gte_cmdw_wedge"]      = 5,
    -- Long-form aliases (same cost as canonical)
    ["gte_cmdw_rotate_translate_perspective_single"] = 12,  -- alias for rtps
    ["gte_cmdw_rotate_translate_perspective_triple"] = 21,  -- alias for rtpt
    ["gte_cmdw_avg_sort_z4"]                          = 14,  -- alias for avsz4
    -- Non-cmdw aliases from gte.h (these are `#define gte_X gte_cmdw_Y`):
    ["gte_avg_sort_z3"]                               = 12,  -- alias for avsz3
    ["gte_avg_sort_z4"]                               = 14,  -- alias for avsz4
    ["gte_rtps"]                                      = 12,  -- alias for rtps
    ["gte_rtpt"]                                      = 21,  -- alias for rtpt
    ["gte_nclip"]                                     = 6,   -- alias for nclip
    ["gte_avsz3"]                                     = 12,
    ["gte_avsz4"]                                     = 14,
    -- Legacy single-cycle store helpers (gte_stotz, gte_stsxy3 are 1 cycle)
    ["gte_stotz"]           = 1,
    ["gte_stsxy3"]          = 1,
    -- High-level GTE helpers (gte_load_v0/v1/v2 do multiple lwc2s)
    ["gte_load_v0"]         = 2,  -- 1 lwc2 for VXY0 + 1 for VZ0
    ["gte_load_v1"]         = 2,
    ["gte_load_v2"]         = 2,
    ["gte_load_v0v1v2"]     = 6,
    -- mac_* helpers (cycle cost = sum of the expanded instructions)
    -- mac_yield transfers control; cycle budget is 0 (the next atom
    -- absorbs the cost).
    ["mac_yield"]           = 0,
    ["mac_pack_color_word"] = 3,  -- lui + ori + sw
    ["mac_format_f3_color"] = 3,  -- = mac_pack_color_word
    ["mac_format_g4_color"] = 12, -- 4 x mac_pack_color_word
    ["mac_load_tri_indices"] = 3, -- 3 x lhu
    ["mac_gte_load_tri_verts"] = 18, -- 3 x {sll, addu, lw, lw, mtc2, mtc2}
    ["mac_gte_store_f3_post_rtpt"] = 3,
    ["mac_gte_store_g3_post_rtpt"] = 3,
    ["mac_gte_store_g4_p012_post_rtpt_pre_rtps"] = 3,
    ["mac_gte_store_g4_p3_post_rtps"] = 1,
    ["mac_insert_ot_tag_f3"] = 11,  -- 11 .word slots in the macro body
    ["mac_insert_ot_tag_g4"] = 11,
    -- Annotation markers (emit no code; pure metaprogram hints)
    ["atom_label"]          = 0,
    ["atom_offset"]         = 0,
    ["atom_info"]           = 0,
    ["atom_bind"]           = 0,
    ["atom_reads"]          = 0,
    ["atom_writes"]         = 0,
}

-- Default cycle cost for unknown macros. The static-analysis pass adds 1
-- cycle per unknown token and emits a "new macro; update INSTRUCTION_LATENCY"
-- advisory so the cycle budget stays accurate as the codebase grows.
M.UNKNOWN_INSTRUCTION_CYCLES = 1

-- Expose the lpeg_ok flag so callers can detect the LPeg-back path.
-- True when LPeg was successfully required and the patterns above were
-- compiled at module load time. False when running in fallback mode.
M.lpeg_ok = lpeg_ok

return M
