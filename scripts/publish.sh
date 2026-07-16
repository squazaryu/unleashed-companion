#!/bin/bash
# Build + publish a new TumoCompanion version and update the Feather source.
#   1. builds the unsigned IPA
#   2. creates/updates the GitHub release with the IPA
#   3. bumps apps.json (top-level + versions history) and pushes it
# Usage: ./scripts/publish.sh ["release notes"]
# Bump MARKETING_VERSION in project.yml BEFORE running.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
REPO="squazaryu/TumoCompanion"
FEATHER_REPO="$ROOT"
ASSET="TumoCompanion-unsigned.ipa"

echo "==> Syncing Feather metadata"
if [ -n "$(git -C "$FEATHER_REPO" status --porcelain)" ]; then
  echo "error: feather-repo has uncommitted changes" >&2
  exit 1
fi
if [ "$(git -C "$FEATHER_REPO" branch --show-current)" != "main" ]; then
  echo "error: feather-repo must be on main" >&2
  exit 1
fi
git -C "$FEATHER_REPO" fetch -q origin main
git -C "$FEATHER_REPO" merge -q --ff-only origin/main

echo "==> Building IPA"
./scripts/build_ipa.sh >/dev/null

VER=$(awk -F'"' '/MARKETING_VERSION:/{print $2; exit}' project.yml)
IPA="$ROOT/build/$ASSET"
SIZE=$(stat -f%z "$IPA")
DATE=$(date +%Y-%m-%d)
DL="https://github.com/$REPO/releases/download/v$VER/$ASSET"
NOTES="${1:-Update $VER}"
echo "==> Version $VER ($SIZE bytes)"

echo "==> Validating IPA"
VERIFY_DIR=$(mktemp -d)
trap 'rm -rf "$VERIFY_DIR"' EXIT
unzip -q "$IPA" -d "$VERIFY_DIR"
APP="$VERIFY_DIR/Payload/UnleashedCompanion.app"
if [ ! -f "$APP/Info.plist" ]; then
  echo "error: IPA does not contain Payload/UnleashedCompanion.app" >&2
  exit 1
fi
if [ "$(plutil -extract CFBundlePackageType raw "$APP/Info.plist")" != "APPL" ]; then
  echo "error: IPA payload is not an iOS application" >&2
  exit 1
fi
if [ "$(plutil -extract CFBundleShortVersionString raw "$APP/Info.plist")" != "$VER" ]; then
  echo "error: IPA version does not match project.yml" >&2
  exit 1
fi

echo "==> GitHub release"
if gh release view "v$VER" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "v$VER" "$IPA" --repo "$REPO" --clobber
else
  gh release create "v$VER" --repo "$REPO" --title "TumoCompanion $VER" --notes "$NOTES" "$IPA"
fi
ASSET_NAME=$(gh release view "v$VER" --repo "$REPO" --json assets \
  --jq ".assets[] | select(.name == \"$ASSET\") | .name")
if [ "$ASSET_NAME" != "$ASSET" ]; then
  echo "error: release asset was not published" >&2
  exit 1
fi

echo "==> Updating apps.json"
python3 - "$VER" "$DATE" "$SIZE" "$DL" "$NOTES" <<'PY'
import json, sys
ver, date, size, dl, notes = sys.argv[1:6]
p = "apps.json"
d = json.load(open(p))
app = d["apps"][0]
app["version"] = ver
app["versionDate"] = date
app["versionDescription"] = notes
app["downloadURL"] = dl
app["size"] = int(size)
vs = [v for v in app.get("versions", []) if v.get("version") != ver]
vs.insert(0, {"version": ver, "date": date, "localizedDescription": notes,
              "downloadURL": dl, "size": int(size), "minOSVersion": "17.0"})
app["versions"] = vs
json.dump(d, open(p, "w"), indent=2)
print("apps.json now at", ver)
PY

echo "==> Pushing apps.json"
cd "$FEATHER_REPO"
git add apps.json
git -c user.email="squazaryu@users.noreply.github.com" -c user.name="squazaryu" commit -q -m "Release $VER" || true
git push -q origin main
git fetch -q origin main
LOCAL_SHA=$(git rev-parse HEAD)
REMOTE_SHA=$(git rev-parse origin/main)
if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
  echo "error: local main ($LOCAL_SHA) differs from origin/main ($REMOTE_SHA)" >&2
  exit 1
fi
echo "==> Published $VER at $REMOTE_SHA. Feather will offer the update on its next source refresh."
