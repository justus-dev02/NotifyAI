//
//  IntegrationTests.swift
//  NotifyAITests
//
//  Obsidian folder, Notion and webhooks with a scripted network: what is sent, signed,
//  replaced and reported.
//

import CryptoKit
import Foundation
@testable import NotifyAI
import NotifyAICore
@testable import NotifyAIPersistence
@testable import NotifyAIServices
import Synchronization
import Testing

/// Answers requests from a script and records them.
final class ScriptedTransport: HTTPTransport {
    private let requests = Mutex<[URLRequest]>([])
    private let answer: @Sendable (URLRequest) -> (Int, [String: Any])

    init(answer: @escaping @Sendable (URLRequest) -> (Int, [String: Any]) = { _ in (200, [:]) }) {
        self.answer = answer
    }

    var recorded: [URLRequest] { requests.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.withLock { $0.append(request) }
        let (status, body) = answer(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (try JSONSerialization.data(withJSONObject: body), response)
    }
}

/// Secrets in memory instead of the keychain.
final class MemorySecrets: SecretStoring {
    private let values = Mutex<[String: String]>([:])

    func secret(for account: String) -> String? { values.withLock { $0[account] } }

    func setSecret(_ secret: String?, for account: String) throws {
        values.withLock { $0[account] = secret?.isEmpty == false ? secret : nil }
    }
}

extension URLRequest {
    var jsonBody: [String: Any] {
        httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
}

@Suite("Obsidian folder")
struct ObsidianExportTests {
    @Test("Front matter, then the Markdown; exporting again replaces the same file, also renamed")
    func exportAndReplace() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Vault-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var snapshot = ExportFixture.snapshot
        snapshot.keywords = ["Website Relaunch", "2026"]

        let file = try ObsidianExporter().export(snapshot, options: .init(), to: folder)
        let date = snapshot.createdAt.formatted(.iso8601.year().month().day())
        #expect(file.lastPathComponent == "\(date) Weekly- Relaunch.md")
        let content = try String(contentsOf: file, encoding: .utf8)
        #expect(content.hasPrefix("---\ntitle: \"Weekly: Relaunch\"\n"))
        #expect(content.contains("participants:\n  - \"Anna\"\n  - \"Eddy\""))
        // Tags without spaces; a purely numeric keyword is no tag.
        #expect(content.contains("tags:\n  - notifyai\n  - website-relaunch\n"))
        #expect(!content.contains("  - 2026"))
        #expect(content.contains("notifyai-id: \(snapshot.id.uuidString)\n---\n# Weekly: Relaunch"))

        // The user renamed the file in Obsidian; the next export finds it by its id.
        let renamed = folder.appending(path: "Relaunch Meeting.md")
        try FileManager.default.moveItem(at: file, to: renamed)
        snapshot.title = "Weekly: Relaunch (korrigiert)"
        let again = try ObsidianExporter().export(snapshot, options: .init(), to: folder)
        #expect(again.lastPathComponent == "Relaunch Meeting.md")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).count == 1)
        #expect(try String(contentsOf: again, encoding: .utf8).contains("(korrigiert)"))

        // Another note with the same title gets its own, numbered file.
        var other = ExportFixture.snapshot
        other.id = UUID()
        _ = try ObsidianExporter().export(other, options: .init(), to: folder)
        let third = try ObsidianExporter().export({ var copy = other; copy.id = UUID(); return copy }(), options: .init(), to: folder)
        #expect(third.lastPathComponent == "\(date) Weekly- Relaunch 2.md")
    }
}

@Suite("Notion")
struct NotionTests {
    @Test("Page IDs are found in links and plain IDs")
    func pageIDs() {
        let id = "0123456789abcdef0123456789abcdef"
        let formatted = "01234567-89ab-cdef-0123-456789abcdef"
        #expect(NotionClient.pageID(from: "https://www.notion.so/team/Meetings-\(id)?pvs=4") == formatted)
        #expect(NotionClient.pageID(from: formatted) == formatted)
        #expect(NotionClient.pageID(from: "https://www.notion.so/team/Meetings") == nil)
    }

    @Test("The document becomes headings, lists and to-dos; long texts are split")
    func blocks() throws {
        let blocks = NotionClient.blocks(for: ExportDocument(note: ExportFixture.snapshot))
        let types = blocks.compactMap { $0["type"] as? String }
        #expect(types.first == "paragraph")
        #expect(types.contains("heading_2") && types.contains("heading_3"))
        #expect(types.filter { $0 == "to_do" }.count == 3)
        let done = blocks.filter { $0["type"] as? String == "to_do" }.compactMap { ($0["to_do"] as? [String: Any])?["checked"] as? Bool }
        #expect(done == [false, true, false])
        let long = NotionClient.richText(String(repeating: "a", count: 4_500))
        #expect(long.count == 3)
    }

    @Test("Large notes are sent in parts of 100 blocks; sending again archives the old page")
    @MainActor
    func sendingAndReplacing() async throws {
        let counter = Mutex(0)
        let transport = ScriptedTransport { request in
            if request.url?.path().hasSuffix("/pages") == true {
                let number = counter.withLock { value -> Int in value += 1; return value }
                return (200, ["id": "page-\(number)", "url": "https://www.notion.so/page-\(number)"])
            }
            return (200, [:])
        }
        let fixture = try IntegrationFixture(transport: transport)
        let service = fixture.service
        try service.setNotionToken("ntn_secret")
        fixture.settings.notionPage = "https://www.notion.so/Meetings-0123456789abcdef0123456789abcdef"
        // The transcript makes the note long; without it only the summary is sent.
        fixture.settings.includesTranscript = true
        #expect(service.isConfigured(.notion))

        let note = try fixture.note(segments: 250)
        let url = try await service.send(note, to: .notion)
        #expect(url?.absoluteString == "https://www.notion.so/page-1")
        let create = try #require(transport.recorded.first)
        #expect(create.value(forHTTPHeaderField: "Authorization") == "Bearer ntn_secret")
        #expect(create.value(forHTTPHeaderField: "Notion-Version") == NotionClient.apiVersion)
        #expect((create.jsonBody["children"] as? [Any])?.count == 100)
        let appends = transport.recorded.filter { $0.httpMethod == "PATCH" && $0.url?.path().hasSuffix("/children") == true }
        #expect(appends.count >= 2)

        _ = try await service.send(note, to: .notion)
        let archive = try #require(transport.recorded.last { $0.url?.path().hasSuffix("/pages/page-1") == true })
        #expect(archive.jsonBody["archived"] as? Bool == true)
    }
}

@Suite("Webhooks")
struct WebhookTests {
    @Test("Only HTTPS, or HTTP to this computer")
    func addresses() {
        #expect(WebhookClient.validatedURL("https://hooks.zapier.com/hooks/catch/1/abc") != nil)
        #expect(WebhookClient.validatedURL("http://localhost:5678/webhook/notes") != nil)
        #expect(WebhookClient.validatedURL("http://example.com/hook") == nil)
        #expect(WebhookClient.validatedURL("ftp://example.com") == nil)
        #expect(WebhookClient.validatedURL("kein link") == nil)
    }

    @Test("The note is posted as signed JSON; the transcript only on request")
    func signedPayload() async throws {
        let transport = ScriptedTransport()
        let client = WebhookClient(transport: transport)
        let url = try #require(URL(string: "https://example.com/hook"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = WebhookClient.payload(for: ExportFixture.snapshot, options: .init(includesTranscript: false))
        try await client.post(payload, to: url, secret: "geheim", now: now)

        let request = try #require(transport.recorded.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-NotifyAI-Timestamp") == "1800000000")
        let body = try #require(request.httpBody)
        var message = Data("1800000000.".utf8)
        message.append(body)
        let expected = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data("geheim".utf8)))
            .map { String(format: "%02x", $0) }.joined()
        #expect(request.value(forHTTPHeaderField: "X-NotifyAI-Signature") == "sha256=" + expected)

        let json = request.jsonBody
        #expect(json["event"] as? String == "note.ready")
        let note = try #require(json["note"] as? [String: Any])
        #expect(note["title"] as? String == "Weekly: Relaunch")
        #expect(note["transcript"] == nil)
        let summary = try #require(note["summary"] as? [String: Any])
        #expect((summary["actionItems"] as? [Any])?.count == 3)
        #expect((summary["sections"] as? [[String: Any]])?.first?["title"] as? String == "Risiken")
    }

    @Test("A rejected request is an error the user can act on")
    func errors() async throws {
        let client = WebhookClient(transport: ScriptedTransport { _ in (401, [:]) })
        let payload = WebhookClient.payload(for: ExportFixture.snapshot, options: .init())
        await #expect(throws: IntegrationError.unauthorized) {
            try await client.post(payload, to: try #require(URL(string: "https://example.com/hook")), secret: nil)
        }
    }

    @Test("Ready notes go to automatic targets; failures are reported")
    @MainActor
    func automatic() async throws {
        let transport = ScriptedTransport { _ in (500, [:]) }
        let fixture = try IntegrationFixture(transport: transport)
        let service = fixture.service
        fixture.settings.webhookURL = "https://example.com/hook"
        fixture.settings.webhookAutomatic = true
        let note = try fixture.note(segments: 3)

        let event = await nextEvent(of: service.events) {
            fixture.processing.events.send(.noteReady(noteID: note.id))
        }
        #expect(transport.recorded.count == 1)
        guard case .failed(let target, let noteID, let message) = event else {
            Issue.record("Expected a failure, got \(event)")
            return
        }
        #expect(target == .webhook)
        #expect(noteID == note.id)
        #expect(message == IntegrationError.server(500).localizedDescription)
    }
}

/// A service with scripted network and secrets.
@MainActor
struct IntegrationFixture {
    let service: IntegrationService
    let store: NoteStore
    let processing: ProcessingCoordinator
    let settings: IntegrationSettings

    init(transport: ScriptedTransport) throws {
        store = try NoteStore(locations: try StorageLocations.temporary(), inMemory: true)
        let appSettings = makeIsolatedSettings()
        settings = appSettings.integrations
        let engine = MockTranscriptionEngine(kind: .appleSpeech)
        processing = ProcessingCoordinator(
            store: store,
            settings: appSettings,
            transcription: TranscriptionService(appleSpeech: engine, whisper: engine, parakeet: engine),
            summarization: SummarizationService(languageModel: MockSummarizer(), fallback: MockSummarizer(), availability: { _ in .available }),
            diarizer: SpeakerDiarizer()
        )
        service = IntegrationService(
            store: store,
            settings: settings,
            processing: processing,
            secrets: MemorySecrets(),
            transport: transport,
            stateURL: nil
        )
    }

    func note(segments count: Int) throws -> Note {
        let note = Note(title: "Weekly", isTitleUserDefined: true, kind: .recording, status: .ready)
        let segments = (0..<count).map { TranscriptSegment(start: Double($0), end: Double($0) + 0.9, text: "Satz \($0).") }
        note.setTranscript(encoded: try Transcript.encode(segments), plainText: Transcript.plainText(of: segments), engine: .whisper)
        note.summary = NoteSummary(overview: "Überblick", keyPoints: ["Punkt"], source: .appleIntelligence)
        try store.insert(note)
        return note
    }
}
