-- The two regexes newmm uses outside of TCC, rewritten as matchers.
--
-- Neither is expressible as a Lua pattern: both need alternation, and both
-- range over codepoints rather than bytes.
--
-- `nonthai` is the one that carries real weight. When maximal matching runs out
-- of dictionary candidates, this decides how far to skip -- so it is what
-- determines the token boundaries around Latin words, numbers, punctuation and
-- whitespace.

local digit_ranges = require("newmm.digits")

local M = {}

--- @param ranges integer[][]
--- @return table<integer, boolean>
local function build_set(ranges)
  local set = {}
  for i = 1, #ranges do
    for cp = ranges[i][1], ranges[i][2] do
      set[cp] = true
    end
  end
  return set
end

local DIGIT = build_set(digit_ranges)

local HYPHEN = 45
local COMMA, FULL_STOP = 44, 46
local SPACE, TAB = 32, 9
local CR, LF = 13, 10

local THAI_FIRST, THAI_LAST = 0x0E00, 0x0E7F
local CONSONANT_FIRST, CONSONANT_LAST = 0x0E01, 0x0E2E -- ก..ฮ

--- `[-a-zA-Z]`
local function is_latin(cp)
  return cp == HYPHEN or (cp >= 97 and cp <= 122) or (cp >= 65 and cp <= 90)
end

--- The catch-all class `[^฀-๿ \t\r\n]`
local function is_other(cp)
  if cp >= THAI_FIRST and cp <= THAI_LAST then
    return false
  end
  return cp ~= SPACE and cp ~= TAB and cp ~= CR and cp ~= LF
end

--- Match `_PAT_NONTHAI` at `pos`; return where the match ends, or nil.
---
--- Upstream's pattern, in order:
---
---     [-a-zA-Z]+          Latin characters
---     \d+([,.]\d+)*       numbers, including grouped and decimal forms
---     [ \t]+              spaces
---     \r?\n               newlines
---     [^฀-๿ \t\r\n]+
---
--- **The order is the behaviour, not an implementation detail.** Python's `|`
--- takes the first branch that matches, not the longest, and upstream's comment
--- calls this out as deliberate: "`|` is used as like early return, which
--- divides `abc123` to `abc`, `123`". The last branch would happily swallow
--- `abc123!` whole; the first branch stops it at `abc`. So these are tried in
--- source order and the first success wins.
--- @param cps integer[]
--- @param pos integer  -0-based
--- @param count integer
--- @return integer?  -0-based end position
function M.nonthai(cps, pos, count)
  if pos >= count then
    return nil
  end

  local cp = cps[pos + 1]

  -- [-a-zA-Z]+
  if is_latin(cp) then
    local i = pos + 1
    while i < count and is_latin(cps[i + 1]) do
      i = i + 1
    end
    return i
  end

  -- \d+([,.]\d+)*
  if DIGIT[cp] then
    local i = pos + 1
    while i < count and DIGIT[cps[i + 1]] do
      i = i + 1
    end

    -- Each group must be a separator followed by at least one digit; a
    -- trailing "1," keeps only the "1", because the group fails and the star
    -- is content with what it already has.
    while i < count do
      local sep = cps[i + 1]
      if sep ~= COMMA and sep ~= FULL_STOP then
        break
      end
      local j = i + 1
      if j >= count or not DIGIT[cps[j + 1]] then
        break
      end
      while j < count and DIGIT[cps[j + 1]] do
        j = j + 1
      end
      i = j
    end

    return i
  end

  -- [ \t]+
  if cp == SPACE or cp == TAB then
    local i = pos + 1
    while i < count do
      local next_cp = cps[i + 1]
      if next_cp ~= SPACE and next_cp ~= TAB then
        break
      end
      i = i + 1
    end
    return i
  end

  -- \r?\n  -- note a lone carriage return matches nothing, here as upstream
  if cp == CR then
    if pos + 1 < count and cps[pos + 2] == LF then
      return pos + 2
    end
  elseif cp == LF then
    return pos + 1
  end

  -- [^฀-๿ \t\r\n]+
  if is_other(cp) then
    local i = pos + 1
    while i < count and is_other(cps[i + 1]) do
      i = i + 1
    end
    return i
  end

  return nil
end

--- Match `_PAT_THAI_TWOCHARS`, i.e. `[ก-ฮ]{,2}$`, against a span.
---
--- True when the span is at most two Thai consonants and nothing else. newmm
--- uses it to reject candidates that are too short to be worth breaking on when
--- it is hunting for the next plausible token start.
---
--- Note `{,2}` is Python for `{0,2}`, so it is an upper bound with no lower
--- one. Since the caller only ever passes spans of at least one character, the
--- empty case cannot arise.
--- @param cps integer[]
--- @param pos integer  -0-based start
--- @param length integer
--- @return boolean
function M.thai_twochars(cps, pos, length)
  if length > 2 then
    return false
  end

  for i = pos + 1, pos + length do
    local cp = cps[i]
    if cp < CONSONANT_FIRST or cp > CONSONANT_LAST then
      return false
    end
  end

  return true
end

return M
