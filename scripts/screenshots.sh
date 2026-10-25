#!/usr/bin/env bash
#
# Nimmt die App-Store-Screenshots auf: englische Oberfläche, englische Beispielnotizen,
# iPhone 6,9″ und iPad 13″, Statusleiste 9:41 mit vollem Akku.
#
#   scripts/screenshots.sh                 speichert nach ~/Downloads/NotifyAI-Screenshots
#   scripts/screenshots.sh ZIELORDNER
#
# Die Navigation steht in NotifyAIUITests/ScreenshotTests.swift, die Notizen in
# Packages/NotifyAIKit/Sources/NotifyAIServices/ScreenshotSampleData.swift (nur Debug-Builds).

set -euo pipefail

fail() { echo "✗ $*" >&2; exit 1; }
step() { echo "▸ $*"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEST="${1:-$HOME/Downloads/NotifyAI-Screenshots}"
OUT="build/screenshots"
# Gerätegrößen, die App Store Connect verlangt: 6,9″ (1320 × 2868) und 13″ (2064 × 2752).
DEVICES=("iPhone 17 Pro Max" "iPad Pro 13-inch (M5)")

# Die UDID des ersten verfügbaren Simulators mit diesem Namen.
udid() {
    xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if "iOS" in runtime:
        for device in devices:
            if device["name"] == name:
                print(device["udid"]); sys.exit(0)
sys.exit(1)' "$1"
}

rm -rf "$OUT"
mkdir -p "$OUT" "$DEST"

for name in "${DEVICES[@]}"; do
    id="$(udid "$name")" || fail "Simulator „$name“ fehlt. Xcode → Window → Devices and Simulators → + anlegen."
    step "$name: Simulator vorbereiten …"
    xcrun simctl boot "$id" 2>/dev/null || true
    xcrun simctl bootstatus "$id" -b >/dev/null
    xcrun simctl ui "$id" appearance light
    xcrun simctl status_bar "$id" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
        --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100

    step "$name: Screenshots aufnehmen …"
    result="$OUT/${name// /-}.xcresult"
    if ! TEST_RUNNER_NOTIFYAI_SCREENSHOTS=1 xcodebuild test \
        -project NotifyAI.xcodeproj -scheme NotifyAI \
        -destination "id=$id" \
        -derivedDataPath "$OUT/DerivedData" \
        -only-testing:NotifyAIUITests/ScreenshotTests \
        -resultBundlePath "$result" \
        > "$OUT/${name// /-}.log" 2>&1; then
        grep -E "error:|failed|✘" "$OUT/${name// /-}.log" | head -20 >&2 || true
        fail "UI-Test auf $name fehlgeschlagen. Log: $OUT/${name// /-}.log"
    fi
    xcrun simctl status_bar "$id" clear

    # Anhänge exportieren und nach ihrem Namen (z. B. iPhone-2-Summary) benennen.
    export_dir="$OUT/${name// /-}-attachments"
    xcrun xcresulttool export attachments --path "$result" --output-path "$export_dir" >/dev/null
    python3 - "$export_dir" "$DEST" <<'EOF'
import json, shutil, sys
source, dest = sys.argv[1], sys.argv[2]
count = 0
for test in json.load(open(f"{source}/manifest.json")):
    for attachment in test["attachments"]:
        name = attachment["suggestedHumanReadableName"].split("_")[0]
        shutil.copy(f"{source}/{attachment['exportedFileName']}", f"{dest}/{name}.png")
        count += 1
print(f"  {count} Screenshots")
EOF
done

echo
echo "✓ Screenshots liegen in $DEST"
