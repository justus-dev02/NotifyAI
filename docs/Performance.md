# Performance und Energie

Wie NotifyAI Rechenzeit, Speicher und Akku schont, wie das gemessen wird und welche Werte gemessen wurden.

## Messumgebung

| | |
|---|---|
| Gerät | MacBook Pro, Apple M3 Pro, 18 GB RAM |
| System | macOS 27.0, Xcode 27.0 |
| Build | Debug (Tests), Werte aus `NotifyAITests/PerformanceBenchmarks.swift`, Mittelwert aus 5 Läufen |
| Datum | 29.09.2026 |

Release-Builds sind schneller. Die Werte eignen sich zum Vergleich von Änderungen, nicht als absolute Zusage.

## Gemessene Werte

| Messung | Ergebnis | Einordnung |
|---|---|---|
| Echtzeit-Callback (Mikrofon + Systemton, 512 Frames bei 48 kHz) | **0,86 µs** pro Zyklus (10.000 Zyklen: 8,6 ms) | Ein Zyklus dauert 10,7 ms: der Audio-Thread ist zu < 0,01 % belegt. Keine Allokation, kein Lock, kein Datei-I/O. |
| Verarbeitung von 60 s Meeting-Audio (Resampling beider Quellen, Mischen, Pegel, Quellaktivität, AAC-Kodierung, CAF schreiben) | **0,60 s CPU** | ≈ 1 % eines Kerns während der Aufnahme, ≈ 100× schneller als Echtzeit. Läuft auf der Verarbeitungs-Queue, nicht im Echtzeit-Thread. |
| Suchindex: 500 unveränderte Notizen prüfen (Fingerprint über `contentRevision`) | **33 ms**, Spitzenspeicher **44 MB** | Die Texte (500 × 100 KB) werden nicht geladen. |
| Zum Vergleich: dieselben 500 Notizen, Text wird gelesen (bisheriges Verfahren) | 46 ms, Spitzenspeicher **119 MB** | Das bisherige Verfahren lud bei jeder Aktualisierung alle Texte (+75 MB Spitzenspeicher). |
| Aufgabenübersicht: 500 Zusammenfassungen / 2.000 Aufgaben aktualisieren, nichts geändert | **18 ms** | Nur geänderte Zusammenfassungen werden dekodiert. |

### Vorher / nachher: Echtzeit-Thread

Vorher liefen Resampling, Mischen, AAC-Kodierung und das Schreiben der Datei **im Audio-Callback** unter einem Mutex.
Das waren pro Zyklus rechnerisch dieselben ≈ 107 µs (0,60 s CPU ÷ 5.625 Zyklen pro Minute), plus Allokationen und
Datei-I/O. Eine blockierende Platte (Time Machine, Spotlight) hielt damit den Audio-Thread an und erzeugte Aussetzer.
Jetzt kopiert der Callback in 0,86 µs in einen lock-freien Ringpuffer (15 s Reserve). Alles Weitere läuft alle 100 ms
auf einer eigenen Queue, bei unsichtbarem Pegelmesser alle 500 ms.

## Was Energie spart

| Maßnahme | Wirkung |
|---|---|
| Ringpuffer + Verarbeitungs-Queue (`SampleRingBuffer`, `AudioCaptureContext`) | Audio-Thread nahezu unbelastet; Verarbeitung gebündelt alle 100 ms statt pro Callback (~100×/s). |
| Pegel nur bei sichtbarem Messgerät (`onScreenVisibilityChange`, `RecordingController.setMeterVisible`) | Ohne sichtbaren Pegel 1 statt 10 Main-Thread-Weckungen pro Sekunde; Timer mit 500 ms und großzügiger Toleranz. |
| Zeit als `elapsedSeconds` | Menüleiste, Timer und Statusleiste rendern 1× statt 10× pro Sekunde. |
| Live-Transkript als `LazyVStack` aus unveränderlichen Zeilen | Nur sichtbare Zeilen werden gelayoutet; nur die volatile Zeile rendert neu. Unsichtbar wird gar nichts beobachtet. |
| Events statt Polling | App-Liste (NSWorkspace + Core-Audio-Listener), Lautsprecher-Hinweis (Ausgabegerät + Datenquelle), Thermalzustand (`thermalStateDidChangeNotification`). Vorher: alle 2 s bzw. 10 s. |
| Wiedergabeposition nur bei sichtbarer Detailansicht | Ticker (10 Hz) pausiert, Wiedergabe läuft weiter. |
| Whisper-Modell entladen | 2 min nach letzter Nutzung und sofort bei Speicherdruck (`DispatchSource.makeMemoryPressureSource`), nie während einer Transkription. Spart mehrere hundert MB. |
| Live-Transkript mit Obergrenze (60 s Rückstand) | Bei zu langsamer Spracherkennung wird die Datei nach der Aufnahme transkribiert; der Speicher wächst nicht unbegrenzt. |
| `NoteContent` (Schema V3) | Die Bibliothek lädt keine Volltexte mehr; die Suche läuft über die Relation in der Datenbank. |
| Float16-Vektoren im Suchindex | Halbe Indexgröße auf der Platte, halbe Lesezeit beim Start. |
| `ProcessInfo.beginActivity` während der Aufnahme (macOS) | App Nap drosselt die Aufnahme nicht, kein Ruhezustand durch Inaktivität. Endet mit der Aufnahme. |

## Selbst messen

### Automatisch (Benchmarks)

```sh
xcodebuild -scheme NotifyAI -destination 'platform=macOS' test -only-testing:NotifyAITests/PerformanceBenchmarks
```

Für eine Baseline im Test-Navigator den Benchmark wählen und „Set Baseline“ klicken. Danach schlägt der Test fehl,
wenn eine Änderung ihn messbar verschlechtert.

### Instruments

Die App setzt Signposts (`Signposts` in `Services/Logging.swift`, Subsystem = Bundle-ID):

| Kategorie | Intervall |
|---|---|
| `Capture` | „Process captured audio“: ein Durchlauf der Verarbeitungs-Queue |
| `Transcription` | „Whisper chunk“: ein Live-Abschnitt |
| `Processing` | „Transcribe file“, „Identify speakers“, „Summarize“ |
| `Knowledge` | „Refresh index“ |

Empfohlene Sitzungen (Release-Build, Profile-Schema):

1. **Aufnahme, 30 min, Fenster sichtbar und dann minimiert.** Vorlage *Time Profiler* + *os_signpost* + *Points of
   Interest*. Erwartung: „Process captured audio“ im 100-ms-Takt, im minimierten Zustand im 500-ms-Takt. Der Thread
   `com.apple.audio.IOThread` bzw. der Engine-Tap-Thread zeigt praktisch keine Samples.
2. **Nur Menüleiste, 30 min.** Vorlage *Energy Log* (macOS: *Activity Monitor* → Spalte „Energy Impact“ / „12 hr Power“
   ergänzend). Erwartung: niedriger Energy Impact, kein App Nap während der Aufnahme.
3. **Speicher.** Vorlage *Allocations* + *Leaks*: Aufnahme mit Whisper, danach 2 min warten. Erwartung: Das Modell
   (mehrere hundert MB) wird freigegeben („Unloading the Whisper model (idle)“ im Log).
4. **Festplatte.** Vorlage *File Activity*: Die Aufnahme schreibt etwa alle 100 ms kleine AAC-Blöcke. Der Suchindex
   schreibt nach einer Verarbeitung nur die Datei der geänderten Notiz.
5. **iPhone (Gerät, nicht Simulator).** Vorlage *Energy Log* bzw. Xcode → Debug-Navigator → Energy Impact während
   einer Hintergrundaufnahme mit gesperrtem Bildschirm.

### Im Feld

`MetricsCollector` speichert die täglichen MetricKit-Berichte (Starts, Hänger, CPU, Speicher, Festplattenschreibvorgänge,
Energie; Absturz- und Hänger-Diagnosen) unter `Application Support/NotifyAI/Diagnostics`. Nichts wird hochgeladen. Der
Diagnosebericht (Einstellungen → „Diagnosebericht exportieren …“) enthält sie zusammen mit dem Protokoll der Sitzung.
