//
//  AudioPlayer.swift
//  NotifyAI
//

import AVFoundation
import Observation
import OSLog

/// Plays a note's audio and publishes the playback position for transcript syncing.
@MainActor
@Observable
final class AudioPlayer {
    static let playbackRates: [Float] = [0.75, 1, 1.25, 1.5, 2]

    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var errorMessage: String?
    var rate: Float = 1 {
        didSet { player?.rate = rate }
    }

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var delegate: PlaybackDelegate?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private let session: AudioSessionController

    init(session: AudioSessionController) {
        self.session = session
    }

    var isLoaded: Bool { player != nil }

    func load(url: URL) {
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.enableRate = true
            player.rate = rate
            player.prepareToPlay()
            let delegate = PlaybackDelegate { [weak self] in
                self?.handlePlaybackFinished()
            }
            player.delegate = delegate
            self.player = player
            self.delegate = delegate
            duration = player.duration
            currentTime = 0
            errorMessage = nil
        } catch {
            errorMessage = "Die Audiodatei konnte nicht geöffnet werden."
            Logger.audio.error("Loading audio failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        do {
            try session.activateForPlayback()
        } catch {
            Logger.audio.error("Activating playback failed: \(error.localizedDescription, privacy: .public)")
        }
        player.play()
        isPlaying = true
        startTicker()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicker()
        syncTime()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, time), player.duration)
        syncTime()
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    /// Stops playback and releases the file.
    func stop() {
        player?.stop()
        player = nil
        delegate = nil
        isPlaying = false
        stopTicker()
    }

    private func syncTime() {
        currentTime = player?.currentTime ?? 0
    }

    /// Publishes the position ten times per second while playing. That is precise enough
    /// for word highlighting without re-rendering the transcript on every frame.
    private func startTicker() {
        stopTicker()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.syncTime()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func handlePlaybackFinished() {
        isPlaying = false
        stopTicker()
        currentTime = duration
    }
}

/// `AVAudioPlayerDelegate` callbacks arrive on the main thread; forward them to the player.
private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    private let onFinish: @MainActor () -> Void

    init(onFinish: @escaping @MainActor () -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated { onFinish() }
    }
}
