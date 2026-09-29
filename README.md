# NotifyAI

Gespräche aufnehmen, als Transkript nachlesen und auf dem Gerät zusammenfassen – für iPhone, iPad und Mac.
Aufnahmen, Transkripte und Zusammenfassungen verlassen das Gerät nicht.

## Funktionen

- **Aufnahme** mit Live-Transkript, Pause und Markierung wichtiger Stellen („Wichtig“ / ⇧⌘M).
  Im Transkript werden markierte Stellen 5 Sekunden davor und danach hervorgehoben.
- **Zwei Spracherkennungen:** Apple Speech (`SpeechAnalyzer`, ohne Download) oder Whisper (WhisperKit, Modell wird einmalig geladen).
- **Zusammenfassung** mit Apple Intelligence (Foundation Models): Überblick, Kernpunkte, Aufgaben, Entscheidungen, offene Fragen, Themen.
  Ohne Apple Intelligence entsteht eine klar gekennzeichnete einfache Zusammenfassung.
- **Wiedergabe** mit Timeline inkl. Markern, Mitlesen im Transkript, Sprung per Tipp.
- **Import** von Audiodateien, PDFs und Fotos (Texterkennung mit Vision).
- **Aufnahme im Hintergrund (iOS)** mit Live Activity auf dem Sperrbildschirm und in der Dynamic Island (Pause / Beenden).
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
│   ├── Transcription/  TranscriptionEngine-Protokoll, Apple Speech, Whisper, Modellverwaltung
│   ├── Summarization/  Foundation-Models-Summarizer (Map-Reduce), extraktiver Fallback
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
| Relative Audio-Dateinamen | Absolute Container-Pfade ändern sich bei Neuinstallation und Updates. |

## Tests

```sh
xcodebuild -scheme NotifyAI -destination 'platform=macOS' test -only-testing:NotifyAITests
```

Unit-Tests (Swift Testing) decken Marker/Highlighting, Chunking, Zusammenfassung inkl. Fallbacks, Redaction,
Markdown-Export, Persistenz, die Verarbeitungspipeline (mit Mocks), das Aufnahmeformat und die Sprechererkennung ab.

## Bekannte Grenzen

- Die Sprechererkennung ist experimentell und nicht an echten Aufnahmen kalibriert.
- Es gibt noch keinen Evaluationsdatensatz (WER/DER) zum Vergleich der Engines.
- Geräte ohne Apple Intelligence erhalten nur die einfache, extraktive Zusammenfassung.
