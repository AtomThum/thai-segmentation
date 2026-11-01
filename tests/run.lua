#!/usr/bin/env texlua
--
-- newmm-lua's test suite.
--
--     texlua tests/run.lua               -- everything, about five seconds
--     texlua tests/run.lua --filter trie -- only tests whose name matches
--
-- The 513k-character corpus sweep runs every time rather than hiding behind a
-- flag: it costs about four seconds here, and a check that strong should not be
-- something you can forget to ask for.
--
-- No test framework, because installing one would undercut the point of a
-- package with no dependencies.
--
-- The load-bearing tests compare against a recording of PyThaiNLP 5.3.4
-- (`tests/data/expected*.tsv`, written by `tools/make_golden.py`). The rest
-- cover the data structures directly, and guard properties that a plausible bug
-- could break while still producing plausible-looking Thai.

local script = arg[0] or "tests/run.lua"
local root = script:gsub("[/\\]?tests[/\\]run%.lua$", "")
if root == "" or root == script then
  root = "."
end

package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local newmm = require("newmm")
local codepoints = require("newmm.codepoints")
local defaultdict = require("newmm.defaultdict")
local heap = require("newmm.heap")
local patterns = require("newmm.patterns")
local tcc = require("newmm.tcc")
local trie = require("newmm.trie")

local DATA_DIR = root .. "/tests/data/"

---------------------------------------------------------------------------
-- harness
---------------------------------------------------------------------------

local cases = {}
local filter = nil

for i = 1, #arg do
  if arg[i] == "--filter" then
    filter = arg[i + 1]
  end
end

local function test(name, fn)
  cases[#cases + 1] = { name = name, fn = fn }
end

local function fail(message, ...)
  if select("#", ...) > 0 then
    message = message:format(...)
  end
  error(message, 0)
end

local function check(condition, message, ...)
  if not condition then
    fail(message, ...)
  end
end

local function brief(value, limit)
  limit = limit or 60
  local text
  if type(value) == "table" then
    local parts = {}
    for i = 1, #value do
      parts[i] = tostring(value[i])
    end
    text = "{" .. table.concat(parts, "|") .. "}"
  else
    text = tostring(value)
  end
  if #text > limit then
    text = text:sub(1, limit) .. "..."
  end
  return text
end

local function equal(got, want, message, ...)
  if got ~= want then
    local context = select("#", ...) > 0 and message:format(...) or (message or "")
    fail("%s\n      got:  %s\n      want: %s", context, brief(got), brief(want))
  end
end

local function equal_list(got, want, message, ...)
  local context = select("#", ...) > 0 and message:format(...) or (message or "")

  if #got ~= #want then
    fail("%s\n      length %d, want %d\n      got:  %s\n      want: %s", context, #got, #want, brief(got), brief(want))
  end

  for i = 1, #want do
    if got[i] ~= want[i] then
      fail(
        "%s\n      first difference at %d: %s vs %s\n      got:  %s\n      want: %s",
        context,
        i,
        tostring(got[i]),
        tostring(want[i]),
        brief(got),
        brief(want)
      )
    end
  end
end

---------------------------------------------------------------------------
-- fixtures
---------------------------------------------------------------------------

--- Undo `tools/make_golden.py`'s escaping.
local function unescape(text)
  return (
    text:gsub("\\(.)", function(c)
      if c == "n" then
        return "\n"
      elseif c == "t" then
        return "\t"
      elseif c == "r" then
        return "\r"
      end
      return c
    end)
  )
end

local function parse_lengths(csv)
  local out, n = {}, 0
  for value in csv:gmatch("[^,]+") do
    n = n + 1
    out[n] = tonumber(value)
  end
  return out
end

--- Lengths in characters of each piece.
local function lengths_of(pieces)
  local out = {}
  for i = 1, #pieces do
    local _, _, n = codepoints.decode(pieces[i])
    out[i] = n
  end
  return out
end

local golden = {}
do
  local f = assert(io.open(DATA_DIR .. "expected.tsv", "rb"), "run tools/make_golden.py first")
  for line in f:lines() do
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local text, words, clusters = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)$")
      check(text ~= nil, "malformed fixture line: %s", brief(line))
      golden[#golden + 1] = {
        text = unescape(text),
        words = parse_lengths(words),
        clusters = parse_lengths(clusters),
      }
    end
  end
  f:close()
end

---------------------------------------------------------------------------
-- codepoints
---------------------------------------------------------------------------

test("codepoints: decodes by character and round-trips", function()
  local cps, offsets, n = codepoints.decode("ก1😀ข")
  equal(n, 4, "character count")
  equal(cps[1], 0x0E01, "thai")
  equal(cps[2], 0x31, "ascii")
  equal(cps[3], 0x1F600, "outside the BMP")
  equal(offsets[n + 1], #"ก1😀ข" + 1, "sentinel offset")
  equal(codepoints.encode(cps), "ก1😀ข", "round trip")
  equal(codepoints.slice("ก1😀ข", offsets, 1, 3), "1😀", "slice by character position")

  local _, _, empty = codepoints.decode("")
  equal(empty, 0, "empty string")
end)

test("codepoints: malformed UTF-8 does not raise", function()
  -- The standard `utf8` library raises on these. A document build must not die
  -- because one byte somewhere upstream got mangled.
  --
  -- The property that matters is that `slice` still covers the input exactly,
  -- since that is how every token is cut. `encode` is deliberately *not*
  -- checked here: it is a canonical encoder, so it cannot reproduce bytes that
  -- were not valid UTF-8 to begin with.
  for _, text in ipairs({ "\128\128", "ก\224", "\255ก", "\237\160\128", "\240\159" }) do
    local ok, cps, offsets, n = pcall(codepoints.decode, text)
    check(ok, "decode raised on %q", text)

    local pieces = {}
    for i = 1, n do
      pieces[i] = codepoints.slice(text, offsets, i - 1, i)
    end
    equal(table.concat(pieces), text, "slices cover malformed input exactly")
    check(#cps == n, "codepoint count agrees")
  end
end)

test("codepoints: segmenting malformed input still round-trips", function()
  -- The property the whole package rests on, checked on input that cannot come
  -- from a well-formed document but might arrive anyway.
  for _, text in ipairs({ "ไทย\255ไทย", "\128สวัสดี", "abc\224\224" }) do
    equal(table.concat(newmm.segment(text)), text, "words for %q", text)
    equal(table.concat(tcc.segment(text)), text, "clusters for %q", text)
  end
end)

---------------------------------------------------------------------------
-- defaultdict
---------------------------------------------------------------------------

test("defaultdict: missing keys become empty lists", function()
  local d = defaultdict.new()

  equal(#d[7], 0, "a fresh key reads as an empty list")

  -- The list must be *stored*, not made afresh each read, or appending to it
  -- would quietly do nothing.
  local list = d[7]
  list[#list + 1] = 42
  equal(#d[7], 1, "the list persists")
  equal(d[7][1], 42, "the appended value is there")

  equal(defaultdict.has(d, 7), true, "assigned key")
  equal(defaultdict.has(d, 99), false, "unassigned key -- and `has` must not create it")
  equal(defaultdict.has(d, 99), false, "still unassigned after asking")
end)

test("defaultdict: clear empties it but keeps the behaviour", function()
  local d = defaultdict.new()
  d[1][1] = "a"
  d[2][1] = "b"

  defaultdict.clear(d)

  equal(next(d), nil, "no keys remain")
  equal(#d[1], 0, "still defaults after clearing")
end)

---------------------------------------------------------------------------
-- heap
---------------------------------------------------------------------------

test("heap: pops in ascending order", function()
  local h = heap.new()
  for _, v in ipairs({ 5, 3, 8, 1, 9, 2, 7 }) do
    heap.push(h, v)
    check(heap.is_valid(h), "heap property broken after pushing %d", v)
  end

  equal(heap.size(h), 7, "size")
  equal(heap.peek(h), 1, "peek is the minimum")

  local out = {}
  while heap.size(h) > 0 do
    out[#out + 1] = heap.pop(h)
    check(heap.is_valid(h), "heap property broken after a pop")
  end

  equal_list(out, { 1, 2, 3, 5, 7, 8, 9 }, "ascending order")
  equal(heap.pop(h), nil, "popping an empty heap")
  equal(heap.peek(h), nil, "peeking an empty heap")
end)

test("heap: matches a sorted list on pseudo-random input", function()
  -- A fixed generator rather than math.random, so a failure is reproducible.
  local seed = 12345
  local function next_value()
    seed = (1103515245 * seed + 12345) % 2147483648
    return seed % 1000
  end

  for trial = 1, 20 do
    local h, reference = heap.new(), {}
    for _ = 1, 50 do
      local v = next_value()
      heap.push(h, v)
      reference[#reference + 1] = v
    end
    table.sort(reference)

    local out = {}
    while heap.size(h) > 0 do
      out[#out + 1] = heap.pop(h)
    end

    equal_list(out, reference, "trial %d", trial)
  end
end)

test("heap: contains", function()
  local h = heap.new()
  for _, v in ipairs({ 4, 1, 9 }) do
    heap.push(h, v)
  end
  equal(heap.contains(h, 9), true, "present")
  equal(heap.contains(h, 5), false, "absent")
  equal(heap.contains(heap.new(), 1), false, "empty heap")
end)

---------------------------------------------------------------------------
-- trie
---------------------------------------------------------------------------

test("trie: add, contains, remove", function()
  local t = trie.new({ "สวัสดี", "สวัส", "ดี", "ครับ" })

  equal(t:len(), 4, "word count")
  equal(t:contains("สวัสดี"), true, "stored word")
  equal(t:contains("สวั"), false, "a prefix is not a word")
  equal(t:contains("ไม่มี"), false, "absent word")

  equal(t:add("สวัสดี"), false, "adding a duplicate reports no change")
  equal(t:len(), 4, "count unchanged by a duplicate")

  equal(t:add("สวัสดีตอนเช้า"), true, "new word")
  equal(t:len(), 5, "count grew")

  equal(t:remove("สวัสดีตอนเช้า"), true, "removing a stored word")
  equal(t:len(), 4, "count shrank")
  equal(t:contains("สวัสดีตอนเช้า"), false, "gone")
  equal(t:contains("สวัสดี"), true, "removing did not disturb a shorter word on the same path")

  equal(t:remove("ไม่มี"), false, "removing an absent word")
  equal(t:remove("สวั"), false, "removing a prefix that is not a word")
end)

test("trie: prefixes are returned shortest first", function()
  local t = trie.new({ "สวัสดี", "สวัส", "ดี", "ครับ" })

  equal_list(
    t:prefixes_of("สวัสดีครับ"),
    { "สวัส", "สวัสดี" },
    "both matches, in order"
  )
  equal_list(t:prefixes_of("ครับ"), { "ครับ" }, "single match")
  equal_list(t:prefixes_of("ไม่มี"), {}, "no match")
  equal_list(t:prefixes_of(""), {}, "empty input")
end)

test("trie: strips surrounding whitespace but keeps interior spaces", function()
  local t = trie.new({ "  ไทย  ", "ก ข ไม่กระดิกหู" })

  equal(t:contains("ไทย"), true, "trimmed on the way in")
  equal(t:contains("  ไทย  "), false, "not stored with its padding")
  equal(t:contains("ก ข ไม่กระดิกหู"), true, "interior spaces preserved")

  equal(t:add("   "), false, "whitespace-only entries are ignored")
  equal(t:len(), 2, "count")
end)

test("trie: words round-trips through the structure", function()
  local input = { "ไทย", "ไทยแลนด์", "ก", "abc", "1,234" }
  local t = trie.new(input)

  local out = t:words()
  table.sort(out)

  local want = {}
  for i, w in ipairs(input) do
    want[i] = w
  end
  table.sort(want)

  equal_list(out, want, "every word comes back")
end)

test("trie: the shipped dictionary loads", function()
  local dict = newmm.dictionary()
  check(dict:len() > 60000, "expected a large dictionary, got %d words", dict:len())
  equal(dict:contains("สวัสดี"), true, "a common word is present")
end)

---------------------------------------------------------------------------
-- patterns
---------------------------------------------------------------------------

test("patterns: non-Thai matching stops at a change of kind", function()
  local function match(text)
    local cps, _, n = codepoints.decode(text)
    local stop = patterns.nonthai(cps, 0, n)
    return stop
  end

  -- Upstream's comment calls this out: `|` acts "like early return", so
  -- "abc123" is cut into "abc" and "123" rather than taken whole by the
  -- catch-all branch.
  equal(match("abc123"), 3, "latin stops before digits")
  equal(match("123abc"), 3, "digits stop before latin")
  equal(match("1,234.56"), 8, "grouped and decimal digits stay together")
  equal(match("1,"), 1, "a trailing separator is not consumed")
  equal(match("๑๒๓"), 3, "thai digits are digits")
  equal(match("  x"), 2, "runs of spaces")
  equal(match("\n"), 1, "newline")
  equal(match("\r\n"), 2, "carriage return plus newline")
  equal(match("\r"), nil, "a lone carriage return matches nothing")
  equal(match("!@#"), 3, "punctuation via the catch-all")
  equal(match("ไทย"), nil, "thai text is not non-Thai")
  equal(match(""), nil, "empty")
end)

test("patterns: the two-consonant test", function()
  local function two(text)
    local cps, _, n = codepoints.decode(text)
    return patterns.thai_twochars(cps, 0, n)
  end

  equal(two("ก"), true, "one consonant")
  equal(two("กข"), true, "two consonants")
  equal(two("กขค"), false, "three is too many")
  equal(two("ก่"), false, "a tone mark is not a consonant")
  equal(two("ไท"), false, "a leading vowel is not a consonant")
end)

---------------------------------------------------------------------------
-- TCC
---------------------------------------------------------------------------

test("tcc: matches the recorded PyThaiNLP output", function()
  for i = 1, #golden do
    local record = golden[i]
    local clusters = tcc.segment(record.text)
    equal(table.concat(clusters), record.text, "record %d: clusters do not reconstruct", i)
    equal_list(lengths_of(clusters), record.clusters, "record %d: %q", i, brief(record.text, 40))
  end
end)

test("tcc: positions agree with the clusters", function()
  for i = 1, #golden do
    local record = golden[i]
    local positions = tcc.positions(record.text)

    local running, expected = 0, {}
    for j = 1, #record.clusters do
      running = running + record.clusters[j]
      expected[j] = running
    end

    equal_list(positions, expected, "record %d", i)
  end
end)

test("tcc: known cluster shapes", function()
  -- One case per rule shape that exists for only a word or two, where a
  -- mis-ordered alternation would otherwise go unnoticed in bulk text.
  local function joined(text)
    return table.concat(tcc.segment(text), "|")
  end

  equal(joined("ก็"), "ก็", "the ก็ rule")
  equal(joined("เกาะ"), "เกาะ", "เcาะ")
  equal(joined("แข็ง"), "แข็ง", "แc็c")
  equal(joined("ทรัพย์"), "ท|รัพย์", "รรc์-adjacent shape")
  equal(joined("เดี๋ยวนี้"), "เดี๋ย|ว|นี้", "เccีtย with lookahead")
end)

---------------------------------------------------------------------------
-- word segmentation
---------------------------------------------------------------------------

test("segment: matches the recorded PyThaiNLP output", function()
  for i = 1, #golden do
    local record = golden[i]
    local words = newmm.segment(record.text)
    equal(table.concat(words), record.text, "record %d: words do not reconstruct", i)
    equal_list(lengths_of(words), record.words, "record %d: %q", i, brief(record.text, 40))
  end
end)

test("segment: degenerate input", function()
  equal(#newmm.segment(""), 0, "empty string")
  equal(#newmm.segment(nil), 0, "nil")
  equal(#newmm.segment(42), 0, "number")
  equal(#newmm.segment({}), 0, "table")
end)

test("segment: is a pure split", function()
  for i = 1, #golden do
    equal(table.concat(newmm.segment(golden[i].text)), golden[i].text, "record %d", i)
  end
end)

test("segment: long input is handled in one piece", function()
  -- safe_mode is deliberately not ported, so a long line must still work --
  -- it just does the whole thing in one pass.
  local text = string.rep(
    "ฉันเดินทางไปโรงเรียนทุกวันเพื่อเรียนหนังสือ",
    200
  )
  local words = newmm.segment(text)
  check(#words > 200, "expected many words, got %d", #words)
  equal(table.concat(words), text, "round trip over a long input")
end)

test("segment_all agrees with segment", function()
  local texts = { "สวัสดีครับ", "", "แมวกินปลา", "abc123", "ก" }
  local batch = newmm.segment_all(texts)

  equal(#batch, #texts, "one result per input")
  for i = 1, #texts do
    equal_list(batch[i], newmm.segment(texts[i]), "row %d", i)
  end
end)

---------------------------------------------------------------------------
-- custom dictionaries
---------------------------------------------------------------------------

test("a custom dictionary changes the segmentation", function()
  local text = "ครูสอนภาษาไทย"

  local small = newmm.new_dictionary({ "ครู", "สอน", "ภาษา", "ไทย" })
  equal_list(newmm.segment(text, small), { "ครู", "สอน", "ภาษา", "ไทย" }, "four words")

  local joined = newmm.new_dictionary({ "ครู", "สอน", "ภาษาไทย" })
  equal_list(newmm.segment(text, joined), { "ครู", "สอน", "ภาษาไทย" }, "three words")
end)

test("adding to the shared dictionary takes effect and can be undone", function()
  -- A made-up word the shipped dictionary cannot know.
  local word = "ฟูบาร์แบซ"
  local text = "นี่คือฟูบาร์แบซนะ"

  local before = newmm.segment(text)
  check(not newmm.dictionary():contains(word), "the test word must start out unknown")

  equal(newmm.add_word(word), true, "adding reports a change")
  equal(newmm.dictionary():contains(word), true, "it is in the dictionary")

  local after = newmm.segment(text)

  local function has(list, value)
    for i = 1, #list do
      if list[i] == value then
        return true
      end
    end
    return false
  end

  check(has(after, word), "the added word should now be a token: %s", brief(after))
  check(not has(before, word), "it should not have been one before: %s", brief(before))

  equal(newmm.remove_word(word), true, "removing reports a change")
  equal_list(newmm.segment(text), before, "removal restores the original segmentation")
end)

test("an empty dictionary still segments", function()
  -- Everything falls to the no-candidate branch, which must still make
  -- progress rather than loop or drop text.
  local empty = newmm.new_dictionary({})
  for _, text in ipairs({ "สวัสดีครับ", "abc 123", "ไทย\nไทย", "ก" }) do
    local words = newmm.segment(text, empty)
    equal(table.concat(words), text, "round trip for %q with an empty dictionary", text)
    check(#words > 0, "expected at least one token for %q", text)
  end
end)

test("tcc: compiled rules agree with the interpreter", function()
  -- Random strings over the whole Thai block plus the characters the rules
  -- treat specially at the edges: newline (Python's `$`), space, Latin.
  local alphabet = { 10, 32, 65 }
  for cp = 0x0E01, 0x0E5B do
    alphabet[#alphabet + 1] = cp
  end

  local seed = 12345
  local function random(n)
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed % n + 1
  end

  for _ = 1, 20000 do
    local count = random(12)
    local cps = {}
    for i = 1, count do
      cps[i] = alphabet[random(#alphabet)]
    end
    for pos = 0, count - 1 do
      local fast = tcc.cluster_length(cps, pos, count)
      local slow = tcc.interpreted_cluster_length(cps, pos, count)
      if fast ~= slow then
        fail("at %d of %q: compiled %d, interpreted %d", pos, codepoints.encode(cps), fast, slow)
      end
    end
  end
end)

test("trie: the trusted bulk build matches add()", function()
  local words = { "ก", "กา", "สวัสดี", "ครับ", "ครับ", "hello", "ï", "日本", "😀", "a b" }
  local slow, fast = trie.new(words), trie.new(words, true)
  equal(fast:len(), slow:len(), "word count")
  for _, word in ipairs(words) do
    check(fast:contains(word), "trusted build lost %q", word)
  end
  check(not fast:contains("กาก"), "trusted build invented a word")
end)

test("segment_positions agrees with segment", function()
  local texts = { "สวัสดีครับ", "ภาษาไทยเป็นภาษาราชการ", "ก", "๑๒๓บาท" }
  for _, text in ipairs(texts) do
    local cps, _, count = codepoints.decode(text)
    local ends = newmm.segment_positions(cps, count)
    equal_list(ends, (function()
      local out, at = {}, 0
      for i, len in ipairs(lengths_of(newmm.segment(text))) do
        at = at + len
        out[i] = at
      end
      return out
    end)(), "ends for %q", text)
  end
  equal_list(newmm.segment_positions({}, 0), {}, "empty input")
end)

---------------------------------------------------------------------------
-- linebreak break points (thai_breakpoints.lua)
---------------------------------------------------------------------------

test("breakpoints: match the old Python worker's output", function()
  local breakpoints = require("thai_breakpoints")

  local f = assert(io.open(DATA_DIR .. "expected-breakpoints.tsv", "rb"), "run tools/make_breakpoints_golden.py first")

  local runs = 0
  for line in f:lines() do
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local text, want_words, want_breaks = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)$")
      check(text ~= nil, "malformed fixture line: %s", brief(line))
      runs = runs + 1

      local result = breakpoints.process(text)
      equal(table.concat(result.words), text, "run %d: words do not reconstruct", runs)
      equal_list(lengths_of(result.words), parse_lengths(want_words), "run %d: words", runs)

      local i = 0
      for field in (want_breaks .. ";"):gmatch("([^;]*);") do
        i = i + 1
        local got = result.tcc[result.words[i]]
        if field == "-" then
          check(got == nil, "run %d word %d (%s): unexpected break entry %s", runs, i, result.words[i], brief(got))
        else
          check(got ~= nil, "run %d word %d (%s): missing break entry", runs, i, result.words[i])
          equal_list(got, parse_lengths(field), "run %d word %d (%s): breaks", runs, i, result.words[i])
        end
      end
      equal(i, #result.words, "run %d: one break field per word", runs)
    end
  end
  f:close()

  check(runs > 0, "fixture is empty")
  print(string.format("        (%d runs -- all identical)", runs))
end)

test("breakpoints: syllable edits change the break points", function()
  local breakpoints = require("thai_breakpoints")

  -- One dictionary word, several syllables.
  local word = "มหาวิทยาลัย"
  local before = breakpoints.process(word).tcc[word]
  equal_list(before, { 3, 5, 6, 8 }, "recorded break points")

  -- Syllables มหา|วิทยา|ลัย, with the five-character วิทยา split further at
  -- cluster boundaries into วิ|ท|ยา. Without วิทยา: มหา|วิ|ทยา|ลัย.
  equal(breakpoints.remove_syllables({ "วิทยา" }), 1, "วิทยา should be a shipped syllable")
  equal_list(breakpoints.process(word).tcc[word], { 3, 5, 8 }, "after removing a syllable")

  equal(breakpoints.add_syllables({ "วิทยา" }), 1, "adding it back reports a change")
  equal_list(breakpoints.process(word).tcc[word], before, "removal restores the original break points")
end)

test("breakpoints: plan agrees with process", function()
  local breakpoints = require("thai_breakpoints")
  local text = "มหาวิทยาลัยเชียงใหม่เป็นมหาวิทยาลัยแห่งแรกในส่วนภูมิภาค"
  local result = breakpoints.process(text)
  local plan = breakpoints.plan(text)

  local want_ends, want_breaks, at = {}, {}, 0
  for i, word in ipairs(result.words) do
    local length = utf8.len(word)
    for _, pos in ipairs(result.tcc[word] or {}) do
      if pos >= breakpoints.TCC_MIN_EDGE and pos <= length - breakpoints.TCC_MIN_EDGE then
        want_breaks[#want_breaks + 1] = at + pos
      end
    end
    at = at + length
    want_ends[i] = at
  end

  equal_list(plan.ends, want_ends, "word ends")
  equal_list(plan.breaks, want_breaks, "break points, edge-filtered")
  check(plan.clusters == nil, "clusters off by default")
  check(breakpoints.plan(text) == plan, "second call is served from the cache")
end)

test("breakpoints: user hyphenations override the computed ones", function()
  local breakpoints = require("thai_breakpoints")
  local word = "ไฮเซนเบิร์ก"
  local text = "นายไฮเซนเบิร์กเป็นนักฟิสิกส์"

  equal(breakpoints.add_hyphenations({ "ไฮ-เซน-เบิร์ก" }), 1, "one entry taken")
  check(newmm.dictionary():contains(word), "the word is added to the dictionary")
  equal_list(breakpoints.process(word).tcc[word], { 2, 5 }, "process uses the given points")

  local plan = breakpoints.plan(text)
  local start = utf8.len("นาย")
  equal_list(plan.ends, { start, start + 11, start + 15, start + 25 }, "segmentation keeps the word whole")
  local given = {}
  for _, pos in ipairs(plan.breaks) do
    if pos > start and pos < start + 11 then
      given[#given + 1] = pos - start
    end
  end
  equal_list(given, { 2, 5 }, "given points are used verbatim, short of the edge limit or not")

  breakpoints.add_hyphenations({ word })
  equal_list(breakpoints.process(word).tcc[word], {}, "an entry without hyphens forbids breaking")

  equal(breakpoints.remove_hyphenations({ "ไฮ-เซน-เบิร์ก" }), 1, "removed by its hyphenated form")
  equal(breakpoints.add_hyphenations({ "-", "" }), 0, "empty entries are ignored")
  newmm.remove_word(word)
end)

test("breakpoints: cluster boundaries inside words", function()
  local breakpoints = require("thai_breakpoints")
  breakpoints.set_options({ clusters = true })
  local plan = breakpoints.plan("สวัสดีครับ")
  breakpoints.set_options({ clusters = false })

  -- สวัสดี|ครับ, clusters ส|วัส|ดี|ค|รับ: the boundary at 6 is a word end.
  equal_list(plan.ends, { 6, 10 }, "word ends")
  equal_list(plan.clusters, { 1, 4, 7 }, "inner cluster boundaries")
  check(breakpoints.plan("สวัสดีครับ").clusters == nil, "switching off is not served a stale cached plan")
end)

---------------------------------------------------------------------------
-- the full corpus (--full)
---------------------------------------------------------------------------

test("full corpus matches the recorded PyThaiNLP output", function()
  local texts = {}
  do
    local f = assert(io.open(DATA_DIR .. "corpus-full.txt", "rb"), "corpus-full.txt is missing")
    for line in f:lines() do
      if line:match("%S") then
        texts[#texts + 1] = line
      end
    end
    f:close()
  end

  local expected =
    assert(io.open(DATA_DIR .. "expected-full.tsv", "rb"), "run tools/make_golden.py to build the full fixture")

  local line_number = 0
  local characters, words_seen, clusters_seen = 0, 0, 0

  for record in expected:lines() do
    line_number = line_number + 1
    local text = texts[line_number]
    check(text ~= nil, "fixture has %d lines but the corpus has %d", line_number, #texts)

    local want_words, want_clusters = record:match("^([^\t]*)\t([^\t]*)$")
    check(want_words ~= nil, "malformed fixture at line %d", line_number)

    local words = newmm.segment(text)
    local clusters = tcc.segment(text)

    equal(table.concat(words), text, "line %d: words do not reconstruct", line_number)
    equal(table.concat(clusters), text, "line %d: clusters do not reconstruct", line_number)

    equal_list(lengths_of(words), parse_lengths(want_words), "line %d: words", line_number)
    equal_list(lengths_of(clusters), parse_lengths(want_clusters), "line %d: clusters", line_number)

    local _, _, n = codepoints.decode(text)
    characters = characters + n
    words_seen = words_seen + #words
    clusters_seen = clusters_seen + #clusters
  end

  expected:close()

  equal(line_number, #texts, "fixture covers every corpus line")
  print(
    string.format(
      "        (%d lines, %d characters, %d words, %d clusters -- all identical)",
      line_number,
      characters,
      words_seen,
      clusters_seen
    )
  )
end)

---------------------------------------------------------------------------
-- go
---------------------------------------------------------------------------

local passed, failed, skipped = 0, 0, 0
local started = os.clock()

for _, case in ipairs(cases) do
  if filter and not case.name:find(filter, 1, true) then
    skipped = skipped + 1
  else
    local at = os.clock()
    local ok, err = pcall(case.fn)
    local elapsed = os.clock() - at

    if ok then
      passed = passed + 1
      print(string.format("  ok    %s (%.2fs)", case.name, elapsed))
    else
      failed = failed + 1
      print(string.format("  FAIL  %s (%.2fs)\n      %s", case.name, elapsed, tostring(err)))
    end
  end
end

print(string.format("\n%d passed, %d failed, %d skipped in %.2fs", passed, failed, skipped, os.clock() - started))

os.exit(failed == 0 and 0 or 1)
