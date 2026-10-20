//
//  SpeakerViews.swift
//  NotifyAI
//

import DesignSystem
import NotifyAICore
import NotifyAIPersistence
import NotifyAIServices
import SwiftUI

/// A speaker to name, or a segment to give another speaker.
struct SpeakerNamingRequest: Identifiable {
    let id = UUID()
    /// The speaker as it is labelled now.
    let label: String?
    /// Set when only this segment changes its speaker.
    var segmentID: TranscriptSegment.ID?
    /// Whether the speaker has a voice print that can be remembered.
    var hasVoicePrint = false
}

/// The speakers of a note with their share of the conversation. Each one opens the actions
/// for naming it.
struct SpeakerOverview: View {
    let note: Note
    let onRequest: (SpeakerNamingRequest) -> Void
    @Environment(SpeakerDirectory.self) private var directory
    @Environment(UserNotices.self) private var notices

    var body: some View {
        let speakers = note.speakers
        let total = max(speakers.reduce(0) { $0 + $1.speechDuration }, 1)
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Sprecher")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            FlowLayout(spacing: Theme.Spacing.small) {
                ForEach(speakers) { speaker in
                    Menu {
                        SpeakerActions(note: note, speaker: speaker, onRequest: onRequest)
                    } label: {
                        SpeakerChip(speaker: speaker, share: speaker.speechDuration / total)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .disabled(!note.isEditable)
                }
            }
        }
    }
}

/// One speaker: name, how it was found and its share of the conversation.
private struct SpeakerChip: View {
    let speaker: NoteSpeaker
    let share: Double

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(speaker.label).fontWeight(.medium)
            Text(share.formatted(.percent.precision(.fractionLength(0))))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.fill.tertiary, in: Capsule())
        .contentShape(Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(hint))
    }

    private var symbol: String {
        switch speaker.origin {
        case .detected: "person.wave.2"
        case .recognized: "person.crop.circle.badge.checkmark"
        case .named: "person.crop.circle"
        case .audioSource: speaker.label == SpeakerDirectory.userLabel ? "mic" : "speaker.wave.2"
        }
    }

    private var hint: String {
        switch speaker.origin {
        case .detected: String(localized: "Automatisch erkannt. Tippen, um die Person zu benennen.")
        case .recognized: String(localized: "An der Stimme wiedererkannt. Tippen, um den Namen zu bestätigen oder zu ändern.")
        case .named: String(localized: "Von dir benannt.")
        case .audioSource: String(localized: "Nach Audioquelle getrennt.")
        }
    }
}

/// The actions for one speaker of a note.
struct SpeakerActions: View {
    let note: Note
    let speaker: NoteSpeaker
    let onRequest: (SpeakerNamingRequest) -> Void
    @Environment(SpeakerDirectory.self) private var directory
    @Environment(UserNotices.self) private var notices

    var body: some View {
        Button("„\(speaker.label)“ benennen …", systemImage: "pencil") {
            onRequest(SpeakerNamingRequest(label: speaker.label, hasVoicePrint: speaker.voicePrint != nil))
        }
        if speaker.label != directory.userLabel {
            Button("Das bin ich", systemImage: "person.fill.checkmark") {
                run { try await directory.rename(speaker.label, to: directory.userLabel, in: note, remembersVoice: directory.remembersVoices) }
            }
        }
        if speaker.origin == .recognized, speaker.voicePrint != nil {
            Button("Name bestätigen", systemImage: "checkmark.seal") {
                run { try await directory.confirm(speaker.label, in: note) }
            }
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                notices.post(UserNotice(title: String(localized: "Sprecher nicht geändert"), message: error.localizedDescription))
            }
        }
    }
}

/// The speaker label of a transcript segment, with the actions for the speaker and for the
/// segment alone.
struct SegmentSpeakerMenu: View {
    let note: Note
    let segment: TranscriptSegment
    let onRequest: (SpeakerNamingRequest) -> Void
    @Environment(SpeakerDirectory.self) private var directory
    @Environment(UserNotices.self) private var notices

    var body: some View {
        Menu {
            if let speaker = speakerEntry {
                Section(speaker.label) {
                    SpeakerActions(note: note, speaker: speaker, onRequest: onRequest)
                }
            }
            Section("Nur dieser Abschnitt") {
                ForEach(otherLabels, id: \.self) { label in
                    Button(label) { assign(to: label) }
                }
                Button("Andere Person …", systemImage: "person.badge.plus") {
                    onRequest(SpeakerNamingRequest(label: segment.speaker, segmentID: segment.id))
                }
                if segment.speaker != nil {
                    Button("Ohne Sprecher", systemImage: "person.slash") { assign(to: nil) }
                }
            }
        } label: {
            Text(segment.speaker ?? String(localized: "Sprecher zuweisen"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(!note.isEditable)
    }

    private var speakerEntry: NoteSpeaker? {
        guard let label = segment.speaker else { return nil }
        return note.speakers.first { $0.label == label } ?? NoteSpeaker(label: label, origin: .detected)
    }

    private var otherLabels: [String] {
        note.speakers.map(\.label).filter { $0 != segment.speaker }
    }

    private func assign(to label: String?) {
        Task {
            do {
                try await directory.assign(segmentID: segment.id, to: label, in: note)
            } catch {
                notices.post(UserNotice(title: String(localized: "Sprecher nicht geändert"), message: error.localizedDescription))
            }
        }
    }
}

/// Names a speaker (everywhere in the note) or the speaker of one segment.
struct SpeakerNamingSheet: View {
    let note: Note
    let request: SpeakerNamingRequest
    @Environment(SpeakerDirectory.self) private var directory
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var remembersVoice = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                        .onSubmit(save)
                    if !suggestions.isEmpty {
                        FlowLayout(spacing: Theme.Spacing.small) {
                            ForEach(suggestions, id: \.self) { suggestion in
                                Button(suggestion) { name = suggestion }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                } footer: {
                    Text(request.segmentID == nil
                        ? String(localized: "Der Name ersetzt „\(request.label ?? "")“ im ganzen Transkript.")
                        : String(localized: "Nur dieser Abschnitt erhält den Namen."))
                }
                if canRememberVoice {
                    Section {
                        Toggle(isOn: $remembersVoice) {
                            SettingLabel(
                                "Stimme merken",
                                detail: "NotifyAI erkennt diese Stimme in künftigen Aufnahmen wieder und setzt den Namen automatisch ein. Der Stimmabdruck bleibt auf diesem Gerät."
                            )
                        }
                    }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(request.segmentID == nil ? String(localized: "Sprecher benennen") : String(localized: "Abschnitt zuweisen"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 320)
        .onAppear {
            // Numbered labels are no names; real ones are kept for editing.
            if let label = request.label, note.speakers.first(where: { $0.label == label })?.origin != .detected {
                name = label
            }
        }
    }

    private var canRememberVoice: Bool {
        request.segmentID == nil && request.hasVoicePrint && directory.remembersVoices
    }

    private var suggestions: [String] {
        let current = NameComparison.key(name)
        return ([directory.userLabel] + directory.suggestedNames(for: note))
            .filter { NameComparison.key($0) != current && $0 != request.label }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                if let segmentID = request.segmentID {
                    try await directory.assign(segmentID: segmentID, to: name, in: note)
                } else if let label = request.label {
                    try await directory.rename(label, to: name, in: note, remembersVoice: canRememberVoice && remembersVoice)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Case- and accent-insensitive comparison of names in the user interface.
enum NameComparison {
    static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

extension Note {
    /// Whether the user may correct the transcript now (not while it is being processed).
    var isEditable: Bool {
        status != .recording && !status.isProcessing
    }
}
