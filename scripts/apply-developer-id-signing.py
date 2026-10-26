#!/usr/bin/env python3
"""Patch the generated Xcode project for CI Developer ID archive.

Reads bundle-id<TAB>profile-name lines (from developer-id-profiles.py) on stdin or
from a file argument. Sets project Release to Manual + Developer ID Application,
and each matching target's Release PROVISIONING_PROFILE_SPECIFIER.

Used only by scripts/release.sh when ASC_KEY_PATH is set, so CI archive never asks
Apple to mint Mac/Apple Development certificates (project.yml stays Automatic for
local Debug). *.xcodeproj is gitignored; this only affects the in-tree generate.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

RELEASE_BLOCK = re.compile(
    r"/\* Release \*/ = \{\n"
    r"\t\t\tisa = XCBuildConfiguration;\n"
    r"\t\t\tbuildSettings = \{.*?\n"
    r"\t\t\t\};\n"
    r"\t\t\tname = Release;",
    re.S,
)


def main() -> None:
    if len(sys.argv) > 1:
        lines = Path(sys.argv[1]).read_text().splitlines()
    else:
        lines = sys.stdin.read().splitlines()

    profiles: dict[str, str] = {}
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        bundle, name = line.split("\t", 1)
        profiles[bundle.strip()] = name.strip()
    if not profiles:
        sys.exit("no bundle/profile lines")

    project = Path("Triwarden.xcodeproj/project.pbxproj")
    text = project.read_text()
    seen: set[str] = set()

    def patch_release(match: re.Match[str]) -> str:
        block = match.group(0)

        # Project-level Release: has CODE_SIGN_STYLE, no PRODUCT_BUNDLE_IDENTIFIER.
        if "CODE_SIGN_STYLE" in block and "PRODUCT_BUNDLE_IDENTIFIER" not in block:
            block = re.sub(
                r'CODE_SIGN_IDENTITY = "[^"]*";',
                'CODE_SIGN_IDENTITY = "Developer ID Application";',
                block,
                count=1,
            )
            block = re.sub(
                r"CODE_SIGN_STYLE = [^;]+;",
                "CODE_SIGN_STYLE = Manual;",
                block,
                count=1,
            )
            return block

        for bundle, profile in profiles.items():
            needle = f"PRODUCT_BUNDLE_IDENTIFIER = {bundle};"
            if needle not in block:
                continue
            if "PROVISIONING_PROFILE_SPECIFIER" in block:
                block = re.sub(
                    r'PROVISIONING_PROFILE_SPECIFIER = "[^"]*";',
                    f'PROVISIONING_PROFILE_SPECIFIER = "{profile}";',
                    block,
                    count=1,
                )
            else:
                block = block.replace(
                    needle,
                    f'PROVISIONING_PROFILE_SPECIFIER = "{profile}";\n\t\t\t\t{needle}',
                    1,
                )
            seen.add(bundle)
            break
        return block

    text = RELEASE_BLOCK.sub(patch_release, text)
    missing = sorted(set(profiles) - seen)
    if missing:
        sys.exit(f"could not set profile for: {', '.join(missing)}")
    if "CODE_SIGN_STYLE = Manual;" not in text:
        sys.exit("project Release was not switched to Manual")

    project.write_text(text)
    print(
        f"patched Developer ID Manual signing for {len(seen)} target(s)",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
