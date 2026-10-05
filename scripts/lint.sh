#!/usr/bin/env bash
#
# SwiftLint für NotifyAI (Regeln: .swiftlint.yml).
#
#   scripts/lint.sh                    ganzes Projekt prüfen (so wie die CI)
#   scripts/lint.sh --fix              automatisch behebbare Verstöße im ganzen Projekt korrigieren
#   scripts/lint.sh DATEI …            nur diese Dateien prüfen (nutzt der pre-commit-Hook)
#
# Jeder Verstoß ist ein Fehler, auch Warnungen. Es gibt keine Liste geduldeter Altverstöße.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

# Der Runner und Git-Hooks starten oft ohne Homebrew im PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v swiftlint >/dev/null || { echo "✗ SwiftLint fehlt: brew install swiftlint" >&2; exit 1; }

case "${1:-}" in
    --fix)
        swiftlint lint --fix --quiet
        echo "✓ Automatische Korrekturen angewendet. Bitte den Diff prüfen und danach scripts/lint.sh ausführen."
        ;;
    "")
        swiftlint lint --quiet --strict
        echo "✓ SwiftLint: keine Verstöße."
        ;;
    -*)
        sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
    *)
        # --force-exclude: auch einzeln übergebene Dateien respektieren excluded aus .swiftlint.yml.
        swiftlint lint --quiet --strict --force-exclude -- "$@"
        ;;
esac
