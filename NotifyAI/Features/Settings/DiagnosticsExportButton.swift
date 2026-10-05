//
//  DiagnosticsExportButton.swift
//  NotifyAI
//

import NotifyAIServices
import SwiftUI
import UniformTypeIdentifiers

/// Creates a diagnosis report and lets the user save or share it. Nothing is sent
/// anywhere automatically.
struct DiagnosticsExportButton: View {
    @Environment(StorageMaintenance.self) private var storage
    @State private var document: DiagnosticsDocument?
    @State private var isCreating = false

    var body: some View {
        Button {
            createReport()
        } label: {
            if isCreating {
                ProgressView().controlSize(.small)
            } else {
                Text("Diagnosebericht exportieren …")
            }
        }
        .disabled(isCreating)
        .fileExporter(
            isPresented: Binding(get: { document != nil }, set: { if !$0 { document = nil } }),
            document: document,
            contentType: .plainText,
            defaultFilename: "NotifyAI-Diagnose"
        ) { _ in
            document = nil
        }
    }

    private func createReport() {
        isCreating = true
        Task {
            let report = await storage.makeDiagnosticsReport(appVersion: Bundle.main.versionDescription)
            document = DiagnosticsDocument(text: report)
            isCreating = false
        }
    }
}

struct DiagnosticsDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]

    let text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

extension Bundle {
    /// "1.0 (1)".
    var versionDescription: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
        return "\(version) (\(build))"
    }
}
