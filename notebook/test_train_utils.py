"""Tests for train_utils: python3 -m unittest discover -s notebook -p 'test_*.py'

The manifest test runs the two sed lines that scripts/warden-cli.sh itself
uses to read a model manifest, taken from that file at test time, so a
change on either side breaks this test instead of the user's first run.
"""
from __future__ import annotations

import json
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

import train_utils
from collect import build, common

CLI = Path(__file__).resolve().parent.parent / "scripts" / "warden-cli.sh"


def cli_reads(manifest: Path) -> tuple[str, str]:
    """(gguf_file, gguf_sha256) as warden-cli.sh's verify_model_manifest parses them."""
    lines = [l.strip() for l in CLI.read_text().splitlines()
             if re.match(r'\s*(file|sha)="\$\(sed -n .*gguf_(file|sha256)', l)]
    assert len(lines) == 2, f"the CLI's manifest parsing changed: {lines}"
    script = f'manifest="$1"\n' + "\n".join(lines) + '\nprintf "%s\\n%s\\n" "$file" "$sha"\n'
    out = subprocess.run(["bash", "-c", script, "_", str(manifest)], check=True,
                         capture_output=True, text=True).stdout.splitlines()
    return out[0], out[1]


class ModelManifest(unittest.TestCase):
    def test_the_cli_reads_what_we_write(self):
        with tempfile.TemporaryDirectory() as d:
            gguf = Path(d) / "warden-coder-1.5b-q8_0.gguf"
            gguf.write_bytes(b"GGUF fake model bytes")
            m = train_utils.write_model_manifest(gguf, "warden-coder", "Qwen/Qwen2.5-Coder-1.5B-Instruct",
                                                 extra={"quantization": "q8_0"})
            file, sha = cli_reads(m)
            data = json.loads(m.read_text())
        self.assertEqual(file, "warden-coder-1.5b-q8_0.gguf")
        self.assertRegex(sha, r"^[0-9a-f]{64}$")
        self.assertEqual(sha, data["gguf_sha256"])
        self.assertEqual(data["schema"], "warden-model-lab/manifest/1")
        self.assertEqual(data["quantization"], "q8_0")

    def test_refuses_names_the_cli_would_refuse(self):
        with tempfile.TemporaryDirectory() as d:
            for name in ("model.bin", "my model.gguf"):
                p = Path(d) / name
                p.write_bytes(b"x")
                with self.assertRaises(ValueError):
                    train_utils.write_model_manifest(p, "m", "b")


class Dataset(unittest.TestCase):
    def test_verify_passes_then_catches_an_edit(self):
        recs = [common.make_record(f"question number {i}?", f"answer number {i}.", "s") for i in range(30)]
        with tempfile.TemporaryDirectory() as d:
            build.build({"a": recs}, d)
            m = train_utils.verify_dataset(d)
            self.assertEqual(m["train"]["records"] + m["val"]["records"], 30)
            with open(Path(d) / "train.jsonl", "a") as f:
                f.write('{"messages": []}\n')
            with self.assertRaisesRegex(ValueError, "changed since it was collected"):
                train_utils.verify_dataset(d)


class Kwargs(unittest.TestCase):
    def test_aliases_follow_the_installed_signature(self):
        class OldConfig:
            def __init__(self, output_dir, max_seq_length=1024, evaluation_strategy="no", fp16=False): ...
        class NewConfig:
            def __init__(self, output_dir, max_length=1024, eval_strategy="no", fp16=False): ...
        want = {"output_dir": "o", "max_seq_length": 2048, "eval_strategy": "no", "fp16": True,
                "not_a_param": 1}
        self.assertEqual(train_utils.accepted_kwargs(OldConfig, want),
                         {"output_dir": "o", "max_seq_length": 2048, "evaluation_strategy": "no", "fp16": True})
        self.assertEqual(train_utils.accepted_kwargs(NewConfig, want),
                         {"output_dir": "o", "max_length": 2048, "eval_strategy": "no", "fp16": True})


if __name__ == "__main__":
    unittest.main()
