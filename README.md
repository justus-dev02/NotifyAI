# NotifyAI

Gespräche aufnehmen, als Transkript nachlesen und auf dem Gerät zusammenfassen – für iPhone, iPad und Mac.
Aufnahmen, Transkripte und Zusammenfassungen verlassen das Gerät nicht.

## Funktionen

- **Aufnahme** mit Live-Transkript, Pause und Markierung wichtiger Stellen („Wichtig“ / ⇧⌘M).
  Im Transkript werden markierte Stellen 5 Sekunden davor und danach hervorgehoben.
- **Zwei Spracherkennungen:** Apple Speech (`SpeechAnalyzer`, ohne Download) oder Whisper (WhisperKit, Modell wird einmalig geladen).
- **Zusammenfassung** mit Apple Intelligence (Foundation Models): Überblick, Kernpunkte, Aufgaben, Entscheidungen, offene Fragen, Themen.
  Ohne Apple Intelligence entsteht eine klar gekennzeichnete einfache Zusammenfassung.
- **Belegte Zusammenfassungen:** Jeder Kernpunkt, jede Entscheidung und Aufgabe springt per Tipp zur Stelle im Transkript.
  Aufnahmen ohne eigenen Titel heißen nach ihren Stichworten plus Datum („Budget, Website-Relaunch – 29. Sept. 2026“).
- **Lange Aufnahmen (2–4 h):** Kapitel von etwa 10 Minuten, geschnitten an Themenwechseln, jeweils einzeln
  zusammengefasst und zwischengespeichert (fortsetzbar nach Abbruch), mit Kapitel-Navigation. Fertige Kapitel werden
  optional schon während der Aufnahme verdichtet. Auf iPhone/iPad läuft die Verarbeitung per `BGContinuedProcessingTask`
  im Hintergrund weiter, Unerledigtes nachts beim Laden (`BGProcessingTask`). Bei Hitze pausiert die Arbeit.
- **macOS:** wahlweise nur im Dock, im Dock und in der Menüleiste oder nur in der Menüleiste.
- **Notizen fragen (⌘K):** Fragen in natürlicher Sprache über alle Notizen („Was hat Anna letzte Woche zum Budget gesagt?“).
  Zeiträume, Personen und Arten werden als Filter erkannt; Antworten nennen ihre Quellen.
- **Verwandte Notizen:** gleiche Personen, Orte, Organisationen, seltene gemeinsame Themen, ähnlicher Inhalt – mit Begründung.
- **Wiedergabe** mit Timeline inkl. Markern, Mitlesen im Transkript, Sprung per Tipp.
- **Import** von Audiodateien, PDFs und Fotos (Texterkennung mit Vision).
- **Aufnahme im Hintergrund (iOS)** mit Live Activity auf dem Sperrbildschirm und in der Dynamic Island (Pause / Beenden).
- **Online-Meetings mitschneiden (macOS):** Systemton von Zoom, Teams, Discord, Browsern & Co. über Core Audio Process Taps –
  wahlweise *Mikrofon + Systemton* oder *nur Systemton*, für alle Apps oder eine bestimmte App (inkl. Helper-Prozesse).
  Mikrofon und Systemton werden getrennt gepegelt: Das Transkript beschriftet dich als „Ich“ und die anderen als „Andere“.
- **macOS-Menüleiste:** Aufnahmen starten, pausieren, markieren und beenden, ohne das Hauptfenster zu öffnen.
- **Offene Aufgaben:** alle Aufgaben aus allen Zusammenfassungen in einer Liste, gruppiert nach Fälligkeit
  (überfällig, heute, diese Woche, später, ohne Termin), filterbar nach Person, abhakbar. Gesprochene Fristen
  („bis Freitag“, „3. Oktober“, „nächste Woche“) werden relativ zum Aufnahmetag in ein Datum umgerechnet.
- **Export** als Markdown, optional anonymisiert (E-Mail, Telefonnummern, IBAN).
- **Sprachen der Oberfläche:** Deutsch (Quellsprache) und Englisch (String Catalogs).
- **Diagnosebericht** zum Teilen mit dem Support: Versionen, Einstellungen, Speicher, Protokoll der Sitzung und
  MetricKit-Berichte, ohne Inhalte der Notizen. Nichts wird automatisch hochgeladen.
- Optionale App-Sperre (Face ID / Touch ID / Code), Ausschluss aus Geräte-Backups.
- **Updates in der App (macOS):** Einstellungen → Updates oder NotifyAI → „Nach Updates suchen …“. Wahlweise automatisch
  suchen (täglich / wöchentlich / monatlich) und automatisch laden und beim Beenden installieren – nie während einer Aufnahme.

## Voraussetzungen

- Xcode 27, Swift 6 (Strict Concurrency)
- iOS / iPadOS 26 oder macOS 26
- Zusammenfassung mit Apple Intelligence: ein Gerät mit aktivierter Apple Intelligence

## Updates und Releases (macOS)

Die Mac-App wird außerhalb des App Stores über GitHub Releases verteilt und aktualisiert sich mit
[Sparkle](https://sparkle-project.org) selbst:

```
App ──(täglich, wenige KB)──▶ appcast.xml (dieses Repo, Branch main)
                               │ neueste Version, Build-Nummer, Release-Notes, EdDSA-Signatur
                               ▼ nur wenn neuer:
                              NotifyAI-x.y.z.zip (Anhang am GitHub-Release)
```

- Die App lädt nur dann ein Archiv herunter, wenn `appcast.xml` eine höhere Build-Nummer nennt. Nutzer müssen
  nicht selbst auf GitHub nach neuen Versionen suchen.
- Jedes Archiv ist mit einem privaten EdDSA-Schlüssel signiert; die App prüft es gegen `SUPublicEDKey`
  (`NotifyAI-macOS-Info.plist`) vor dem Entpacken. Manipulierte Downloads werden verworfen.
- Die App ist sandboxed: Sparkle installiert über seinen Installer-Dienst (`SUEnableInstallerLauncherService`,
  Mach-Lookup-Ausnahmen in `NotifyAI-macOS.entitlements`). Notizen und Einstellungen bleiben erhalten.
- Hintergrund-Prüfungen werden während einer Aufnahme übersprungen (`AppUpdater`).
- Builds ohne `SUPublicEDKey` (z. B. selbst aus dem Quellcode gebaut) starten Sparkle nicht und zeigen das in den Einstellungen.

### Einmalig: Signaturschlüssel erzeugen

```bash
# nach dem ersten Build liegen die Sparkle-Werkzeuge in den SourcePackages, z. B.:
build/release/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
```

`generate_keys` legt den privaten Schlüssel im Schlüsselbund an und gibt den öffentlichen aus. Diesen in
`NotifyAI-macOS-Info.plist` bei `SUPublicEDKey` eintragen und committen. Den privaten Schlüssel sichern
(`generate_keys -x datei`) – geht er verloren, können bestehende Installationen keine Updates mehr annehmen.

### Release veröffentlichen

1. `release-notes/<version>.md` schreiben (siehe `release-notes/README.md`) und alles committen.
2. `scripts/release.sh 0.2.0` – baut ad-hoc signiert, packt `build/release/NotifyAI-0.2.0.zip`, signiert es für
   Sparkle und trägt die Version in `appcast.xml` ein. Die Build-Nummer ist die Anzahl der Commits.
3. Veröffentlichen – entweder mit `scripts/release.sh 0.2.0 --publish` (GitHub CLI `gh`) oder von Hand:
   Tag pushen, GitHub-Release mit dem ZIP anlegen, **danach** `appcast.xml` committen und pushen.

Ad-hoc signierte Releases (ohne Developer ID) brauchen `NotifyAI-macOS-AdHoc.entitlements`
(`disable-library-validation`), sonst blockiert die Hardened Runtime `Sparkle.framework`. Mit einer Developer ID
entfällt diese Datei, und macOS behält Mikrofon- und Systemaudio-Freigaben auch über Updates hinweg.

### Installation für Nutzer

1. `NotifyAI-x.y.z.zip` unter Releases laden, entpacken, `NotifyAI.app` nach *Programme* ziehen.
2. Beim ersten Öffnen meldet macOS, dass die App nicht überprüft werden kann → *Fertig*.
3. *Systemeinstellungen → Datenschutz & Sicherheit* → bei NotifyAI *Dennoch öffnen*.
   Alternativ: `xattr -dr com.apple.quarantine /Applications/NotifyAI.app`

Spätere Updates installiert die App selbst, ohne diese Schritte. Weil die App nicht mit einer Developer ID signiert
ist, fragt macOS nach einem Update eventuell erneut nach Mikrofon- und Systemaudio-Zugriff.

## Architektur

Ausführlich in [docs/Architecture.md](docs/Architecture.md).

```
Packages/NotifyAIKit/     Lokales Swift Package, vom Compiler erzwungene Schichten
├── NotifyAICore          Werte und Regeln, Logging, EventChannel, BackgroundWork
├── AudioCapture          Echtzeit-Aufnahmepfad: lock-freie Ringpuffer, Mischen, Schreiben     (→ Core)
├── NotifyAIPersistence   SwiftData-Schema V1–V4 mit Migrationen, NoteStore, Abfragen, Ablage (→ Core)
├── NotifyAIServices      Aufnahme, Verarbeitung, Transkription, Zusammenfassung, Suche, Aufgaben,
│                         Import/Export, Einstellungen, Use Cases, ServiceContainer   (→ Persistence, AudioCapture, WhisperKit)
└── DesignSystem          Theme, Komponenten, Sichtbarkeits-Modifier                        (→ Core)
NotifyAI/
├── App/            Einstieg, AppLaunch (Datenbank-Wiederherstellung), Composition Root, Lebenszyklus, Hinweise
│   ├── Platform/   Live Activity, Hintergrundaufgaben (iOS), Audio-Umgebung (macOS)
│   └── Updates/    Sparkle (macOS)
└── Features/       SwiftUI-Screens und View-Models: Library, Detail, Chat, Tasks, Recording, MenuBar, Settings, Onboarding
Shared/             Live-Activity-Attribute und -Intents (App + Widget-Extension)
NotifyAIWidgets/    Widget-Extension (nur iOS): Live Activity der Aufnahme
docs/               Architecture.md, Quality.md, Performance.md, CI.md
```

- **Lesen ja, schreiben nein:** Modelle und Store sind für die App lesbar, alle Schreibzugriffe sind `package`.
  Die App ändert Notizen nur über Use Cases wie `NoteLibrary`.
- **Abhängigkeiten werden übergeben:** `ServiceContainer` baut die Services, `AppEnvironment` injiziert jedes Objekt
  einzeln über seinen Typ. Kein Service Locator, kein globaler veränderlicher Zustand.
- **Ereignisse statt Callbacks:** Services melden über `EventChannel` (beliebig viele Empfänger).
- **Ports:** Hardware, Modelle, Dateien und System liegen hinter Protokollen und werden in Tests ersetzt.
- Die Regeln prüfen Architekturtests (`Packages/NotifyAIKit/Tests/ArchitectureTests`) bei jedem CI-Lauf.

### Aufnahme-Pipeline

```
Audio-Thread (Echtzeit)                    Verarbeitungs-Queue (alle 100 ms, unsichtbar alle 500 ms)
Mikrofon / Aggregate-IOProc                SourceReader → 16 kHz mono → Mischen in 100-ms-Blöcken
  └─ Downmix (vDSP) ─► SampleRingBuffer ─►   ├─► AAC/CAF schreiben (RecordingSink)
     keine Allokation, kein Lock, kein I/O   ├─► Pegel (nur so oft, wie sie jemand sieht)
     15 s Reserve bei stockender Platte      ├─► Quellaktivität („Ich“ / „Andere“)
                                             └─► Live-Transkription (Rückstand ≤ 60 s)
```

Fehler werden nicht verschluckt: Ein Schreibfehler oder weniger als 50 MB freier Speicher beenden die Aufnahme
geordnet (alles bis dahin Aufgenommene bleibt erhalten) und der Nutzer erfährt den Grund. Unter 200 MB startet keine
Aufnahme. Auf dem Mac hält eine `ProcessInfo`-Activity App Nap und den Ruhezustand durch Inaktivität fern; geht der
Mac trotzdem schlafen (Deckel zu), pausiert die Aufnahme an einer definierten Stelle. ⌘Q während einer Aufnahme beendet
sie zuerst sauber. Fehlgeschlagene Speichervorgänge erscheinen als Hinweis (`UserNotices`).

Fällt ein Audiogerät aus und lässt sich nicht neu starten (Mikrofon getrennt, Aggregate-Gerät nicht neu aufzubauen),
meldet die Aufnahmeschicht das (`CaptureEvent.inputFailed`), statt still weiterzulaufen oder selbst zu pausieren. Der
`RecordingController` besitzt als Einziger den Aufnahmezustand: Er pausiert sichtbar mit Begründung, und „Fortsetzen“
setzt die Aufnahme erst fort, wenn die Geräte tatsächlich wieder laufen. Nach einem Anruf wird nur eine Pause
aufgehoben, die der Anruf ausgelöst hat, nie eine, die der Nutzer gewählt hat (`InterruptionPolicy`).

Der Main Thread wartet nie auf die Platte: Umrechnen und Mischen laufen unter einem kurzen Lock, Kodieren und Schreiben
unter einem eigenen Lock auf der Verarbeitungs-Queue. Verlorene Samples (voller Ringpuffer, fehlgeschlagene Umrechnung)
werden gesammelt protokolliert.

Die Verarbeitung nach der Aufnahme wartet während einer Aufnahme; mit Live-Transkript wird auch ein laufender Job
angehalten und danach ab seinem letzten gespeicherten Schritt fortgesetzt. Endet unter iOS die Hintergrundzeit, wird
der Hintergrund-Task sofort beendet und die Arbeit beim nächsten Aktivwerden der App fortgesetzt. Abschnitte, die
Apple Intelligence nicht verarbeiten kann, fließen mit ihren wichtigsten Sätzen ein; gekürzte Notizen und nicht
berücksichtigte markierte Stellen stehen unter der Zusammenfassung.

### Ablauf einer Aufnahme

```
Mikrofon ─► AudioRecorder ─┬─► CAF-Datei (AAC, 16 kHz)
                           └─► LiveTranscriptionSession ─► Live-Text + finales Transkript
Stopp ─► Note (Transkript, Marker) ─► ProcessingCoordinator
         ├─ Transkription der Datei (nur falls kein Live-Transkript)
         ├─ Sprechererkennung (optional)
         └─ Zusammenfassung ─► Note.status = ready
```

## Entscheidungen

| Entscheidung | Begründung |
|---|---|
| iOS/macOS 26 als Mindestversion | `SpeechAnalyzer` (lange Aufnahmen, Wort-Zeitstempel) und Foundation Models (lokales LLM) gibt es erst ab 26. |
| Ein Multiplattform-Target statt Catalyst | Native macOS-Oberfläche inkl. `MenuBarExtra` und Settings-Fenster bei geteiltem Code. |
| Live-Transkript ist das finale Transkript | Die Session bekommt exakt das Audio der Datei; ein zweiter Durchlauf würde Rechenzeit und Akku verdoppeln. |
| Whisper live in Pausen-geschnittenen Abschnitten | Jede Sekunde Audio wird genau einmal transkribiert (linear statt quadratisch). Stille wird nicht an Whisper gegeben (Halluzinationen). |
| Zeiten auf der Aufnahme-Zeitachse | Pausen sind nicht Teil der Datei; Marker und Transkript beziehen sich dadurch exakt auf dieselbe Zeit. |
| AAC in CAF | Etwa 10× kleiner als PCM und – anders als M4A – auch nach einem Absturz lesbar. |
| SwiftData mit externem Speicher für Transkripte | Die Liste lädt keine Transkripte; Suche läuft über denormalisierte Textfelder per `#Predicate`. |
| Map-Reduce für Zusammenfassungen | Das On-Device-Modell hat 4096 Token Kontext; lange Transkripte werden abschnittsweise verdichtet. |
| Core Audio Process Taps statt ScreenCaptureKit | Braucht nur die Berechtigung „Systemaudio aufnehmen“ statt Bildschirmaufnahme und erlaubt einzelne Prozesse. |
| Mikrofon und Tap in *einem* Aggregate Device | Beide laufen auf der Uhr des Mikrofons (Tap mit Drift-Kompensation) – kein Auseinanderlaufen, auch bei stundenlangen Meetings. |
| Tap bei Prozessänderungen neu aufbauen | Apps wie Zoom oder Chrome starten Audio-Prozesse erst im Call bzw. pro Tab; der Tap folgt ihnen automatisch. |
| „Ich / Andere“ aus Pegeln statt aus Stimmen | Der Systemton ist eine saubere Referenz für die Gegenseite – zuverlässiger als die experimentelle Sprechererkennung, auch bei Lautsprecher-Echo. |
| Apple Foundation Models statt heruntergeladener LLMs | Kein Download, läuft auf dem Neural Engine auch im Hintergrund, Guided Generation garantiert die Struktur. Eigene LLMs wären 2–5 GB groß, auf iPhones speicherkritisch und dürften im Hintergrund nicht auf der GPU rechnen. |
| Volltext (BM25) als Hauptsignal, Embeddings nur halb gewichtet | Gemessen: Apples deutsche Satz-Embeddings trennen Themen kaum (Frage ↔ Antwort −0,02). Synonyme aus der Query-Expansion des Sprachmodells decken „gleiche Bedeutung, andere Worte“ ab. |
| Kein eigenes ML-Modell für Beziehungen | Ohne Trainingsdaten nicht besser als die Kombination aus Named-Entity-Erkennung, seltenen gemeinsamen Stichworten (IDF) und relativer Inhaltsähnlichkeit. |
| Datumsfilter per Kalender, nie per Sprachmodell | Das Modell nennt nur den Zeitraum („lastWeek“); kleine Modelle rechnen Daten unzuverlässig. |
| Kapitelgrenzen deterministisch | Ein Kapitel wird erst geschlossen, wenn das Transkript über seine späteste Grenze plus Kohäsionsfenster hinausreicht. Während der Aufnahme geschnittene Kapitel sind daher identisch mit den finalen, ihre Zusammenfassungen werden 1:1 wiederverwendet. |
| Sprechererkennung in zwei Durchläufen | Erst nur Frame-Energien (VAD-Schwelle), dann Spektren blockweise: rund 15 MB statt 920 MB Speicher für 4 Stunden. |
| Relative Audio-Dateinamen | Absolute Container-Pfade ändern sich bei Neuinstallation und Updates. |
| Ringpuffer statt Arbeit im Audio-Callback | Der Callback braucht 0,86 µs statt ≈ 107 µs pro Zyklus und blockiert nie; eine stockende Platte verzögert nur die Verarbeitungs-Queue (siehe `docs/Performance.md`). |
| Volltext in eigener Entität (`NoteContent`, Schema V3) | Die Bibliothek lädt keine Transkripte mehr; die Suche folgt der Relation in der Datenbank. |
| Aufgaben als eigene Entität (`NoteTask`, Schema V4) | Die Aufgabenübersicht ist eine Abfrage statt alle Zusammenfassungen zu dekodieren; Abhaken ändert nur eine Zeile. |
| `contentRevision` statt Text-Hash | Der Suchindex prüft 500 Notizen, ohne einen einzigen Text zu laden. |
| Fälligkeiten per Regeln, nicht per Sprachmodell | Fristen bleiben als gesagter Text erhalten; das Datum wird deterministisch relativ zum Aufnahmetag berechnet. |
| Datenbank verschieben statt löschen | Bei einer beschädigten Datenbank startet die App mit einer Wiederherstellung; die alte Datei bleibt erhalten, Aufnahmen werden als neue Notizen angelegt. |

## Tests

```sh
scripts/ci.sh                 # alles, wie die CI: Lint, Paket- und Architekturtests, App-Tests, UI-Tests, iOS-Build
scripts/ci.sh package         # Paket: Core, Echtzeit-Aufnahme, Architekturregeln
scripts/ci.sh macos           # App-Tests (Swift Testing) auf dem Mac, inkl. Qualitätsmessungen
scripts/ci.sh ui              # UI-Tests inkl. Accessibility-Audits auf dem Mac
# Benchmarks (siehe docs/Performance.md)
xcodebuild -scheme NotifyAI -destination 'platform=macOS' test -only-testing:NotifyAITests/PerformanceBenchmarks
```

Unit-Tests (Swift Testing) decken Marker/Highlighting, Chunking, Zusammenfassung inkl. Fallbacks, Redaction,
Markdown-Export, Persistenz, die Verarbeitungspipeline (mit Mocks), das Aufnahmeformat und die Sprechererkennung ab,
außerdem:

- **Aufnahme-Steuerung:** der Zustandsautomat des `RecordingController` mit Fakes für Mikrofon, Recorder, System und
  Live Activity (Pause, Unterbrechung, Ruhezustand, Geräteausfall, volle Platte, Stopp, Verwerfen).
- **Aufnahme-Pipeline:** synthetisches Audio → CAF-Datei → Dauer, Pause und Marker-Position stimmen; lückenlose Chunks;
  Schreibfehler (volle Platte); Gerätewechsel mitten in der Aufnahme (48 → 24 → 44,1 kHz, Mikrofon ab/an);
  überlaufender Ringpuffer; reduzierte Pegel; Nebenläufigkeit von Produzent und Konsument.
- **Migrationen** V1 → V4 auf echten Store-Dateien, Suche über die Relation, Aufgaben als Zeilen.
- **Schreibweg und Ereignisse:** `NoteLibrary`, Store-Ereignisse, Suchindex und Verarbeitung folgen Löschungen.
- **Wiederherstellung** einer nicht zu öffnenden Datenbank inkl. verwaister Aufnahmen.
- **Qualität** (siehe [docs/Quality.md](docs/Quality.md)): Trefferquote der Suche, Fehlerrate der Sprechererkennung auf
  synthetisierten Stimmen, Fristen, Fragenverständnis, Kapitelgrenzen – mit Untergrenzen gegen Rückschritte.

Tests warten auf Ereignisse, nie auf feste Zeiten (`NotifyAITests/Waiting.swift`).

UI-Tests prüfen Einwilligung, Aufgabenübersicht (Filtern, Abhaken), das Löschen geladener Modelle und führen
Accessibility-Audits (`performAccessibilityAudit`) für Bibliothek, Notiz, Aufgaben und Aufnahme aus.

### Ablauf einer Meeting-Aufnahme (macOS)

```
Mikrofon ─┐
          ├─► Aggregate Device (eine Uhr) ─► IOProc ─► je Quelle 16 kHz mono ─┬─► Mix ─► CAF + Live-Transkript
Process Tap (Zoom/Teams/…) ┘                                                  └─► Pegel je 100 ms ─► „Ich“ / „Andere“
```

## Bekannte Grenzen

- Die Sprechererkennung ist experimentell. Gemessen wird sie an synthetisierten Stimmen (5,9 % DER), nicht an echten
  Aufnahmen; für die Transkription (WER) gibt es noch keinen Datensatz.
- Ohne Apple Intelligence findet die Suche umformulierte Fragen kaum (Recall@3 = 0,2, siehe docs/Quality.md).
- Geräte ohne Apple Intelligence erhalten nur die einfache, extraktive Zusammenfassung.
- Für die Systemaudio-Berechtigung gibt es keine öffentliche Abfrage-API. Eine verweigerte Berechtigung liefert Stille;
  die App erkennt das nur indirekt und zeigt nach 10 Sekunden ohne Systemton einen Hinweis.
- Über Lautsprecher nimmt das Mikrofon die Gegenseite zusätzlich auf (Echo). Die Beschriftung bleibt korrekt, für die beste
  Tonqualität empfiehlt die App Kopfhörer.
- Auf dem Mac braucht der UI-Test-Runner die Bedienungshilfen-Berechtigung
  (Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen), sonst startet er nicht.
- Apple Speech hat keine Rückstandsmeldung; der Analyzer ist für Echtzeit ausgelegt. Die 60-Sekunden-Grenze greift für
  Whisper und für Audio, das beim Laden eines Modells gepuffert wird.
- Der Suchindex liegt vollständig im Speicher (Vektoren im Speicher als Float32, auf der Platte als Float16). Für sehr
  große Bibliotheken wäre ein Index mit Lazy Loading (z. B. SQLite FTS5) der nächste Schritt.
