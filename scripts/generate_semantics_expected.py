"""Render the core semantics cases of test/fixtures/semantics with Python Jinja2.

Usage (from the repository root):

    uv run --project scripts python -I scripts/generate_semantics_expected.py

Each case is a text file: a JSON object with the variables, a line with `---`, and the template. The
optional `$settings` key of the JSON object sets `trim_blocks`, `lstrip_blocks` and
`keep_trailing_newline`, or `transformers: true` for the chat template environment of transformers,
with its tojson filter and its raise_exception and strftime_now functions. The cases in `minijinja/`
come from the snapshot tests of minijinja (https://github.com/mitsuhiko/minijinja,
minijinja/tests/inputs, Apache-2.0). The cases in `otera/` are new. The expected results never come
from minijinja: this script renders every case with an ImmutableSandboxedEnvironment with the
loopcontrols extension, like transformers, and writes test/fixtures/semantics/expected.json.

It also renders the random cases of a differential check in test/fixtures/differential/cases.json,
which scripts/import_differential_cases.py made, and writes test/fixtures/differential/expected.json.
scripts/pyproject.toml and scripts/uv.lock pin the versions of Python, Jinja2 and transformers.
"""

import datetime as dt
import json
import os

import jinja2
from jinja2.ext import loopcontrols
from jinja2.sandbox import ImmutableSandboxedEnvironment
from transformers.utils import chat_template_utils

FIXED_NOW = dt.datetime(2025, 3, 9, 14, 30, 5)


class FixedDatetime(dt.datetime):
    @classmethod
    def now(cls, tz=None):
        return FIXED_NOW

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CASES = os.path.join(ROOT, "test", "fixtures", "semantics")
DIFFERENTIAL = os.path.join(ROOT, "test", "fixtures", "differential")


def render_file(path):
    with open(path, encoding="utf-8", newline="") as f:
        variables, source = f.read().split("\n---\n", 1)
    variables = json.loads(variables)
    return render(source, variables, variables.pop("$settings", {}))


def render(source, variables, settings):
    settings = dict(settings)
    try:
        if settings.pop("transformers", False):
            template = chat_template_utils._compile_jinja_template(source)
        else:
            template = ImmutableSandboxedEnvironment(extensions=[loopcontrols], **settings).from_string(source)
        return {"output": template.render(**variables)}
    except jinja2.TemplateSyntaxError as error:
        return {"error": {"type": type(error).__name__, "message": error.message, "line": error.lineno}}
    except Exception as error:
        return {"error": {"type": type(error).__name__, "message": str(error)}}


def main():
    chat_template_utils.datetime = FixedDatetime
    expected = {}
    for directory in sorted(os.listdir(CASES)):
        if os.path.isdir(os.path.join(CASES, directory)):
            for name in sorted(os.listdir(os.path.join(CASES, directory))):
                expected[f"{directory}/{name}"] = render_file(os.path.join(CASES, directory, name))

    write(os.path.join(CASES, "expected.json"), expected)

    with open(os.path.join(DIFFERENTIAL, "cases.json"), encoding="utf-8") as f:
        cases = json.load(f)

    expected = {c["name"]: render(c["template"], json.loads(c["variables"]), c["settings"]) for c in cases}
    write(os.path.join(DIFFERENTIAL, "expected.json"), expected)


def write(path, expected):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(expected, f, ensure_ascii=False, indent=1)
        f.write("\n")

    errors = sum("error" in case for case in expected.values())
    print(f"{path}: {len(expected)} cases, {errors} raise an error")


if __name__ == "__main__":
    main()
