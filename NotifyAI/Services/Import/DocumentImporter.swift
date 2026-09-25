//
//  DocumentImporter.swift
//  NotifyAI
//

import AVFoundation
import Foundation
import PDFKit
import UniformTypeIdentifiers
import Vision

enum ImportError: LocalizedError {
    case unsupportedType
    case accessDenied
    case noTextFound
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .unsupportedType: "Dieser Dateityp wird nicht unterstützt."
        case .accessDenied: "Auf die Datei konnte nicht zugegriffen werden."
        case .noTextFound: "In der Datei wurde kein Text gefunden."
        case .unreadableFile: "Die Datei konnte nicht gelesen werden."
        }
    }
}

/// Extracts content from files the user imports. Everything runs on device.
enum DocumentImporter {
    enum Content: Sendable {
        case audio(duration: TimeInterval)
        case text(String, kind: NoteKind)
    }

    static let supportedTypes: [UTType] = [.audio, .pdf, .image]

    /// Reads a file picked by the user. Security-scoped access is handled here.
    static func content(of url: URL, languages: [TranscriptionLanguage]) async throws -> Content {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { url.stopAccessingSecurityScopedResource() }
        }

        guard let type = UTType(filenameExtension: url.pathExtension) else {
            throw ImportError.unsupportedType
        }
        if type.conforms(to: .audio) {
            let duration = try await AVURLAsset(url: url).load(.duration).seconds
            return .audio(duration: duration.isFinite ? duration : 0)
        }
        if type.conforms(to: .pdf) {
            return .text(try pdfText(at: url), kind: .document)
        }
        if type.conforms(to: .image) {
            let data = try Data(contentsOf: url)
            return .text(try await recognizedText(inImageData: data, languages: languages), kind: .image)
        }
        throw ImportError.unsupportedType
    }

    static func pdfText(at url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else { throw ImportError.unreadableFile }
        let pages = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
        let text = pages.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ImportError.noTextFound }
        return text
    }

    /// On-device text recognition with Vision.
    static func recognizedText(inImageData data: Data, languages: [TranscriptionLanguage]) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages.map { Locale.Language(identifier: $0.id) }

        let observations = try await request.perform(on: data)
        let text = observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ImportError.noTextFound }
        return text
    }
}
