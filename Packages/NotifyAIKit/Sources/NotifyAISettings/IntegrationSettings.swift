//
//  IntegrationSettings.swift
//  NotifyAISettings
//

import Foundation
import NotifyAISupport
import Observation

/// Where notes go besides the app: an Obsidian folder, a Notion page, a webhook. Everything is
/// off until the user sets it up; the secrets live in the keychain (`IntegrationService`).
@MainActor
@Observable
public final class IntegrationSettings {
    private enum Key {
        static let obsidianBookmark = "integrations.obsidian.bookmark"
        static let obsidianFolderName = "integrations.obsidian.folderName"
        static let obsidianAutomatic = "integrations.obsidian.automatic"
        static let notionPage = "integrations.notion.page"
        static let notionAutomatic = "integrations.notion.automatic"
        static let webhookURL = "integrations.webhook.url"
        static let webhookAutomatic = "integrations.webhook.automatic"
        static let includesTranscript = "integrations.includesTranscript"
        static let redactsPersonalData = "integrations.redactsPersonalData"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// The bookmark of the chosen Obsidian folder.
    public package(set) var obsidianBookmark: Data? {
        didSet { defaults.set(obsidianBookmark, forKey: Key.obsidianBookmark) }
    }

    /// The folder's name, for showing which one is chosen.
    public package(set) var obsidianFolderName: String? {
        didSet { defaults.set(obsidianFolderName, forKey: Key.obsidianFolderName) }
    }

    /// Writes every finished note into the Obsidian folder.
    public var obsidianAutomatic: Bool {
        didSet { defaults.set(obsidianAutomatic, forKey: Key.obsidianAutomatic) }
    }

    /// The Notion page new notes are created under (its link or ID).
    public var notionPage: String {
        didSet { defaults.set(notionPage, forKey: Key.notionPage) }
    }

    /// Sends every finished note to Notion.
    public var notionAutomatic: Bool {
        didSet { defaults.set(notionAutomatic, forKey: Key.notionAutomatic) }
    }

    /// The address finished notes are posted to (Zapier, Make, n8n, an own server).
    public var webhookURL: String {
        didSet { defaults.set(webhookURL, forKey: Key.webhookURL) }
    }

    /// Posts every finished note to the webhook.
    public var webhookAutomatic: Bool {
        didSet { defaults.set(webhookAutomatic, forKey: Key.webhookAutomatic) }
    }

    /// Whether exports to Notion and the webhook contain the transcript (the Obsidian file
    /// always does: it stays on the device).
    public var includesTranscript: Bool {
        didSet { defaults.set(includesTranscript, forKey: Key.includesTranscript) }
    }

    /// Replaces e-mail addresses, phone numbers and IBANs in everything that is exported.
    public var redactsPersonalData: Bool {
        didSet { defaults.set(redactsPersonalData, forKey: Key.redactsPersonalData) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        obsidianBookmark = defaults.data(forKey: Key.obsidianBookmark)
        obsidianFolderName = defaults.string(forKey: Key.obsidianFolderName)
        obsidianAutomatic = defaults.bool(forKey: Key.obsidianAutomatic)
        notionPage = defaults.string(forKey: Key.notionPage) ?? ""
        notionAutomatic = defaults.bool(forKey: Key.notionAutomatic)
        webhookURL = defaults.string(forKey: Key.webhookURL) ?? ""
        webhookAutomatic = defaults.bool(forKey: Key.webhookAutomatic)
        includesTranscript = defaults.bool(forKey: Key.includesTranscript)
        redactsPersonalData = defaults.bool(forKey: Key.redactsPersonalData)
    }
}
