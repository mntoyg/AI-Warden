"""Helpers for train.ipynb that can be tested without a GPU.

- verify_dataset(): the data you train on is the data collect_data.ipynb
  described (sha256 from its manifest.json), not a file edited since.
- accepted_kwargs(): TRL renames arguments between releases (max_seq_length
  -> max_length, tokenizer -> processing_class); pass only what the
  installed version accepts instead of pinning a combination that rots.
- write_model_manifest(): the manifest AI Warden's `aider-local` checks
  before it loads a model (scripts/warden-cli.sh verify_model_manifest).
"""
from __future__ import annotations

import datetime as _dt
import hashlib
import inspect
import json
import re
from pathlib import Path

MODEL_SCHEMA = "warden-model-lab/manifest/1"
DATASET_SCHEMA = "warden-model-lab/dataset/1"

# Same argument, different names across library versions.
ALIASES = {
    "max_seq_length": "max_length", "max_length": "max_seq_length",
    "processing_class": "tokenizer", "tokenizer": "processing_class",
    "eval_strategy": "evaluation_strategy", "evaluation_strategy": "eval_strategy",
}


def sha256_file(path: str | Path) -> str:
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def verify_dataset(data_dir: str | Path) -> dict:
    """Return the dataset manifest after checking every file against it."""
    data_dir = Path(data_dir)
    manifest = json.loads((data_dir / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("schema") != DATASET_SCHEMA:
        raise ValueError(f"not a {DATASET_SCHEMA} manifest: {manifest.get('schema')!r}")
    for split in ("train", "val"):
        want = manifest[split]["sha256"]
        got = sha256_file(data_dir / f"{split}.jsonl")
        if got != want:
            raise ValueError(f"{split}.jsonl changed since it was collected "
                             f"(sha256 {got[:16]}... != manifest {want[:16]}...)")
    return manifest


def accepted_kwargs(target, kwargs: dict) -> dict:
    """kwargs filtered to what `target` (a class or function) accepts, renaming aliases."""
    params = inspect.signature(target).parameters
    if any(p.kind is p.VAR_KEYWORD for p in params.values()) and not \
            any(k in params for k in kwargs):
        return dict(kwargs)
    out = {}
    for key, value in kwargs.items():
        if key in params:
            out[key] = value
        elif ALIASES.get(key) in params:
            out[ALIASES[key]] = value
    return out


def write_model_manifest(gguf_path: str | Path, model_name: str, base_model: str,
                         dataset_manifest: dict | None = None, extra: dict | None = None) -> Path:
    """Write manifest.json next to the GGUF, in the shape warden-cli.sh accepts.

    The CLI reads "gguf_file" and "gguf_sha256" line by line with sed, so the
    file is indented JSON with one key per line, and gguf_file is a plain
    file name in the same directory.
    """
    gguf_path = Path(gguf_path)
    if gguf_path.suffix != ".gguf" or not re.fullmatch(r"[A-Za-z0-9._-]+", gguf_path.name):
        raise ValueError(f"the model file must be a plain *.gguf name: {gguf_path.name!r}")
    manifest = {
        "schema": MODEL_SCHEMA,
        "model_name": model_name,
        "gguf_file": gguf_path.name,
        "gguf_sha256": sha256_file(gguf_path),
        "base_model": base_model,
        "created_utc": _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    if dataset_manifest:
        manifest["dataset"] = {"train_sha256": dataset_manifest["train"]["sha256"],
                               "train_records": dataset_manifest["train"]["records"],
                               "records_by_source": dataset_manifest.get("records_by_source", {})}
    if extra:
        manifest.update(extra)
    out = gguf_path.parent / "manifest.json"
    out.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return out
