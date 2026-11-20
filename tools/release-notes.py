"""Print the release notes for a tag, from CHANGELOG.md.

Usage: release-notes.py TAG [CHANGELOG]

A release that can become the latest release, a final or a post release,
needs a section of its own, under a heading such as "## 0.4.8 - 2026-11-21".
Without one, or with an empty one, the script stops, so that the release
stops before anything is published.

A pre-release, such as v0.4.8rc1 or v0.5.0.dev1, needs no section. It gets
its own section if there is one, else the section of the version it leads
up to, else the "## Unreleased" section. Without any of them, the script
prints nothing, and the release uses the notes that GitHub generates.

This script needs the packaging module, which pyproject.toml pins. Run it
with uv run python.
"""

import sys
from pathlib import Path

from packaging.version import InvalidVersion, Version

ROOT = Path(__file__).resolve().parent.parent


def sections(text: str) -> dict[str, str]:
    """Return the text of each "## " section, by its heading up to " - "."""
    found: dict[str, list[str]] = {}
    lines = None
    for line in text.splitlines():
        if line.startswith("## "):
            lines = found.setdefault(line[3:].split(" - ", 1)[0].strip(), [])
        elif lines is not None:
            lines.append(line)
    return {name: "\n".join(lines).strip() for name, lines in found.items()}


def section_for(found: dict[str, str], version: Version) -> str:
    """Return the text of the section for version, or "" when there is none."""
    for name, text in found.items():
        try:
            if Version(name) == version:
                return text
        except InvalidVersion:
            pass
    return ""


def notes(tag: str, changelog: str) -> str:
    """Return the release notes for tag. Stop when a release needs a section."""
    try:
        version = Version(tag)
    except InvalidVersion:
        sys.exit(f"release-notes: not a PEP 440 version: {tag!r}")
    found = sections(changelog)
    own = section_for(found, version)
    if version.is_prerelease:
        return (
            own or section_for(found, Version(version.base_version)) or found.get("Unreleased", "")
        )
    if not own:
        sys.exit(
            f"release-notes: CHANGELOG.md has no section for {version}, such as '## {version} - DATE'"
        )
    return own


def main() -> None:
    """Print the release notes for the tag on the command line."""
    match sys.argv[1:]:
        case [tag]:
            path = ROOT / "CHANGELOG.md"
        case [tag, changelog]:
            path = Path(changelog)
        case _:
            sys.exit("usage: release-notes.py TAG [CHANGELOG]")
    text = notes(tag, path.read_text())
    if text:
        print(text)


if __name__ == "__main__":
    main()
