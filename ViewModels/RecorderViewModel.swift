//
//  RecorderViewModel.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//  Updated for Consolidated CoreAudio & Complete Pipeline Execution.
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class RecorderViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var liveText = ""
    @Published var note: Note
    @Published var bookmarks: [RecorderBookmark] = []
    @Published private var elapsed: TimeInterval = 0
    @Published var isRealTimeTranscriptionEnabled = true
    @Published var amplitudes: [Float] = Array(repeating: 0.08, count: 30)

    var timerDisplay: String {
        timeString(elapsed)
    }

    var levelDisplay: String {
        isRecording ? "Aktiv" : "--"
    }

    var diarizationStatus: String {
        "Aktiv"
    }

    private let sl = ServiceLocator.shared
    private var audioURL: URL
    private var timer: Timer?

    var backendDisplayName: String {
        sl.transcription.backend.displayName
    }
    
    init(note: Note) {
        self.note = note
        self.audioURL = ServiceLocator.shared.storage.temporaryAudioURL(for: note.id)
    }
    
    func start(consent: ConsentLog?) async {
        note.consent = consent
        if let consent {
            note.participants = consent.participants.map { Participant(name: $0, role: "") }
            note.location = consent.location
        }
        
        do {
            // Set up buffer consumer to route live buffers to the active STT engine
            sl.recorder.bufferConsumer = { [weak self] buffer in
                self?.sl.transcription.appendAudioBuffer(buffer)
            }
            
            // Set up amplitude callback for waveform visualization
            sl.recorder.amplitudeCallback = { [weak self] amp in
                let scaled = min(1.0, max(0.08, amp * 12.0))
                withAnimation(.easeOut(duration: 0.08)) {
                    guard let self = self else { return }
                    if !self.amplitudes.isEmpty {
                        self.amplitudes.removeFirst()
                        self.amplitudes.append(scaled)
                    }
                }
            }
            
            // Start audio recording
            try sl.recorder.start(to: audioURL)
            isRecording = true
            isPaused = false
            note.pipeline.stage = .transcribing
            startTimer()

            // Start live streaming transcription
            if isRealTimeTranscriptionEnabled {
                liveText = ""
                try await sl.transcription.startStreaming { [weak self] text, _, _ in
                    self?.liveText = text
                }
            }
        } catch {
            print("Fehler beim Starten der Aufnahme/Transkription: \(error)")
            stop()
        }
    }

    func pause() {
        sl.recorder.pause()
        isPaused = true
    }

    func resume() {
        sl.recorder.resume()
        isPaused = false
    }

    func stop() {
        let dur = sl.recorder.stop()
        isRecording = false
        isPaused = false
        note.duration = dur
        note.audioURL = audioURL

        sl.transcription.stop()
        stopTimer()

        // Always save note and run the pipeline to generate summaries, action items & mindmap
        Task {
            await sl.storage.save(note)
            await sl.pipeline.enqueue(noteId: note.id, audio: audioURL)
        }
    }

    func addBookmark(label: String) {
        let timecode = timeString(elapsed)
        let contextText = liveText.isEmpty ? "" : String(liveText.suffix(60))
        let bookmark = RecorderBookmark(label: label, icon: "bookmark.fill", timecode: timecode, context: contextText)
        bookmarks.append(bookmark)
    }

    func addParticipant() {
        let newParticipant = Participant(
            name: "Teilnehmer \(note.participants.count + 1)",
            role: ""
        )
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

struct RecorderBookmark: Identifiable {
    let id = UUID()
    var label: String
    var icon: String = "bookmark.fill"
    var timecode: String
    var context: String?
}
