# CI/CD für NotifyAI

Gebaut und getestet wird **auf einer Mac-Maschine von GitHub** (GitHub-hosted Runner, Image
`xcode-27`). Für öffentliche Repositories ist das kostenlos, und dein Mac muss dafür nicht laufen.
Nur der Release-Workflow braucht deinen Mac, weil er mit deinem Developer-ID-Zertifikat signiert
(siehe [2.2](#22-ein-release-veröffentlichen)).

| Wann | Was läuft | Wo |
|---|---|---|
| `git commit` | SwiftLint für die Swift-Dateien des Commits | Hook `.githooks/pre-commit` |
| `git push` | SwiftLint, ShellCheck, actionlint, Paket-Tests (~15 s) | Hook `.githooks/pre-push` |
| Push auf `main`, Pull Request | Lint, Veröffentlichungs-Checks, Paket- und Architekturtests, App-Tests auf macOS, UI-Tests auf macOS, iOS-Simulator-Build, Übersetzungen | `.github/workflows/ci.yml` (GitHub-Mac) |
| Von Hand: Actions → Release | komplette CI, danach `scripts/release.sh --publish` (macOS) und/oder `scripts/release-ios.sh` (App Store Connect) | `.github/workflows/release.yml` (dein Mac, self-hosted Runner) |
| Push auf `main`, der `website/` ändert | Website auf GitHub Pages veröffentlichen | `.github/workflows/pages.yml` (GitHub-Linux-Maschine) |

Alle Prüfungen stehen in `scripts/ci.sh`. Lokal laufen sie genau wie in der CI:

```sh
scripts/ci.sh                 # alles (~4 min beim ersten Mal, danach deutlich schneller)
scripts/ci.sh lint            # nur Lint
scripts/ci.sh package macos   # einzelne Schritte
```

Logs und Testergebnisse landen in `build/ci/`. Die `.xcresult`-Datei öffnest du per Doppelklick in Xcode.
Schlägt die CI auf GitHub fehl, hängen Logs und `.xcresult` als Artefakt `ci-logs` am Lauf
(Actions → Lauf → *Artifacts*, 7 Tage).

---

## 1. Einmalige Einrichtung

### 1.1 Werkzeuge (kostenlos, Homebrew)

```sh
brew install swiftlint shellcheck actionlint gh
```

Die CI nutzt SwiftLint in genau der Version, die in `.github/workflows/ci.yml` steht
(`SWIFTLINT_VERSION`). Aktualisierst du SwiftLint lokal, dort Version und Prüfsumme mitziehen.

### 1.2 Git-Hooks aktivieren

```sh
scripts/install-hooks.sh
```

Pro Klon des Repos einmal ausführen. Im Notfall kannst du die Hooks umgehen mit
`git commit --no-verify` bzw. `git push --no-verify`.

### 1.3 Die Mac-Maschine von GitHub

- **Image:** `runs-on: xcode-27`, Apple Silicon. Xcode 27 gibt es auf GitHub nur in diesem Image
  (Public Preview); `macos-26` hat nur Xcode 26. Bei einer Preview kann ein Lauf ab und zu länger in
  der Warteschlange stehen. Sobald Xcode 27 in `macos-26` oder einem `macos-27`-Image enthalten ist,
  dort umstellen.
- **Xcode-Version:** fest `XCODE_VERSION` in `ci.yml`, dieselbe wie lokal. Fehlt sie im Image, bricht
  der erste Schritt mit der Liste der vorhandenen Versionen ab. Welche Versionen ein Image hat, steht
  in [actions/runner-images](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md).
- **Build-Cache:** DerivedData (mit den Swift-Paketen und ihren fertig gebauten Modulen) und der
  Build-Ordner der Paket-Tests liegen im Actions-Cache. Der Schlüssel enthält die Xcode-Version und
  `Package.resolved`; ändert sich eins davon, beginnt ein neuer Cache. Gespeichert wird nur bei
  Läufen auf `main`, Pull Requests lesen ihn nur.
- **Was dort nicht verfügbar ist:** Apple Intelligence, das Suchmodell (`NLContextualEmbedding`) und
  die neuronalen Modelle. Die Tests ersetzen das Sprachmodell durch Attrappen und überspringen, was
  ein geladenes Modell braucht. Das ist lokal ohne Modelle genauso.
- Ein neuer Push auf denselben Branch bricht den laufenden Lauf ab („Canceling since a higher
  priority waiting request …“). Geprüft wird immer der neueste Stand.

### 1.4 Kosten und Sicherheit

**Kosten.** Laut GitHub ist Actions „free for self-hosted runners and for public repositories that
use standard GitHub-hosted runners“. `xcode-27` ist ein Standard-Runner. Geld kostet es nur, wenn:

- das Repository **privat** wird: Dann zählen Mac-Minuten mit einem hohen Faktor gegen das
  Kontingent, danach wird pro Minute abgerechnet;
- ein **größerer Runner** genutzt wird (`xcode-27-xlarge`, `macos-26-large` …): „Larger runners are
  always charged for, even when used by public repositories.“

Zur Sicherheit unter **GitHub → Settings (Konto) → Billing and plans** prüfen: Ist **keine
Zahlungsmethode** hinterlegt, kann GitHub nichts abbuchen. Ist eine Karte hinterlegt, setze unter
**Budgets** ein Actions-Budget von 0 $ mit „Stop usage when budget limit is reached“.

**Sicherheit.** Das Repo ist öffentlich.

- **CI und Pull Requests:** Die CI läuft auch für Pull Requests, auch aus Forks. Das ist auf GitHubs
  Maschinen sicher: Jeder Lauf bekommt eine frische, isolierte Maschine, ein Token nur mit Leserechten
  und keine Secrets. Unter **Settings → Actions → General → Fork pull request workflows** sollte
  „Require approval for first-time contributors“ (Standard) oder strenger gewählt sein.
- **Release auf deinem Mac:** Der Release-Workflow läuft auf einem self-hosted Runner, also mit deinen
  Rechten, deinem Schlüsselbund und deinem Developer-ID-Zertifikat. Er darf deshalb nie auf
  Pull Requests reagieren und startet nur von Hand. `scripts/ci.sh lint` bricht ab, wenn ein Workflow
  mit `self-hosted` auf `pull_request` reagiert oder irgendein Workflow `pull_request_target` nutzt
  (das liefe mit Schreibrechten und Secrets, auch für Forks).
- Secrets (`SPARKLE_ED_PRIVATE_KEY`, optional `ASC_*`) stehen nur dem Release-Workflow zur Verfügung
  und liegen während des Laufs als Datei unter `$RUNNER_TEMP`. Am Ende werden sie gelöscht.

### 1.5 Self-hosted Runner für Releases (optional)

Nur nötig, wenn du Releases über **Actions → Release** starten willst. Ohne Runner veröffentlichst du
lokal mit `scripts/release.sh <version> --publish` und `scripts/release-ios.sh <version>`.

1. Auf GitHub: **Repository → Settings → Actions → Runners → New self-hosted runner**.
   Wähle **macOS** und **ARM64**.
2. Führe die angezeigten Befehle im Terminal aus. Nimm als Ordner `~/actions-runner`, **nicht** den
   Projektordner. Bei `./config.sh` alle Fragen mit Enter bestätigen. Die Standard-Labels
   `self-hosted, macOS, ARM64` sind genau die, die `release.yml` erwartet.
3. Runner als Hintergrunddienst starten:
   ```sh
   cd ~/actions-runner
   ./svc.sh install
   ./svc.sh start
   ./svc.sh status    # sollte "Started" zeigen
   ```
   Der Dienst läuft als LaunchAgent unter deinem Benutzer, also nur, **solange du angemeldet bist**.
4. Auf GitHub sollte der Runner jetzt als **Idle** erscheinen.

Ist der Mac aus, wartet ein Release-Job in der Warteschlange; nach 24 Stunden bricht GitHub ihn ab.
**Entfernen:** erst `./svc.sh stop && ./svc.sh uninstall`, dann
`./config.sh remove --token <Token von der Runner-Seite>`.

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
   (siehe [Publishing.md](Publishing.md)), weil der Runner als dein Benutzer läuft. Dafür muss
   der self-hosted Runner eingerichtet sein ([1.5](#15-self-hosted-runner-für-releases-optional)).
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
