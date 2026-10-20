//
//  NoteDeletion.swift
//  NotifyAI
//

import NotifyAICore
import NotifyAIPersistence
import NotifyAIServices
import SwiftUI

/// What of a note the user wants to delete.
enum NoteDeletion: Identifiable {
    /// Only the recording, to free space; the text stays.
    case audio
    /// Only the transcript; summary, tasks and recording stay.
    case transcript
    /// The whole note.
    case note

    var id: Self { self }
}

/// "Löschen" in the note's menu: the recording, the transcript or the whole note.
struct NoteDeletionMenu: View {
    let note: Note
    @Binding var request: NoteDeletion?
    @Environment(NoteLibrary.self) private var library

    var body: some View {
        Menu("Löschen", systemImage: "trash") {
            if note.kind.hasAudio {
                Button("Nur Aufnahme löschen …", systemImage: "waveform.slash") { request = .audio }
                    .disabled(!library.canDeleteAudio(of: note))
                Button("Transkript löschen …", systemImage: "text.badge.xmark") { request = .transcript }
                    .disabled(!library.canDeleteTranscript(of: note))
                Divider()
            }
            Button("Notiz löschen …", systemImage: "trash", role: .destructive) { request = .note }
                .disabled(note.status == .recording)
        }
    }
}

extension View {
    /// Asks before deleting what `request` names and then deletes it.
    /// - Parameter onDeleteNote: Deletes the whole note (the screen has to close first).
    func noteDeletionConfirmation(
        for note: Note,
        request: Binding<NoteDeletion?>,
        onDeleteNote: @escaping () -> Void
    ) -> some View {
        modifier(NoteDeletionConfirmation(note: note, request: request, onDeleteNote: onDeleteNote))
    }
}

private struct NoteDeletionConfirmation: ViewModifier {
    let note: Note
    @Binding var request: NoteDeletion?
    let onDeleteNote: () -> Void
    @Environment(NoteLibrary.self) private var library
    /// The size of the recording, shown when asking to delete it.
    @State private var audioSize: Int64?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(title, isPresented: Binding(presenting: $request), titleVisibility: .visible, presenting: request) { deletion in
                Button(confirmTitle(for: deletion), role: .destructive) { delete(deletion) }
                Button("Abbrechen", role: .cancel) { request = nil }
            } message: { deletion in
                Text(message(for: deletion))
            }
            .task(id: request) {
                guard request == .audio else { return }
                audioSize = await library.audioSize(of: [note])
            }
    }

    private var title: String {
        switch request {
        case .audio: String(localized: "Nur die Aufnahme löschen?")
        case .transcript: String(localized: "Transkript löschen?")
        case .note, nil: String(localized: "Notiz löschen?")
        }
    }

    private func confirmTitle(for deletion: NoteDeletion) -> String {
        switch deletion {
        case .audio: String(localized: "Aufnahme löschen")
        case .transcript: String(localized: "Transkript löschen")
        case .note: String(localized: "Löschen")
        }
    }

    private func message(for deletion: NoteDeletion) -> String {
        switch deletion {
        case .audio:
            let kept = String(localized: "Transkript, Zusammenfassung, Aufgaben und Sprecher bleiben erhalten. Abspielen und neu transkribieren sind danach nicht mehr möglich.")
            guard let audioSize else {
                return String(localized: "Die Audiodatei wird endgültig gelöscht. \(kept)")
            }
            return String(localized: "Die Audiodatei (\(TimeFormatting.byteCount(audioSize))) wird endgültig gelöscht. \(kept)")
        case .transcript:
            return note.hasAudioFile
                ? String(localized: "Das Transkript und die Sprecher werden gelöscht. Zusammenfassung, Aufgaben, Markierungen und die Aufnahme bleiben erhalten; aus der Aufnahme lässt sich jederzeit ein neues Transkript erstellen.")
                : String(localized: "Das Transkript und die Sprecher werden endgültig gelöscht. Zusammenfassung, Aufgaben und Markierungen bleiben erhalten. Da die Aufnahme bereits gelöscht ist, lässt sich das Transkript nicht wiederherstellen.")
        case .note:
            return String(localized: "Die Aufnahme, das Transkript und die Zusammenfassung werden endgültig entfernt.")
        }
    }

    private func delete(_ deletion: NoteDeletion) {
        request = nil
        switch deletion {
        case .audio: library.deleteAudio(of: [note])
        case .transcript: library.deleteTranscript(of: note)
        case .note: onDeleteNote()
        }
    }
}
