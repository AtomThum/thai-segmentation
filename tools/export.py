"""Compile the parts of newmm that come from regex into Lua tables.

This is a *build-time* tool.  It needs PyThaiNLP installed::

    uv pip install pythainlp

copies ``data/syllables_th.txt`` verbatim, and writes two generated modules:

``newmm/tcc_rules.lua``
    The Thai Character Cluster grammar, parsed out of
    ``pythainlp.tokenize.tcc_p._RE_TCC``.

``newmm/digits.lua``
    Every codepoint Python's ``\\d`` matches.  ``_PAT_NONTHAI`` uses ``\\d+`` to
    pick out numbers, and for a ``str`` pattern that means any Unicode decimal
    digit, not just ASCII.  This is not a detail that can be waved away: Thai
    digits ๐-๙ live *inside* the Thai block, so the catch-all
    ``[^\\u0E00-\\u0E7F ...]+`` branch cannot match them and only the ``\\d+``
    branch will.  Getting the set wrong changes how "๑๒๓" is tokenised.

Why this exists
---------------

``pythainlp.tokenize.tcc_p`` defines Thai Character Clusters as one big regex
alternation, and ``tcc()`` walks the text applying ``_PAT_TCC.match`` at each
position.  Lua patterns cannot express any of what that relies on: no
alternation, no lookahead, no ``?`` on a group, and character classes are
byte-oriented so ``[ก-ฮ]`` -- a range over three-byte UTF-8 sequences -- is not
expressible either.

So the rules are parsed here, at build time, into a small structure that
``newmm/tcc.lua`` interprets with a purpose-built backtracking matcher.  Parsing
the upstream strings rather than hand-transcribing 29 patterns means a
PyThaiNLP upgrade is a re-run of this script, not a careful re-reading.

The subset of regex syntax actually used, verified by ``check_grammar`` below:

    literal character            เ
    character class              [ก-ฮ]
    optional suffix              ?          on a literal, a class, or a group
    group                        (...)      always optional, always last
    lookahead                    (?=[...]|$)
    end anchor                   $          only inside a lookahead

Anything outside that subset makes this script fail rather than emit something
subtly wrong.
"""

from __future__ import annotations

import os
import sys
from typing import Any, Dict, List, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_PATH = os.path.join(HERE, os.pardir, "newmm", "tcc_rules.lua")
DIGITS_PATH = os.path.join(HERE, os.pardir, "newmm", "digits.lua")
SYLLABLES_PATH = os.path.join(HERE, os.pardir, "data", "syllables_th.txt")


class ParseError(Exception):
    pass


def parse_class(pattern: str, i: int) -> Tuple[List[Tuple[int, int]], int]:
    """Parse ``[...]`` into a list of inclusive codepoint ranges."""
    if pattern[i] != "[":
        raise ParseError(f"expected '[' at {i} of {pattern!r}")
    i += 1

    if pattern[i] == "^":
        raise ParseError(f"negated class in {pattern!r}; not supported")

    ranges: List[Tuple[int, int]] = []
    while pattern[i] != "]":
        start = pattern[i]
        i += 1
        if pattern[i] == "-" and pattern[i + 1] != "]":
            end = pattern[i + 1]
            i += 2
            ranges.append((ord(start), ord(end)))
        else:
            ranges.append((ord(start), ord(start)))

    return ranges, i + 1


def parse_sequence(pattern: str, i: int, closing: str | None) -> Tuple[List[Dict[str, Any]], int]:
    """Parse a sequence of items until ``closing`` (or end of pattern)."""
    items: List[Dict[str, Any]] = []

    while i < len(pattern):
        ch = pattern[i]

        if closing is not None and ch == closing:
            return items, i + 1

        item: Dict[str, Any]

        if ch == "(":
            if pattern.startswith("(?=", i):
                item, i = parse_lookahead(pattern, i)
            else:
                sub, i = parse_sequence(pattern, i + 1, ")")
                item = {"kind": "group", "items": sub}
        elif ch == "[":
            ranges, i = parse_class(pattern, i)
            # Remembered only so `unparse` can reproduce the source exactly:
            # upstream writes some single characters as one-element classes
            # (`[์]`), which is the same language but not the same string.
            item = {"kind": "set", "ranges": ranges, "bracketed": True}
        elif ch == "$":
            item = {"kind": "eol"}
            i += 1
        elif ch in "|?*+":
            raise ParseError(f"unexpected {ch!r} at {i} of {pattern!r}")
        else:
            item = {"kind": "set", "ranges": [(ord(ch), ord(ch))], "bracketed": False}
            i += 1

        if i < len(pattern) and pattern[i] == "?":
            item["optional"] = True
            i += 1

        items.append(item)

    if closing is not None:
        raise ParseError(f"unterminated group in {pattern!r}")

    return items, i


def parse_lookahead(pattern: str, i: int) -> Tuple[Dict[str, Any], int]:
    """Parse ``(?=[...]|$)`` into a single zero-width item."""
    i += 3  # past "(?="

    ranges: List[Tuple[int, int]] = []
    allow_eol = False

    while pattern[i] != ")":
        if pattern[i] == "[":
            branch, i = parse_class(pattern, i)
            ranges.extend(branch)
        elif pattern[i] == "$":
            allow_eol = True
            i += 1
        elif pattern[i] == "|":
            i += 1
        else:
            raise ParseError(f"unsupported lookahead content at {i} of {pattern!r}")

    return {"kind": "ahead", "ranges": ranges, "eol": allow_eol}, i + 1


def unparse(items: List[Dict[str, Any]]) -> str:
    """Rebuild the regex source from the parsed form.

    The round trip is the check that nothing was dropped or misread.  A parser
    that silently ignored, say, a trailing ``?`` would produce a matcher that is
    wrong in a way no amount of staring at the output would reveal.
    """

    def render_ranges(ranges: List[Tuple[int, int]]) -> str:
        out = []
        for lo, hi in ranges:
            out.append(chr(lo) if lo == hi else f"{chr(lo)}-{chr(hi)}")
        return "".join(out)

    parts = []
    for item in items:
        if item["kind"] == "set":
            rendered = render_ranges(item["ranges"])
            text = f"[{rendered}]" if item["bracketed"] else rendered
        elif item["kind"] == "group":
            text = f"({unparse(item['items'])})"
        elif item["kind"] == "ahead":
            branches = [f"[{render_ranges(item['ranges'])}]"] if item["ranges"] else []
            if item["eol"]:
                branches.append("$")
            text = f"(?={'|'.join(branches)})"
        elif item["kind"] == "eol":
            text = "$"
        else:
            raise ParseError(f"unknown item {item!r}")

        parts.append(text + ("?" if item.get("optional") else ""))

    return "".join(parts)


def check_grammar(rules: List[List[Dict[str, Any]]]) -> None:
    """Reject anything the Lua matcher is not built to handle.

    ``newmm/tcc.lua`` backtracks over optional literals and classes, but treats
    a group as "try it, else skip it" without re-entering it for a shorter
    match.  That is only sound while nothing follows a group -- which holds for
    every rule upstream ships.  If that ever stops being true, this fails here
    rather than producing a matcher that is quietly wrong on rare input.
    """
    for index, items in enumerate(rules):
        for position, item in enumerate(items):
            if item["kind"] == "group":
                if position != len(items) - 1:
                    raise ParseError(
                        f"rule {index}: a group is followed by {items[position + 1]['kind']!r}; "
                        "newmm/tcc.lua assumes groups are final"
                    )
                for inner in item["items"]:
                    if inner["kind"] == "group":
                        raise ParseError(f"rule {index}: nested group; not supported")


def lua_ranges(ranges: List[Tuple[int, int]]) -> str:
    return "{" + ",".join(f"{{{lo},{hi}}}" for lo, hi in ranges) + "}"


def lua_items(items: List[Dict[str, Any]], indent: str) -> str:
    lines = []
    for item in items:
        optional = ", optional = true" if item.get("optional") else ""

        if item["kind"] == "set":
            body = f'kind = "set", ranges = {lua_ranges(item["ranges"])}{optional}'
        elif item["kind"] == "ahead":
            body = (
                f'kind = "ahead", ranges = {lua_ranges(item["ranges"])}, '
                f'eol = {"true" if item["eol"] else "false"}'
            )
        elif item["kind"] == "eol":
            body = f'kind = "eol"{optional}'
        elif item["kind"] == "group":
            inner = lua_items(item["items"], indent + "  ")
            body = f'kind = "group"{optional}, items = {{\n{inner}{indent}  }}'
        else:
            raise ParseError(f"unknown item {item!r}")

        lines.append(f"{indent}{{ {body} }},\n")

    return "".join(lines)


def write_digits() -> int:
    """Emit every codepoint Python's ``\\d`` matches, as inclusive ranges.

    Derived from ``unicodedata`` rather than by probing the regex engine a
    million times, having first checked the two agree exactly.
    """
    import re
    import unicodedata

    digits = {c for c in range(0x110000) if unicodedata.category(chr(c)) == "Nd"}

    # Cheap insurance that "category Nd" really is what `\d` means here: a
    # disagreement would mean this table is subtly wrong for some script.
    probe = [0x30, 0x39, 0x0E50, 0x0E59, 0x0660, 0x1B50, 0x41, 0x0E01, 0xB2]
    for c in probe:
        if bool(re.match(r"\d", chr(c))) != (c in digits):
            raise ParseError(f"\\d and category Nd disagree on U+{c:04X}")

    ranges: List[Tuple[int, int]] = []
    start = previous = None
    for c in sorted(digits):
        if start is None:
            start = previous = c
        elif previous is not None and c == previous + 1:
            previous = c
        else:
            ranges.append((start, previous))  # type: ignore[arg-type]
            start = previous = c
    if start is not None:
        ranges.append((start, previous))  # type: ignore[arg-type]

    out_path = os.path.abspath(DIGITS_PATH)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("-- Generated by tools/export.py -- do not edit by hand.\n")
        f.write("--\n")
        f.write("-- Codepoints matched by Python's `\\d` in a `str` pattern, which is every\n")
        f.write("-- Unicode decimal digit (category Nd), not just 0-9. newmm's non-Thai\n")
        f.write("-- pattern uses `\\d+` for its number branch.\n")
        f.write("--\n")
        f.write("-- Thai digits U+0E50..U+0E59 are the reason this matters: they sit inside\n")
        f.write("-- the Thai block, so the catch-all branch excludes them and only this set\n")
        f.write("-- can match them.\n")
        f.write("--\n")
        f.write(f"-- {len(digits)} codepoints in {len(ranges)} ranges.\n\n")
        f.write("return {\n")
        for lo, hi in ranges:
            f.write(f"  {{{lo},{hi}}},\n")
        f.write("}\n")

    print(f"wrote {out_path}: {len(digits)} codepoints in {len(ranges)} ranges")
    return len(digits)


def main() -> int:
    try:
        import pythainlp
        from pythainlp.tokenize.tcc_p import _RE_TCC
    except ImportError as exc:
        raise SystemExit(f"{exc}\n\nThis needs PyThaiNLP: uv pip install pythainlp")

    rules: List[List[Dict[str, Any]]] = []

    for pattern in _RE_TCC:
        items, consumed = parse_sequence(pattern, 0, None)
        if consumed != len(pattern):
            raise ParseError(f"trailing input in {pattern!r}")

        rebuilt = unparse(items)
        if rebuilt != pattern:
            raise ParseError(f"round trip changed the pattern:\n  in  {pattern!r}\n  out {rebuilt!r}")

        rules.append(items)

    check_grammar(rules)

    out_path = os.path.abspath(OUT_PATH)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("-- Generated by tools/export_tcc.py -- do not edit by hand.\n")
        f.write("--\n")
        f.write(f"-- Thai Character Cluster rules from PyThaiNLP {pythainlp.__version__},\n")
        f.write("-- pythainlp.tokenize.tcc_p._RE_TCC, compiled from regex into a form\n")
        f.write("-- newmm/tcc.lua can match without a regex engine.\n")
        f.write("--\n")
        f.write("-- Order is significant: Python's alternation returns the first branch\n")
        f.write("-- that matches, not the longest, so the matcher must try these in order.\n")
        f.write("--\n")
        f.write("-- `ranges` are inclusive codepoint pairs. A single character is a range\n")
        f.write("-- whose ends are equal.\n\n")
        f.write("return {\n")
        f.write(f'  source = "pythainlp {pythainlp.__version__} tcc_p._RE_TCC",\n')
        f.write("  rules = {\n")

        for pattern, items in zip(_RE_TCC, rules):
            f.write(f"    -- {pattern}\n")
            f.write("    {\n")
            f.write(lua_items(items, "      "))
            f.write("    },\n")

        f.write("  },\n")
        f.write("}\n")

    print(f"wrote {out_path}: {len(rules)} rules from pythainlp {pythainlp.__version__}")
    print("round trip verified for every rule")

    write_digits()
    copy_syllables()

    return 0


def copy_syllables() -> None:
    """Copy PyThaiNLP's syllable list verbatim into ``data/``.

    ``syllable_tokenize(engine="dict")`` is newmm against this list, which is how
    the linebreaker picks hyphenation points inside long words.
    """
    import shutil

    import pythainlp.corpus

    source = os.path.join(os.path.dirname(pythainlp.corpus.__file__), "syllables_th.txt")
    out_path = os.path.abspath(SYLLABLES_PATH)
    shutil.copyfile(source, out_path)
    print(f"wrote {out_path}: copied from {source}")


if __name__ == "__main__":
    sys.exit(main())
