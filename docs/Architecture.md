# Architektur

NotifyAI besteht aus einer schlanken App und einem lokalen Swift-Paket (`Packages/NotifyAIKit`). Das
Paket hat vier Basismodule und dreizehn Service-Module, jedes mit einer klaren Aufgabe. Die Richtung
der Abhängigkeiten erzwingt der Compiler über `Package.swift`; die Architekturtests
(`Packages/NotifyAIKit/Tests/ArchitectureTests`) prüfen zusätzlich die Imports jeder Datei gegen
dieselbe Schichttabelle, damit ein versehentlich erweitertes Manifest auffällt.

```
App (Szenen, Views, View-Models, Plattform-Adapter)
 ├─ DesignSystem
 └─ NotifyAIServices ─ Composition Root: baut und verdrahtet alle Services, re-exportiert die Module
      ├─ NotifyAILibrary ─────── Use Cases der Screens
      ├─ NotifyAIRecording ───── Aufnahme mit Live-Transkript und Live-Kapiteln
      ├─ NotifyAIIntegrations ── Obsidian, Notion, Webhooks
      ├─ NotifyAIKnowledge ───── Suchindex, „Notizen fragen“, verwandte Notizen
      ├─ NotifyAIExport ──────── Markdown, PDF, Word, Untertitel
      └─ NotifyAIProcessing ──── Warteschlange: Transkription → Bereinigung → Sprecher → Zusammenfassung
           ├─ NotifyAISettings ─────── Einstellungen
           ├─ NotifyAISummarization ── Apple Intelligence, extraktiv, Kapitel, Aufgaben, Sammelzusammenfassung
           ├─ NotifyAISpeakers ─────── Sprechertrennung, Stimmprofile, Zuordnung
           ├─ NotifyAITranscription ── Apple Speech, Whisper (WhisperKit), Parakeet (FluidAudio)
           │    └─ NotifyAINeuralModels ─ Download und Prüfung der Core-ML-Modelle
           └─ NotifyAIAudio ────────── Rekorder, Wiedergabe, Audio-Session, Geräte, Systemton, Audiodateien
                └─ NotifyAISupport ─── Textanalyse, Satz-Embeddings, Plattform, Anzeigenamen, Sprecher-Labels, Schlüsselbund
                     ├─ NotifyAIPersistence ─┐
                     ├─ AudioCapture ────────┤
                     └───────────────────────┴─ NotifyAICore
```

Die vollständige Liste, wer wen importieren darf, steht in `Package.swift` und in `serviceLayers`
der Architekturtests. Ein Modul sieht nur die Module unter sich: Die Transkription kennt keine
Zusammenfassung, die Zusammenfassung keine Warteschlange, die Suche keine Aufnahme.

| Modul | Inhalt | Darf nicht |
|---|---|---|
| `NotifyAICore` | Werttypen (Transkript, Zusammenfassung, Marker, Fristen, Labels, Vorlagenwahl), Logging, `EventChannel`, `BackgroundWork` | UI, Daten, Services kennen |
| `AudioCapture` | Echtzeit-Aufnahme: lock-freie Ringpuffer, Konvertieren, Mischen, Echo-Unterdrückung, Schreiben | UI, Daten |
| `NotifyAIPersistence` | SwiftData-Schema V1–V7 mit Migrationen, `NoteStore`, `NoteQueries`, Dateiablage | UI, Services |
| `NotifyAISupport` | `TextAnalysis`, `ContextualSentenceEmbedder` (Suche) und `SentenceEmbedder` (Belege der Zusammenfassung), `DeviceLoad`, Plattform-Adapter, Anzeigenamen, `SpeakerLabels`, Schlüsselbund | andere Services; UIKit/AppKit nur in `Platform/` |
| `NotifyAIAudio` | `AudioRecorder`, `AudioPlayer`, Audio-Session, Mikrofon, Systemton, `MonoAudioFile` | höhere Services; UIKit/AppKit nur in `SystemAudio/` |
| `NotifyAINeuralModels` | `NeuralModelManager`, `NeuralModelStore`, `LoadedModel`; kennt Parakeet und Sprechererkennung nur über `NeuralModelUsage` | Transkription, Sprecher |
| `NotifyAITranscription` | Engines, Live-Sitzungen, Prüfung gegen das Audio, Füllwörter, Vokabular, Whisper-Modelle | Zusammenfassung, Verarbeitung |
| `NotifyAISpeakers` | Sprechertrennung (neuronal und spektral), `VoiceRecognition`, `SpeakerAttribution`, Stimmprofile | Transkription, Zusammenfassung |
| `NotifyAISummarization` | Summarizer, Kapitel, Verdichtung, `ActionItemRefiner`, Grounding, Vorlagen-Anweisungen, Sammelquellen | Einstellungen, Verarbeitung |
| `NotifyAISettings` | `AppSettings` und ihre Gruppen | Verarbeitung, UI |
| `NotifyAIProcessing` | `ProcessingCoordinator` und Pipeline-Schritte | Aufnahme, Suche, Use Cases |
| `NotifyAIExport` | `ExportDocument` und die Formate | Verarbeitung, Integrationen |
| `NotifyAIKnowledge` | `KnowledgeIndex`, `PassageVectors`, `HybridRetriever`, `RelatedNotesFinder`, `QueryPlanner`, `NoteChatModel`, `NoteQuestionAnswering`, `CrossNoteAnswering` | Aufnahme, Use Cases |
| `NotifyAIIntegrations` | `IntegrationService`, Obsidian, Notion, Webhooks | Aufnahme, Use Cases |
| `NotifyAIRecording` | `RecordingController`, Live-Transkript, Live-Kapitel, Wiederherstellung | Suche, Use Cases |
| `NotifyAILibrary` | `NoteLibrary`, `NoteLabels`, `NoteCollections`, `TaskBoard`, `SummaryTemplates`, `SpeakerDirectory`, `TranscriptEditor`, Import, Speicher, Diagnose, App-Sperre | Aufnahme |
| `NotifyAIServices` | `ServiceContainer`, Re-Export aller Service-Module | eigene Logik |
| `DesignSystem` | Theme und wiederverwendbare SwiftUI-Komponenten | Daten, Services |
| App | Szenen, Views, `NoteDetailModel`, Composition Root, Plattform-Adapter (Live Activity, Hintergrundaufgaben) | die Datenbank selbst schreiben |

**Sichtbarkeit zwischen Modulen.** `public` ist, was die App braucht. `package` ist, was ein
Service-Modul den anderen anbietet (z. B. `TextAnalysis`, `SummaryRequest`, `ProcessingCoordinator.enqueue`).
Alles andere bleibt modulintern. Die App-Tests gehören über `-package-name notifyaikit` zum Paket und
sehen deshalb auch dessen `package`-Schnittstellen.

**Texte pro Modul.** Jedes Service-Modul mit Texten hat seinen eigenen String-Katalog
(`Sources/<Modul>/Resources/Localizable.xcstrings`) und schlägt mit `bundle: .module` nach;
`scripts/check-localization.py` prüft jeden Katalog.

## Regeln

**Lesen ja, schreiben nein.** Modelle und Store sind für die App lesbar (`@Query`, `audioURL`), jede
Eigenschaft ist aber `public package(set)` und jede Schreibmethode `package`. Die App ändert Notizen
nur über Use Cases wie `NoteLibrary`. So kann keine View ein Modell ändern und das Speichern
vergessen, und jede Änderung erreicht die Empfänger der Store-Ereignisse.

**Abhängigkeiten werden übergeben, nicht geholt.** `ServiceContainer` baut den Service-Graphen
(die Initialisierer der Services sind `package`, die App kann sie nicht aufrufen), `AppEnvironment` ergänzt die App-Objekte und
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
`WhisperModelUsage`, `NeuralModelUsage`, `AudioRecording`, `CaptureDevice`, `MicrophoneAccess`,
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

**Netzwerk nur auf Wunsch.** Modelle (Whisper, Parakeet, Sprecher) werden nur geladen, wenn das in den
Einstellungen ausdrücklich ausgelöst wird (`WhisperModelManager`, `NeuralModelManager`). Zur Laufzeit werden sie
ausschließlich aus dem geladenen Ordner mit Fertig-Markierung geöffnet (`AsrModels.loadLocal`, eigener
Loader für die Sprechermodelle), nie implizit nachgeladen. Geladene Modelle gibt `LoadedModel` zwei Minuten
nach der letzten Nutzung oder bei Speicherdruck frei.
Das Sprachmodell der Suche (`NLContextualEmbedding`) ist ein System-Download von Apple wie die Sprachpakete von
Apple Speech: Es wird nur über Einstellungen → Zusammenfassung → „Suche“ geladen. Bis dahin sucht die App nach Wörtern.

## Suche

`HybridRetriever` gibt jedem Abschnitt einen Wert aus zwei Signalen: `0,7 · Ähnlichkeit + 0,3 · Abdeckung`.

- **Ähnlichkeit:** `ContextualSentenceEmbedder` (Apples `NLContextualEmbedding`, Mittel aller Token, minus einer
  festen Hintergrundrichtung aus Alltagssätzen). Vektoren gibt es für Fenster von etwa 25 Wörtern, mehrere pro
  Abschnitt; ein Abschnitt zählt mit seinem besten Fenster. Gespeichert als 8-Bit-Matrix pro Notiz.
- **Abdeckung:** Anteil der Fragebegriffe im Abschnitt, gewichtet nach Seltenheit in der ganzen Bibliothek
  (geglättete IDF). BM25 entscheidet nur Gleichstände.

Ab 0,32 beantwortet ein Abschnitt die Frage; darunter erscheint nichts, und „Notizen fragen“ sagt, dass es nichts
gefunden hat. Ohne kalibrierte Vektoren (Modell nicht geladen, andere Schrift) zählt die Abdeckung allein, ab 0,22.
Vektoren tragen ihren Raum (Modell und Revision); er gehört zum Fingerabdruck einer Notiz, sodass ein neues Modell
alle Notizen neu indexiert. Wie die Werte gewählt und geprüft wurden, steht in [Quality.md](Quality.md).

**Fragen über mehrere Notizen.** „Was wurde mit Samsung bisher entschieden?“ oder „Welche Aufgaben aus den
Meetings mit Anna sind offen?“ beantworten wenige beste Stellen nur scheinbar vollständig. Erkennen Regeln
(„bisher“, „insgesamt“, „entwickelt“, „Meetings“ …) oder der Suchplan des Sprachmodells eine solche Frage und
passen mindestens zwei Notizen, liest `CrossNoteAnswering` die bis zu sechs besten einzeln: Kontext pro Notiz ist
ihre Zusammenfassung (deckt die ganze Notiz ab) plus ihre passenden Abschnitte. Passt alles in eine Anfrage, sind
das die Quellen; sonst zieht das Modell pro Notiz heraus, was sie zur Frage sagt (Map), Punkte ohne gemeinsames
Inhaltswort mit der Notiz fallen weg (`SummaryGrounding`), und eine Notiz, an der das Modell scheitert, trägt ihre
beste Stelle bei. Eine letzte Anfrage führt die Notizen ältester zuerst zusammen (Reduce), nennt Änderungen mit
Datum und zitiert jede Notiz; die Quellkarte zeigt die beste Stelle der Notiz im Wortlaut. Weitere Treffer,
Fehlschläge und gekürzte Funde nennt der Hinweis unter der Antwort. „Fasse alle … zusammen“ bleibt die
Sammelzusammenfassung, die jede Notiz vollständig liest.

Verwandte Notizen vergleichen die Mittelwertvektoren nach Abzug des Mittels aller Notizen: Transkripte ähneln
einander mehr als allem anderen, entscheidend ist, was zwei Notizen darüber hinaus teilen.

## Sprecher

`SpeakerStep` sammelt drei Hinweise und überlässt die Zuordnung `SpeakerAttribution` (pro Wort, Segmente
werden am Sprecherwechsel geteilt):

1. Audioquelle bei „Mikrofon + Systemton“ (`SourceActivity`): Mikrofon → „Ich“, Systemton → die andere
   Seite. Gewinnt immer.
2. Sprechertrennung (`SpeakerDetection`): neuronal (`NeuralSpeakerDiarizer`, FluidAudio-Offline-Pipeline)
   oder ohne Modell die einfache spektrale (`SpeakerDiarizer`). Die neuronale liefert pro Stimme einen
   L2-normierten Stimmabdruck.
3. Wiedererkennung (`VoiceRecognition`): Kosinus-Ähnlichkeit zu den gemerkten Stimmen (`VoiceProfile`),
   eindeutig zugeordnet ab 0,55 (gemessen: gleiche Stimme 0,85–0,94, verschiedene 0,06–0,42).

Korrekturen (`SpeakerDirectory`) markieren das Transkript als bearbeitet (`transcriptEditedAt`); der
Schritt läuft danach erst wieder beim erneuten Transkribieren. „Stimme merken“ lernt den Abdruck in das
Profil des Namens (gewichtetes Mittel), überschreibt aber nie ein anderes Profil.

## Daten

- **Schema V5:** gemerkte Stimmen (`VoiceProfile`), eigene Vorlagen (`SummaryTemplate`), Sprecher einer
  Notiz mit Stimmabdrücken (`Note.speakersData`), Vorlage einer Notiz und Bearbeitungsstand des
  Transkripts. Nur neue Entitäten und optionale Attribute: leichtgewichtige Migration.

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
| Echte Modelle (Sprecher, Parakeet) | `NotifyAITests/NeuralModelIntegrationTests.swift` | nur mit Fixtures unter `~/Library/Caches/NotifyAINeuralFixtures`, sonst übersprungen |
| Abläufe und Barrierefreiheit | `NotifyAIUITests` | `scripts/ci.sh ui` |

Tests warten auf Ereignisse (Observation, `EventChannel`, Gates), nie auf feste Zeiten.
