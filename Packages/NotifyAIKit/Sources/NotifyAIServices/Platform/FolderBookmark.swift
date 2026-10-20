//
//  FolderBookmark.swift
//  NotifyAIServices
//

import Foundation

/// Lasting access to a folder the user chose (the Obsidian vault): a bookmark that is stored
/// and resolved again, with the security scope the sandbox requires.
enum FolderBookmark {
    /// A bookmark for a folder the user just picked.
    static func make(for folder: URL) throws -> Data {
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        return try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    /// The folder of a bookmark and, if the folder moved, a renewed bookmark to store.
    static func resolve(_ bookmark: Data) throws -> (folder: URL, renewed: Data?) {
        var isStale = false
        #if os(macOS)
        let folder = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
        #else
        let folder = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        #endif
        return (folder, isStale ? try? make(for: folder) : nil)
    }

    /// Runs `work` with access to the folder.
    static func withAccess<Result>(to folder: URL, _ work: () throws -> Result) rethrows -> Result {
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        return try work()
    }
}
