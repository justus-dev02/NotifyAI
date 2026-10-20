//
//  TranscriptionSettings.swift
//  NotifyAISettings
//

import Foundation
import NotifyAICore
import NotifyAISupport
import NotifyAITranscription
import Observation

/// Speech recognition: engine, language, Whisper model and live transcription.
@MainActor
@Observable
public final class TranscriptionSettings {
    private enum Key {
        static let engine = "transcription.engine"
        static let language = "transcription.language"
        static let whisperModel = "transcription.whisperModel"
        static let liveTranscription = "transcription.live"
        static let vocabulary = "transcription.vocabulary"
        static let removesFillerWords = "transcription.removesFillerWords"
    }

    @ObservationIgnored private let defaults: UserDefaults

    public var engine: TranscriptionEngineKind {
        didSet { defaults.set(engine.rawValue, forKey: Key.engine) }
    }

    public var language: TranscriptionLanguage {
        didSet { defaults.set(language.id, forKey: Key.language) }
    }

    public var whisperModel: WhisperModel {
        didSet { defaults.set(whisperModel.id, forKey: Key.whisperModel) }
    }

    /// Transcribe while recording. When off, the file is transcribed after the recording.
    public var liveTranscription: Bool {
        didSet { defaults.set(liveTranscription, forKey: Key.liveTranscription) }
    }

    /// Names and terms the recognizer should know (people, products, technical terms).
    public var vocabulary: [String] {
        didSet { defaults.set(vocabulary, forKey: Key.vocabulary) }
    }

    /// Removes "äh", "ähm" and similar fillers from new transcripts.
    public var removesFillerWords: Bool {
        didSet { defaults.set(removesFillerWords, forKey: Key.removesFillerWords) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        engine = defaults.string(forKey: Key.engine).flatMap(TranscriptionEngineKind.init(rawValue:)) ?? .appleSpeech
        language = defaults.string(forKey: Key.language).map(TranscriptionLanguage.init(id:)) ?? Self.defaultLanguage
        whisperModel = defaults.string(forKey: Key.whisperModel).flatMap(WhisperModel.withID) ?? .recommended
        liveTranscription = defaults.object(forKey: Key.liveTranscription) as? Bool ?? true
        vocabulary = defaults.stringArray(forKey: Key.vocabulary) ?? []
        removesFillerWords = defaults.bool(forKey: Key.removesFillerWords)
    }

    package var options: TranscriptionOptions {
        options(for: language)
    }

    package func options(for language: TranscriptionLanguage) -> TranscriptionOptions {
        TranscriptionOptions(language: language, whisperModel: whisperModel, vocabulary: CustomVocabulary(vocabulary))
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
