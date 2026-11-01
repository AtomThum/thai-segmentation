# thai-segmentation

สำหรับภาษาไทย :
<https://github.com/AtomThum/thai-segmentation/blob/main/docs/main.pdf>

`thai-segmentation` breaks lines in Thai text in LuaLaTeX documents. Thai has no
spaces between words, so TeX alone can't tell where word boundaries end, and
worse, cannot tell where to put hyphenation points. This package finds the word
boundaries with a LuaTeX port of
[PyThaiNLP](https://github.com/PyThaiNLP/pythainlp)'s
[`newmm`](https://github.com/PyThaiNLP/pythainlp/wiki/newmm-tokenization)
dictionary-based word segmenter, and informs TeX about the following:

1. Thai word boundaries - places where TeX can break the line without inserting
   hyphenations. Optionally, a stretch or shrink can be inserted at these spaces
   to help with typography and text justification.
2. Hyphenation points inside long words, at syllable boundaries. Optionally, a
   small stretch can be inserted just like at the boundaries.

Everything runs inside LuaLaTeX. No `--shell-escape` are needed.

## Requirements

- LuaLaTeX with version after November of 2025. pdfLaTeX and XeLaTeX is NOT
  supported.
- `polyglossia` and `fontspec` package. `babel` package is not yet supported,
  but is in the roadmap.

## Installation

Copy the whole `thai-segmentation` directory, including `newmm/` and `data/`,
into your personal texmf tree:

```text
~/texmf/tex/latex/thai-segmentation/
```

Then run `mktexlsr` if your TeX distribution needs it. Placing the directory
next to your document also works.

## Usage

```latex
\usepackage[<options>]{thai-segmentation}
```

Segmentation runs on all text with Thai characters. Latin and other scripts are
still hyphenated by TeX's own patterns, as usual.

### Options

| Option                             | Default | Meaning                                                                                                                                                                                                          |
| ---------------------------------- | ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `thai-segmentation=<true/false>`   | `true`  | Turns the package on or off.                                                                                                                                                                                     |
| `interword-expansion=<true/false>` | `true`  | When `true`, each Thai word boundary becomes glue that can stretch and shrink. When `false`, it is only a break point with no width.                                                                             |
| `interword-stretch=<pt>`           | `1`     | Only takes effect when `interword-expansion` is true. It sets the "ideal" upper bound of that a Thai word boundary can stretch. Values above 1 is not recommended as it can make the gaps look like spaces.      |
| `interword-shrink=<pt>`            | `0.5`   | Only takes effect when `interword-expansion` is true. Sets the absolute lower limit on how much a Thai word boundary can shrink. Values above 0.5 is not recommended as it can make glyphs touch.                |
| `intercluster-stretch=<pt>`        | `0`     | Stretch, in pt, between the character clusters inside a word. `0` turns it off. The bare key `intercluster-stretch` means `0.2`. Keep it smaller than `interword-stretch`. This glue never becomes a line break. |
| `tcc-min-edge=<n>`                 | `2`     | A hyphenation point must have at least this many characters before it and after it in the word                                                                                                                   |
| `dictionary={<file>,<file>}`       | none    | Extra word lists to load, one word per line. Files are found the way TeX finds files (`kpse`), and then as plain paths.                                                                                          |
| `show-hyph`                        | `false` | A debugging aid: draws a long mark at each word break and a short mark at each hyphenation point. Do not use it in a final document.                                                                             |

Example:

```latex
\usepackage[
  interword-expansion=true,
  interword-stretch=0.5,
  interword-shrink=0.2,
  intercluster-stretch=0,
  dictionary=dict.txt,
  tcc-min-edge=3,
]{thai-segmentation}
```

### Commands

Each command takes a comma-separated list. They can be used anywhere in the
document.

- `\ThaiAddWords{<คำที่หนึ่ง,คำที่สอง,...>}` adds words to the dictionary.
- `\ThaiRemoveWords{<คำที่หนึ่ง,คำที่สอง,...>}` removes words from the
  dictionary.
- `\ThaiHyphenation{<คำ-ที่-หนึ่ง,คำ-ที่-สอง>}` forces where a word may be
  hyphenated. A word input into `\ThaiHyphenation` written without hyphens is
  never hyphenated. The word is also added to the dictionary.
- `\ThaiRemoveHyphenation{<คำ-ที่-หนึ่ง,คำ-ที่-สอง>}` forgets a fixed
  hyphenation. You may write the word with or without hyphens. The word stays in
  the dictionary.
- `\ThaiAddWordsFromFile{<file>}` adds every word in a file, one per line. It
  does the same as the `dictionary` option.
- `\ThaiAddSyllables{<กลุ่มอักษรที่หนึ่ง,กลุ่มอักษรที่สอง,...>}` adds syllables
  used to choose hyphenation points inside long words.
- `\ThaiRemoveSyllables{<กลุ่มอักษรที่หนึ่ง,กลุ่มอักษรที่สอง,...>}` removes
  syllables from that list.

### When edits take effect

Segmentation happens when TeX hyphenates a list: at the end of each paragraph,
and when an `\hbox` is built. A dictionary edit or `\ThaiInterclusterStretch`
therefore affects the **whole paragraph it appears in** and every later one,
including the part of that paragraph before the command. It does not affect
boxes that were already built. All edits are global; TeX groups do not limit
them.

### How hyphenation points are chosen

Only words longer than five characters get hyphenation points. The word is split
into syllables using the syllable list, and any syllable longer than four
characters is split again at Thai character cluster boundaries. Points closer to
either end of the word than `tcc-min-edge` are dropped. If a word breaks
somewhere wrong, fix it with `\ThaiHyphenation`, or teach the syllable list with
`\ThaiAddSyllables`.

Where TeX breaks at a hyphenation point, it prints a `-`, and the cost is
`\hyphenpenalty`. A break between two words prints nothing and costs nothing.

## Limitations

- Segmentation uses a dictionary. Words that are not in the dictionary, such as
  names and transliterated terms, may be split in odd places. Add them with
  `\ThaiAddWords` or the `dictionary` option.
- Thai text is segmented one unbroken stretch of characters at a time. A command
  that puts something other than characters in the middle of a word, such as a
  colour change (`\textcolor{red}{สวัส}ดี`), a box or an explicit kern, splits
  it into two pieces that are segmented separately. A font change such as
  `\textbf` does not.
- The old `python-path` option was removed. Delete it from your preamble.

## Attribution and licensing

The algorithm, the TCC grammar and the word lists are from the PyThaiNLP
project:

- PyThaiNLP 5.3.4, Apache 2.0, <https://github.com/PyThaiNLP/pythainlp>
- `newmm` is based on
  <https://github.com/PyThaiNLP/pythainlp/blob/main/pythainlp/tokenize/newmm.py>
- `data/words_th.txt` is from PyThaiNLP's word list
- `data/syllables_th.txt` is from PyThaiNLP's syllable list.

This package is a derivative work of Apache-2.0 source and is licensed **Apache
2.0** in turn. See `LICENSE.txt`.

Technical details on how the package works are in `PACKAGE_LAYOUT.md`.

## AI Disclosure

The LaTeX interface and the node tree walking logic were human-written and
AI-assisted. The newmm algorithm and the tests were AI-translated and manually
checked. The test suite and data conversion code were AI-generated.

AI Model: Claude Opus 5.5
