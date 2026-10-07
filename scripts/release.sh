#!/bin/bash
# Publishes a GitHub release: builds dist/Subtits-<version>.dmg from the committed code, tags v<version>,
# pushes main and the tag, then creates the release with the DMG attached.
#   VERSION=1.5.0 NOTES=~/notes-1.5.0.md ./scripts/release.sh     (keep the notes file outside the repo)
# git goes through the remote's deploy key (git@github-subtits:..., see ~/.ssh/config). The release API needs a
# fine-grained token of tihomirov-nick with Contents: Read and write on this repo, kept in the Keychain under
# TOKEN_SERVICE (account tihomirov-nick). gh's own login is a different account and is not used.
# Safe to re-run: an existing tag on HEAD and an existing release are reused.
set -euo pipefail

VERSION="${VERSION:?set VERSION, e.g. VERSION=1.5.0}"
NOTES="${NOTES:?set NOTES to a Markdown file with the release notes}"
[ -f "$NOTES" ] || { echo "no notes file: $NOTES"; exit 1; }
NOTES="$(cd "$(dirname "$NOTES")" && pwd)/$(basename "$NOTES")"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REPO="tihomirov-nick/subtits"
TOKEN_SERVICE="${TOKEN_SERVICE:-github-mpxtrans-token}"   # one token shared with the mpxtrans repo
TAG="v$VERSION"
DMG="dist/Subtits-$VERSION.dmg"

# 1. The release must match committed code on main
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "switch to main first"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "commit or stash changes first (untracked files count too)"; exit 1; }
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && [ "$(git rev-parse "$TAG^{commit}")" != "$(git rev-parse HEAD)" ]; then
    echo "$TAG already points to another commit"; exit 1
fi
TOKEN="$(security find-generic-password -a tihomirov-nick -s "$TOKEN_SERVICE" -w 2>/dev/null)" ||
    { echo "no GitHub token in the Keychain (service $TOKEN_SERVICE, account tihomirov-nick)"; exit 1; }

# 2. Build (build_app.sh regenerates Localizable.strings, which is tracked)
VERSION="$VERSION" ./scripts/make_dmg.sh
[ -z "$(git status --porcelain)" ] || { echo "the build changed tracked files, commit them and run again:"; git status --short; exit 1; }

# 3. Tag and push
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git tag -a "$TAG" -m "Subtits $VERSION"
git push origin main "$TAG"

# 4. Release with the DMG
if GH_TOKEN="$TOKEN" gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    GH_TOKEN="$TOKEN" gh release upload "$TAG" "$DMG" --repo "$REPO" --clobber
    GH_TOKEN="$TOKEN" gh release edit "$TAG" --repo "$REPO" --draft=false --notes-file "$NOTES"
else
    GH_TOKEN="$TOKEN" gh release create "$TAG" "$DMG" --repo "$REPO" --verify-tag \
        --title "Subtits $VERSION" --notes-file "$NOTES"
fi
echo "==> https://github.com/$REPO/releases/tag/$TAG"
