#!/usr/bin/env python3
"""Injects the shared blocks in Scripts/site-partials/ into the pages under site/.

The site is plain static HTML with no framework, so every page carried its own copy
of the footer and the top bar — and they drifted apart (four pages still claimed
version 0.1.0 long after 0.3.0 shipped).

Pages mark where a partial goes:

    <!--#partial footer-->
    ...generated, do not edit...
    <!--#endpartial-->

The generated HTML is written back into the page itself, so site/ stays a directory
of complete, self-contained files: the deploy is unchanged, the pages open straight
from disk, and nothing depends on JavaScript.

Usage:
  Scripts/site-build.py           write the partials into the pages
  Scripts/site-build.py --check   fail if any page is out of date (for CI/release)
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PARTIALS = ROOT / "Scripts" / "site-partials"
SITE = ROOT / "site"

BLOCK = re.compile(
    r"(?P<open><!--#partial (?P<name>[a-z0-9-]+)-->)"
    r".*?"
    r"(?P<close><!--#endpartial-->)",
    re.DOTALL,
)


def partial(name: str) -> str:
    path = PARTIALS / f"{name}.html"
    if not path.is_file():
        sys.exit(f"site-build: no partial named {name} ({path})")
    return path.read_text().rstrip("\n")


def render(page: Path) -> tuple[str, list[str]]:
    """Returns the page with every partial filled in, and which ones were used."""
    used: list[str] = []

    def replace(match: re.Match[str]) -> str:
        name = match.group("name")
        used.append(name)
        return f"{match.group('open')}\n{partial(name)}\n{match.group('close')}"

    return BLOCK.sub(replace, page.read_text()), used


def main() -> int:
    check = "--check" in sys.argv[1:]
    pages = sorted(SITE.rglob("*.html"))
    if not pages:
        sys.exit("site-build: no pages under site/")

    stale: list[str] = []
    written = 0
    for page in pages:
        current = page.read_text()
        rendered, used = render(page)
        if not used:
            continue
        relative = page.relative_to(ROOT)
        if rendered == current:
            print(f"  {relative} · {', '.join(used)} · up to date")
            continue
        if check:
            stale.append(str(relative))
            continue
        page.write_text(rendered)
        written += 1
        print(f"  {relative} · {', '.join(used)} · written")

    if stale:
        print("site-build: these pages do not match the partials:", file=sys.stderr)
        for name in stale:
            print(f"  {name}", file=sys.stderr)
        print("run `make site-build` and commit the result", file=sys.stderr)
        return 1
    if not check and written == 0:
        print("  everything already up to date")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
