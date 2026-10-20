//
//  HTTPTransport.swift
//  NotifyAIServices
//

import Foundation

/// Sends HTTP requests for the integrations; tests replace it.
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession` without cookies, cache or stored credentials.
struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw IntegrationError.invalidResponse }
        return (data, http)
    }
}

/// Why an export to another service failed, in words the user can act on.
public enum IntegrationError: LocalizedError, Equatable {
    case notConfigured(String)
    case invalidAddress
    case invalidNotionPage
    case unauthorized
    case notFound
    case rateLimited
    case server(Int)
    case invalidResponse
    case folderUnavailable

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let service):
            String(localized: "\(service) ist noch nicht eingerichtet. Du findest die Einstellung unter „Integrationen“.", bundle: .module)
        case .invalidAddress:
            String(localized: "Die Webhook-Adresse ist ungültig. Sie muss mit https:// beginnen (http:// nur für localhost).", bundle: .module)
        case .invalidNotionPage:
            String(localized: "Der Notion-Link enthält keine Seiten-ID. Kopiere den Link der Seite über „Teilen“ → „Link kopieren“.", bundle: .module)
        case .unauthorized:
            String(localized: "Der Zugang wurde abgelehnt. Prüfe den Schlüssel und ob die Seite für die Integration freigegeben ist.", bundle: .module)
        case .notFound:
            String(localized: "Das Ziel wurde nicht gefunden. In Notion muss die Seite über „Verbindungen“ für die Integration freigegeben sein.", bundle: .module)
        case .rateLimited:
            String(localized: "Der Dienst hat zu viele Anfragen erhalten. Bitte versuche es in einer Minute erneut.", bundle: .module)
        case .server(let status):
            String(localized: "Der Dienst hat mit Fehler \(status) geantwortet.", bundle: .module)
        case .invalidResponse:
            String(localized: "Der Dienst hat unerwartet geantwortet.", bundle: .module)
        case .folderUnavailable:
            String(localized: "Auf den Obsidian-Ordner kann nicht mehr zugegriffen werden. Wähle ihn in den Einstellungen erneut aus.", bundle: .module)
        }
    }

    /// The error for an HTTP status that is not a success.
    static func from(status: Int) -> Self? {
        switch status {
        case 200..<300: nil
        case 401, 403: .unauthorized
        case 404: .notFound
        case 429: .rateLimited
        default: .server(status)
        }
    }
}
