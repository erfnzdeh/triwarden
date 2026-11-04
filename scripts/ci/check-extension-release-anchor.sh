#!/usr/bin/env bash
# Fail when .release-please-manifest.json lists an extension version with no
# matching extension-v* tag. Without that tag, release-please rescans old
# history and opens a bogus chore: release 0.1.0 PR.
set -euo pipefail

manifest=.release-please-manifest.json
key=BrowserExtension/WebExtension
[[ -f $manifest ]] || { echo "missing $manifest" >&2; exit 1; }

version=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$manifest" "$key")
[[ -n $version ]] || { echo "manifest missing $key version" >&2; exit 1; }

tag="extension-v${version}"

has_tag() {
  git rev-parse -q --verify "refs/tags/${tag}" >/dev/null 2>&1 && return 0
  # Annotated tags resolve via ^{}; also accept any remote tip.
  git ls-remote --tags origin "refs/tags/${tag}" "refs/tags/${tag}^{}" 2>/dev/null \
    | awk 'NF { found=1 } END { exit !found }'
}

if has_tag; then
  echo "OK: ${tag} anchors manifest ${key}=${version}"
  exit 0
fi

# release-please bumps the manifest on merge, then creates the tag in the same
# push's release workflow. Allow that transient window.
subject=$(git log -1 --format=%s)
if [[ $subject == 'chore: release '* ]]; then
  echo "WARN: ${tag} missing, but HEAD is a release-please release commit; tag expected shortly."
  exit 0
fi

cat >&2 <<MSG
Missing git tag ${tag} for ${key} version ${version} in ${manifest}.

release-please needs refs/tags/${tag} (or package bootstrap-sha) or it will
rescan extension history and open a bogus "chore: release 0.1.0" PR.

Create an annotated tag on the commit that shipped ${version}, e.g.:
  git tag -a ${tag} <sha> -m "Browser extension ${version} (anchor for release-please)"
  git push origin refs/tags/${tag}
MSG
exit 1
