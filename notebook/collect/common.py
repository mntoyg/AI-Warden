"""Shared pieces for the training-data collectors.

Every collector turns its source into *records*: one chat-format training
example each, ready for TRL's SFTTrainer and Qwen's chat template::

    {"messages": [{"role": "system", ...}, {"role": "user", ...},
                  {"role": "assistant", ...}],
     "source": "git:AI-Warden", "meta": {...}}

Nothing leaves this module unredacted: make_record() scrubs every message
with redact() first, because whatever reaches the training set can come
back out of the model word for word.
"""
from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Iterable, Iterator

SYSTEM_PROMPT = (
    "You are a careful coding assistant. Answer with working code and short, "
    "plain explanations. Never invent APIs; say when you are unsure."
)

# (kind, pattern, group to replace or 0 for the whole match). Order matters:
# the specific key formats run before the generic "password = ..." rule.
_SECRET_PATTERNS: list[tuple[str, re.Pattern[str], int]] = [
    ("private-key", re.compile(
        r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
        re.S), 0),
    ("anthropic-key", re.compile(r"sk-ant-[A-Za-z0-9_\-]{16,}"), 0),
    ("openai-key", re.compile(r"sk-(?:proj-)?[A-Za-z0-9_\-*]{16,}"), 0),
    ("github-token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"), 0),
    ("aws-key-id", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"), 0),
    ("stripe-key", re.compile(r"\b[rs]k_live_[0-9A-Za-z]{10,}"), 0),
    ("slack-token", re.compile(r"\bxox[abprs]-[0-9A-Za-z\-]{10,}"), 0),
    ("hf-token", re.compile(r"\bhf_[A-Za-z0-9]{30,}"), 0),
    ("google-key", re.compile(r"\bAIza[0-9A-Za-z_\-]{35}\b"), 0),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"), 0),
    ("email", re.compile(r"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}\b"), 0),
    # Only literal values: `token = get_token()` is code worth keeping, while
    # `token = "abc123..."` and `OPENAI_API_KEY=abc123...` are secrets.
    ("secret-value", re.compile(
        r"(?i)\b(?:api[_-]?key|secret(?:[_-]?key)?|access[_-]?token|auth[_-]?token|token|"
        r"password|passwd|aws_secret_access_key)\b[\"']?\s*[:=]\s*[\"']([^\s\"']{8,})[\"']"), 1),
    ("secret-value", re.compile(
        r"(?m)^\s*(?:export\s+)?[A-Z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD)[A-Z0-9_]*="
        r"([^\s\"'$][^\s\"']{7,})"), 1),
]


def redact(text: str) -> tuple[str, int]:
    """Replace anything that looks like a credential or an email address.

    Returns the scrubbed text and how many replacements were made.
    """
    count = 0
    for kind, pattern, group in _SECRET_PATTERNS:
        def _sub(m: re.Match[str], kind: str = kind, group: int = group) -> str:
            nonlocal count
            if group and m.group(group).startswith("<REDACTED:"):
                return m.group(0)
            count += 1
            if group == 0:
                return f"<REDACTED:{kind}>"
            start, end = m.start(group) - m.start(), m.end(group) - m.start()
            whole = m.group(0)
            return whole[:start] + f"<REDACTED:{kind}>" + whole[end:]
        text = pattern.sub(_sub, text)
    return text, count


_MARKER = re.compile(r"<REDACTED:[a-z-]+>")


def find_leaks(text: str) -> list[str]:
    """Kinds of secret still visible in already-redacted text (should be empty)."""
    bare = _MARKER.sub("", text)
    return [kind for kind, pattern, _ in _SECRET_PATTERNS if pattern.search(bare)]


def make_record(user: str, assistant: str, source: str, meta: dict | None = None,
                system: str | None = SYSTEM_PROMPT, max_chars: int = 12000,
                min_chars: int = 20) -> dict | None:
    """One single-turn record, redacted, or None if it is too short or long."""
    return make_chat_record([("user", user), ("assistant", assistant)], source,
                            meta, system, max_chars, min_chars)


def make_chat_record(turns: list[tuple[str, str]], source: str, meta: dict | None = None,
                     system: str | None = SYSTEM_PROMPT, max_chars: int = 12000,
                     min_chars: int = 20) -> dict | None:
    """A multi-turn record. Turns are (role, text) with role user/assistant.

    Leading turns are dropped until the record fits max_chars; it must still
    hold at least one user turn followed by an assistant turn.
    """
    clean: list[dict] = []
    redactions = 0
    for role, text in turns:
        if role not in ("user", "assistant") or not text or not text.strip():
            continue
        scrubbed, n = redact(text.strip())
        redactions += n
        clean.append({"role": role, "content": scrubbed})
    while clean and clean[0]["role"] != "user":
        clean.pop(0)
    while clean and sum(len(m["content"]) for m in clean) > max_chars:
        clean.pop(0)
        while clean and clean[0]["role"] != "user":
            clean.pop(0)
    while clean and clean[-1]["role"] != "assistant":
        clean.pop()
    if len(clean) < 2:
        return None
    if min(len(m["content"]) for m in clean) < 1 or \
            sum(len(m["content"]) for m in clean) < min_chars:
        return None
    messages = ([{"role": "system", "content": system}] if system else []) + clean
    return {"messages": messages, "source": source,
            "meta": dict(meta or {}, redactions=redactions)}


def record_key(record: dict) -> str:
    """Identity for de-duplication: the conversation without the system prompt."""
    body = [(m["role"], m["content"]) for m in record["messages"] if m["role"] != "system"]
    return hashlib.sha256(json.dumps(body, ensure_ascii=False).encode()).hexdigest()


def dedupe(records: Iterable[dict]) -> Iterator[dict]:
    seen: set[str] = set()
    for r in records:
        k = record_key(r)
        if k not in seen:
            seen.add(k)
            yield r


def write_jsonl(records: Iterable[dict], path: str | Path) -> int:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    n = 0
    with path.open("w", encoding="utf-8") as f:
        for r in records:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
            n += 1
    return n


def read_jsonl(path: str | Path) -> Iterator[dict]:
    with Path(path).open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                yield json.loads(line)
