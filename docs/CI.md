# CI/CD für NotifyAI

Alles läuft **auf deinem eigenen Mac** und kostet nichts. GitHub verteilt nur die Aufträge. Gebaut
und getestet wird ausschließlich auf dem self-hosted Runner. Einzige Ausnahme ist die Website: Sie
besteht nur aus statischen Dateien und wird auf einer GitHub-Maschine veröffentlicht, was für
öffentliche Repositories nichts kostet.

| Wann | Was läuft | Wo |
|---|---|---|
| `git commit` | SwiftLint für die Swift-Dateien des Commits | Hook `.githooks/pre-commit` |
| `git push` | SwiftLint, ShellCheck, actionlint, Paket-Tests (~15 s) | Hook `.githooks/pre-push` |
| Push auf `main`, Pull Request | Lint, Paket- und Architekturtests, App-Tests auf macOS, UI-Tests auf macOS, iOS-Simulator-Build | `.github/workflows/ci.yml` |
| Von Hand: Actions → Release | komplette CI, danach `scripts/release.sh --publish` (macOS) und/oder `scripts/release-ios.sh` (App Store Connect) | `.github/workflows/release.yml` |
| Push auf `main`, der `website/` ändert | Website auf GitHub Pages veröffentlichen | `.github/workflows/pages.yml` (GitHub-Maschine, für öffentliche Repos kostenlos) |

Alle Prüfungen stehen in `scripts/ci.sh`. Lokal laufen sie genau wie auf dem Runner:

```sh
scripts/ci.sh                 # alles (~4 min beim ersten Mal, danach deutlich schneller)
scripts/ci.sh lint            # nur Lint
scripts/ci.sh package macos   # einzelne Schritte
```

Logs und Testergebnisse landen in `build/ci/`. Die `.xcresult`-Datei öffnest du per Doppelklick in Xcode.

---

## 1. Einmalige Einrichtung

### 1.1 Werkzeuge (kostenlos, Homebrew)

```sh
brew install swiftlint shellcheck actionlint gh
```

### 1.2 Git-Hooks aktivieren

```sh
scripts/install-hooks.sh
```

Pro Klon des Repos einmal ausführen. Im Notfall kannst du die Hooks umgehen mit
`git commit --no-verify` bzw. `git push --no-verify`.

### 1.3 Self-hosted Runner auf dem Mac

1. Auf GitHub: **Repository → Settings → Actions → Runners → New self-hosted runner**.
   Wähle **macOS** und **ARM64**.
2. Führe die angezeigten Befehle im Terminal aus. Nimm als Ordner `~/actions-runner`, **nicht** den
   Projektordner. Bei `./config.sh` alle Fragen mit Enter bestätigen. Die Standard-Labels
   `self-hosted, macOS, ARM64` sind genau die, die die Workflows erwarten.
3. Runner als Hintergrunddienst starten:
   ```sh
   cd ~/actions-runner
   ./svc.sh install
   ./svc.sh start
   ./svc.sh status    # sollte "Started" zeigen
   ```
   Der Dienst läuft als LaunchAgent unter deinem Benutzer. Er arbeitet also nur, **solange du
   angemeldet bist**. Das ist so gewollt: Die App-Tests starten NotifyAI als Test-Host und brauchen
   eine Benutzersitzung.
4. Auf GitHub sollte der Runner jetzt als **Idle** erscheinen.
5. **UI-Tests:** Sie steuern die App über die Bedienungshilfen. Beim ersten Lauf fragt macOS, ob
   `xcodebuild` bzw. der Test-Runner die Bedienungshilfen nutzen darf. Erlaube es unter
   **Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen**. Am einfachsten startest
   du dafür einmal `scripts/ci.sh ui` von Hand im Terminal.

Wichtig zu wissen:

- **Ist der Mac aus oder im Ruhezustand,** wartet ein Job in der Warteschlange. Nach 24 Stunden
  bricht GitHub ihn ab. Es geht nichts verloren, du kannst ihn einfach neu starten.
- **Der Runner aktualisiert sich selbst.** Xcode, Simulatoren und Homebrew-Werkzeuge musst du
  selbst aktuell halten.
- **Entfernen:** erst `./svc.sh stop && ./svc.sh uninstall`, dann
  `./config.sh remove --token <Token von der Runner-Seite>`.

### 1.4 Kosten ausschließen

- Self-hosted Runner verbrauchen **keine** Actions-Minuten.
- Unter **GitHub → Settings (Konto) → Billing and plans** prüfen:
  - Ist **keine Zahlungsmethode** hinterlegt, kann GitHub nichts abbuchen. Überschreitet etwas
    das Gratiskontingent, wird es blockiert, nicht berechnet.
  - Ist eine Karte hinterlegt, setze unter **Budgets** ein Actions-Budget von 0 $ mit
    „Stop usage when budget limit is reached“.
- Die Workflows laden keine Artefakte hoch und nutzen keinen GitHub-Cache. Der Build-Cache liegt
  lokal unter `~/Library/Developer/Xcode/DerivedData/NotifyAI-CI`. Damit wird auch kein
  Speicherkontingent verbraucht.

### 1.5 Sicherheit

Ein self-hosted Runner führt den Code aus, den Workflows mitbringen, **auf deinem Mac und mit
deinen Rechten**, also auch mit Zugriff auf Schlüsselbund, Developer-ID-Zertifikat und
Notarisierungs-Profil. Das Repo ist öffentlich, deshalb gilt:

- **Kein Workflow auf dem Runner reagiert auf `pull_request` oder `pull_request_target`.** Sonst
  könnte jeder per Fork-Pull-Request Code auf deinem Mac ausführen. `scripts/ci.sh lint` bricht ab,
  sobald eine Workflow-Datei diese Auslöser nutzt. Fremde Änderungen prüfst du, indem du sie nach dem
  Review auf `main` übernimmst oder den Branch lokal mit `scripts/ci.sh` testest.
- Ausgelöst werden die Workflows nur durch Pushes auf `main` und von Hand. Beides können nur Personen
  mit Schreibrechten.
- Zusätzlich unter **Settings → Actions → General → Fork pull request workflows** die Option
  **„Require approval for all external contributors“** wählen.
- Secrets (`SPARKLE_ED_PRIVATE_KEY`, optional `ASC_*`) stehen nur dem Release-Workflow zur Verfügung
  und liegen während des Laufs als Datei unter `$RUNNER_TEMP`. Am Ende werden sie gelöscht.

---

## 2. Releases (Sparkle-Updates für macOS)

### 2.1 Einmalig: Schlüssel erzeugen

`SUPublicEDKey` in `NotifyAI-macOS-Info.plist` ist noch leer. Ohne Schlüssel bricht
`release.sh` ab.

```sh
# Liegt im DerivedData, sobald das Projekt einmal mit Sparkle gebaut wurde:
BIN=$(ls -d ~/Library/Developer/Xcode/DerivedData/NotifyAI-*/SourcePackages/artifacts/sparkle/Sparkle/bin | head -1)

"$BIN/generate_keys"                       # legt den privaten Schlüssel im Schlüsselbund an
                                           # und gibt den öffentlichen aus
"$BIN/generate_keys" -x ~/Desktop/sparkle_private_key.txt   # privaten Schlüssel exportieren
```

1. Den ausgegebenen **öffentlichen** Schlüssel in `NotifyAI-macOS-Info.plist` bei `SUPublicEDKey`
   eintragen und committen.
2. Den Inhalt von `sparkle_private_key.txt` auf GitHub unter **Settings → Secrets and variables →
   Actions → New repository secret** speichern, Name: `SPARKLE_ED_PRIVATE_KEY`.
3. Den privaten Schlüssel zusätzlich **offline sichern**, zum Beispiel im Passwortmanager. Danach
   die Datei löschen: `rm ~/Desktop/sparkle_private_key.txt`.
   **Geht der Schlüssel verloren, können bereits installierte Apps nie wieder aktualisiert werden.**

### 2.2 Ein Release veröffentlichen

1. `release-notes/<version>.md` anlegen (siehe `release-notes/README.md`), committen und auf
   `main` pushen.
2. GitHub → **Actions → Release → Run workflow**, Branch `main`, Version eingeben, z. B. `0.2.0`.
3. Der Workflow führt die komplette CI aus und danach `scripts/release.sh <version> --publish`.
   Das Skript baut mit Developer ID, notarisiert, legt den Tag an, erstellt das GitHub-Release mit
   DMG und ZIP und pusht `appcast.xml` auf `main`. Bei Plattform „iOS“ folgt
   `scripts/release-ios.sh` (Upload zu App Store Connect).
   Developer-ID-Zertifikat, Notarisierungs-Profil und Xcode-Account kommen aus deinem Schlüsselbund
   (siehe [Publishing.md](Publishing.md)), weil der Runner als dein Benutzer läuft.
4. Danach lokal `git pull`, denn auf `main` ist der Commit „Release …: Update-Feed“
   dazugekommen.

Beim ersten Release über den Runner fragt macOS eventuell, ob `codesign` auf den Schlüssel des
Zertifikats zugreifen darf. Das Fenster sieht nur, wer am Mac sitzt. Starte deshalb das erste
Release einmal lokal im Terminal (`scripts/release.sh <version>` ohne `--publish`) und klicke
**Immer erlauben**. Alternativ hinterlegst du einen App-Store-Connect-API-Schlüssel als Secrets
`ASC_KEY_ID`, `ASC_ISSUER_ID` und `ASC_PRIVATE_KEY` (Inhalt der `.p8`-Datei; erstellen unter App Store
Connect → Benutzer und Zugriff → Integrationen → Team-Schlüssel, Rolle **Admin**). Dann signiert
Xcode mit einem von Apple verwalteten Zertifikat, und Notarisierung und Upload laufen ohne
Schlüsselbund.

Lokal geht es weiterhin ohne GitHub Actions: `scripts/release.sh 0.2.0 --publish`. Das braucht
`gh auth login`, und der Schlüssel wird aus dem Schlüsselbund gelesen.

---

## 3. Linter

### SwiftLint

Die Regeln stehen in `.swiftlint.yml`: Standardregeln plus zusätzliche Regeln für Korrektheit
(`force_unwrapping`, `unhandled_throwing_task`, `private_swiftui_state` …) und Lesbarkeit.

- **Keine Altlasten:** Der Code hat keine Verstöße, eine Baseline gibt es nicht. **Jeder Verstoß ist
  ein Fehler**, auch Warnungen (`--strict`).
- **Tests:** In `NotifyAITests`, `NotifyAIUITests` und `Packages/NotifyAIKit/Tests` sind `!` und
  `try!` für Fixtures erlaubt (eigene `.swiftlint.yml`); ein gescheitertes Fixture beendet den Test.
- **Lange Texte:** Zeilen mit einem Stringliteral ab 60 Zeichen sind von der Längenregel
  ausgenommen. Lokalisierte Texte lassen sich nicht umbrechen, ohne ihren Schlüssel zu ändern.
- **Automatisch korrigieren:** `scripts/lint.sh --fix`. Den Diff danach prüfen.
- **Begründete Ausnahme im Code:** `// swiftlint:disable:next force_unwrapping`

### Compiler-Warnungen

`scripts/ci.sh` lässt den Build fehlschlagen, sobald **im eigenen Code** eine Compiler-Warnung
auftaucht. Warnungen aus Abhängigkeiten wie WhisperKit werden ignoriert. Ein globales
`SWIFT_TREAT_WARNINGS_AS_ERRORS` geht nicht: Es kollidiert mit Swift-Paketen, die ihre Warnungen
unterdrücken.

### ShellCheck und actionlint

Diese beiden prüfen `scripts/*.sh`, `.githooks/*` und `.github/workflows/*.yml`. Ausnahmen stehen
in `.shellcheckrc`.

---

## 4. Apple-Developer-Programm

Mit dem Developer-Account ist die Mac-App mit Developer ID signiert und notarisiert (keine
Gatekeeper-Warnung, Freigaben bleiben über Updates erhalten), und iOS-Builds gehen über
`scripts/release-ios.sh` zu TestFlight und in den App Store. Einrichtung und Ablauf:
[Publishing.md](Publishing.md).

Pflicht-Checks für Branches („erst mergen, wenn die CI grün ist“) gibt es bei öffentlichen
Repositories kostenlos unter *Settings → Branches*.
