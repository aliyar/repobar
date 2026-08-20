#!/bin/bash
# RepoBar release: version bump → Release build → sign → zip (+ install.txt) → Sparkle appcast
#                  → git commit/tag/push → GitHub release with assets.
#
# Usage:
#   Scripts/release.sh <version> [--notes FILE] [--dry-run] [--no-git] [--draft] [--prerelease] [--adhoc]
#
#   --notes FILE   Markdown release notes (used for the GitHub release and the Sparkle appcast).
#                  Without it, GitHub generates notes from commits and they are reused for the appcast.
#   --dry-run      Build everything into dist/ but do not touch git or GitHub.
#   --no-git       Skip the version commit, tag and push (still creates the GitHub release).
#   --adhoc        Force ad-hoc signing even if a Developer ID certificate is installed.
#
# Environment:
#   REPO            GitHub slug (default: aliyar/repobar)
#   NOTARY_PROFILE  notarytool keychain profile; notarization runs only with Developer ID signing.
#
# Prerequisites: xcodegen, gh (logged in), Xcode, the Sparkle EdDSA key in the keychain
# (generated once with generate_keys; back it up with `generate_keys -x sparkle_private_key`).
set -euo pipefail
cd "$(dirname "$0")/.."

# ---------- arguments ----------
VERSION="${1:-}"
shift || true
NOTES_FILE=""; DRY_RUN=0; NO_GIT=0; DRAFT=0; PRERELEASE=0; FORCE_ADHOC=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes) NOTES_FILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-git) NO_GIT=1; shift ;;
    --draft) DRAFT=1; shift ;;
    --prerelease) PRERELEASE=1; shift ;;
    --adhoc) FORCE_ADHOC=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 <major.minor.patch> [--notes FILE] [--dry-run] [--no-git] [--draft] [--prerelease] [--adhoc]" >&2
  exit 2
fi
REPO="${REPO:-aliyar/repobar}"
TAG="v$VERSION"
APP_NAME="RepoBar"
DIST="dist"
STAGE="$DIST/$APP_NAME-$VERSION"
ZIP="$DIST/$APP_NAME-$VERSION.zip"
DERIVED="build/Release"
SPARKLE_BIN="build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
DOWNLOAD_PREFIX="https://github.com/$REPO/releases/download/$TAG/"

step() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ---------- preconditions ----------
step "Checking prerequisites"
for tool in xcodegen gh xcodebuild ditto plutil codesign python3; do
  command -v "$tool" >/dev/null || die "$tool is required"
done
if [[ $DRY_RUN -eq 0 ]]; then
  gh auth status >/dev/null 2>&1 || die "gh is not logged in (run: gh auth login)"
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists"
  if [[ $NO_GIT -eq 0 ]]; then
    [[ -z "$(git status --porcelain)" ]] || die "working tree is not clean — commit or stash first"
    git remote get-url origin >/dev/null 2>&1 || die "git remote 'origin' is missing"
  fi
fi
if [[ ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
  step "Resolving Swift packages (Sparkle tools)"
  xcodegen generate --quiet
  xcodebuild -project $APP_NAME.xcodeproj -scheme $APP_NAME -destination 'platform=macOS' \
    -derivedDataPath build/DerivedData -resolvePackageDependencies -quiet
  [[ -x "$SPARKLE_BIN/generate_appcast" ]] || die "Sparkle tools not found under $SPARKLE_BIN"
fi
[[ -z "$NOTES_FILE" || -f "$NOTES_FILE" ]] || die "notes file not found: $NOTES_FILE"

# ---------- version bump ----------
step "Setting version $VERSION"
mkdir -p build && cp project.yml build/project.yml.before-release
PREV_BUILD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' project.yml | head -1)
BUILD=$(( ${PREV_BUILD:-0} + 1 ))
sed -i '' "s/^\( *MARKETING_VERSION: \)\"[^\"]*\"/\1\"$VERSION\"/" project.yml
sed -i '' "s/^\( *CURRENT_PROJECT_VERSION: \)\"[^\"]*\"/\1\"$BUILD\"/" project.yml
grep -q "MARKETING_VERSION: \"$VERSION\"" project.yml || die "could not set MARKETING_VERSION in project.yml"
echo "  marketing version $VERSION, build $BUILD"
xcodegen generate --quiet

# ---------- signing ----------
SIGN_ARGS=()
SIGN_MODE="ad-hoc"
DEVELOPER_ID=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
if [[ $FORCE_ADHOC -eq 0 && -n "$DEVELOPER_ID" ]]; then
  SIGN_MODE="Developer ID"
  SIGN_ARGS=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$DEVELOPER_ID" OTHER_CODE_SIGN_FLAGS=--timestamp)
else
  # Ad-hoc signatures carry no Team ID, so the hardened runtime's library validation would reject the
  # embedded Sparkle.framework. Hardened runtime is only required for notarization (Developer ID path).
  SIGN_ARGS=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= ENABLE_HARDENED_RUNTIME=NO)
fi

# ---------- build ----------
step "Building Release ($SIGN_MODE signing)"
rm -rf "$DERIVED/Build/Products/Release/$APP_NAME.app"
xcodebuild -project $APP_NAME.xcodeproj -scheme $APP_NAME -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED" "${SIGN_ARGS[@]}" build -quiet
APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
[[ -d "$APP" ]] || die "build product not found at $APP"

step "Verifying build"
codesign --verify --deep --strict "$APP" || die "code signature is invalid"
PLIST="$APP/Contents/Info.plist"
BUILT_VERSION=$(plutil -extract CFBundleShortVersionString raw "$PLIST")
[[ "$BUILT_VERSION" == "$VERSION" ]] || die "built version $BUILT_VERSION != $VERSION"
[[ -n "$(plutil -extract SUPublicEDKey raw "$PLIST")" ]] || die "SUPublicEDKey missing from Info.plist"
[[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]] || die "Sparkle.framework is not embedded"
AUTHORITY=$(codesign -dv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)
echo "  $APP_NAME $BUILT_VERSION ($(plutil -extract CFBundleVersion raw "$PLIST")), signed by ${AUTHORITY:-ad-hoc identity}"

# ---------- package ----------
step "Packaging"
# The app must sit at the archive root (generate_appcast requirement); install.txt rides along.
# Archive Utility unpacks multi-item archives into a folder named after the zip.
rm -rf "$DIST"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
sed "s/{{VERSION}}/$VERSION/g" Scripts/install.template.txt > "$STAGE/install.txt"
cp "$STAGE/install.txt" "$DIST/install.txt"
ditto -c -k --norsrc "$STAGE" "$ZIP"
rm -rf "$STAGE"

if [[ "$SIGN_MODE" == "Developer ID" && -n "${NOTARY_PROFILE:-}" ]]; then
  step "Notarizing"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  mkdir -p "$STAGE"; ditto -x -k "$ZIP" "$STAGE"
  xcrun stapler staple "$STAGE/$APP_NAME.app"
  rm "$ZIP"; ditto -c -k --norsrc "$STAGE" "$ZIP"; rm -rf "$STAGE"
fi
echo "  $(du -h "$ZIP" | cut -f1) $ZIP"

# ---------- release notes → HTML for the appcast ----------
notes_to_html() {  # markdown-ish text on stdin → simple HTML on stdout
  python3 - <<'PY'
import html, re, sys
out, in_list = [], False
for raw in sys.stdin.read().splitlines():
    line = raw.rstrip()
    if in_list and not line.lstrip().startswith(("- ", "* ")):
        out.append("</ul>"); in_list = False
    if not line.strip():
        continue
    text = html.escape(line.strip())
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", text)
    text = re.sub(r"\[([^\]]+)\]\((https?://[^)]+)\)", r'<a href="\2">\1</a>', text)
    if line.startswith("#"):
        level = min(len(line) - len(line.lstrip("#")), 3)
        out.append(f"<h{level + 1}>{text.lstrip('# ').strip()}</h{level + 1}>")
    elif line.lstrip().startswith(("- ", "* ")):
        if not in_list:
            out.append("<ul>"); in_list = True
        out.append(f"<li>{text[2:].strip()}</li>")
    else:
        out.append(f"<p>{text}</p>")
if in_list:
    out.append("</ul>")
print("\n".join(out))
PY
}

make_appcast() {
  local notes_md="$1"
  if [[ -n "$notes_md" ]]; then
    notes_to_html < "$notes_md" > "$DIST/$APP_NAME-$VERSION.html"
  fi
  "$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "$DOWNLOAD_PREFIX" \
    --link "https://github.com/$REPO/releases/tag/$TAG" \
    --full-release-notes-url "https://github.com/$REPO/releases" \
    -o "$DIST/appcast.xml" "$DIST" >/dev/null
  rm -f "$DIST/$APP_NAME-$VERSION.html"
  grep -q "sparkle:edSignature" "$DIST/appcast.xml" || die "appcast has no EdDSA signature (is the Sparkle key in your keychain?)"
}

if [[ -n "$NOTES_FILE" || $DRY_RUN -eq 1 ]]; then
  step "Generating Sparkle appcast"
  make_appcast "$NOTES_FILE"
fi

if [[ $DRY_RUN -eq 1 ]]; then
  step "Dry run complete (version bump reverted)"
  cp build/project.yml.before-release project.yml
  xcodegen generate --quiet
  ls -la "$DIST"
  exit 0
fi

# ---------- git ----------
if [[ $NO_GIT -eq 0 ]]; then
  step "Committing and tagging $TAG"
  git add project.yml
  git commit -q -m "Release $VERSION"
  git tag -a "$TAG" -m "$APP_NAME $VERSION"
  git push -q origin HEAD
  git push -q origin "$TAG"
fi

# ---------- GitHub release ----------
step "Creating GitHub release $TAG"
GH_ARGS=(--repo "$REPO" --title "$APP_NAME $VERSION")
[[ $DRAFT -eq 1 ]] && GH_ARGS+=(--draft)
[[ $PRERELEASE -eq 1 ]] && GH_ARGS+=(--prerelease)
if [[ -n "$NOTES_FILE" ]]; then
  gh release create "$TAG" "$ZIP" "$DIST/install.txt" "$DIST/appcast.xml" "${GH_ARGS[@]}" --notes-file "$NOTES_FILE"
else
  gh release create "$TAG" "$ZIP" "$DIST/install.txt" "${GH_ARGS[@]}" --generate-notes
  step "Generating Sparkle appcast from the release notes"
  gh release view "$TAG" --repo "$REPO" --json body --jq .body > "$DIST/.notes.md"
  make_appcast "$DIST/.notes.md"
  rm -f "$DIST/.notes.md"
  gh release upload "$TAG" "$DIST/appcast.xml" --repo "$REPO" --clobber
fi

step "Done"
echo "  https://github.com/$REPO/releases/tag/$TAG"
echo "  Sparkle feed: https://github.com/$REPO/releases/latest/download/appcast.xml"
