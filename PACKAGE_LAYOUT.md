# How thai-segmentation works

This file is for people working on the package. The user documentation is in
`README.md`.

## Layout

```text
thai-segmentation.sty       LaTeX interface: options, user commands
thai_segmentation.lua       Lua entry point: config, dictionary edits, file lookup
thai_linebreak.lua          the `hyphenate` callback: extracts runs, inserts nodes
thai_breakpoints.lua        what to insert where, per Thai run (no `node`/`tex`)
show_hyph.lua               debug marks at break points (the show-hyph option)
newmm.lua                   newmm word segmenter: public interface and the search
newmm/
  tcc.lua                   Thai Character Clusters: compiles and runs the rules
  tcc_rules.lua             generated -- the parsed TCC grammar
  digits.lua                generated -- codepoints Python's \d matches
  patterns.lua              the two non-TCC regexes newmm uses, as matchers
  trie.lua                  dictionary trie keyed by codepoint
  heap.lua                  binary min-heap
  defaultdict.lua           Python's defaultdict(list)
  codepoints.lua            UTF-8 decoding, slicing and encoding
  dictionary.lua            finding and loading the word and syllable lists
  types_annotations.lua     LuaLS type annotations
types_annotations.lua       LuaLS type annotations for the run tables
data/
  words_th.txt              PyThaiNLP's 62,101-word list
  syllables_th.txt          PyThaiNLP's 10,322-syllable list
tools/
  export.py                 PyThaiNLP -> tcc_rules.lua, digits.lua, syllables_th.txt
  make_golden.py            records upstream newmm/TCC output into tests/data/
  make_breakpoints_golden.py    records the old Python worker's break points
tests/
  run.lua                   test suite, runs under plain texlua
  data/                     corpora and recorded expected output
docs/
  main.tex                  Thai user manual
```

The modules are layered so that only the top two touch LuaTeX:

```text
thai-segmentation.sty
  └─ thai_segmentation.lua        (kpse, texio)
       ├─ thai_linebreak.lua       (node, tex, lang, luatexbase)
       ├─ show_hyph.lua            (node, luatexbase)
       └─ thai_breakpoints.lua     (pure Lua)
            └─ newmm.lua           (pure Lua)
                 └─ newmm/*
```

`thai_breakpoints` and everything below it use only the Lua standard library, so
they are tested under plain `texlua` with no TeX run.

## Start-up

`\usepackage{thai-segmentation}`:

1. Stops with a fatal error unless the engine is LuaTeX.
2. Reads the options with `l3keys` and passes them to `thai_segmentation.config`
   in one `\lua_now:e` call.
3. If `thai-segmentation` is on, `config`:
   - builds both dictionaries at once (`thai_breakpoints.load()`), so the cost
     (about 0.1 s) falls at package load instead of inside the first paragraph;
   - loads each `dictionary=` file, found with
     `kpse.find_file(name, "other text files")`, then `"tex"`, then as a literal
     path;
   - copies the stretch, shrink and expansion settings onto `thai_linebreak`,
     and `tcc-min-edge` and whether cluster glue is on into `thai_breakpoints`;
   - registers the `hyphenate` callback (`thai_linebreak.enable`).
4. If `show-hyph` is on, registers a `post_linebreak_filter` (see
   [show-hyph](#show-hyph)).

The user commands (`\ThaiAddWords` and the others) all go through
`\__thaiseg_call:nn`, which escapes the argument, splits it on commas with
`thai_segmentation.split_list` (items are trimmed and empty ones are dropped),
and calls the matching Lua function.

The word list and the syllable list are found by trying, in order:
`newmm.setup{ words = ... }` or `$NEWMM_WORDS` (`syllables` and
`$NEWMM_SYLLABLES` for the syllable list), then `data/<file>` next to the
`newmm/` directory, then `kpse`.

## The paragraph pipeline

Everything happens in the `hyphenate` callback. LuaTeX calls it with the
unhyphenated node list of every paragraph, and of every `\hbox`, before
ligatures and kerning are applied. At that point the glyphs are still plain
characters (glyph subtype 1).

```text
hyphenate(head)
  │
  ├─ extract_runs(head)              split the list into thai / other / space / node runs
  │
  ├─ for each run:
  │    thai  → plan = thai_breakpoints.plan(text, cps, count)
  │              ├─ newmm.segment_positions(cps, count)   → word ends + TCC flags
  │              ├─ word_breaks(word) for long words      → hyphenation points
  │              └─ TCC flags inside words                → cluster boundaries
  │            insert_breaks(head, run, plan)            → glue / disc / penalty nodes
  │    other → lang.hyphenate(first, last)               → TeX's own patterns
  │
  └─ insert_junction_breaks(head, runs)   break points where thai meets other
```

Registering any `hyphenate` handler replaces LuaTeX's built-in pattern
hyphenation for every language, not only Thai. That is why non-Thai runs are
passed back to `lang.hyphenate` explicitly.

### 1. Extracting runs (`thai_linebreak.extract_runs`)

The node list is walked once, from `head` along `.next`. Only the top level of
the list is visited; the callback is called separately for the contents of each
box. Each node starts or extends a **run**:

| Node                                  | Run kind | What is kept                                                       |
| ------------------------------------- | -------- | ------------------------------------------------------------------ |
| glyph, subtype 1, Thai codepoint      | `thai`   | `text` (UTF-8), `cps` (codepoints), `first`, `last`, `glyph_count` |
| glyph, subtype 1, any other codepoint | `other`  | `first`, `last`, `glyph_count` only                                |
| glue (interword space)                | `space`  | the node itself                                                    |
| anything else                         | `node`   | the node itself                                                    |

Thai codepoints are U+0E01–U+0E3A and U+0E3F–U+0E5B, which includes the Thai
digits and the signs ฯ and ๆ.

Consecutive glyphs of the same kind are joined into one run. Any change of kind,
and any non-glyph node, ends the current run. So a Thai run is always an
unbroken chain of Thai glyph nodes, linked directly by `.next`, with
`glyph_count` nodes from `first` to `last`. A Thai run never contains spaces or
newlines. Font changes insert no nodes, so a run can span them. Anything that
does insert a node (a colour whatsit, a kern, a box, a penalty, math) splits the
run.

Codepoints are read straight from `glyph.char`, so the Thai text is never
decoded from UTF-8 again. The UTF-8 `text` is built only to serve as the cache
key and for the warning message.

### 2. Planning a Thai run (`thai_breakpoints.plan`)

`plan(text, cps, count)` returns all the insertion points for one run as 0-based
character offsets into the run. Offset `p` means "after the `p`-th character":

```lua
{
  ends     = { ... },  -- end of each word; the last entry equals count
  breaks   = { ... },  -- hyphenation points, ascending
  clusters = { ... },  -- cluster boundaries inside words, ascending; nil when off
}
```

Plans are cached in a table keyed by the run's text. LuaTeX hyphenates every
paragraph, `\hbox`, running head and trial typesetting pass, so the same text is
often seen many times. The plan depends on the dictionaries and the options as
well as the text, so every dictionary edit and every `set_options` call empties
the cache.

The returned table is shared with the cache. Callers must not modify it.

### 3. Calling newmm for word boundaries

`plan` calls `newmm.segment_positions(cps, count)`. It takes the codepoint array
that came from the glyph nodes and returns two arrays:

- `ends`: the end offset of each word. The last entry is `count`.
- `valid`: TCC boundary flags. `valid[p + 1]` is true when offset `p` ends a
  Thai Character Cluster.

Both come from `onecut` in `newmm.lua`, a direct port of upstream's `_onecut`.
Upstream returns substrings; this version returns end positions, so no string is
built per word. `newmm.segment(text)`, the string interface, is `onecut` plus
cutting the text at those positions.

`onecut` works like this:

1. **Cluster flags.** `tcc.boundary_flags` walks the text one cluster at a time
   and marks the end of each one. A word may only end where a cluster ends.
2. **Search.** A min-heap holds positions the segmentation might reach, starting
   with `{0}`. Each step pops the smallest position `b` and asks the trie for
   every dictionary word starting at `b` (`Trie:prefixes`, one walk down the
   trie, returning word lengths shortest first). Each word that ends on a
   cluster boundary is added as an edge `b → b + length` in a graph, and its end
   is pushed onto the heap if it is not already there. The graph stops growing
   after `MAX_GRAPH_SIZE` (50) edges.
3. **Collapse.** When only one position is left on the heap, every path must go
   through it. The graph is resolved with a breadth-first search from the last
   emitted position to that one. BFS finds the path with the fewest edges (the
   fewest words), and ties go to the edge added first, which is the shorter
   word. The path's positions are emitted as word ends, and the graph is
   cleared.
4. **No dictionary match.** When the heap is empty after a step, nothing in the
   dictionary starts at `b`. Then:
   - if `patterns.nonthai` matches at `b` (a Latin word, a number such as
     `1,000.5`, spaces, a newline, or a run of other non-Thai characters), the
     token ends where that match ends;
   - otherwise the text is scanned forward for the first cluster boundary that
     could start a token: a position that starts a dictionary word longer than
     two Thai consonants ending on a cluster boundary, or that starts a non-Thai
     match. If there is none, the token runs to the end of the text.

   That end is emitted as a word end and pushed back onto the heap.

5. The loop stops when the smallest position on the heap reaches `count`.

Concatenating the words always gives back the original text, even for malformed
input. Where upstream would raise `StopIteration`, the port emits the span as
one word instead, because losing text from a paragraph is worse than a bad
split.

Inside the package, Thai runs reach newmm already free of spaces and Latin text,
so the non-Thai branch mostly handles Thai digits, punctuation and characters
that are not in any word.

Before inserting anything, `insert_breaks` checks that the last entry of `ends`
equals the run's glyph count. If it does not, the run is left untouched and a
warning is written to the terminal and the log. With the guarantee above this
should never happen.

### 4. Hyphenation points (`word_breaks`)

For each word in `ends`:

- If the user fixed the word with `\ThaiHyphenation`, those offsets are used as
  they are, with no `tcc-min-edge` filter. An entry with no hyphens gives an
  empty list, so the word is never hyphenated.
- Otherwise, only words longer than `TCC_THRESHOLD` (5) characters get
  hyphenation points:
  1. The word is segmented again with newmm, this time against the **syllable**
     dictionary. This is what PyThaiNLP calls
     `syllable_tokenize(engine="dict")`.
  2. Each syllable longer than `SYLLABLE_SPLIT_THRESHOLD` (4) characters is
     split further into TCC clusters.
  3. The end offset of each piece is a candidate. The last one, the end of the
     word, is dropped because it is a word boundary.
  4. Candidates closer than `TCC_MIN_EDGE` to either end of the word are dropped
     (`min_edge <= pos <= length - min_edge`).

Step 1 to 3 depend only on the word and the syllable dictionary, so they are
memoised per word. That memo survives word-dictionary edits and is cleared only
by syllable edits. The offsets are relative to the word; `plan` adds the word's
start offset.

The rules are the same as the old Python worker.
`tests/data/expected-breakpoints.tsv` records that worker's output, and the test
suite checks the Lua code against it.

### 5. Cluster boundaries

Only when `intercluster-stretch` is positive (`thai_breakpoints.clusters` is
true). For each word, every offset strictly inside the word whose `valid` flag
is set is a cluster boundary. These come from the same flags newmm already
computed, so there is no second TCC pass.

### Worked example

For `มหาวิทยาลัยเทคโนโลยี` with the default options and cluster glue on:

```text
newmm words      มหาวิทยาลัย | เทคโนโลยี
ends             11, 20
syllables        มหา | วิทยา | ลัย       เทค | โน | โล | ยี
  วิทยา > 4      → TCC: วิ | ท | ยา
word offsets     3, 5, 6, 8, (11)       3, 5, 7, (9)
breaks           3, 5, 6, 8             14, 16, 18
TCC clusters     ม|หา|วิ|ท|ยา|ลัย | เท|ค|โน|โล|ยี
clusters         1, 3, 5, 6, 8          13, 14, 16, 18
```

The end of each word (11 and 9) is dropped from the hyphenation points. Offset
20 is the end of the run, so no node is inserted there.

### 6. Inserting nodes (`thai_linebreak.insert_breaks`)

`insert_breaks` walks the run's glyphs from `run.first`, one character per
offset (`pos` from 1 to `glyph_count`), with one index into each of `ends`,
`breaks` and `clusters`. All three are ascending, so the whole run takes one
pass. The next glyph is read before anything is inserted, so new nodes are never
visited as glyphs. Nodes are inserted with `node.insert_after` on the
paragraph's `head`, which is returned to the callback.

After the glyph at offset `pos`:

- If `pos` is a word end and not the end of the run, a **word boundary** is
  inserted. Hyphenation and cluster points at a word end are skipped.
- Otherwise, if `pos` is in `breaks`, a **hyphenation disc** is inserted; then,
  if `pos` is in `clusters`, a **cluster pair** is inserted after it.

| Insertion                   | Nodes                                                                                                                    | Line-breaking behaviour                                                             |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------- |
| word boundary, expansion    | `glue` width 0, stretch `interword-stretch` pt, shrink `interword-shrink` pt                                             | breakable at no cost (glue after a glyph); stretches and shrinks in justified lines |
| word boundary, no expansion | `disc` subtype 0, empty `pre`/`post`/`replace`, penalty `WORD_BOUNDARY_PENALTY` (0)                                      | breakable at no cost; prints nothing                                                |
| hyphenation point           | `disc` subtype 2 (automatic), `pre` = a `-` glyph, penalty `\hyphenpenalty`                                              | breakable; prints `-` at the end of the line                                        |
| cluster pair                | `penalty` 10000, then `glue` width 0, stretch `intercluster-stretch` pt, no shrink, attribute `thaiseg_intercluster` = 1 | never breakable                                                                     |

Details:

- The hyphen glyph copies `font`, `lang`, `left`, `right` and `uchyph` from the
  glyph before it, so it is set in the same font as the word.
- `\hyphenpenalty` is read when the paragraph is hyphenated, so its value at the
  end of the paragraph is what counts.
- A disc cannot hold glue, so cluster glue goes next to it. Glue is only a legal
  break after a non-discardable node. Here it follows a penalty, which is
  discardable, and the penalty of 10000 forbids a break at itself. When a
  hyphenation disc comes before the pair and TeX breaks at the disc, both the
  penalty and the glue are discardable and disappear from the start of the next
  line.
- The attribute on cluster glue lets `show_hyph` tell it apart from glue that is
  a break point.

For the example above, the node list around the first word becomes:

```text
ม [pen+glue] ห า [disc-] [pen+glue] วิ [disc-] [pen+glue] ท [disc-] [pen+glue] ย า [disc-] [pen+glue] ลั ย [interword glue] เ [pen+glue] ท ...
```

### 7. Non-Thai runs

`other` runs are passed to `lang.hyphenate(first, last)`. That uses the `lang`
already stored in each glyph, so Latin text in a Thai document is hyphenated
with whatever patterns its language has, exactly as without this package. It
does nothing if no patterns are loaded.

### 8. Junction breaks (`insert_junction_breaks`)

After every run is processed, an empty word-boundary disc (penalty 0) is
inserted between any two glyph runs (`thai` or `other`) that touch with no
`space` or `node` run between them, for example `100บาท` or `ABCภาษาไทย`. This
step comes last because it only inserts after a run's `last` node, where neither
`insert_breaks` nor `lang.hyphenate` inserts anything.

## Dictionary edits and caches

There are three caches in `thai_breakpoints`:

| Cache    | Key      | Cleared by                                                       |
| -------- | -------- | ---------------------------------------------------------------- |
| `plans`  | run text | any word, syllable or hyphenation edit, any `set_options` call   |
| `memo`   | word     | syllable edits only                                              |
| `custom` | word     | holds `\ThaiHyphenation` entries; changed only by those commands |

Edits change the shared tries in place (`Trie:add`, `Trie:remove`).
`\ThaiHyphenation` also adds the word to the word dictionary, so newmm keeps it
in one piece; `\ThaiRemoveHyphenation` leaves it there.

Because segmentation runs at the end of a paragraph, an edit affects the whole
paragraph it is in, including text before the command. Lists that were already
hyphenated, such as boxes built earlier, keep their old breaks. Edits are global
Lua state and do not respect TeX groups.

## show-hyph

`show_hyph.setup` adds a `post_linebreak_filter` that walks the broken lines,
going into nested hlists and vlists. After every `disc` node, and every `glue`
node without the `thaiseg_intercluster` attribute, it inserts a `pdf_literal`
whatsit that draws a vertical line:

- a thick line from 0 to 7 bp where the node has no `pre` (word boundaries and
  ordinary glue);
- a thin line from 3 to 7 bp where it has a `pre` (hyphenation discs).

All interword spaces, Latin ones included, are marked too.

## Inside newmm

### Data structures

Three data structures had to exist before the algorithm could be translated.

**`defaultdict`**: reading a key that was never assigned returns an empty list
_and stores it_, so `graph[k]` can be appended to without checking first. The
storing part matters; without it the position graph would stay empty.

**A binary min-heap**: `push` and `pop` over a plain array, so `heap[1]` is the
smallest element. That is how the main loop checks whether it has reached the
end of the text. newmm only stores distinct integers, so the tie-breaking order
`heapq` would use never matters and the internal layout is free to differ.

**A trie**: nodes keyed by _codepoint_ rather than by character string. The
input is decoded once, and integer keys avoid building a one-character substring
at every step of every walk. `prefixes` is the core: one descent finds every
dictionary word starting at a position, in time proportional to the longest of
them rather than to the size of the dictionary. The shipped list is loaded with
a "trusted" bulk build that skips the per-word checks of `Trie:add`; a test
checks that both give the same trie.

### TCC

`newmm` cannot be ported without TCC, because maximal matching is constrained by
it. Upstream writes the clusters as one regex alternation of 29 branches. Lua
patterns cannot express that: they have no alternation, no lookahead, no `?` on
a group, and they work on bytes, so `[ก-ฮ]`, a range over three-byte sequences,
cannot be written.

So `tools/export.py` parses the upstream rule strings at build time into
`newmm/tcc_rules.lua`. Parsing rather than copying by hand means a PyThaiNLP
upgrade is a re-run of the script. The exporter **rebuilds the regex from what
it parsed and refuses to continue unless it matches the original string byte for
byte**.

At load time, `newmm/tcc.lua` turns each rule into Lua source (nested `if`s, one
per character class, with each optional item generated as "take it" followed by
"skip it") and compiles it with `load`. The rules are then put into buckets by
the set of characters their first item accepts, keeping their original order, so
for any character only the three or four rules that can match are tried. If no
rule matches, the cluster is one character long, which makes TCC defined for any
input. A slower interpreter over the same rule tables
(`interpreted_cluster_length`) is kept as the reference, and the tests check
that both agree.

Three behaviours had to survive the translation:

- **Order, not length.** Python's `|` returns the first branch that matches, not
  the longest. Sorting the rules, or taking the longest match, changes the
  output.
- **Greedy with backtracking.** `เ[ก-ฮ][่-๋]?า?ะ?` takes each optional if it can
  but must give it up when what follows fails.
- **Python's `$`.** It matches at the end of the string _or_ just before a final
  newline.

The matcher does not re-enter a group to look for a shorter match. That is only
correct while nothing follows a group, so both the exporter and the compiler
refuse rules where a group is not last.

### What `\d` means

`_PAT_NONTHAI` uses `\d+` for its number branch, and for a Python `str` pattern
`\d` means _any_ Unicode decimal digit, not `0-9`. This matters: the Thai digits
๐–๙ are inside the Thai block, so the catch-all branch excludes them and only
`\d+` can match them. `tools/export.py` writes the exact set, 760 codepoints in
71 ranges, checked against Unicode category Nd, as `newmm/digits.lua`.

### Differences from upstream

- **`safe_mode` is not implemented.** Upstream uses it to split texts of
  hundreds of kilobytes into chunks. Here the input is a single run from one
  paragraph. `MAX_GRAPH_SIZE` is kept, because it limits ambiguity, not length.
  Long input still works in one pass, and there is a test for it.
- **`Trie:prefixes` returns lengths, not strings,** so no substring is built per
  candidate per position. `prefixes_of(text)` returns the strings for other
  callers.
- **`onecut` returns end positions, not strings.**
- **An unreachable goal emits the span instead of raising.**

None of these changes the output for any input that upstream handles.

## Lua interface

These are for testing and for use from other Lua code. The package itself uses
only `segment_positions`, `syllable_dictionary`, `tcc.segment` and the
dictionary edit functions.

```lua
local newmm = require("newmm")

newmm.segment("ผมชอบกินข้าวผัด")              --> { "ผม", "ชอบ", "กิน", "ข้าวผัด" }
newmm.segment_positions(cps, count)         --> ends, valid
newmm.segment("ข้าวผัด", newmm.syllable_dictionary())   --> { "ข้าว", "ผัด" }

newmm.tcc.segment("สวัสดี")                    --> { "ส", "วัส", "ดี" }
newmm.tcc.positions("สวัสดี")                  --> { 1, 4, 6 }

newmm.add_word("ฟูบาร์")
newmm.add_words({ "ฟูบาร์", "แบซ" })
newmm.add_words_from_file("mywords.txt")
newmm.remove_word("ฟูบาร์")
newmm.add_syllables({ ... })
newmm.dictionary():contains("สวัสดี")          --> true

local mine = newmm.new_dictionary({ "ครู", "สอน", "ภาษาไทย" })
newmm.segment("ครูสอนภาษาไทย", mine)          --> { "ครู", "สอน", "ภาษาไทย" }

newmm.setup{ words = "/path/to/words.txt", syllables = "/path/to/syllables.txt" }
```

```lua
local bp = require("thai_breakpoints")

bp.plan("ผมชอบกินข้าวผัด")    --> { ends = {2,5,8,15}, breaks = {12}, clusters = nil }
bp.process("ผมชอบกินข้าวผัด") --> { words = {...}, tcc = { ["ข้าวผัด"] = {4} } }
```

`process` and `process_batch` are the string-based form of `plan`, matching the
old Python worker's output format. The tests use them; the linebreaker does not.
Note that `process` does not apply the `TCC_MIN_EDGE` filter.

## Testing

```bash
texlua tests/run.lua               # 35 tests, about 2.5 s
texlua tests/run.lua --filter trie # only tests whose name contains "trie"
```

The main tests compare against recordings of PyThaiNLP 5.3.4 and of the old
Python worker in `tests/data/`. The full sweep covers 513k characters of Thai
Wikipedia (1,858 lines, 122,009 words, 305,347 clusters) plus hand-picked edge
cases. It runs every time rather than behind a flag, because it is fast and a
check that strong should not be easy to forget.

Other tests check each data structure directly: that `defaultdict` really stores
the list it returns, that the heap agrees with a sorted list on pseudo-random
input, that removing a word from the trie leaves shorter words on the same path,
that compiled TCC rules agree with the interpreter, that `segment_positions`
agrees with `segment`, that `plan` agrees with `process`, and that user
hyphenations override the computed ones.

`thai_linebreak.lua` and `show_hyph.lua` need LuaTeX's `node` library and are
not covered by the suite; test them by compiling a document, for example
`docs/main.tex` with `show-hyph`.

There is no test framework, because installing one would go against the point of
a package with no dependencies.

## Re-running the conversion

Needs PyThaiNLP. The generated Lua does not.

```bash
uv venv && uv pip install pythainlp
python tools/export.py       # writes newmm/tcc_rules.lua, newmm/digits.lua, data/syllables_th.txt
python tools/make_golden.py  # refreshes tests/data/expected.tsv, expected-full.tsv
python tools/make_breakpoints_golden.py  # refreshes tests/data/expected-breakpoints.tsv
texlua tests/run.lua
```
