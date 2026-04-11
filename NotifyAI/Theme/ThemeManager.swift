//
//  ThemeManager.swift
//  NotifyAI
//
//  Created by AI Assistant on 23.10.25.
//

import SwiftUI

class ThemeManager: ObservableObject {
    @Published var isDarkMode: Bool = false
    
    init() {
        // Check system appearance preference
        self.isDarkMode = UITraitCollection.current.userInterfaceStyle == .dark
    }
    
    func toggleTheme() {
        isDarkMode.toggle()
    }
}

struct AppTheme {
    // Background Colors
    static let primaryBackground = Color.adaptiveBackground
    static let secondaryBackground = Color.adaptiveSecondaryBackground
    static let tertiaryBackground = Color.adaptiveTertiaryBackground
    
    // Text Colors
    static let primaryText = Color.adaptiveLabel
    static let secondaryText = Color.adaptiveSecondaryLabel
    static let tertiaryText = Color.adaptiveTertiaryLabel
    
    // Accent Colors
    static let accent = Color("AccentColor") // Using the existing AccentColor.colorset
    static let accentSecondary = Color.adaptiveSecondaryLabel
    
    // Status Colors
    static let success = Color.green
    static let warning = Color.orange
    static let error = Color.red
    
    // Card Colors
    static let cardBackground = Color.adaptiveSecondaryBackground
    static let cardBorder = Color.adaptiveSeparator
    
    // Glass Effect Colors
    static let glassBackground = Color.adaptiveBackground.opacity(0.8)
    static let glassBorder = Color.adaptiveSeparator
}

// MARK: - Color Extensions
extension Color {
    init(_ colorName: String) {
        self.init(colorName, bundle: .main)
    }
    
    // Dynamic colors that adapt to light/dark mode
    static let adaptiveBackground = Color(UIColor.systemBackground)
    static let adaptiveSecondaryBackground = Color(UIColor.secondarySystemBackground)
    static let adaptiveTertiaryBackground = Color(UIColor.tertiarySystemBackground)
    
    static let adaptiveLabel = Color(UIColor.label)
    static let adaptiveSecondaryLabel = Color(UIColor.secondaryLabel)
    static let adaptiveTertiaryLabel = Color(UIColor.tertiaryLabel)
    
    static let adaptiveSeparator = Color(UIColor.separator)
    static let adaptiveOpaqueSeparator = Color(UIColor.opaqueSeparator)
}

// MARK: - View Modifiers
struct ThemedBackground: ViewModifier {
    let style: BackgroundStyle
    
    enum BackgroundStyle {
        case primary
        case secondary
        case tertiary
        case card
        case glass
    }
    
    func body(content: Content) -> some View {
        content
            .background(backgroundColor)
    }
    
    private var backgroundColor: Color {
        switch style {
        case .primary:
            return AppTheme.primaryBackground
        case .secondary:
            return AppTheme.secondaryBackground
        case .tertiary:
            return AppTheme.tertiaryBackground
        case .card:
            return AppTheme.cardBackground
        case .glass:
            return AppTheme.glassBackground
        }
    }
}

struct ThemedText: ViewModifier {
    let style: TextStyle
    
    enum TextStyle {
        case primary
        case secondary
        case tertiary
    }
    
    func body(content: Content) -> some View {
        content
            .foregroundColor(textColor)
    }
    
    private var textColor: Color {
        switch style {
        case .primary:
            return AppTheme.primaryText
        case .secondary:
            return AppTheme.secondaryText
        case .tertiary:
            return AppTheme.tertiaryText
        }
    }
}

// MARK: - View Extensions
extension View {
    func themedBackground(_ style: ThemedBackground.BackgroundStyle) -> some View {
        self.modifier(ThemedBackground(style: style))
    }
    
    func themedText(_ style: ThemedText.TextStyle) -> some View {
        self.modifier(ThemedText(style: style))
    }
    
    func glassCard() -> some View {
        self
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(AppTheme.glassBorder.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
    }
}
