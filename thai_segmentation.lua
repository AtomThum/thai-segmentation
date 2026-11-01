local breakpoints = require("thai_breakpoints")

local M = {}

--- Find a user-supplied file the way TeX would, falling back to the literal path.
---@param name string
---@return string
local function find_file(name)
  local found = kpse.find_file(name, "other text files") or kpse.find_file(name, "tex")
  return found or name
end

---@param opts { thai_segmentation: boolean?, interword_expansion: boolean?, show_hyph: boolean?, dictionaries: string[]?, interword_stretch: number, interword_shrink: number, intercluster_stretch: number?, tcc_min_edge: number }
function M.config(opts)
  local thai_segmentation = (opts.thai_segmentation == nil) and true or opts.thai_segmentation ---@type boolean
  local interword_expansion = (opts.interword_expansion == nil) and true or opts.interword_expansion ---@type boolean
  local show_hyph = opts.show_hyph or false ---@type boolean
  local interword_stretch = opts.interword_stretch ---@type number
  local interword_shrink = opts.interword_shrink ---@type number
  local tcc_min_edge = opts.tcc_min_edge ---@type number
  local intercluster_stretch = opts.intercluster_stretch or 0 ---@type number

  texio.write_nl("log", "[thai-segmentation] Thai segmentation is: " .. tostring(thai_segmentation))

  if thai_segmentation then
    -- Build the dictionaries now, so the cost lands here rather than inside
    -- whichever paragraph happens to be first.
    breakpoints.load()

    for _, name in ipairs(opts.dictionaries or {}) do
      M.add_words_from_file(name)
    end

    local thai_linebreak = require("thai_linebreak")
    thai_linebreak.interword_expansion = interword_expansion
    thai_linebreak.INTERWORD_EXPAND_PT = interword_stretch
    thai_linebreak.INTERWORD_SHRINK_PT = interword_shrink
    breakpoints.set_options({ min_edge = tcc_min_edge })
    M.set_intercluster_stretch(intercluster_stretch)
    thai_linebreak.enable(breakpoints)
  end

  if show_hyph then
    require("show_hyph").setup()
  end
end

--- Stretch, in pt, of the glue between clusters inside a word; 0 or less turns
--- it off, so nothing but the plain break points is inserted. Called from the
--- intercluster-stretch key and from \ThaiInterclusterStretch.
---@param value number
function M.set_intercluster_stretch(value)
  require("thai_linebreak").INTERCLUSTER_STRETCH_PT = value
  breakpoints.set_options({ clusters = value > 0 })
end

---------------------------------------------------------------------------
-- dictionary edits, called from \ThaiAddWords and friends
--
-- They act on the paragraph being built too: segmentation happens in the
-- `hyphenate` callback, when a paragraph ends.
---------------------------------------------------------------------------

---@param words string[]
function M.add_words(words)
  breakpoints.add_words(words)
end

---@param words string[]
function M.remove_words(words)
  breakpoints.remove_words(words)
end

---@param name string
function M.add_words_from_file(name)
  local path = find_file(name)
  local added = breakpoints.add_words_from_file(path)
  texio.write_nl("log", string.format("[thai-segmentation] %d words added from %s", added, path))
end

---@param syllables string[]
function M.add_syllables(syllables)
  breakpoints.add_syllables(syllables)
end

---@param syllables string[]
function M.remove_syllables(syllables)
  breakpoints.remove_syllables(syllables)
end

--- Fix the break points of words, e.g. `ไฮ-เซน-เบิร์ก`; see thai_breakpoints.
---@param entries string[]
function M.hyphenation(entries)
  breakpoints.add_hyphenations(entries)
end

---@param entries string[]
function M.remove_hyphenation(entries)
  breakpoints.remove_hyphenations(entries)
end

--- Split a comma-separated list from TeX into trimmed, non-empty items.
---@param csv string
---@return string[]
function M.split_list(csv)
  local out = {}
  for item in (csv .. ","):gmatch("([^,]*),") do
    item = item:match("^%s*(.-)%s*$")
    if item ~= "" then
      out[#out + 1] = item
    end
  end
  return out
end

return M
