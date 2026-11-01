-- Thai Character Clusters, ported from `pythainlp.tokenize.tcc_p`.
--
-- A TCC is the smallest group of characters that must not be broken apart --
-- a consonant together with whatever vowels, tone marks and diacritics attach
-- to it. Two things here need them:
--
--   * newmm only allows a word boundary where a cluster ends, which is what
--     stops maximal matching from cutting a syllable in half.
--   * the LuaTeX linebreaker wants cluster edges as the places it may put a
--     hyphenation point inside a word.
--
-- Upstream expresses the rules as one regex alternation of 29 branches and
-- applies it at each position. Lua patterns cannot express any part of that --
-- no alternation, no lookahead, no `?` on a group, and classes are byte-wise so
-- `[ก-ฮ]`, a range over three-byte sequences, is not writable either. So
-- `tools/export.py` compiles the grammar into a table at build time and
-- this file interprets it.
--
-- What the matcher has to preserve, all three of which are easy to get wrong:
--
--   * **Order, not length.** Python's `|` returns the first branch that
--     matches, not the longest. Rule 16 `[ก-ฮ]็` is tried before rule 17
--     `[ก-ฮ][่-๋]?[ะาำ]?(...)?`, and swapping them changes the output.
--   * **Greedy with backtracking.** `เ[ก-ฮ][่-๋]?า?ะ?` tries to take each
--     optional before giving it up, but must give it up if what follows fails.
--   * **Python's `$`.** It matches at the end of the string *or* just before a
--     final newline. `$` only appears inside a lookahead here, but newmm feeds
--     this whole paragraphs, newlines included.

local codepoints = require("newmm.codepoints")
local compiled = require("newmm.tcc_rules")

local M = {}

local NEWLINE = 10

--- Expand `{{lo, hi}, ...}` into a membership table.
--- @param ranges integer[][]
--- @return table<integer, boolean>
local function build_set(ranges)
  local set = {}
  for i = 1, #ranges do
    local lo, hi = ranges[i][1], ranges[i][2]
    for cp = lo, hi do
      set[cp] = true
    end
  end
  return set
end

--- Turn the generated `ranges` tables into membership sets, in place.
--- @param items table[]
local function prepare(items)
  for i = 1, #items do
    local item = items[i]
    if item.ranges then
      item.set = build_set(item.ranges)
    end
    if item.items then
      prepare(item.items)
    end
  end
end

local RULES = compiled.rules
for i = 1, #RULES do
  prepare(RULES[i])
end

--- True at a position where Python's `$` would match.
--- @param pos integer  -0-based
--- @param cps integer[]
--- @param count integer
--- @return boolean
local function at_end(pos, cps, count)
  return pos == count or (pos == count - 1 and cps[pos + 1] == NEWLINE)
end

local match_items

--- Match `items[idx..]` at 0-based `pos`; return the end position, or nil.
---
--- Backtracking falls out of the recursion: an optional item first tries to
--- consume its character and match the rest, and only if that whole
--- continuation fails does it try again having consumed nothing.
---
--- Groups are the one exception -- they are tried, then skipped, without being
--- re-entered for a shorter match. That is sound only while nothing follows a
--- group, which `tools/export_tcc.py` refuses to emit rules violating.
--- @param items table[]
--- @param idx integer
--- @param cps integer[]
--- @param pos integer
--- @param count integer
--- @return integer?
match_items = function(items, idx, cps, pos, count)
  local item = items[idx]
  if item == nil then
    return pos
  end

  local kind = item.kind

  if kind == "set" then
    local cp = cps[pos + 1]
    if cp and item.set[cp] then
      local after = match_items(items, idx + 1, cps, pos + 1, count)
      if after then
        return after
      end
    end
    if item.optional then
      return match_items(items, idx + 1, cps, pos, count)
    end
    return nil
  elseif kind == "group" then
    local inner = match_items(item.items, 1, cps, pos, count)
    if inner then
      local after = match_items(items, idx + 1, cps, inner, count)
      if after then
        return after
      end
    end
    if item.optional then
      return match_items(items, idx + 1, cps, pos, count)
    end
    return nil
  elseif kind == "ahead" then
    -- Zero-width: look, do not consume.
    local cp = cps[pos + 1]
    local ok = (cp ~= nil and item.set[cp]) or (item.eol and at_end(pos, cps, count))
    if ok then
      return match_items(items, idx + 1, cps, pos, count)
    end
    return nil
  elseif kind == "eol" then
    if at_end(pos, cps, count) then
      return match_items(items, idx + 1, cps, pos, count)
    end
    return nil
  end

  error("newmm.tcc: unknown rule item kind " .. tostring(kind), 0)
end

--- Compile one rule into a Lua function `(cps, pos, count) -> end?`.
---
--- `match_items` interprets a rule one table at a time, recursing per item; at
--- one call per character of every Thai run, that was about 40% of the time
--- spent segmenting. A compiled rule is straight-line code instead. Because
--- every consuming item takes exactly one character, each position along any
--- path through a rule is `pos` plus a constant known at compile time, so the
--- generated code needs no position variables at all.
---
--- Backtracking is unrolled: an optional item emits its "consume" branch and
--- then, if that branch falls through without returning, its "skip" branch.
--- Falling off the end of a branch *is* failure, so the semantics match
--- `match_items` exactly, the first-branch-wins order included. Code size is
--- exponential in the optional items per rule, which tops out at a handful.
---
--- Groups follow `match_items` too: tried, then skipped, never re-entered for
--- a shorter match, and only legal last.
--- @param rule table[]
--- @param index integer  -for error messages
--- @return fun(cps: integer[], pos: integer, count: integer): integer?
local function compile_rule(rule, index)
  local sets, refs = {}, {}
  local out = {}

  local function emit(line)
    out[#out + 1] = line
  end

  local function ref(item)
    local name = refs[item]
    if not name then
      sets[#sets + 1] = item.set
      name = "S" .. #sets
      refs[item] = name
    end
    return name
  end

  local function at_end(off)
    return ("(pos + %d == count or (pos + %d == count - 1 and cps[pos + %d] == %d))"):format(
      off, off, off + 1, NEWLINE)
  end

  local function gen(items, idx, off, tail)
    local item = items[idx]
    if item == nil then
      emit(tail(off))
      return
    end

    local kind = item.kind
    if kind == "set" then
      emit(("if %s[cps[pos + %d]] then"):format(ref(item), off + 1))
      gen(items, idx + 1, off + 1, tail)
      emit("end")
      if item.optional then
        gen(items, idx + 1, off, tail)
      end
    elseif kind == "group" then
      if idx ~= #items then
        error(("newmm.tcc: rule %d has a group that is not last"):format(index), 0)
      end
      gen(item.items, 1, off, tail)
      if item.optional then
        emit(tail(off))
      end
    elseif kind == "ahead" then
      local cond = ("%s[cps[pos + %d]]"):format(ref(item), off + 1)
      if item.eol then
        cond = cond .. " or " .. at_end(off)
      end
      emit("if " .. cond .. " then")
      gen(items, idx + 1, off, tail)
      emit("end")
    elseif kind == "eol" then
      emit("if " .. at_end(off) .. " then")
      gen(items, idx + 1, off, tail)
      emit("end")
    else
      error("newmm.tcc: unknown rule item kind " .. tostring(kind), 0)
    end
  end

  -- `do ... end` because a bare `return` must end its block, and an optional
  -- item's skip branch can follow one.
  gen(rule, 1, 0, function(off)
    return ("do return pos + %d end"):format(off)
  end)

  local names = {}
  for i = 1, #sets do
    names[i] = "S" .. i
  end

  local source = ("local %s = ...\nreturn function(cps, pos, count)\n%s\nend"):format(
    table.concat(names, ", "), table.concat(out, "\n"))
  local chunk = assert(load(source, "=newmm.tcc rule " .. index, "t", {}))
  return chunk(table.unpack(sets, 1, #sets))
end

local COMPILED = {}
for i = 1, #RULES do
  COMPILED[i] = compile_rule(RULES[i], i)
end

--- Rules whose first item can match a given codepoint, in rule order.
---
--- Every rule begins with a required literal or class, so a rule whose first
--- item rejects the character at `pos` cannot match there at all. Bucketing by
--- that character turns "try 29 rules" into "try the three or four that stand a
--- chance" without changing which one wins, because each bucket keeps the
--- original order. `dispatch` holds the compiled rules; `interpreted` the same
--- buckets of rule tables, for `interpreted_cluster_length`.
local dispatch, interpreted = {}, {}
do
  for index = 1, #RULES do
    local first = RULES[index][1]
    if first == nil or first.kind ~= "set" or first.optional then
      error(
        ("newmm.tcc: rule %d does not begin with a required character; " ..
          "the dispatch table assumes it does"):format(index),
        0
      )
    end

    for cp in pairs(first.set) do
      local bucket = dispatch[cp]
      if not bucket then
        bucket = {}
        dispatch[cp] = bucket
        interpreted[cp] = {}
      end
      bucket[#bucket + 1] = COMPILED[index]
      local slow = interpreted[cp]
      slow[#slow + 1] = RULES[index]
    end
  end
end

--- Length in characters of the cluster starting at `pos`.
---
--- Upstream falls back to a single character when no rule matches, which is
--- what makes TCC total over any input, Thai or not.
--- @param cps integer[]
--- @param pos integer  -0-based
--- @param count integer
--- @return integer
function M.cluster_length(cps, pos, count)
  local bucket = dispatch[cps[pos + 1]]

  if bucket then
    for i = 1, #bucket do
      local stop = bucket[i](cps, pos, count)
      -- A rule that matches the empty string would stall the caller's loop.
      -- None can -- every rule starts with a required character -- but the
      -- cost of being sure is one comparison.
      if stop and stop > pos then
        return stop - pos
      end
    end
  end

  return 1
end

--- `cluster_length` through the rule interpreter rather than the compiled
--- rules. Slower, and kept only as the reference the tests hold the compiled
--- form to.
--- @param cps integer[]
--- @param pos integer  -0-based
--- @param count integer
--- @return integer
function M.interpreted_cluster_length(cps, pos, count)
  local bucket = interpreted[cps[pos + 1]]

  if bucket then
    for i = 1, #bucket do
      local stop = match_items(bucket[i], 1, cps, pos, count)
      -- A rule that matches the empty string would stall the caller's loop.
      -- None can -- every rule starts with a required character -- but the
      -- cost of being sure is one comparison.
      if stop and stop > pos then
        return stop - pos
      end
    end
  end

  return 1
end

--- Which positions are cluster boundaries.
---
--- `flags[p + 1]` is true when 0-based position `p` ends a cluster. Position 0
--- is deliberately *not* flagged: upstream builds this by accumulating cluster
--- lengths from zero, so the start of the text is never marked, and newmm
--- relies on the resulting array only for positions it reaches by adding a
--- word length to a start position.
--- @param cps integer[]
--- @param count integer
--- @return boolean[]  -count+1 entries
function M.boundary_flags(cps, count)
  local flags = {}
  for i = 1, count + 1 do
    flags[i] = false
  end

  local pos = 0
  while pos < count do
    pos = pos + M.cluster_length(cps, pos, count)
    flags[pos + 1] = true
  end

  return flags
end

--- Split `text` into Thai Character Clusters.
--- @param text string
--- @return string[]
function M.segment(text)
  if type(text) ~= "string" or text == "" then
    return {}
  end

  local cps, offsets, count = codepoints.decode(text)

  local out, n = {}, 0
  local pos = 0
  while pos < count do
    local width = M.cluster_length(cps, pos, count)
    n = n + 1
    out[n] = codepoints.slice(text, offsets, pos, pos + width)
    pos = pos + width
  end

  return out
end

--- End positions of every cluster, as 0-based character offsets.
---
--- These are the points inside a word where a line may be broken. The last
--- entry is always the length of the text.
--- @param text string
--- @return integer[]
function M.positions(text)
  if type(text) ~= "string" or text == "" then
    return {}
  end

  local cps, _, count = codepoints.decode(text)

  local out, n = {}, 0
  local pos = 0
  while pos < count do
    pos = pos + M.cluster_length(cps, pos, count)
    n = n + 1
    out[n] = pos
  end

  return out
end

M.source = compiled.source

return M
