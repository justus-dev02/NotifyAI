//
//  WebhookClient.swift
//  NotifyAIServices
//

import CryptoKit
import Foundation
import NotifyAICore

/// Posts a finished note as JSON to an address of the user (Zapier, Make, n8n, an own server).
///
/// With a secret, every request is signed: `X-NotifyAI-Signature` is
/// `sha256=` + hex(HMAC-SHA256(secret, timestamp + "." + body)), the timestamp is sent in
/// `X-NotifyAI-Timestamp`. The receiver can check that the note comes from this app and was
/// not replayed. Only HTTPS is allowed, except for the own computer (`localhost`).
struct WebhookClient {
    let transport: any HTTPTransport

    typealias Payload = WebhookPayload

    /// The address, if it is one the app may post to.
    static func validatedURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host()?.lowercased() else { return nil }
        switch url.scheme?.lowercased() {
        case "https": return url
        case "http": return ["localhost", "127.0.0.1", "::1"].contains(host) ? url : nil
        default: return nil
        }
    }

    static func payload(for snapshot: MarkdownExporter.NoteSnapshot, options: MarkdownExporter.Options) -> Payload {
        let redactsPersonalData = options.redactsPersonalData
        let redact = { (text: String) -> String in redactsPersonalData ? Redactor.redact(text) : text }
        let summary = snapshot.summary.map { summary in
            Payload.Summary(
                overview: redact(summary.overview),
                keyPoints: summary.keyPoints.map(redact),
                decisions: summary.decisions.map(redact),
                actionItems: summary.actionItems.map { Payload.Task(task: redact($0.task), owner: $0.owner, due: $0.due, isDone: $0.isDone) },
                openQuestions: summary.openQuestions.map(redact),
                topics: summary.topics.map { Payload.Section(title: $0.title, points: $0.points.map(redact)) },
                sections: summary.templateSections.map { Payload.Section(title: $0.title, points: $0.points.map(redact)) }
            )
        }
        let transcript = options.includesTranscript
            ? snapshot.segments.map { Payload.Line(start: $0.start, end: $0.end, speaker: $0.speaker, text: redact($0.text)) }
            : nil
        return Payload(note: Payload.Note(
            id: snapshot.id,
            title: redact(snapshot.title),
            createdAt: snapshot.createdAt,
            duration: snapshot.duration,
            participants: snapshot.participants,
            keywords: snapshot.keywords,
            labels: snapshot.labels,
            summary: summary,
            markdown: MarkdownExporter().markdown(for: snapshot, options: options),
            transcript: transcript
        ))
    }

    func post(_ payload: Payload, to url: URL, secret: String?, now: Date = .now) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(payload)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("NotifyAI", forHTTPHeaderField: "User-Agent")
        if let secret, !secret.isEmpty {
            let timestamp = String(Int(now.timeIntervalSince1970))
            request.setValue(timestamp, forHTTPHeaderField: "X-NotifyAI-Timestamp")
            request.setValue("sha256=" + Self.signature(of: body, timestamp: timestamp, secret: secret), forHTTPHeaderField: "X-NotifyAI-Signature")
        }
        let (_, response) = try await transport.send(request)
        if let error = IntegrationError.from(status: response.statusCode) { throw error }
    }

    static func signature(of body: Data, timestamp: String, secret: String) -> String {
        var message = Data(timestamp.utf8)
        message.append(Data(".".utf8))
        message.append(body)
        let code = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(secret.utf8)))
        return code.map { String(format: "%02x", $0) }.joined()
    }
}

/// The JSON a webhook receives.
struct WebhookPayload: Encodable {
    struct Note: Encodable {
        let id: UUID
        let title: String
        let createdAt: Date
        let duration: TimeInterval
        let participants: [String]
        let keywords: [String]
        let labels: [String]
        let summary: Summary?
        let markdown: String
        let transcript: [Line]?
    }

    struct Summary: Encodable {
        let overview: String
        let keyPoints: [String]
        let decisions: [String]
        let actionItems: [Task]
        let openQuestions: [String]
        let topics: [Section]
        let sections: [Section]
    }

    struct Task: Encodable {
        let task: String
        let owner: String?
        let due: String?
        let isDone: Bool
    }

    struct Section: Encodable {
        let title: String
        let points: [String]
    }

    struct Line: Encodable {
        let start: TimeInterval
        let end: TimeInterval
        let speaker: String?
        let text: String
    }

    let event = "note.ready"
    let note: Note
}
