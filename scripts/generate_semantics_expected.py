"""Render the core semantics cases of test/fixtures/semantics with Python Jinja2.

Usage (from the repository root):

    uv run --no-project --with jinja2==3.1.6 python -I scripts/generate_semantics_expected.py

Each case is a text file: a JSON object with the variables, a line with `---`, and the template. The
optional `$settings` key of the JSON object sets `trim_blocks`, `lstrip_blocks` and
`keep_trailing_newline`. The cases in `minijinja/` come from the snapshot tests of minijinja
(https://github.com/mitsuhiko/minijinja, minijinja/tests/inputs, Apache-2.0). The cases in `otera/`
are new. The expected results never come from minijinja: this script renders every case with the
environment of transformers, an ImmutableSandboxedEnvironment with the loopcontrols extension, and
writes test/fixtures/semantics/expected.json.
"""

import json
import os

import jinja2
from jinja2.ext import loopcontrols
from jinja2.sandbox import ImmutableSandboxedEnvironment

JINJA2_VERSION = "3.1.6"

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CASES = os.path.join(ROOT, "test", "fixtures", "semantics")


def render(path):
    with open(path, encoding="utf-8", newline="") as f:
        variables, source = f.read().split("\n---\n", 1)
    variables = json.loads(variables)
    settings = variables.pop("$settings", {})
    env = ImmutableSandboxedEnvironment(extensions=[loopcontrols], **settings)
    try:
        return {"output": env.from_string(source).render(**variables)}
    except jinja2.TemplateSyntaxError as error:
        return {"error": {"type": type(error).__name__, "message": error.message, "line": error.lineno}}
    except Exception as error:
        return {"error": {"type": type(error).__name__, "message": str(error)}}


def main():
    assert jinja2.__version__ == JINJA2_VERSION, jinja2.__version__
    expected = {}
    for directory in sorted(os.listdir(CASES)):
        if os.path.isdir(os.path.join(CASES, directory)):
            for name in sorted(os.listdir(os.path.join(CASES, directory))):
                expected[f"{directory}/{name}"] = render(os.path.join(CASES, directory, name))

    with open(os.path.join(CASES, "expected.json"), "w", encoding="utf-8") as f:
        json.dump(expected, f, ensure_ascii=False, indent=1)
        f.write("\n")

    errors = sum("error" in case for case in expected.values())
    print(f"{len(expected)} cases, {errors} raise an error")


if __name__ == "__main__":
    main()
