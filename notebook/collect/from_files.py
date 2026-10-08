"""Docs and source files of a project -> explain / write-this-function examples.

- Markdown: every section with a real body becomes "explain <heading>".
- Python: every function or class with a docstring becomes "write <name>
  that does <docstring>", answered with its source.
- Bash: every function preceded by a comment block becomes the same.

Point it at AI Warden to teach the model this project, or at any of your
own repositories.
"""
from __future__ import annotations

import ast
import re
from pathlib import Path
from typing import Iterator

from .common import make_record

SKIP_DIRS = {".git", "node_modules", ".venv", "venv", "__pycache__", "dist", "build",
             "data", "outputs", "workspaces"}

_HEADING = re.compile(r"^(#{1,4})\s+(.+?)\s*#*\s*$")
_BASH_FUNC = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{")


def _files(root: Path, suffixes: tuple[str, ...]) -> Iterator[Path]:
    for p in sorted(root.rglob("*")):
        if p.is_file() and p.suffix in suffixes and not (SKIP_DIRS & set(p.relative_to(root).parts[:-1])):
            yield p


def markdown_sections(text: str) -> Iterator[tuple[str, str]]:
    """(heading path, body) for every section; fenced code does not end a section."""
    path: list[str] = []
    body: list[str] = []
    fence = False
    def flush() -> Iterator[tuple[str, str]]:
        if path and "".join(body).strip():
            yield " > ".join(path), "\n".join(body).strip()
    for line in text.splitlines():
        if line.lstrip().startswith("```"):
            fence = not fence
        m = None if fence else _HEADING.match(line)
        if m:
            yield from flush()
            level = len(m.group(1))
            path = path[:level - 1] + [m.group(2)]
            body = []
        else:
            body.append(line)
    yield from flush()


def python_units(source: str) -> Iterator[tuple[str, str, str]]:
    """(name, docstring, code) for documented functions and classes."""
    try:
        tree = ast.parse(source)
    except SyntaxError:
        return
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            doc = ast.get_docstring(node)
            code = ast.get_source_segment(source, node)
            if doc and code:
                yield node.name, doc, code


def bash_units(source: str) -> Iterator[tuple[str, str, str]]:
    """(name, comment, code) for functions with a comment block right above them."""
    lines = source.splitlines()
    i = 0
    while i < len(lines):
        m = _BASH_FUNC.match(lines[i])
        if not m:
            i += 1
            continue
        j = i - 1
        comment: list[str] = []
        while j >= 0 and lines[j].lstrip().startswith("#") and not lines[j].startswith("#!"):
            comment.insert(0, lines[j].lstrip().lstrip("#").strip())
            j -= 1
        k = i + 1
        while k < len(lines) and lines[k] != "}":
            k += 1
        if comment and k < len(lines):
            yield m.group(1), " ".join(c for c in comment if c), "\n".join(lines[i:k + 1])
        i = k + 1


def collect(root: str | Path, project: str | None = None, min_body_chars: int = 200,
            max_chars: int = 12000) -> Iterator[dict]:
    root = Path(root)
    project = project or root.resolve().name
    for p in _files(root, (".md",)):
        rel = str(p.relative_to(root))
        for heading, body in markdown_sections(p.read_text(encoding="utf-8", errors="replace")):
            if len(body) < min_body_chars:
                continue
            rec = make_record(f"In the {project} project ({rel}), explain: {heading}", body,
                              f"docs:{project}", {"file": rel}, max_chars=max_chars)
            if rec:
                yield rec
    for p in _files(root, (".py",)):
        rel = str(p.relative_to(root))
        for name, doc, code in python_units(p.read_text(encoding="utf-8", errors="replace")):
            rec = make_record(f"Write the Python `{name}` for {project} ({rel}). It should:\n{doc}",
                              f"```python\n{code}\n```", f"code:{project}", {"file": rel},
                              max_chars=max_chars)
            if rec:
                yield rec
    for p in _files(root, (".sh",)):
        rel = str(p.relative_to(root))
        for name, comment, code in bash_units(p.read_text(encoding="utf-8", errors="replace")):
            rec = make_record(f"Write the bash function `{name}` for {project} ({rel}). It should:\n{comment}",
                              f"```bash\n{code}\n```", f"code:{project}", {"file": rel},
                              max_chars=max_chars)
            if rec:
                yield rec
