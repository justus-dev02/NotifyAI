//
//  TranscriptReplaceSheet.swift
//  NotifyAI
//

import NotifyAIPersistence
import NotifyAIServices
import SwiftUI

/// "Suchen und ersetzen": fixes a word that recognition got wrong everywhere in the note, for
/// example a name, and can add the right spelling to the custom vocabulary so new
/// transcripts get it right from the start.
struct TranscriptReplaceSheet: View {
    let note: Note
    @Environment(TranscriptEditor.self) private var editor
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var replacement = ""
    @State private var matchesCase = false
    @State private var addsToVocabulary = true
    /// Places the search matches; `nil` while it is being counted.
    @State private var occurrences: Int?
    @State private var isReplacing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Suchen", text: $search)
                    TextField("Ersetzen durch", text: $replacement)
                    Toggle("Groß- und Kleinschreibung beachten", isOn: $matchesCase)
                } footer: {
                    Text(occurrenceText)
                }
                if note.kind.hasAudio {
                    Section {
                        Toggle("Zum eigenen Vokabular hinzufügen", isOn: $addsToVocabulary)
                            .disabled(trimmedReplacement.isEmpty || isInVocabulary)
                    } footer: {
                        Text(vocabularyText)
                    }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Suchen und ersetzen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Alle ersetzen", action: replace)
                        .disabled((occurrences ?? 0) == 0 || isReplacing || !note.isEditable)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 320)
        .task(id: "\(search)|\(matchesCase)") {
            occurrences = nil
            // Counting decodes the transcript; it waits until the user stops typing.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            occurrences = editor.occurrences(of: search, in: note, matchesCase: matchesCase)
        }
    }

    private var trimmedReplacement: String {
        replacement.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isInVocabulary: Bool {
        settings.transcription.vocabulary.contains { $0.caseInsensitiveCompare(trimmedReplacement) == .orderedSame }
    }

    private var occurrenceText: String {
        guard !search.trimmingCharacters(in: .whitespaces).isEmpty else {
            return String(localized: "Ganze Wörter werden ersetzt; die Zeitstempel bleiben erhalten. Bleibt „Ersetzen durch“ leer, wird das Wort entfernt.")
        }
        switch occurrences {
        case nil: return String(localized: "Wird gezählt …")
        case 0: return String(localized: "Kommt im Text nicht vor.")
        case 1: return String(localized: "Kommt einmal vor.")
        case let count?: return String(localized: "Kommt \(count)-mal vor.")
        }
    }

    private var vocabularyText: String {
        if isInVocabulary {
            return String(localized: "„\(trimmedReplacement)“ steht schon im eigenen Vokabular.")
        }
        return String(localized: "Die Spracherkennung bevorzugt dann diese Schreibweise in neuen Transkripten.")
    }

    private func replace() {
        isReplacing = true
        Task {
            defer { isReplacing = false }
            do {
                try await editor.replace(search, with: replacement, in: note, matchesCase: matchesCase)
                if note.kind.hasAudio, addsToVocabulary, !trimmedReplacement.isEmpty, !isInVocabulary {
                    settings.transcription.vocabulary.append(trimmedReplacement)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
