#!/usr/bin/env python3
"""Checks that every text the compiler extracted from the code is in its string catalog and
translated to English. Run after a build; the first argument is the DerivedData folder.

    scripts/check-localization.py build/ci/DerivedData
"""
import glob
import json
import sys

derived = sys.argv[1] if len(sys.argv) > 1 else "build/ci/DerivedData"
intermediates = f"{derived}/Build/Intermediates.noindex"
targets = [
    ("App", f"{intermediates}/NotifyAI.build/**/NotifyAI.build/**/*.stringsdata", "NotifyAI/Localizable.xcstrings"),
    ("Widget", f"{intermediates}/NotifyAI.build/**/NotifyAIWidgets.build/**/*.stringsdata", "NotifyAIWidgets/Localizable.xcstrings"),
    ("Services", f"{intermediates}/NotifyAIKit.build/**/NotifyAIServices*.build/**/*.stringsdata",
     "Packages/NotifyAIKit/Sources/NotifyAIServices/Resources/Localizable.xcstrings"),
]

problems = []
for name, pattern, catalog in targets:
    files = glob.glob(pattern, recursive=True)
    if not files:
        problems.append(f"{name}: no extracted strings found below {intermediates} (build first)")
        continue
    strings = json.load(open(catalog))["strings"]
    for path in files:
        data = json.load(open(path))
        source = data["source"].split("/")[-1]
        for entry in data["tables"].get("Localizable", []):
            key = entry["key"]
            item = strings.get(key)
            if item is None:
                problems.append(f"{name}: \"{key}\" ({source}) is missing in {catalog}")
                continue
            if item.get("shouldTranslate") is False:
                continue
            english = (item.get("localizations") or {}).get("en") or {}
            if not english.get("variations") and (english.get("stringUnit") or {}).get("state") != "translated":
                problems.append(f"{name}: \"{key}\" ({source}) has no English translation")

for problem in sorted(set(problems)):
    print(f"  {problem}")
if problems:
    sys.exit(1)
print("  every text is in its catalog and translated")
