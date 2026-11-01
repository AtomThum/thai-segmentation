-- A binary min-heap, standing in for Python's `heapq`.
--
-- The heap is a plain Lua array, so `heap[1]` is always the smallest element
-- and can be read directly -- newmm's main loop does exactly that, as
-- `pos_list[0]`, to decide whether it has reached the end of the text.
--
-- newmm only ever stores distinct integers (it checks membership before
-- pushing), so this never has to answer the question heapq answers with
-- insertion order: which of two equal elements comes out first. That means the
-- internal layout is free to differ from heapq's without changing any result.
--
-- Lua's 1-based arrays make the index arithmetic differ from the textbook
-- 0-based form: for node `i` the children are `2i` and `2i + 1`, and the parent
-- is `floor(i / 2)`.

local M = {}

local floor = math.floor

--- @return integer[]
function M.new()
  return {}
end

--- Insert a value.
--- @param heap integer[]
--- @param value integer
function M.push(heap, value)
  local i = #heap + 1
  heap[i] = value

  -- Sift up while the value is smaller than its parent.
  while i > 1 do
    local parent = floor(i / 2)
    if heap[parent] <= value then
      break
    end
    heap[i] = heap[parent]
    i = parent
  end

  heap[i] = value
end

--- Remove and return the smallest value.
--- @param heap integer[]
--- @return integer?
function M.pop(heap)
  local size = #heap
  if size == 0 then
    return nil
  end

  local smallest = heap[1]

  if size == 1 then
    heap[1] = nil
    return smallest
  end

  -- Move the last element to the root, then sift it down.
  local value = heap[size]
  heap[size] = nil
  size = size - 1

  local i = 1
  while true do
    local left = 2 * i
    if left > size then
      break
    end

    local child = left
    local right = left + 1
    if right <= size and heap[right] < heap[left] then
      child = right
    end

    if heap[child] >= value then
      break
    end

    heap[i] = heap[child]
    i = child
  end

  heap[i] = value

  return smallest
end

--- The smallest value, without removing it.
--- @param heap integer[]
--- @return integer?
function M.peek(heap)
  return heap[1]
end

--- Whether a value is present.
---
--- A linear scan, matching Python's `x not in pos_list` on a heapq list. The
--- heap never holds more than a handful of positions, so an auxiliary set would
--- cost more to maintain than it saves.
--- @param heap integer[]
--- @param value integer
--- @return boolean
function M.contains(heap, value)
  for i = 1, #heap do
    if heap[i] == value then
      return true
    end
  end
  return false
end

--- @param heap integer[]
--- @return integer
function M.size(heap)
  return #heap
end

--- Check the heap property holds. Used by the tests, not by newmm.
--- @param heap integer[]
--- @return boolean
function M.is_valid(heap)
  for i = 2, #heap do
    if heap[floor(i / 2)] > heap[i] then
      return false
    end
  end
  return true
end

return M
