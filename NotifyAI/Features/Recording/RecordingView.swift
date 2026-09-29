//
//  RecordingView.swift
//  NotifyAI
//

import SwiftUI

/// Full-screen (iOS) or sheet (macOS) recording flow: setup, then the live session.
struct RecordingView: View {
    @Environment(RecordingController.self) private var recording
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if recording.phase == .idle {
                    RecordingSetupView()
                } else {
                    LiveRecordingView { noteID in
                        navigation.selectedNoteID = noteID
                        dismiss()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Closing does not stop a running recording; it continues in the background.
                    Button(recording.isActive ? "Minimieren" : "Abbrechen", systemImage: recording.isActive ? "chevron.down" : "xmark") {
                        dismiss()
                    }
                }
            }
        }
        .alert("Aufnahme nicht möglich", isPresented: Binding(
            get: { recording.errorMessage != nil },
            set: { if !$0 { recording.dismissError() } }
        )) {
            Button("OK") { recording.dismissError() }
        } message: {
            Text(recording.errorMessage ?? "")
        }
    }
}

// MARK: - Setup

private struct RecordingSetupView: View {
    @Environment(RecordingController.self) private var recording
    @Environment(AppSettings.self) private var settings
    @Environment(WhisperModelManager.self) private var whisperModels

    var body: some View {
        @Bindable var recording = recording
        @Bindable var settings = settings

        Form {
            Section {
                TextField("Titel (optional)", text: $recording.draft.title)
                Picker("Art des Gesprächs", selection: $recording.draft.focus) {
                    ForEach(RecordingFocus.allCases) { focus in
                        Label(focus.title, systemImage: focus.symbolName).tag(focus)
                    }
                }
                TextField("Teilnehmende (durch Komma getrennt)", text: $recording.draft.participants)
            } footer: {
                Text("Die Art des Gesprächs bestimmt, worauf die Zusammenfassung achtet.")
            }

            #if os(macOS)
            Section {
                AudioSourceRows()
                SystemAudioHints(source: settings.audioSource)
            } header: {
                Text("Audioquelle")
            } footer: {
                Text(settings.audioSource.detail)
            }
            #endif

            Section("Transkription") {
                Picker("Sprache", selection: $settings.language) {
                    ForEach(TranscriptionLanguage.all) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                Picker("Spracherkennung", selection: $settings.engine) {
                    ForEach(TranscriptionEngineKind.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                Toggle("Live-Transkript anzeigen", isOn: $settings.liveTranscription)
                if settings.engine == .whisper {
                    WhisperModelStatusRow(model: settings.whisperModel)
                }
            }

            Section {
                Toggle(isOn: $recording.draft.consentConfirmed) {
                    Text("Alle Anwesenden sind mit der Aufnahme einverstanden.")
                }
            } footer: {
                Text("Gespräche dürfen nur mit Zustimmung aller Beteiligten aufgenommen werden. Die Aufnahme bleibt auf diesem Gerät.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Neue Aufnahme")
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await recording.start() }
            } label: {
                Label(recording.phase == .starting ? "Wird gestartet …" : "Aufnahme starten", systemImage: "mic.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.small)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.recording)
            .controlSize(.large)
            .disabled(!canStart)
            .keyboardShortcut(.defaultAction)
            .padding(Theme.Spacing.large)
        }
    }

    private var canStart: Bool {
        guard recording.canStart else { return false }
        return settings.engine != .whisper || whisperModels.isInstalled(settings.whisperModel)
    }
}

/// Shows whether the selected Whisper model is available and offers the download.
struct WhisperModelStatusRow: View {
    let model: WhisperModel
    @Environment(WhisperModelManager.self) private var whisperModels

    var body: some View {
        switch whisperModels.state(for: model) {
        case .installed:
            LabeledContent("Whisper-Modell") {
                Label(model.name, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .downloading(let progress):
            LabeledContent("\(model.name) wird geladen") {
                ProgressView(value: progress)
                    .frame(width: 120)
            }
        case .preparing:
            LabeledContent("\(model.name) wird vorbereitet") {
                ProgressView()
                    .controlSize(.small)
            }
        case .notInstalled, .failed:
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Label("Das Modell „\(model.name)“ ist noch nicht geladen.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button("Jetzt laden (\(model.approximateSize))") {
                    whisperModels.download(model)
                }
                Text("Einmaliger Download. Danach läuft Whisper ohne Internet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Live

private struct LiveRecordingView: View {
    @Environment(RecordingController.self) private var recording
    let onFinish: (UUID) -> Void
    @State private var isConfirmingDiscard = false

    var body: some View {
        VStack(spacing: Theme.Spacing.large) {
            VStack(spacing: Theme.Spacing.small) {
                RecordingStatusPill()
                Text(TimeFormatting.timestamp(recording.elapsed))
                    .font(.system(size: 56, weight: .light, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.default, value: Int(recording.elapsed))
                    .accessibilityLabel("Aufnahmedauer \(TimeFormatting.timestamp(recording.elapsed))")
            }
            .padding(.top, Theme.Spacing.large)

            LevelMeter(levels: recording.levels, isActive: recording.phase == .recording)
                .frame(height: 56)
                .padding(.horizontal, Theme.Spacing.large)

            #if os(macOS)
            SystemAudioStatus()
                .padding(.horizontal, Theme.Spacing.large)
            #endif

            if let message = recording.interruptionMessage {
                Label(message, systemImage: "phone.arrow.down.left")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            }

            LiveTranscriptPanel()
                .frame(maxHeight: .infinity)
                .padding(.horizontal, Theme.Spacing.large)

            if recording.phase == .finishing {
                ProgressView("Transkript wird abgeschlossen …")
                    .padding(.bottom, Theme.Spacing.xLarge)
            } else {
                RecordingControls(onStop: stop)
                    .padding(.bottom, Theme.Spacing.large)
            }
        }
        .frame(maxWidth: Theme.readableWidth)
        .frame(maxWidth: .infinity)
        .navigationTitle(recording.draft.title.isEmpty ? "Aufnahme" : recording.draft.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button("Verwerfen", systemImage: "trash", role: .destructive) {
                    isConfirmingDiscard = true
                }
                .disabled(recording.phase == .finishing)
            }
        }
        .confirmationDialog("Aufnahme verwerfen?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
            Button("Verwerfen", role: .destructive) {
                Task { await recording.discard() }
            }
        } message: {
            Text("Die Aufnahme wird gelöscht und nicht gespeichert.")
        }
        .sensoryFeedback(.impact, trigger: recording.markers.count)
    }

    private func stop() {
        Task {
            if let noteID = await recording.stop() {
                onFinish(noteID)
            }
        }
    }
}

/// "● Aufnahme" / "Pausiert" indicator.
struct RecordingStatusPill: View {
    @Environment(RecordingController.self) private var recording

    var body: some View {
        let isPaused = recording.phase == .paused
        HStack(spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(isPaused ? Color.secondary : Theme.recording)
                .symbolEffect(.pulse, isActive: !isPaused)
            Text(isPaused ? "Pausiert" : "Aufnahme")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.fill.tertiary, in: Capsule())
    }
}

/// Pause, stop and "important" buttons. Shared by the recording screen and the menu bar.
struct RecordingControls: View {
    @Environment(RecordingController.self) private var recording
    var isCompact = false
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: isCompact ? Theme.Spacing.large : Theme.Spacing.xLarge) {
            Button {
                recording.togglePause()
            } label: {
                Label(recording.phase == .paused ? "Fortsetzen" : "Pause", systemImage: recording.phase == .paused ? "play.fill" : "pause.fill")
                    .frame(width: buttonSize, height: buttonSize)
                    .background(.fill.tertiary, in: Circle())
                    .contentShape(Circle())
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .help("Pause / Fortsetzen (⇧⌘P)")

            Button(action: onStop) {
                Label("Beenden", systemImage: "stop.fill")
                    .font(isCompact ? .title3 : .title)
                    .frame(width: buttonSize * 1.35, height: buttonSize * 1.35)
                    .foregroundStyle(.white)
                    .background(Theme.recording, in: Circle())
            }
            .keyboardShortcut(.return, modifiers: .command)
            .help("Aufnahme beenden (⌘↩)")

            Button {
                recording.addMarker()
            } label: {
                Label("Wichtig", systemImage: recording.lastMarker == nil ? "star" : "star.fill")
                    .foregroundStyle(Theme.marker)
                    .frame(width: buttonSize, height: buttonSize)
                    .background(Theme.marker.opacity(0.15), in: Circle())
                    .contentShape(Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .help("Stelle als wichtig markieren (⇧⌘M)")
        }
        .labelStyle(.iconOnly)
        .font(isCompact ? .body : .title2)
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if let marker = recording.lastMarker {
                Text("Markiert bei \(TimeFormatting.timestamp(marker.time))")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .offset(y: isCompact ? -30 : -44)
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .animation(.snappy, value: recording.lastMarker)
    }

    private var buttonSize: CGFloat { isCompact ? 32 : 56 }
}

/// Finalized text plus the current hypothesis, scrolled to the newest words.
struct LiveTranscriptPanel: View {
    @Environment(RecordingController.self) private var recording
    var lineLimit: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    switch recording.liveTranscription {
                    case .off:
                        placeholder("Das Transkript wird nach der Aufnahme erstellt.")
                    case .preparing:
                        placeholder("Spracherkennung wird vorbereitet …")
                    case .unavailable(let reason):
                        placeholder("Live-Transkript nicht verfügbar: \(reason) Das Transkript wird nach der Aufnahme erstellt.")
                    case .running:
                        if recording.liveSegments.isEmpty, recording.volatileText.isEmpty {
                            placeholder(recording.engineKind == .whisper
                                ? "Whisper schreibt abschnittsweise mit – der erste Text erscheint nach einer Sprechpause."
                                : "Sprich los – der Text erscheint hier.")
                        }
                        transcriptText
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.large)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
            .onChange(of: recording.liveSegments.count) {
                withAnimation { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .onChange(of: recording.volatileText) {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }

    private let bottomID = "bottom"

    private var transcriptText: some View {
        let finalized = recording.liveSegments.map(\.text).joined(separator: " ")
        var text = AttributedString(finalized)
        if !recording.volatileText.isEmpty {
            var volatile = AttributedString((finalized.isEmpty ? "" : " ") + recording.volatileText)
            volatile.foregroundColor = .secondary
            text += volatile
        }
        return Text(text)
            .lineSpacing(3)
            .lineLimit(lineLimit)
            .textSelection(.enabled)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .font(.callout)
    }
}
