"""Record what PyThaiNLP's newmm and TCC produce, for the Lua tests to check against.

Needs PyThaiNLP installed::

    uv pip install pythainlp

Writes two fixtures:

``tests/data/expected.tsv``
    The fast suite, self-contained: escaped input text, word lengths, TCC
    cluster lengths.  180 corpus lines plus hand-picked edge cases.

``tests/data/expected-full.tsv``
    The ``--full`` sweep over ``corpus-full.txt``: word lengths and cluster
    lengths only, aligned line by line with the corpus file.

Both store *lengths in characters* rather than the segments themselves.  The
segments are a partition of an input the fixture already has, and
``tests/run.lua`` separately asserts that concatenating them reproduces that
input -- so lengths pin the segmentation down exactly, at a fraction of the
size.

Text is escaped because some edge cases contain newlines and tabs, which a
line-and-tab-delimited file cannot hold literally.  Those cases matter: Python's
``$`` in the TCC lookahead behaves differently just before a trailing newline,
and newmm has a branch specifically for ``\\r?\\n``.

Run it with::

    python tools/make_golden.py

A *changed* fixture means the port's behaviour changed, which is what these
tests exist to catch.  Regenerate deliberately.
"""

from __future__ import annotations

import os
import sys
from typing import List

HERE = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(HERE, os.pardir, "tests", "data")

# Inputs chosen to reach the parts of the algorithm ordinary prose does not.
EDGE_CASES: List[str] = [
    "",
    " ",
    "  ",
    "\t",
    "\n",
    "\r\n",
    "ก\nข",
    "ก",
    "กก",
    "ไทย",
    # TCC rules that exist for a single word or a single shape
    "ก็",
    "อึ",
    "หึ",
    "เกาะ",
    "เดี๋ยวนี้",
    "แข็ง",
    "โต๊ะ",
    "ค่ะ",
    "น้ำ",
    "เปลี่ยน",
    "ทรัพย์",
    "สังข์",
    "จันทร์",
    "เกียรติ",
    "กรรม์",
    "เชี่ยวชาญ",
    "ผู้",
    "เอ๋ย",
    "โอ๊ะ",
    "ฯลฯ",
    # the non-Thai pattern, branch by branch
    "abc",
    "abc123",
    "123abc",
    "1,234.56",
    "๑๒๓",
    "๑,๒๓๔.๕๖",
    "1,",
    "1.",
    "A1-b_c",
    "!@#$%",
    "café",
    "😀ไทย😀",
    # mixed
    "สวัสดีครับ",
    "ผมชอบกินข้าวผัด",
    "กรุงเทพมหานคร 10200",
    "ภาษาไทย ภาษาอังกฤษ English",
    "ทดสอบ  ระบบ  ตัด  คำ",
    # words that are not in the dictionary, to reach the skip-forward branch
    "ฃฃฃฃฃฃ",
    "กขคงจฉชซ",
    "เเเเเเ",
]


def escape(text: str) -> str:
    return (
        text.replace("\\", "\\\\").replace("\t", "\\t").replace("\r", "\\r").replace("\n", "\\n")
    )


def read_lines(path: str) -> List[str]:
    with open(path, encoding="utf-8") as f:
        return [line.rstrip("\n") for line in f if line.strip()]


def main() -> int:
    try:
        import pythainlp
        from pythainlp.tokenize.newmm import segment as word_segment
        from pythainlp.tokenize.tcc_p import segment as tcc_segment
    except ImportError as exc:
        raise SystemExit(f"{exc}\n\nThis needs PyThaiNLP: uv pip install pythainlp")

    print(f"pythainlp {pythainlp.__version__}")

    def lengths(pieces: List[str]) -> str:
        return ",".join(str(len(p)) for p in pieces)

    corpus = read_lines(os.path.join(DATA_DIR, "corpus.txt"))
    records = corpus + EDGE_CASES

    out_path = os.path.join(DATA_DIR, "expected.tsv")
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("# text\twords\tclusters -- lengths in characters; see SOURCE.md\n")
        for text in records:
            words = word_segment(text)
            clusters = tcc_segment(text)

            assert "".join(words) == text, f"words do not reconstruct: {text[:60]!r}"
            assert "".join(clusters) == text, f"clusters do not reconstruct: {text[:60]!r}"

            f.write(f"{escape(text)}\t{lengths(words)}\t{lengths(clusters)}\n")

    print(
        f"wrote {out_path}: {len(records)} records "
        f"({len(corpus)} corpus + {len(EDGE_CASES)} edge cases)"
    )

    full_path = os.path.join(DATA_DIR, "corpus-full.txt")
    if not os.path.exists(full_path):
        print(f"skipping the full fixture: {full_path} is not present")
        return 0

    full = read_lines(full_path)
    words_total = clusters_total = 0

    out_path = os.path.join(DATA_DIR, "expected-full.tsv")
    with open(out_path, "w", encoding="utf-8") as f:
        for text in full:
            words = word_segment(text)
            clusters = tcc_segment(text)

            assert "".join(words) == text, f"words do not reconstruct: {text[:60]!r}"
            assert "".join(clusters) == text, f"clusters do not reconstruct: {text[:60]!r}"

            words_total += len(words)
            clusters_total += len(clusters)

            f.write(f"{lengths(words)}\t{lengths(clusters)}\n")

    size = os.path.getsize(out_path) / 1e6
    print(
        f"wrote {out_path}: {len(full)} lines, {words_total} words, "
        f"{clusters_total} clusters ({size:.2f} MB)"
    )

    return 0


if __name__ == "__main__":
    sys.exit(main())
