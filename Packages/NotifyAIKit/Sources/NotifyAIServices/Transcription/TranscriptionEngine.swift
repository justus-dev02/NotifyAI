//
//  TranscriptionEngine.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore

/// Parameters for one transcription.
struct TranscriptionOptions: Sendable {
    var language: TranscriptionLanguage
    var whisperModel: WhisperModel
}

/// An update from a live transcription session.
enum LiveTranscriptionEvent: Sendable {
    /// Text that will not change any more.
    case finalized([TranscriptSegment])
    /// The current, still changing hypothesis for the audio after the last finalized segment.
    case volatile(String)
    /// Seconds of appended audio that still wait for transcription. Sessions that keep up
    /// with real time by design (Apple Speech) never report it.
    case backlog(TimeInterval)
}

/// Transcribes audio while it is being recorded.
///
/// The session receives exactly the audio that is written to the file, so the finalized
/// segments are the complete transcript and no second pass over the file is needed.
protocol LiveTranscriptionSession: Sendable {
    var events: AsyncStream<LiveTranscriptionEvent> { get }
    func append(_ chunk: AudioChunk) async
    /// Transcribes any remaining audio and returns the complete, final transcript.
    func finish() async throws -> [TranscriptSegment]
    func cancel() async
}

protocol TranscriptionEngine: Sendable {
    var kind: TranscriptionEngineKind { get }
    func startLiveSession(options: TranscriptionOptions) async throws -> any LiveTranscriptionSession
    /// Transcribes a finished audio file. `progress` receives values from 0 to 1.
    func transcribeFile(
        at url: URL,
        options: TranscriptionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment]
}

enum TranscriptionError: LocalizedError {
    case languageNotSupported(String)
    case speechAssetsUnavailable
    case whisperModelNotInstalled(String)
    case unreadableAudio

    var errorDescription: String? {
        switch self {
        case .languageNotSupported(let language):
            String(localized: "\(language) wird von der gewählten Spracherkennung nicht unterstützt.", bundle: .module)
        case .speechAssetsUnavailable:
            String(localized: "Das Sprachpaket für Apple Speech ist nicht verfügbar. Bitte prüfe die Internetverbindung für den einmaligen Download.", bundle: .module)
        case .whisperModelNotInstalled(let name):
            String(localized: "Das Whisper-Modell „\(name)“ ist noch nicht geladen. Du kannst es in den Einstellungen herunterladen.", bundle: .module)
        case .unreadableAudio:
            String(localized: "Die Audiodatei konnte nicht gelesen werden.", bundle: .module)
        }
    }
}

/// Resolves the engine for a kind. Views and coordinators depend on this instead of
/// concrete engines, which keeps them testable.
struct TranscriptionService: Sendable {
    let appleSpeech: any TranscriptionEngine
    let whisper: any TranscriptionEngine

    func engine(for kind: TranscriptionEngineKind) -> any TranscriptionEngine {
        switch kind {
        case .appleSpeech: appleSpeech
        case .whisper: whisper
        }
    }
}
