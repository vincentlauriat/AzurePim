#!/usr/bin/env bash
# Build a universal Release AzPim.app, sign it with Developer ID and Hardened
# Runtime, package it as a DMG, notarize and staple it, then sign it for Sparkle
# and prepare its appcast.xml item.
#
# +--------------------------------------------------------------------------+
# | SPARKLE SIGNING KEY: DO NOT REGENERATE                                     |
# |                                                                            |
# | Updates are EdDSA-signed with the private key in the login keychain under  |
# | account "AzurePim" (historical name of the app, kept on purpose: never     |
# | rename the account). Its public half is SUPublicEDKey in project.yml:      |
# |     oGxHAH0aXmMuHBG/E6/PsROoQPDhw3vicDP+FK1S4hA=                           |
# |                                                                            |
# | Never import a new key into this account and never change SUPublicEDKey:   |
# | every installed app would reject all future updates. Back it up with       |
# | `generate_keys -x <absolute path outside this repo> --account AzurePim`.   |
# +--------------------------------------------------------------------------+
#
# Usage:
#   ./Scripts/release.sh <version>                    e.g. ./Scripts/release.sh 0.9.3
#   ./Scripts/release.sh --publish-appcast <version>  after `gh release create`
#
# Before a build run: bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in
# project.yml, write release/release-notes-<version>.md, commit, and run from a
# clean `main`.
#
# The build run outputs release/AzPim-<version>.dmg and the signed appcast item
# release/appcast-item-<version>.xml. It does NOT publish and does NOT touch
# appcast.xml: Sparkle must never be offered an enclosure that does not exist yet.
# --publish-appcast checks that the uploaded DMG answers (curl -fsIL), then prepends
# the item to appcast.xml; older items are always kept.

set -euo pipefail

# Notary credentials: an App Store Connect API key (.p8) when NOTARY_KEY_ID, NOTARY_ISSUER_ID and
# NOTARY_KEY_PATH are set or read from ~/.config/notarytool/api-key.env (it survives a keychain
# reset); otherwise the keychain profile given as first argument. Usage: notary_run <profile> <args>
notary_run() {
  _np="$1"; shift
  _nf="${NOTARY_ENV_FILE:-$HOME/.config/notarytool/api-key.env}"
  if [ -z "${NOTARY_KEY_ID:-}" ] && [ -f "$_nf" ]; then . "$_nf"; fi
  if [ -n "${NOTARY_KEY_ID:-}" ]; then
    xcrun notarytool "$@" --key "${NOTARY_KEY_PATH/#\~/$HOME}" --key-id "$NOTARY_KEY_ID" --issuer "${NOTARY_ISSUER_ID:-}"
  else
    xcrun notarytool "$@" --keychain-profile "$_np"
  fi
}

USAGE="Usage: ./Scripts/release.sh [--publish-appcast] <version>  (e.g. ./Scripts/release.sh 0.9.3)"
MODE=build
if [ "${1:-}" = "--publish-appcast" ]; then
  MODE=publish
  shift
fi
VERSION="${1:?$USAGE}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APPCAST="$ROOT/appcast.xml"
RELEASE_DIR="$ROOT/release"
NOTES="$RELEASE_DIR/release-notes-$VERSION.md"
ITEM_FILE="$RELEASE_DIR/appcast-item-$VERSION.xml"
ENCLOSURE_URL="https://github.com/vincentlauriat/AzPim/releases/download/v$VERSION/AzPim-$VERSION.dmg"
RELEASE_PAGE="https://github.com/vincentlauriat/AzPim/releases/tag/v$VERSION"
# First build shipped as AzPim (bundle id fr.vincentlauriat.azpim). GitHub serves this feed to AzurePim 0.9.x
# too (old repository URL, builds <= 5, other bundle id): every new item is informational below this build, so
# AzurePim is told to download AzPim from the web instead of installing a different app over itself.
FIRST_AZPIM_BUILD=6

# Highest sparkle:version across every item of appcast.xml (0 when there is none).
# Fails if the feed is not well-formed XML or a build number is not an integer.
appcast_max_build() {
  python3 - "$APPCAST" <<'PY'
import sys
import xml.etree.ElementTree as ET
ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
try:
    channel = ET.parse(sys.argv[1]).getroot().find("channel")
    builds = [int(i.findtext(ns + "version") or "") for i in channel.findall("item")]
except (ET.ParseError, AttributeError, ValueError) as exc:
    sys.exit(f"✗ cannot read build numbers from {sys.argv[1]}: {exc}")
print(max(builds, default=0))
PY
}

# sparkle:version of the item fragment written by the build run. The fragment
# has no namespace declaration of its own: parse it inside a wrapper that has one.
item_build() {
  python3 - "$ITEM_FILE" <<'PY'
import sys
import xml.etree.ElementTree as ET
ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
with open(sys.argv[1], encoding="utf-8") as f:
    fragment = f.read()
try:
    root = ET.fromstring(f'<channel xmlns:sparkle="{ns}">{fragment}</channel>')
except ET.ParseError as exc:
    sys.exit(f"✗ {sys.argv[1]} is not a well-formed appcast item: {exc}")
items = root.findall("item")
if len(items) != 1:
    sys.exit(f"✗ {sys.argv[1]} must hold exactly one <item>")
print(items[0].findtext("{%s}version" % ns) or "")
PY
}

# Highest CURRENT_PROJECT_VERSION across the release tags v*, except v$VERSION
# (it exists once `gh release create` ran, before --publish-appcast). A withdrawn
# release leaves the appcast but keeps its tag, so its build number stays burnt.
tags_max_build() {
  python3 - "v$VERSION" <<'PY'
import re
import subprocess
import sys
current = sys.argv[1]
tags = subprocess.run(["git", "tag", "-l", "v*"], check=True, capture_output=True, text=True).stdout.split()
builds = [0]
for tag in tags:
    if tag == current:
        continue
    shown = subprocess.run(["git", "show", f"{tag}:project.yml"], capture_output=True, text=True)
    if shown.returncode != 0:
        continue  # tag older than project.yml
    m = re.search(r'^\s*CURRENT_PROJECT_VERSION:\s*"?(\d+)"?', shown.stdout, re.MULTILINE)
    if m:
        builds.append(int(m.group(1)))
print(max(builds))
PY
}

# Refuse a build number that is not strictly greater than every build in the feed
# and in every release tag: Sparkle would ignore the update, or two different DMGs
# would share one number.
require_new_build() {
  local build="$1" newest tagged
  newest="$(appcast_max_build)"
  tagged="$(tags_max_build)"
  [ "$tagged" -le "$newest" ] || newest="$tagged"
  case "$build" in
    ''|*[!0-9]*) echo "✗ build number '$build' is not an integer" >&2; exit 1 ;;
  esac
  if [ "$build" -le "$newest" ]; then
    echo "✗ build number $build is not greater than the newest in appcast.xml or the v* tags ($newest)." >&2
    echo "  Bump CURRENT_PROJECT_VERSION in project.yml; never reuse a build number." >&2
    exit 1
  fi
}

if [ "$MODE" = publish ]; then
  # 8. Publish the appcast item, only once the DMG it points at is downloadable.
  [ -f "$ITEM_FILE" ] || { echo "✗ $ITEM_FILE not found: run ./Scripts/release.sh $VERSION first" >&2; exit 1; }
  ITEM_BUILD="$(item_build)"
  require_new_build "$ITEM_BUILD"
  LOCAL_DMG="$RELEASE_DIR/AzPim-$VERSION.dmg"
  [ -f "$LOCAL_DMG" ] || { echo "✗ $LOCAL_DMG not found: it is the DMG the item was signed for" >&2; exit 1; }
  echo "→ Checking the enclosure is downloadable: $ENCLOSURE_URL"
  # -L: GitHub answers 302 to its object storage; check the asset itself.
  if ! curl -fsIL -o /dev/null "$ENCLOSURE_URL"; then
    echo "✗ $ENCLOSURE_URL does not answer. Upload the DMG first:" >&2
    echo "  gh release create v$VERSION ./release/AzPim-$VERSION.dmg --title \"v$VERSION\" --notes-file release/release-notes-$VERSION.md" >&2
    exit 1
  fi
  # The item's EdDSA signature covers the local DMG: the uploaded asset must be that file.
  echo "→ Checking the uploaded asset is the signed DMG (SHA-256)"
  DL_DIR="$(mktemp -d)"
  curl -fsSL -o "$DL_DIR/enclosure.dmg" "$ENCLOSURE_URL"
  REMOTE_SHA="$(shasum -a 256 "$DL_DIR/enclosure.dmg" | cut -d ' ' -f1)"
  LOCAL_SHA="$(shasum -a 256 "$LOCAL_DMG" | cut -d ' ' -f1)"
  rm -rf "$DL_DIR"
  if [ "$REMOTE_SHA" != "$LOCAL_SHA" ]; then
    echo "✗ the uploaded asset differs from $LOCAL_DMG" >&2
    echo "  remote $REMOTE_SHA" >&2
    echo "  local  $LOCAL_SHA" >&2
    exit 1
  fi
  echo "→ Prepending v$VERSION (build $ITEM_BUILD) to appcast.xml"
  python3 - "$APPCAST" "$ITEM_FILE" "$ITEM_BUILD" <<'PY'
import sys
import xml.etree.ElementTree as ET
feed_path, item_path, build = sys.argv[1], sys.argv[2], int(sys.argv[3])
ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
with open(feed_path, encoding="utf-8") as f:
    feed = f.read()
with open(item_path, encoding="utf-8") as f:
    item = f.read().strip()
before = len(ET.fromstring(feed).find("channel").findall("item"))
# Text insertion keeps the existing items byte for byte; the result is re-parsed below.
anchor = feed.find("<item>")
if anchor != -1:
    new_feed = feed[:anchor] + item + "\n    " + feed[anchor:]
else:
    anchor = feed.find("</channel>")
    if anchor == -1:
        sys.exit("✗ appcast.xml has no </channel>")
    new_feed = feed[:anchor] + "  " + item + "\n  " + feed[anchor:]
items = ET.fromstring(new_feed).find("channel").findall("item")
first = int(items[0].findtext(ns + "version"))
newest = max(int(i.findtext(ns + "version")) for i in items)
if len(items) != before + 1 or first != build or newest != build:
    sys.exit("✗ prepending the item did not give the expected feed; appcast.xml left unchanged")
with open(feed_path, "w", encoding="utf-8") as f:
    f.write(new_feed)
print(f"  appcast.xml: {len(items)} item(s), newest build {newest}")
PY
  echo ""
  echo "✅ appcast.xml updated for v$VERSION. Publish it through a PR (never push to main):"
  echo "  git switch -c chore/appcast-$VERSION && git add appcast.xml"
  echo "  git commit -m 'chore: publish appcast for v$VERSION' && git push -u origin chore/appcast-$VERSION"
  echo "  gh pr create --fill   # squash-merge once CI is green"
  exit 0
fi

# 0. Preflight, before anything slow: release notes, branch, clean tree.
if [ ! -s "$NOTES" ]; then
  echo "✗ Release notes $NOTES are missing or empty. Write them first." >&2
  exit 1
fi
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "main" ]; then
  echo "✗ Releases are built from main (current branch: $BRANCH)." >&2
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "✗ Working tree is not clean: commit or discard changes first." >&2
  git status --short >&2
  exit 1
fi
git fetch -q origin main
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo "✗ HEAD is not origin/main: pull (or push through a PR) first." >&2
  exit 1
fi
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
  echo "✗ Tag v$VERSION already exists: a released version is never rebuilt." >&2
  exit 1
fi
appcast_max_build >/dev/null

# 1. Sanity check: project.yml must declare the same MARKETING_VERSION
if ! grep -q "MARKETING_VERSION: \"$VERSION\"" project.yml; then
  echo "✗ MARKETING_VERSION in project.yml does not match $VERSION" >&2
  echo "  Found:" >&2
  grep "MARKETING_VERSION" project.yml | sed 's/^/    /' >&2
  echo "  Bump project.yml first, then re-run." >&2
  exit 1
fi

# 3. Regenerate xcodeproj
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "✗ XcodeGen not installed. brew install xcodegen" >&2
  exit 1
fi
echo "→ xcodegen generate"
xcodegen generate >/dev/null

# 4. Build Release
# CODE_SIGNING_ALLOWED=NO works around the macOS Sequoia
# `com.apple.provenance` xattr that breaks ad-hoc codesign in CLI.
# We sign manually below after a clean xattr scrub.
echo "→ xcodebuild Release"
xcodebuild -project AzPim.xcodeproj \
  -scheme AzPim \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tail -5

APP="$ROOT/build/Build/Products/Release/AzPim.app"
if [ ! -d "$APP" ]; then
  echo "✗ Build did not produce $APP" >&2
  exit 1
fi

# The first shipped build must already carry a working updater: Sparkle cannot
# repair a missing feed or key later. Check what was built, not project.yml.
plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
[ "$(plist_value CFBundleShortVersionString)" = "$VERSION" ] || { echo "✗ built version is not $VERSION" >&2; exit 1; }
[ "$(plist_value SUFeedURL)" = "https://raw.githubusercontent.com/vincentlauriat/AzPim/main/appcast.xml" ] || { echo "✗ unexpected SUFeedURL" >&2; exit 1; }
BUILT_ARCHS="$(lipo -archs "$APP/Contents/MacOS/AzPim")"
case "$BUILT_ARCHS" in
  *x86_64*arm64*|*arm64*x86_64*) ;;
  *) echo "✗ not a universal binary: $BUILT_ARCHS" >&2; exit 1 ;;
esac

# Sparkle compares <sparkle:version> against the running app's CFBundleVersion
# (a monotonically increasing build number), NOT against the marketing version.
# If we put "0.7.0" here while the installed app reports CFBundleVersion="1",
# Sparkle's standard comparator sees [0,7,0] < [1] and concludes "up to date".
# Read the actual CFBundleVersion baked into the .app, and check it before the
# slow signing and notarization steps.
BUILD_NUMBER="$(plist_value CFBundleVersion)"
require_new_build "$BUILD_NUMBER"

# 5. Stage to a clean directory, Developer ID sign with Hardened Runtime, package.
# Direct in-place codesign fails because Xcode's post-build `lsregister`
# adds `com.apple.provenance` xattrs, which `codesign --force` rejects with
# "resource fork, Finder information, or similar detritus not allowed".
# `ditto --noextattr` copies without xattrs and survives.
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Vincent LAURIAT (KFLACS69T9)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AppliMacVincentGithub}"

STAGING_DIR="$(mktemp -d)"
STAGING="$STAGING_DIR/AzPim.app"
echo "→ Staging to $STAGING_DIR"
ditto --norsrc --noextattr --noacl "$APP" "$STAGING"

# Developer ID provisioning profile: required by the restricted entitlements in AzPim.entitlements
# (application-identifier, keychain-access-groups for the MSAL token cache). Kept outside the repo.
PROVISIONING_PROFILE="${PROVISIONING_PROFILE:-$HOME/DevApps/Templates/clefs/AzPim_Developer_ID.provisionprofile}"
echo "→ Embedding the provisioning profile $PROVISIONING_PROFILE"
[ -f "$PROVISIONING_PROFILE" ] || { echo "✗ provisioning profile not found: $PROVISIONING_PROFILE" >&2; exit 1; }
PROFILE_PLIST="$STAGING_DIR/profile.plist"
security cms -D -i "$PROVISIONING_PROFILE" > "$PROFILE_PLIST"
SIGNING_SERIAL="$(security find-certificate -c "$SIGNING_IDENTITY" -p | openssl x509 -noout -serial | cut -d= -f2)"
python3 -I - "$PROFILE_PLIST" "KFLACS69T9.$(plist_value CFBundleIdentifier)" "$SIGNING_SERIAL" <<'PY'
import datetime, plistlib, subprocess, sys
profile = plistlib.load(open(sys.argv[1], "rb"))
app_id, serial = sys.argv[2], sys.argv[3].upper()
ent = profile["Entitlements"]
if ent.get("com.apple.application-identifier") != app_id:
    sys.exit(f"✗ profile is for {ent.get('com.apple.application-identifier')}, not {app_id}")
if "KFLACS69T9.*" not in ent.get("keychain-access-groups", []):
    sys.exit("✗ profile does not allow the KFLACS69T9.* keychain groups")
if profile["ExpirationDate"] <= datetime.datetime.now():
    sys.exit(f"✗ profile expired on {profile['ExpirationDate']:%Y-%m-%d}")
serials = []
for der in profile["DeveloperCertificates"]:
    out = subprocess.run(["openssl", "x509", "-inform", "DER", "-noout", "-serial"], input=der,
                         capture_output=True, check=True).stdout.decode()
    serials.append(out.strip().split("=", 1)[1].upper())
if serial not in serials:
    sys.exit(f"✗ profile does not include the signing certificate {serial} (has {', '.join(serials)})")
print(f"  profile {profile['Name']} OK (expires {profile['ExpirationDate']:%Y-%m-%d})")
PY
cp "$PROVISIONING_PROFILE" "$STAGING/Contents/embedded.provisionprofile"

# Apple's timestamp.apple.com is intermittently flaky — we've seen
# "A timestamp was expected but was not found." mid-pipeline several times.
# Retry up to 5 times with a short backoff before giving up.
codesign_ts() {
  local target="$1"
  shift
  local attempt
  for attempt in 1 2 3 4 5; do
    if codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$@" "$target" 2>&1; then
      return 0
    fi
    if [ "$attempt" -lt 5 ]; then
      echo "  ↻ codesign failed (attempt $attempt/5), retrying in 5s…"
      sleep 5
    fi
  done
  echo "✗ codesign $target failed after 5 attempts" >&2
  return 1
}

echo "→ Codesigning Sparkle.framework nested binaries (deepest first)"
SPARKLE_FW="$STAGING/Contents/Frameworks/Sparkle.framework"
SPARKLE_VER="$SPARKLE_FW/Versions/B"
codesign_ts "$SPARKLE_VER/Autoupdate"
codesign_ts "$SPARKLE_VER/XPCServices/Downloader.xpc"
codesign_ts "$SPARKLE_VER/XPCServices/Installer.xpc"
codesign_ts "$SPARKLE_VER/Updater.app"
codesign_ts "$SPARKLE_FW"

echo "→ Codesigning any other embedded framework"
for FW in "$STAGING"/Contents/Frameworks/*; do
  [ -e "$FW" ] || continue
  [ "$FW" = "$SPARKLE_FW" ] || codesign_ts "$FW"
done

echo "→ Codesigning the app itself with Developer ID + Hardened Runtime"
codesign_ts "$STAGING" --entitlements "$ROOT/AzPim/AzPim.entitlements"
codesign --verify --strict --deep "$STAGING"
# Notarization rejects an app without Hardened Runtime or a Developer ID signature;
# check both here rather than after a 5-minute round trip to Apple.
SIGN_INFO="$(codesign -dvv "$STAGING" 2>&1)"
case "$SIGN_INFO" in
  *" flags=0x"*"("*runtime*")"*) ;;
  *) echo "✗ the app is not signed with Hardened Runtime (no 'runtime' in the CodeDirectory flags)" >&2; exit 1 ;;
esac
case "$SIGN_INFO" in
  *"Authority=Developer ID Application"*) ;;
  *) echo "✗ the app is not signed with a Developer ID Application certificate" >&2; exit 1 ;;
esac

mkdir -p "$RELEASE_DIR"
DMG="$RELEASE_DIR/AzPim-$VERSION.dmg"
rm -f "$DMG"

# 5b. Build the DMG with a custom Finder layout: signed .app on the left,
# /Applications alias on the right, background image with an arrow between them.
# dmgbuild writes the .DS_Store itself. The Finder AppleScript it replaces needs
# Apple Events, which some shells cannot send, and silently shipped DMGs without
# a layout (ClaudeCockpit 1.1.3 and 1.1.4).
DMG_VOLNAME="AzPim $VERSION"
DMG_BG="$STAGING_DIR/background.png"
"$ROOT/Scripts/make-dmg-background.swift" "$DMG_BG" >/dev/null

# dmgbuild and its two dependencies, installed once per requirements file into a
# private venv, every wheel checked against its pinned hash.
DMGBUILD_REQS="$ROOT/Scripts/dmgbuild-requirements.txt"
DMGBUILD_VENV="$ROOT/.dmgbuild-venv/$(shasum -a 256 "$DMGBUILD_REQS" | cut -c1-12)"
if [ ! -x "$DMGBUILD_VENV/bin/dmgbuild" ]; then
  echo "→ Installing dmgbuild (one-time)"
  rm -rf "$DMGBUILD_VENV"
  python3 -m venv "$DMGBUILD_VENV"
  "$DMGBUILD_VENV/bin/pip" install --quiet --disable-pip-version-check \
    --only-binary=:all: --require-hashes -r "$DMGBUILD_REQS"
fi

# hdiutil detach can fail with "resource busy". Retry, then force.
detach_retry() {
  local mnt="$1" i
  for i in 1 2 3 4 5; do
    if hdiutil detach "$mnt" -quiet; then
      return 0
    fi
    echo "  …hdiutil detach retry $i/5 ($mnt busy) in 2s" >&2
    sleep 2
  done
  hdiutil detach "$mnt" -force -quiet
}
# Detach any volume left mounted by an aborted previous run of this version.
for STALE in "/Volumes/$DMG_VOLNAME" "/Volumes/$DMG_VOLNAME "[0-9]*; do
  if [ -d "$STALE" ]; then
    echo "  …detaching stale volume $STALE" >&2
    detach_retry "$STALE"
  fi
done

echo "→ Building $DMG with dmgbuild"
"$DMGBUILD_VENV/bin/dmgbuild" -s "$ROOT/Scripts/dmg-settings.py" \
  -D app="$STAGING" -D background="$DMG_BG" \
  "$DMG_VOLNAME" "$DMG" 2> >(grep -v "is deprecated" >&2) >/dev/null

# The layout is deterministic now, so its absence is a bug, not a Finder mood.
CHECK_MOUNT="$(hdiutil attach -nobrowse -readonly -noverify -noautoopen "$DMG" | awk -F '\t' 'END {print $NF}')"
LAYOUT_OK=1
for ITEM in .DS_Store .background.png Applications AzPim.app; do
  [ -e "$CHECK_MOUNT/$ITEM" ] || { echo "✗ DMG is missing $ITEM" >&2; LAYOUT_OK=0; }
done
codesign --verify --strict --deep "$CHECK_MOUNT/AzPim.app" || LAYOUT_OK=0
detach_retry "$CHECK_MOUNT"
[ "$LAYOUT_OK" = 1 ] || exit 1

rm -rf "$STAGING_DIR"

# 6. Notarize the DMG with Apple, then staple the ticket so the app
# launches on machines without internet access.
echo "→ Submitting $DMG to Apple notary service (this takes 2–5 min)"
# `submit --wait` exits 0 even when Apple returns "Invalid": read the status.
NOTARY_JSON="$(notary_run "$NOTARY_PROFILE" submit "$DMG" --wait --output-format json)" || true
# Any parse problem yields empty fields, so it reaches the "not accepted" path
# below (log + exit 1) instead of a python traceback.
NOTARY_FIELDS="$(printf '%s' "$NOTARY_JSON" | python3 -c "
import sys, json
text = sys.stdin.read()
try:
    d = json.loads(text)
except ValueError:
    # Progress text reached stdout: keep the last single-line JSON object.
    try:
        lines = [l for l in text.splitlines() if l.lstrip().startswith('{')]
        d = json.loads(lines[-1]) if lines else {}
    except ValueError:
        d = {}
if not isinstance(d, dict):
    d = {}
print(d.get('id', ''), d.get('status', ''), sep='\t')
")"
NOTARY_ID="$(printf '%s' "$NOTARY_FIELDS" | cut -f1)"
NOTARY_STATUS="$(printf '%s' "$NOTARY_FIELDS" | cut -f2)"
echo "  notarization $NOTARY_ID: $NOTARY_STATUS"
if [ "$NOTARY_STATUS" != "Accepted" ]; then
  echo "✗ notarization not accepted (status: ${NOTARY_STATUS:-unknown})" >&2
  if [ -n "$NOTARY_ID" ]; then
    notary_run "$NOTARY_PROFILE" log "$NOTARY_ID" >&2 || true
  fi
  exit 1
fi

echo "→ Stapling notarization ticket to the DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# Gatekeeper's verdict on the app exactly as users get it: inside the stapled DMG.
GK_MOUNT="$(hdiutil attach -nobrowse -readonly -noverify -noautoopen "$DMG" | awk -F '\t' 'END {print $NF}')"
GK_OK=1
spctl -a -t exec -vv "$GK_MOUNT/AzPim.app" || GK_OK=0
detach_retry "$GK_MOUNT"
[ "$GK_OK" = 1 ] || { echo "✗ Gatekeeper rejects the app inside $DMG" >&2; exit 1; }

# 7. Sign the DMG with the Sparkle EdDSA key and generate / refresh
# `appcast.xml` so the in-app updater (Sparkle 2) can serve this version.
# Keep in step with the Sparkle.framework version pinned in project.yml.
SPARKLE_VERSION="2.10.1"
# sign_update reads the private EdDSA key: never run an unverified download.
# SHA-256 of the exact tarball below (matches the digest GitHub publishes for the
# release asset); update both lines together.
SPARKLE_TARBALL_SHA256="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
# One cache directory per version: bumping SPARKLE_VERSION fetches fresh tools
# instead of silently reusing an older cached sign_update.
SPARKLE_TOOLS="$ROOT/.sparkle-tools/$SPARKLE_VERSION"
if [ ! -x "$SPARKLE_TOOLS/bin/sign_update" ]; then
  echo "→ Fetching Sparkle $SPARKLE_VERSION tools (one-time setup)"
  SPARKLE_DL_DIR="$(mktemp -d)"
  SPARKLE_TARBALL="$SPARKLE_DL_DIR/Sparkle-$SPARKLE_VERSION.tar.xz"
  curl -fsSL -o "$SPARKLE_TARBALL" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  ACTUAL_SHA256="$(shasum -a 256 "$SPARKLE_TARBALL" | cut -d ' ' -f1)"
  if [ "$ACTUAL_SHA256" != "$SPARKLE_TARBALL_SHA256" ]; then
    echo "✗ Sparkle tarball checksum mismatch" >&2
    echo "  expected $SPARKLE_TARBALL_SHA256" >&2
    echo "  got      $ACTUAL_SHA256" >&2
    exit 1
  fi
  mkdir -p "$SPARKLE_TOOLS"
  tar -xJf "$SPARKLE_TARBALL" -C "$SPARKLE_TOOLS"
  rm -rf "$SPARKLE_DL_DIR"
fi

# A mismatch would publish an update that every installed app rejects.
# Keychain account of the Sparkle key: "AzurePim", the app's name before the AzPim rename.
# Historical and deliberate: the key must never be regenerated or moved to another account.
SPARKLE_KEY_ACCOUNT="AzurePim"
KEYCHAIN_PUBKEY="$("$SPARKLE_TOOLS/bin/generate_keys" --account "$SPARKLE_KEY_ACCOUNT" -p)"
if [ "$KEYCHAIN_PUBKEY" != "$(plist_value SUPublicEDKey)" ]; then
  echo "✗ SUPublicEDKey in the app does not match the keychain key for account $SPARKLE_KEY_ACCOUNT" >&2
  exit 1
fi

echo "→ Signing $DMG with Sparkle EdDSA key"
# `sign_update` returns: sparkle:edSignature="..." length="<bytes>"
# (so we don't add `length=` ourselves on the <enclosure> — that would duplicate).
SPARKLE_SIG_LINE=$("$SPARKLE_TOOLS/bin/sign_update" --account "$SPARKLE_KEY_ACCOUNT" "$DMG")

# Written as a fragment, not into appcast.xml: `--publish-appcast` prepends it
# once the enclosure is downloadable, keeping every older item.
echo "→ Writing $ITEM_FILE (sparkle:version=$BUILD_NUMBER, shortVersionString=$VERSION)"
PUB_DATE=$(LC_ALL=C date -R)
cat > "$ITEM_FILE" <<APPCAST
<item>
      <title>v$VERSION</title>
      <link>$RELEASE_PAGE</link>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:informationalUpdate><sparkle:belowVersion>$FIRST_AZPIM_BUILD</sparkle:belowVersion></sparkle:informationalUpdate>
      <sparkle:releaseNotesLink>$RELEASE_PAGE</sparkle:releaseNotesLink>
      <enclosure
        url="$ENCLOSURE_URL"
        type="application/octet-stream"
        $SPARKLE_SIG_LINE />
    </item>
APPCAST
[ "$(item_build)" = "$BUILD_NUMBER" ] || { echo "✗ $ITEM_FILE does not carry build $BUILD_NUMBER" >&2; exit 1; }

DMG_SIZE=$(ls -lh "$DMG" | awk '{print $5}')
echo ""
echo "✅ Built, signed, notarized, stapled and Sparkle-signed: $DMG ($DMG_SIZE)"
echo "✅ Appcast item written to $ITEM_FILE (appcast.xml not modified yet)"
echo ""
echo "Next steps to publish:"
echo "  1. gh release create v$VERSION ./release/AzPim-$VERSION.dmg --title \"v$VERSION\" --notes-file release/release-notes-$VERSION.md"
echo "  2. ./Scripts/release.sh --publish-appcast $VERSION   # checks the DMG URL, prepends the item"
echo "  3. Commit appcast.xml on a branch and merge it through a PR (step 2 prints the commands)."
echo ""
echo "After step 3, Sparkle clients on older versions will be offered the update on next check."
