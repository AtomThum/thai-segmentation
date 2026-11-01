-- newmm -- dictionary-based maximal matching word segmentation for Thai,
-- constrained by Thai Character Cluster boundaries.
--
-- A port of `pythainlp.tokenize.newmm`, which is in turn based on notebooks by
-- Korakot Chaovavanich.
--
--     local newmm = require("newmm")
--     newmm.segment("สวัสดีครับ")
--     --> { "สวัสดี", "ครับ" }
--
-- Nothing outside the Lua standard library is required. The 62,101-word
-- dictionary ships as `data/words_th.txt` and is read on first use.
--
-- How it works, since "maximal matching" undersells it
-- ----------------------------------------------------
--
-- Thai is written without spaces, so segmentation is a search. The algorithm
-- keeps a priority queue of positions it might be at, and from the earliest one
-- looks up every dictionary word starting there. Each such word is an edge in a
-- graph from one position to another, and a segmentation is a path through that
-- graph from 0 to the end of the text.
--
-- Two things keep the search from exploding:
--
--   * **TCC constraint.** An edge is only allowed if it ends on a Thai
--     Character Cluster boundary, which throws away the great majority of
--     spurious dictionary matches -- the ones that would cut a vowel away from
--     its consonant.
--   * **Collapse on agreement.** Whenever the queue drops to a single position,
--     every path must pass through it, so the graph so far can be resolved into
--     tokens by a breadth-first search and then thrown away. Ambiguity is
--     settled locally and never accumulates.
--
-- When the dictionary offers nothing at all, a separate rule decides how far to
-- skip: non-Thai runs (Latin, numbers, punctuation, whitespace) are consumed by
-- pattern, and inside Thai the text is scanned forward for the first position
-- that looks like a plausible token start.
--
-- Deliberate differences from upstream
-- ------------------------------------
--
--   * `safe_mode` is not implemented. It exists upstream to chunk texts of
--     hundreds of kilobytes; here the caller is a LuaTeX paragraph handler that
--     has already split the document into runs. `_MAX_GRAPH_SIZE` is kept,
--     because that guards against ambiguity rather than length.
--   * `prefixes` returns lengths rather than strings, which avoids building a
--     substring per candidate per position.
--
-- Neither changes the output for any input the LuaTeX side produces.

local codepoints = require("newmm.codepoints")
local defaultdict = require("newmm.defaultdict")
local dictionary = require("newmm.dictionary")
local heap = require("newmm.heap")
local patterns = require("newmm.patterns")
local tcc = require("newmm.tcc")
local trie = require("newmm.trie")

local M = {}

M._VERSION = "0.1.0"

--- Version of PyThaiNLP the algorithm and data were taken from.
M._PYTHAINLP_VERSION = "5.3.4"

--- Maximum number of graph edges before the search stops adding more.
---
--- Upstream's cutoff, kept as-is. It bounds the work spent on a genuinely
--- ambiguous stretch of text; without it a pathological run of short
--- dictionary words can blow up combinatorially.
M.MAX_GRAPH_SIZE = 50

--- First path from `start` to `goal`, breadth-first.
---
--- Breadth-first, so the first path found has the fewest edges -- the
--- segmentation into the fewest words. Ties are broken by the order edges were
--- added to the graph, which is the order the trie returned them: shortest word
--- first.
---
--- The visited set is what keeps this linear. Without it, a diamond-shaped
--- graph is re-explored along every route into each node.
--- @param graph table<integer, integer[]>
--- @param start integer
--- @param goal integer
--- @return integer[]?
local function bfs_first_path(graph, start, goal)
  local visited = { [start] = true }

  -- A queue as an array with a moving head; `table.remove(queue, 1)` would make
  -- this quadratic.
  local queue = { { start, { start } } }
  local head = 1

  while head <= #queue do
    local entry = queue[head]
    head = head + 1

    local vertex, path = entry[1], entry[2]
    local edges = graph[vertex]

    for i = 1, #edges do
      local pos = edges[i]

      local extended = {}
      for j = 1, #path do
        extended[j] = path[j]
      end
      extended[#path + 1] = pos

      if pos == goal then
        return extended
      end

      if not visited[pos] then
        visited[pos] = true
        queue[#queue + 1] = { pos, extended }
      end
    end
  end

  return nil
end

--- Segment one text, recording where each token ends.
---
--- A direct port of upstream's `_onecut`, written against decoded codepoints so
--- that every position here means the same thing it does there. Upstream yields
--- substrings; this yields their end positions, so `ends[i]` is the 0-based
--- position just past token `i` and the last entry is `count`. Callers that
--- want strings cut them from the text; the linebreaker never needs them.
--- @param cps integer[]
--- @param count integer
--- @param dict Trie
--- @return integer[] ends
--- @return boolean[] valid  -the TCC boundary flags, see `tcc.boundary_flags`
local function onecut(cps, count, dict)
  local out = {}
  local emitted = 0

  -- Keyed by start position, valued by the end positions reachable from it.
  local graph = defaultdict.new()
  local graph_size = 0

  local valid = tcc.boundary_flags(cps, count)

  local pos_list = heap.new()
  heap.push(pos_list, 0)

  local end_pos = 0

  while true do
    local frontier = heap.peek(pos_list)
    if frontier == nil or frontier >= count then
      break
    end

    local begin_pos = heap.pop(pos_list)

    local lengths, found = dict:prefixes(cps, begin_pos, count)
    for i = 1, found do
      local candidate = begin_pos + lengths[i]

      if valid[candidate + 1] then
        local edges = graph[begin_pos]
        edges[#edges + 1] = candidate
        graph_size = graph_size + 1

        if not heap.contains(pos_list, candidate) then
          heap.push(pos_list, candidate)
        end

        if graph_size > M.MAX_GRAPH_SIZE then
          break
        end
      end
    end

    local pending = heap.size(pos_list)

    if pending == 1 then
      -- Every path runs through this position, so everything before it can be
      -- resolved now and forgotten.
      local goal = heap.peek(pos_list)
      local path = bfs_first_path(graph, end_pos, goal)

      graph_size = 0
      defaultdict.clear(graph)

      if path then
        for i = 2, #path do
          emitted = emitted + 1
          out[emitted] = path[i]
          end_pos = path[i]
        end
      else
        -- Unreachable: every position in the queue was put there by an edge
        -- from a position already reachable from `end_pos`, so a path exists by
        -- induction. Handled anyway, because the alternative to emitting this
        -- span is emitting nothing for it -- and text vanishing out of the
        -- middle of a paragraph is the one failure a linebreaker must never
        -- have. Upstream raises StopIteration here; keeping the text and
        -- getting the split wrong is the better trade in a document build.
        if goal > end_pos then
          emitted = emitted + 1
          out[emitted] = goal
          end_pos = goal
        end
      end
    elseif pending == 0 then
      -- Nothing in the dictionary starts here.
      local stop = patterns.nonthai(cps, begin_pos, count)

      if stop then
        end_pos = stop
      else
        end_pos = nil

        -- Scan forward for the first position that could plausibly begin a
        -- token: one that starts a dictionary word of more than two Thai
        -- consonants ending on a cluster boundary, or that starts a non-Thai
        -- run.
        for pos = begin_pos + 1, count - 1 do
          if valid[pos + 1] then
            local candidates, n = dict:prefixes(cps, pos, count)

            local plausible = false
            for i = 1, n do
              local length = candidates[i]
              if valid[pos + length + 1] and not patterns.thai_twochars(cps, pos, length) then
                plausible = true
                break
              end
            end

            if plausible or patterns.nonthai(cps, pos, count) then
              end_pos = pos
              break
            end
          end
        end

        if end_pos == nil then
          end_pos = count
        end
      end

      graph_size = 0
      defaultdict.clear(graph)

      emitted = emitted + 1
      out[emitted] = end_pos

      heap.push(pos_list, end_pos)
    end
  end

  return out, valid
end

--- Split Thai text into words.
---
--- Segmenting is a pure split: `table.concat(newmm.segment(text)) == text`
--- always holds.
--- @param text string
--- @param dict Trie?  -defaults to the shared dictionary
--- @return string[]
function M.segment(text, dict)
  if type(text) ~= "string" or text == "" then
    return {}
  end

  dict = dict or dictionary.default()

  local cps, offsets, count = codepoints.decode(text)
  local ends = onecut(cps, count, dict)

  local out, from = {}, 0
  for i = 1, #ends do
    out[i] = codepoints.slice(text, offsets, from, ends[i])
    from = ends[i]
  end

  return out
end

--- Split already-decoded text into words, as end positions.
---
--- What `segment` computes, minus the strings: `ends[i]` is the 0-based
--- position just past word `i`, the last entry is `count`, and `valid[p + 1]`
--- is true when position `p` ends a Thai Character Cluster. For callers that
--- hold codepoints already -- the LuaTeX side reads them straight off glyph
--- nodes -- this skips both the decode and a substring per word.
--- @param cps integer[]
--- @param count integer
--- @param dict Trie?
--- @return integer[] ends
--- @return boolean[] valid
function M.segment_positions(cps, count, dict)
  if count == 0 then
    return {}, { false }
  end
  return onecut(cps, count, dict or dictionary.default())
end

--- Split several texts.
--- @param texts string[]
--- @param dict Trie?
--- @return string[][]
function M.segment_all(texts, dict)
  dict = dict or dictionary.default()

  local out = {}
  for i = 1, #texts do
    out[i] = M.segment(texts[i], dict)
  end

  return out
end

---------------------------------------------------------------------------
-- dictionary
---------------------------------------------------------------------------

--- The shared dictionary, building it from the shipped word list if needed.
--- @return Trie
function M.dictionary()
  return dictionary.default()
end

--- Add one word to the shared dictionary.
--- @param word string
--- @return boolean  -true if it was not already there
function M.add_word(word)
  return dictionary.default():add(word)
end

--- Add several words to the shared dictionary.
--- @param words string[]
--- @return integer  -how many were new
function M.add_words(words)
  local dict = dictionary.default()

  local added = 0
  for i = 1, #words do
    if dict:add(words[i]) then
      added = added + 1
    end
  end

  return added
end

--- Remove a word from the shared dictionary.
--- @param word string
--- @return boolean
function M.remove_word(word)
  return dictionary.default():remove(word)
end

--- Add every word from a file to the shared dictionary.
--- One word per line; blank lines are skipped.
--- @param path string
--- @return integer  -how many were new
function M.add_words_from_file(path)
  return M.add_words(dictionary.read_words(path))
end

--- The shared syllable dictionary, building it from the shipped list if needed.
---
--- Segmenting against it is what PyThaiNLP calls
--- `syllable_tokenize(text, engine="dict")`:
--- `newmm.segment(text, newmm.syllable_dictionary())`.
--- @return Trie
function M.syllable_dictionary()
  return dictionary.syllables()
end

--- Add several syllables to the shared syllable dictionary.
--- @param syllables string[]
--- @return integer  -how many were new
function M.add_syllables(syllables)
  local dict = dictionary.syllables()

  local added = 0
  for i = 1, #syllables do
    if dict:add(syllables[i]) then
      added = added + 1
    end
  end

  return added
end

--- Build a dictionary of your own, ignoring the shipped word list.
--- @param words string[]?
--- @return Trie
function M.new_dictionary(words)
  return trie.new(words)
end

--- Configure the package.
---
--- `words` points at a word list to use instead of the shipped one, and
--- `syllables` at a syllable list; each takes effect on the next use, so call it
--- before segmenting anything.
--- @param opts { words: string?, syllables: string? }
function M.setup(opts)
  opts = opts or {}

  if opts.words then
    dictionary.set_path(opts.words)
    dictionary.reset()
  end

  if opts.syllables then
    dictionary.set_syllables_path(opts.syllables)
    dictionary.reset_syllables()
  end
end

--- Build the dictionary now rather than on first use.
function M.load()
  dictionary.default()
end

---------------------------------------------------------------------------
-- re-exports
---------------------------------------------------------------------------

-- The in-house data structures, exposed because they are generally useful and
-- because the test suite exercises them directly.
M.tcc = tcc
M.trie = trie
M.heap = heap
M.defaultdict = defaultdict
M.codepoints = codepoints

return M
