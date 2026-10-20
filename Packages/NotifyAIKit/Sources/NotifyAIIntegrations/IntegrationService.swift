//
//  IntegrationService.swift
//  NotifyAIIntegrations
//

import Foundation
import NotifyAICore
import NotifyAIExport
import NotifyAIPersistence
import NotifyAIProcessing
import NotifyAISettings
import NotifyAISupport
import Observation
import OSLog

/// A place outside the app that notes can be sent to.
public enum IntegrationTarget: String, CaseIterable, Identifiable, Sendable {
    case obsidian
    case notion
    case webhook

    public var id: String { rawValue }

    /// Product names; they are not translated.
    public var name: String {
        switch self {
        case .obsidian: "Obsidian"
        case .notion: "Notion"
        case .webhook: "Webhook"
        }
    }

    public var symbolName: String {
        switch self {
        case .obsidian: "folder"
        case .notion: "square.stack"
        case .webhook: "arrow.up.forward.app"
        }
    }
}

/// What happened when a note was sent somewhere.
public enum IntegrationEvent: Sendable {
    case exported(IntegrationTarget, noteID: UUID, location: URL?)
    case failed(IntegrationTarget, noteID: UUID, message: String)
}

/// Sends notes to Obsidian, Notion and webhooks: on request, and automatically when a note is
/// ready if the user turned that on.
///
/// Nothing leaves the device unless the user set up a target. The Obsidian folder stays on the
/// device; Notion and webhooks are network services, which the settings say plainly. Secrets
/// are kept in the keychain. Sending a note to Notion again moves the previous page to the
/// trash and creates it anew, so the page always shows the current state.
@MainActor
@Observable
public final class IntegrationService {
    /// Results of automatic exports, for notices.
    @ObservationIgnored public let events = EventChannel<IntegrationEvent>()
    /// Targets that are sending right now, by note.
    public private(set) var sending: [UUID: Set<IntegrationTarget>] = [:]
    /// Whether the keychain holds the Notion key / the webhook's signing secret.
    public private(set) var hasNotionToken = false
    public private(set) var hasWebhookSecret = false

    @ObservationIgnored private let store: NoteStore
    @ObservationIgnored private let settings: IntegrationSettings
    @ObservationIgnored private let secrets: any SecretStoring
    @ObservationIgnored private let transport: any HTTPTransport
    @ObservationIgnored private let stateURL: URL?
    @ObservationIgnored private var notionPages: [UUID: String]
    @ObservationIgnored private var subscriptions: [EventSubscription] = []
    @ObservationIgnored private var automaticExports: Task<Void, Never>?

    static let notionTokenAccount = "notion.token"
    static let webhookSecretAccount = "webhook.secret"

    package init(
        store: NoteStore,
        settings: IntegrationSettings,
        processing: ProcessingCoordinator,
        secrets: any SecretStoring = KeychainSecretStore(),
        transport: any HTTPTransport = URLSessionTransport(),
        stateURL: URL?
    ) {
        self.store = store
        self.settings = settings
        self.secrets = secrets
        self.transport = transport
        self.stateURL = stateURL
        notionPages = stateURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([UUID: String].self, from: $0) } ?? [:]
        hasNotionToken = secrets.secret(for: Self.notionTokenAccount) != nil
        hasWebhookSecret = secrets.secret(for: Self.webhookSecretAccount) != nil
        processing.events.subscribe { [weak self] event in
            guard case .noteReady(let noteID) = event else { return }
            self?.noteBecameReady(noteID)
        }.store(in: &subscriptions)
    }

    // MARK: - Setup

    public func isConfigured(_ target: IntegrationTarget) -> Bool {
        switch target {
        case .obsidian: settings.obsidianBookmark != nil
        case .notion: hasNotionToken && NotionClient.pageID(from: settings.notionPage) != nil
        case .webhook: WebhookClient.validatedURL(settings.webhookURL) != nil
        }
    }

    public func isAutomatic(_ target: IntegrationTarget) -> Bool {
        switch target {
        case .obsidian: settings.obsidianAutomatic
        case .notion: settings.notionAutomatic
        case .webhook: settings.webhookAutomatic
        }
    }

    /// Remembers the folder the user picked for Obsidian.
    public func setObsidianFolder(_ folder: URL) throws {
        settings.obsidianBookmark = try FolderBookmark.make(for: folder)
        settings.obsidianFolderName = folder.lastPathComponent
    }

    public func removeObsidianFolder() {
        settings.obsidianBookmark = nil
        settings.obsidianFolderName = nil
        settings.obsidianAutomatic = false
    }

    public func setNotionToken(_ token: String?) throws {
        try secrets.setSecret(token?.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.notionTokenAccount)
        hasNotionToken = secrets.secret(for: Self.notionTokenAccount) != nil
        if !hasNotionToken { settings.notionAutomatic = false }
    }

    public func setWebhookSecret(_ secret: String?) throws {
        try secrets.setSecret(secret?.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.webhookSecretAccount)
        hasWebhookSecret = secrets.secret(for: Self.webhookSecretAccount) != nil
    }

    /// Whether a link or text contains a Notion page ID.
    public static func isNotionPage(_ text: String) -> Bool {
        NotionClient.pageID(from: text) != nil
    }

    // MARK: - Sending

    /// Sends the note to a target.
    /// - Returns: Where it went: the file, the Notion page, or `nil` for a webhook.
    @discardableResult
    public func send(_ note: Note, to target: IntegrationTarget) async throws -> URL? {
        let noteID = note.id
        sending[noteID, default: []].insert(target)
        defer { sending[noteID]?.remove(target) }
        let snapshot = MarkdownExporter.NoteSnapshot(note: note, segments: note.decodedTranscript())
        switch target {
        case .obsidian: return try await sendToObsidian(snapshot)
        case .notion: return try await sendToNotion(snapshot)
        case .webhook:
            try await sendToWebhook(snapshot)
            return nil
        }
    }

    private func sendToObsidian(_ snapshot: MarkdownExporter.NoteSnapshot) async throws -> URL {
        guard let bookmark = settings.obsidianBookmark else { throw IntegrationError.notConfigured(IntegrationTarget.obsidian.name) }
        let resolved: (folder: URL, renewed: Data?)
        do {
            resolved = try FolderBookmark.resolve(bookmark)
        } catch {
            throw IntegrationError.folderUnavailable
        }
        if let renewed = resolved.renewed { settings.obsidianBookmark = renewed }
        // The file stays on the device, so it always has the transcript.
        let options = MarkdownExporter.Options(includesTranscript: true, redactsPersonalData: settings.redactsPersonalData)
        return try await Self.write(snapshot, options: options, to: resolved.folder)
    }

    @concurrent
    private static func write(_ snapshot: MarkdownExporter.NoteSnapshot, options: MarkdownExporter.Options, to folder: URL) async throws -> URL {
        try FolderBookmark.withAccess(to: folder) {
            guard FileManager.default.isWritableFile(atPath: folder.path(percentEncoded: false)) else { throw IntegrationError.folderUnavailable }
            return try ObsidianExporter().export(snapshot, options: options, to: folder)
        }
    }

    private func sendToNotion(_ snapshot: MarkdownExporter.NoteSnapshot) async throws -> URL? {
        guard let token = secrets.secret(for: Self.notionTokenAccount) else { throw IntegrationError.notConfigured(IntegrationTarget.notion.name) }
        guard let parent = NotionClient.pageID(from: settings.notionPage) else { throw IntegrationError.invalidNotionPage }
        let client = NotionClient(token: token, transport: transport)
        let document = ExportDocument(note: snapshot, options: exportOptions)
        let page = try await client.createPage(document, parentPageID: parent)
        if let previous = notionPages[snapshot.id] {
            do {
                try await client.archivePage(previous)
            } catch {
                // The new page exists; an old one that cannot be archived is only a leftover.
                Logger.processing.error("Archiving the previous Notion page failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        notionPages[snapshot.id] = page.id
        saveState()
        return page.url
    }

    private func sendToWebhook(_ snapshot: MarkdownExporter.NoteSnapshot) async throws {
        guard let url = WebhookClient.validatedURL(settings.webhookURL) else {
            throw settings.webhookURL.isEmpty ? IntegrationError.notConfigured(IntegrationTarget.webhook.name) : IntegrationError.invalidAddress
        }
        let payload = WebhookClient.payload(for: snapshot, options: exportOptions)
        try await WebhookClient(transport: transport).post(payload, to: url, secret: secrets.secret(for: Self.webhookSecretAccount))
    }

    /// Network targets carry the transcript only if the user wants that.
    private var exportOptions: MarkdownExporter.Options {
        MarkdownExporter.Options(includesTranscript: settings.includesTranscript, redactsPersonalData: settings.redactsPersonalData)
    }

    // MARK: - Automatic

    /// Sends a note that just became ready to every target set to automatic, one after another.
    private func noteBecameReady(_ noteID: UUID) {
        let targets = IntegrationTarget.allCases.filter { isAutomatic($0) && isConfigured($0) }
        guard !targets.isEmpty else { return }
        let previous = automaticExports
        automaticExports = Task { [weak self] in
            await previous?.value
            for target in targets {
                await self?.sendAutomatically(noteID, to: target)
            }
        }
    }

    private func sendAutomatically(_ noteID: UUID, to target: IntegrationTarget) async {
        guard let note = store.note(id: noteID), note.status == .ready else { return }
        do {
            let location = try await send(note, to: target)
            events.send(.exported(target, noteID: noteID, location: location))
        } catch {
            Logger.processing.error("Sending to \(target.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            events.send(.failed(target, noteID: noteID, message: error.localizedDescription))
        }
    }

    private func saveState() {
        guard let stateURL else { return }
        do {
            try JSONEncoder().encode(notionPages).write(to: stateURL, options: .atomic)
        } catch {
            Logger.processing.error("Saving the integration state failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
