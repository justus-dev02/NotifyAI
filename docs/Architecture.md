# Architektur

NotifyAI besteht aus einer schlanken App und einem lokalen Swift-Paket (`Packages/NotifyAIKit`) mit
fünf Modulen. Die Richtung der Abhängigkeiten erzwingt der Compiler; was er nicht sehen kann, prüfen
die Architekturtests (`Packages/NotifyAIKit/Tests/ArchitectureTests`).

```
App (Szenen, Views, View-Models, Plattform-Adapter)
 ├─ DesignSystem ───────────────┐
 └─ NotifyAIServices            │
      ├─ NotifyAIPersistence ───┤
      ├─ AudioCapture ──────────┤
      └─ WhisperKit             └─ NotifyAICore
```

| Modul | Inhalt | Darf nicht |
|---|---|---|
| `NotifyAICore` | Werttypen (Transkript, Zusammenfassung, Marker, Fristen), Logging, `EventChannel`, `BackgroundWork` | UI, Daten, Services kennen |
| `AudioCapture` | Echtzeit-Aufnahme: lock-freie Ringpuffer, Konvertieren, Mischen, Schreiben | UI, Daten |
| `NotifyAIPersistence` | SwiftData-Schema V1–V4 mit Migrationen, `NoteStore`, `NoteQueries`, Dateiablage | UI, Services |
| `NotifyAIServices` | Aufnahme, Verarbeitung, Transkription, Zusammenfassung, Suche, Aufgaben, Import/Export, Einstellungen, Use Cases (`NoteLibrary`, `StorageMaintenance`), `ServiceContainer` | SwiftUI; UIKit/AppKit nur in `Platform/` und `Audio/SystemAudio/` |
| `DesignSystem` | Theme und wiederverwendbare SwiftUI-Komponenten | Daten, Services |
| App | Szenen, Views, `NoteDetailModel`, Composition Root, Plattform-Adapter (Live Activity, Hintergrundaufgaben) | die Datenbank selbst schreiben |

## Regeln

**Lesen ja, schreiben nein.** Modelle und Store sind für die App lesbar (`@Query`, `audioURL`), jede
Eigenschaft ist aber `public package(set)` und jede Schreibmethode `package`. Die App ändert Notizen
nur über Use Cases wie `NoteLibrary`. So kann keine View ein Modell ändern und das Speichern
vergessen, und jede Änderung erreicht die Empfänger der Store-Ereignisse.

**Abhängigkeiten werden übergeben, nicht geholt.** `ServiceContainer` baut den Service-Graphen
(die Initialisierer der Services sind modulintern), `AppEnvironment` ergänzt die App-Objekte und
injiziert jedes Objekt einzeln über seinen Typ (`@Environment(NoteLibrary.self)`). Es gibt keinen
Service Locator und keinen globalen veränderlichen Zustand. AppKit-Callbacks erreichen die App über
den App-Delegate, der `AppLaunch` besitzt; Live-Activity-Intents über `@Dependency`.

**Ereignisse statt Callback-Slots.** Services melden über `EventChannel`, was passiert ist
(`NoteStore.events`, `ProcessingCoordinator.events`, `RecordingController.events`, …). Beliebig viele
Empfänger, synchrone Zustellung auf dem Main Actor, Abmeldung über die Lebensdauer des Abonnements.
Jeder Service abonniert in seinem Initialisierer, worauf er reagiert; Fehler werden zu typisierten
Ereignissen, die App formuliert daraus die Texte (`UserNotices`).

**Ports für Hardware und System.** Was Hardware, Modelle, Dateien oder das System berührt, liegt
hinter einem Protokoll: `TranscriptionEngine`, `Summarizer`, `LanguageModelResponder`,
`NoteAssistant`, `SpeakerDiarizing`, `SentenceEmbedding`, `KnowledgeIndexPersisting`,
`WhisperModelUsage`, `AudioRecording`, `CaptureDevice`, `MicrophoneAccess`,
`SystemActivityControlling`, `RecordingActivityPresenting`. Reine Berechnungen (Kapitelschnitt,
Textanalyse, Suche) bleiben konkret. Der Store wird in Tests mit einer In-Memory-Datenbank ersetzt.

**Nebenläufigkeit strukturiert.** Arbeit verlässt den Main Actor über `@concurrent`-Funktionen
(gleiche Priorität) oder `BackgroundWork.run` (niedrigere Priorität), nie über `Task.detached`.
Der Abbruch eines Jobs erreicht so auch seine Hintergrundarbeit.

**Plattformen an einer Stelle.** `PlatformServices` (App), `DeviceProfile`, `SystemActivity`,
`BackgroundExecution` und die Fabrik `CaptureDevices` unterscheiden iOS und macOS. Composition Root,
Controller und Store enthalten kein `#if os(…)`.

**Texte.** Jedes Modul mit Texten hat seinen eigenen String-Katalog (`bundle: .module`). Jeder Text
ist ins Englische übersetzt; ein Test prüft das.

## Daten

- **Schema V4:** Aufgaben sind eigene Zeilen (`NoteTask`) mit beim Speichern aufgelöstem
  Fälligkeitsdatum. `Note.summary` fügt JSON und Aufgaben-Zeilen zusammen; Abhaken ändert nur die
  Zeile. Migration V3→V4 verschiebt bestehende Aufgaben (`NotifyAIMigrationPlan.moveTasksIntoRows`).
- **Volltext** liegt in `NoteContent`, damit Listen ihn nicht laden.
- **Dekodier-Cache:** Zusammenfassung und Marker werden nur neu dekodiert, wenn sich ihre Daten ändern.

## Tests

| Ebene | Ort | Ausführung |
|---|---|---|
| Architekturregeln | `Packages/NotifyAIKit/Tests/ArchitectureTests` | `swift test` (CI-Schritt `package`) |
| Core, Echtzeit-Aufnahme | `Packages/NotifyAIKit/Tests/…` | `swift test` |
| Services, Persistenz, App | `NotifyAITests` | `scripts/ci.sh macos` |
| Qualität der Analyse | `NotifyAITests/QualityEvaluationTests.swift`, siehe [Quality.md](Quality.md) | mit den App-Tests |
| Abläufe und Barrierefreiheit | `NotifyAIUITests` | `scripts/ci.sh ui` |

Tests warten auf Ereignisse (Observation, `EventChannel`, Gates), nie auf feste Zeiten.
