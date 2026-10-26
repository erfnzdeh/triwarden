#!/usr/bin/env python3
"""`tw install-chrome` must name the real binary, however tw was started.

Run through PATH (the Homebrew symlink), argv[0] is just "tw"; resolving that against the
working directory wrote a manifest pointing at a file that does not exist, so Chrome could
not start the host. These cases run the built binary with a throwaway home directory, so the
developer's own browser configuration is never touched.
"""
from pathlib import Path
import json
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
binary = Path(os.environ.get("TW_BINARY") or root / "build/Build/Products/Debug/tw")
if not binary.exists():
    raise SystemExit(f"{binary} is missing; build it first with `make build` (or `xcodebuild -scheme tw build`)")
real = binary.resolve()
host = "io.github.sinhong2011.triwarden"
extension_id = "a" * 32


def manifest_in(home):
    return home / "Library/Application Support/Google/Chrome/NativeMessagingHosts" / f"{host}.json"


def run(args, cwd, home):
    """Run tw with a throwaway home, so manifests land there instead of the real one."""
    env = dict(os.environ, CFFIXED_USER_HOME=str(home), PATH=f"{home / 'bin'}:{os.environ['PATH']}")
    return subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True)


def check(label, args, cwd):
    with tempfile.TemporaryDirectory(prefix="triwarden-install-chrome-") as directory:
        home = Path(directory)
        (home / "bin").mkdir()
        (home / "Library/Application Support/Google/Chrome").mkdir(parents=True)
        (home / "elsewhere").mkdir()
        (home / "bin/tw").symlink_to(binary)

        result = run(args, cwd(home), home)
        assert result.returncode == 0, f"{label}: tw failed:\n{result.stdout}\n{result.stderr}"

        path = manifest_in(home)
        assert path.exists(), f"{label}: no manifest written:\n{result.stdout}"
        manifest = json.loads(path.read_text())
        written = Path(manifest["path"])

        # The regression: a relative argv[0] resolved against the working directory.
        assert written.is_absolute(), f"{label}: manifest path is not absolute: {written}"
        assert written == real, f"{label}: manifest names {written}, expected {real}"
        assert written.exists(), f"{label}: manifest names a file that does not exist: {written}"
        assert manifest["name"] == host and manifest["type"] == "stdio", f"{label}: bad manifest: {manifest}"
        assert manifest["allowed_origins"] == [f"chrome-extension://{extension_id}/"], f"{label}: bad origins: {manifest}"
        print(f"PASS: {label}")


check("via PATH symlink", ["tw", "install-chrome", extension_id], lambda home: home / "elsewhere")
check("via absolute path", [str(real), "install-chrome", extension_id], lambda home: home / "elsewhere")
check("via relative path", ["./tw", "install-chrome", extension_id], lambda home: home / "bin")

# A rejected id must not leave a manifest behind, so a bad invocation cannot break a good install.
with tempfile.TemporaryDirectory(prefix="triwarden-install-chrome-bad-") as directory:
    home = Path(directory)
    (home / "bin").mkdir()
    (home / "Library/Application Support/Google/Chrome").mkdir(parents=True)
    (home / "bin/tw").symlink_to(binary)
    result = run(["tw", "install-chrome", "not-an-id"], home, home)
    assert result.returncode == 64, f"bad extension id: expected exit 64, got {result.returncode}"
    assert not manifest_in(home).exists(), "bad extension id: a manifest was written anyway"
    print("PASS: rejects a bad extension id")
