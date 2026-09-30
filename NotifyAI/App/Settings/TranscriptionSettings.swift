//
//  TranscriptionSettings.swift
//  NotifyAI
//

import Foundation
import NotifyAICore
import Observation

/// Speech recognition: engine, language, Whisper model and live transcription.
@MainActor
@Observable
final class TranscriptionSettings {
    private enum Key {
        static let engine = "transcription.engine"
        static let language = "transcription.language"
        static let whisperModel = "transcription.whisperModel"
        static let liveTranscription = "transcription.live"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var engine: TranscriptionEngineKind {
        didSet { defaults.set(engine.rawValue, forKey: Key.engine) }
    }

    var language: TranscriptionLanguage {
        didSet { defaults.set(language.id, forKey: Key.language) }
    }

    var whisperModel: WhisperModel {
        didSet { defaults.set(whisperModel.id, forKey: Key.whisperModel) }
    }

    /// Transcribe while recording. When off, the file is transcribed after the recording.
    var liveTranscription: Bool {
        didSet { defaults.set(liveTranscription, forKey: Key.liveTranscription) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        engine = defaults.string(forKey: Key.engine).flatMap(TranscriptionEngineKind.init(rawValue:)) ?? .appleSpeech
        language = defaults.string(forKey: Key.language).map(TranscriptionLanguage.init(id:)) ?? Self.defaultLanguage
        whisperModel = defaults.string(forKey: Key.whisperModel).flatMap(WhisperModel.withID) ?? .recommended
        liveTranscription = defaults.object(forKey: Key.liveTranscription) as? Bool ?? true
    }

    var options: TranscriptionOptions {
        TranscriptionOptions(language: language, whisperModel: whisperModel)
    }

    /// The system language if it is supported, German otherwise.
    private static var defaultLanguage: TranscriptionLanguage {
        let preferred = Locale.current.language
        return TranscriptionLanguage.all.first {
            $0.locale.language.languageCode == preferred.languageCode && $0.locale.region == preferred.region
        } ?? TranscriptionLanguage.all.first {
            $0.locale.language.languageCode == preferred.languageCode
        } ?? .german
    }
}
