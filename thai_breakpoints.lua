-- Word boundaries and intra-word break points for Thai runs
--
-- The linebreaker itself calls `plan`, which answers the same question in the
-- form it needs -- character offsets into the run rather than strings -- and
-- caches the answer per run text, because LuaTeX hyphenates every hbox, running
-- head and trial typesetting pass, not just paragraphs, and sees the same text
-- many times over.
--
-- No `node` or `tex` here, so this runs (and is tested) under plain texlua.

---@source types_annotations.lua

local newmm = require("newmm")

local M = {}

--- Words longer than this (in characters) get break points computed.
M.TCC_THRESHOLD = 5

--- Syllables longer than this are split further into TCC clusters.
M.SYLLABLE_SPLIT_THRESHOLD = 10

--- Breaks closer than this to either end of a word are dropped, as
--- \lefthyphenmin and \righthyphenmin would. User hyphenations are exempt.
M.TCC_MIN_EDGE = 2

--- Whether `plan` reports cluster boundaries for intercluster glue.
M.clusters = false

-- word -> break offsets. Depends only on the word and the syllable dictionary,
-- so it survives word-dictionary edits but not syllable edits.
local memo = {}

-- word -> break offsets given by the user with \ThaiHyphenation. Used verbatim.
local custom = {}
local has_custom = false

-- run text -> plan. Depends on everything, so any edit or option change clears it.
local plans = {}

local function invalidate()
  plans = {}
end

--- Change linebreaking options; clears the plan cache.
--- @param opts { min_edge: integer?, clusters: boolean? }
function M.set_options(opts)
  if opts.min_edge ~= nil then
    M.TCC_MIN_EDGE = opts.min_edge
  end
  if opts.clusters ~= nil then
    M.clusters = opts.clusters
  end
  invalidate()
end

--- Break offsets inside one word.
--- @param word string
--- @return integer[]
local function word_breaks(word)
  local cached = memo[word]
  if cached then
    return cached
  end

  local positions, n = {}, 0
  local pos = 0

  local syllables = newmm.segment(word, newmm.syllable_dictionary())
  for i = 1, #syllables do
    local syllable = syllables[i]
    local pieces = (utf8.len(syllable) or 0) > M.SYLLABLE_SPLIT_THRESHOLD and newmm.tcc.segment(syllable)
      or { syllable }

    for j = 1, #pieces do
      pos = pos + (utf8.len(pieces[j]) or 0)
      n = n + 1
      positions[n] = pos
    end
  end

  -- The last offset is the end of the word, which is a word boundary, not a
  -- hyphenation point.
  positions[n] = nil

  memo[word] = positions
  return positions
end

--- Segment one Thai run.
--- @param text string
--- @return run_result
function M.process(text)
  local words = newmm.segment(text)
  local tcc = {}

  for i = 1, #words do
    local word = words[i]
    if not tcc[word] then
      if custom[word] then
        tcc[word] = custom[word]
      elseif (utf8.len(word) or 0) > M.TCC_THRESHOLD then
        tcc[word] = word_breaks(word)
      end
    end
  end

  return { words = words, tcc = tcc }
end

local utf8_char, unpack = utf8.char, table.unpack

--- Everything the linebreaker inserts into one Thai run, as 0-based character
--- offsets into the run: a node goes after the character ending at each one.
---
---   * `ends`: word ends, the last of which is the end of the run.
---   * `breaks`: hyphenation points, ascending, already filtered by
---     `TCC_MIN_EDGE` (user hyphenations excepted).
---   * `clusters`: cluster boundaries inside words, ascending, when
---     `M.clusters` is on; otherwise nil.
---
--- Cached by `text`. The returned table is shared: do not modify it.
--- @param text string  -the run, used as the cache key
--- @param cps integer[]?  -its codepoints, if the caller has them already
--- @param count integer?
--- @return { ends: integer[], breaks: integer[], clusters: integer[]? }
function M.plan(text, cps, count)
  local cached = plans[text]
  if cached then
    return cached
  end

  if not cps then
    local _
    cps, _, count = newmm.codepoints.decode(text)
  end
  ---@cast count integer

  local ends, valid = newmm.segment_positions(cps, count)
  local breaks, nb = {}, 0
  local clusters, nc = M.clusters and {} or nil, 0
  local min_edge = M.TCC_MIN_EDGE
  local threshold = M.TCC_THRESHOLD

  local from = 0
  for i = 1, #ends do
    local to = ends[i]
    local length = to - from

    local word = nil
    if has_custom or length > threshold then
      word = utf8_char(unpack(cps, from + 1, to))
    end

    local user = word and custom[word]
    if user then
      for j = 1, #user do
        nb = nb + 1
        breaks[nb] = from + user[j]
      end
    elseif length > threshold then
      ---@cast word string
      local positions = word_breaks(word)
      for j = 1, #positions do
        local pos = positions[j]
        if pos >= min_edge and pos <= length - min_edge then
          nb = nb + 1
          breaks[nb] = from + pos
        end
      end
    end

    if clusters then
      for pos = from + 1, to - 1 do
        if valid[pos + 1] then
          nc = nc + 1
          clusters[nc] = pos
        end
      end
    end

    from = to
  end

  local result = { ends = ends, breaks = breaks, clusters = clusters }
  plans[text] = result
  return result
end

--- Segment several runs; results are aligned 1:1 with `texts`.
--- @param texts string[]
--- @return run_result[]
function M.process_batch(texts)
  local results = {}
  for i = 1, #texts do
    results[i] = M.process(texts[i])
  end
  return results
end

---------------------------------------------------------------------------
-- dictionary edits
---------------------------------------------------------------------------

--- @param words string[]
--- @return integer  -how many were new
function M.add_words(words)
  invalidate()
  return newmm.add_words(words)
end

--- @param words string[]
--- @return integer  -how many were removed
function M.remove_words(words)
  invalidate()
  local removed = 0
  for i = 1, #words do
    if newmm.remove_word(words[i]) then
      removed = removed + 1
    end
  end
  return removed
end

--- @param path string
--- @return integer  -how many were new
function M.add_words_from_file(path)
  invalidate()
  return newmm.add_words_from_file(path)
end

--- @param syllables string[]
--- @return integer  -how many were new
function M.add_syllables(syllables)
  memo = {}
  invalidate()
  return newmm.add_syllables(syllables)
end

--- @param syllables string[]
--- @return integer  -how many were removed
function M.remove_syllables(syllables)
  memo = {}
  invalidate()
  local dict = newmm.syllable_dictionary()
  local removed = 0
  for i = 1, #syllables do
    if dict:remove(syllables[i]) then
      removed = removed + 1
    end
  end
  return removed
end

--- Parse one \ThaiHyphenation entry, `ไฮ-เซน-เบิร์ก`, into the word and its
--- break offsets. Returns nil for an entry with nothing but hyphens.
--- @param entry string
--- @return string? word
--- @return integer[] offsets
local function parse_hyphenation(entry)
  local pieces, offsets = {}, {}
  local at = 0
  for piece in (entry .. "-"):gmatch("([^-]*)-") do
    if piece ~= "" then
      if at > 0 then
        offsets[#offsets + 1] = at
      end
      pieces[#pieces + 1] = piece
      at = at + (utf8.len(piece) or #piece)
    end
  end
  if at == 0 then
    return nil, offsets
  end
  return table.concat(pieces), offsets
end

--- Fix the break points of words, as LaTeX's \hyphenation does: `ไฮ-เซน-เบิร์ก`
--- breaks there and nowhere else, and an entry with no hyphens is never broken.
--- Each word is added to the word dictionary too, so segmentation keeps it whole.
--- A later entry for the same word replaces the earlier one.
--- @param entries string[]
--- @return integer  -how many entries were taken
function M.add_hyphenations(entries)
  local words, taken = {}, 0
  for i = 1, #entries do
    local word, offsets = parse_hyphenation(entries[i])
    if word then
      custom[word] = offsets
      words[#words + 1] = word
      taken = taken + 1
    end
  end
  has_custom = next(custom) ~= nil
  newmm.add_words(words)
  invalidate()
  return taken
end

--- Forget user hyphenations, given either plain or hyphenated. The words stay
--- in the dictionary; use \ThaiRemoveWords for that.
--- @param entries string[]
--- @return integer  -how many were removed
function M.remove_hyphenations(entries)
  local removed = 0
  for i = 1, #entries do
    local word = parse_hyphenation(entries[i])
    if word and custom[word] then
      custom[word] = nil
      removed = removed + 1
    end
  end
  has_custom = next(custom) ~= nil
  invalidate()
  return removed
end

--- Build both dictionaries now rather than inside the first paragraph.
function M.load()
  newmm.load()
  newmm.syllable_dictionary()
end

return M
