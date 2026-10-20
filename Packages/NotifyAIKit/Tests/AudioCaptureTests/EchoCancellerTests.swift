//
//  EchoCancellerTests.swift
//  AudioCaptureTests
//
//  The echo of the system audio is removed from the microphone, the user's own voice stays,
//  and both sources leave the canceller aligned and complete.
//

@testable import AudioCapture
import Accelerate
import Foundation
import Testing

@Suite("Echo cancellation")
struct EchoCancellerTests {
    static let sampleRate = 16_000

    /// Deterministic noise, so every run sees the same signals.
    struct Noise {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int64(bitPattern: state >> 11) % 2_000_001) / 1_000_000 - 1
        }
    }

    /// Speech-like far-end audio: broadband noise in syllables of about 250 ms.
    static func farEnd(seconds: Double, seed: UInt64 = 1) -> [Float] {
        var noise = Noise(seed: seed)
        var previous: Float = 0
        return (0..<Int(seconds * Double(sampleRate))).map { index in
            let time = Double(index) / Double(sampleRate)
            let envelope = Float(0.55 + 0.45 * sin(2 * .pi * 4 * time))
            // A one-pole low-pass gives the noise a falling spectrum like speech.
            previous = 0.7 * previous + 0.3 * noise.next()
            return 0.25 * envelope * previous
        }
    }

    /// A voice of its own for the near end: a 160 Hz tone with harmonics, in syllables.
    static func nearEnd(seconds: Double) -> [Float] {
        (0..<Int(seconds * Double(sampleRate))).map { index in
            let time = Double(index) / Double(sampleRate)
            let envelope = 0.5 + 0.5 * sin(2 * .pi * 3 * time)
            let voice = (1...8).reduce(0.0) { sum, harmonic in
                sum + sin(2 * .pi * 160 * Double(harmonic) * time) / Double(harmonic)
            }
            return Float(0.08 * envelope * voice)
        }
    }

    /// Speakers → room → microphone: 40 ms delay, then 60 ms of decaying reflections.
    static func echoPath() -> [Float] {
        var noise = Noise(seed: 7)
        let delay = Int(0.04 * Double(sampleRate))
        let reflections = Int(0.06 * Double(sampleRate))
        var path = [Float](repeating: 0, count: delay + reflections)
        path[delay] = 0.35
        for index in 1..<reflections {
            path[delay + index] = 0.12 * noise.next() * exp(-Float(index) / Float(reflections / 4))
        }
        return path
    }

    /// Linear convolution, as long as `signal`.
    static func convolve(_ signal: [Float], with path: [Float]) -> [Float] {
        // vDSP correlates; a reversed kernel over a zero-padded signal is the convolution.
        // The overlay returns `vector.count - kernel.count` values, hence one extra zero.
        let padded = [Float](repeating: 0, count: path.count - 1) + signal + [0]
        return Array(vDSP.convolve(padded, withKernel: Array(path.reversed())).prefix(signal.count))
    }

    /// Runs the canceller in blocks of 100 ms, as the capture does, plus its tail.
    static func run(
        _ canceller: inout EchoCanceller,
        microphone: [Float],
        reference: [Float],
        blockSize: Int = 1_600
    ) -> (microphone: [Float], reference: [Float]) {
        var outputMicrophone: [Float] = []
        var outputReference: [Float] = []
        var start = 0
        while start < microphone.count {
            let end = min(microphone.count, start + blockSize)
            let result = canceller.process(microphone: microphone[start..<end], reference: reference[start..<end])
            #expect(result.microphone.count == end - start)
            outputMicrophone += result.microphone
            outputReference += result.reference
            start = end
        }
        let tail = canceller.finish()
        return (outputMicrophone + tail.microphone, outputReference + tail.reference)
    }

    /// Energy in dB of `signal[range]`.
    static func level(_ signal: [Float], _ range: Range<Int>) -> Float {
        10 * log10(vDSP.sumOfSquares(signal[range]) + 1e-12)
    }

    /// `signal` shifted later by the canceller's latency, at the original length.
    static func delayed(_ signal: [Float]) -> [Float] {
        Array(([Float](repeating: 0, count: EchoCanceller.latency) + signal).prefix(signal.count))
    }

    @Test("Every sample comes out once, both sources delayed by exactly the latency", arguments: [1_600, 1_000, 37])
    func lengthAndAlignment(blockSize: Int) {
        var noise = Noise(seed: 3)
        let microphone = (0..<20_011).map { _ in 0.2 * noise.next() }
        let reference = (0..<20_011).map { _ in 0.2 * noise.next() }
        var canceller = EchoCanceller()
        let output = Self.run(&canceller, microphone: microphone, reference: reference, blockSize: blockSize)

        #expect(output.microphone.count == microphone.count)
        #expect(output.reference.count == reference.count)
        // The reference passes through unchanged, only delayed.
        let expected = Self.delayed(reference)
        let difference = vDSP.maximumMagnitude(vDSP.subtract(output.reference, expected))
        #expect(difference < 1e-6)
    }

    @Test("Without far-end audio the microphone passes through unchanged")
    func silentReferenceIsTransparent() {
        let microphone = Self.nearEnd(seconds: 2)
        let reference = [Float](repeating: 0, count: microphone.count)
        var canceller = EchoCanceller()
        let output = Self.run(&canceller, microphone: microphone, reference: reference)

        let expected = Self.delayed(microphone)
        let difference = vDSP.maximumMagnitude(vDSP.subtract(output.microphone, expected))
        #expect(difference < 1e-4)
    }

    @Test("The echo of the far end is removed", arguments: [true, false])
    func removesEcho(suppressesResidualEcho: Bool) {
        let reference = Self.farEnd(seconds: 8)
        let echo = Self.convolve(reference, with: Self.echoPath())
        var noise = Noise(seed: 11)
        let microphone = echo.map { $0 + 0.0005 * noise.next() }
        var canceller = EchoCanceller(suppressesResidualEcho: suppressesResidualEcho)
        let output = Self.run(&canceller, microphone: microphone, reference: reference)

        // After the filter has converged (the first 4 s), measured on the last 3 s.
        let range = (5 * Self.sampleRate)..<(8 * Self.sampleRate)
        let reduction = Self.level(Self.delayed(microphone), range) - Self.level(output.microphone, range)
        #expect(reduction > (suppressesResidualEcho ? 25 : 18), "Echo reduced by \(reduction) dB")
    }

    @Test("The echo is mostly gone after two seconds")
    func convergesQuickly() {
        let reference = Self.farEnd(seconds: 3)
        let echo = Self.convolve(reference, with: Self.echoPath())
        var canceller = EchoCanceller()
        let output = Self.run(&canceller, microphone: echo, reference: reference)

        // The second second of the conversation.
        let range = Self.sampleRate..<(2 * Self.sampleRate)
        let reduction = Self.level(Self.delayed(echo), range) - Self.level(output.microphone, range)
        #expect(reduction > 18, "Echo in the second second reduced by \(reduction) dB")
    }

    @Test("The user's voice stays when the other side is silent")
    func keepsNearEndAfterConvergence() {
        let seconds = 8.0
        let length = Int(seconds * Double(Self.sampleRate))
        let split = 5 * Self.sampleRate
        // Far end for 5 s (the filter converges), then only the user speaks.
        var reference = Self.farEnd(seconds: seconds)
        for index in split..<length { reference[index] = 0 }
        let echo = Self.convolve(reference, with: Self.echoPath())
        var voice = Self.nearEnd(seconds: seconds)
        for index in 0..<split { voice[index] = 0 }
        let microphone = vDSP.add(echo, voice)

        var canceller = EchoCanceller()
        let output = Self.run(&canceller, microphone: microphone, reference: reference)

        // Skip the echo tail of the last far-end audio.
        let range = (split + Self.sampleRate / 2)..<length
        let expected = Self.delayed(voice)
        let change = Self.level(output.microphone, range) - Self.level(expected, range)
        #expect(abs(change) < 0.5, "Voice level changed by \(change) dB")
        let error = Self.level(vDSP.subtract(output.microphone, expected), range) - Self.level(expected, range)
        #expect(error < -30, "Voice distorted: error at \(error) dB")
    }

    @Test("While both sides speak, the echo is reduced and the user's voice is kept")
    func doubleTalk() {
        let seconds = 10.0
        let length = Int(seconds * Double(Self.sampleRate))
        let start = 5 * Self.sampleRate
        let reference = Self.farEnd(seconds: seconds)
        let echo = Self.convolve(reference, with: Self.echoPath())
        var voice = Self.nearEnd(seconds: seconds)
        for index in 0..<start { voice[index] = 0 }
        let microphone = vDSP.add(echo, voice)

        var canceller = EchoCanceller()
        let output = Self.run(&canceller, microphone: microphone, reference: reference)

        let range = start..<length
        let expectedVoice = Self.delayed(voice)
        let residual = vDSP.subtract(output.microphone, expectedVoice)
        // What remains besides the voice is far below the echo that came in …
        let reduction = Self.level(Self.delayed(echo), range) - Self.level(residual, range)
        #expect(reduction > 10, "Echo during double talk reduced by \(reduction) dB")
        // … and the voice itself is not suppressed.
        let voiceChange = Self.level(output.microphone, range) - Self.level(expectedVoice, range)
        #expect(voiceChange > -3, "Voice level changed by \(voiceChange) dB")
    }

    @Test("A changed echo path is learned again")
    func reconvergesAfterPathChange() {
        let reference = Self.farEnd(seconds: 12)
        let firstPath = Self.echoPath()
        var secondPath = [Float](repeating: 0, count: firstPath.count + 800)
        // The user turned the laptop: a longer delay and a different level.
        for (index, tap) in firstPath.enumerated() { secondPath[index + 800] = -0.8 * tap }
        let half = 6 * Self.sampleRate
        let first = Self.convolve(Array(reference[..<half]), with: firstPath)
        let second = Self.convolve(reference, with: secondPath)
        let microphone = first + second[half...]

        var canceller = EchoCanceller()
        let output = Self.run(&canceller, microphone: microphone, reference: reference)

        let range = (10 * Self.sampleRate)..<(12 * Self.sampleRate)
        let reduction = Self.level(Self.delayed(microphone), range) - Self.level(output.microphone, range)
        #expect(reduction > 30, "Echo after the change reduced by \(reduction) dB")
    }
}
