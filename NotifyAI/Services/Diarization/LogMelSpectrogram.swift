//
//  LogMelSpectrogram.swift
//  NotifyAI
//

import Accelerate
import Foundation
import NotifyAICore

/// Computes log-mel filterbank energies, the standard short-time spectral representation
/// used in speech processing.
///
/// Frames are 25 ms long with a 10 ms hop at 16 kHz, windowed with a Hann window and
/// transformed with a 512-point real FFT.
struct LogMelSpectrogram {
    static let frameLength = 400
    static let hopLength = 160
    static let fftLength = 512
    static let melBandCount = 24

    /// Seconds per spectrogram frame (hop).
    static var frameDuration: TimeInterval { Double(hopLength) / AudioFormat.sampleRate }

    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private let filterbank: [[Float]]

    init() {
        let log2n = vDSP_Length(log2(Double(Self.fftLength)))
        // Creating an FFT setup for a power-of-two length cannot fail.
        fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.frameLength, isHalfWindow: false)
        filterbank = Self.makeFilterbank(
            bandCount: Self.melBandCount,
            fftLength: Self.fftLength,
            sampleRate: Float(AudioFormat.sampleRate),
            lowFrequency: 80,
            highFrequency: 7_600
        )
    }

    /// One row of `melBandCount` log energies per frame, plus the frame's energy in dB.
    struct Frame {
        let logMel: [Float]
        let energyDB: Float
    }

    func frames(of samples: [Float]) -> [Frame] {
        guard samples.count >= Self.frameLength else { return [] }
        var frames: [Frame] = []
        frames.reserveCapacity((samples.count - Self.frameLength) / Self.hopLength + 1)

        var padded = [Float](repeating: 0, count: Self.fftLength)
        var real = [Float](repeating: 0, count: Self.fftLength / 2)
        var imaginary = [Float](repeating: 0, count: Self.fftLength / 2)
        var power = [Float](repeating: 0, count: Self.fftLength / 2)

        var start = 0
        while start + Self.frameLength <= samples.count {
            let frame = Array(samples[start..<(start + Self.frameLength)])
            let windowed = vDSP.multiply(frame, window)
            padded.replaceSubrange(0..<Self.frameLength, with: windowed)

            let energy = vDSP.sumOfSquares(frame) / Float(Self.frameLength)
            computePowerSpectrum(of: padded, real: &real, imaginary: &imaginary, power: &power)

            let logMel = filterbank.map { filter in
                log(vDSP.dot(filter, power) + 1e-10)
            }
            frames.append(Frame(logMel: logMel, energyDB: 10 * log10(energy + 1e-10)))
            start += Self.hopLength
        }
        return frames
    }

    /// Only the energy of every frame, in dB: the same values as `frames(of:)` computes, at a
    /// fraction of the cost (no FFT). Used for voice-activity detection of long files.
    static func energiesDB(of samples: [Float]) -> [Float] {
        guard samples.count >= frameLength else { return [] }
        var energies: [Float] = []
        energies.reserveCapacity((samples.count - frameLength) / hopLength + 1)
        var start = 0
        samples.withUnsafeBufferPointer { buffer in
            while start + frameLength <= buffer.count {
                let frame = UnsafeBufferPointer(rebasing: buffer[start..<(start + frameLength)])
                let energy = vDSP.sumOfSquares(frame) / Float(frameLength)
                energies.append(10 * log10(energy + 1e-10))
                start += hopLength
            }
        }
        return energies
    }

    /// Power spectrum of a real signal using the packed split-complex FFT layout.
    private func computePowerSpectrum(of signal: [Float], real: inout [Float], imaginary: inout [Float], power: inout [Float]) {
        let halfLength = Self.fftLength / 2
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                signal.withUnsafeBytes { bytes in
                    let complexPointer = bytes.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(complexPointer.baseAddress!, 2, &split, 1, vDSP_Length(halfLength))
                }
                fft.forward(input: split, output: &split)
                // Packed format: imagp[0] holds the Nyquist component, which is ignored.
                split.imagp[0] = 0
                vDSP.squareMagnitudes(split, result: &power)
            }
        }
    }

    /// Triangular filters equally spaced on the mel scale.
    static func makeFilterbank(bandCount: Int, fftLength: Int, sampleRate: Float, lowFrequency: Float, highFrequency: Float) -> [[Float]] {
        func mel(_ hertz: Float) -> Float { 2595 * log10(1 + hertz / 700) }
        func hertz(_ mel: Float) -> Float { 700 * (pow(10, mel / 2595) - 1) }

        let binCount = fftLength / 2
        let lowMel = mel(lowFrequency)
        let highMel = mel(highFrequency)
        let edges = (0...(bandCount + 1)).map { index in
            hertz(lowMel + (highMel - lowMel) * Float(index) / Float(bandCount + 1))
        }
        let binFrequency = sampleRate / Float(fftLength)

        return (0..<bandCount).map { band in
            let lower = edges[band]
            let center = edges[band + 1]
            let upper = edges[band + 2]
            return (0..<binCount).map { bin in
                let frequency = Float(bin) * binFrequency
                if frequency <= lower || frequency >= upper { return 0 }
                return frequency <= center
                    ? (frequency - lower) / (center - lower)
                    : (upper - frequency) / (upper - center)
            }
        }
    }
}
