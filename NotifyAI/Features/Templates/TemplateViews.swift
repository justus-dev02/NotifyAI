//
//  TemplateViews.swift
//  NotifyAI
//

import DesignSystem
import NotifyAICore
import NotifyAIPersistence
import NotifyAIServices
import SwiftData
import SwiftUI

extension RecordingController.Draft {
    /// The kind of conversation or the user's template, as one choice.
    var templateChoice: SummaryTemplateChoice {
        get { templateID.map(SummaryTemplateChoice.custom) ?? .focus(focus) }
        set {
            switch newValue {
            case .focus(let focus):
                self.focus = focus
                templateID = nil
            case .custom(let id):
                templateID = id
            }
        }
    }
}

/// The options of a template picker: the built-in kinds of conversation and the user's own
/// templates.
struct TemplateChoiceOptions: View {
    var showsSymbols = true
    @Query(sort: \SummaryTemplate.name) private var templates: [SummaryTemplate]

    var body: some View {
        ForEach(RecordingFocus.allCases) { focus in
            option(focus.title, systemImage: focus.symbolName).tag(SummaryTemplateChoice.focus(focus))
        }
        if !templates.isEmpty {
            Divider()
            ForEach(templates) { template in
                option(template.name, systemImage: template.symbolName).tag(SummaryTemplateChoice.custom(template.id))
            }
        }
    }

    @ViewBuilder
    private func option(_ title: String, systemImage: String) -> some View {
        if showsSymbols {
            Label(title, systemImage: systemImage)
        } else {
            Text(title)
        }
    }
}

/// "Mit Vorlage neu zusammenfassen": the templates as a menu.
struct ResummarizeWithTemplateMenu: View {
    let note: Note

    var body: some View {
        Menu("Mit Vorlage neu zusammenfassen", systemImage: "doc.text.magnifyingglass") {
            TemplateChoiceButtons(note: note)
        }
        .disabled(note.status.isProcessing || !note.hasText)
    }
}

/// One button per template; choosing one summarizes the note again with it. The current one
/// has a check mark.
struct TemplateChoiceButtons: View {
    let note: Note
    @Environment(SummaryTemplates.self) private var templates
    @Query(sort: \SummaryTemplate.name) private var custom: [SummaryTemplate]

    var body: some View {
        ForEach(RecordingFocus.allCases) { focus in
            choiceButton(.focus(focus), title: focus.title, systemImage: focus.symbolName)
        }
        if !custom.isEmpty {
            Divider()
            ForEach(custom) { template in
                choiceButton(.custom(template.id), title: template.name, systemImage: template.symbolName)
            }
        }
    }

    private func choiceButton(_ choice: SummaryTemplateChoice, title: String, systemImage: String) -> some View {
        Button {
            templates.summarize(note, with: choice)
        } label: {
            if templates.choice(for: note) == choice {
                Label(title, systemImage: "checkmark")
            } else {
                Label(title, systemImage: systemImage)
            }
        }
    }
}

// MARK: - Settings

/// The templates: the default for new notes, the built-in ones and the user's own.
struct TemplateSettingsSection: View {
    @Query(sort: \SummaryTemplate.name) private var templates: [SummaryTemplate]
    @Environment(SummaryTemplates.self) private var library
    @Environment(AppSettings.self) private var settings
    @State private var editing: TemplateEditing?
    @State private var errorMessage: String?

    var body: some View {
        @Bindable var analysis = settings.analysis

        Group {
            Section {
                Picker("Standard für neue Notizen", selection: $analysis.defaultTemplate) {
                    TemplateChoiceOptions()
                }
                ForEach(RecordingFocus.allCases) { focus in
                    BuiltInTemplateRow(
                        focus: focus,
                        isDefault: analysis.defaultTemplate == .focus(focus),
                        onUseAsDefault: { analysis.defaultTemplate = .focus(focus) },
                        onAdapt: { editing = TemplateEditing(template: nil, draft: SummaryTemplates.draft(basedOn: focus)) }
                    )
                }
            } header: {
                Text("Vorlagen für Zusammenfassungen")
            } footer: {
                Text("Jede Notiz wird mit einer Vorlage zusammengefasst. Du wählst sie vor der Aufnahme bei „Art des Gesprächs“ oder später in der Notiz. Eine mitgelieferte Vorlage kannst du als eigene anpassen.")
            }
            Section {
                ForEach(templates) { template in
                    Button {
                        editing = TemplateEditing(template: template)
                    } label: {
                        HStack {
                            Label(template.name, systemImage: template.symbolName)
                            Spacer()
                            if analysis.defaultTemplate == .custom(template.id) {
                                DefaultBadge()
                            }
                            Text(summary(of: template))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Als Standard verwenden", systemImage: "checkmark.circle") { analysis.defaultTemplate = .custom(template.id) }
                        Button("Löschen", systemImage: "trash", role: .destructive) { delete(template) }
                    }
                }
                .onDelete { offsets in
                    offsets.map { templates[$0] }.forEach(delete)
                }
                Button("Neue Vorlage …", systemImage: "plus") {
                    editing = TemplateEditing(template: nil)
                }
            } header: {
                Text("Eigene Vorlagen")
            } footer: {
                Text("Eigene Vorlagen legen fest, worauf die Zusammenfassung achtet, welche Abschnitte sie hat und welche eigenen Überschriften sie füllt.")
            }
        }
        .sheet(item: $editing) { editing in
            TemplateEditorSheet(template: editing.template, initialDraft: editing.draft)
        }
        .alert("Nicht gelöscht", isPresented: Binding(presenting: $errorMessage)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func summary(of template: SummaryTemplate) -> String {
        template.customHeadings.isEmpty
            ? String(localized: "\(template.sections.count) Abschnitte")
            : String(localized: "\(template.sections.count) Abschnitte · \(template.customHeadings.count) eigene")
    }

    private func delete(_ template: SummaryTemplate) {
        do {
            try library.delete(template)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A built-in template: what it pays attention to, and using or adapting it.
private struct BuiltInTemplateRow: View {
    let focus: RecordingFocus
    let isDefault: Bool
    let onUseAsDefault: () -> Void
    let onAdapt: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: focus.symbolName)
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(focus.title)
                Text(focus.summaryDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if isDefault {
                DefaultBadge()
            }
            Menu {
                actions
            } label: {
                Label("Optionen", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .contextMenu { actions }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Als Standard verwenden", systemImage: "checkmark.circle", action: onUseAsDefault)
            .disabled(isDefault)
        Button("Als eigene Vorlage anpassen …", systemImage: "square.and.pencil", action: onAdapt)
    }
}

/// "Standard" next to the default template.
private struct DefaultBadge: View {
    var body: some View {
        Text("Standard")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tint.opacity(0.15), in: Capsule())
            .foregroundStyle(.tint)
    }
}

/// A template to edit, or a new one, possibly based on a built-in one.
private struct TemplateEditing: Identifiable {
    let id = UUID()
    let template: SummaryTemplate?
    var draft: SummaryTemplates.Draft?
}

/// Creates or edits a template.
struct TemplateEditorSheet: View {
    let template: SummaryTemplate?
    /// The fields a new template starts with, e.g. those of a built-in one.
    var initialDraft: SummaryTemplates.Draft?
    @Environment(SummaryTemplates.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var draft = SummaryTemplates.Draft()
    @State private var newHeading = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    Picker("Symbol", selection: $draft.symbolName) {
                        ForEach(SummaryTemplates.symbols, id: \.self) { symbol in
                            Image(systemName: symbol).tag(symbol)
                        }
                    }
                }
                Section {
                    TextField("Worauf soll die Zusammenfassung achten?", text: $draft.instructions, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("Anweisungen")
                } footer: {
                    Text("Zum Beispiel: „Achte auf Wünsche und Einwände des Kunden, Budget und Zeitplan.“")
                }
                Section("Abschnitte") {
                    ForEach(SummarySection.allCases) { section in
                        Toggle(section.title, isOn: binding(for: section))
                    }
                }
                Section {
                    ForEach(draft.headings, id: \.self) { heading in
                        Text(heading)
                    }
                    .onDelete { draft.headings.remove(atOffsets: $0) }
                    .onMove { draft.headings.move(fromOffsets: $0, toOffset: $1) }
                    HStack {
                        TextField("Neue Überschrift", text: $newHeading)
                            .onSubmit(addHeading)
                        Button("Hinzufügen", systemImage: "plus.circle.fill", action: addHeading)
                            .labelStyle(.iconOnly)
                            .disabled(newHeading.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Eigene Überschriften")
                } footer: {
                    Text("Jede Überschrift wird mit den passenden Punkten aus dem Gespräch gefüllt, etwa „Risiken“ oder „Nächste Termine“. Benötigt Apple Intelligence.")
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(template == nil ? String(localized: "Neue Vorlage") : String(localized: "Vorlage bearbeiten"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern", action: save)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 560)
        .onAppear {
            if let template {
                draft = SummaryTemplates.Draft(template)
            } else if let initialDraft {
                draft = initialDraft
            }
        }
    }

    private func binding(for section: SummarySection) -> Binding<Bool> {
        Binding(
            get: { draft.sections.contains(section) },
            set: { isOn in
                if isOn { draft.sections.formUnion([section]) } else { draft.sections.remove(section) }
            }
        )
    }

    private func addHeading() {
        let heading = newHeading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heading.isEmpty, !draft.headings.contains(heading) else { return }
        draft.headings.append(heading)
        newHeading = ""
    }

    private func save() {
        do {
            if let template {
                try library.update(template, with: draft)
            } else {
                try library.create(draft)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension SummarySection {
    var title: String {
        switch self {
        case .keyPoints: String(localized: "Kernpunkte")
        case .decisions: String(localized: "Entscheidungen")
        case .actionItems: String(localized: "Aufgaben")
        case .openQuestions: String(localized: "Offene Fragen")
        case .topics: String(localized: "Themen")
        }
    }
}
