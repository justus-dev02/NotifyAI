//
//  RecorderViewModel.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

@MainActor
final class RecorderViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var liveText = ""
    @Published var note: Note

    private let sl = ServiceLocator.shared
    private var audioURL: URL

    init(note: Note) {
        self.note = note
        audioURL = ServiceLocator.shared.storage.temporaryAudioURL(for: note.id)
    }

    func start(consent: ConsentLog?) {
        note.consent = consent
        do {
            try sl.recorder.start(to: audioURL)
            isRecording = true
            note.pipeline.stage = .transcribing
            Task { try? await sl.transcription.startStreaming { [weak self] text, _, _ in
                await MainActor.run {
                    self?.liveText = text
                }
            }}
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

        Task { await sl.pipeline.enqueue(noteId: note.id, audio: audioURL) }
    }
}
