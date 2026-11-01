-- Shared type shapes, for the language server.
--
-- Not required at run time and never loaded by anything. It exists so that the
-- shapes passed between the modules are written down in one place, in
-- particular the position convention, which is the single easiest thing to get
-- wrong in this package.
--
-- **Positions are Python's, not Lua's.** They are 0-based and run from 0 to
-- `count` inclusive, because that is what the algorithm being ported uses and
-- what its arithmetic assumes. Lua arrays are 1-based, so the character at
-- position `p` lives at `cps[p + 1]`. Every function taking a `position` means
-- the 0-based kind; every function taking a Lua array index means the 1-based
-- kind. Mixing them produces output that is wrong by one character, which on
-- Thai text looks almost right.

--- A decoded string: codepoint values, 1..count.
---@alias cps integer[]

--- Byte offset of each character, with `count + 1` entries. The last is
--- `#text + 1`, so characters at 0-based positions `[a, b)` are
--- `text:sub(offsets[a + 1], offsets[b + 1] - 1)`.
---@alias offsets integer[]

--- Inclusive codepoint range, as emitted by tools/export.py.
---@alias cprange { [1]: integer, [2]: integer }

--- One element of a compiled TCC rule.
---
--- `set` is built from `ranges` when the rules are loaded.
---   "set"    match one character; `optional` allows zero
---   "group"  match a sub-sequence; always optional and always last
---   "ahead"  zero-width lookahead: a character in `ranges`, or end of text
---            when `eol`
---   "eol"    zero-width end-of-text anchor
---@alias tcc_item {
---  kind: "set"|"group"|"ahead"|"eol",
---  ranges: cprange[]?,
---  set: table<integer, boolean>?,
---  items: tcc_item[]?,
---  optional: boolean?,
---  eol: boolean?,
--- }

--- One alternative of the TCC grammar: a sequence matched left to right.
---@alias tcc_rule tcc_item[]

--- The generated rule table.
---@alias tcc_rules { source: string, rules: tcc_rule[] }

--- The position graph newmm builds: start position -> reachable end positions.
--- A `defaultdict`, so reading an absent key yields (and stores) an empty list.
---@alias position_graph table<integer, integer[]>

--- A binary min-heap held in a plain array; `heap[1]` is the smallest element.
---@alias min_heap integer[]

--- One record of tests/data/expected.tsv.
---@alias golden_record { text: string, words: integer[], clusters: integer[] }
