"""Commits of your own git repositories -> "make this change" examples.

Each non-merge commit whose code diff is small enough becomes one record:
the user asks for the change in the words of the commit message, the
assistant answers with the diff. Authors and emails are never read.
"""
from __future__ import annotations

import re
import subprocess
from pathlib import Path
from typing import Iterator

from .common import make_record

CODE_SUFFIXES = (
    ".py", ".sh", ".bash", ".js", ".ts", ".tsx", ".jsx", ".go", ".rs", ".java",
    ".kt", ".c", ".h", ".cpp", ".hpp", ".cs", ".rb", ".php", ".sql", ".yml",
    ".yaml", ".toml", ".ini", ".cfg", ".conf", ".json", ".html", ".css",
)
CODE_NAMES = ("Dockerfile", "Makefile", "docker-compose.yml")

_FIELD, _RECORD = "\x1f", "\x1e"


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True,
                          capture_output=True, text=True, errors="replace").stdout


def is_code_path(path: str, include_docs: bool = False) -> bool:
    name = path.rsplit("/", 1)[-1]
    if include_docs and name.endswith(".md"):
        return True
    return name in CODE_NAMES or name.endswith(CODE_SUFFIXES)


_TRAILER = re.compile(r"^[A-Z][A-Za-z0-9-]*: \S")


def strip_trailers(body: str) -> str:
    """Drop the closing block of git trailers (Co-Authored-By:, Signed-off-by:, ...)."""
    lines = body.rstrip().splitlines()
    while lines and _TRAILER.match(lines[-1]):
        lines.pop()
    return "\n".join(lines).rstrip()


def collect(repo: str | Path, max_diff_chars: int = 6000, min_diff_chars: int = 40,
            include_docs: bool = False, limit: int | None = None) -> Iterator[dict]:
    repo = Path(repo)
    name = repo.resolve().name
    log = _git(repo, "log", "--no-merges", f"--format=%H{_FIELD}%s{_FIELD}%b{_RECORD}")
    made = 0
    for entry in log.split(_RECORD):
        entry = entry.strip("\n")
        if not entry:
            continue
        sha, subject, body = (entry.split(_FIELD) + ["", ""])[:3]
        files = [f for f in _git(repo, "show", "--format=", "--name-only", sha).splitlines()
                 if f and is_code_path(f, include_docs)]
        if not files:
            continue
        diff = _git(repo, "show", "--format=", "--unified=3", sha, "--", *files)
        if not (min_diff_chars <= len(diff) <= max_diff_chars):
            continue
        ask = f"Repository: {name}\nMake this change:\n{subject.strip()}"
        body = strip_trailers(body)
        if body:
            ask += "\n\n" + body
        rec = make_record(ask, f"```diff\n{diff.rstrip()}\n```", f"git:{name}",
                          {"commit": sha[:12], "files": files})
        if rec:
            yield rec
            made += 1
            if limit and made >= limit:
                return
