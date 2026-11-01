"""Record the old Python linebreak worker's output, for thai_breakpoints.lua to match.

Needs PyThaiNLP installed::

    uv pip install pythainlp

``process_sentence`` below is a verbatim copy of the function that the
FIFO-bridged ``thai_server.py`` ran for every Thai run, kept here as the
reference after the bridge was removed.

Writes ``tests/data/expected-breakpoints.tsv``, one Thai run per line::

    text<TAB>word lengths<TAB>break offsets

Runs are cut from ``tests/data/corpus.txt`` the way ``thai_linebreak.lua`` cuts
them from a paragraph: maximal stretches of Thai codepoints.  Break offsets are
per word, ``;``-separated and aligned with the words; each is a ``,``-separated
list, or ``-`` when the word has no entry in the ``tcc`` map at all.

Run it with::

    python tools/make_breakpoints_golden.py
"""

from __future__ import annotations

import itertools as itr
import os
import re
from typing import Final

from pythainlp.tokenize import syllable_tokenize, tcc_p, word_tokenize

HERE = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(HERE, os.pardir, "tests", "data")

# thai_linebreak.lua's is_thai_codepoint.
THAI_RUN = re.compile("[ก-ฺ฿-๛]+")

TCC_THRESHOLD: Final[int] = 5


def process_sentence(text: str) -> dict:
    words: list[str] = word_tokenize(text, engine="newmm")
    tcc_map: dict = {}
    for w in words:
        if len(w) > TCC_THRESHOLD and w not in tcc_map:
            presyllables: list[str] = syllable_tokenize(w, engine="dict")
            syllables: list[str] = []
            for syllable in presyllables:
                if len(syllable) > 4:
                    subsyllable: list[str] = list(tcc_p.tcc(syllable))
                    syllables += subsyllable
                else:
                    syllables.append(syllable)
            tcc_map[w] = list(itr.accumulate(map(len, syllables)))
            tcc_map[w].pop()
    return {"words": words, "tcc": tcc_map}


def main() -> None:
    import pythainlp

    with open(os.path.join(DATA_DIR, "corpus.txt"), encoding="utf-8") as f:
        corpus = f.read().splitlines()

    out_path = os.path.abspath(os.path.join(DATA_DIR, "expected-breakpoints.tsv"))
    runs = 0
    with open(out_path, "w", encoding="utf-8", newline="\n") as out:
        out.write(f"# thai_server.py process_sentence, pythainlp {pythainlp.__version__}\n")
        for line in corpus:
            for match in THAI_RUN.finditer(line):
                text = match.group(0)
                result = process_sentence(text)
                words = result["words"]
                breaks = []
                for w in words:
                    if w in result["tcc"]:
                        breaks.append(",".join(map(str, result["tcc"][w])))
                    else:
                        breaks.append("-")
                out.write(f"{text}\t{','.join(str(len(w)) for w in words)}\t{';'.join(breaks)}\n")
                runs += 1

    print(f"wrote {out_path}: {runs} runs")


if __name__ == "__main__":
    main()
