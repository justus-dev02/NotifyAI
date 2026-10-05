#!/usr/bin/env bash
#
# SwiftLint für NotifyAI (Regeln: .swiftlint.yml).
#
#   scripts/lint.sh                    ganzes Projekt prüfen (so wie die CI)
#   scripts/lint.sh --fix              automatisch behebbare Verstöße im ganzen Projekt korrigieren
#   scripts/lint.sh DATEI …            nur diese Dateien prüfen (nutzt der pre-commit-Hook)
#   scripts/lint.sh --update-baseline  alle heutigen Verstöße als „bekannt“ speichern
#
# Verstöße aus .swiftlint-baseline.json werden ignoriert. Alles andere ist ein Fehler, auch Warnungen.
# --update-baseline nur bewusst verwenden, etwa nachdem du Regeln geändert hast. Sonst wächst die
# Liste der geduldeten Verstöße unbemerkt.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"
BASELINE=".swiftlint-baseline.json"

# Der Runner und Git-Hooks starten oft ohne Homebrew im PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v swiftlint >/dev/null || { echo "✗ SwiftLint fehlt: brew install swiftlint" >&2; exit 1; }

case "${1:-}" in
    --fix)
        swiftlint lint --fix --quiet
        echo "✓ Automatische Korrekturen angewendet. Bitte den Diff prüfen und danach scripts/lint.sh ausführen."
        ;;
    --update-baseline)
        swiftlint lint --quiet --write-baseline "$BASELINE" >/dev/null || true
        echo "✓ $BASELINE aktualisiert."
        ;;
    "")
        swiftlint lint --quiet --strict --baseline "$BASELINE"
        echo "✓ SwiftLint: keine neuen Verstöße."
        ;;
    -*)
        sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
    *)
        # --force-exclude: auch einzeln übergebene Dateien respektieren excluded aus .swiftlint.yml.
        swiftlint lint --quiet --strict --baseline "$BASELINE" --force-exclude -- "$@"
        ;;
esac
