#!/usr/bin/env bash
# Publish TotemRange as a release of the public GitHub repo shrimptec/TotemRange, which is where
# the wowupd addon manager pulls updates from.
#
#   ./release.sh patch|minor|major|X.Y.Z  ["release notes"]
#
# It runs the checks, bumps `## Version:` in the .toc, builds TotemRange-vX.Y.Z-forever.zip
# (folder TotemRange/ at the top, the layout wowupd and the game need), commits, tags vX.Y.Z,
# pushes, creates the GitHub release and downloads the asset back to prove it is intact.
# The tag, the .toc version and the zip name always carry the same number: wowupd compares them.
set -euo pipefail
cd "$(dirname "$0")"

REPO="shrimptec/TotemRange"
NAME="TotemRange"
TOC="$NAME/$NAME.toc"
BUMP="${1:-}"
NOTES="${2:-}"
[ -n "$BUMP" ] || { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

command -v gh >/dev/null || { echo "gh (GitHub CLI) not found" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not logged in: gh auth login" >&2; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git repo" >&2; exit 1; }
git remote get-url origin >/dev/null 2>&1 || { echo "no 'origin' remote" >&2; exit 1; }

echo "== checks"
for f in "$NAME"/*.lua t/harness.lua; do luac -p "$f"; done
luajit t/harness.lua | tail -1 | grep -q "ALL PASSED" || { echo "tests failed: luajit t/harness.lua" >&2; exit 1; }
grep -q '^## Interface: .*16001' "$TOC" || { echo "$TOC must declare ## Interface: 16001" >&2; exit 1; }
grep -q "^## X-Website: https://github.com/$REPO\$" "$TOC" || { echo "$TOC needs ## X-Website: https://github.com/$REPO" >&2; exit 1; }

echo "== version"
OLD=$(sed -n 's/^## Version:[[:space:]]*//p' "$TOC" | tr -d '\r' | head -1)
[[ "$OLD" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || { echo "## Version in $TOC must look like 1.2.3 (is '$OLD')" >&2; exit 1; }
MA=${BASH_REMATCH[1]} MI=${BASH_REMATCH[2]} PA=${BASH_REMATCH[3]}
case "$BUMP" in
	patch) NEW="$MA.$MI.$((PA + 1))" ;;
	minor) NEW="$MA.$((MI + 1)).0" ;;
	major) NEW="$((MA + 1)).0.0" ;;
	[0-9]*.[0-9]*.[0-9]*) NEW="$BUMP" ;;
	*) echo "bump must be patch, minor, major or X.Y.Z" >&2; exit 2 ;;
esac
[[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad version $NEW" >&2; exit 2; }
TAG="v$NEW"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
	echo "$TAG already exists" >&2; exit 1
fi
PREV=$(git describe --tags --abbrev=0 2>/dev/null || true)
echo "   $OLD -> $NEW ($TAG)"
python3 - "$TOC" "$NEW" <<'PY'
import re, sys
p, v = sys.argv[1:]
s = open(p, newline="").read()
s, n = re.subn(r"(?m)^(## Version:[ \t]*).*?(\r?)$", lambda m: m.group(1) + v + m.group(2), s, count=1)
assert n == 1, "no ## Version line"
open(p, "w", newline="").write(s)
PY

echo "== build"
mkdir -p dist
ZIP="dist/$NAME-$TAG-forever.zip"
rm -f "$ZIP"
python3 - "$NAME" "$ZIP" <<'PY'
import os, sys, zipfile
name, out = sys.argv[1:]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
    for root, dirs, files in os.walk(name):
        dirs[:] = sorted(d for d in dirs if not d.startswith("."))
        for f in sorted(files):
            if not f.startswith("."):
                path = os.path.join(root, f)
                zf.write(path, path.replace(os.sep, "/"))
with zipfile.ZipFile(out) as zf:
    names = zf.namelist()
    assert f"{name}/{name}.toc" in names, "toc missing"
    assert all(n.startswith(name + "/") for n in names), "files outside the addon folder"
    toc = zf.read(f"{name}/{name}.toc").decode()
    assert "## Interface: 16001" in toc, "wrong interface in the zip"
    print(f"   {out}: {len(names)} files")
PY

echo "== publish"
git add -A
git commit -q -m "Release $TAG" || true
git tag -a "$TAG" -m "$NAME $NEW"
git push -q origin HEAD
git push -q origin "$TAG"
if [ -z "$NOTES" ]; then
	if [ -n "$PREV" ]; then NOTES=$(git log --pretty='- %s' "$PREV..HEAD" | grep -v "^- Release v" || true)
	else NOTES="First release."; fi
	[ -n "$NOTES" ] || NOTES="Maintenance release."
fi
gh release create "$TAG" "$ZIP" -R "$REPO" --title "$NAME $NEW" --notes "$NOTES" --latest

echo "== verify"
CHECK=$(mktemp -d)
trap 'rm -rf "$CHECK"' EXIT
gh release download "$TAG" -R "$REPO" -p '*.zip' -D "$CHECK"
[ "$(sha256sum "$ZIP" | cut -d' ' -f1)" = "$(sha256sum "$CHECK"/*.zip | cut -d' ' -f1)" ] \
	|| { echo "the uploaded file differs from the local one" >&2; exit 1; }
LATEST=$(gh release view -R "$REPO" --json tagName -q .tagName)
[ "$LATEST" = "$TAG" ] || { echo "GitHub's latest release is $LATEST, not $TAG" >&2; exit 1; }
echo "published $TAG: $(gh release view "$TAG" -R "$REPO" --json url -q .url)"
echo "wowupd now sees $NEW."
