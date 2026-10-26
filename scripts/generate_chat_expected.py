"""Render every chat template of the corpus with every conversation, like transformers.

Usage (from the repository root):

    uv run --project scripts python -I scripts/generate_chat_expected.py

The script reads test/fixtures/chat_templates/manifest.json and test/fixtures/conversations.json,
renders each pair with `render_jinja_template` of transformers, which `apply_chat_template` uses,
and writes test/fixtures/chat_expected/<template>.json. Each case has the rendered "output", or the
"error" type and message when the template raises. The variables of each render are the special
tokens of the template and the "variables" of the conversation. `strftime_now` sees a fixed time,
so that the output does not change from day to day. scripts/pyproject.toml and scripts/uv.lock pin
the versions of Python, Jinja2 and transformers.
"""

import datetime as dt
import json
import os
import re
import sys

import jinja2
import jinja2.debug
import jinja2.utils

from transformers.utils import chat_template_utils
from transformers.utils.chat_template_utils import render_jinja_template

FIXED_NOW = dt.datetime(2025, 3, 9, 14, 30, 5)

def record_position(rewrite):
    """Wrap jinja2.debug.rewrite_traceback_stack to keep the line of a runtime error, like the template traceback.

    scripts/generate_semantics_expected.py has the same function.
    """

    def wrapper(source=None):
        _, error, tb = sys.exc_info()
        while tb is not None:
            template = tb.tb_frame.f_globals.get("__jinja_template__")
            # Like the traceback of Jinja2, skip the internal functions, such as the stub of a missing test.
            if template is not None and tb.tb_frame.f_code not in jinja2.utils.internal_code:
                error.template_line = template.get_corresponding_lineno(tb.tb_lineno)
            tb = tb.tb_next
        return rewrite(source)

    return wrapper


ERRNO_MESSAGE = re.compile(r"^\((\d+), '.*'\)$")


def canonical_message(message):
    """Drops the strerror text of an "(errno, strerror)" message.

    CPython renders a math range error as "(34, strerror(ERANGE))", and that
    text belongs to libc: macOS says "Result too large" and glibc says
    "Numerical result out of range". Only the errno is portable, so a fixture
    keeps the errno alone and stays the same on every platform.
    Otera.Differential in test/test_helper.exs applies the same rule.
    """
    match = ERRNO_MESSAGE.match(message)
    return f"(errno {match.group(1)})" if match else message


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(ROOT, "test", "fixtures")
TEMPLATES = os.path.join(FIXTURES, "chat_templates")
OUT_DIR = os.path.join(FIXTURES, "chat_expected")


class FixedDatetime(dt.datetime):
    @classmethod
    def now(cls, tz=None):
        return FIXED_NOW


def render(source, conversation, special_tokens):
    variables = {**special_tokens, **conversation.get("variables", {})}
    try:
        rendered, _ = render_jinja_template(
            conversations=[conversation["messages"]],
            tools=conversation.get("tools"),
            documents=conversation.get("documents"),
            chat_template=source,
            continue_final_message=conversation.get("continue_final_message", False),
            add_generation_prompt=conversation["add_generation_prompt"],
            **variables,
        )
        return {"output": rendered[0]}
    except jinja2.TemplateSyntaxError as error:
        return {"error": {"type": type(error).__name__, "message": error.message, "line": error.lineno}}
    except Exception as error:
        described = {"type": type(error).__name__, "message": canonical_message(str(error))}
        if hasattr(error, "template_line"):
            described["line"] = error.template_line
        return {"error": described}


def main():
    chat_template_utils.datetime = FixedDatetime
    jinja2.debug.rewrite_traceback_stack = record_position(jinja2.debug.rewrite_traceback_stack)

    with open(os.path.join(TEMPLATES, "manifest.json"), encoding="utf-8") as f:
        manifest = json.load(f)
    with open(os.path.join(FIXTURES, "conversations.json"), encoding="utf-8") as f:
        conversations = json.load(f)

    os.makedirs(OUT_DIR, exist_ok=True)
    for old in os.listdir(OUT_DIR):
        os.remove(os.path.join(OUT_DIR, old))

    errors = 0
    for entry in manifest:
        with open(os.path.join(TEMPLATES, entry["name"] + ".jinja"), encoding="utf-8", newline="") as f:
            source = f.read()
        cases = {c["name"]: render(source, c, entry["special_tokens"]) for c in conversations}
        errors += sum("error" in case for case in cases.values())
        with open(os.path.join(OUT_DIR, entry["name"] + ".json"), "w", encoding="utf-8") as f:
            json.dump(cases, f, ensure_ascii=False, indent=1)
            f.write("\n")

    total = len(manifest) * len(conversations)
    print(f"{total} cases from {len(manifest)} templates, {errors} raise an error")


if __name__ == "__main__":
    main()
