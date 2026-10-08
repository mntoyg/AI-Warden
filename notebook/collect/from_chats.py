"""Your own AI chat exports -> multi-turn examples.

Reads the ``conversations.json`` inside a Claude export (Settings > Privacy >
Export data) or a ChatGPT export (Settings > Data controls > Export). These
are private: keep them and everything built from them out of git.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Iterator

from .common import make_chat_record

CODE_HINTS = ("```", "def ", "function ", "class ", "#!/", "import ", "$ ", "docker ", "git ")


def _claude_text(msg: dict) -> str:
    if isinstance(msg.get("text"), str) and msg["text"].strip():
        return msg["text"]
    parts = [c.get("text", "") for c in msg.get("content") or [] if c.get("type") == "text"]
    return "\n".join(p for p in parts if p)


def claude_turns(conv: dict) -> list[tuple[str, str]]:
    roles = {"human": "user", "assistant": "assistant"}
    return [(roles[m.get("sender")], _claude_text(m)) for m in conv.get("chat_messages") or []
            if m.get("sender") in roles]


def chatgpt_turns(conv: dict) -> list[tuple[str, str]]:
    """The thread that ends at current_node (edits create side branches)."""
    mapping = conv.get("mapping") or {}
    node = conv.get("current_node")
    chain: list[dict] = []
    while node and node in mapping:
        chain.append(mapping[node])
        node = mapping[node].get("parent")
    turns: list[tuple[str, str]] = []
    for item in reversed(chain):
        msg = item.get("message") or {}
        role = (msg.get("author") or {}).get("role")
        content = msg.get("content") or {}
        if role not in ("user", "assistant") or content.get("content_type") != "text":
            continue
        text = "\n".join(p for p in content.get("parts") or [] if isinstance(p, str))
        turns.append((role, text))
    return turns


def detect(conv: dict) -> str | None:
    if "chat_messages" in conv:
        return "claude"
    if "mapping" in conv:
        return "chatgpt"
    return None


def collect(path: str | Path, code_only: bool = True, max_chars: int = 12000) -> Iterator[dict]:
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    for conv in data if isinstance(data, list) else []:
        kind = detect(conv)
        if kind is None:
            continue
        turns = claude_turns(conv) if kind == "claude" else chatgpt_turns(conv)
        if code_only and not any(h in t for _, t in turns for h in CODE_HINTS):
            continue
        rec = make_chat_record(turns, f"chat:{kind}", {"turns": len(turns)}, max_chars=max_chars)
        if rec:
            yield rec
