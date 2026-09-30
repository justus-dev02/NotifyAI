//
//  Components.swift
//  DesignSystem
//

import NotifyAICore
import SwiftUI

/// The rounded, tinted symbol that identifies a note's kind.
public struct NoteKindIcon: View {
    public let kind: NoteKind
    public var size: CGFloat = 36

    public var body: some View {
        Image(systemName: kind.symbolName)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.tint)
            .frame(width: size, height: size)
            .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }

    public init(kind: NoteKind, size: CGFloat = 36) {
        self.kind = kind
        self.size = size
    }
}

/// A titled content block used on the detail screen.
public struct ContentSection<Content: View>: View {
    public let title: LocalizedStringKey
    public let systemImage: String
    public var tint: Color = .accentColor
    public let content: Content

    public init(title: LocalizedStringKey, systemImage: String, tint: Color = .accentColor, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.content = content()
    }

    public var body: some View {
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
public struct BulletList: View {
    public let items: [String]
    public var bullet: String = "circle.fill"
    public var tint: Color = .secondary

    public var body: some View {
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

    public init(items: [String], bullet: String = "circle.fill", tint: Color = .secondary) {
        self.items = items
        self.bullet = bullet
        self.tint = tint
    }
}

/// Animated bars showing the recent microphone level.
public struct LevelMeter: View {
    public let levels: [Float]
    public var isActive = true

    public var body: some View {
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

    public init(levels: [Float], isActive: Bool = true) {
        self.levels = levels
        self.isActive = isActive
    }
}

/// A small capsule for secondary metadata.
public struct Tag: View {
    public let text: String
    public var systemImage: String?

    public var body: some View {
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

    public init(text: String, systemImage: String? = nil) {
        self.text = text
        self.systemImage = systemImage
    }
}

extension Binding where Value == Bool {
    /// `true` while `optional` holds a value. Setting it to `false` clears the value, which
    /// lets alerts and dialogs driven by an optional dismiss themselves correctly.
    public init<Wrapped: Sendable>(presenting optional: Binding<Wrapped?>) {
        self.init(
            get: { optional.wrappedValue != nil },
            set: { isPresented in
                if !isPresented { optional.wrappedValue = nil }
            }
        )
    }
}

/// A section header of a list or form with an explicit Dynamic Type text style, so it grows
/// with the user's text size like the rows below it.
public struct SectionHeader: View {
    private let text: Text

    public init(_ title: LocalizedStringKey) {
        text = Text(title)
    }

    /// For titles that are already localized.
    public init(verbatim title: String) {
        text = Text(verbatim: title)
    }

    public var body: some View {
        text
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}
