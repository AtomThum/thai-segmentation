-- UTF-8 decoding.
--
-- Everything in this package indexes by codepoint, not by byte, because the
-- Python it is ported from does: `len(text)`, `text[i]` and `text[a:b]` all
-- count characters, and the TCC boundary array and the trie walk are both
-- indexed in those units. Working in bytes would not merely be slower to
-- reason about, it would produce different answers.
--
-- Not the standard `utf8` library, for two reasons. `utf8.codepoint` raises on
-- malformed input, and a document build should not die because one byte of one
-- paragraph got mangled somewhere upstream; and avoiding it means this runs
-- unchanged on Lua 5.1 and LuaJIT, which have no `utf8` table at all.
--
-- Positions follow Python's convention throughout: 0-based, running from 0 to
-- `count`, so that a slice `[a, b)` is the characters at 0-based positions a
-- through b-1. Lua's arrays are 1-based, so character at position `p` is
-- `cps[p + 1]`. The `offsets` array makes the conversion back to bytes cheap.

local M = {}

local byte, sub, char = string.byte, string.sub, string.char
local floor = math.floor

--- Decode a string into codepoints.
---
--- Malformed sequences -- a stray continuation byte, a truncated multi-byte
--- sequence at the end of the string -- are reported as one single-byte
--- character each. That keeps `decode` total, and keeps `slice` below able to
--- reproduce the input exactly whatever it is handed.
--- @param text string
--- @return integer[] cps  -codepoint values, 1..count
--- @return integer[] offsets  -byte offset of each character; count+1 entries
--- @return integer count
function M.decode(text)
  local cps, offsets, n = {}, {}, 0
  local i, len = 1, #text

  while i <= len do
    local b = byte(text, i)
    local cp, width

    if b < 0x80 then
      cp, width = b, 1
    elseif b < 0xC0 then
      -- Continuation byte with no lead: not a character, but pass it through.
      cp, width = b, 1
    elseif b < 0xE0 then
      local b2 = byte(text, i + 1)
      if b2 then
        cp, width = (b - 0xC0) * 0x40 + b2 % 0x40, 2
      else
        cp, width = b, 1
      end
    elseif b < 0xF0 then
      local b2, b3 = byte(text, i + 1), byte(text, i + 2)
      if b2 and b3 then
        cp, width = (b - 0xE0) * 0x1000 + (b2 % 0x40) * 0x40 + b3 % 0x40, 3
      else
        cp, width = b, 1
      end
    elseif b < 0xF5 then
      local b2, b3, b4 = byte(text, i + 1), byte(text, i + 2), byte(text, i + 3)
      if b2 and b3 and b4 then
        cp = (b - 0xF0) * 0x40000 + (b2 % 0x40) * 0x1000 + (b3 % 0x40) * 0x40 + b4 % 0x40
        width = 4
      else
        cp, width = b, 1
      end
    else
      -- 0xF5 and above cannot begin a valid sequence -- the largest codepoint
      -- is U+10FFFF, which leads with 0xF4. Consuming three bytes after one
      -- would swallow whatever legitimately follows.
      cp, width = b, 1
    end

    n = n + 1
    cps[n] = cp
    offsets[n] = i
    i = i + width
  end

  offsets[n + 1] = len + 1

  return cps, offsets, n
end

--- The substring covering 0-based character positions `[from, to)`.
--- @param text string
--- @param offsets integer[]  -from `M.decode`
--- @param from integer
--- @param to integer
--- @return string
function M.slice(text, offsets, from, to)
  return sub(text, offsets[from + 1], offsets[to + 1] - 1)
end

--- Encode one codepoint as UTF-8.
---
--- Canonical, which means it is *not* an inverse of `decode` for malformed
--- input: `decode` reports a stray 0x80 byte as codepoint 0x80, and encoding
--- that back gives the two-byte sequence C2 80. That asymmetry is fine because
--- nothing reconstructs text this way -- tokens are cut from the original
--- string with `slice`, which works from byte offsets and is therefore exact
--- whatever the input. `encode` exists for `Trie:words()`, whose codepoints
--- came from well-formed dictionary entries.
--- @param cp integer
--- @return string
function M.char(cp)
  if cp < 0x80 then
    return char(cp)
  elseif cp < 0x800 then
    return char(0xC0 + floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return char(
      0xE0 + floor(cp / 0x1000),
      0x80 + floor(cp / 0x40) % 0x40,
      0x80 + cp % 0x40
    )
  end
  return char(
    0xF0 + floor(cp / 0x40000),
    0x80 + floor(cp / 0x1000) % 0x40,
    0x80 + floor(cp / 0x40) % 0x40,
    0x80 + cp % 0x40
  )
end

--- Encode an array of codepoints as UTF-8.
--- @param cps integer[]
--- @param from integer?  -1-based, inclusive
--- @param to integer?  -1-based, inclusive
--- @return string
function M.encode(cps, from, to)
  local parts = {}
  local at = 0
  for i = from or 1, to or #cps do
    at = at + 1
    parts[at] = M.char(cps[i])
  end
  return table.concat(parts)
end

return M
