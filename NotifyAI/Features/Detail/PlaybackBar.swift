//
//  PlaybackBar.swift
//  NotifyAI
//

import DesignSystem
import NotifyAICore
import NotifyAIServices
import SwiftUI

/// Playback controls pinned to the bottom of the detail screen.
struct PlaybackBar: View {
    let model: NoteDetailModel
    let onAddMarker: () -> Void

    var body: some View {
        @Bindable var player = model.player

        VStack(spacing: Theme.Spacing.small) {
            TimelineScrubber(
                currentTime: player.currentTime,
                duration: player.duration,
                markers: model.markers,
                highlights: model.highlights
            ) { time in
                player.seek(to: time)
            }

            HStack {
                Text(TimeFormatting.timestamp(player.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)

                Spacer()

                HStack(spacing: Theme.Spacing.large) {
                    Button("15 Sekunden zurück", systemImage: "gobackward.15") {
                        player.skip(by: -15)
                    }
                    Button(
                        player.isPlaying ? String(localized: "Pause") : String(localized: "Abspielen"),
                        systemImage: player.isPlaying ? "pause.fill" : "play.fill"
                    ) {
                        player.togglePlayback()
                    }
                    .font(.title2)
                    .contentTransition(.symbolEffect(.replace))
                    .keyboardShortcut(.space, modifiers: [])
                    Button("15 Sekunden vor", systemImage: "goforward.15") {
                        player.skip(by: 15)
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.title3)

                Spacer()

                HStack(spacing: Theme.Spacing.medium) {
                    Menu {
                        Picker("Geschwindigkeit", selection: $player.rate) {
                            ForEach(AudioPlayer.playbackRates, id: \.self) { rate in
                                Text(rate.formatted(.number.precision(.fractionLength(0...2))) + "×").tag(rate)
                            }
                        }
                    } label: {
                        Text(player.rate.formatted(.number.precision(.fractionLength(0...2))) + "×")
                            .font(.caption.monospacedDigit().weight(.semibold))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()

                    Button("Stelle markieren", systemImage: "star") {
                        onAddMarker()
                    }
                    // Before playback has started there is no position to mark.
                    .disabled(!player.isPlaying && player.currentTime == 0)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.marker)
                    .help("Aktuelle Stelle als wichtig markieren")
                }
                .frame(width: 64, alignment: .trailing)
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.medium)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .frame(maxWidth: Theme.readableWidth)
    }
}

/// A scrubber that shows marker positions and their highlighted windows.
struct TimelineScrubber: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let markers: [Marker]
    let highlights: HighlightWindows
    let onSeek: (TimeInterval) -> Void

    @State private var dragTime: TimeInterval?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let displayedTime = dragTime ?? currentTime

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.fill.tertiary)
                    .frame(height: 4)

                ForEach(Array(highlights.ranges.enumerated()), id: \.offset) { _, range in
                    Capsule()
                        .fill(Theme.marker.opacity(0.35))
                        .frame(width: max(3, position(of: range.upperBound, in: width) - position(of: range.lowerBound, in: width)), height: 8)
                        .offset(x: position(of: range.lowerBound, in: width))
                }

                Capsule()
                    .fill(.tint)
                    .frame(width: position(of: displayedTime, in: width), height: 4)

                ForEach(markers) { marker in
                    Image(systemName: "star.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.marker)
                        .offset(x: position(of: marker.time, in: width) - 4, y: -10)
                }

                Circle()
                    .fill(.tint)
                    .frame(width: dragTime == nil ? 12 : 16, height: dragTime == nil ? 12 : 16)
                    .offset(x: position(of: displayedTime, in: width) - (dragTime == nil ? 6 : 8))
                    .animation(.snappy(duration: 0.15), value: dragTime == nil)
            }
            .frame(height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragTime = time(at: value.location.x, in: width)
                    }
                    .onEnded { value in
                        onSeek(time(at: value.location.x, in: width))
                        dragTime = nil
                    }
            )
        }
        .frame(height: 24)
        .accessibilityRepresentation {
            Slider(
                value: Binding(get: { currentTime }, set: { onSeek($0) }),
                in: 0...max(duration, 1)
            ) {
                Text("Wiedergabeposition")
            }
            .accessibilityValue(TimeFormatting.timestamp(currentTime))
        }
    }

    private func position(of time: TimeInterval, in width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return width * CGFloat(min(max(time / duration, 0), 1))
    }

    private func time(at x: CGFloat, in width: CGFloat) -> TimeInterval {
        guard width > 0 else { return 0 }
        return duration * Double(min(max(x / width, 0), 1))
    }
}
