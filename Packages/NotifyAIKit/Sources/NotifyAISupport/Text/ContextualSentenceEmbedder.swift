//
//  ContextualSentenceEmbedder.swift
//  NotifyAISupport
//

import Accelerate
import Foundation
import NaturalLanguage
import OSLog
import Synchronization

/// Whether the system's model for meaning vectors is on the device.
public enum EmbeddingModelStatus: Equatable, Sendable {
    case installed
    /// The system can download it (once, from Apple).
    case downloadable
    /// The language has no such model; search uses its simpler fallback.
    case unsupported
}

/// Embeddings whose model the system downloads on request.
package protocol EmbeddingModelAssets: Sendable {
    func modelStatus(for languageCode: String) -> EmbeddingModelStatus
    /// Downloads the model; returns whether it is available afterwards.
    func installModel(for languageCode: String) async throws -> Bool
}

/// Meaning vectors from Apple's contextual language model (`NLContextualEmbedding`).
///
/// Measured on `SearchEvaluationCorpus.json` (docs/Quality.md), vectors alone, 25 notes:
/// questions in other words than the note find it first in 50 % of cases, against 15 % with
/// `NLEmbedding.sentenceEmbedding`. Three choices make the difference, each measured:
/// - **Mean of all token vectors.** Leaving out stop words helps questions with the note's
///   own words but loses a third of the paraphrases; full text search covers the former.
/// - **Minus a fixed background.** The model's vectors share a common direction. Removing the
///   mean of everyday sentences unrelated to any note (`backgroundSentences`) separates topics;
///   removing the mean of the user's own notes hurt, and would be unstable for small libraries.
/// - **Short texts.** Callers embed about 25 words at a time; longer passages blur the one
///   statement a question is about.
///
/// One model covers all languages in Latin script, so their vectors are comparable (an English
/// question finds a German note, though less reliably). The model is a system download; until
/// it is installed, and for other scripts, `fallback` answers. The model needs about 80 MB of
/// memory and is released two minutes after its last use.
package final class ContextualSentenceEmbedder: SentenceEmbedding, EmbeddingModelAssets {
    /// The model and its background direction; the background is computed once per model.
    private struct Model {
        let embedding: NLContextualEmbedding
        var isLoaded = false
        var background: [Float]?
        var space: String { "contextual-\(embedding.modelIdentifier)-\(embedding.revision)" }
    }

    private struct State {
        /// Models by identifier; languages of one script share one model.
        var models: [String: Model] = [:]
        /// Model identifier per language code; `nil` marks a language without a model.
        var modelIDs: [String: String?] = [:]
        var lastUse = ContinuousClock.now
        var isUnloadScheduled = false
    }

    /// The model reads at most 256 tokens; chunks of this many words stay below it.
    static let maximumWordsPerChunk = 120
    static let idleTimeout = Duration.seconds(120)

    private let fallback: any SentenceEmbedding
    private let state = Mutex(State())
    private let logger = Logger.processing

    package init(fallback: any SentenceEmbedding = SentenceEmbedder()) {
        self.fallback = fallback
    }

    // MARK: - SentenceEmbedding

    package func vector(for text: String, languageCode: String) -> EmbeddingVector? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let result: EmbeddingVector?? = state.withLock { state in
            guard let id = Self.modelID(for: languageCode, state: &state),
                  var model = state.models[id],
                  model.embedding.hasAvailableAssets
            else { return .none }
            defer {
                state.models[id] = model
                state.lastUse = .now
            }
            do {
                if !model.isLoaded {
                    try model.embedding.load()
                    model.isLoaded = true
                }
                if model.background == nil {
                    model.background = try Self.background(of: model.embedding)
                }
                let language = NLLanguage(rawValue: languageCode)
                // As measured: normalize, remove the background, normalize again.
                guard let raw = try Self.meanVector(of: trimmed, language: language, embedding: model.embedding),
                      let unit = EmbeddingVector.normalized(raw),
                      let background = model.background
                else { return .some(nil) }
                return .some(EmbeddingVector.normalized(vDSP.subtract(unit, background)).map(EmbeddingVector.init))
            } catch {
                logger.error("Contextual embedding failed: \(error.localizedDescription, privacy: .public)")
                return .some(nil)
            }
        }
        scheduleUnload()
        // `.none`: no contextual model for this language, the fallback answers.
        guard let result else { return fallback.vector(for: trimmed, languageCode: languageCode) }
        return result
    }

    package func space(for languageCode: String) -> String? {
        let space: String? = state.withLock { state in
            guard let id = Self.modelID(for: languageCode, state: &state), let model = state.models[id],
                  model.embedding.hasAvailableAssets
            else { return nil }
            return model.space
        }
        return space ?? fallback.space(for: languageCode)
    }

    /// Whether vectors of `space` come from this model, whose similarities the search's
    /// thresholds were calibrated with.
    package static func isCalibrated(space: String) -> Bool {
        space.hasPrefix("contextual-")
    }

    // MARK: - EmbeddingModelAssets

    package func modelStatus(for languageCode: String) -> EmbeddingModelStatus {
        state.withLock { state in
            guard let id = Self.modelID(for: languageCode, state: &state), let model = state.models[id] else { return .unsupported }
            return model.embedding.hasAvailableAssets ? .installed : .downloadable
        }
    }

    package func installModel(for languageCode: String) async throws -> Bool {
        let embedding: NLContextualEmbedding? = state.withLock { state in
            Self.modelID(for: languageCode, state: &state).flatMap { state.models[$0]?.embedding }
        }
        guard let embedding else { return false }
        if embedding.hasAvailableAssets { return true }
        logger.info("Requesting the contextual embedding model for \(languageCode, privacy: .public)")
        let result = try await embedding.requestAssets()
        return result == .available
    }

    // MARK: - Model

    private static func modelID(for languageCode: String, state: inout State) -> String? {
        if let known = state.modelIDs[languageCode] {
            return known
        }
        let embedding = NLContextualEmbedding(language: NLLanguage(rawValue: languageCode))
        let id = embedding?.modelIdentifier
        if let embedding, let id, state.models[id] == nil {
            state.models[id] = Model(embedding: embedding)
        }
        state.modelIDs[languageCode] = id
        return id
    }

    /// The mean of the token vectors of `text`, without normalizing. Text longer than the
    /// model reads is embedded in chunks, weighted by their number of tokens.
    private static func meanVector(of text: String, language: NLLanguage, embedding: NLContextualEmbedding) throws -> [Float]? {
        var sum = [Float](repeating: 0, count: embedding.dimension)
        var count = 0
        for chunk in chunks(of: text) {
            let result = try embedding.embeddingResult(for: chunk, language: language)
            result.enumerateTokenVectors(in: chunk.startIndex..<chunk.endIndex) { vector, _ in
                guard vector.count == sum.count else { return true }
                sum = vDSP.add(sum, vector.map(Float.init))
                count += 1
                return true
            }
        }
        guard count > 0 else { return nil }
        return vDSP.divide(sum, Float(count))
    }

    static func chunks(of text: String) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > maximumWordsPerChunk else { return [text] }
        return stride(from: 0, to: words.count, by: maximumWordsPerChunk).map { start in
            words[start..<min(start + maximumWordsPerChunk, words.count)].joined(separator: " ")
        }
    }

    /// The common direction of the model's vectors: the mean over everyday sentences.
    private static func background(of embedding: NLContextualEmbedding) throws -> [Float] {
        var sum = [Float](repeating: 0, count: embedding.dimension)
        var count = 0
        for (sentence, language) in backgroundSentences {
            guard let vector = try meanVector(of: sentence, language: language, embedding: embedding),
                  let normalized = EmbeddingVector.normalized(vector)
            else { continue }
            sum = vDSP.add(sum, normalized)
            count += 1
        }
        return count > 0 ? vDSP.divide(sum, Float(count)) : sum
    }

    /// Everyday sentences about nothing a note is likely to be about. Changing them changes
    /// every vector: the space then gets a new name only if the model does, so the search
    /// index has to be rebuilt by hand (`KnowledgeIndex.formatVersion`).
    static let backgroundSentences: [(String, NLLanguage)] = [
        ("Ich gehe heute Abend noch einkaufen.", .german),
        ("Das Wetter soll am Wochenende besser werden.", .german),
        ("Kannst du mir kurz helfen?", .german),
        ("Wir sehen uns morgen früh im Büro.", .german),
        ("Der Zug hatte wieder zwanzig Minuten Verspätung.", .german),
        ("Hast du die E-Mail schon gelesen?", .german),
        ("Ich habe das Buch fast durch.", .german),
        ("Die Kinder schlafen schon.", .german),
        ("Lass uns später noch einmal telefonieren.", .german),
        ("Das Restaurant an der Ecke hat neu eröffnet.", .german),
        ("Ich muss noch die Wäsche aufhängen.", .german),
        ("Der Termin passt mir leider nicht.", .german),
        ("Wir haben gestern lange über das Thema gesprochen.", .german),
        ("Ich schicke dir die Unterlagen nachher.", .german),
        ("Das hat besser geklappt als gedacht.", .german),
        ("Im Garten blühen schon die ersten Blumen.", .german),
        ("Er hat sich für die Verspätung entschuldigt.", .german),
        ("Wie war dein Urlaub?", .german),
        ("Die Besprechung wurde auf Donnerstag verschoben.", .german),
        ("Ich trinke morgens immer einen Kaffee.", .german),
        ("I will call you back later today.", .english),
        ("The meeting was moved to Thursday.", .english),
        ("Can you send me the file?", .english),
        ("We had a long discussion about it yesterday.", .english),
        ("The weather is supposed to get better.", .english),
        ("Thanks for your help.", .english),
    ]

    // MARK: - Unloading

    /// Releases the models once they have not been used for `idleTimeout`.
    private func scheduleUnload() {
        let shouldStart = state.withLock { state in
            guard !state.isUnloadScheduled, state.models.values.contains(where: \.isLoaded) else { return false }
            state.isUnloadScheduled = true
            return true
        }
        guard shouldStart else { return }
        Task(priority: .utility) { [weak self] in
            while let self {
                let idleUntil = state.withLock { $0.lastUse + Self.idleTimeout }
                guard ContinuousClock.now >= idleUntil else {
                    try? await Task.sleep(until: idleUntil)
                    continue
                }
                state.withLock { state in
                    for id in state.models.keys where state.models[id]?.isLoaded == true {
                        state.models[id]?.embedding.unload()
                        state.models[id]?.isLoaded = false
                    }
                    state.isUnloadScheduled = false
                }
                logger.info("Unloaded the contextual embedding model (idle)")
                return
            }
        }
    }
}
