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
- **Export** als Markdown, optional anonymisiert (E-Mail, Telefonnummern, IBAN).
- Optionale App-Sperre (Face ID / Touch ID / Code), Ausschluss aus Geräte-Backups.

## Voraussetzungen

- Xcode 27, Swift 6 (Strict Concurrency)
- iOS / iPadOS 26 oder macOS 26
- Zusammenfassung mit Apple Intelligence: ein Gerät mit aktivierter Apple Intelligence

## Architektur

```
NotifyAI/
├── App/            Einstieg, Composition Root (AppEnvironment), Einstellungen, Navigation
├── Domain/         Note (SwiftData), Transkript, Marker, Zusammenfassung – ohne UI-Abhängigkeiten
├── Services/
│   ├── Audio/          Aufnahme (AVAudioEngine → 16 kHz mono → AAC/CAF), Wiedergabe, Audio-Session
│   │   └── SystemAudio/    Process Tap + Aggregate Device (macOS), App-/Prozess-Zuordnung
│   ├── Transcription/  TranscriptionEngine-Protokoll, Apple Speech, Whisper, Modellverwaltung
│   ├── Summarization/  Foundation-Models-Summarizer (Map-Reduce), extraktiver Fallback, Quellen-Verknüpfung
│   ├── Knowledge/      Suchindex, hybride Suche (BM25 + Embeddings), verwandte Notizen, Frage-Verständnis, RAG
│   ├── Diarization/    Experimentelle Sprechererkennung (Log-Mel, Average-Linkage-Clustering)
│   ├── Processing/     Serielle, fortsetzbare Pipeline nach der Aufnahme
│   ├── Persistence/    NoteStore, Speicherorte
│   └── Import/Export/Security
├── Features/       SwiftUI-Screens: Library, Detail, Recording, MenuBar (macOS), Settings, Onboarding
└── DesignSystem/   Tokens und wiederverwendbare Komponenten
Shared/             Live-Activity-Attribute und -Intents (App + Widget-Extension)
NotifyAIWidgets/    Widget-Extension (nur iOS): Live Activity der Aufnahme
```

Abhängigkeiten werden einmal in `AppEnvironment` erzeugt und über das SwiftUI-Environment verteilt.
Services hängen von Protokollen ab (`TranscriptionEngine`, `Summarizer`), damit sie in Tests ersetzt werden können.

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

## Tests

```sh
xcodebuild -scheme NotifyAI -destination 'platform=macOS' test -only-testing:NotifyAITests
```

Unit-Tests (Swift Testing) decken Marker/Highlighting, Chunking, Zusammenfassung inkl. Fallbacks, Redaction,
Markdown-Export, Persistenz, die Verarbeitungspipeline (mit Mocks), das Aufnahmeformat und die Sprechererkennung ab.

### Ablauf einer Meeting-Aufnahme (macOS)

```
Mikrofon ─┐
          ├─► Aggregate Device (eine Uhr) ─► IOProc ─► je Quelle 16 kHz mono ─┬─► Mix ─► CAF + Live-Transkript
Process Tap (Zoom/Teams/…) ┘                                                  └─► Pegel je 100 ms ─► „Ich“ / „Andere“
```

## Bekannte Grenzen

- Die Sprechererkennung ist experimentell und nicht an echten Aufnahmen kalibriert.
- Es gibt noch keinen Evaluationsdatensatz (WER/DER) zum Vergleich der Engines.
- Geräte ohne Apple Intelligence erhalten nur die einfache, extraktive Zusammenfassung.
- Für die Systemaudio-Berechtigung gibt es keine öffentliche Abfrage-API. Eine verweigerte Berechtigung liefert Stille;
  die App erkennt das nur indirekt und zeigt nach 10 Sekunden ohne Systemton einen Hinweis.
- Über Lautsprecher nimmt das Mikrofon die Gegenseite zusätzlich auf (Echo). Die Beschriftung bleibt korrekt, für die beste
  Tonqualität empfiehlt die App Kopfhörer.
