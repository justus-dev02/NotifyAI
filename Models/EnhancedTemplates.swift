//
//  EnhancedTemplates.swift
//  NotifyAI
//
//  Created by AI Assistant on 23.10.25.
//

import Foundation

// MARK: - Enhanced Note Template

struct EnhancedNoteTemplate: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var description: String
    var category: TemplateCategory
    var audience: [TemplateAudience]
    var defaultPrompt: String
    var fields: [TemplateField]
    var processingSteps: [TemplateProcessingStep]
    var icon: String
    var color: String
    
    init(
        id: UUID = UUID(),
        title: String,
        description: String,
        category: TemplateCategory,
        audience: [TemplateAudience],
        defaultPrompt: String,
        fields: [TemplateField] = [],
        processingSteps: [TemplateProcessingStep] = [],
        icon: String = "doc.text",
        color: String = "#6E5DE7"
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.category = category
        self.audience = audience
        self.defaultPrompt = defaultPrompt
        self.fields = fields
        self.processingSteps = processingSteps
        self.icon = icon
        self.color = color
    }
}

// MARK: - Template Categories

enum TemplateCategory: String, CaseIterable, Identifiable, Codable {
    case meeting = "meeting"
    case education = "education"
    case business = "business"
    case personal = "personal"
    case creative = "creative"
    case technical = "technical"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .meeting: return "Meetings"
        case .education: return "Bildung"
        case .business: return "Business"
        case .personal: return "Persönlich"
        case .creative: return "Kreativ"
        case .technical: return "Technisch"
        }
    }
    
    var icon: String {
        switch self {
        case .meeting: return "person.3.fill"
        case .education: return "book.fill"
        case .business: return "briefcase.fill"
        case .personal: return "person.fill"
        case .creative: return "paintbrush.fill"
        case .technical: return "gear.fill"
        }
    }
}

// MARK: - Template Audiences

enum TemplateAudience: String, CaseIterable, Identifiable, Codable {
    case executive = "executive"
    case team = "team"
    case individual = "individual"
    case students = "students"
    case clients = "clients"
    case stakeholders = "stakeholders"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .executive: return "Führungskräfte"
        case .team: return "Team"
        case .individual: return "Einzeln"
        case .students: return "Studenten"
        case .clients: return "Kunden"
        case .stakeholders: return "Stakeholder"
        }
    }
}

// MARK: - Template Fields

struct TemplateField: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var type: FieldType
    var isRequired: Bool
    var placeholder: String
    var options: [String]?
    
    init(
        id: UUID = UUID(),
        name: String,
        type: FieldType,
        isRequired: Bool = false,
        placeholder: String = "",
        options: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.isRequired = isRequired
        self.placeholder = placeholder
        self.options = options
    }
}

enum FieldType: String, CaseIterable, Codable {
    case text = "text"
    case textArea = "textArea"
    case select = "select"
    case multiSelect = "multiSelect"
    case date = "date"
    case time = "time"
    case number = "number"
    case boolean = "boolean"
    
    var displayName: String {
        switch self {
        case .text: return "Text"
        case .textArea: return "Mehrzeiliger Text"
        case .select: return "Auswahl"
        case .multiSelect: return "Mehrfachauswahl"
        case .date: return "Datum"
        case .time: return "Zeit"
        case .number: return "Zahl"
        case .boolean: return "Ja/Nein"
        }
    }
}

// MARK: - Processing Steps

struct TemplateProcessingStep: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var description: String
    var isEnabled: Bool
    var order: Int
    
    init(
        id: UUID = UUID(),
        name: String,
        description: String,
        isEnabled: Bool = true,
        order: Int
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.isEnabled = isEnabled
        self.order = order
    }
}

// MARK: - Template Library

class TemplateLibrary: ObservableObject {
    @Published var templates: [EnhancedNoteTemplate] = []
    
    init() {
        loadDefaultTemplates()
    }
    
    private func loadDefaultTemplates() {
        templates = [
            // Meeting Templates
            EnhancedNoteTemplate(
                title: "Team Meeting",
                description: "Strukturiertes Team-Meeting mit Agenda und Action Items",
                category: .meeting,
                audience: [.team, .executive],
                defaultPrompt: "Erstelle eine strukturierte Zusammenfassung des Team-Meetings mit Fokus auf Entscheidungen, Action Items und nächste Schritte.",
                fields: [
                    TemplateField(name: "Agenda", type: .textArea, isRequired: true, placeholder: "Meeting-Agenda eingeben"),
                    TemplateField(name: "Teilnehmer", type: .multiSelect, isRequired: true, placeholder: "Teilnehmer auswählen"),
                    TemplateField(name: "Dauer", type: .time, isRequired: false, placeholder: "Meeting-Dauer")
                ],
                processingSteps: [
                    TemplateProcessingStep(name: "Transkription", description: "Audio zu Text konvertieren", order: 1),
                    TemplateProcessingStep(name: "Sprechererkennung", description: "Teilnehmer identifizieren", order: 2),
                    TemplateProcessingStep(name: "Zusammenfassung", description: "Wichtigste Punkte extrahieren", order: 3),
                    TemplateProcessingStep(name: "Action Items", description: "Aufgaben identifizieren", order: 4),
                    TemplateProcessingStep(name: "Mindmap", description: "Strukturierte Darstellung erstellen", order: 5)
                ],
                icon: "person.3.fill",
                color: "#4A90E2"
            ),
            
            EnhancedNoteTemplate(
                title: "1:1 Meeting",
                description: "Persönliches Gespräch mit Fokus auf Entwicklung und Feedback",
                category: .meeting,
                audience: [.individual, .executive],
                defaultPrompt: "Erstelle eine vertrauliche Zusammenfassung des 1:1 Meetings mit Fokus auf persönliche Entwicklung, Ziele und Feedback.",
                fields: [
                    TemplateField(name: "Gesprächspartner", type: .text, isRequired: true, placeholder: "Name des Gesprächspartners"),
                    TemplateField(name: "Thema", type: .text, isRequired: true, placeholder: "Hauptthema des Gesprächs"),
                    TemplateField(name: "Vertraulichkeit", type: .boolean, isRequired: true, placeholder: "Vertraulich behandeln")
                ],
                processingSteps: [
                    TemplateProcessingStep(name: "Transkription", description: "Audio zu Text konvertieren", order: 1),
                    TemplateProcessingStep(name: "Zusammenfassung", description: "Wichtigste Punkte extrahieren", order: 2),
                    TemplateProcessingStep(name: "Entwicklungsziele", description: "Ziele und nächste Schritte identifizieren", order: 3)
                ],
                icon: "person.fill",
                color: "#7B68EE"
            ),
            
            // Education Templates
            EnhancedNoteTemplate(
                title: "Vorlesung",
                description: "Akademische Vorlesung mit Fokus auf Lerninhalte und Prüfungsvorbereitung",
                category: .education,
                audience: [.students, .individual],
                defaultPrompt: "Erstelle eine strukturierte Zusammenfassung der Vorlesung mit Fokus auf Lernziele, Schlüsselkonzepte und Prüfungsrelevante Inhalte.",
                fields: [
                    TemplateField(name: "Fach", type: .text, isRequired: true, placeholder: "Vorlesungsfach"),
                    TemplateField(name: "Dozent", type: .text, isRequired: false, placeholder: "Name des Dozenten"),
                    TemplateField(name: "Kapitel", type: .text, isRequired: false, placeholder: "Kapitel/Thema"),
                    TemplateField(name: "Lernziele", type: .textArea, isRequired: false, placeholder: "Lernziele der Vorlesung")
                ],
                processingSteps: [
                    TemplateProcessingStep(name: "Transkription", description: "Audio zu Text konvertieren", order: 1),
                    TemplateProcessingStep(name: "Kapitelmarken", description: "Thematische Abschnitte identifizieren", order: 2),
                    TemplateProcessingStep(name: "Zusammenfassung", description: "Wichtigste Konzepte extrahieren", order: 3),
                    TemplateProcessingStep(name: "Lernkarten", description: "Quiz-Karten generieren", order: 4),
                    TemplateProcessingStep(name: "Mindmap", description: "Wissensstruktur erstellen", order: 5)
                ],
                icon: "book.fill",
                color: "#32CD32"
            ),
            
            EnhancedNoteTemplate(
                title: "Workshop",
                description: "Interaktiver Workshop mit praktischen Übungen",
                category: .education,
                audience: [.students, .team, .individual],
                defaultPrompt: "Erstelle eine detaillierte Zusammenfassung des Workshops mit Fokus auf praktische Übungen, Erkenntnisse und Anwendungsmöglichkeiten.",
                fields: [
                    TemplateField(name: "Workshop-Titel", type: .text, isRequired: true, placeholder: "Titel des Workshops"),
                    TemplateField(name: "Trainer", type: .text, isRequired: false, placeholder: "Name des Trainers"),
                    TemplateField(name: "Dauer", type: .time, isRequired: false, placeholder: "Workshop-Dauer"),
                    TemplateField(name: "Übungen", type: .textArea, isRequired: false, placeholder: "Durchgeführte Übungen")
                ],
                processingSteps: [
                    TemplateProcessingStep(name: "Transkription", description: "Audio zu Text konvertieren", order: 1),
                    TemplateProcessingStep(name: "Übungen", description: "Praktische Übungen identifizieren", order: 2),
                    TemplateProcessingStep(name: "Zusammenfassung", description: "Wichtigste Erkenntnisse extrahieren", order: 3),
                    TemplateProcessingStep(name: "Action Items", description: "Umsetzungsaufgaben identifizieren", order: 4)
                ],
                icon: "hammer.fill",
                color: "#FF6347"
            ),
            
            // Business Templates
            EnhancedNoteTemplate(
                title: "Vertriebscall",
                description: "Kundengespräch mit Fokus auf Deal-Entwicklung und nächste Schritte",
                category: .business,
                audience: [.executive, .clients, .stakeholders],
                defaultPrompt: "Erstelle eine professionelle Zusammenfassung des Vertriebscalls mit Fokus auf Kundenbedürfnisse, Einwände, nächste Schritte und Deal-Status.",
                fields: [
                    TemplateField(name: "Kunde", type: .text, isRequired: true, placeholder: "Kundenname"),
                    TemplateField(name: "Deal-Stage", type: .select, isRequired: true, placeholder: "Deal-Phase", options: ["Lead", "Qualified", "Proposal", "Negotiation", "Closed Won", "Closed Lost"]),
                    TemplateField(name: "Wert", type: .number, isRequired: false, placeholder: "Deal-Wert"),
                    TemplateField(name: "Nächster Termin", type: .date, isRequired: false, placeholder: "Nächster Call")
                ],
                processingSteps: [
                    TemplateProcessingStep(name: "Transkription", description: "Audio zu Text konvertieren", order: 1),
                    TemplateProcessingStep(name: "Sprechererkennung", description: "Kunde vs. Vertrieb identifizieren", order: 2),
                    TemplateProcessingStep(name: "Zusammenfassung", description: "Wichtigste Punkte extrahieren", order: 3),
                    TemplateProcessingStep(name: "Einwände", description: "Kundeneinwände identifizieren", order: 4),
                    TemplateProcessingStep(name: "Nächste Schritte", description: "Follow-up Aufgaben definieren", order: 5)
                ],
                icon: "phone.fill",
                color: "#FFD700"
            ),
            
            EnhancedNoteTemplate(
                title: "Projekt-Update",
                description: "Projektstatus-Update mit Meilensteinen und Risiken",
                category: .business,
                audience: [.executive, .team, .stakeholders],
                defaultPrompt: "Erstelle ein strukturiertes Projekt-Update mit Fokus auf Fortschritt, Meilensteine, Risiken und nächste Schritte.",
                fields: [
                    TemplateField(name: "Projekt", type: .text, isRequired: true, placeholder: "Projektname"),
                    TemplateField(name: "Phase", type: .select, isRequired: true, placeholder: "Projektphase", options: ["Planung", "Entwicklung", "Testing", "Deployment", "Abgeschlossen"]),
                    TemplateField(name: "Fortschritt", type: .number, isRequired: true, placeholder: "Fortschritt in %"),
                    TemplateField(name: "Meilensteine", type: .textArea, isRequired: false, placeholder: "Erreichte Meilensteine")
                ],
                processingSteps: [
                    TemplateProcessingStep(name: "Transkription", description: "Audio zu Text konvertieren", order: 1),
                    TemplateProcessingStep(name: "Zusammenfassung", description: "Projektstatus extrahieren", order: 2),
                    TemplateProcessingStep(name: "Risiken", description: "Projektrisiken identifizieren", order: 3),
                    TemplateProcessingStep(name: "Action Items", description: "Nächste Schritte definieren", order: 4)
                ],
                icon: "chart.line.uptrend.xyaxis",
                color: "#20B2AA"
            ),
            
            // Personal Templates
            EnhancedNoteTemplate(
                title: "Tagebuch",
                description: "Persönliche Gedanken und Erlebnisse",
                category: .personal,
                audience: [.individual],
                defaultPrompt: "Erstelle eine persönliche Zusammenfassung mit Fokus auf Emotionen, Erkenntnisse und persönliche Entwicklung.",
                fields: [
                    TemplateField(name: "Stimmung", type: .select, isRequired: false, placeholder: "Wie fühlst du dich?", options: ["Sehr gut", "Gut", "Neutral", "Schlecht", "Sehr schlecht"]),
                    TemplateField(name: "Thema", type: .text, isRequired: false, placeholder: "Hauptthema des Tages"),
                    TemplateField(name: "Erkenntnisse", type: .textArea, isRequired: false, placeholder: "Was hast du heute gelernt?")
                ],
                processingSteps: [
                    TemplateProcessingStep(name: "Transkription", description: "Audio zu Text konvertieren", order: 1),
                    TemplateProcessingStep(name: "Zusammenfassung", description: "Wichtigste Gedanken extrahieren", order: 2),
                    TemplateProcessingStep(name: "Emotionen", description: "Emotionale Muster identifizieren", order: 3)
                ],
                icon: "heart.fill",
                color: "#FF69B4"
            ),
            
            // Creative Templates
            EnhancedNoteTemplate(
                title: "Brainstorming",
                description: "Kreative Ideensammlung und Konzeptentwicklung",
                category: .creative,
                audience: [.team, .individual],
                defaultPrompt: "Erstelle eine strukturierte Zusammenfassung der Brainstorming-Session mit Fokus auf Ideen, Konzepte und Umsetzungsmöglichkeiten.",
                fields: [
                    TemplateField(name: "Thema", type: .text, isRequired: true, placeholder: "Brainstorming-Thema"),
                    TemplateField(name: "Teilnehmer", type: .multiSelect, isRequired: false, placeholder: "Teilnehmer auswählen"),
                    TemplateField(name: "Ziel", type: .textArea, isRequired: false, placeholder: "Ziel der Session")
                ],
                processingSteps: [
                    TemplateProcessingStep(name: "Transkription", description: "Audio zu Text konvertieren", order: 1),
                    TemplateProcessingStep(name: "Ideen", description: "Alle Ideen sammeln", order: 2),
                    TemplateProcessingStep(name: "Kategorisierung", description: "Ideen gruppieren", order: 3),
                    TemplateProcessingStep(name: "Bewertung", description: "Ideen priorisieren", order: 4),
                    TemplateProcessingStep(name: "Mindmap", description: "Ideenstruktur erstellen", order: 5)
                ],
                icon: "lightbulb.fill",
                color: "#FFA500"
            )
        ]
    }
    
    func getTemplates(for category: TemplateCategory) -> [EnhancedNoteTemplate] {
        return templates.filter { $0.category == category }
    }
    
    func getTemplates(for audience: TemplateAudience) -> [EnhancedNoteTemplate] {
        return templates.filter { $0.audience.contains(audience) }
    }
    
    func searchTemplates(query: String) -> [EnhancedNoteTemplate] {
        let lowercaseQuery = query.lowercased()
        return templates.filter { template in
            template.title.lowercased().contains(lowercaseQuery) ||
            template.description.lowercased().contains(lowercaseQuery) ||
            template.category.displayName.lowercased().contains(lowercaseQuery)
        }
    }
}

