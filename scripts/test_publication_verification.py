"""Exercise the actual publication-verification shell with registry fixtures."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RegistryFixture(unittest.TestCase):
    def verify(self, metadata, status=200, changed_download=False, empty=False, sidecars=False):
        text = (ROOT / WORKFLOW).read_text()
        block = text.split("      - name: " + STEP + "\n", 1)[1]
        block = block.split("        run: |\n", 1)[1].split("\n      - name:", 1)[0].split("\n  github-release:", 1)[0]
        script = textwrap.dedent(block)
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            binary = root / "bin"
            binary.mkdir()
            (root / "pkg").mkdir()
            (root / "dist").mkdir()
            if not empty:
                for name, body in ARTIFACTS.items():
                    (root / name).write_bytes(body)
            if sidecars:
                (root / "dist/package.whl.publish.attestation").write_text("signed attestation")
            fixture = {"metadata": metadata, "status": status, "payload": "different" if changed_download else "tested gem"}
            (root / "fixture.json").write_text(json.dumps(fixture))
            curl = binary / "curl"
            curl.write_text("#!/usr/bin/env python3\n" + textwrap.dedent('''
                import json, os, sys
                from pathlib import Path
                args = sys.argv[1:]
                fixture = json.loads(Path(os.environ["REGISTRY_FIXTURE"]).read_text())
                url = next(a for a in args if a.startswith("https://"))
                is_metadata = url.endswith("json")
                status = fixture["status"] if is_metadata else 200
                if status >= 400 and "--fail" in args:
                    sys.exit(22)
                body = json.dumps(fixture["metadata"]) if is_metadata else fixture["payload"]
                if "--output" in args:
                    Path(args[args.index("--output") + 1]).write_text(body)
                else:
                    print(body)
                if "--write-out" in args:
                    print(status, end="")
            '''))
            curl.chmod(0o755)
            sleeper = binary / "sleep"
            sleeper.write_text("#!/bin/sh\nexit 0\n")
            sleeper.chmod(0o755)
            env = {**os.environ, "PATH": str(binary) + os.pathsep + os.environ["PATH"],
                   "REGISTRY_FIXTURE": str(root / "fixture.json"), "RELEASE_TAG": TAG, "TAG_NAME": TAG}
            return subprocess.run(["bash", "-c", script], cwd=root, env=env,
                                  capture_output=True, text=True, timeout=15)

WORKFLOW = ".github/workflows/release.yml"
STEP = "Verify RubyGems publication"
TAG = "v0.4.1"
ARTIFACTS = {"pkg/logister-ruby-0.4.1.gem": b"tested gem"}


def metadata():
    return {"name": "logister-ruby", "number": "0.4.1", "sha": hashlib.sha256(b"tested gem").hexdigest()}


class PublicationVerificationTest(RegistryFixture):
    def test_exact_built_bytes(self):
        result = self.verify(metadata())
        self.assertEqual(result.returncode, 0, result.stderr)
    def test_wrong_identity_or_hash(self):
        for key, value in [("name", "other"), ("number", "0.4.0"), ("sha", "0" * 64)]:
            with self.subTest(key=key):
                self.assertNotEqual(self.verify({**metadata(), key: value}).returncode, 0)
    def test_wrong_download(self):
        self.assertNotEqual(self.verify(metadata(), changed_download=True).returncode, 0)
    def test_provider_failure(self):
        for status in [401, 404, 503]:
            with self.subTest(status=status):
                self.assertNotEqual(self.verify(metadata(), status=status).returncode, 0)


if __name__ == "__main__":
    unittest.main()
