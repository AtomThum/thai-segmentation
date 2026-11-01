-- Loading the word list and holding the shared dictionary.
--
-- The package ships PyThaiNLP's `words_th.txt` verbatim -- 62,101 entries, one
-- per line -- and builds a trie from it on first use. Plain text rather than
-- some packed format because it is the form the corpus is published in, it is
-- what a user will want to diff or extend, and reading it costs about 0.04 s
-- against 0.08 s to build the trie, so a cleverer format would be optimising
-- the wrong third of a fifth of a second.
--
-- Loading is lazy. A document that turns out to contain no Thai never pays for
-- it.

local trie = require("newmm.trie")

local M = {}

M.WORDS_FILE = "words_th.txt"

--- PyThaiNLP's syllable list, which `syllable_tokenize(engine="dict")`
--- segments against. Used by the linebreaker to choose hyphenation points
--- inside long words; newmm itself never reads it.
M.SYLLABLES_FILE = "syllables_th.txt"

--- Directory this package was loaded from, with a trailing separator.
---
--- Resolved at require time, not on first use: a LuaTeX run may change
--- directory in between, and the path recorded here can be relative.
--- @return string?
local function module_path()
  -- LuaTeX strips `debug.getinfo` unless run with --luadebug, so it cannot be
  -- relied on inside a document build.
  if debug and debug.getinfo then
    local source = debug.getinfo(1, "S").source
    return source:match("^@(.*)$") -- nil if loaded from a string or a stripped chunk
  end

  if kpse then
    local ok, found = pcall(kpse.find_file, "newmm/dictionary.lua", "lua")
    if ok and found then
      return found
    end
  end

  if package.searchpath then
    return package.searchpath("newmm.dictionary", package.path)
  end

  return nil
end

--- @return string?
local function package_root()
  local path = module_path()
  if not path then
    return nil
  end

  local root = path:gsub("newmm[/\\]dictionary%.lua$", "")
  if root == path then
    return nil
  end

  return root == "" and "./" or root
end

local PACKAGE_ROOT = package_root()

--- Explicitly configured paths, by file name.
--- @type table<string, string?>
local configured_paths = {
  [M.WORDS_FILE] = os.getenv("NEWMM_WORDS"),
  [M.SYLLABLES_FILE] = os.getenv("NEWMM_SYLLABLES"),
}

--- @param path string
--- @return boolean
local function readable(path)
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

--- Locate a shipped list.
--- @param name string  -file name, e.g. `M.WORDS_FILE`
--- @return string
local function resolve(name)
  local tried = {}

  local configured_path = configured_paths[name]
  if configured_path then
    if readable(configured_path) then
      return configured_path
    end
    tried[#tried + 1] = configured_path
  end

  if PACKAGE_ROOT then
    local path = PACKAGE_ROOT .. "data/" .. name
    if readable(path) then
      return path
    end
    tried[#tried + 1] = path
  end

  if kpse then
    -- Guarded: `kpse` exists but is uninitialised in a bare `texlua script.lua`,
    -- where calling it raises "Please call kpse.set_program_name()" and would
    -- bury the useful message below.
    local ok, found = pcall(function()
      return kpse.find_file(name, "other text files") or kpse.find_file(name)
    end)
    if ok and found then
      return found
    end
    tried[#tried + 1] = "kpse:" .. name
  end

  local hint = name == M.SYLLABLES_FILE and "Set NEWMM_SYLLABLES or call newmm.setup{ syllables = ... }."
    or "Set NEWMM_WORDS or call newmm.setup{ words = ... }."

  error(
    "newmm: cannot find the word list '"
      .. name
      .. "'. Looked in: "
      .. (#tried > 0 and table.concat(tried, ", ") or "<nowhere>")
      .. ". "
      .. hint,
    0
  )
end

--- Use a specific word list file instead of the shipped one.
--- @param path string
function M.set_path(path)
  configured_paths[M.WORDS_FILE] = path
end

--- Use a specific syllable list file instead of the shipped one.
--- @param path string
function M.set_syllables_path(path)
  configured_paths[M.SYLLABLES_FILE] = path
end

--- Read a word list: one word per line, blank lines ignored.
---
--- A leading `#` is *not* treated as a comment. The dictionary legitimately
--- contains punctuation, and silently dropping entries from a user's custom
--- list would be worse than requiring them to keep it clean.
--- @param path string
--- @return string[], integer
function M.read_words(path)
  local f = assert(io.open(path, "rb"), "newmm: cannot open word list " .. path)

  local words, n = {}, 0
  for line in f:lines() do
    -- Tolerate CRLF, which a word list edited on Windows will have.
    local word = line:match("^%s*(.-)%s*$")
    if word ~= "" then
      n = n + 1
      words[n] = word
    end
  end

  f:close()

  return words, n
end

local shared
local shared_syllables

--- The shared dictionary, built on first use.
--- @return Trie
function M.default()
  if not shared then
    local words = M.read_words(resolve(M.WORDS_FILE))
    shared = trie.new(words, true)
  end
  return shared
end

--- Replace the shared dictionary.
--- @param dictionary Trie
function M.set_default(dictionary)
  shared = dictionary
end

--- Drop the shared dictionary so the next use rebuilds it.
function M.reset()
  shared = nil
end

--- The shared syllable dictionary, built on first use.
--- @return Trie
function M.syllables()
  if not shared_syllables then
    local words = M.read_words(resolve(M.SYLLABLES_FILE))
    shared_syllables = trie.new(words, true)
  end
  return shared_syllables
end

--- Drop the shared syllable dictionary so the next use rebuilds it.
function M.reset_syllables()
  shared_syllables = nil
end

return M
