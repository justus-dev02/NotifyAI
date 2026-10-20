//
//  SourceReaderTests.swift
//  AudioCaptureTests
//
//  Conversion to 16 kHz does not depend on how much audio is converted at once.
//

@testable import AudioCapture
import Accelerate
import Foundation
import Testing

@Suite("Source conversion")
struct SourceReaderTests {
    /// Writes `count` samples of a deterministic signal into the ring.
    private static func write(_ count: Int, startingAt start: Int, to source: CaptureSource) {
        _ = source.ring.write(count: count) { destination, offset in
            for index in destination.indices {
                let position = Double(start + offset + index)
                destination[index] = Float(0.3 * sin(position * 0.031) + 0.2 * sin(position * 0.47))
            }
        }
    }

    /// Converts four seconds at 48 kHz, draining after every `interval` written samples.
    private static func convert(drainingEvery interval: Int) throws -> [Float] {
        let source = CaptureSource(sampleRate: 48_000, channelCount: 1)
        var reader = try SourceReader(source: source)
        var output = SampleFIFO()
        var converted: [Float] = []
        let total = 4 * 48_000
        var written = 0
        while written < total {
            let count = min(interval, total - written)
            write(count, startingAt: written, to: source)
            written += count
            reader.drain(into: &output)
            converted += output.prefix(output.count)
            output.removeAll()
        }
        #expect(reader.takeLosses().isEmpty)
        return converted
    }

    @Test("Large blocks (a stalled processing queue) convert exactly like small ones")
    func blockSizeDoesNotMatter() throws {
        let small = try Self.convert(drainingEvery: 512)
        // A second's worth at once: the converter's output buffer fills up repeatedly.
        let large = try Self.convert(drainingEvery: 48_000)
        let count = min(small.count, large.count)
        // The resampler holds back a few milliseconds until more input arrives.
        #expect(count > 63_800, "Converted \(small.count) and \(large.count) of 64 000 samples")
        let difference = vDSP.maximumMagnitude(vDSP.subtract(small[..<count], large[..<count]))
        #expect(difference < 1e-5, "Samples differ by up to \(difference)")
    }
}
