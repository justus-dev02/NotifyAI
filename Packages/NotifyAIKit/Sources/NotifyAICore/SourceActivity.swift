//
//  SourceActivity.swift
//  NotifyAICore
//

import Foundation

/// Loudness of the microphone and of the system audio in fixed time bins, recorded
/// alongside a "Mikrofon + Systemton" recording.
///
/// The two sources are mixed into one file, but their levels are kept separately. This
/// tells the user ("Ich", microphone) apart from the other participants ("Andere",
/// system audio) far more reliably than guessing from voices. Bins lie on the recording
/// timeline (pauses excluded), like transcript and marker times.
public struct SourceActivity: Codable, Equatable, Sendable {
    public static let binDuration: TimeInterval = 0.1
    /// Levels are stored as dBFS + `levelOffset`, clamped to 0…255: one byte per bin.
    private static let levelOffset: Float = 100

    private var microphoneBytes: Data
    private var systemBytes: Data

    /// - Parameters: Levels per bin in dBFS. Both arrays must have the same length.
    public init(microphoneLevels: [Float], systemLevels: [Float]) {
        precondition(microphoneLevels.count == systemLevels.count, "Both sources need one level per bin")
        microphoneBytes = Data(microphoneLevels.map(Self.encode))
        systemBytes = Data(systemLevels.map(Self.encode))
    }

    public var binCount: Int { microphoneBytes.count }

    /// Level of bin `index` in dBFS (−100 means silence).
    public func microphoneLevel(at index: Int) -> Float { Self.decode(microphoneBytes[microphoneBytes.startIndex + index]) }
    public func systemLevel(at index: Int) -> Float { Self.decode(systemBytes[systemBytes.startIndex + index]) }

    public var microphoneLevels: [Float] { microphoneBytes.map(Self.decode) }
    public var systemLevels: [Float] { systemBytes.map(Self.decode) }

    /// Bins overlapping `start..<end`, clamped to the recorded range.
    public func bins(from start: TimeInterval, to end: TimeInterval) -> Range<Int> {
        let lower = max(0, Int((start / Self.binDuration).rounded(.down)))
        let upper = min(binCount, Int((end / Self.binDuration).rounded(.up)))
        return lower..<max(lower, upper)
    }

    private static func encode(_ level: Float) -> UInt8 {
        guard level.isFinite else { return 0 }
        return UInt8(min(255, max(0, (level + levelOffset).rounded())))
    }

    private static func decode(_ byte: UInt8) -> Float {
        Float(byte) - levelOffset
    }
}

/// Collects the per-bin energy of both sources while recording.
///
/// Bins are addressed by the absolute frame position on the recording timeline, so
/// blocks of any size can be appended.
public struct SourceActivityRecorder: Sendable {
    private let samplesPerBin = Int(AudioFormat.sampleRate * SourceActivity.binDuration)
    private var microphoneEnergy: [Double] = []
    private var systemEnergy: [Double] = []
    private var sampleCounts: [Int] = []

    /// Appends one block. `microphone` and `system` must have the same length.
    public mutating func append(microphone: ArraySlice<Float>, system: ArraySlice<Float>, startFrame: Int64) {
        precondition(microphone.count == system.count, "Both sources need the same number of samples")
        var frame = Int(startFrame)
        for (mic, sys) in zip(microphone, system) {
            let bin = frame / samplesPerBin
            while sampleCounts.count <= bin {
                microphoneEnergy.append(0)
                systemEnergy.append(0)
                sampleCounts.append(0)
            }
            microphoneEnergy[bin] += Double(mic * mic)
            systemEnergy[bin] += Double(sys * sys)
            sampleCounts[bin] += 1
            frame += 1
        }
    }

    public var isEmpty: Bool { sampleCounts.isEmpty }

    public func makeActivity() -> SourceActivity {
        func levels(_ energy: [Double]) -> [Float] {
            zip(energy, sampleCounts).map { sum, count in
                guard count > 0, sum > 0 else { return -100 }
                return Float(10 * log10(sum / Double(count)))
            }
        }
        return SourceActivity(microphoneLevels: levels(microphoneEnergy), systemLevels: levels(systemEnergy))
    }

    public init() {}
}
