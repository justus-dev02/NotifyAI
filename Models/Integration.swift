import Foundation

struct Integration: Identifiable, Hashable, Codable {
    enum Kind: String, CaseIterable, Codable, Identifiable {
        case notion
        case googleDrive
        case googleDocs
        case calendar
        case zoom

        var id: String { rawValue }

        var iconName: String {
            switch self {
            case .notion: return "n.circle.fill"
            case .googleDrive: return "triangle.fill"
            case .googleDocs: return "doc.fill"
            case .calendar: return "calendar"
            case .zoom: return "video.fill"
            }
        }

        var title: String {
            switch self {
            case .notion: return "Notion"
            case .googleDrive: return "Google Drive"
            case .googleDocs: return "Google Docs"
            case .calendar: return "Kalender"
            case .zoom: return "Zoom"
            }
        }
    }

    let id: UUID
    var kind: Kind
    var isConnected: Bool
    var details: String

    init(id: UUID = UUID(), kind: Kind, isConnected: Bool = false, details: String = "") {
        self.id = id
        self.kind = kind
        self.isConnected = isConnected
        self.details = details
    }
}
