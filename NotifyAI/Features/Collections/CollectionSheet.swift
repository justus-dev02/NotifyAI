//
//  CollectionSheet.swift
//  NotifyAI
//

import DesignSystem
import NotifyAICore
import NotifyAIPersistence
import NotifyAIServices
import SwiftData
import SwiftUI

/// Chooses the notes for a summary across several notes: by period, label, person and
/// template, or the notes a question found, each of which can be left out.
struct CollectionSheet: View {
    let request: CollectionRequest
    /// Called after the summary was created and opened.
    var onCreated: () -> Void = {}
    @Environment(NoteCollections.self) private var collections
    @Environment(NoteLabels.self) private var labels
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SummaryTemplate.name) private var templates: [SummaryTemplate]
    /// Refreshes the list when notes change.
    @Query private var notes: [Note]

    @State private var period = CollectionPeriod.last30Days
    @State private var from = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var through = Date.now
    @State private var label: String?
    @State private var person: String?
    @State private var template: SummaryTemplateChoice?
    @State private var excluded: Set<UUID> = []
    @State private var title = ""
    @State private var isTitleEdited = false
    @State private var errorMessage: String?

    init(request: CollectionRequest, onCreated: @escaping () -> Void = {}) {
        self.request = request
        self.onCreated = onCreated
        _label = State(initialValue: request.label)
        // A question's notes are shown as found, whatever their age.
        _period = State(initialValue: request.noteIDs == nil ? .last30Days : .all)
    }

    var body: some View {
        let candidates = candidates
        let chosen = candidates.filter { !excluded.contains($0.id) }
        NavigationStack {
            Form {
                if request.noteIDs == nil {
                    filterSection(people: collections.people(in: candidates))
                }
                Section {
                    if candidates.isEmpty {
                        Text("Keine fertige Notiz mit Zusammenfassung passt zu dieser Auswahl.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(candidates) { note in
                        Toggle(isOn: binding(for: note)) {
                            CandidateRow(note: note)
                        }
                    }
                } header: {
                    Text("Notizen (\(chosen.count) von \(candidates.count))")
                } footer: {
                    if chosen.count > NoteCollections.maximumNotes {
                        Text("Zusammengefasst werden die neuesten \(NoteCollections.maximumNotes) Notizen.")
                    }
                }
                Section {
                    TextField("Titel", text: titleBinding(for: chosen))
                } footer: {
                    Text("Die Zusammenfassung wird als eigene Notiz gesichert und verweist auf ihre Notizen. Sie liest die Zusammenfassung jeder Notiz vollständig und verdichtet sie schrittweise; Aufgaben werden ohne Doppelte aus den Notizen übernommen. „Neu zusammenfassen“ liest die Notizen später erneut.")
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Notizen zusammenfassen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Zusammenfassen") { create(from: chosen) }
                        .disabled(chosen.count < 2)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 560)
    }

    // MARK: Filters

    private func filterSection(people: [String]) -> some View {
        Section("Welche Notizen?") {
            Picker("Zeitraum", selection: $period) {
                ForEach(CollectionPeriod.allCases) { period in
                    Text(period.title).tag(period)
                }
            }
            if period == .custom {
                DatePicker("Von", selection: $from, displayedComponents: .date)
                DatePicker("Bis", selection: $through, in: from..., displayedComponents: .date)
            }
            let usages = labels.all()
            if !usages.isEmpty {
                Picker("Label", selection: $label) {
                    Text("Alle").tag(String?.none)
                    ForEach(usages) { usage in
                        Text(usage.name).tag(String?.some(usage.name))
                    }
                }
            }
            if !people.isEmpty || person != nil {
                Picker("Person", selection: $person) {
                    Text("Alle").tag(String?.none)
                    ForEach(people, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
            }
            Picker("Vorlage", selection: $template) {
                Text("Alle").tag(SummaryTemplateChoice?.none)
                ForEach(RecordingFocus.allCases) { focus in
                    Text(focus.title).tag(SummaryTemplateChoice?.some(.focus(focus)))
                }
                ForEach(templates) { template in
                    Text(template.name).tag(SummaryTemplateChoice?.some(.custom(template.id)))
                }
            }
        }
    }

    private var filter: CollectionFilter {
        let range = period.range(customFrom: from, customThrough: through)
        return CollectionFilter(from: range?.from, through: range?.through, label: label, person: person, template: template)
    }

    private var candidates: [Note] {
        _ = notes.count
        if let ids = request.noteIDs {
            return collections.candidates(withIDs: ids)
        }
        return collections.candidates(matching: filter)
    }

    private func binding(for note: Note) -> Binding<Bool> {
        Binding(
            get: { !excluded.contains(note.id) },
            set: { isOn in
                if isOn { excluded.remove(note.id) } else { excluded.formUnion([note.id]) }
            }
        )
    }

    /// The suggested title follows the choice until the user writes their own.
    private func titleBinding(for chosen: [Note]) -> Binding<String> {
        Binding(
            get: { isTitleEdited ? title : collections.suggestedTitle(for: chosen) },
            set: {
                title = $0
                isTitleEdited = true
            }
        )
    }

    private func create(from chosen: [Note]) {
        do {
            let title = isTitleEdited ? title : collections.suggestedTitle(for: chosen)
            let note = try collections.create(from: chosen, title: title)
            navigation.filter = .all
            navigation.labelFilter = nil
            navigation.selectedNoteID = note.id
            dismiss()
            onCreated()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A note in the choice: title, date, kind of conversation and labels.
private struct CandidateRow: View {
    let note: Note
    @Environment(SummaryTemplates.self) private var templates

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title)
                .lineLimit(1)
            Text(details)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var details: String {
        var parts = [note.createdAt.formatted(date: .abbreviated, time: .omitted), templates.template(for: note)?.name ?? note.focus.title]
        parts += note.labels
        return parts.joined(separator: " · ")
    }
}

/// The periods to choose notes from.
enum CollectionPeriod: String, CaseIterable, Identifiable {
    case last7Days, last30Days, last90Days, thisYear, all, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .last7Days: String(localized: "Letzte 7 Tage")
        case .last30Days: String(localized: "Letzte 30 Tage")
        case .last90Days: String(localized: "Letzte 90 Tage")
        case .thisYear: String(localized: "Dieses Jahr")
        case .all: String(localized: "Alle")
        case .custom: String(localized: "Eigener Zeitraum")
        }
    }

    /// The first and last day; `nil` for all notes.
    func range(customFrom: Date, customThrough: Date, now: Date = .now, calendar: Calendar = .current) -> (from: Date, through: Date)? {
        func daysBack(_ days: Int) -> (Date, Date)? {
            calendar.date(byAdding: .day, value: -days, to: now).map { ($0, now) }
        }
        return switch self {
        case .last7Days: daysBack(7)
        case .last30Days: daysBack(30)
        case .last90Days: daysBack(90)
        case .thisYear: calendar.dateInterval(of: .year, for: now).map { ($0.start, now) }
        case .all: nil
        case .custom: (customFrom, customThrough)
        }
    }
}
