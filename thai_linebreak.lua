local M = {}

-- The table `runs` contains a single node tree.
-- Each sentence inside the paragraph is called a `run`, which is nested inside `runs`
-- A `run` contains { kind: str, text: str, first: node }
---@source types_annotations.lua

local glyph_id = node.id("glyph") ---@type integer
local glue_id = node.id("glue") ---@type integer

local utf8_char = utf8.char

local HYPHEN_CHAR = 0x2D ---@type integer (Represents the - character)
M.WORD_BOUNDARY_PENALTY = 0 ---@type integer (Self-explanatory)
M.INTERWORD_EXPAND_PT = 1 ---@type number (Stretch of the glue between words; matches the interword-stretch key)
M.INTERWORD_SHRINK_PT = 0.5 ---@type number (Shrink of the glue between words; matches the interword-shrink key)
M.INTERCLUSTER_STRETCH_PT = 0 ---@type number (Stretch of the glue between clusters inside a word; 0 means none)
M.interword_expansion = true ---@type boolean (Word boundaries become stretchable glue rather than plain break points)

--- Marks intercluster glue, so show_hyph can tell it from glue that is a break.
M.intercluster_attribute = luatexbase.new_attribute("thaiseg_intercluster") ---@type integer

---@param cp integer
---@return boolean
local function is_thai_codepoint(cp)
  return (cp >= 0x0E01 and cp <= 0x0E3A) or (cp >= 0x0E3F and cp <= 0x0E5B)
end
M.is_thai_codepoint = is_thai_codepoint

---@param kind string
---@return boolean
local function is_glyph_run(kind)
  return kind == "thai" or kind == "other"
end

--- Extract a paragraph's node list from hyphenate callback.
---
--- Thai runs carry their text and codepoints, which the segmenter needs; other
--- runs only their ends, which is all `lang.hyphenate` needs.
---@param head Node  -- first node of the paragraph's node list
---@return table -- array of runs: { kind, text, cps, first, last, glyph_count }
function M.extract_runs(head)
  local current = nil ---@type run
  local runs = {} ---@type runs

  -- Push current character list to runs and clear character
  local function flush_paragraph()
    if current then
      runs[#runs + 1] = {
        kind = current.kind,
        text = current.chars and table.concat(current.chars) or "",
        cps = current.cps,
        first = current.first,
        last = current.last,
        glyph_count = current.glyph_count,
      }
      current = nil
    end
  end

  -- Walks the node tree and extracts Thai paragraphs
  local n = head ---@type Node
  while n do
    --- Check node types for the following cases:
    --- 1. Glyph Node
    --- 2. Glue Node (spaces)
    --- 3. Other Nodes

    if (n.id == glyph_id) and (n.subtype == 1) then
      ---@cast n GlyphNode

      local cp = n.char
      local kind = is_thai_codepoint(cp) and "thai" or "other" ---@type string

      -- Iterate over sentences, extracting Thai texts
      if current and current.kind == kind then
        local count = current.glyph_count + 1
        if current.chars then
          current.chars[count] = utf8_char(cp)
          current.cps[count] = cp
        end
        current.last = n
        current.glyph_count = count
      -- If the node tree ended or the language changes, flush to runs and update current node
      else
        flush_paragraph()
        local thai = kind == "thai"
        current = {
          kind = kind,
          chars = thai and { utf8_char(cp) } or nil,
          cps = thai and { cp } or nil,
          first = n,
          last = n,
          glyph_count = 1,
        }
      end

    -- If the sentence ended in a space, flush to runs and add a space in runs
    elseif n.id == glue_id then
      ---@cast n GlueNode

      flush_paragraph()
      runs[#runs + 1] = {
        kind = "space",
        text = " ",
        first = n,
        last = n,
        glyph_count = 0,
      }

    -- If anything else happens, flush to runs and add a node in runs
    else
      flush_paragraph()
      runs[#runs + 1] = {
        kind = "node",
        text = "",
        first = n,
        last = n,
        glyph_count = 0,
      }
    end
    n = n.next
  end
  flush_paragraph()

  return runs
end

---@return DiscNode
local function make_word_boundary_node()
  local d = node.new("disc") ---@class DiscNode
  d.subtype = 0
  d.penalty = M.WORD_BOUNDARY_PENALTY
  return d
end

---@return DiscNode
local function make_hyphen_node(template)
  local d = node.new("disc") ---@class DiscNode
  d.subtype = 2
  d.penalty = tex.hyphenpenalty

  local h = node.new("glyph") ---@class GlyphNode
  h.char = HYPHEN_CHAR
  h.subtype = 1
  h.font = template.font
  h.lang = template.lang
  h.left = template.left
  h.right = template.right
  h.uchyph = template.uchyph

  d.pre = h
  return d
end

---@param stretch_pt number
---@param shrink_pt number
---@return GlueNode
local function make_glue_node(stretch_pt, shrink_pt)
  local g = node.new("glue") ---@class GlueNode
  g.width = 0
  g.stretch = math.floor(stretch_pt * 65536)
  g.stretch_order = 0
  g.shrink = math.floor(shrink_pt * 65536)
  g.shrink_order = 0
  return g
end

--- Stretch between two clusters of one word, which must never become a break.
---
--- A disc cannot hold glue, so the glue goes beside it instead, behind a
--- `\penalty10000`. Glue is a legal breakpoint only after a non-discardable
--- node; after the penalty it is not one, and the penalty itself forbids a break.
--- Where a hyphenation disc precedes the pair and TeX breaks there, both are
--- discardable and vanish from the start of the next line.
---@param head Node
---@param at Node
---@return Node head, Node last
local function insert_intercluster(head, at)
  local p = node.new("penalty") ---@class PenaltyNode
  p.penalty = 10000
  head, at = node.insert_after(head, at, p)

  local g = make_glue_node(M.INTERCLUSTER_STRETCH_PT, 0)
  node.set_attribute(g, M.intercluster_attribute, 1)
  return node.insert_after(head, at, g)
end

--- Splice word boundaries, hyphenation discs and (optionally) intercluster glue
--- into one Thai run's glyph chain, following the plan computed for it
--- (thai_breakpoints.plan). Mutates the paragraph's node list in place.
--- @param head Node  the paragraph's node list head (needed by node.insert_after -- not just this run's nodes)
--- @param run table  a `kind == "thai"` run
--- @param plan { ends: integer[], breaks: integer[], clusters: integer[]? }
--- @return Node  the (possibly updated) paragraph head
function M.insert_breaks(head, run, plan)
  local ends, breaks, clusters = plan.ends, plan.breaks, plan.clusters
  local count = run.glyph_count

  if ends[#ends] ~= count then
    texio.write_nl("term and log", "[thai-linebreak] warning: segmentation doesn't cover the run, skipping: " .. run.text)
    return head
  end

  local ei, bi, ci = 1, 1, 1
  local nb, nc = #breaks, clusters and #clusters or 0

  local curr = run.first ---@type Node
  for pos = 1, count do
    local glyph = curr
    curr = curr.next
    local at = glyph

    if pos == ends[ei] then
      ei = ei + 1
      if pos < count then
        --- Choose whether the word will be a break or a stretch glue node
        local boundary = M.interword_expansion and make_glue_node(M.INTERWORD_EXPAND_PT, M.INTERWORD_SHRINK_PT)
          or make_word_boundary_node()
        head = node.insert_after(head, at, boundary)
      end
    else
      if bi <= nb and breaks[bi] == pos then
        head, at = node.insert_after(head, at, make_hyphen_node(glyph))
      end
      if ci <= nc and clusters[ci] == pos then
        head, at = insert_intercluster(head, at)
      end
    end

    while bi <= nb and breaks[bi] <= pos do
      bi = bi + 1
    end
    while ci <= nc and clusters[ci] <= pos do
      ci = ci + 1
    end
  end

  return head
end

--- Delegate an `other` (non-Thai) run to LuaTeX's own automatic
--- hyphenation. Needed because registering *any* `hyphenate` handler
--- replaces the engine's built-in Liang-pattern algorithm for every
--- language, not just Thai (Phase 0 finding) -- without this, Latin/etc.
--- text would silently get zero hyphenation now that we own the
--- callback. `lang.hyphenate` reads whatever `.lang` is already baked
--- into each glyph node, so no language parameter is needed here; it's a
--- no-op (not an error) if no patterns are loaded for that language.
--- @param run table  a `kind == "other"` run
function M.hyphenate_other_run(run)
  lang.hyphenate(run.first, run.last)
end

--- Add a low-penalty break opportunity at any boundary between two
--- glyph-bearing runs (`thai` or `other`) that have no `space` run
--- between them -- e.g. a Thai sentence directly abutting a digit or
--- Latin acronym with no space (`100บาท`). "Add a space" means a
--- break point, not a literal character -- reuses the same word-boundary
--- disc as intra-Thai-run word breaks (penalty 0, no visible pre/post).
--- Safe to run after all other insertion for this paragraph: it only
--- touches the single edge between two runs' `last`/`first`, which
--- neither `insert_breaks` nor `lang.hyphenate` ever inserts
--- into (they only insert strictly *within* their own run).
--- @param head Node
--- @param runs table  the full run array for one paragraph
--- @return Node  the (possibly updated) paragraph head
function M.insert_junction_breaks(head, runs)
  for i = 1, #runs - 1 do
    if is_glyph_run(runs[i].kind) and is_glyph_run(runs[i + 1].kind) then
      head = (node.insert_after(head, runs[i].last, make_word_boundary_node()))
    end
  end
  return head
end

--- Take over the `hyphenate` callback.
--- @param segmenter { plan: fun(text: string, cps: integer[]?, count: integer?): table }  -normally thai_breakpoints
function M.enable(segmenter)
  luatexbase.add_to_callback("hyphenate", function(head, tail)
    local runs = M.extract_runs(head)

    for _, run in ipairs(runs) do
      if run.kind == "thai" then
        head = M.insert_breaks(head, run, segmenter.plan(run.text, run.cps, run.glyph_count))
      elseif run.kind == "other" then
        M.hyphenate_other_run(run)
      end
    end

    head = M.insert_junction_breaks(head, runs)
  end, "thai_linebreak")
end

return M
