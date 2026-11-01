-- Python's `collections.defaultdict(list)`.
--
-- Reading a key that was never assigned gives back a fresh empty list, and --
-- this is the part that is easy to miss -- *stores* it, so that
--
--     table.insert(graph[k], v)
--
-- works without the caller first checking whether `graph[k]` exists. newmm
-- leans on exactly that when building its position graph.
--
-- The functions are on the module rather than on the instance because a
-- metatable's `__index` can be a function or a table, not both: making
-- `d:clear()` work would mean putting `clear` in the same namespace as the
-- keys. newmm's keys are integers so nothing would actually collide, but a
-- dictionary whose contents you cannot safely enumerate is a bad shape to
-- leave lying around.

local M = {}

local metatable = {
  __index = function(t, key)
    local value = {}
    rawset(t, key, value)
    return value
  end,
}

--- @return table<any, any[]>
function M.new()
  return setmetatable({}, metatable)
end

--- Remove every entry, keeping the default behaviour.
--- @param dict table
function M.clear(dict)
  for key in pairs(dict) do
    rawset(dict, key, nil)
  end
end

--- Whether a key has actually been assigned, without creating it.
--- Plain indexing cannot answer this: it would create the key as a side effect.
--- @param dict table
--- @param key any
--- @return boolean
function M.has(dict, key)
  return rawget(dict, key) ~= nil
end

return M
