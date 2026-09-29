//
//  AudioSourceViews.swift
//  NotifyAI
//

#if os(macOS)
import SwiftUI

/// Source selection rows: microphone and/or system audio, the app to record and hints.
///
/// Edits `AppSettings` directly, like the language and engine pickers: the choice is
/// remembered for the next recording. Used by the recording setup, the menu bar and the
/// settings window.
struct AudioSourceRows: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Picker("Quelle", selection: $settings.audioSource) {
            ForEach(RecordingAudioSource.available) { source in
                Label(source.title, systemImage: source.symbolName).tag(source)
            }
        }

        if settings.audioSource.usesSystemAudio {
            SystemAudioAppPicker()
        }
    }
}

/// Picks "Alle Apps" or one running app. The list refreshes while it is visible, so an
/// app that starts playing audio moves to the top.
struct SystemAudioAppPicker: View {
    @Environment(AppSettings.self) private var settings
    @State private var apps: [AudioApp] = []

    var body: some View {
        @Bindable var settings = settings

        Picker("App", selection: $settings.systemAudioTarget) {
            Label(SystemAudioTarget.allApps.displayName, systemImage: "square.stack.3d.up")
                .tag(SystemAudioTarget.allApps)
            if !apps.isEmpty {
                Divider()
            }
            ForEach(apps) { app in
                AudioAppLabel(app: app)
                    .tag(app.target)
            }
            if let closedTarget {
                Text("\(closedTarget.displayName) (nicht geöffnet)")
                    .tag(closedTarget)
            }
        }
        .task {
            while !Task.isCancelled {
                apps = AudioAppCatalog.runningApps()
                try? await Task.sleep(for: .seconds(2))
            }
        }

        if let closedTarget {
            Label("„\(closedTarget.displayName)“ ist nicht geöffnet. Öffne die App vor dem Start oder wähle „Alle Apps“.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    /// The remembered app when it is not running; kept as an option so the picker has a matching tag.
    private var closedTarget: SystemAudioTarget? {
        guard case .app(let bundleID, _) = settings.systemAudioTarget,
              !apps.isEmpty,
              !apps.contains(where: { $0.bundleID == bundleID })
        else { return nil }
        return settings.systemAudioTarget
    }
}

private struct AudioAppLabel: View {
    let app: AudioApp

    var body: some View {
        Label {
            Text(app.isPlayingAudio ? "\(app.name) · spielt Ton ab" : app.name)
        } icon: {
            if let icon = AudioAppCatalog.icon(bundleID: app.bundleID) {
                Image(nsImage: Self.menuSized(icon))
            } else {
                Image(systemName: "app")
            }
        }
    }

    /// Menus show images at their intrinsic size.
    private static func menuSized(_ image: NSImage) -> NSImage {
        let copy = image.copy() as? NSImage ?? image
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

/// Explains what system audio recording needs: the permission and, next to loudspeakers, headphones.
struct SystemAudioHints: View {
    let source: RecordingAudioSource
    @State private var isLoudspeaker = false

    var body: some View {
        if source.usesSystemAudio {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                if source == .microphoneAndSystemAudio, isLoudspeaker {
                    Label("Tipp: Nutze Kopfhörer. Über die Lautsprecher nimmt das Mikrofon die anderen Teilnehmenden ein zweites Mal auf.", systemImage: "headphones")
                        .foregroundStyle(.orange)
                }
                Label("Beim ersten Start fragt macOS, ob NotifyAI Systemaudio aufnehmen darf.", systemImage: "lock.shield")
                    .foregroundStyle(.secondary)
                Button("Datenschutz-Einstellungen öffnen …") {
                    AudioAppCatalog.openPrivacySettings()
                }
                .buttonStyle(.link)
            }
            .font(.caption)
            .task(id: source) {
                // The output can change at any time (headphones plugged in, AirPods connected).
                while !Task.isCancelled {
                    isLoudspeaker = CoreAudioObject.defaultOutputIsLoudspeaker()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }
}

/// Level of the system audio next to the microphone meter, so the user sees that the
/// other participants are recorded. Also warns when nothing arrives.
struct SystemAudioStatus: View {
    @Environment(RecordingController.self) private var recording
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if recording.audioSource == .microphoneAndSystemAudio {
                HStack(spacing: Theme.Spacing.small) {
                    Label(recording.systemAudioTarget.displayName, systemImage: "speaker.wave.2")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: isCompact ? 90 : 140, alignment: .leading)
                    LevelMeter(
                        levels: Array(recording.systemLevels.suffix(isCompact ? 20 : 32)),
                        isActive: recording.phase == .recording
                    )
                    .frame(height: isCompact ? 14 : 22)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Systemton von \(recording.systemAudioTarget.displayName)")
            }

            if recording.isMissingSystemAudio {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Noch kein Systemton empfangen. Läuft das Meeting schon? Falls ja, erlaube NotifyAI unter „Bildschirm- & Systemaudioaufnahme“ das Aufnehmen von Systemaudio.", systemImage: "speaker.slash")
                        .foregroundStyle(.orange)
                    Button("Datenschutz-Einstellungen öffnen …") {
                        AudioAppCatalog.openPrivacySettings()
                    }
                    .buttonStyle(.link)
                }
                .font(.caption)
            }
        }
    }
}
#endif
