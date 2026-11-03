#!/usr/bin/env bash
# Fail when Chrome/Firefox zip inputs change without increasing package.json version.
set -euo pipefail
base=${1:?usage: check-extension-version.sh <base-sha>}
pkg=BrowserExtension/WebExtension/package.json
[[ -f $pkg ]] || { echo "missing $pkg" >&2; exit 1; }
git cat-file -e "$base:$pkg" 2>/dev/null || {
  echo "Base commit has no $pkg; treating as first introduction (ok)."
  exit 0
}
base_ver=$(git show "$base:$pkg" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')
head_ver=$(python3 -c 'import json; print(json.load(open("'"$pkg"'"))["version"])')
python3 - "$base_ver" "$head_ver" <<'PY'
import sys

def parts(v: str) -> tuple[int, ...]:
    try:
        return tuple(int(p) for p in v.split("."))
    except ValueError as e:
        raise SystemExit(f"invalid semver {v!r}: {e}") from e

base, head = sys.argv[1], sys.argv[2]
if parts(head) <= parts(base):
    print(
        f"BrowserExtension/WebExtension zip inputs changed, but {base} was not increased (still {head}).",
        file=sys.stderr,
    )
    print(
        "Bump BrowserExtension/WebExtension/package.json in this PR "
        "(or wait for the extension release-please PR after merge).",
        file=sys.stderr,
    )
    raise SystemExit(1)
print(f"Extension version {base} → {head}")
PY
