//
//  TranscriptView.swift
//  NotifyAI
//

import DesignSystem
import NotifyAICore
import NotifyAIPersistence
import NotifyAIServices
import SwiftUI

/// The transcript with marker highlighting and playback synchronisation.
///
/// Words within `Marker.highlightPadding` seconds before and after each marker get a
/// highlight background. While audio plays, the spoken word is emphasised and the view
/// can follow along. Tapping a segment starts playback there.
struct TranscriptView: View {
    let note: Note
    @Bindable var model: NoteDetailModel
    let scrollProxy: ScrollViewProxy
    @State private var naming: SpeakerNamingRequest?
    /// The corrected texts while correcting, by segment; `nil` otherwise.
    @State private var drafts: [TranscriptSegment.ID: String]?
    @State private var isSaving = false
    @Environment(TranscriptEditor.self) private var editor
    @Environment(UserNotices.self) private var notices

    var body: some View {
        if !note.kind.hasAudio {
            documentText
        } else if model.segments.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                controls
                if !note.speakers.isEmpty {
                    SpeakerOverview(note: note) { naming = $0 }
                }
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    ForEach(model.segments) { segment in
                        let isCurrent = segment.id == currentSegmentID
                        TranscriptRow(
                            segment: segment,
                            highlights: model.showsHighlights ? model.highlights : nil,
                            markers: markers(in: segment),
                            currentTime: isCurrent ? model.player.currentTime : nil,
                            speakerMenu: hasSpeakers ? SegmentSpeakerMenu(note: note, segment: segment) { naming = $0 } : nil,
                            draft: draftBinding(for: segment)
                        ) {
                            model.play(from: segment.start)
                        }
                        .id(segment.id)
                    }
                }
            }
            .sheet(item: $naming) { request in
                SpeakerNamingSheet(note: note, request: request)
            }
            .onChange(of: currentSegmentID) { _, segmentID in
                guard model.followsPlayback, model.player.isPlaying, let segmentID else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    scrollProxy.scrollTo(segmentID, anchor: .center)
                }
            }
        }
    }

    private var currentSegmentID: UUID? { model.currentSegmentID }

    /// Speaker labels and their menus appear once the transcript has speakers.
    private var hasSpeakers: Bool {
        !note.speakers.isEmpty || model.segments.contains { $0.speaker != nil }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            if drafts != nil {
                correctionBar
            }
            HStack(spacing: Theme.Spacing.large) {
                Toggle(isOn: $model.showsHighlights) {
                    Label("Markierungen hervorheben", systemImage: "highlighter")
                }
                .disabled(model.markers.isEmpty)
                if model.player.isLoaded {
                    Toggle(isOn: $model.followsPlayback) {
                        Label("Mitlesen", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                }
                if drafts == nil {
                    Button("Korrigieren", systemImage: "pencil") {
                        drafts = [:]
                    }
                    .disabled(!note.isEditable)
                }
            }
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)

            if !model.markers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.small) {
                        ForEach(model.markers) { marker in
                            Button {
                                jump(to: marker)
                            } label: {
                                Label(TimeFormatting.timestamp(marker.time), systemImage: "star.fill")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .tint(Theme.marker)
                            .controlSize(.small)
                            .accessibilityLabel("Markierung bei \(TimeFormatting.timestamp(marker.time))")
                        }
                    }
                }
            }
        }
    }

    // MARK: Correcting

    private var correctionBar: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Label("Text direkt bearbeiten. Ein leerer Abschnitt wird entfernt.", systemImage: "pencil")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Verwerfen", role: .cancel) { drafts = nil }
            Button("Fertig", action: saveCorrections)
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
    }

    /// The editable text of a segment while correcting.
    private func draftBinding(for segment: TranscriptSegment) -> Binding<String>? {
        guard drafts != nil else { return nil }
        return Binding(
            get: { drafts?[segment.id] ?? segment.text },
            set: { drafts?[segment.id] = $0 }
        )
    }

    private func saveCorrections() {
        guard let drafts else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await editor.apply(drafts, to: note)
                self.drafts = nil
            } catch {
                notices.post(UserNotice(title: String(localized: "Korrektur nicht gesichert"), message: error.localizedDescription))
            }
        }
    }

    // MARK: States

    private var documentText: some View {
        Text(note.bodyText)
            .textSelection(.enabled)
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var emptyState: some View {
        if note.status.isProcessing || note.status == .recording {
            ContentUnavailableView("Transkript folgt", systemImage: "waveform", description: Text("Das Transkript wird gerade erstellt."))
        } else {
            ContentUnavailableView("Kein Transkript", systemImage: "waveform.slash", description: Text("Für diese Aufnahme gibt es noch kein Transkript."))
        }
    }

    // MARK: Helpers

    private func markers(in segment: TranscriptSegment) -> [Marker] {
        model.markers.filter { segment.timeRange.contains($0.time) }
    }

    private func jump(to marker: Marker) {
        let target = model.segments.last { $0.start <= marker.time } ?? model.segments.first
        if let target {
            withAnimation { scrollProxy.scrollTo(target.id, anchor: .center) }
        }
        if model.player.isLoaded {
            model.play(from: max(0, marker.time - Marker.highlightPadding))
        }
    }
}

// MARK: - Row

private struct TranscriptRow: View {
    let segment: TranscriptSegment
    let highlights: HighlightWindows?
    let markers: [Marker]
    /// Playback position, only set for the segment that is currently playing.
    let currentTime: TimeInterval?
    /// The speaker of the segment with its actions; `nil` without speakers.
    let speakerMenu: SegmentSpeakerMenu?
    /// The text being corrected; `nil` unless the transcript is being corrected.
    let draft: Binding<String>?
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
            Button(action: onTap) {
                Text(TimeFormatting.timestamp(segment.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(currentTime != nil ? Color.accentColor : .secondary)
                    .frame(minWidth: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ab \(TimeFormatting.timestamp(segment.start)) abspielen")

            VStack(alignment: .leading, spacing: 4) {
                if speakerMenu != nil || !markers.isEmpty {
                    HStack(spacing: Theme.Spacing.small) {
                        if let speakerMenu {
                            speakerMenu
                        }
                        ForEach(markers) { marker in
                            Label(TimeFormatting.timestamp(marker.time), systemImage: "star.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.marker)
                        }
                    }
                }
                if let draft {
                    TextField("Text", text: draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineSpacing(3)
                        .padding(6)
                        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                } else {
                    Text(attributedText)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, Theme.Spacing.small)
        .background(
            currentTime != nil ? Color.accentColor.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            // While correcting, a tap places the cursor instead of starting playback.
            if draft == nil { onTap() }
        }
    }

    /// Builds the text word by word so highlights cover exactly the marker windows.
    private var attributedText: AttributedString {
        guard !segment.words.isEmpty else {
            var text = AttributedString(segment.text)
            if let highlights, highlights.intersects(segment.timeRange) {
                text.backgroundColor = Theme.highlight
            }
            return text
        }

        var result = AttributedString()
        var previousWasHighlighted = false
        for (index, word) in segment.words.enumerated() {
            // Leading whitespace is only highlighted between two highlighted words, so a
            // highlighted passage starts exactly at its first word.
            let leading = String(word.text.prefix(while: \.isWhitespace))
            let core = String(word.text.dropFirst(leading.count))
            let isHighlighted = highlights?.contains(word) ?? false

            if index > 0, !leading.isEmpty {
                var space = AttributedString(leading)
                if isHighlighted, previousWasHighlighted {
                    space.backgroundColor = Theme.highlight
                }
                result += space
            }

            var part = AttributedString(core)
            if isHighlighted {
                part.backgroundColor = Theme.highlight
            }
            if let currentTime, word.start <= currentTime, currentTime < max(word.end, word.start + 0.2) {
                part.foregroundColor = .accentColor
                part.font = .body.weight(.semibold)
            }
            result += part
            previousWasHighlighted = isHighlighted
        }
        return result
    }
}
