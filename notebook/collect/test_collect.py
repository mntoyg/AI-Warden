"""Tests for the collectors: python3 -m unittest discover -s notebook -p 'test_*.py'

Stdlib only, no network: the Hugging Face path is tested through
rows_to_records() and check_license() with rows built here.
"""
from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from collect import build, common, from_chats, from_files, from_git, from_hf


class Redaction(unittest.TestCase):
    def test_known_secret_shapes_are_removed(self):
        # Assembled at run time so this file itself holds no scannable secret.
        samples = {
            "openai-key": "sk-proj-" + "A1b2C3d4E5f6G7h8I9j0",
            "anthropic-key": "sk-ant-" + "api03-abcdefghijklmnop",
            "github-token": "ghp_" + "a" * 36,
            "aws-key-id": "AKIA" + "ABCDEFGHIJKLMNOP",
            "stripe-key": "sk_live_" + "0123456789abcdef",
            "email": "someone" + "@example.com",
        }
        for kind, secret in samples.items():
            out, n = common.redact(f"value: {secret} end")
            self.assertNotIn(secret, out, kind)
            self.assertIn(f"<REDACTED:{kind}>", out, kind)
            self.assertEqual(n, 1, kind)

    def test_private_key_block(self):
        block = "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\nBBBB\n-----END OPENSSH PRIVATE KEY-----"
        out, n = common.redact(f"key:\n{block}\ndone")
        self.assertNotIn("AAAA", out)
        self.assertEqual(n, 1)

    def test_literal_values_go_but_code_stays(self):
        out, _ = common.redact('password = "hunter2hunter2"')
        self.assertNotIn("hunter2hunter2", out)
        value = "abcdefgh" + "12345678"          # assembled: no scannable literal in git
        out, _ = common.redact("OPENAI_API_KEY=" + value)
        self.assertNotIn(value, out)
        code = "token = get_token(session)\nexport API_KEY=$API_KEY"
        out, n = common.redact(code)
        self.assertEqual((out, n), (code, 0))

    def test_find_leaks_ignores_markers_but_sees_raw_secrets(self):
        scrubbed, _ = common.redact('password = "hunter2hunter2" mail someone' + '@example.com')
        self.assertEqual(common.find_leaks(scrubbed), [])
        self.assertIn("github-token", common.find_leaks("ghp_" + "c" * 36))

    def test_make_record_redacts_every_message(self):
        secret = "ghp_" + "b" * 36
        rec = common.make_record(f"use {secret} please", f"done with {secret}", "t")
        self.assertNotIn(secret, json.dumps(rec))
        self.assertEqual(rec["meta"]["redactions"], 2)


class Records(unittest.TestCase):
    def test_too_short_or_empty_is_dropped(self):
        self.assertIsNone(common.make_record("hi", "", "t"))
        self.assertIsNone(common.make_record("a", "b", "t"))

    def test_long_chat_keeps_the_latest_turns(self):
        turns = [("user", "q" * 50), ("assistant", "a" * 50)] * 10
        rec = common.make_chat_record(turns, "t", max_chars=250)
        body = [m for m in rec["messages"] if m["role"] != "system"]
        self.assertEqual(body[0]["role"], "user")
        self.assertEqual(body[-1]["role"], "assistant")
        self.assertLessEqual(sum(len(m["content"]) for m in body), 250)

    def test_dedupe_ignores_system_prompt(self):
        a = common.make_record("question one?", "answer one.", "t")
        b = common.make_record("question one?", "answer one.", "t", system="other")
        self.assertEqual(len(list(common.dedupe([a, b]))), 1)


class Git(unittest.TestCase):
    def test_commits_become_change_requests_without_authors(self):
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d) / "demo"
            repo.mkdir()
            def git(*a):
                subprocess.run(["git", "-C", str(repo), *a], check=True, capture_output=True)
            git("init", "-q")
            git("config", "user.email", "author" + "@example.org")
            git("config", "user.name", "Author Name")
            (repo / "app.py").write_text("def add(a, b):\n    return a + b\n")
            git("add", "."); git("commit", "-qm", "feat: add an add function")
            (repo / "app.py").write_text("def add(a, b):\n    return a + b\n\n\ndef sub(a, b):\n    return a - b\n")
            (repo / "notes.md").write_text("just notes\n")
            git("add", "."); git("commit", "-qm", "feat: add sub", "-m", "Needed for the calculator.",
                "-m", "Co-Authored-By: Bot <bot" + "@example.org>\nSigned-off-by: Someone")
            recs = list(from_git.collect(repo))
        self.assertEqual(len(recs), 2)
        newest = recs[0]
        user = newest["messages"][1]["content"]
        self.assertIn("Make this change:\nfeat: add sub", user)
        self.assertIn("Needed for the calculator.", user)
        self.assertIn("+def sub(a, b):", newest["messages"][2]["content"])
        self.assertEqual(newest["meta"]["files"], ["app.py"])  # notes.md is not code
        blob = json.dumps(recs)
        self.assertNotIn("Author Name", blob)
        self.assertNotIn("example.org", blob)
        self.assertNotIn("Co-Authored-By", blob)
        self.assertNotIn("Signed-off-by", blob)


class Files(unittest.TestCase):
    def test_markdown_python_and_bash_units(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "proj"
            (root / "docs").mkdir(parents=True)
            (root / "docs" / "guide.md").write_text(
                "# Guide\n\n## Install\n\n" + "Run the installer and check it. " * 10 +
                "\n\n```bash\n# not a heading\n```\n\n## Tiny\n\nshort\n")
            (root / "tool.py").write_text(
                'def greet(name):\n    """Return a greeting for name."""\n    return f"hi {name}"\n\n'
                "def undocumented():\n    return 1\n")
            (root / "run.sh").write_text(
                "#!/usr/bin/env bash\n# Print the version of the tool.\nversion() {\n  echo 1.0\n}\n"
                "nocomment() {\n  :\n}\n")
            (root / "data").mkdir()
            (root / "data" / "private.md").write_text("# Secret\n\n" + "x" * 300)
            recs = list(from_files.collect(root, project="proj"))
        asks = [r["messages"][1]["content"] for r in recs]
        self.assertTrue(any("explain: Guide > Install" in a for a in asks))
        self.assertFalse(any("Tiny" in a for a in asks))            # body under the minimum
        self.assertFalse(any("not a heading" in a for a in asks))   # fenced code is not a heading
        self.assertTrue(any("`greet`" in a for a in asks))
        self.assertFalse(any("undocumented" in a for a in asks))
        self.assertTrue(any("`version`" in a and "Print the version" in a for a in asks))
        self.assertFalse(any("nocomment" in a for a in asks))
        self.assertFalse(any("Secret" in a for a in asks))          # data/ is skipped


class Chats(unittest.TestCase):
    def test_claude_and_chatgpt_exports(self):
        claude = {"uuid": "1", "name": "x", "chat_messages": [
            {"sender": "human", "text": "How do I list files in bash?"},
            {"sender": "assistant", "text": "", "content": [{"type": "text", "text": "Use ```ls -la```."}]},
        ]}
        chitchat = {"uuid": "2", "chat_messages": [
            {"sender": "human", "text": "hello there friend"},
            {"sender": "assistant", "text": "hi, how can I help today?"}]}
        chatgpt = {"title": "t", "current_node": "c", "mapping": {
            "root": {"message": None, "parent": None},
            "s": {"message": {"author": {"role": "system"}, "content": {"content_type": "text", "parts": [""]}}, "parent": "root"},
            "u": {"message": {"author": {"role": "user"}, "content": {"content_type": "text", "parts": ["write def add in python"]}}, "parent": "s"},
            "old": {"message": {"author": {"role": "assistant"}, "content": {"content_type": "text", "parts": ["abandoned branch"]}}, "parent": "u"},
            "c": {"message": {"author": {"role": "assistant"}, "content": {"content_type": "text", "parts": ["```python\ndef add(a, b): return a + b\n```"]}}, "parent": "u"},
        }}
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "conversations.json"
            p.write_text(json.dumps([claude, chitchat, chatgpt]))
            recs = list(from_chats.collect(p))
            all_recs = list(from_chats.collect(p, code_only=False))
        self.assertEqual([r["source"] for r in recs], ["chat:claude", "chat:chatgpt"])
        self.assertEqual(len(all_recs), 3)
        self.assertIn("ls -la", recs[0]["messages"][2]["content"])
        gpt = json.dumps(recs[1])
        self.assertIn("def add", gpt)
        self.assertNotIn("abandoned branch", gpt)


class HuggingFace(unittest.TestCase):
    def test_license_allow_list(self):
        self.assertEqual(from_hf.check_license("d", "mit"), "mit")
        for bad in (None, "cc-by-nc-4.0", "other"):
            with self.assertRaises(from_hf.LicenseRefused):
                from_hf.check_license("d", bad)

    def test_rows_map_and_filter_by_language(self):
        rows = [{"problem": "Write a python add function please", "solution": "def add(a,b): return a+b", "lang": "python"},
                {"problem": "Write a rust add function please", "solution": "fn add() {}", "lang": "rust"},
                {"problem": "", "solution": "orphan answer text", "lang": "python"}]
        recs = list(from_hf.rows_to_records(rows, "problem", "solution", "hf:x", "mit", "lang", {"python"}))
        self.assertEqual(len(recs), 1)
        self.assertEqual(recs[0]["meta"]["license"], "mit")


class Build(unittest.TestCase):
    def test_merge_dedupe_split_manifest(self):
        recs = [common.make_record(f"question number {i}?", f"answer number {i}.", "s") for i in range(40)]
        with tempfile.TemporaryDirectory() as d:
            m = build.build({"a": recs, "b": recs[:5]}, d, val_ratio=0.1)
            train = (Path(d) / "train.jsonl").read_text().splitlines()
            val = (Path(d) / "val.jsonl").read_text().splitlines()
        self.assertEqual(m["duplicates_dropped"], 5)
        self.assertEqual((len(train), len(val)), (36, 4))
        self.assertEqual(m["collected_per_source"], {"a": 40, "b": 5})
        self.assertEqual(json.loads(train[0])["messages"][0]["role"], "system")


if __name__ == "__main__":
    unittest.main()
