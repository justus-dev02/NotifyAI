//
//  WhisperBackend.swift
//  NotifyAI
//
//  Created by OpenAI Assistant on 05.10.23.
//  Updated for Real WhisperKit Neural Engine Execution & Streaming.
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
    private var liveAudioBuffer: [Float] = []
    private var liveStreamHandler: TranscriptionService.TranscriptHandler?
    private var lastDecodedLength: Int = 0
    private var isProcessingChunk = false
    #endif

    private init() {}

    #if canImport(WhisperKit)
    func getPipeline() async throws -> WhisperKit {
        if let pipeline = pipeline {
            return pipeline
        }
        let kit = try await WhisperKit(
            model: selectedModel.rawValue,
            computeOptions: ModelComputeOptions(
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            )
        )
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

    /// Starts live streaming audio recognition.
    func start(handler: @escaping TranscriptionService.TranscriptHandler) async throws {
        #if canImport(WhisperKit)
        _ = try await getPipeline()
        self.liveStreamHandler = handler
        self.liveAudioBuffer.removeAll()
        self.lastDecodedLength = 0
        self.isProcessingChunk = false
        #else
        throw NSError(domain: "WhisperBackend", code: -1, userInfo: [NSLocalizedDescriptionKey: "WhisperKit framework ist nicht verfügbar."])
        #endif
    }

    /// Appends incoming audio PCM buffers and processes live speech chunks
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        #if canImport(WhisperKit)
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
        liveAudioBuffer.append(contentsOf: samples)
        
        // Every ~2.5 seconds of 16kHz audio (40,000 samples) and not currently decoding
        if liveAudioBuffer.count - lastDecodedLength >= 40000 && !isProcessingChunk {
            isProcessingChunk = true
            let currentSamples = liveAudioBuffer
            lastDecodedLength = currentSamples.count
            
            Task {
                if let pipe = self.pipeline {
                    if let results = try? await pipe.transcribe(audioArray: currentSamples) {
                        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            DispatchQueue.main.async {
                                self.liveStreamHandler?(text, nil, nil)
                            }
                        }
                    }
                }
                self.isProcessingChunk = false
            }
        }
        #endif
    }

    func stop() {
        #if canImport(WhisperKit)
        liveStreamHandler = nil
        liveAudioBuffer.removeAll()
        lastDecodedLength = 0
        isProcessingChunk = false
        #endif
    }
}
