-- A trie (prefix tree), holding the segmentation dictionary.
--
-- Ported from `pythainlp.util.Trie`. Nodes are plain Lua tables keyed by
-- *codepoint*, not by character string: the segmenter has already decoded its
-- input to codepoints, so keying by integer saves building a one-character
-- substring for every step of every walk.
--
-- The one operation that matters for speed is `prefixes`, which the segmenter
-- calls at nearly every position of the text: walk down from the root while the
-- next character has a child, noting each node that ends a word. That is what
-- makes the whole maximal-matching approach affordable -- all words starting at
-- a position are found in one descent, in time proportional to the longest of
-- them rather than to the size of the dictionary.
--
-- The 62,101-word default dictionary builds into about 235,000 nodes in
-- roughly 0.08 s and occupies ~22 MB. Measured against a flat
-- word-set-plus-prefix-set alternative, the trie was both faster to build and
-- no larger, so there was no reason to deviate from upstream's structure.

local codepoints = require("newmm.codepoints")

local M = {}

--- Marks a node as ending a word.
---
--- A table, so that it can never be confused with a codepoint key. Using a
--- string like "end" would be safe today only because every other key is an
--- integer; this is safe by construction.
local FINAL = {}

--- @class Trie
--- @field root table
--- @field count integer
local Trie = {}
Trie.__index = Trie

local byte = string.byte

--- Insert words already trimmed and non-empty, as `dictionary.read_words`
--- returns them.
---
--- `add` without its per-word overhead: no second trim, and the UTF-8 is decoded
--- while walking down instead of into three fresh tables per word. Building the
--- default dictionary is most of what the package costs at startup, and this
--- roughly halves it. Decoding agrees with `codepoints.decode` for well-formed
--- input; a malformed word falls back to `add`.
--- @param self Trie
--- @param words string[]
local function add_trusted(self, words)
  local root, count = self.root, self.count

  for w = 1, #words do
    local word = words[w]
    local node = root
    local i, len = 1, #word
    local ok = true

    while i <= len do
      local b = byte(word, i)
      local cp
      if b < 0x80 then
        cp, i = b, i + 1
      elseif b >= 0xE0 and b < 0xF0 and i + 2 <= len then
        local b2, b3 = byte(word, i + 1, i + 2)
        cp, i = (b - 0xE0) * 0x1000 + (b2 % 0x40) * 0x40 + b3 % 0x40, i + 3
      else
        ok = false -- two- or four-byte, or malformed: leave it to `add`
        break
      end

      local child = node[cp]
      if child == nil then
        child = {}
        node[cp] = child
      end
      node = child
    end

    if not ok then
      self.count = count
      self:add(word)
      count = self.count
    elseif not node[FINAL] then
      node[FINAL] = true
      count = count + 1
    end
  end

  self.count = count
end

--- @param words string[]?
--- @param trusted boolean?  -words are already trimmed and non-empty
--- @return Trie
function M.new(words, trusted)
  local self = setmetatable({ root = {}, count = 0 }, Trie)

  if words then
    if trusted then
      add_trusted(self, words)
    else
      for i = 1, #words do
        self:add(words[i])
      end
    end
  end

  return self
end

--- Add a word.
---
--- Surrounding whitespace is trimmed, matching upstream -- dictionary files are
--- line-oriented and stray spaces are a data-entry artefact, not part of the
--- word. Interior spaces are kept: 611 entries of the default dictionary are
--- multi-word phrases like "ก ข ไม่กระดิกหู".
--- @param word string
--- @return boolean  -true if the word was not already present
function Trie:add(word)
  word = word:match("^%s*(.-)%s*$")
  if word == "" then
    return false
  end

  local cps, _, n = codepoints.decode(word)

  local node = self.root
  for i = 1, n do
    local cp = cps[i]
    local child = node[cp]
    if child == nil then
      child = {}
      node[cp] = child
    end
    node = child
  end

  if node[FINAL] then
    return false
  end

  node[FINAL] = true
  self.count = self.count + 1
  return true
end

--- Remove a word, if present.
---
--- Prunes nodes that are left neither ending a word nor leading anywhere, so
--- that repeatedly adding and removing custom entries cannot grow the trie
--- without bound.
--- @param word string
--- @return boolean  -true if the word was there
function Trie:remove(word)
  local cps, _, n = codepoints.decode(word)

  -- Walk down, remembering the path so it can be pruned on the way back up.
  local node = self.root
  local parents, keys = {}, {}

  for i = 1, n do
    local cp = cps[i]
    local child = node[cp]
    if child == nil then
      return false
    end
    parents[i], keys[i] = node, cp
    node = child
  end

  if not node[FINAL] then
    return false
  end

  node[FINAL] = nil
  self.count = self.count - 1

  for i = n, 1, -1 do
    local child = parents[i][keys[i]]
    if next(child) ~= nil then
      break -- still ends a word or still has children
    end
    parents[i][keys[i]] = nil
  end

  return true
end

--- @param word string
--- @return boolean
function Trie:contains(word)
  local cps, _, n = codepoints.decode(word)

  local node = self.root
  for i = 1, n do
    node = node[cps[i]]
    if node == nil then
      return false
    end
  end

  return node[FINAL] == true
end

--- How many words are stored.
--- @return integer
function Trie:len()
  return self.count
end

--- Shared result buffer for `prefixes`; see the note there.
local prefix_buffer = {}

--- Lengths of every dictionary word that starts at `start`.
---
--- Returned in increasing order, as counts of characters rather than as the
--- words themselves: the caller wants to know where each candidate word *ends*,
--- and building the substrings would allocate a string per candidate per
--- position for nothing.
---
--- **The array is reused by the next call**, and entries past `n` are stale.
--- newmm calls this at nearly every position and always finishes reading one
--- result before asking for the next, so a fresh table each time was pure
--- garbage. Copy the first `n` entries if you need to keep them.
--- @param cps integer[]  -the whole text, decoded
--- @param start integer  -0-based position to match from
--- @param count integer  -length of the text in characters
--- @return integer[] lengths
--- @return integer n
function Trie:prefixes(cps, start, count)
  local lengths, n = prefix_buffer, 0

  local node = self.root
  local i = start

  while i < count do
    node = node[cps[i + 1]]
    if node == nil then
      break
    end
    i = i + 1
    if node[FINAL] then
      n = n + 1
      lengths[n] = i - start
    end
  end

  return lengths, n
end

--- Every dictionary word that is a prefix of `text`.
---
--- The string-returning form of `prefixes`, for callers outside the segmenter.
--- @param text string
--- @return string[]
function Trie:prefixes_of(text)
  local cps, offsets, count = codepoints.decode(text)
  local lengths, n = self:prefixes(cps, 0, count)

  local out = {}
  for i = 1, n do
    out[i] = codepoints.slice(text, offsets, 0, lengths[i])
  end

  return out
end

--- Every word in the trie, in no particular order.
--- @return string[]
function Trie:words()
  local out, n = {}, 0
  local prefix = {}

  local function walk(node, depth)
    if node[FINAL] then
      n = n + 1
      out[n] = codepoints.encode(prefix, 1, depth)
    end
    for cp, child in pairs(node) do
      if cp ~= FINAL then
        prefix[depth + 1] = cp
        walk(child, depth + 1)
      end
    end
  end

  walk(self.root, 0)

  return out
end

M.Trie = Trie

return M
