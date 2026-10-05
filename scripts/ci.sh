#!/usr/bin/env bash
#
# Prüft NotifyAI so, wie es die CI tut. Läuft lokal genauso wie auf dem GitHub-Runner.
#
#   scripts/ci.sh              alles: lint, package, macos, ios
#   scripts/ci.sh lint macos   nur die genannten Schritte, in dieser Reihenfolge
#
# Schritte:
#   lint      SwiftLint (neue Verstöße sind Fehler, siehe .swiftlint.yml)
#   package   Tests des lokalen Pakets Packages/NotifyAIKit (swift test)
#   macos     App bauen und NotifyAITests auf dem Mac ausführen
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
[[ ${#STEPS[@]} -gt 0 ]] || STEPS=(lint package macos ios)
for s in "${STEPS[@]}"; do
    case "$s" in
        lint|package|macos|ios) ;;
        *) sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'; fail "Unbekannter Schritt: $s" ;;
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
        package) package_tests ;;
        macos) macos_tests ;;
        ios) ios_build ;;
    esac
done
echo
echo "✓ CI erfolgreich (${STEPS[*]}) in $((SECONDS - START)) s."
