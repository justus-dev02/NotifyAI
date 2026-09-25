//
//  NoteTemplate.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//  Updated with Rich Templates & Domain Presets.
//

import Foundation

struct NoteTemplate: Identifiable, Codable, Hashable {
    enum Audience: String, CaseIterable, Codable, Identifiable {
        case sales
        case team
        case leadership
        case education
        case product

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .sales: return "Vertrieb"
            case .team: return "Team & Daily"
            case .leadership: return "Leadership"
            case .education: return "Vorlesung & Bildung"
            case .product: return "Produkt & UX"
            }
        }

        var icon: String {
            switch self {
            case .sales: return "briefcase.fill"
            case .team: return "person.3.fill"
            case .leadership: return "chart.line.uptrend.xyaxis"
            case .education: return "book.fill"
            case .product: return "sparkles"
            }
        }
    }

    let id: UUID
    var title: String
    var description: String
    var defaultPrompt: String
    var audiences: [Audience]
    var placeholderContext: String

    init(
        id: UUID = UUID(),
        title: String,
        description: String,
        defaultPrompt: String,
        audiences: [Audience],
        placeholderContext: String = ""
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.defaultPrompt = defaultPrompt
        self.audiences = audiences
        self.placeholderContext = placeholderContext
    }
}

extension NoteTemplate {
    static let defaultTemplates: [NoteTemplate] = [
        NoteTemplate(
            title: "Vertriebs- & Kundencall",
            description: "Fokus auf Kundenbedürfnisse, Einwände, Budget und nächste Schritte.",
            defaultPrompt: "Fokussiere auf Kundenzufriedenheit, Einwände und Verkaufsabschluss.",
            audiences: [.sales, .leadership],
            placeholderContext: "z.B. Enterprise Pitch bei Neukunde"
        ),
        NoteTemplate(
            title: "Team Sync & Daily Scrum",
            description: "Gestern erreicht, heutige Prioritäten, Blocker und Sprint-Aufgaben.",
            defaultPrompt: "Extrahiere Sprint-Fortschritte, Blocker und To-Dos für Entwickler.",
            audiences: [.team, .product],
            placeholderContext: "z.B. Sprint 24 Daily Sync"
        ),
        NoteTemplate(
            title: "1:1 Mitarbeitergespräch",
            description: "Feedback, Zielvereinbarungen, persönliche Entwicklung und Unterstützung.",
            defaultPrompt: "Strukturiere nach Zielerreichung, Feedback und Entwicklungsfeldern.",
            audiences: [.leadership, .team],
            placeholderContext: "z.B. Quartals-Review mit Sarah"
        ),
        NoteTemplate(
            title: "Vorlesung & Workshop",
            description: "Kapitelgliederung, Definitionen, Kernkonzepte und Prüfungsfragen.",
            defaultPrompt: "Erstelle strukturierte Studiennotizen mit Definitionen und Lernzielen.",
            audiences: [.education],
            placeholderContext: "z.B. Informatik II - Vorlesung 5"
        ),
        NoteTemplate(
            title: "User Interview & UX Research",
            description: "Nutzer-Pain-Points, Zitate, Feature-Wünsche und Usability-Feedback.",
            defaultPrompt: "Extrahiere Insights, Pain Points und Zitate.",
            audiences: [.product, .leadership],
            placeholderContext: "z.B. Feedback zum neuen Onboarding"
        )
    ]
}
