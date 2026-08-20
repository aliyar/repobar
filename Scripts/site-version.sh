#!/bin/bash
# Point the landing page at a release: version, download links, size, checksum, sitemap date.
# Every fact the page states about the download lives here, so a release cannot leave the
# site claiming an older build.
#
# Usage: Scripts/site-version.sh <version> <zip-path> [repo-slug]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"; ZIP="${2:-}"; REPO="${3:-aliyar/repobar}"
PAGE="site/index.html"
MAP="site/sitemap.xml"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 <x.y.z> <zip> [repo]" >&2; exit 1; }
[[ -f "$ZIP" ]] || { echo "no such zip: $ZIP" >&2; exit 1; }
[[ -f "$PAGE" ]] || { echo "no such page: $PAGE" >&2; exit 1; }

BYTES=$(stat -f%z "$ZIP")
SIZE=$(python3 -c "print(f'{$BYTES/1024/1024:.1f} MB')")
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
TODAY=$(date +%Y-%m-%d)
URL="https://github.com/$REPO/releases/download/v$VERSION/RepoBar-$VERSION.zip"

# Each edit is matched on shape, not on the outgoing value, and verified after it runs,
# so a markup change here fails the release instead of silently skipping a fact.
edit() { # <sed-expression> <expected-substring> <what>
  sed -i '' "$1" "$PAGE"
  grep -qF "$2" "$PAGE" || { echo "site-version: could not set $3 in $PAGE" >&2; exit 1; }
}

edit "s|\"softwareVersion\": \"[^\"]*\"|\"softwareVersion\": \"$VERSION\"|" \
     "\"softwareVersion\": \"$VERSION\"" "JSON-LD version"
edit "s|\"fileSize\": \"[^\"]*\"|\"fileSize\": \"$SIZE\"|" \
     "\"fileSize\": \"$SIZE\"" "JSON-LD file size"
edit "s|releases/download/v[0-9][0-9.]*/RepoBar-[0-9][0-9.]*\.zip|releases/download/v$VERSION/RepoBar-$VERSION.zip|g" \
     "$URL" "download links"
edit "s|Download RepoBar [0-9][0-9.]*<|Download RepoBar $VERSION<|" \
     "Download RepoBar $VERSION<" "download button label"
edit "s|<li>[0-9][0-9.]*</li><li>[0-9][0-9.]* MB</li>|<li>$VERSION</li><li>$SIZE</li>|" \
     "<li>$VERSION</li><li>$SIZE</li>" "requirements line"
edit "s|<p class=\"dl-meta\">[0-9][0-9.]* MB |<p class=\"dl-meta\">$SIZE |" \
     "<p class=\"dl-meta\">$SIZE " "download meta"
edit "s|<span class=\"mono\">[0-9a-f]\{64\}</span>|<span class=\"mono\">$SHA</span>|" \
     "$SHA" "SHA-256"
edit "s|RepoBar <span class=\"mono\">[0-9][0-9.]*</span>|RepoBar <span class=\"mono\">$VERSION</span>|" \
     "RepoBar <span class=\"mono\">$VERSION</span>" "footer version"

if [[ -f "$MAP" ]]; then
  sed -i '' "s|<lastmod>[0-9-]*</lastmod>|<lastmod>$TODAY</lastmod>|g" "$MAP"
fi

# Nothing may still point at an older release.
STALE=$(grep -oE 'RepoBar-[0-9]+\.[0-9]+\.[0-9]+\.zip' "$PAGE" | grep -v "RepoBar-$VERSION.zip" || true)
[[ -z "$STALE" ]] || { echo "site-version: stale download links left: $STALE" >&2; exit 1; }

echo "  site: $VERSION · $SIZE · ${SHA:0:12}… · sitemap $TODAY"
