#!/usr/bin/env bash
#
# Baut NotifyAI für iPhone und iPad und lädt den Build zu App Store Connect hoch.
#
#   scripts/release-ios.sh 1.0.0
#
# Danach erscheint der Build nach etwa 10–30 Minuten in App Store Connect unter TestFlight. Testen,
# Screenshots und Texte pflegen und zur Prüfung einreichen geschieht im Browser (docs/Publishing.md).
#
# Voraussetzungen: sauberer Git-Stand, App-Eintrag in App Store Connect mit der Bundle-ID com.justus.NotifyAI,
# angemeldeter Apple-Account in Xcode (Einstellungen → Accounts) oder ein App-Store-Connect-API-Schlüssel in
# ASC_KEY_PATH, ASC_KEY_ID und ASC_ISSUER_ID.

set -euo pipefail

usage() {
    sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

[[ $# -eq 1 ]] || usage
VERSION="$1"

fail() { echo "✗ $*" >&2; exit 1; }
step() { echo "▸ $*"; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Version muss die Form 1.2.3 haben, nicht „$VERSION“."

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT="build/release-ios"
ARCHIVE="$OUT/NotifyAI.xcarchive"
# Gleiche Build-Nummer wie das Mac-Release desselben Commits. App Store Connect verlangt pro Version steigende Nummern.
BUILD_NUMBER="$(git rev-list --count HEAD)"

XCODE_AUTH=()
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
    XCODE_AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "${ASC_KEY_ID:?ASC_KEY_ID fehlt}" -authenticationKeyIssuerID "${ASC_ISSUER_ID:?ASC_ISSUER_ID fehlt}")
fi

[[ -z "$(git status --porcelain)" ]] || fail "Es gibt nicht committete Änderungen. Bitte erst committen – der Build soll genau einem Commit entsprechen."

step "Baue NotifyAI $VERSION (Build $BUILD_NUMBER) für iOS …"
rm -rf "$OUT"
mkdir -p "$OUT"
xcodebuild archive \
    -project NotifyAI.xcodeproj -scheme NotifyAI \
    -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    -allowProvisioningUpdates ${XCODE_AUTH[@]+"${XCODE_AUTH[@]}"} \
    -quiet

step "Lade zu App Store Connect hoch …"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" -exportPath "$OUT/export" -exportOptionsPlist scripts/ExportOptions-iOS.plist \
    -allowProvisioningUpdates ${XCODE_AUTH[@]+"${XCODE_AUTH[@]}"} \
    || fail "Upload fehlgeschlagen. Häufigste Ursachen: Build-Nummer $BUILD_NUMBER schon hochgeladen (neuen Commit machen) oder App-Eintrag fehlt in App Store Connect."

echo
echo "✓ NotifyAI $VERSION (Build $BUILD_NUMBER) ist hochgeladen."
echo "  Nach der Verarbeitung bei Apple (meist 10–30 Minuten) erscheint er in App Store Connect unter TestFlight."
