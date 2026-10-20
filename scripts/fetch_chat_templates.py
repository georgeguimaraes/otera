"""Fetch the chat templates of popular Hugging Face models into test/fixtures/chat_templates.

Usage (from the repository root):

    uv run --project scripts python -I scripts/fetch_chat_templates.py

The script takes the most downloaded text-generation models of the Hub, plus a fixed list of
model families that the corpus must cover. It reads the chat template of each model from
`chat_template.jinja` (and `additional_chat_templates/*.jinja`), from `chat_template.json`, or
from the `chat_template` field of `tokenizer_config.json`, in that order, like transformers.
It removes duplicate templates by content and writes each template to `<name>.jinja`, with
`manifest.json` that records the source repository, file and special tokens of each template.

Gated repositories need HF_TOKEN. Without it, the script uses the public mirror in REQUIRED.
"""

import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "test", "fixtures", "chat_templates")
HUB = "https://huggingface.co"
TOKEN = os.environ.get("HF_TOKEN")
TOP_MODELS = 300

# Model families the corpus must cover. The second element is a public mirror for a gated repository.
REQUIRED = [
    ("HuggingFaceTB/SmolLM2-1.7B-Instruct", None),
    ("HuggingFaceTB/SmolLM3-3B", None),
    ("Qwen/Qwen2.5-7B-Instruct", None),
    ("Qwen/Qwen2.5-Coder-7B-Instruct", None),
    ("Qwen/Qwen2.5-Math-7B-Instruct", None),
    ("Qwen/QwQ-32B", None),
    ("Qwen/Qwen3-8B", None),
    ("Qwen/Qwen3-4B-Instruct-2507", None),
    ("Qwen/Qwen3-4B-Thinking-2507", None),
    ("Qwen/Qwen3-Coder-30B-A3B-Instruct", None),
    ("meta-llama/Llama-3.1-8B-Instruct", "unsloth/Llama-3.1-8B-Instruct"),
    ("meta-llama/Llama-3.2-1B-Instruct", "unsloth/Llama-3.2-1B-Instruct"),
    ("meta-llama/Llama-3.2-11B-Vision-Instruct", "unsloth/Llama-3.2-11B-Vision-Instruct"),
    ("meta-llama/Llama-3.3-70B-Instruct", "unsloth/Llama-3.3-70B-Instruct"),
    ("meta-llama/Meta-Llama-3-8B-Instruct", "unsloth/llama-3-8b-Instruct"),
    ("meta-llama/Llama-4-Scout-17B-16E-Instruct", "unsloth/Llama-4-Scout-17B-16E-Instruct"),
    ("google/gemma-2-2b-it", "unsloth/gemma-2-2b-it"),
    ("google/gemma-3-1b-it", "unsloth/gemma-3-1b-it"),
    ("google/gemma-3-4b-it", "unsloth/gemma-3-4b-it"),
    ("google/gemma-3n-E4B-it", "unsloth/gemma-3n-E4B-it"),
    ("mistralai/Mistral-7B-Instruct-v0.1", None),
    ("mistralai/Mistral-7B-Instruct-v0.2", "unsloth/mistral-7b-instruct-v0.2"),
    ("mistralai/Mistral-7B-Instruct-v0.3", "unsloth/mistral-7b-instruct-v0.3"),
    ("mistralai/Mixtral-8x7B-Instruct-v0.1", "unsloth/Mixtral-8x7B-Instruct-v0.1"),
    ("mistralai/Mistral-Nemo-Instruct-2407", "unsloth/Mistral-Nemo-Instruct-2407"),
    ("mistralai/Mistral-Small-24B-Instruct-2501", "unsloth/Mistral-Small-24B-Instruct-2501"),
    ("microsoft/Phi-3-mini-4k-instruct", None),
    ("microsoft/Phi-3.5-mini-instruct", None),
    ("microsoft/phi-4", None),
    ("microsoft/Phi-4-mini-instruct", None),
    ("microsoft/Phi-4-reasoning", None),
    ("deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B", None),
    ("deepseek-ai/DeepSeek-R1-Distill-Llama-8B", None),
    ("deepseek-ai/DeepSeek-R1-0528-Qwen3-8B", None),
    ("deepseek-ai/DeepSeek-V3", None),
    ("ibm-granite/granite-3.1-8b-instruct", None),
    ("ibm-granite/granite-3.3-8b-instruct", None),
    ("ibm-granite/granite-4.0-micro", None),
    ("NousResearch/Hermes-3-Llama-3.1-8B", None),
    ("NousResearch/Hermes-2-Pro-Llama-3-8B", None),
    ("CohereLabs/c4ai-command-r-08-2024", "unsloth/c4ai-command-r-08-2024"),
    ("allenai/OLMo-2-1124-7B-Instruct", None),
    ("tiiuae/Falcon3-7B-Instruct", None),
    ("HuggingFaceH4/zephyr-7b-beta", None),
    ("TinyLlama/TinyLlama-1.1B-Chat-v1.0", None),
    ("openai/gpt-oss-20b", None),
]

SPECIAL_TOKENS = ["bos_token", "eos_token", "unk_token", "sep_token", "pad_token", "cls_token", "mask_token"]


def get(url, as_json=True, attempt=1):
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {TOKEN}"} if TOKEN else {})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            body = response.read().decode("utf-8")
    except urllib.error.HTTPError as error:
        if error.code in (401, 403, 404):
            return None
        if error.code == 429 and attempt < 8:
            time.sleep(int(error.headers.get("Retry-After") or 10 * attempt))
            return get(url, as_json, attempt + 1)
        raise
    return json.loads(body) if as_json else body


def model_info(repo):
    query = "expand[]=siblings&expand[]=gated&expand[]=downloads"
    return get(f"{HUB}/api/models/{repo}?{query}")


def file_url(repo, path):
    return f"{HUB}/{repo}/resolve/main/{urllib.parse.quote(path)}"


def token_content(value):
    return value.get("content") if isinstance(value, dict) else value


def special_tokens(repo, files):
    config = get(file_url(repo, "tokenizer_config.json")) if "tokenizer_config.json" in files else None
    tokens_map = get(file_url(repo, "special_tokens_map.json")) if "special_tokens_map.json" in files else None
    tokens = {}
    for name in SPECIAL_TOKENS:
        value = token_content((config or {}).get(name)) or token_content((tokens_map or {}).get(name))
        if isinstance(value, str):
            tokens[name] = value
    return tokens, config


def templates(repo, files, config):
    """Returns [(template_name, file, source)] for a repository, like transformers loads them."""
    if "chat_template.jinja" in files:
        found = [("default", "chat_template.jinja", get(file_url(repo, "chat_template.jinja"), as_json=False))]
        for path in sorted(f for f in files if f.startswith("additional_chat_templates/") and f.endswith(".jinja")):
            name = os.path.basename(path)[: -len(".jinja")]
            found.append((name, path, get(file_url(repo, path), as_json=False)))
        return found

    if "chat_template.json" in files:
        data = get(file_url(repo, "chat_template.json"))
        return [("default", "chat_template.json", data["chat_template"])] if data else []

    template = (config or {}).get("chat_template")
    if isinstance(template, str):
        return [("default", "tokenizer_config.json", template)]
    if isinstance(template, list):
        return [(t["name"], "tokenizer_config.json", t["template"]) for t in template]
    return []


def fetch(repo, mirror_of=None):
    info = model_info(repo)
    if info is None:
        return repo, mirror_of, None, "not found"
    if info.get("gated") and not TOKEN:
        return repo, mirror_of, None, "gated"
    files = {s["rfilename"] for s in info.get("siblings", [])}
    tokens, config = special_tokens(repo, files)
    found = [(name, path, source) for name, path, source in templates(repo, files, config) if source]
    return repo, mirror_of, {"downloads": info.get("downloads", 0), "tokens": tokens, "templates": found}, None


def top_models():
    query = urllib.parse.urlencode(
        {"pipeline_tag": "text-generation", "sort": "downloads", "direction": "-1", "limit": TOP_MODELS}
    )
    return [m["id"] for m in get(f"{HUB}/api/models?{query}")]


def main():
    repos = []
    for repo, mirror in REQUIRED:
        repos.append((mirror, repo) if mirror and not TOKEN else (repo, None))
    required = {repo for repo, _ in repos}
    repos += [(repo, None) for repo in top_models() if repo not in required]

    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(lambda pair: fetch(*pair), repos))

    by_hash = {}
    skipped = []
    for repo, mirror_of, result, reason in results:
        if result is None:
            skipped.append(f"{repo}: {reason}")
            continue
        for name, path, source in result["templates"]:
            digest = hashlib.sha256(source.encode("utf-8")).hexdigest()
            entry = {
                "repo": repo,
                "mirror_of": mirror_of,
                "template_name": name,
                "file": path,
                "downloads": result["downloads"],
                "special_tokens": result["tokens"],
                "source": source,
            }
            current = by_hash.get(digest)
            if current is None:
                by_hash[digest] = {**entry, "also_in": []}
            else:
                current["also_in"].append(repo)

    os.makedirs(OUT_DIR, exist_ok=True)
    for old in os.listdir(OUT_DIR):
        if old.endswith(".jinja"):
            os.remove(os.path.join(OUT_DIR, old))

    manifest = []
    for entry in sorted(by_hash.values(), key=lambda e: (e["repo"].lower(), e["template_name"])):
        name = entry["repo"].lower().replace("/", "--")
        if entry["template_name"] != "default":
            name += "--" + entry["template_name"]
        with open(os.path.join(OUT_DIR, name + ".jinja"), "w", encoding="utf-8", newline="") as f:
            f.write(entry.pop("source"))
        manifest.append({"name": name, **entry})

    with open(os.path.join(OUT_DIR, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print(f"{len(manifest)} distinct templates from {len(repos)} repositories")
    for line in skipped:
        print(f"skipped {line}", file=sys.stderr)


if __name__ == "__main__":
    main()
