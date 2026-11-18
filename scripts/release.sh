#!/bin/zsh
# Publish a release: scripts/release.sh 0.1.1
# 1. Add a "## 0.1.1 · Month Day, Year" section to CHANGELOG.md first.
# 2. This sets VERSION, builds the DMG, commits, tags, pushes, and creates a
#    GitHub release with the DMG and that changelog section.
set -euo pipefail
cd "${0:A:h:h}"
V="${1:?Usage: scripts/release.sh <version>  e.g. 0.1.1}"
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first."; exit 1; }
grep -q "^## $V " CHANGELOG.md || { echo "Add a '## $V · <date>' section to CHANGELOG.md first."; exit 1; }
NOTES=$(awk -v v="$V" '$0 ~ "^## "v" " {on=1; next} /^## / && on {exit} on' CHANGELOG.md)
echo "$V" > VERSION
app/build-app.sh --dmg
git add VERSION && git commit -m "Release $V"
git tag "v$V"
git push origin HEAD --tags
gh release create "v$V" "dist/AirPlay-Splitter-$V.dmg" --title "AirPlay Splitter $V" --notes "$NOTES"
echo "Published $V"
