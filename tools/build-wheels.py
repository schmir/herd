"""Build one PyPI wheel for each platform that PyPI accepts.

Usage: build-wheels.py VERSION BINARY_DIR OUTPUT_DIR

BINARY_DIR has one directory for each platform, such as linux-x86_64, with
the herd binary in it. A directory name may start with "herd-". A platform
that PyPI has no tag for (the BSDs) is skipped.

A wheel holds only the binary, as a script. An installer puts a script in
the bin directory of the environment, so `uv tool install herd-cli` gives
the command `herd`. The wheel is not tied to a Python version.

This script uses only the standard library, so it runs without an
environment.
"""

import base64
import hashlib
import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# The name on PyPI. The name `herd` belongs to another project.
DIST_NAME = "herd-cli"

# The Linux binaries are static, so they run on any libc.
PLATFORM_TAGS = {
    "linux-x86_64": ("manylinux_2_17_x86_64.manylinux2014_x86_64.musllinux_1_1_x86_64"),
    "linux-aarch64": (
        "manylinux_2_17_aarch64.manylinux2014_aarch64.musllinux_1_1_aarch64"
    ),
    # The binaries need macOS 11 or later.
    "macos-arm64": "macosx_11_0_arm64",
    "macos-x86_64": "macosx_11_0_x86_64",
}

SUMMARY = "Manage a collection of Git repositories."


def record_line(path, data):
    digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest())
    return f"{path},sha256={digest.rstrip(b'=').decode()},{len(data)}"


def metadata(version):
    readme = (ROOT / "README.md").read_text()
    return (
        "Metadata-Version: 2.4\n"
        f"Name: {DIST_NAME}\n"
        f"Version: {version}\n"
        f"Summary: {SUMMARY}\n"
        "Description-Content-Type: text/markdown\n"
        "License-Expression: GPL-3.0-only\n"
        "License-File: LICENSE\n"
        "Project-URL: Homepage, https://github.com/schmir/herd\n"
        "Project-URL: Changelog, "
        "https://github.com/schmir/herd/blob/main/CHANGELOG.md\n"
        "\n"
        f"{readme}"
    )


def build_wheel(version, platform, binary, out_dir):
    tag = PLATFORM_TAGS[platform]
    stem = f"{DIST_NAME.replace('-', '_')}-{version}"
    dist_info = f"{stem}.dist-info"
    wheel_meta = (
        "Wheel-Version: 1.0\n"
        "Generator: herd tools/build-wheels.py\n"
        "Root-Is-Purelib: false\n"
        f"Tag: py3-none-{tag}\n"
    )
    files = [
        (f"{stem}.data/scripts/herd", binary.read_bytes(), 0o755),
        (f"{dist_info}/METADATA", metadata(version).encode(), 0o644),
        (f"{dist_info}/WHEEL", wheel_meta.encode(), 0o644),
        (f"{dist_info}/licenses/LICENSE", (ROOT / "LICENSE").read_bytes(), 0o644),
    ]
    record = [record_line(name, data) for name, data, _ in files]
    record.append(f"{dist_info}/RECORD,,")
    files.append((f"{dist_info}/RECORD", ("\n".join(record) + "\n").encode(), 0o644))

    wheel = out_dir / f"{stem}-py3-none-{tag}.whl"
    with zipfile.ZipFile(wheel, "w", zipfile.ZIP_DEFLATED) as zf:
        for name, data, mode in files:
            # A fixed time keeps the wheel the same for the same input.
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.external_attr = (0o100000 | mode) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            zf.writestr(info, data)
    return wheel


def main(argv):
    if len(argv) != 4:
        sys.exit(__doc__)
    version = argv[1].removeprefix("v")
    # A release, or a pre-release in the form PEP 440 uses, such as 0.4.6rc1.
    if not re.fullmatch(r"\d+(\.\d+)*((a|b|rc)\d+)?", version):
        sys.exit(f"build-wheels: not a release version: {argv[1]!r}")
    binary_dir, out_dir = Path(argv[2]), Path(argv[3])
    out_dir.mkdir(parents=True, exist_ok=True)

    built = 0
    for entry in sorted(binary_dir.iterdir()):
        platform = entry.name.removeprefix("herd-")
        binary = entry / "herd"
        if platform not in PLATFORM_TAGS or not binary.is_file():
            continue
        print(build_wheel(version, platform, binary, out_dir))
        built += 1
    if built != len(PLATFORM_TAGS):
        sys.exit(f"build-wheels: built {built} wheels, expected {len(PLATFORM_TAGS)}")


if __name__ == "__main__":
    main(sys.argv)
