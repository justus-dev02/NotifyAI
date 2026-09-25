//
//  Components.swift
//  NotifyAI
//

import SwiftUI

/// The rounded, tinted symbol that identifies a note's kind.
struct NoteKindIcon: View {
    let kind: NoteKind
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: kind.symbolName)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.tint)
            .frame(width: size, height: size)
            .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A titled content block used on the detail screen.
struct ContentSection<Content: View>: View {
    let title: String
    let systemImage: String
    var tint: Color = .accentColor
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(tint)
                .labelStyle(.titleAndIcon)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.large)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
    }
}

/// A bullet list with consistent spacing and alignment.
struct BulletList: View {
    let items: [String]
    var bullet: String = "circle.fill"
    var tint: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                    Image(systemName: bullet)
                        .font(.system(size: 6))
                        .foregroundStyle(tint)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    Text(item)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Status line for a note, with progress while it is processed.
struct NoteStatusLabel: View {
    let status: NoteStatus
    var progress: Double?

    var body: some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            if status.isProcessing {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: status.symbolName)
            }
            Text(status.displayName)
            if let progress, status.isProcessing {
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .foregroundStyle(status.tint)
    }
}

/// Animated bars showing the recent microphone level.
struct LevelMeter: View {
    let levels: [Float]
    var isActive = true

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 3
            let barWidth = max(2, (proxy.size.width - spacing * CGFloat(levels.count - 1)) / CGFloat(max(levels.count, 1)))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(levels.indices, id: \.self) { index in
                    Capsule()
                        .fill(isActive ? Theme.recording.gradient : Color.secondary.gradient)
                        .frame(width: barWidth, height: max(3, proxy.size.height * CGFloat(levels[index])))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.linear(duration: 0.08), value: levels)
        }
        .accessibilityHidden(true)
    }
}

/// A small capsule for secondary metadata.
struct Tag: View {
    let text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.fill.tertiary, in: Capsule())
    }
}

extension Binding where Value == Bool {
    /// `true` while `optional` holds a value. Setting it to `false` clears the value, which
    /// lets alerts and dialogs driven by an optional dismiss themselves correctly.
    init<Wrapped: Sendable>(presenting optional: Binding<Wrapped?>) {
        self.init(
            get: { optional.wrappedValue != nil },
            set: { isPresented in
                if !isPresented { optional.wrappedValue = nil }
            }
        )
    }
}
