# Test data

Inputs and recordings, not code. The recordings come from **PyThaiNLP 5.3.4**
running the original Python, so a test failure means the Lua port disagrees with
upstream — not that a number moved.

## `corpus.txt` and `corpus-full.txt`

Thai prose sampled from Thai Wikipedia article extracts, fetched via the
MediaWiki API in July 2026, bucketed by length so that headings, single
sentences and full paragraphs are all represented.

| | lines | characters |
| --- | --- | --- |
| `corpus.txt` | 180 | ~36,000 |
| `corpus-full.txt` | 1,858 | 513,316 |

Wikipedia text is licensed [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/);
it is here purely as tokeniser input.

## `expected.tsv`

Self-contained, three tab-separated fields per line:

```
text<TAB>word lengths<TAB>cluster lengths
```

180 corpus lines followed by 50 hand-picked edge cases. The edge cases are
chosen to reach code the prose never does:

- **TCC rules that exist for one word or one shape** — `ก็`, `อึ`, `หึ`, `เกาะ`,
  `แข็ง`, `ทรัพย์`, `เดี๋ยวนี้`. A mis-ordered alternation would still produce
  reasonable-looking clusters on bulk text but get these wrong.
- **Every branch of the non-Thai pattern** — `abc123` (which must split, not
  merge), `1,234.56`, `1,` (whose trailing comma must *not* be consumed), `๑๒๓`
  (Thai digits, which only the `\d` branch can match), `\r\n`, punctuation.
- **Inputs with no dictionary words at all** — `ฃฃฃฃฃฃ`, `กขคงจฉชซ`, `เเเเเเ` —
  which force the skip-forward branch that only runs when maximal matching has
  nothing to offer.
- **Whitespace and empty input**, including a bare `\n` and `ก\nข`, because
  Python's `$` matches just before a trailing newline and the TCC lookahead
  depends on it.

The `text` field is escaped (`\\`, `\t`, `\r`, `\n`) so that inputs containing
newlines and tabs survive a line-oriented file.

## `expected-full.tsv`

The corpus sweep. Two tab-separated fields per line — word lengths, then
cluster lengths — aligned line by line with `corpus-full.txt`.

## Why lengths and not the segments

The segments are a partition of an input this directory already ships, and
`tests/run.lua` separately asserts that concatenating them reproduces that
input. Lengths plus that assertion pin the segmentation down exactly, at about
a fifth of the size.

## Regenerating

```bash
python tools/make_golden.py
```

Needs `pythainlp` installed. A *changed* fixture means the port's behaviour
changed, which is exactly what these tests exist to catch — regenerate
deliberately, not to turn a red test green.
