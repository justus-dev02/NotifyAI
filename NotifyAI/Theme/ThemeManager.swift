//
//  ThemeManager.swift
//  NotifyAI
//
//  Created by AI Assistant on 23.10.25.
//  Updated for Apple Liquid Glass Design System.
//

import SwiftUI

class ThemeManager: ObservableObject {
    @Published var isDarkMode: Bool = false
    
    init() {
        self.isDarkMode = UITraitCollection.current.userInterfaceStyle == .dark
    }
    
    func toggleTheme() {
        isDarkMode.toggle()
    }
}

// MARK: - Liquid Glass Theme Tokens

struct AppTheme {
    // Primary Brand Accents
    static let accent = Color.indigo
    static let accentSecondary = Color.cyan
    static let accentPurple = Color.purple
    
    // Status Colors
    static let success = Color.green
    static let warning = Color.orange
    static let error = Color.red
    
    // Adaptive Text
    static let primaryText = Color.adaptiveLabel
    static let secondaryText = Color.adaptiveSecondaryLabel
    static let tertiaryText = Color.adaptiveTertiaryLabel

    // Background & Card Legacy Tokens
    static let primaryBackground = Color.adaptiveBackground
    static let secondaryBackground = Color.adaptiveSecondaryBackground
    static let tertiaryBackground = Color.adaptiveTertiaryBackground
    static let cardBackground = Color.adaptiveSecondaryBackground
    static let cardBorder = Color.adaptiveSeparator
    static let glassBackground = Color.adaptiveBackground.opacity(0.8)
    static let glassBorder = Color.adaptiveSeparator
}

// MARK: - Color Extensions
extension Color {
    static let adaptiveBackground = Color(UIColor.systemGroupedBackground)
    static let adaptiveSecondaryBackground = Color(UIColor.secondarySystemGroupedBackground)
    static let adaptiveTertiaryBackground = Color(UIColor.tertiarySystemGroupedBackground)
    
    static let adaptiveLabel = Color(UIColor.label)
    static let adaptiveSecondaryLabel = Color(UIColor.secondaryLabel)
    static let adaptiveTertiaryLabel = Color(UIColor.tertiaryLabel)
    
    static let adaptiveSeparator = Color(UIColor.separator)
}

// MARK: - Liquid Glass View Modifiers

struct LiquidGlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 24
    var padding: CGFloat = 18
    var hasSpecularBorder: Bool = true
    
    @Environment(\.colorScheme) var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: colorScheme == .dark
                                ? [Color.white.opacity(0.28), Color.white.opacity(0.06), Color.indigo.opacity(0.18)]
                                : [Color.white.opacity(0.65), Color.white.opacity(0.15), Color.indigo.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.2
                    )
            )
            .shadow(color: colorScheme == .dark ? Color.black.opacity(0.3) : Color.indigo.opacity(0.06), radius: 16, x: 0, y: 8)
    }
}

struct LiquidGlassBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme

    func body(content: Content) -> some View {
        ZStack {
            // Ambient Fluid Mesh Gradients
            GeometryReader { proxy in
                ZStack {
                    Color.adaptiveBackground
                        .ignoresSafeArea()

                    // Ambient Glow Orbs
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.indigo.opacity(colorScheme == .dark ? 0.22 : 0.14), Color.clear],
                                center: .center,
                                startRadius: 10,
                                endRadius: proxy.size.width * 0.75
                            )
                        )
                        .frame(width: proxy.size.width * 1.2, height: proxy.size.width * 1.2)
                        .offset(x: -proxy.size.width * 0.35, y: -proxy.size.height * 0.25)
                        .blur(radius: 40)

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.cyan.opacity(colorScheme == .dark ? 0.16 : 0.10), Color.clear],
                                center: .center,
                                startRadius: 10,
                                endRadius: proxy.size.width * 0.65
                            )
                        )
                        .frame(width: proxy.size.width, height: proxy.size.width)
                        .offset(x: proxy.size.width * 0.4, y: proxy.size.height * 0.3)
                        .blur(radius: 50)

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.purple.opacity(colorScheme == .dark ? 0.14 : 0.08), Color.clear],
                                center: .center,
                                startRadius: 10,
                                endRadius: proxy.size.width * 0.55
                            )
                        )
                        .frame(width: proxy.size.width * 0.8, height: proxy.size.width * 0.8)
                        .offset(x: 0, y: proxy.size.height * 0.65)
                        .blur(radius: 45)
                }
            }
            .ignoresSafeArea()

            content
        }
    }
}

// MARK: - View Extensions

extension View {
    /// Applies full Liquid Glass ambient background with fluid gradient mesh
    func liquidGlassBackground() -> some View {
        self.modifier(LiquidGlassBackgroundModifier())
    }

    /// Wraps the view inside a sleek Liquid Glass container
    func liquidGlassCard(cornerRadius: CGFloat = 24, padding: CGFloat = 18) -> some View {
        self.modifier(LiquidGlassCardModifier(cornerRadius: cornerRadius, padding: padding))
    }

    /// Modern glass button style
    func liquidGlassButton(tint: Color = .indigo) -> some View {
        self
            .font(.subheadline)
            .fontWeight(.semibold)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.5), Color.white.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: tint.opacity(0.15), radius: 8, y: 3)
    }

    /// Backward compatibility helpers
    func themedBackground(_ style: ThemedBackground.BackgroundStyle) -> some View {
        self.modifier(ThemedBackground(style: style))
    }
    
    func themedText(_ style: ThemedText.TextStyle) -> some View {
        self.modifier(ThemedText(style: style))
    }
    
    func glassCard() -> some View {
        self.modifier(LiquidGlassCardModifier(cornerRadius: 22, padding: 16))
    }
}

struct ThemedBackground: ViewModifier {
    let style: BackgroundStyle
    enum BackgroundStyle { case primary, secondary, tertiary, card, glass }
    func body(content: Content) -> some View { content }
}

struct ThemedText: ViewModifier {
    let style: TextStyle
    enum TextStyle { case primary, secondary, tertiary }
    func body(content: Content) -> some View {
        switch style {
        case .primary: content.foregroundStyle(Color.adaptiveLabel)
        case .secondary: content.foregroundStyle(Color.adaptiveSecondaryLabel)
        case .tertiary: content.foregroundStyle(Color.adaptiveTertiaryLabel)
        }
    }
}
