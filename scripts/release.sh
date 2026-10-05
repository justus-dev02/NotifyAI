#!/usr/bin/env bash
#
# Baut ein Release von NotifyAI für macOS und trägt es in den Update-Feed (appcast.xml) ein.
#
#   scripts/release.sh 0.2.0              bauen, ZIP signieren, appcast.xml ergänzen
#   scripts/release.sh 0.2.0 --publish    zusätzlich Tag, GitHub-Release und appcast.xml pushen (braucht `gh`)
#
# Optionen:
#   --ed-key-file DATEI   privaten Sparkle-Schlüssel aus einer Datei statt aus dem Schlüsselbund lesen (z. B. für CI)
#
# Voraussetzungen: sauberer Git-Stand, release-notes/<version>.md, SUPublicEDKey in NotifyAI-macOS-Info.plist.
# Die App wird ad-hoc signiert (ohne Developer ID). Für Updates zählt die EdDSA-Signatur von Sparkle.

set -euo pipefail

usage() {
    sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

[[ $# -ge 1 ]] || usage
VERSION="$1"; shift
PUBLISH=0
KEY_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --publish) PUBLISH=1 ;;
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
ZIP="$OUT/NotifyAI-$VERSION.zip"

# github.com/<owner>/<repo> aus dem Remote, egal ob HTTPS oder SSH.
REPO_URL="$(git remote get-url origin | sed -E 's#^git@github\.com:#https://github.com/#; s#\.git$##')"
[[ "$REPO_URL" == https://github.com/* ]] || fail "Remote „origin“ zeigt nicht auf GitHub: $REPO_URL"
DOWNLOAD_URL="$REPO_URL/releases/download/$TAG/NotifyAI-$VERSION.zip"

# Sparkle vergleicht die Build-Nummer. Die Anzahl der Commits steigt mit jedem Release.
BUILD_NUMBER="$(git rev-list --count HEAD)"

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

# --- Bauen --------------------------------------------------------------------

step "Baue NotifyAI $VERSION (Build $BUILD_NUMBER) …"
rm -rf "$OUT"
mkdir -p "$OUT"
xcodebuild \
    -project NotifyAI.xcodeproj -scheme NotifyAI \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    NOTIFYAI_MACOS_ENTITLEMENTS=NotifyAI-macOS-AdHoc.entitlements \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    -quiet build

APP="$DERIVED/Build/Products/Release/NotifyAI.app"
codesign --verify --deep --strict "$APP" || fail "Code-Signatur der App ist ungültig."
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "disable-library-validation" \
    || fail "Ad-hoc-Entitlements fehlen – die App könnte Sparkle.framework nicht laden."
BUILT_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")"
[[ "$BUILT_KEY" == "$PUBLIC_KEY" ]] || fail "Die gebaute App enthält einen anderen SUPublicEDKey."
MIN_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"

# --- Verpacken und für Sparkle signieren --------------------------------------

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
echo
echo "✓ NotifyAI $VERSION (Build $BUILD_NUMBER) ist gebaut."
echo "  Archiv:  $ZIP"
echo "  SHA-256: $SHA256"
echo

# --- Veröffentlichen ----------------------------------------------------------
# Reihenfolge ist wichtig: Erst muss das ZIP auf GitHub liegen, dann wird appcast.xml gepusht.
# Sonst findet die App ein Update, dessen Download noch nicht existiert.

if [[ $PUBLISH -eq 1 ]]; then
    step "Erzeuge Tag $TAG und GitHub-Release …"
    git tag "$TAG"
    git push origin "$TAG"
    {
        cat "$NOTES"
        # shellcheck disable=SC2016 # Backticks sind Markdown, keine Befehlsersetzung.
        printf '\n---\nSHA-256 (`NotifyAI-%s.zip`): `%s`\n' "$VERSION" "$SHA256"
    } > "$OUT/release-notes.md"
    gh release create "$TAG" "$ZIP" --verify-tag --title "NotifyAI $VERSION" --notes-file "$OUT/release-notes.md"

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
     $ZIP hochladen, Text aus $NOTES einfügen, veröffentlichen.
  3. git add $APPCAST && git commit -m "Release $VERSION: Update-Feed" && git push
Oder alles auf einmal: scripts/release.sh $VERSION --publish
(Zum Verwerfen: git checkout -- $APPCAST)
EOF
fi
