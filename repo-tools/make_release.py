#!/usr/bin/env python3
"""
Generates a Debian-style "Release" file for a flat APT repo (the kind
Sileo/Zebra read), matching the format real working Sileo repos use
(Origin/Label/Suite/.../ + MD5Sum/SHA256 blocks for Packages/Packages.gz).

Sileo's source-add flow 404s without this file -- a flat repo with only
Packages (no Release) is valid per plain APT, but Sileo appears to require
Release to accept a source.

Usage:
    python3 make_release.py <site_dir> <output_Release_path>

<site_dir> must contain "Packages" and, if present, "Packages.gz"/
"Packages.bz2" -- whichever of those exist get a checksum entry.
"""
import hashlib
import sys
from datetime import datetime, timezone
from pathlib import Path

ORIGIN = "anhtran3199's CarPlay tweaks"
LABEL = "CarPlay tweaks"
SUITE = "stable"
VERSION = "1.0"
CODENAME = "ios"
# The .deb packages themselves declare "Architecture: iphoneos-arm" (the
# standard Theos catch-all), which dpkg-on-iOS treats as compatible with
# any arm64 variant. But Sileo's source-add check compares this Release
# field against the device's *actual* reported architecture (what
# DPKGArchitecture() returns -- "iphoneos-arm64" on rootful/arm64 devices,
# "iphoneos-arm64e" on rootless/arm64e ones), not the package's field, and
# 404s the add if it isn't an exact match. List every real device
# architecture explicitly (this is what working repos like
# sideplay.pages.dev do) rather than just the generic package-level name.
ARCHITECTURES = "iphoneos-arm iphoneos-arm64 iphoneos-arm64e"
COMPONENTS = "main"
DESCRIPTION = "Personal CarPlay tweaks (SplitCarPlay, VietmapLiveExport)"


def file_hashes(path: Path):
    md5 = hashlib.md5()
    sha256 = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            md5.update(chunk)
            sha256.update(chunk)
    return md5.hexdigest(), sha256.hexdigest(), path.stat().st_size


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)

    site_dir = Path(sys.argv[1]).resolve()
    output_path = Path(sys.argv[2]).resolve()

    candidates = ["Packages", "Packages.gz", "Packages.bz2"]
    present = [name for name in candidates if (site_dir / name).is_file()]
    if "Packages" not in present:
        print(f"error: {site_dir}/Packages not found", file=sys.stderr)
        sys.exit(1)

    md5_lines = []
    sha256_lines = []
    for name in present:
        md5, sha256, size = file_hashes(site_dir / name)
        md5_lines.append(f" {md5} {size} {name}")
        sha256_lines.append(f" {sha256} {size} {name}")

    date_str = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S UTC")

    release = "\n".join([
        f"Origin: {ORIGIN}",
        f"Label: {LABEL}",
        f"Suite: {SUITE}",
        f"Version: {VERSION}",
        f"Codename: {CODENAME}",
        f"Date: {date_str}",
        f"Architectures: {ARCHITECTURES}",
        f"Components: {COMPONENTS}",
        f"Description: {DESCRIPTION}",
        "MD5Sum:",
        *md5_lines,
        "SHA256:",
        *sha256_lines,
        "",
    ])

    output_path.write_text(release)
    print(f"wrote {output_path} covering: {', '.join(present)}")


if __name__ == "__main__":
    main()
