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
            case .team: return "Team"
            case .leadership: return "Leadership"
            case .education: return "Vorlesung"
            case .product: return "Produkt"
            }
        }
    }

    let id: UUID
    var title: String
    var description: String
    var defaultPrompt: String
    var audiences: [Audience]

    init(id: UUID = UUID(),
         title: String,
         description: String,
         defaultPrompt: String,
         audiences: [Audience]) {
        self.id = id
        self.title = title
        self.description = description
        self.defaultPrompt = defaultPrompt
        self.audiences = audiences
    }
}
