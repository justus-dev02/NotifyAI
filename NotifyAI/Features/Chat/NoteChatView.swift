//
//  NoteChatView.swift
//  NotifyAI
//

import SwiftUI

/// "Notizen fragen": a conversation about all notes.
struct NoteChatView: View {
    @Environment(NoteChatModel.self) private var chat
    @Environment(KnowledgeIndexService.self) private var knowledge
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.large) {
                        if chat.messages.isEmpty {
                            introduction
                        }
                        ForEach(chat.messages) { message in
                            ChatMessageView(message: message, onOpen: open)
                                .id(message.id)
                        }
                    }
                    .padding(Theme.Spacing.large)
                    .frame(maxWidth: Theme.readableWidth)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: chat.messages.last?.id) {
                    if let id = chat.messages.last?.id {
                        withAnimation { proxy.scrollTo(id, anchor: .top) }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
            .navigationTitle("Notizen fragen")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Neue Unterhaltung", systemImage: "square.and.pencil") {
                        chat.reset()
                    }
                    .disabled(chat.messages.isEmpty)
                }
            }
        }
        .task {
            knowledge.scheduleRefresh()
            isInputFocused = true
        }
    }

    // MARK: Parts

    private var introduction: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            Label("Frag deine Notizen", systemImage: "bubble.left.and.text.bubble.right")
                .font(.title2.bold())
            Text("Stell Fragen in normaler Sprache, zum Beispiel zu Personen, Themen oder Zeiträumen. Die Antworten stammen nur aus deinen Notizen und nennen ihre Quellen.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                ForEach(NoteChatModel.suggestions, id: \.self) { suggestion in
                    Button {
                        chat.send(suggestion)
                    } label: {
                        Label(suggestion, systemImage: "sparkle.magnifyingglass")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.Spacing.medium)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            if case .unavailable(let reason) = chat.modelAvailability {
                Label("\(reason) Ich zeige dann die passenden Stellen statt einer formulierten Antwort.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if knowledge.isIndexing {
                Label("Notizen werden für die Suche vorbereitet …", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(knowledge.index.notes.count) Notizen durchsuchbar")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: Theme.Spacing.small) {
            TextField("Frag etwas zu deinen Notizen …", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .focused($isInputFocused)
                .onSubmit(send)
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.vertical, Theme.Spacing.small)

            if chat.isResponding {
                Button("Abbrechen", systemImage: "stop.circle.fill") { chat.cancel() }
                    .labelStyle(.iconOnly)
                    .font(.title2)
            } else {
                Button("Senden", systemImage: "arrow.up.circle.fill", action: send)
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .padding(Theme.Spacing.small)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: Theme.readableWidth)
        .frame(maxWidth: .infinity)
    }

    private func send() {
        let question = draft
        draft = ""
        chat.send(question)
    }

    private func open(_ noteID: UUID, _ time: TimeInterval?) {
        navigation.open(noteID: noteID, at: time)
        dismiss()
    }
}

// MARK: - Messages

private struct ChatMessageView: View {
    let message: ChatMessage
    let onOpen: (UUID, TimeInterval?) -> Void

    var body: some View {
        switch message.role {
        case .user:
            Text(message.text)
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.vertical, Theme.Spacing.small)
                .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        case .assistant:
            assistantMessage
        }
    }

    @ViewBuilder
    private var assistantMessage: some View {
        if message.isPending {
            HStack(spacing: Theme.Spacing.small) {
                ProgressView().controlSize(.small)
                Text("Durchsuche deine Notizen …")
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                if !message.filters.isEmpty {
                    FlowLayout(spacing: Theme.Spacing.xSmall) {
                        ForEach(message.filters, id: \.self) { filter in
                            Tag(text: filter, systemImage: "line.3.horizontal.decrease")
                        }
                    }
                }

                if !message.text.isEmpty {
                    Text(Self.formatted(message.text))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let notice = message.notice {
                    Label(notice, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !message.sources.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        Text("Quellen")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(message.sources) { source in
                            SourceCard(source: source) { onOpen(source.noteID, source.start) }
                        }
                    }
                }

                let sourceNotes = Set(message.sources.map(\.noteID))
                let otherNotes = message.notes.filter { !sourceNotes.contains($0.noteID) }
                if !otherNotes.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        Text(message.sources.isEmpty ? "Passende Notizen" : "Weitere passende Notizen")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(otherNotes.prefix(8)) { note in
                            NoteLinkRow(note: note) { onOpen(note.noteID, nil) }
                        }
                    }
                }
            }
        }
    }

    /// Source numbers like "[2]" are shown as small superscript badges.
    static func formatted(_ text: String) -> AttributedString {
        var result = AttributedString()
        var remainder = Substring(text)
        while let match = remainder.firstMatch(of: /\[(\d+)\]/) {
            result += AttributedString(String(remainder[..<match.range.lowerBound]))
            var badge = AttributedString(String(match.1))
            badge.font = .caption2.weight(.bold)
            badge.foregroundColor = .accentColor
            badge.baselineOffset = 5
            result += badge
            remainder = remainder[match.range.upperBound...]
        }
        result += AttributedString(String(remainder))
        return result
    }
}

private struct SourceCard: View {
    let source: ChatSource
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                HStack(spacing: Theme.Spacing.small) {
                    Text("\(source.number)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(.tint, in: Circle())
                    Text(source.noteTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let start = source.start {
                        Label(TimeFormatting.timestamp(start), systemImage: "play.circle")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tint)
                    } else if source.isSummary {
                        Label("Zusammenfassung", systemImage: "sparkles")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(source.noteDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(source.excerpt)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
            }
            .padding(Theme.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(source.start == nil ? "Öffnet die Notiz" : "Öffnet die Notiz an dieser Stelle")
    }
}

private struct NoteLinkRow: View {
    let note: ChatNoteLink
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Theme.Spacing.medium) {
                NoteKindIcon(kind: note.kind, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(([note.date.formatted(date: .abbreviated, time: .omitted)] + note.reasons).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
