//
//  OnboardingView.swift
//  NotifyAI
//

import DesignSystem
import SwiftUI

/// First-launch introduction: what the app does, permissions and engine status.
struct OnboardingView: View {
    private enum Step: Int, CaseIterable {
        case welcome, permissions, intelligence
    }

    @Environment(AppSettings.self) private var settings
    @State private var step: Step = .welcome
    @State private var microphone = MicrophonePermission.state
    @State private var speech = SpeechRecognitionPermission.state

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: Theme.Spacing.xLarge) {
                    switch step {
                    case .welcome: welcome
                    case .permissions: permissions
                    case .intelligence: intelligence
                    }
                }
                .frame(maxWidth: 520)
                .padding(Theme.Spacing.xLarge)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)

            footer
        }
        .animation(.snappy, value: step)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: Theme.Spacing.large) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
                .padding(.top, Theme.Spacing.xLarge)

            VStack(spacing: Theme.Spacing.small) {
                Text("Willkommen bei NotifyAI")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text("Nimm Gespräche auf, lies sie als Transkript nach und erhalte eine Zusammenfassung mit Aufgaben und Entscheidungen.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                feature("lock.shield", "Bleibt auf deinem Gerät", "Aufnahmen, Transkripte und Zusammenfassungen werden lokal verarbeitet und gespeichert.")
                feature("star", "Wichtiges markieren", "Tippe während der Aufnahme auf „Wichtig“. Die Stelle wird später im Transkript hervorgehoben.")
                feature("sparkles", "Zusammenfassung auf dem Gerät", "Mit Apple Intelligence entstehen Überblick, Aufgaben und Entscheidungen ohne Cloud.")
                feature("bubble.left.and.text.bubble.right", "Frag deine Notizen", "Stell Fragen über alle Aufnahmen, zum Beispiel zu Personen, Themen oder Zeiträumen. Jede Antwort nennt ihre Quellen.")
                #if os(macOS)
                feature("person.2.wave.2", "Online-Meetings mitschneiden", "Nimm Zoom, Teams, Discord & Co. direkt am Mac auf. Deine Stimme und die der anderen werden getrennt beschriftet.")
                #endif
            }
            .padding(.top, Theme.Spacing.medium)
        }
    }

    private var permissions: some View {
        VStack(spacing: Theme.Spacing.large) {
            header("mic.circle.fill", "Zugriff erlauben", "NotifyAI braucht das Mikrofon für Aufnahmen und die Spracherkennung für das Transkript.")

            VStack(spacing: Theme.Spacing.medium) {
                permissionRow(
                    title: "Mikrofon",
                    detail: "Für Aufnahmen",
                    systemImage: "mic",
                    state: microphone
                ) {
                    _ = await MicrophonePermission.request()
                    microphone = MicrophonePermission.state
                }
                permissionRow(
                    title: "Spracherkennung",
                    detail: "Für das Transkript, direkt auf dem Gerät",
                    systemImage: "text.bubble",
                    state: speech
                ) {
                    speech = await SpeechRecognitionPermission.request()
                }
            }

            #if os(macOS)
            Label("Für Online-Meetings fragt macOS beim ersten Mitschnitt zusätzlich, ob NotifyAI Systemaudio aufnehmen darf.", systemImage: "speaker.wave.2")
                .font(.callout)
                .foregroundStyle(.secondary)
            #endif
        }
    }

    private var intelligence: some View {
        VStack(spacing: Theme.Spacing.large) {
            header("sparkles", "Transkription & Zusammenfassung", "Beides läuft vollständig auf diesem Gerät.")

            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                LabeledContent("Spracherkennung") {
                    Text(settings.transcription.engine.displayName)
                }
                LabeledContent("Sprache") {
                    Text(settings.transcription.language.displayName)
                }
                LabeledContent("Zusammenfassung") {
                    switch LanguageModelAvailability.current(for: settings.transcription.language) {
                    case .available:
                        Label("Apple Intelligence", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .unavailable:
                        Label("Einfache Zusammenfassung", systemImage: "info.circle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(Theme.Spacing.large)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))

            if case .unavailable(let reason) = LanguageModelAvailability.current(for: settings.transcription.language) {
                Text("\(reason) Bis dahin erstellt NotifyAI eine einfache Zusammenfassung aus den wichtigsten Sätzen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text("Spracherkennung, Sprache und das optionale Whisper-Modell kannst du jederzeit in den Einstellungen ändern.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: Building blocks

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Zurück") {
                    step = Step(rawValue: step.rawValue - 1) ?? .welcome
                }
                .buttonStyle(.bordered)
            }
            Spacer()
            Button(step == .intelligence ? String(localized: "Los geht’s") : String(localized: "Weiter")) {
                if let next = Step(rawValue: step.rawValue + 1) {
                    step = next
                } else {
                    settings.general.hasCompletedOnboarding = true
                }
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .padding(Theme.Spacing.large)
    }

    private func header(_ systemImage: String, _ title: LocalizedStringKey, _ subtitle: LocalizedStringKey) -> some View {
        VStack(spacing: Theme.Spacing.medium) {
            Image(systemName: systemImage)
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text(title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, Theme.Spacing.large)
    }

    private func feature(_ systemImage: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.medium) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary)
            }
        }
    }

    private func permissionRow(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        systemImage: String,
        state: PermissionState,
        request: @escaping () async -> Void
    ) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            switch state {
            case .granted:
                Label("Erlaubt", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.iconOnly)
                    .font(.title2)
            case .denied:
                Text("In den Einstellungen erlauben")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
            case .notDetermined:
                Button("Erlauben") {
                    Task { await request() }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(Theme.Spacing.large)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
    }
}
