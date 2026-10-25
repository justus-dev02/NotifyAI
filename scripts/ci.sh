#!/usr/bin/env bash
#
# Prüft NotifyAI so, wie es die CI tut. Läuft lokal genauso wie auf dem GitHub-Runner.
#
#   scripts/ci.sh              alles: lint, dist, package, macos, ui, ios
#   scripts/ci.sh lint macos   nur die genannten Schritte, in dieser Reihenfolge
#
# Schritte:
#   lint      SwiftLint (neue Verstöße sind Fehler, siehe .swiftlint.yml)
#   dist      Veröffentlichung: Plists, Entitlements, App-Icons, Export-Optionen, Website
#   package   Tests des lokalen Pakets Packages/NotifyAIKit (swift test)
#   macos     App bauen und NotifyAITests auf dem Mac ausführen
#   ui        NotifyAIUITests auf dem Mac ausführen (Abläufe und Barrierefreiheits-Audits)
#   ios       App für den iOS-Simulator bauen (ohne Tests)
#
# Umgebungsvariablen:
#   CI_DERIVED_DATA   Ort für DerivedData (Standard: build/ci/DerivedData). Auf dem Runner liegt es
#                     außerhalb des Checkouts, damit der Build-Cache zwischen Läufen erhalten bleibt.
#
# macOS-Tests werden ad-hoc signiert: Der Test-Target hat kein Team, die App schon. Mit Team-Signatur
# lehnt die Hardened Runtime das Test-Bundle ab („different Team IDs“). Ad-hoc braucht außerdem
# kein Zertifikat im Schlüsselbund.

set -euo pipefail

fail() { echo "✗ $*" >&2; exit 1; }
step() { echo; echo "▸ $*"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

# Der Runner und Git-Hooks (z. B. aus Xcode oder einem Git-Client) starten oft ohne Homebrew im PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

OUT="$ROOT/build/ci"
DERIVED="${CI_DERIVED_DATA:-$OUT/DerivedData}"
mkdir -p "$OUT"

STEPS=("$@")
[[ ${#STEPS[@]} -gt 0 ]] || STEPS=(lint dist package macos ui ios)
for s in "${STEPS[@]}"; do
    case "$s" in
        lint|dist|package|macos|ui|ios) ;;
        *) sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; fail "Unbekannter Schritt: $s" ;;
    esac
done

XCODEBUILD_COMMON=(
    -project NotifyAI.xcodeproj -scheme NotifyAI
    -derivedDataPath "$DERIVED"
    # Nur die Versionen aus Package.resolved verwenden. Weicht die Datei ab, schlägt der Build fehl,
    # statt still andere Abhängigkeiten zu laden.
    -disableAutomaticPackageResolution
)

# xcodebuild schreibt das volle Log in eine Datei. Bei einem Fehler werden die Fehlerzeilen und das
# Ende des Logs gezeigt. Warnungen im eigenen Code (nicht in Abhängigkeiten) gelten als Fehler.
run_xcodebuild() {
    local name="$1"; shift
    local log="$OUT/$name.log"
    if ! xcodebuild "$@" > "$log" 2>&1; then
        grep -E "error:|✘|failed" "$log" | grep -v "^note:" | sort -u | head -40 >&2 || true
        echo "… Ende des Logs:" >&2
        tail -25 "$log" >&2
        fail "xcodebuild ($name) ist fehlgeschlagen. Volles Log: $log"
    fi
    local warnings
    warnings="$(grep -E "^$ROOT/[^:]+:[0-9]+:[0-9]+: warning:" "$log" | grep -v "/SourcePackages/" | sort -u || true)"
    if [[ -n "$warnings" ]]; then
        echo "$warnings" >&2
        fail "Compiler-Warnungen im eigenen Code ($name). Bitte beheben."
    fi
}

lint() {
    step "SwiftLint"
    "$ROOT/scripts/lint.sh"

    step "ShellCheck (scripts/, .githooks/) und actionlint (.github/workflows/)"
    command -v shellcheck >/dev/null || fail "ShellCheck fehlt: brew install shellcheck"
    command -v actionlint >/dev/null || fail "actionlint fehlt: brew install actionlint"
    shellcheck scripts/*.sh .githooks/*
    actionlint
    # Öffentliches Repo, self-hosted Runner: Pull Requests aus Forks dürfen nie Code auf dem Mac ausführen.
    if grep -nE '^\s*pull_request(_target)?\s*:|^\s*on:.*pull_request|^\s*-\s*pull_request' .github/workflows/*.yml; then
        fail "Workflows dürfen nicht auf pull_request reagieren (siehe docs/CI.md, 1.5)."
    fi
    echo "  ok"
}

# Was der App Store, die Notarisierung oder die Website sonst erst beim Release bemängeln würden.
dist_checks() {
    step "Veröffentlichung: Plists, App-Icons, Export-Optionen, Website"
    local f
    for f in NotifyAI-Info.plist NotifyAI-macOS-Info.plist NotifyAIWidgets-Info.plist NotifyAI-macOS.entitlements \
             NotifyAI/PrivacyInfo.xcprivacy NotifyAIWidgets/PrivacyInfo.xcprivacy scripts/ExportOptions-*.plist; do
        plutil -lint -s "$f" || fail "$f ist keine gültige Plist."
    done

    [[ "$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' NotifyAI-Info.plist 2>/dev/null)" == false ]] \
        || fail "ITSAppUsesNonExemptEncryption fehlt in NotifyAI-Info.plist – App Store Connect würde jeden Build anhalten."

    # Das Team in den Export-Optionen muss das Team der App sein, sonst scheitert der Export erst nach dem Build.
    local team
    for f in scripts/ExportOptions-*.plist; do
        team="$(/usr/libexec/PlistBuddy -c 'Print :teamID' "$f")"
        grep -q "DEVELOPMENT_TEAM = $team;" NotifyAI.xcodeproj/project.pbxproj \
            || fail "$f nennt Team $team, das Projekt nutzt ein anderes DEVELOPMENT_TEAM."
    done

    # Die Lizenz in der App (Einstellungen → Lizenzen) ist dieselbe wie die des Repos.
    cmp -s LICENSE NotifyAI/Licenses/License-NotifyAI.txt \
        || fail "NotifyAI/Licenses/License-NotifyAI.txt weicht von LICENSE ab – bitte LICENSE dorthin kopieren."

    # App-Icons: iOS braucht 1024 × 1024 ohne Transparenz, macOS alle Größen aus Contents.json.
    python3 - NotifyAI/Assets.xcassets/AppIcon.appiconset <<'EOF' || fail "App-Icon unvollständig (siehe oben)."
import json, subprocess, sys
folder = sys.argv[1]
def info(name):
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "hasAlpha", f"{folder}/{name}"],
                         capture_output=True, text=True, check=True).stdout
    return {k.strip(): v.strip() for k, v in (l.split(":", 1) for l in out.splitlines()[1:])}
errors, platforms = [], set()
for image in json.load(open(f"{folder}/Contents.json"))["images"]:
    name = image.get("filename")
    if not name:
        continue
    platforms.add(image.get("platform", image["idiom"]))
    pixels = round(float(image["size"].split("x")[0]) * int(image.get("scale", "1x")[0]))
    i = info(name)
    if (int(i["pixelWidth"]), int(i["pixelHeight"])) != (pixels, pixels):
        errors.append(f"{name}: {i['pixelWidth']}×{i['pixelHeight']}, erwartet {pixels}×{pixels}")
    if image.get("platform") == "ios" and i["hasAlpha"] == "yes":
        errors.append(f"{name}: iOS-Icons dürfen keine Transparenz haben")
for needed in ("ios", "mac"):
    if needed not in platforms:
        errors.append(f"kein Icon für {needed}")
print("\n".join(errors), file=sys.stderr)
sys.exit(1 if errors else 0)
EOF

    # Website: jede lokal verlinkte Datei existiert.
    local ref missing=0
    for f in website/*.html; do
        while read -r ref; do
            [[ -e "website/${ref%%#*}" ]] || { echo "  $f verweist auf fehlende Datei: $ref" >&2; missing=1; }
        done < <(grep -oE '(href|src)="[^"]+"' "$f" | sed -E 's/^(href|src)="//; s/"$//' | grep -vE '^#|:|/$' || true)
    done
    [[ $missing -eq 0 ]] || fail "Website enthält tote Links."
    if grep -qE "BITTE AUSFÜLLEN|BITTE-AUSFUELLEN" website/*.html; then
        echo "  Hinweis: website/ enthält noch Platzhalter (BITTE AUSFÜLLEN). Die Website wird erst veröffentlicht, wenn sie ersetzt sind."
    fi
    echo "  ok"
}

package_tests() {
    step "Tests: Packages/NotifyAIKit"
    local log="$OUT/package-test.log"
    if ! swift test --package-path Packages/NotifyAIKit --scratch-path "$OUT/package-build" > "$log" 2>&1; then
        grep -E "error:|✘|failed" "$log" | head -40 >&2 || true
        fail "swift test ist fehlgeschlagen. Volles Log: $log"
    fi
    grep -E "Test run with|Executed [1-9][0-9]* tests" "$log" | sed 's/^[^A-Za-z]*/  /' || true
}

macos_tests() {
    step "Tests: NotifyAITests auf macOS"
    local result="$OUT/NotifyAITests-macOS.xcresult"
    rm -rf "$result"
    run_xcodebuild macos-test test \
        "${XCODEBUILD_COMMON[@]}" \
        -testPlan NotifyAI \
        -destination 'platform=macOS' \
        -only-testing:NotifyAITests \
        -resultBundlePath "$result" \
        CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
    xcrun xcresulttool get test-results summary --path "$result" 2>/dev/null \
        | python3 -c 'import json,sys; s=json.load(sys.stdin); print("  %d bestanden, %d fehlgeschlagen, %d übersprungen" % (s["passedTests"], s["failedTests"], s["skippedTests"]))' \
        || true
    echo "  Ergebnis: $result"

    step "Übersetzungen: jeder Text im Katalog und ins Englische übersetzt"
    python3 "$ROOT/scripts/check-localization.py" "$DERIVED" || fail "Texte ohne Katalogeintrag oder Übersetzung (siehe oben)."
}

ui_tests() {
    step "Tests: NotifyAIUITests auf macOS"
    local result="$OUT/NotifyAIUITests-macOS.xcresult"
    rm -rf "$result"
    run_xcodebuild macos-ui-test test \
        "${XCODEBUILD_COMMON[@]}" \
        -testPlan NotifyAI \
        -destination 'platform=macOS' \
        -only-testing:NotifyAIUITests \
        -resultBundlePath "$result" \
        CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
    echo "  Ergebnis: $result"
}

ios_build() {
    step "Build: iOS-Simulator"
    run_xcodebuild ios-build build \
        "${XCODEBUILD_COMMON[@]}" \
        -destination 'generic/platform=iOS Simulator' \
        CODE_SIGNING_ALLOWED=NO
    echo "  ok"
}

START=$SECONDS
for s in "${STEPS[@]}"; do
    case "$s" in
        lint) lint ;;
        dist) dist_checks ;;
        package) package_tests ;;
        macos) macos_tests ;;
        ui) ui_tests ;;
        ios) ios_build ;;
    esac
done
echo
echo "✓ CI erfolgreich (${STEPS[*]}) in $((SECONDS - START)) s."
