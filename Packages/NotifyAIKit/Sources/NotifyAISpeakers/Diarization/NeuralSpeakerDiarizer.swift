//
//  NeuralSpeakerDiarizer.swift
//  NotifyAISpeakers
//

import Accelerate
import CoreML
import FluidAudio
import Foundation
import NotifyAICore
import NotifyAINeuralModels
import NotifyAISupport
import OSLog

/// Speaker diarization with neural models on the Neural Engine (FluidAudio's offline pipeline,
/// the Core ML port of pyannote): powerset segmentation in 10 s windows, a WeSpeaker voice
/// embedding per speaker and window, PLDA scoring and VBx clustering.
///
/// Besides the turns it returns a voice print per speaker: the duration-weighted mean of the
/// speaker's embeddings, L2-normalized. Voice prints of the same person in different
/// recordings are close (cosine similarity), which `VoiceRecognition` uses to put names on
/// speakers.
///
/// The models are loaded only from the downloaded folder, never fetched implicitly; without
/// them diarization throws `NeuralModelError.notInstalled`. The file is converted to 16 kHz
/// into a memory-mapped temporary file (4 bytes per sample) instead of being loaded, so a long
/// recording needs disk space, not memory.
package struct NeuralSpeakerDiarizer: SpeakerDiarizing, NeuralModelUsage {
    package let model = NeuralSpeechModel.speakers
    private let store: NeuralModelStore
    private let models: LoadedModel<OfflineDiarizerModels>

    package init(store: NeuralModelStore) {
        self.store = store
        models = LoadedModel(name: "speaker") {
            try Self.loadModels(from: store)
        }
    }

    var isInstalled: Bool { store.isInstalled(model) }
    package var isInUse: Bool { get async { await models.isInUse } }

    package func unloadModel() async {
        await models.unload()
    }

    package func diarize(audioAt url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Diarization {
        guard isInstalled else { throw NeuralModelError.notInstalled(model) }
        progress(0)
        let result = try await models.use { loaded in
            try await BackgroundWork.run(priority: .utility) {
                let manager = OfflineDiarizerManager(config: .default)
                manager.initialize(models: loaded)
                return try await manager.process(url) { processed, total in
                    progress(0.95 * Double(processed) / Double(max(total, 1)))
                }
            }
        }
        try Task.checkCancellation()
        let diarization = Self.diarization(from: result.segments.map {
            DiarizedSegment(speakerID: $0.speakerId, start: TimeInterval($0.startTimeSeconds), end: TimeInterval($0.endTimeSeconds), embedding: $0.embedding)
        })
        progress(1)
        return diarization
    }

    /// One segment of FluidAudio's result, without its types.
    package struct DiarizedSegment: Sendable {
        let speakerID: String
        let start: TimeInterval
        let end: TimeInterval
        let embedding: [Float]
    }

    /// Turns and voice prints from the segments. Speakers are numbered by their first
    /// appearance; a speaker with less than `minimumSpeech` in total is noise (a cough, a
    /// door) and is left out.
    package static func diarization(from segments: [DiarizedSegment], minimumSpeech: TimeInterval = 1) -> Diarization {
        let byStart = segments.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        let durations = Dictionary(grouping: byStart, by: \.speakerID).mapValues { $0.reduce(0) { $0 + $1.end - $1.start } }
        let kept = byStart.filter { durations[$0.speakerID, default: 0] >= minimumSpeech }

        var numbers: [String: Int] = [:]
        var turns: [SpeakerTurn] = []
        var sums: [Int: [Float]] = [:]
        for segment in kept {
            let speaker = numbers[segment.speakerID] ?? {
                let number = numbers.count
                numbers[segment.speakerID] = number
                return number
            }()
            if var last = turns.last, last.speaker == speaker, segment.start <= last.end + 0.5 {
                last.end = max(last.end, segment.end)
                turns[turns.count - 1] = last
            } else {
                turns.append(SpeakerTurn(start: segment.start, end: segment.end, speaker: speaker))
            }
            if !segment.embedding.isEmpty {
                let weighted = vDSP.multiply(Float(segment.end - segment.start), segment.embedding)
                sums[speaker] = sums[speaker].map { vDSP.add($0, weighted) } ?? weighted
            }
        }
        // Also with a single voice: it is not told apart from others, but it can be recognized.
        return Diarization(turns: turns, voicePrints: sums.compactMapValues(VoicePrint.normalized))
    }

    // MARK: - Models

    /// Loads the models from the downloaded folder only. Mirrors FluidAudio's own loader
    /// (`OfflineDiarizerModels.load`), which would download missing or damaged files.
    package func verifyDownload() throws {
        _ = try Self.loadModels(from: store)
    }

    static func loadModels(from store: NeuralModelStore) throws -> OfflineDiarizerModels {
        guard let folder = store.folder(for: .speakers) else { throw NeuralModelError.notInstalled(.speakers) }
        let start = Date()
        func load(_ file: String, units: MLComputeUnits) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            return try MLModel(contentsOf: folder.appending(path: file), configuration: configuration)
        }
        let names = ModelNames.OfflineDiarizer.self
        return OfflineDiarizerModels(
            segmentationModel: try load(names.segmentationFile, units: .all),
            // The filter bank is fastest on the CPU.
            fbankModel: try load(names.fbankFile, units: .cpuOnly),
            embeddingModel: try load(names.embeddingFile, units: .all),
            pldaRhoModel: try load(names.pldaRhoFile, units: .all),
            pldaPsi: try pldaPsi(at: folder.appending(path: names.pldaParameters)),
            compilationDuration: Date().timeIntervalSince(start)
        )
    }

    /// The PLDA eigenvalues ("psi").
    static func pldaPsi(at url: URL) throws -> [Double] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let parameters = try decoder.decode(PLDAParameters.self, from: Data(contentsOf: url))
        guard let encoded = parameters.tensors["psi"]?.dataBase64,
              let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              data.count >= MemoryLayout<Float>.size
        else {
            throw NeuralModelError.notInstalled(.speakers)
        }
        var floats = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return floats.map(Double.init)
    }
}

/// `plda-parameters.json`: named tensors, each a base64 float32 array.
private struct PLDAParameters: Decodable {
    /// `data_base64` in the file (snake case).
    struct Tensor: Decodable {
        let dataBase64: String
    }

    let tensors: [String: Tensor]
}

/// Voice prints: L2-normalized speaker embeddings.
enum VoicePrint {
    static func normalized(_ vector: [Float]) -> [Float]? {
        let length = sqrt(vDSP.sumOfSquares(vector))
        guard length > 0, length.isFinite else { return nil }
        return vDSP.divide(vector, length)
    }

    /// Cosine similarity of two voice prints (-1…1; same person ≈ 0.5 and above).
    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        return vDSP.dot(a, b)
    }
}
