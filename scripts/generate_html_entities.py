"""Write the HTML5 character references of Python html.unescape to priv/html_entities.json.

Usage (from the repository root):

    uv run --project scripts python -I scripts/generate_html_entities.py

Otera.HTML reads this file at compile time to unescape HTML like Python, for the striptags filter.
"""

import html
import html.entities
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

data = {
    "named": html.entities.html5,
    "invalid_charrefs": {str(k): v for k, v in html._invalid_charrefs.items()},
    "invalid_codepoints": sorted(html._invalid_codepoints),
}

with open(os.path.join(ROOT, "priv", "html_entities.json"), "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, sort_keys=True)
    f.write("\n")
