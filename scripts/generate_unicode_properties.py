"""Write the character properties of Python str methods to priv/unicode_properties.json.

Usage (from the repository root):

    uv run --project scripts python -I scripts/generate_unicode_properties.py

For each property, the file has the code point ranges where it is true, as a flat list of start and
end pairs: [start1, end1, start2, end2, ...]. Otera.Unicode reads it at compile time, so Otera uses
the Unicode version of the pinned Python, not the one of Erlang/OTP.

- printable: str.isprintable(), which repr() uses to escape a character.
- alpha, decimal, digit, numeric, space: str.isalpha(), isdecimal(), isdigit(), isnumeric(), isspace().
- lower, upper: str.islower() and str.isupper() of one character, the Lowercase and Uppercase properties.
- title: the category Lt. A cased character is lower, upper or title.
"""

import json
import os
import sys
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

PROPERTIES = {
    "printable": str.isprintable,
    "alpha": str.isalpha,
    "decimal": str.isdecimal,
    "digit": str.isdigit,
    "numeric": str.isnumeric,
    "space": str.isspace,
    "lower": str.islower,
    "upper": str.isupper,
    "title": lambda c: unicodedata.category(c) == "Lt",
}


def ranges(check):
    flat = []
    start = None
    for code in range(sys.maxunicode + 2):
        inside = code <= sys.maxunicode and check(chr(code))
        if inside and start is None:
            start = code
        elif not inside and start is not None:
            flat += [start, code - 1]
            start = None
    return flat


data = {"unicode_version": unicodedata.unidata_version}
data.update({name: ranges(check) for name, check in PROPERTIES.items()})

with open(os.path.join(ROOT, "priv", "unicode_properties.json"), "w", encoding="utf-8") as f:
    json.dump(data, f, separators=(",", ":"))
    f.write("\n")
