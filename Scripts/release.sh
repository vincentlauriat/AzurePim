#!/usr/bin/env bash
# Build a universal Release AzurePim.app, sign it with Developer ID and Hardened
# Runtime, package it as a DMG, notarize and staple it, then sign it for Sparkle
# and write appcast.xml.
#
# +--------------------------------------------------------------------------+
# | SPARKLE SIGNING KEY: DO NOT REGENERATE                                     |
# |                                                                            |
# | Updates are EdDSA-signed with the private key in the login keychain under  |
# | account "AzurePim". Its public half is SUPublicEDKey in project.yml:       |
# |     oGxHAH0aXmMuHBG/E6/PsROoQPDhw3vicDP+FK1S4hA=                           |
# |                                                                            |
# | Never import a new key into this account and never change SUPublicEDKey:   |
# | every installed app would reject all future updates. Back it up with       |
# | `generate_keys -x <absolute path outside this repo> --account AzurePim`.   |
# +--------------------------------------------------------------------------+
#
# Usage: ./Scripts/release.sh <version>      e.g. ./Scripts/release.sh 0.9.0
# Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml first.
#
# Outputs release/AzurePim-<version>.dmg and appcast.xml.
# Does NOT publish: prints the `gh release create` command to run next.

set -euo pipefail

VERSION="${1:?Usage: ./Scripts/release.sh <version>  (e.g. ./Scripts/release.sh 0.3.0)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

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
xcodebuild -project AzurePim.xcodeproj \
  -scheme AzurePim \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tail -5

APP="$ROOT/build/Build/Products/Release/AzurePim.app"
if [ ! -d "$APP" ]; then
  echo "✗ Build did not produce $APP" >&2
  exit 1
fi

# The first shipped build must already carry a working updater: Sparkle cannot
# repair a missing feed or key later. Check what was built, not project.yml.
plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
[ "$(plist_value CFBundleShortVersionString)" = "$VERSION" ] || { echo "✗ built version is not $VERSION" >&2; exit 1; }
[ "$(plist_value SUFeedURL)" = "https://raw.githubusercontent.com/vincentlauriat/AzurePim/main/appcast.xml" ] || { echo "✗ unexpected SUFeedURL" >&2; exit 1; }
BUILT_ARCHS="$(lipo -archs "$APP/Contents/MacOS/AzurePim")"
case "$BUILT_ARCHS" in
  *x86_64*arm64*|*arm64*x86_64*) ;;
  *) echo "✗ not a universal binary: $BUILT_ARCHS" >&2; exit 1 ;;
esac

# 5. Stage to a clean directory, Developer ID sign with Hardened Runtime, package.
# Direct in-place codesign fails because Xcode's post-build `lsregister`
# adds `com.apple.provenance` xattrs, which `codesign --force` rejects with
# "resource fork, Finder information, or similar detritus not allowed".
# `ditto --noextattr` copies without xattrs and survives.
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Vincent LAURIAT (KFLACS69T9)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AppliMacVincentGithub}"

STAGING_DIR="$(mktemp -d)"
STAGING="$STAGING_DIR/AzurePim.app"
echo "→ Staging to $STAGING_DIR"
ditto --norsrc --noextattr --noacl "$APP" "$STAGING"

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
codesign_ts "$STAGING" --entitlements "$ROOT/AzurePim/AzurePim.entitlements"
codesign --verify --strict --deep "$STAGING"

RELEASE_DIR="$ROOT/release"
mkdir -p "$RELEASE_DIR"
DMG="$RELEASE_DIR/AzurePim-$VERSION.dmg"
rm -f "$DMG"

# 5b. Build the DMG with a custom Finder layout: signed .app on the left,
# /Applications alias on the right, background image with an arrow between them.
# dmgbuild writes the .DS_Store itself. The Finder AppleScript it replaces needs
# Apple Events, which some shells cannot send, and silently shipped DMGs without
# a layout (ClaudeCockpit 1.1.3 and 1.1.4).
DMG_VOLNAME="AzurePim $VERSION"
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
for ITEM in .DS_Store .background.png Applications AzurePim.app; do
  [ -e "$CHECK_MOUNT/$ITEM" ] || { echo "✗ DMG is missing $ITEM" >&2; LAYOUT_OK=0; }
done
codesign --verify --strict --deep "$CHECK_MOUNT/AzurePim.app" || LAYOUT_OK=0
detach_retry "$CHECK_MOUNT"
[ "$LAYOUT_OK" = 1 ] || exit 1

rm -rf "$STAGING_DIR"

# 6. Notarize the DMG with Apple, then staple the ticket so the app
# launches on machines without internet access.
echo "→ Submitting $DMG to Apple notary service (this takes 2–5 min)"
# `submit --wait` exits 0 even when Apple returns "Invalid": read the status.
NOTARY_JSON="$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)" || true
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
    xcrun notarytool log "$NOTARY_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
  fi
  exit 1
fi

echo "→ Stapling notarization ticket to the DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

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
KEYCHAIN_PUBKEY="$("$SPARKLE_TOOLS/bin/generate_keys" --account "AzurePim" -p)"
if [ "$KEYCHAIN_PUBKEY" != "$(plist_value SUPublicEDKey)" ]; then
  echo "✗ SUPublicEDKey in the app does not match the keychain key for account AzurePim" >&2
  exit 1
fi

echo "→ Signing $DMG with Sparkle EdDSA key"
# `sign_update` returns: sparkle:edSignature="..." length="<bytes>"
# (so we don't add `length=` ourselves on the <enclosure> — that would duplicate).
SPARKLE_SIG_LINE=$("$SPARKLE_TOOLS/bin/sign_update" --account "AzurePim" "$DMG")

# Sparkle compares <sparkle:version> against the running app's CFBundleVersion
# (a monotonically increasing build number), NOT against the marketing version.
# If we put "0.7.0" here while the installed app reports CFBundleVersion="1",
# Sparkle's standard comparator sees [0,7,0] < [1] and concludes "up to date".
# Read the actual CFBundleVersion baked into the .app and use that.
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")

echo "→ Writing $ROOT/appcast.xml (sparkle:version=$BUILD_NUMBER, shortVersionString=$VERSION)"
PUB_DATE=$(LC_ALL=C date -R)
cat > "$ROOT/appcast.xml" <<APPCAST
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>AzurePim</title>
    <link>https://raw.githubusercontent.com/vincentlauriat/AzurePim/main/appcast.xml</link>
    <description>AzurePim release feed</description>
    <language>en</language>
    <item>
      <title>v$VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/vincentlauriat/AzurePim/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure
        url="https://github.com/vincentlauriat/AzurePim/releases/download/v$VERSION/AzurePim-$VERSION.dmg"
        type="application/octet-stream"
        $SPARKLE_SIG_LINE />
    </item>
  </channel>
</rss>
APPCAST

DMG_SIZE=$(ls -lh "$DMG" | awk '{print $5}')
echo ""
echo "✅ Built, signed, notarized, stapled and Sparkle-signed: $DMG ($DMG_SIZE)"
echo "✅ appcast.xml written for v$VERSION"
echo ""
echo "Next steps to publish on GitHub:"
echo "  1. gh release create v$VERSION ./release/AzurePim-$VERSION.dmg --title \"v$VERSION\" --notes-file release/release-notes-$VERSION.md"
echo "  2. git add appcast.xml && git commit -m 'docs: appcast for v$VERSION' && git push"
echo ""
echo "After both, Sparkle clients on older versions will be offered the update on next check."
