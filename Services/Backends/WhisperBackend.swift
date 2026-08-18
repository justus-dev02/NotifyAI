//
//  WhisperBackend.swift
//  NotifyAI
//
//  Created by OpenAI Assistant on 05.10.23.
//  Updated for WhisperKit On-Device Integration.
//

import Foundation
import AVFoundation

#if canImport(WhisperKit)
import WhisperKit
#endif

final class WhisperBackend {
    static let shared = WhisperBackend()

    enum WhisperModelVariant: String, CaseIterable, Identifiable {
        case tiny = "openai_whisper-tiny"
        case base = "openai_whisper-base"
        case small = "openai_whisper-small"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .tiny: return "Whisper Tiny (Ultraschnell, ~75 MB)"
            case .base: return "Whisper Base (Empfohlen, ~145 MB)"
            case .small: return "Whisper Small (Höchste Genauigkeit, ~460 MB)"
            }
        }
    }

    var selectedModel: WhisperModelVariant = .base {
        didSet {
            if oldValue != selectedModel {
                #if canImport(WhisperKit)
                pipeline = nil
                #endif
            }
        }
    }

    #if canImport(WhisperKit)
    private var pipeline: WhisperKit?
    private var isInitializing = false
    #endif

    private init() {}

    #if canImport(WhisperKit)
    func getPipeline() async throws -> WhisperKit {
        if let pipeline = pipeline {
            return pipeline
        }
        let kit = try await WhisperKit(model: selectedModel.rawValue)
        self.pipeline = kit
        return kit
    }
    #endif

    /// Transcribes an audio file at the given URL into structured transcript segments.
    func transcribe(audioURL: URL) async throws -> [TranscriptSegment] {
        #if canImport(WhisperKit)
        let pipe = try await getPipeline()
        let results: [TranscriptionResult] = try await pipe.transcribe(audioPath: audioURL.path)

        var segments: [TranscriptSegment] = []
        for result in results {
            for seg in result.segments {
                let clean = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty {
                    segments.append(TranscriptSegment(
                        start: TimeInterval(seg.start),
                        end: TimeInterval(seg.end),
                        speakerId: nil,
                        text: clean
                    ))
                }
            }
        }

        if segments.isEmpty {
            let combinedText = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !combinedText.isEmpty {
                let asset = AVURLAsset(url: audioURL)
                let duration = (try? await asset.load(.duration))?.seconds ?? 0
                segments.append(TranscriptSegment(start: 0, end: duration, speakerId: nil, text: combinedText))
            }
        }

        return segments
        #else
        throw NSError(domain: "WhisperBackend", code: -1, userInfo: [NSLocalizedDescriptionKey: "WhisperKit framework ist nicht verlinkt."])
        #endif
    }

    /// Transcribes raw 16kHz float audio samples into transcript segments.
    func transcribe(audioSamples: [Float]) async throws -> [TranscriptSegment] {
        #if canImport(WhisperKit)
        guard !audioSamples.isEmpty else { return [] }
        let pipe = try await getPipeline()
        let results: [TranscriptionResult] = try await pipe.transcribe(audioArray: audioSamples)

        var segments: [TranscriptSegment] = []
        for result in results {
            for seg in result.segments {
                let clean = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty {
                    segments.append(TranscriptSegment(
                        start: TimeInterval(seg.start),
                        end: TimeInterval(seg.end),
                        speakerId: nil,
                        text: clean
                    ))
                }
            }
        }
        return segments
        #else
        throw NSError(domain: "WhisperBackend", code: -1, userInfo: [NSLocalizedDescriptionKey: "WhisperKit framework ist nicht verlinkt."])
        #endif
    }

    /// Starts live streaming audio recognition if applicable.
    func start(handler: @escaping TranscriptionService.TranscriptHandler) async throws {
        #if canImport(WhisperKit)
        _ = try await getPipeline()
        // WhisperKit processes audio chunks as they arrive during recording
        #else
        throw NSError(domain: "WhisperBackend", code: -1, userInfo: [NSLocalizedDescriptionKey: "WhisperKit framework ist nicht verfügbar."])
        #endif
    }

    func stop() {
        // Cleanup if needed
    }
}
