"""Render every chat template of the corpus with every conversation, like transformers.

Usage (from the repository root):

    uv run --no-project --with transformers==5.20.2 --with jinja2==3.1.6 python -I scripts/generate_chat_expected.py

The script reads test/fixtures/chat_templates/manifest.json and test/fixtures/conversations.json,
renders each pair with `render_jinja_template` of transformers, which `apply_chat_template` uses,
and writes test/fixtures/chat_expected/<template>.json. Each case has the rendered "output", or the
"error" type and message when the template raises. The variables of each render are the special
tokens of the template and the "variables" of the conversation. `strftime_now` sees a fixed time,
so that the output does not change from day to day.
"""

import datetime as dt
import json
import os

import jinja2
import transformers
from transformers.utils import chat_template_utils
from transformers.utils.chat_template_utils import render_jinja_template

TRANSFORMERS_VERSION = "5.20.2"
JINJA2_VERSION = "3.1.6"
FIXED_NOW = dt.datetime(2025, 3, 9, 14, 30, 5)

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
    except Exception as error:
        return {"error": {"type": type(error).__name__, "message": str(error)}}


def main():
    assert transformers.__version__ == TRANSFORMERS_VERSION, transformers.__version__
    assert jinja2.__version__ == JINJA2_VERSION, jinja2.__version__
    chat_template_utils.datetime = FixedDatetime

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
