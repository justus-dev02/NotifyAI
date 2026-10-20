//
//  EchoCanceller.swift
//  AudioCapture
//

import Accelerate
import NotifyAICore

/// Removes the echo of the system audio from the microphone of a "Mikrofon + Systemton"
/// recording.
///
/// Without headphones, the Mac's speakers play the other participants and the microphone
/// records them a second time, a few dozen milliseconds later. Mixed into the file, every
/// remote sentence then sounds doubled; the transcript gets repeated phrases and remote
/// speech is attributed to "Ich". The system audio is the exact signal the speakers play,
/// so it serves as the reference:
///
/// 1. `AdaptiveEchoFilter` learns the path from the speakers to the microphone (delay, room,
///    loudness) and subtracts the predicted echo. It is a partitioned-block frequency-domain
///    NLMS filter over `tailDuration` with two copies: a background filter that always adapts
///    and a foreground filter that produces the output and only takes over the background's
///    coefficients when they predict the echo clearly better. Adaptation during double talk
///    (both sides speak) disturbs only the background, so the user's voice is never removed
///    by a diverged filter.
/// 2. `ResidualEchoSuppressor` attenuates what is left of the echo (speaker distortion, a
///    path that just changed) per frequency band, only while the reference plays.
///
/// Both run on 16 kHz mono in blocks of `blockSize`. Output lags the input by `latency`
/// samples; `process` returns as many samples as it receives, the reference delayed by the
/// same amount, so microphone and system audio stay aligned for mixing. `finish()` returns
/// the samples still inside. Pure computation, no allocation per block after the first.
public struct EchoCanceller {
    /// 16 ms at 16 kHz; the FFT size is twice this.
    public static let blockSize = 256
    /// Echo delays up to this long are cancelled: output latency, the room, input latency.
    public static let tailDuration: TimeInterval = 0.32
    /// Fixed delay of the output, in samples (see `process`).
    public static let latency = 2 * blockSize

    private var filter: AdaptiveEchoFilter
    private var suppressor: ResidualEchoSuppressor
    private let suppressesResidualEcho: Bool

    /// Input not yet processed (less than one block).
    private var pendingMicrophone: [Float] = []
    private var pendingReference: [Float] = []
    /// Processed output waiting to be returned. It starts with one block of silence, which
    /// together with the one block the overlap of the suppressor holds back makes `latency`.
    private var outputMicrophone = SampleFIFO()
    private var outputReference = SampleFIFO()
    /// Samples passed in and handed out so far; `finish()` returns the difference.
    private var receivedCount = 0
    private var returnedCount = 0

    public init(suppressesResidualEcho: Bool = true) {
        let partitions = Int((Self.tailDuration * AudioFormat.sampleRate / Double(Self.blockSize)).rounded(.up))
        filter = AdaptiveEchoFilter(blockSize: Self.blockSize, partitions: partitions)
        suppressor = ResidualEchoSuppressor(blockSize: Self.blockSize)
        self.suppressesResidualEcho = suppressesResidualEcho
        outputMicrophone.appendSilence(Self.blockSize)
        outputReference.appendSilence(Self.blockSize)
    }

    /// Cancels the echo of `reference` in `microphone`. Both must have the same length.
    /// - Returns: The cleaned microphone and the reference, both delayed by `latency`
    ///   samples and exactly as long as the input.
    public mutating func process(
        microphone: ArraySlice<Float>,
        reference: ArraySlice<Float>
    ) -> (microphone: [Float], reference: [Float]) {
        precondition(microphone.count == reference.count, "Microphone and reference need the same length")
        pendingMicrophone.append(contentsOf: microphone)
        pendingReference.append(contentsOf: reference)
        receivedCount += microphone.count
        processCompleteBlocks()
        return take(microphone.count)
    }

    /// The samples still inside the canceller; afterwards the canceller is empty. Together
    /// with all `process` results exactly as many samples as were passed in.
    public mutating func finish() -> (microphone: [Float], reference: [Float]) {
        let outstanding = receivedCount - returnedCount
        // Silence completes the last block and pushes it through the suppressor's overlap.
        let padding = (Self.blockSize - pendingMicrophone.count % Self.blockSize) % Self.blockSize + Self.blockSize
        pendingMicrophone.append(contentsOf: repeatElement(0, count: padding))
        pendingReference.append(contentsOf: repeatElement(0, count: padding))
        processCompleteBlocks()
        let remaining = take(outstanding)
        self = Self(suppressesResidualEcho: suppressesResidualEcho)
        return remaining
    }

    private mutating func processCompleteBlocks() {
        let blockSize = Self.blockSize
        var offset = 0
        while pendingMicrophone.count - offset >= blockSize {
            let microphone = pendingMicrophone[offset..<(offset + blockSize)]
            let reference = pendingReference[offset..<(offset + blockSize)]
            let linear = filter.process(microphone: microphone, reference: reference)
            let cleaned = suppressesResidualEcho
                ? suppressor.process(error: linear.error, echo: linear.echo)
                : suppressor.delay(linear.error)
            cleaned.withUnsafeBufferPointer { outputMicrophone.append($0) }
            outputReference.append(contentsOf: suppressor.delayedReference(reference))
            offset += blockSize
        }
        if offset > 0 {
            pendingMicrophone.removeFirst(offset)
            pendingReference.removeFirst(offset)
        }
    }

    private mutating func take(_ count: Int) -> (microphone: [Float], reference: [Float]) {
        let count = min(count, outputMicrophone.count)
        let microphone = Array(outputMicrophone.prefix(count))
        let reference = Array(outputReference.prefix(count))
        outputMicrophone.removeFirst(count)
        outputReference.removeFirst(count)
        returnedCount += count
        return (microphone, reference)
    }
}

// MARK: - Linear echo cancellation

/// Partitioned-block frequency-domain NLMS filter (overlap-save) with a foreground and a
/// background copy of its coefficients.
struct AdaptiveEchoFilter {
    /// Step size of the normalized update (stable below 2). The background may adapt fast:
    /// a step that diverges during double talk never reaches the output.
    static let stepSize: Float = 0.7
    /// Blocks whose reference is quieter than this (RMS, about -60 dBFS) do not adapt.
    static let minimumReferenceRMS: Float = 0.001
    /// The background replaces the foreground when its error energy is below this share.
    static let takeoverRatio: Float = 0.6
    /// The background is reset when its error is this much larger than the microphone.
    static let divergenceRatio: Float = 1.5

    let blockSize: Int
    let partitions: Int
    private let fft: RealSpectrum
    private var previousReference: [Float]
    /// Spectra of the last `partitions` reference frames, newest first.
    private var history: [Spectrum]
    private var foreground: [Spectrum]
    private var background: [Spectrum]
    /// Partition whose coefficients are constrained to `blockSize` taps in this block.
    private var constrainedPartition = 0
    private var foregroundEnergy: Float = 0
    private var backgroundEnergy: Float = 0
    private var microphoneEnergy: Float = 0

    init(blockSize: Int, partitions: Int) {
        self.blockSize = blockSize
        self.partitions = partitions
        fft = RealSpectrum(size: 2 * blockSize)
        previousReference = [Float](repeating: 0, count: blockSize)
        let empty = Spectrum(bins: blockSize + 1)
        history = Array(repeating: empty, count: partitions)
        foreground = Array(repeating: empty, count: partitions)
        background = Array(repeating: empty, count: partitions)
    }

    /// One block: the microphone with the foreground's echo estimate removed, and that estimate.
    mutating func process(microphone: ArraySlice<Float>, reference: ArraySlice<Float>) -> (error: [Float], echo: [Float]) {
        // Overlap-save: the frame is the previous and the current reference block.
        history.removeLast()
        history.insert(fft.forward(previousReference + reference), at: 0)
        previousReference = Array(reference)

        let foregroundEcho = estimate(with: foreground)
        let backgroundEcho = estimate(with: background)
        let microphone = Array(microphone)
        let foregroundError = vDSP.subtract(microphone, foregroundEcho)
        let backgroundError = vDSP.subtract(microphone, backgroundEcho)

        if vDSP.rootMeanSquare(reference) >= Self.minimumReferenceRMS {
            adaptBackground(error: backgroundError)
            compare(
                foregroundError: vDSP.sumOfSquares(foregroundError),
                backgroundError: vDSP.sumOfSquares(backgroundError),
                microphone: vDSP.sumOfSquares(microphone)
            )
        }
        return (foregroundError, foregroundEcho)
    }

    /// The echo the coefficients predict for the current block.
    private func estimate(with coefficients: [Spectrum]) -> [Float] {
        var sum = Spectrum(bins: blockSize + 1)
        for partition in 0..<partitions {
            sum.addProduct(coefficients[partition], history[partition])
        }
        // The last block of the circular result is the linear convolution.
        return Array(fft.inverse(sum)[blockSize...])
    }

    /// Proportionate NLMS (IPNLMS): half of the step is shared evenly by all partitions, the
    /// other half in proportion to their coefficients. An echo path is mostly a delay and
    /// early reflections, i.e. a few strong partitions, which therefore converge many times
    /// faster than with an even step, while the weak ones keep adapting.
    private mutating func adaptBackground(error: [Float]) {
        let errorSpectrum = fft.forward([Float](repeating: 0, count: blockSize) + error)
        let magnitudes = background.map { sqrt(vDSP.sum($0.power)) }
        let total = vDSP.sum(magnitudes) + 1e-9
        let weights = magnitudes.map { 0.5 / Float(partitions) + 0.5 * $0 / total }

        // Normalized by the weighted energy of the whole regression vector, per frequency.
        var power = [Float](repeating: 1e-3 / Float(partitions), count: blockSize + 1)
        for (partition, frame) in history.enumerated() {
            frame.addPower(to: &power, scaledBy: weights[partition])
        }
        let normalization = power.map { Self.stepSize / $0 }
        for partition in 0..<partitions {
            let gains = vDSP.multiply(weights[partition], normalization)
            background[partition].addConjugateProduct(history[partition], errorSpectrum, scaledBy: gains)
        }
        // Constraining one partition per block keeps all of them causal and short without
        // two extra transforms per partition and block.
        var taps = fft.inverse(background[constrainedPartition])
        for index in blockSize..<taps.count {
            taps[index] = 0
        }
        background[constrainedPartition] = fft.forward(taps)
        constrainedPartition = (constrainedPartition + 1) % partitions
    }

    /// Lets the better copy win. Energies are smoothed over a few blocks so a single block
    /// of double talk decides nothing.
    private mutating func compare(foregroundError: Float, backgroundError: Float, microphone: Float) {
        let smoothing: Float = 0.3
        foregroundEnergy += smoothing * (foregroundError - foregroundEnergy)
        backgroundEnergy += smoothing * (backgroundError - backgroundEnergy)
        microphoneEnergy += smoothing * (microphone - microphoneEnergy)
        if backgroundEnergy < Self.takeoverRatio * foregroundEnergy {
            foreground = background
            foregroundEnergy = backgroundEnergy
        } else if backgroundEnergy > Self.divergenceRatio * microphoneEnergy, backgroundEnergy > foregroundEnergy {
            background = foreground
            backgroundEnergy = foregroundEnergy
        }
    }
}

// MARK: - Residual echo

/// Attenuates the echo the linear filter leaves, per frequency, in overlapping windows.
///
/// The residual is assumed to be a share ("leak") of the predicted echo. The share is
/// estimated continuously from how the error's spectrum follows the echo's spectrum while
/// only the reference plays; frequencies where the user speaks keep their level because
/// their error is far above the predicted residual.
struct ResidualEchoSuppressor {
    /// Strongest attenuation (-20 dB): speech underneath is never cut off completely.
    static let minimumGain: Float = 0.1
    /// The residual estimate is raised by this factor to be on the safe side.
    static let overestimation: Float = 2

    private let blockSize: Int
    private let fft: RealSpectrum
    /// Square root of a periodic Hann window: analysis × synthesis sums to one at 50 % overlap.
    private let window: [Float]
    private var previousError: [Float]
    private var previousEcho: [Float]
    private var overlap: [Float]
    private var gains: [Float]
    private var leak: Float = 0.1
    private var crossPower: Float = 0
    private var echoAutoPower: Float = 0
    /// The reference, delayed by one block to match the output.
    private var referenceDelay: [Float]

    init(blockSize: Int) {
        self.blockSize = blockSize
        fft = RealSpectrum(size: 2 * blockSize)
        window = (0..<(2 * blockSize)).map { Float(sin(Double.pi * Double($0) / Double(2 * blockSize))) }
        previousError = [Float](repeating: 0, count: blockSize)
        previousEcho = [Float](repeating: 0, count: blockSize)
        overlap = [Float](repeating: 0, count: blockSize)
        gains = [Float](repeating: 1, count: blockSize + 1)
        referenceDelay = [Float](repeating: 0, count: blockSize)
    }

    /// The error block of one block earlier, with the residual echo attenuated.
    mutating func process(error: [Float], echo: [Float]) -> [Float] {
        let errorSpectrum = fft.forward(vDSP.multiply(previousError + error, window))
        let echoSpectrum = fft.forward(vDSP.multiply(previousEcho + echo, window))
        previousError = error
        previousEcho = echo

        let errorPower = errorSpectrum.power
        let predictedPower = echoSpectrum.power
        let echoIsPresent = vDSP.sum(predictedPower) > 1e-6
        if echoIsPresent {
            updateLeak(errorPower: errorPower, echoPower: predictedPower)
        }
        for bin in gains.indices {
            var target: Float = 1
            if echoIsPresent {
                let residual = Self.overestimation * leak * predictedPower[bin]
                target = max(Self.minimumGain, 1 - residual / (errorPower[bin] + 1e-9))
            }
            // Quick to open (speech onsets), slower to close (no "musical" fluttering).
            gains[bin] = target > gains[bin] ? target : 0.5 * gains[bin] + 0.5 * target
        }
        var filtered = errorSpectrum
        filtered.scale(by: gains)
        return overlapAdd(fft.inverse(filtered))
    }

    /// The error block of one block earlier, unchanged (residual suppression turned off).
    mutating func delay(_ error: [Float]) -> [Float] {
        let delayed = previousError
        previousError = error
        return delayed
    }

    /// The reference block of one block earlier, to stay aligned with the output.
    mutating func delayedReference(_ reference: ArraySlice<Float>) -> [Float] {
        let delayed = referenceDelay
        referenceDelay = Array(reference)
        return delayed
    }

    private mutating func overlapAdd(_ frame: [Float]) -> [Float] {
        let windowed = vDSP.multiply(frame, window)
        let output = vDSP.add(overlap, windowed[0..<blockSize])
        overlap = Array(windowed[blockSize...])
        return output
    }

    /// Leak = how much of the predicted echo's spectral shape remains in the error, from the
    /// mean-free cross power of both (Speex' estimator), smoothed over time.
    private mutating func updateLeak(errorPower: [Float], echoPower: [Float]) {
        let errorMean = vDSP.mean(errorPower)
        let echoMean = vDSP.mean(echoPower)
        let errorCentered = vDSP.add(-errorMean, errorPower)
        let echoCentered = vDSP.add(-echoMean, echoPower)
        let smoothing: Float = 0.05
        crossPower += smoothing * (vDSP.dot(errorCentered, echoCentered) - crossPower)
        echoAutoPower += smoothing * (vDSP.sumOfSquares(echoCentered) - echoAutoPower)
        guard echoAutoPower > 0 else { return }
        leak = min(0.5, max(0.005, crossPower / echoAutoPower))
    }
}

// MARK: - Spectra

/// The bins 0…size/2 of the spectrum of a real signal.
struct Spectrum {
    var real: [Float]
    var imaginary: [Float]

    init(bins: Int) {
        real = [Float](repeating: 0, count: bins)
        imaginary = [Float](repeating: 0, count: bins)
    }

    init(real: [Float], imaginary: [Float]) {
        self.real = real
        self.imaginary = imaginary
    }

    var power: [Float] {
        vDSP.add(vDSP.square(real), vDSP.square(imaginary))
    }

    /// self += a × b
    mutating func addProduct(_ a: Self, _ b: Self) {
        for bin in real.indices {
            real[bin] += a.real[bin] * b.real[bin] - a.imaginary[bin] * b.imaginary[bin]
            imaginary[bin] += a.real[bin] * b.imaginary[bin] + a.imaginary[bin] * b.real[bin]
        }
    }

    /// self += conj(a) × b × gain
    mutating func addConjugateProduct(_ a: Self, _ b: Self, scaledBy gains: [Float]) {
        for bin in real.indices {
            real[bin] += gains[bin] * (a.real[bin] * b.real[bin] + a.imaginary[bin] * b.imaginary[bin])
            imaginary[bin] += gains[bin] * (a.real[bin] * b.imaginary[bin] - a.imaginary[bin] * b.real[bin])
        }
    }

    func addPower(to power: inout [Float], scaledBy weight: Float) {
        for bin in power.indices {
            power[bin] += weight * (real[bin] * real[bin] + imaginary[bin] * imaginary[bin])
        }
    }

    mutating func scale(by gains: [Float]) {
        real = vDSP.multiply(real, gains)
        imaginary = vDSP.multiply(imaginary, gains)
    }
}

/// Forward and inverse DFT of real signals of one size, returning / taking the bins 0…size/2.
struct RealSpectrum {
    private let forwardTransform: vDSP.DiscreteFourierTransform<Float>
    private let inverseTransform: vDSP.DiscreteFourierTransform<Float>
    let size: Int

    init(size: Int) {
        self.size = size
        // Sizes of the form 2^n are always supported, so the setup cannot fail.
        // swiftlint:disable force_try
        forwardTransform = try! vDSP.DiscreteFourierTransform(count: size, direction: .forward, transformType: .complexComplex, ofType: Float.self)
        inverseTransform = try! vDSP.DiscreteFourierTransform(count: size, direction: .inverse, transformType: .complexComplex, ofType: Float.self)
        // swiftlint:enable force_try
    }

    func forward(_ signal: [Float]) -> Spectrum {
        let zeros = [Float](repeating: 0, count: size)
        let (real, imaginary) = forwardTransform.transform(real: signal, imaginary: zeros)
        let bins = size / 2 + 1
        return Spectrum(real: Array(real[0..<bins]), imaginary: Array(imaginary[0..<bins]))
    }

    /// The real signal of a spectrum; the missing bins follow from conjugate symmetry.
    func inverse(_ spectrum: Spectrum) -> [Float] {
        var real = [Float](repeating: 0, count: size)
        var imaginary = [Float](repeating: 0, count: size)
        let half = size / 2
        for bin in 0...half {
            real[bin] = spectrum.real[bin]
            imaginary[bin] = spectrum.imaginary[bin]
        }
        for bin in 1..<half {
            real[size - bin] = spectrum.real[bin]
            imaginary[size - bin] = -spectrum.imaginary[bin]
        }
        // The DC and Nyquist bins of a real signal have no imaginary part.
        imaginary[0] = 0
        imaginary[half] = 0
        let (signal, _) = inverseTransform.transform(real: real, imaginary: imaginary)
        return vDSP.multiply(1 / Float(size), signal)
    }
}
