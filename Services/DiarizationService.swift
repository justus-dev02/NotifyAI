//
//  DiarizationService.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//  Updated for Chunked Streaming Acoustic Feature Extraction & Dynamic N-Speaker Clustering.
//

import Foundation
import AVFoundation
import Accelerate

final class DiarizationService {
    /// Acoustic feature signature representing a speaker's vocal characteristics in a speech turn
    struct VoiceSignature {
        var meanEnergy: Float
        var zeroCrossingRate: Float
        var spectralCentroid: Float
        var duration: TimeInterval
    }

    /// Diarizes an audio file by chunked acoustic feature extraction and dynamic multi-speaker clustering.
    func diarize(_ pcmURL: URL) async throws -> [(start: TimeInterval, end: TimeInterval, speakerId: String)] {
        guard FileManager.default.fileExists(atPath: pcmURL.path) else { return [] }

        return try await Task.detached(priority: .userInitiated) {
            guard let audioFile = try? AVAudioFile(forReading: pcmURL) else { return [] }
            let format = audioFile.processingFormat
            let sampleRate = Float(format.sampleRate > 0 ? format.sampleRate : 16000.0)
            let totalFrames = audioFile.length
            guard totalFrames > 0 else { return [] }

            // Read in chunks of 5 seconds (to keep memory footprint minimal < 2 MB)
            let chunkFrames = AVAudioFrameCount(sampleRate * 5.0)
            guard let chunkBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { return [] }

            let frameSize = Int(sampleRate * 0.04) // 40ms analysis window
            guard frameSize > 0 else { return [] }

            var speechTurns: [(start: TimeInterval, end: TimeInterval, signature: VoiceSignature)] = []
            var currentTurnStart: TimeInterval = 0
            var currentSignatures: [VoiceSignature] = []
            var inSpeech = false
            var silenceFrames = 0
            var processedFrames: Int64 = 0

            while audioFile.framePosition < totalFrames {
                let framesToRead = AVAudioFrameCount(min(Int64(chunkFrames), totalFrames - audioFile.framePosition))
                guard framesToRead > 0 else { break }

                try? audioFile.read(into: chunkBuffer, frameCount: framesToRead)
                let actualFrames = Int(chunkBuffer.frameLength)
                guard actualFrames > 0, let channelData = chunkBuffer.floatChannelData?[0] else { break }

                var offset = 0
                while offset + frameSize <= actualFrames {
                    let globalFrameIndex = processedFrames + Int64(offset)
                    let time = Double(globalFrameIndex) / Double(sampleRate)
                    let framePointer = channelData.advanced(by: offset)

                    // 1. RMS Energy calculation
                    var rms: Float = 0
                    vDSP_rmsqv(framePointer, 1, &rms, vDSP_Length(frameSize))

                    // 2. Zero-Crossing Rate
                    var zcrCount = 0
                    for i in 1..<frameSize {
                        if (framePointer[i] >= 0 && framePointer[i - 1] < 0) ||
                           (framePointer[i] < 0 && framePointer[i - 1] >= 0) {
                            zcrCount += 1
                        }
                    }
                    let zcr = Float(zcrCount) / Float(frameSize)

                    // 3. Spectral Energy Centroid Approximation
                    var weightedSum: Float = 0
                    var totalMag: Float = 0
                    for i in 0..<frameSize {
                        let val = abs(framePointer[i])
                        weightedSum += Float(i) * val
                        totalMag += val
                    }
                    let centroid = totalMag > 0.001 ? (weightedSum / totalMag) * (sampleRate / Float(frameSize)) : 0

                    let sig = VoiceSignature(
                        meanEnergy: rms,
                        zeroCrossingRate: zcr,
                        spectralCentroid: centroid,
                        duration: Double(frameSize) / Double(sampleRate)
                    )

                    let isVoice = rms > 0.015 // Speech threshold

                    if isVoice {
                        if !inSpeech {
                            inSpeech = true
                            currentTurnStart = time
                            currentSignatures.removeAll()
                        }
                        currentSignatures.append(sig)
                        silenceFrames = 0
                    } else {
                        silenceFrames += 1
                        // 400ms pause indicates a turn boundary
                        if inSpeech && silenceFrames >= 10 {
                            let turnEnd = time
                            if turnEnd - currentTurnStart >= 0.6 && !currentSignatures.isEmpty {
                                let avgEnergy = currentSignatures.map(\.meanEnergy).reduce(0, +) / Float(currentSignatures.count)
                                let avgZcr = currentSignatures.map(\.zeroCrossingRate).reduce(0, +) / Float(currentSignatures.count)
                                let avgCentroid = currentSignatures.map(\.spectralCentroid).reduce(0, +) / Float(currentSignatures.count)

                                let turnSig = VoiceSignature(
                                    meanEnergy: avgEnergy,
                                    zeroCrossingRate: avgZcr,
                                    spectralCentroid: avgCentroid,
                                    duration: turnEnd - currentTurnStart
                                )
                                speechTurns.append((start: currentTurnStart, end: turnEnd, signature: turnSig))
                            }
                            inSpeech = false
                            currentSignatures.removeAll()
                        }
                    }

                    offset += frameSize
                }

                processedFrames += Int64(actualFrames)
            }

            // Close last speech turn if still open
            if inSpeech && !currentSignatures.isEmpty {
                let turnEnd = Double(processedFrames) / Double(sampleRate)
                let avgEnergy = currentSignatures.map(\.meanEnergy).reduce(0, +) / Float(currentSignatures.count)
                let avgZcr = currentSignatures.map(\.zeroCrossingRate).reduce(0, +) / Float(currentSignatures.count)
                let avgCentroid = currentSignatures.map(\.spectralCentroid).reduce(0, +) / Float(currentSignatures.count)

                let turnSig = VoiceSignature(meanEnergy: avgEnergy, zeroCrossingRate: avgZcr, spectralCentroid: avgCentroid, duration: turnEnd - currentTurnStart)
                speechTurns.append((start: currentTurnStart, end: turnEnd, signature: turnSig))
            }

            guard !speechTurns.isEmpty else { return [] }

            // 4. Dynamic Multi-Speaker Clustering (Leader Clustering on Normalized Feature Space)
            // Does NOT force 2 speakers: accurately handles 1, 2, 3, or more speakers.
            var speakerCentroids: [VoiceSignature] = []
            var turnAssignments: [Int] = []

            for turn in speechTurns {
                let sig = turn.signature

                if speakerCentroids.isEmpty {
                    speakerCentroids.append(sig)
                    turnAssignments.append(1)
                    continue
                }

                // Find closest speaker profile
                var bestIndex = 0
                var minDistance: Float = Float.greatestFiniteMagnitude

                for (idx, centroid) in speakerCentroids.enumerated() {
                    // Normalized acoustic distance (Centroid timbre + ZCR pitch)
                    let centroidDiff = abs(sig.spectralCentroid - centroid.spectralCentroid) / 800.0
                    let zcrDiff = abs(sig.zeroCrossingRate - centroid.zeroCrossingRate) / 0.15
                    let distance = sqrt(centroidDiff * centroidDiff + zcrDiff * zcrDiff)

                    if distance < minDistance {
                        minDistance = distance
                        bestIndex = idx
                    }
                }

                // Threshold for new speaker discovery:
                // If distance is large and we have fewer than 6 speakers, create a new speaker cluster
                if minDistance > 1.35 && speakerCentroids.count < 6 {
                    speakerCentroids.append(sig)
                    turnAssignments.append(speakerCentroids.count)
                } else {
                    // Update running centroid for the matched speaker
                    var current = speakerCentroids[bestIndex]
                    current.spectralCentroid = (current.spectralCentroid + sig.spectralCentroid) / 2.0
                    current.zeroCrossingRate = (current.zeroCrossingRate + sig.zeroCrossingRate) / 2.0
                    speakerCentroids[bestIndex] = current

                    turnAssignments.append(bestIndex + 1)
                }
            }

            var result: [(start: TimeInterval, end: TimeInterval, speakerId: String)] = []
            for (i, turn) in speechTurns.enumerated() {
                let speakerNum = turnAssignments[i]
                result.append((start: turn.start, end: turn.end, speakerId: "Sprecher \(speakerNum)"))
            }

            return result
        }.value
    }
}
