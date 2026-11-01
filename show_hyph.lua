local M = {}

local hlist_id = node.id("hlist")
local vlist_id = node.id("vlist")
local disc_id = node.id("disc")
local glue_id = node.id("glue")

function M.setup()
  -- Intercluster glue is not a breakpoint, so it gets no mark. Read here, not
  -- at load, so thai_linebreak has created the attribute first.
  local intercluster = require("thai_linebreak").intercluster_attribute
  local show_hyph
  ---@param head Node
  show_hyph = function(head)
    while head do
      if head.id == vlist_id or head.id == hlist_id then
        ---@cast head HlistNode | VlistNode
        show_hyph(head.list)
      elseif head.id == disc_id or (head.id == glue_id and not node.has_attribute(head, intercluster)) then
        ---@cast head DiscNode | GlueNode
        local n = node.new("whatsit", "pdf_literal") ---@class WhatsitNode
        n.mode = 0
        n.data = (head.pre == nil) and "q 0.7 w 0 0 m 0 7 l S Q" or "q 0.3 w 0 3 m 0 7 l S Q"
        n.next = head.next
        n.prev = head
        head.next = n
        head = n
      end
      head = head.next
    end
    return true
  end
  luatexbase.add_to_callback("post_linebreak_filter", show_hyph, "Show hyphenations")
end

return M
