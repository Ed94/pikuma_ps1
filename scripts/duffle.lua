-- duffle.lua
--
-- Shared primitives + domain tables for the tape-atom metaprograms.
-- Both `tape_atom_annotation_pass.lua` and `tape_atom.offset_gen.meta.lua`
-- `require("duffle")` for these.
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

function M.ensure_dir(path)
    local is_win = package.config:sub(1, 1) == "\\"
    os.execute(is_win and ('if not exist "' .. path .. '" mkdir "' .. path .. '"')
                  or ('mkdir -p "' .. path .. '" 2>/dev/null'))
end

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
function M.split_top_level_commas(body)
    local tokens = {}
    local i = 1
    local token_start = 1
    while i <= #body do
        local c = body:byte(i)
        if c == 40 then local _, a = M.read_parens(body, i); i = a    -- '('
        elseif c == 123 then local _, a = M.read_braces(body, i); i = a  -- '{'
        elseif c == 91 then local _, a = M.read_brackets(body, i); i = a  -- '['
        elseif c == 44 then  -- ','
            tokens[#tokens + 1] = body:sub(token_start, i - 1)
            i = i + 1
            token_start = i
        else
            local nx = M.skip_str_or_cmt(body, i)
            if nx > i then i = nx; token_start = nx else i = i + 1 end
        end
    end
    local last = body:sub(token_start)
    if M.trim(last) ~= "" then tokens[#tokens + 1] = last end
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

M.MACRO_EXPANSION = {
    ["phase_init"]      = "init",
    ["phase_bind"]      = "bind",
    ["phase_setup"]     = "setup",
    ["phase_work"]      = "work",
    ["phase_commit"]    = "commit",
    ["phase_terminate"] = "terminate",
    ["REGION_PRIM_ARENA"]   = "prim_arena",
    ["REGION_FACE_ARENA"]   = "face_arena",
    ["REGION_VERTEX_ARENA"] = "vertex_arena",
    ["REGION_OT_ARENA"]     = "ot_arena",
    ["REGION_HEAP_3D"]      = "heap_3d_models",
    ["REGION_CDROM_STREAM"] = "cdrom_stream",
    ["REGION_VRAM"]         = "vram_heap",
    ["CADENCE_FRAME"]       = "frame",
    ["CADENCE_ONCE"]        = "once",
    ["CADENCE_ONDEMAND"]    = "ondemand",
}

M.KNOWN_PHASES = {
    ["init"]      = true, ["bind"]   = true, ["setup"]    = true,
    ["work"]      = true, ["commit"] = true, ["terminate"] = true,
}
M.KNOWN_REGIONS = {
    ["prim_arena"]     = true, ["face_arena"]     = true,
    ["vertex_arena"]   = true, ["ot_arena"]       = true,
    ["heap_3d_models"] = true, ["cdrom_stream"]   = true,
    ["vram_heap"]      = true,
}
M.KNOWN_CADENCES = {
    ["frame"]    = true, ["once"] = true, ["ondemand"] = true,
}

M.TAPE_ATOM_MACROS = {
    ["atom_annot"]     = { kind = "work",      binds = false },
    ["atom_bind"]      = { kind = "bind",      binds = true  },
    ["atom_setup"]     = { kind = "setup",     binds = false },
    ["atom_commit"]    = { kind = "commit",    binds = false },
    ["atom_init"]      = { kind = "init",      binds = false },
    ["atom_terminate"] = { kind = "terminate", binds = false },
}

M.ATOM_PRAGMA_KINDS = {
    ["resource"] = { kind = "string" },
    ["region"]   = { kind = "ident",  allowed = M.KNOWN_REGIONS },
    ["group"]    = { kind = "ident" },
    ["cadence"]  = { kind = "ident",  allowed = M.KNOWN_CADENCES },
    ["async"]    = { kind = "ident",  allowed = { ["true"] = true, ["false"] = true } },
}

-- Expose the lpeg_ok flag so callers can detect the LPeg-back path.
-- True when LPeg was successfully required and the patterns above were
-- compiled at module load time. False when running in fallback mode.
M.lpeg_ok = lpeg_ok

return M