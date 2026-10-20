//
//  SettingsPage.swift
//  NotifyAI
//

import SwiftUI

extension View {
    /// A page pushed inside the settings, such as the custom vocabulary or the integrations.
    func settingsPage(_ title: LocalizedStringKey) -> some View {
        modifier(SettingsPageModifier(title: title))
    }
}

/// The title and the way back of a settings page.
///
/// The Mac's settings window lays out its toolbar like a preferences window, centered, so the
/// system back button would sit in the middle of the title bar. On the Mac the page hides it
/// and shows its own back button at the leading edge, above the content, as System Settings
/// does; ⌘[ goes back as well. iOS keeps the back button of the navigation bar.
private struct SettingsPageModifier: ViewModifier {
    let title: LocalizedStringKey
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .navigationTitle(title)
            .navigationBarBackButtonHidden(true)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 8) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Zurück", systemImage: "chevron.backward")
                            .labelStyle(.iconOnly)
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Zurück zu den Einstellungen")
                    Text(title)
                        .font(.headline)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }
        #else
        content
            .navigationTitle(title)
        #endif
    }
}
