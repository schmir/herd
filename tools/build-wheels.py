"""Build one PyPI wheel for each platform that PyPI accepts.

Usage: build-wheels.py

The environment variable HERD_VERSION has the version, as a PEP 440 version.
A leading "v" is fine.

dist/ has one directory for each platform, such as linux-x86_64, with
the herd binary in it. A directory name may start with "herd-". A platform
that PyPI has no tag for (the BSDs) is skipped.

The wheels go to dist/wheels/. A wheel holds only the binary, as a script. An
installer puts a script in the bin directory of the environment, so
`uv tool install herd-cli` gives the command `herd`. The wheel is not tied to
a Python version.

This script needs the packaging module, which pyproject.toml pins. Run it
with uv run python.
"""

import base64
import hashlib
import os
import sys
import zipfile
from pathlib import Path

from packaging.version import InvalidVersion, Version

ROOT = Path(__file__).resolve().parent.parent

# The name on PyPI. The name `herd` belongs to another project.
DIST_NAME = "herd-cli"

# The Linux binaries are static, so they run on any libc.
PLATFORM_TAGS = {
    "linux-x86_64": "manylinux_2_17_x86_64.manylinux2014_x86_64.musllinux_1_1_x86_64",
    "linux-aarch64": "manylinux_2_17_aarch64.manylinux2014_aarch64.musllinux_1_1_aarch64",
    # The binaries need macOS 11 or later.
    "macos-arm64": "macosx_11_0_arm64",
    "macos-x86_64": "macosx_11_0_x86_64",
}

SUMMARY = "Manage a collection of Git repositories."

# The directory with one directory of binaries for each platform.
BINARY_DIR = ROOT / "dist"

# The directory for the wheels.
OUT_DIR = BINARY_DIR / "wheels"


def record_line(path: str, data: bytes) -> str:
    """Return the RECORD line for a file: path, SHA-256 digest and size."""
    digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest())
    return f"{path},sha256={digest.rstrip(b'=').decode()},{len(data)}"


def metadata(version: str) -> str:
    """Return the METADATA text, with the README as the description."""
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


def build_wheel(version: str, platform: str, binary: Path, out_dir: Path) -> Path:
    """Write the wheel for one platform to out_dir and return its path."""
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


def main() -> None:
    """Build the wheels for the version in HERD_VERSION."""
    raw_version = os.environ.get("HERD_VERSION")
    if not raw_version:
        sys.exit("Error: HERD_VERSION not set")
    # PyPI rejects a local part, such as +gb3ae314.dirty, so only a local
    # build has one.
    try:
        version = str(Version(raw_version))
    except InvalidVersion:
        sys.exit(f"build-wheels: not a PEP 440 version: {raw_version!r}")
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    built = 0
    for entry in sorted(BINARY_DIR.iterdir()):
        platform = entry.name.removeprefix("herd-")
        binary = entry / "herd"
        if platform not in PLATFORM_TAGS or not binary.is_file():
            continue
        print(build_wheel(version, platform, binary, OUT_DIR))
        built += 1
    if built != len(PLATFORM_TAGS):
        sys.exit(f"build-wheels: built {built} wheels, expected {len(PLATFORM_TAGS)}")


if __name__ == "__main__":
    main()
