#!/usr/bin/env python3
"""Ensure failed tools cannot be hidden by log filters or a stale application binary."""
from pathlib import Path
import os
import subprocess
import tempfile

makefile = Path(__file__).resolve().parents[1] / "Makefile"
with tempfile.TemporaryDirectory(prefix="triwarden-make-test-") as directory:
    root = Path(directory)
    (root / "Packages/VaultCore").mkdir(parents=True)
    tools = root / "tools"
    tools.mkdir()
    for name in ("swift", "xcodebuild", "failed-app"):
        script = tools / name
        script.write_text('#!/bin/sh\necho "Test run passed; PASS; BUILD SUCCEEDED"\nexit 23\n')
        script.chmod(0o755)
    stale = root / "stale-app"
    stale.write_text("#!/bin/sh\nexit 0\n")
    stale.chmod(0o755)
    env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}")
    for target in ("test", "test-dev", "build", "uitest", "selftest", "selftest-security", "snapshots"):
        args = ["make", "-f", str(makefile), "-o", "project", target]
        if target.startswith("selftest") or target == "snapshots":
            args += ["-o", "build", f"BIN={tools / 'failed-app'}"]
        elif target == "build":
            args += ["XCB=xcodebuild", f"BIN={stale}"]
        result = subprocess.run(args, cwd=root, env=env, capture_output=True, text=True)
        assert result.returncode != 0, f"{target} hid the failure:\n{result.stdout}\n{result.stderr}"
        print(f"PASS: {target} preserves failure")
