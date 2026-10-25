#!/usr/bin/env bash
#
# Baut ein Release von NotifyAI für macOS (Download von der Website) und trägt es in den Update-Feed ein.
#
#   scripts/release.sh 0.2.0              bauen, signieren, notarisieren, ZIP + DMG, appcast.xml ergänzen
#   scripts/release.sh 0.2.0 --publish    zusätzlich Tag, GitHub-Release und appcast.xml pushen (braucht `gh`)
#   scripts/release.sh 0.2.0 --check      nur die Voraussetzungen prüfen, nichts bauen (Sekunden statt Minuten)
#
# Optionen:
#   --ed-key-file DATEI   privaten Sparkle-Schlüssel aus einer Datei statt aus dem Schlüsselbund lesen (z. B. für CI)
#
# Voraussetzungen: sauberer Git-Stand, release-notes/<version>.md, SUPublicEDKey in NotifyAI-macOS-Info.plist,
# Developer-ID-Zertifikat, Notarisierungs-Zugang (siehe docs/Publishing.md). Anmeldung bei Apple entweder über
# das Schlüsselbund-Profil NOTARY_PROFILE (Standard: NotifyAI-Notary) oder über einen App-Store-Connect-API-Schlüssel
# in ASC_KEY_PATH, ASC_KEY_ID und ASC_ISSUER_ID.

set -euo pipefail

usage() {
    sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

[[ $# -ge 1 ]] || usage
VERSION="$1"; shift
PUBLISH=0
CHECK_ONLY=0
KEY_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --publish) PUBLISH=1 ;;
        --check) CHECK_ONLY=1 ;;
        --ed-key-file) KEY_FILE="${2:?--ed-key-file braucht einen Pfad}"; shift ;;
        *) usage ;;
    esac
    shift
done

fail() { echo "✗ $*" >&2; exit 1; }
step() { echo "▸ $*"; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Version muss die Form 1.2.3 haben, nicht „$VERSION“."

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TAG="v$VERSION"
APPCAST="appcast.xml"
NOTES="release-notes/$VERSION.md"
INFO_PLIST="NotifyAI-macOS-Info.plist"
OUT="build/release"
DERIVED="$OUT/DerivedData"
ARCHIVE="$OUT/NotifyAI.xcarchive"
EXPORT="$OUT/export"
ZIP="$OUT/NotifyAI-$VERSION.zip"
DMG="$OUT/NotifyAI-$VERSION.dmg"
# Fester Name für den Download-Link der Website: …/releases/latest/download/NotifyAI.dmg
DMG_LATEST="$OUT/NotifyAI.dmg"
EXPORT_OPTIONS="scripts/ExportOptions-macOS.plist"
TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :teamID' "$EXPORT_OPTIONS")"

# github.com/<owner>/<repo> aus dem Remote, egal ob HTTPS oder SSH.
REPO_URL="$(git remote get-url origin | sed -E 's#^git@github\.com:#https://github.com/#; s#\.git$##')"
[[ "$REPO_URL" == https://github.com/* ]] || fail "Remote „origin“ zeigt nicht auf GitHub: $REPO_URL"
DOWNLOAD_URL="$REPO_URL/releases/download/$TAG/NotifyAI-$VERSION.zip"

# Sparkle vergleicht die Build-Nummer. Die Anzahl der Commits steigt mit jedem Release.
BUILD_NUMBER="$(git rev-list --count HEAD)"

# Anmeldung bei Apple: API-Schlüssel (z. B. CI) oder Schlüsselbund-Profil von `notarytool store-credentials`.
XCODE_AUTH=()
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
    XCODE_AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "${ASC_KEY_ID:?ASC_KEY_ID fehlt}" -authenticationKeyIssuerID "${ASC_ISSUER_ID:?ASC_ISSUER_ID fehlt}")
    NOTARY_AUTH=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
else
    NOTARY_AUTH=(--keychain-profile "${NOTARY_PROFILE:-NotifyAI-Notary}")
fi

# --- Prüfungen ----------------------------------------------------------------

[[ -z "$(git status --porcelain)" ]] || fail "Es gibt nicht committete Änderungen. Bitte erst committen – das Release soll genau einem Commit entsprechen."
! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "Tag $TAG existiert bereits."
[[ -f "$NOTES" ]] || fail "$NOTES fehlt. Lege die Release-Notes an (siehe release-notes/README.md)."
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO_PLIST" 2>/dev/null || true)"
[[ -n "$PUBLIC_KEY" ]] || fail "SUPublicEDKey in $INFO_PLIST ist leer. Einmalig: generate_keys ausführen und den öffentlichen Schlüssel eintragen."
! grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST" || fail "Version $VERSION steht schon in $APPCAST."
grep -q "<!-- NEW-RELEASES -->" "$APPCAST" || fail "Markierung <!-- NEW-RELEASES --> fehlt in $APPCAST."
if [[ $PUBLISH -eq 1 ]]; then
    command -v gh >/dev/null || fail "--publish braucht die GitHub CLI: brew install gh && gh auth login"
fi
# Früh prüfen, nicht erst nach zehn Minuten Build.
xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null 2>&1 \
    || fail "Anmeldung für die Notarisierung fehlgeschlagen. Einmalig: xcrun notarytool store-credentials NotifyAI-Notary (siehe docs/Publishing.md)."

# Ohne API-Schlüssel signiert xcodebuild mit dem Zertifikat aus dem Schlüsselbund. Mit API-Schlüssel kann
# Xcode ein von Apple verwaltetes Zertifikat nutzen (Cloud Signing), dann ist keins im Schlüsselbund nötig.
if [[ -z "${ASC_KEY_PATH:-}" ]] && ! security find-identity -v -p codesigning | grep -q "Developer ID Application: .*($TEAM_ID)"; then
    fail "Kein „Developer ID Application“-Zertifikat für Team $TEAM_ID im Schlüsselbund (siehe docs/Publishing.md, 1.1)."
fi
if [[ -n "$KEY_FILE" ]]; then
    [[ -s "$KEY_FILE" ]] || fail "--ed-key-file $KEY_FILE ist leer oder fehlt."
fi
if [[ $CHECK_ONLY -eq 1 ]]; then
    echo "✓ Alle Voraussetzungen für NotifyAI $VERSION (macOS) sind erfüllt."
    exit 0
fi

# Reicht eine Datei zur Notarisierung ein und wartet auf Apples Ergebnis. Bei Ablehnung steht der Grund im Log.
notarize() {
    local file="$1" result status id
    step "Notarisiere $(basename "$file") (dauert meist 1–5 Minuten) …"
    result="$(xcrun notarytool submit "$file" "${NOTARY_AUTH[@]}" --wait --output-format json)" \
        || fail "notarytool submit ist fehlgeschlagen: $result"
    status="$(plutil -extract status raw -o - - <<<"$result")"
    id="$(plutil -extract id raw -o - - <<<"$result")"
    if [[ "$status" != "Accepted" ]]; then
        xcrun notarytool log "$id" "${NOTARY_AUTH[@]}" >&2 || true
        fail "Apple hat $(basename "$file") nicht notarisiert (Status: $status). Details stehen oben."
    fi
}

# --- Bauen und mit Developer ID signieren -------------------------------------

step "Baue NotifyAI $VERSION (Build $BUILD_NUMBER) …"
rm -rf "$OUT"
mkdir -p "$OUT"
xcodebuild archive \
    -project NotifyAI.xcodeproj -scheme NotifyAI \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED" -archivePath "$ARCHIVE" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    -allowProvisioningUpdates ${XCODE_AUTH[@]+"${XCODE_AUTH[@]}"} \
    -quiet

step "Exportiere mit Developer ID …"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" -exportPath "$EXPORT" -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates ${XCODE_AUTH[@]+"${XCODE_AUTH[@]}"} \
    -quiet

APP="$EXPORT/NotifyAI.app"
codesign --verify --deep --strict "$APP" || fail "Code-Signatur der App ist ungültig."
SIGNATURE_INFO="$(codesign -dv --verbose=2 "$APP" 2>&1)"
[[ "$SIGNATURE_INFO" == *"TeamIdentifier=$TEAM_ID"* ]] || fail "Die App ist nicht mit Team $TEAM_ID signiert."
[[ "$SIGNATURE_INFO" =~ flags=0x[0-9a-f]+\([^\)]*runtime ]] || fail "Hardened Runtime fehlt – Apple würde nicht notarisieren."
SIGN_IDENTITY="$(sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' <<<"$SIGNATURE_INFO" | head -1)"
[[ -n "$SIGN_IDENTITY" ]] || fail "Die App ist nicht mit einem „Developer ID Application“-Zertifikat signiert."
BUILT_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")"
[[ "$BUILT_KEY" == "$PUBLIC_KEY" ]] || fail "Die gebaute App enthält einen anderen SUPublicEDKey."
MIN_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"

# --- Notarisieren -------------------------------------------------------------

ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
notarize "$OUT/notarize.zip"
rm "$OUT/notarize.zip"
xcrun stapler staple -q "$APP"
spctl --assess --type execute "$APP" || fail "Gatekeeper lehnt die notarisierte App ab."

# --- Disk-Image für den Download von der Website -------------------------------

step "Erzeuge $DMG …"
mkdir -p "$OUT/dmg"
ditto "$APP" "$OUT/dmg/NotifyAI.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -volname "NotifyAI" -srcfolder "$OUT/dmg" -fs HFS+ -format UDZO -ov -quiet "$DMG"
rm -rf "$OUT/dmg"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple -q "$DMG"
spctl --assess --type open --context context:primary-signature "$DMG" || fail "Gatekeeper lehnt das DMG ab."
cp "$DMG" "$DMG_LATEST"

# --- Verpacken und für Sparkle signieren --------------------------------------

# Sparkle lädt Updates als ZIP: In einer Sandbox-App ist das zuverlässiger als ein DMG.
step "Packe $ZIP …"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

SIGN_UPDATE="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "$SIGN_UPDATE" ]] || fail "sign_update nicht gefunden: $SIGN_UPDATE"
step "Signiere das Update (EdDSA) …"
if [[ -n "$KEY_FILE" ]]; then
    SIGNATURE_ATTRIBUTES="$("$SIGN_UPDATE" --ed-key-file "$KEY_FILE" "$ZIP")"
else
    SIGNATURE_ATTRIBUTES="$("$SIGN_UPDATE" "$ZIP")"
fi
[[ "$SIGNATURE_ATTRIBUTES" == *'sparkle:edSignature="'*'length="'* ]] || fail "Unerwartete Ausgabe von sign_update: $SIGNATURE_ATTRIBUTES"

# --- appcast.xml ergänzen -----------------------------------------------------

# Release-Notes: ## Überschrift → <h3>, - Punkt → <li>, sonst <p>. HTML-Zeichen werden maskiert.
NOTES_HTML="$(awk '
    function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
    function close_list() { if (in_list) { print "</ul>"; in_list = 0 } }
    /^[[:space:]]*$/ { close_list(); next }
    /^#+ / { close_list(); sub(/^#+ /, ""); print "<h3>" esc($0) "</h3>"; next }
    /^[-*] / { if (!in_list) { print "<ul>"; in_list = 1 } sub(/^[-*] /, ""); print "<li>" esc($0) "</li>"; next }
    { close_list(); print "<p>" esc($0) "</p>" }
    END { close_list() }
' "$NOTES")"

PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
ITEM_FILE="$OUT/appcast-item.xml"
cat > "$ITEM_FILE" <<EOF
    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <link>$REPO_URL/releases/tag/$TAG</link>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM</sparkle:minimumSystemVersion>
      <description><![CDATA[
$NOTES_HTML
      ]]></description>
      <enclosure url="$DOWNLOAD_URL" type="application/octet-stream" $SIGNATURE_ATTRIBUTES/>
    </item>
EOF

step "Trage Version $VERSION in $APPCAST ein …"
awk -v item="$ITEM_FILE" '
    { print }
    /<!-- NEW-RELEASES -->/ { while ((getline line < item) > 0) print line }
' "$APPCAST" > "$OUT/appcast.xml"
xmllint --noout "$OUT/appcast.xml" || fail "Die neue appcast.xml ist kein gültiges XML."
cp "$OUT/appcast.xml" "$APPCAST"

SHA256="$(shasum -a 256 "$ZIP" | cut -d ' ' -f 1)"
DMG_SHA256="$(shasum -a 256 "$DMG" | cut -d ' ' -f 1)"
echo
echo "✓ NotifyAI $VERSION (Build $BUILD_NUMBER) ist gebaut, signiert und notarisiert."
echo "  Download: $DMG  (SHA-256 $DMG_SHA256)"
echo "  Update:   $ZIP  (SHA-256 $SHA256)"
echo

# --- Veröffentlichen ----------------------------------------------------------
# Reihenfolge ist wichtig: Erst müssen ZIP und DMG auf GitHub liegen, dann wird appcast.xml gepusht.
# Sonst findet die App ein Update, dessen Download noch nicht existiert.

if [[ $PUBLISH -eq 1 ]]; then
    step "Erzeuge Tag $TAG und GitHub-Release …"
    git tag "$TAG"
    git push origin "$TAG"
    {
        cat "$NOTES"
        # shellcheck disable=SC2016 # Backticks sind Markdown, keine Befehlsersetzung.
        printf '\n---\nSHA-256 (`NotifyAI-%s.dmg`): `%s`  \n' "$VERSION" "$DMG_SHA256"
        # shellcheck disable=SC2016
        printf 'SHA-256 (`NotifyAI-%s.zip`): `%s`\n' "$VERSION" "$SHA256"
    } > "$OUT/release-notes.md"
    gh release create "$TAG" "$DMG" "$DMG_LATEST" "$ZIP" --latest --verify-tag --title "NotifyAI $VERSION" --notes-file "$OUT/release-notes.md"

    step "Veröffentliche den Update-Feed …"
    git add "$APPCAST"
    git commit -m "Release $VERSION: Update-Feed"
    git push origin HEAD
    echo
    echo "✓ Veröffentlicht. Installierte Apps finden das Update bei der nächsten Prüfung."
else
    cat <<EOF
Nächste Schritte (in dieser Reihenfolge):
  1. git tag $TAG && git push origin $TAG
  2. Auf GitHub: Releases → Draft a new release → Tag $TAG
     $DMG, $DMG_LATEST und $ZIP hochladen, Text aus $NOTES einfügen,
     als „Latest release“ veröffentlichen (die Website verlinkt …/releases/latest/download/NotifyAI.dmg).
  3. git add $APPCAST && git commit -m "Release $VERSION: Update-Feed" && git push
Oder alles auf einmal: scripts/release.sh $VERSION --publish
(Zum Verwerfen: git checkout -- $APPCAST)
EOF
fi
