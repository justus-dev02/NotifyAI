#!/usr/bin/env bash
#
# Aktiviert die Git-Hooks aus .githooks/ für diesen Klon (einmalig nach dem Klonen ausführen).
#
#   pre-commit   SwiftLint für die Swift-Dateien des Commits
#   pre-push     SwiftLint und die Paket-Tests
#
# Rückgängig: git config --unset core.hooksPath

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"
chmod +x .githooks/*
git config core.hooksPath .githooks
echo "✓ Git-Hooks aktiv (core.hooksPath = .githooks)."
command -v swiftlint >/dev/null || [[ -x /opt/homebrew/bin/swiftlint ]] \
    || echo "! SwiftLint fehlt noch: brew install swiftlint"
