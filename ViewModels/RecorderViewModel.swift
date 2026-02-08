//
//  RecorderViewModel.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class RecorderViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var liveText = "" // <- Hinzugefügt: Für Live-Transkriptionstext
    @Published var note: Note
    @Published var bookmarks: [RecorderBookmark] = []
    @Published private var elapsed: TimeInterval = 0
    @Published var isRealTimeTranscriptionEnabled = true // <- Hinzugefügt: Steuert den Modus

    var timerDisplay: String {
        timeString(elapsed)
    }

    var levelDisplay: String {
        isRecording ? "0 dB" : "--"
    }

    var diarizationStatus: String {
        // For now, return a default status since we can't access settings
        // In a real implementation, you'd need to access settings differently
        return "Inaktiv"  // Default to inactive
    }

    private let sl = ServiceLocator.shared
    private var audioURL: URL
    private var timer: Timer?

    var backendDisplayName: String {
        sl.transcription.backend.displayName
    }
    
    init(note: Note) {
        self.note = note
        audioURL = ServiceLocator.shared.storage.temporaryAudioURL(for: note.id)
        // Setze den Backend-Typ im TranscriptionService basierend auf der Einstellung
        sl.transcription.backend = .appleSpeech // Oder basierend auf SettingsViewModel
    }
    
    func start(consent: ConsentLog?) async {
        note.consent = consent
        if let consent {
            note.participants = consent.participants.map { Participant(name: $0, role: "") }
            note.location = consent.location
        }
        do {
            // Immer Audio aufnehmen
            try sl.recorder.start(to: audioURL)
            isRecording = true
            note.pipeline.stage = .transcribing // Zeigt an, dass Transkription geplant ist
            startTimer()

            // Nur bei Live-Modus die Streaming-Transkription starten
            if isRealTimeTranscriptionEnabled && sl.transcription.backend == .appleSpeech {
                liveText = "" // Text zurücksetzen
                try await sl.transcription.startStreaming { [weak self] text, _, _ in
                    // Update liveText auf dem MainActor (bereits sichergestellt durch ViewModel)
                    self?.liveText = text
                }
            } else if isRealTimeTranscriptionEnabled && sl.transcription.backend == .whisperKit {
                 liveText = "" // Text zurücksetzen
                 // Ggf. WhisperKit Streaming starten (wenn implementiert)
                 print("WhisperKit Streaming gestartet (Implementierung ausstehend)")
                 try await sl.transcription.startStreaming { [weak self] text, _, _ in
                    self?.liveText = text
                 }
            }

        } catch {
            print("Fehler beim Starten der Aufnahme/Transkription: \(error)")
            // Fehlerbehandlung hinzufügen (z.B. dem User anzeigen)
            stop() // Aufnahme stoppen bei Fehler
        }
    }

    func pause() {
        sl.recorder.pause()
        isPaused = true
        // Optional: Pausiere auch das Streaming, falls das Backend es unterstützt
         if isRealTimeTranscriptionEnabled {
             // AppleSpeechBackend hat keine Pause-Funktion, WhisperKit evtl.?
             // sl.transcription.pause() // Wenn verfügbar
         }
    }

    func resume() {
        sl.recorder.resume()
        isPaused = false
        // Optional: Fortsetzen des Streamings
        // if isRealTimeTranscriptionEnabled {
        //     sl.transcription.resume() // Wenn verfügbar
        // }
    }

    func stop() {
        let dur = sl.recorder.stop()
        isRecording = false
        note.duration = dur
        note.audioURL = audioURL

        // Transkription immer stoppen, egal ob Live oder nicht
        sl.transcription.stop()
        stopTimer()

        // Nur Pipeline starten, wenn *nicht* Live-AppleSpeech genutzt wurde (da Text schon da ist)
        // Oder wenn WhisperKit verwendet wird (weil es evtl. noch nachbearbeitet)
        // Oder wenn es eine reine Audioaufnahme war.
        if !isRealTimeTranscriptionEnabled || sl.transcription.backend == .whisperKit {
             Task { await sl.pipeline.enqueue(noteId: note.id, audio: audioURL) }
        } else if isRealTimeTranscriptionEnabled && sl.transcription.backend == .appleSpeech {
            // Bei Live Apple Speech: Füge den finalen Text direkt als Segment hinzu
            let finalSegment = TranscriptSegment(start: 0, end: dur, speakerId: nil, text: liveText)
            note.segments = [finalSegment]
            // Setze Pipeline auf 'fertig', da keine weitere Bearbeitung nötig
            note.pipeline.stage = .done
            note.pipeline.progress = 1.0
            Task { await sl.storage.save(note) } // Speichere die Note mit Segment & Status
            print("Live Apple Speech beendet. Finaler Text: \(liveText)")
        }
        liveText = "" // Live-Text zurücksetzen
    }


    // ... (restlicher Code bleibt gleich) ...
     func addBookmark(label: String) {
        let timecode = timeString(elapsed)
        // Füge auch den aktuellen Live-Text zum Bookmark hinzu, wenn verfügbar
        let contextText = liveText.isEmpty ? "" : String(liveText.suffix(50)) // Die letzten 50 Zeichen als Kontext
        let bookmark = RecorderBookmark(label: label, icon: "bookmark", timecode: timecode, context: contextText)
        bookmarks.append(bookmark)
    }

    func addParticipant() {
        // Create a new participant with a default name
        let newParticipant = Participant(
            name: "Neuer Teilnehmer",
            role: ""
            // Using default colorHex and avatarSymbol
        )

        // Add to the note's participants
        note.participants.append(newParticipant)
    }

    private func startTimer() {
        timer?.invalidate()
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.elapsed += 1
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func timeString(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// Ergänze RecorderBookmark um Kontext
struct RecorderBookmark: Identifiable {
    let id = UUID()
    var label: String
    var icon: String = "bookmark"
    var timecode: String
    var context: String? // Optionaler Text-Kontext zum Zeitpunkt des Bookmarks
}
