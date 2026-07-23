//
//  EnhancedAudioPlayerView.swift
//  NotifyAI
//
//  Created by AI Assistant on 23.10.25.
//

import SwiftUI
import AVFoundation

struct EnhancedAudioPlayerView: View {
    let url: URL
    @Binding var isPlaying: Bool
    @Binding var currentTime: TimeInterval
    @Binding var duration: TimeInterval
    @StateObject private var audioPlayer = AudioPlayerManager()
    
    var body: some View {
        VStack(spacing: 16) {
            // Progress Bar
            VStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { currentTime },
                        set: { audioPlayer.seek(to: $0) }
                    ),
                    in: 0...duration
                )
                .accentColor(AppTheme.accent)
                
                HStack {
                    Text(formatTime(currentTime))
                        .font(.caption)
                        .themedText(.secondary)
                    
                    Spacer()
                    
                    Text(formatTime(duration))
                        .font(.caption)
                        .themedText(.secondary)
                }
            }
            
            // Controls
            HStack(spacing: 24) {
                Button(action: { audioPlayer.skipBackward() }) {
                    Image(systemName: "gobackward.15")
                        .font(.title2)
                        .foregroundColor(AppTheme.accent)
                }
                
                Button(action: { togglePlayback() }) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.largeTitle)
                        .foregroundColor(AppTheme.accent)
                }
                
                Button(action: { audioPlayer.skipForward() }) {
                    Image(systemName: "goforward.15")
                        .font(.title2)
                        .foregroundColor(AppTheme.accent)
                }
            }
        }
        .onAppear {
            setupAudioPlayer()
        }
        .onDisappear {
            audioPlayer.cleanup()
        }
    }
    
    private func setupAudioPlayer() {
        audioPlayer.setupPlayer(url: url)
        audioPlayer.onTimeUpdate = { time in
            currentTime = time
        }
        audioPlayer.onDurationUpdate = { dur in
            duration = dur
        }
        audioPlayer.onPlaybackStateChange = { playing in
            isPlaying = playing
        }
    }
    
    private func togglePlayback() {
        if isPlaying {
            audioPlayer.pause()
        } else {
            audioPlayer.play()
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Audio Player Manager

class AudioPlayerManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?
    
    var onTimeUpdate: ((TimeInterval) -> Void)?
    var onDurationUpdate: ((TimeInterval) -> Void)?
    var onPlaybackStateChange: ((Bool) -> Void)?
    
    func setupPlayer(url: URL) {
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            
            onDurationUpdate?(audioPlayer?.duration ?? 0)
        } catch {
            print("Error setting up audio player: \(error)")
        }
    }
    
    func play() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        audioPlayer?.play()
        startTimer()
        onPlaybackStateChange?(true)
    }
    
    func pause() {
        audioPlayer?.pause()
        stopTimer()
        onPlaybackStateChange?(false)
    }
    
    func seek(to time: TimeInterval) {
        audioPlayer?.currentTime = time
        onTimeUpdate?(time)
    }
    
    func skipBackward() {
        guard let player = audioPlayer else { return }
        let newTime = max(0, player.currentTime - 15)
        seek(to: newTime)
    }
    
    func skipForward() {
        guard let player = audioPlayer else { return }
        let newTime = min(player.duration, player.currentTime + 15)
        seek(to: newTime)
    }
    
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.audioPlayer else { return }
            self.onTimeUpdate?(player.currentTime)
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    func cleanup() {
        audioPlayer?.stop()
        stopTimer()
    }
    
    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onPlaybackStateChange?(false)
    }
}
