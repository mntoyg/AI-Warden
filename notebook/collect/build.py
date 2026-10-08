"""Merge every source into train/val JSONL plus a manifest.

    python -m collect.build --out data \\
        --git ~/code/AI-Warden --files ~/code/AI-Warden \\
        --chats ~/exports/claude/conversations.json \\
        --hf ise-uiuc/Magicoder-OSS-Instruct-75K --hf-limit 3000 --hf-langs python,shell

Run it from the notebook/ directory. The output lands in notebook/data/,
which git ignores: it may hold your private code and chats.
"""
from __future__ import annotations

import argparse
import collections
import datetime as _dt
import hashlib
import json
import random
from pathlib import Path
from typing import Iterable

from .common import dedupe, write_jsonl


def build(sources: dict[str, Iterable[dict]], out_dir: str | Path, val_ratio: float = 0.05,
          seed: int = 13) -> dict:
    """Run every source, de-duplicate, shuffle, split, write, describe."""
    out = Path(out_dir)
    records: list[dict] = []
    per_source: dict[str, int] = {}
    for name, recs in sources.items():
        before = len(records)
        records.extend(recs)
        per_source[name] = len(records) - before
    unique = list(dedupe(records))
    random.Random(seed).shuffle(unique)
    n_val = max(1, int(len(unique) * val_ratio)) if len(unique) >= 20 else 0
    val, train = unique[:n_val], unique[n_val:]
    write_jsonl(train, out / "train.jsonl")
    write_jsonl(val, out / "val.jsonl")
    def sha(p: Path) -> str:
        return hashlib.sha256(p.read_bytes()).hexdigest()
    manifest = {
        "schema": "warden-model-lab/dataset/1",
        "created_utc": _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "format": "chat messages (system/user/assistant), one JSON object per line",
        "collected_per_source": per_source,
        "duplicates_dropped": len(records) - len(unique),
        "train": {"records": len(train), "sha256": sha(out / "train.jsonl")},
        "val": {"records": len(val), "sha256": sha(out / "val.jsonl")},
        "records_by_source": dict(collections.Counter(r["source"] for r in unique)),
        "redactions": sum(r["meta"].get("redactions", 0) for r in unique),
        "chars": sum(len(m["content"]) for r in unique for m in r["messages"]),
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
                                       encoding="utf-8")
    return manifest


def main(argv: list[str] | None = None) -> int:
    from . import from_chats, from_files, from_git, from_hf
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default="data")
    ap.add_argument("--git", action="append", default=[], help="a git repo (repeatable)")
    ap.add_argument("--files", action="append", default=[], help="a project dir (repeatable)")
    ap.add_argument("--chats", action="append", default=[], help="conversations.json (repeatable)")
    ap.add_argument("--hf", action="append", default=[], help="a Hub dataset id (repeatable)")
    ap.add_argument("--hf-limit", type=int, default=3000)
    ap.add_argument("--hf-langs", default="", help="comma list, e.g. python,shell")
    ap.add_argument("--val-ratio", type=float, default=0.05)
    a = ap.parse_args(argv)
    langs = {x.strip().lower() for x in a.hf_langs.split(",") if x.strip()} or None
    sources: dict[str, Iterable[dict]] = {}
    for p in a.git:
        sources[f"git:{p}"] = from_git.collect(p)
    for p in a.files:
        sources[f"files:{p}"] = from_files.collect(p)
    for p in a.chats:
        sources[f"chats:{p}"] = from_chats.collect(p)
    for d in a.hf:
        sources[f"hf:{d}"] = from_hf.collect(d, limit=a.hf_limit, langs=langs)
    if not sources:
        ap.error("give at least one source")
    print(json.dumps(build(sources, a.out, a.val_ratio), indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
