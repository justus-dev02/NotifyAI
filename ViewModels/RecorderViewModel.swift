//
//  RecorderViewModel.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import Combine
import Foundation

@MainActor
final class RecorderViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var liveText = ""
    @Published var note: Note
    @Published var bookmarks: [RecorderBookmark] = []
    @Published private var elapsed: TimeInterval = 0

    private let sl = ServiceLocator.shared
    private var audioURL: URL
    private var timer: Timer?

    init(note: Note) {
        self.note = note
        audioURL = ServiceLocator.shared.storage.temporaryAudioURL(for: note.id)
    }

    func start(consent: ConsentLog?) async {
        note.consent = consent
        if let consent {
            note.participants = consent.participants.map { Participant(name: $0, role: "") }
            note.location = consent.location
        }
        do {
            try sl.recorder.start(to: audioURL)
            isRecording = true
            note.pipeline.stage = .transcribing
            try await sl.transcription.startStreaming { [weak self] text, _, _ in
                self?.liveText = text
            }
            startTimer()
        } catch { print(error) }
    }

    func pause() { sl.recorder.pause(); isPaused = true }
    func resume() { sl.recorder.resume(); isPaused = false }

    func stop() {
        let dur = sl.recorder.stop()
        isRecording = false
        note.duration = dur
        note.audioURL = audioURL
        sl.transcription.stop()
        stopTimer()

        Task { await sl.pipeline.enqueue(noteId: note.id, audio: audioURL) }
    }

    func addBookmark(label: String) {
        let timecode = timeString(elapsed)
        let bookmark = RecorderBookmark(label: label, timecode: timecode)
        bookmarks.append(bookmark)
    }

    func addParticipant() {
        note.participants.append(Participant(name: "Gast", role: ""))
    }

    var timerDisplay: String { timeString(elapsed) }

    var levelDisplay: String { "Pegelaussteuerung stabil" }

    var diarizationStatus: String {
        isRecording ? "läuft" : "bereit"
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
    var icon: String = "bookmark"
    var timecode: String
}
