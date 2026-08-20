# RepoBar

A small, modern macOS menu bar app that watches your local git repositories and tells you —
without clicking — when the remote has new commits.

- **Colored dots in the menu bar, one per repository.** Filled = new commits on the remote,
  faded = up to date, ring with `!` = the last check failed. "3 of 5 repos changed" is readable at a glance.
  Prefer a number? Switch to the *Count* style in Settings.
- **Panel** with every repository: branch, ↓ behind / ↑ ahead, uncommitted-changes dot, the incoming
  commits (click one to open it on GitHub/GitLab/Bitbucket/…), *Pull* (fast-forward only, never a merge),
  *Mark as seen*, *Open in* Finder / Terminal / your editor.
- **Notifications** when new commits arrive (per-repository mute), with *Open* and *Pull* actions.
- **Zero surprises:** checks use `git ls-remote` first and only `fetch` when the branch tip moved,
  never touch your working tree, honour your `~/.ssh`, credential helpers and `core.sshCommand`,
  back off on auth failures, pause on battery saver / offline, and re-check after wake.

Requires macOS 14 (Sonoma) or later and a `git` binary (Homebrew or the Xcode Command Line Tools).

## Install

Download `RepoBar-<version>.zip` from the [latest release](https://github.com/aliyar/repobar/releases/latest),
unzip it and drag `RepoBar.app` to `/Applications`. The app is not notarized, so the first launch needs
one extra step — see `install.txt` in the release (macOS 14: right-click → Open; macOS 15+: System Settings →
Privacy & Security → Open Anyway). RepoBar then checks for updates daily via [Sparkle](https://sparkle-project.org)
and can update itself; About → *Check for Updates…* checks on demand.

## Build

```sh
brew install xcodegen        # once
make run                     # generate project, build Debug, launch
make test                    # engine tests (swift test) + app tests (xcodebuild)
make logs                    # follow OSLog output
```

`project.yml` is the source of truth; `RepoBar.xcodeproj` is generated and git-ignored.
`make open` opens the generated project in Xcode.

## How a check works

1. `git status --porcelain=v2 --branch` — branch, upstream, working-tree state (read-only, no index writes).
2. Resolve the watched ref: the current branch's upstream → the remote's default branch → a per-repo override.
3. `git ls-remote --heads origin <branch>` — compare the remote tip with `refs/remotes/origin/<branch>`.
4. Only if it moved: `git fetch --porcelain --no-write-fetch-head --no-auto-maintenance origin`.
5. `git rev-list --left-right --count` for ahead/behind and "unseen since you last looked",
   `git log HEAD..origin/<branch>` for the commit list.

Data lives in `~/Library/Application Support/RepoBar/` (`repos.json` = your list, `state.json` = cache).

## Layout

```
RepoBar/                 SwiftUI app: status item (AppKit NSStatusItem + NSPopover), panel, settings, notifications
Packages/RepoBarKit/     GitEngine: process runner, git client, parsers, checker, scheduler, persistence (+ tests)
Scripts/                 make-icon.swift (app icon), release.sh (Developer ID + notarization + DMG)
```

## Release

```sh
make release VERSION=1.2.3 [NOTES=notes.md] [FLAGS="--draft"]   # the whole thing
make release-dry VERSION=1.2.3                                   # only build dist/, no git/GitHub
```

`Scripts/release.sh` bumps `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in `project.yml`, builds a Release
app (ad-hoc signed, or Developer ID + notarization when such a certificate and `NOTARY_PROFILE` exist),
zips it together with `install.txt`, signs the archive with the Sparkle EdDSA key, writes `appcast.xml`,
commits and tags `vX.Y.Z`, pushes, and publishes a GitHub release with the zip, `install.txt` and
`appcast.xml` as assets. Running apps pick the update up from
`https://github.com/aliyar/repobar/releases/latest/download/appcast.xml`.

The EdDSA private key lives in the login keychain (created once with Sparkle's `generate_keys`; the public
half is `SUPublicEDKey` in `project.yml`). Back it up with `generate_keys -x <file>` and keep it out of the
repository — without it you cannot sign future updates. Sparkle's tools are under
`build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/` after the first build.
