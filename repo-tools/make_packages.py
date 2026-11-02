#!/usr/bin/env python3
"""
Builds an APT-style "Packages" file (what Sileo/Zebra read) from a folder
of .deb files, without needing `dpkg-scanpackages` (which isn't available
on the macOS GitHub Actions runner we build on — only `dpkg-deb`, via
`brew install dpkg`, is).

For each .deb:
  - reads its control fields via `dpkg-deb --field`
  - appends the extra fields a repo index needs: Filename, Size, MD5sum,
    SHA1, SHA256

Usage:
    python3 make_packages.py <debs_dir> <output_Packages_path>

`<output_Packages_path>` is written relative to the repo root that will
be served — Filename entries are written as "debs/<name>.deb", so this
script expects to be run with cwd such that <debs_dir> is "debs" (or you
pass a path and it uses the basename for the Filename field's directory).
"""
import hashlib
import subprocess
import sys
from pathlib import Path


def control_fields(deb_path: Path) -> str:
    out = subprocess.run(
        ["dpkg-deb", "--field", str(deb_path)],
        check=True, capture_output=True, text=True,
    ).stdout
    return out.rstrip("\n")


def hashes(deb_path: Path):
    md5 = hashlib.md5()
    sha1 = hashlib.sha1()
    sha256 = hashlib.sha256()
    with open(deb_path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            md5.update(chunk)
            sha1.update(chunk)
            sha256.update(chunk)
    return md5.hexdigest(), sha1.hexdigest(), sha256.hexdigest()


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)

    debs_dir = Path(sys.argv[1]).resolve()
    output_path = Path(sys.argv[2]).resolve()
    debs_dirname = debs_dir.name  # e.g. "debs" -> Filename: debs/foo.deb

    deb_files = sorted(debs_dir.glob("*.deb"))
    if not deb_files:
        print(f"error: no .deb files found in {debs_dir}", file=sys.stderr)
        sys.exit(1)

    blocks = []
    for deb in deb_files:
        fields = control_fields(deb)
        size = deb.stat().st_size
        md5, sha1, sha256 = hashes(deb)
        block = (
            f"{fields}\n"
            f"Filename: {debs_dirname}/{deb.name}\n"
            f"Size: {size}\n"
            f"MD5sum: {md5}\n"
            f"SHA1: {sha1}\n"
            f"SHA256: {sha256}\n"
        )
        blocks.append(block)
        print(f"indexed {deb.name} ({size} bytes)")

    output_path.write_text("\n".join(blocks))
    print(f"wrote {output_path} with {len(blocks)} package(s)")


if __name__ == "__main__":
    main()
