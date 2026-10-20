"""Import the cases of a differential check of Otera against Python Jinja2 into test/fixtures/differential.

Usage (from the repository root):

    uv run --project scripts python -I scripts/import_differential_cases.py VERIFIER_DIR

VERIFIER_DIR has the files cases1.json to cases9.json, which hold about 3000 random templates. Each case
has an "id", a template "t", the variables "v" as JSON text, and the settings "s": "chat" for the
environment of transformers, or a dict of trim_blocks, lstrip_blocks and keep_trailing_newline. The
results of VERIFIER_DIR/py*.json show which cases Python renders with a memory address.

The script leaves out the cases that Otera does not match on purpose:

- Python prints the memory address of a function or an iterator, which changes on each run.
- The random filter and lipsum give random output.
- Python raises its own SyntaxError, with a line of the compiled Python code, for break and continue outside a loop.
- The cases in EXCEPTIONS differ by design, for the reason next to each one.

scripts/generate_semantics_expected.py renders the cases with Python.
"""

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "test", "fixtures", "differential", "cases.json")

INF_NAN = "Elixir floats have no inf, nan or complex values, so Otera raises an error where Python gives one"

EXCEPTIONS = {
    "b2_0380": INF_NAN,
    "b2_0381": INF_NAN,
    "b2_0382": INF_NAN,
    "b2_0383": INF_NAN,
    "b2_0384": INF_NAN,
    "b2_0385": INF_NAN,
    "b2_0492": INF_NAN,
    "b2_0493": INF_NAN,
    "b2_0494": INF_NAN,
    "b2_0495": INF_NAN,
    "b3_0002": INF_NAN,
    "b3_0006": INF_NAN,
    "b3_0009": INF_NAN,
    "b6_0030": INF_NAN,
    "b6_0031": INF_NAN,
    "b6_0178": INF_NAN + " (a JSON number of 1E400)",
    "b6_0179": INF_NAN + " (a JSON number of -1E400)",
    "b2_0624": "An Elixir string cannot hold a lone surrogate like \\ud800",
    "b5_0159": "Otera has no table of Unicode character names for \\N{...}",
    "b7_0428": "Otera has no table of Unicode character names for \\N{...}",
    "b9_0016": "Otera values have no identity, so sameas compares two empty lists as the same",
}

LEFT_OUT = [
    re.compile(r"\|\s*random\b|lipsum\("),
]


def left_out(case, python):
    if case["id"] in EXCEPTIONS:
        return True
    if any(pattern.search(case["t"]) for pattern in LEFT_OUT):
        return True
    if " at 0x" in json.dumps(python) or python.get("kind") == "syntax_error":
        return True
    return False


def main():
    directory = sys.argv[1]
    cases = []
    for batch in range(1, 10):
        with open(os.path.join(directory, f"cases{batch}.json"), encoding="utf-8") as f:
            batch_cases = json.load(f)
        with open(os.path.join(directory, f"py{batch}.json"), encoding="utf-8") as f:
            python = json.load(f)
        for case in batch_cases:
            if not left_out(case, python[case["id"]]):
                settings = case.get("s", "chat")
                cases.append(
                    {
                        "name": case["id"],
                        "template": case["t"],
                        "variables": case["v"],
                        "settings": {"transformers": True} if settings == "chat" else settings,
                    }
                )

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(cases, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print(f"{len(cases)} cases imported")


if __name__ == "__main__":
    main()
