//
//  ImportHubView.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//  Updated with Real PDF Text Extraction, Vision OCR & Web Reader.
//

import SwiftUI
import PDFKit
import Vision
import UniformTypeIdentifiers

struct ImportHubView: View {
    @EnvironmentObject private var notesVM: NotesViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var webURLString: String = ""
    @State private var isShowingFilePicker = false
    @State private var isShowingImagePicker = false
    @State private var selectedImage: UIImage?
    @State private var isProcessing = false
    @State private var statusMessage = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    headerSection

                    if isProcessing {
                        processingIndicator
                    }

                    if let error = errorMessage {
                        errorBanner(error)
                    }

                    // 1. Web Article Reader
                    webSection

                    // 2. PDF Document Import
                    pdfSection

                    // 3. Document OCR Scan
                    ocrSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 40)
            }
            .liquidGlassBackground()
            .navigationTitle("Import & Capture Hub")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(
                isPresented: $isShowingFilePicker,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false
            ) { result in
                handlePDFSelection(result: result)
            }
            .sheet(isPresented: $isShowingImagePicker) {
                ImagePicker(image: $selectedImage) { img in
                    handleImageOCR(image: img)
                }
            }
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down.on.square.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.indigo)

            Text("Inhalte importieren & scannen")
                .font(.title2.bold())
                .foregroundStyle(Color.adaptiveLabel)

            Text("Wandle Webseiten, PDF-Dokumente oder Whiteboard-Fotos lokal in strukturierte Notizen um.")
                .font(.subheadline)
                .foregroundStyle(Color.adaptiveSecondaryLabel)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Processing Indicator

    private var processingIndicator: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(Color.indigo)
            Text(statusMessage)
                .font(.subheadline.bold())
                .foregroundStyle(Color.indigo)
            Spacer()
        }
        .padding(14)
        .background(Color.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(msg)
                .font(.caption)
                .foregroundStyle(.red)
            Spacer()
        }
        .padding(12)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Web Section

    private var webSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Web-Artikel & Links", systemImage: "globe")
                .font(.headline)
                .foregroundStyle(Color.adaptiveLabel)

            TextField("https://beispiel.de/artikel", text: $webURLString)
                .font(.subheadline)
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)

            Button {
                extractWebContent()
            } label: {
                HStack {
                    Image(systemName: "doc.text.magnifyingglass")
                    Text("Artikelinhalt laden & zusammenfassen")
                }
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(webURLString.trimmingCharacters(in: .whitespaces).isEmpty ? Color.gray.opacity(0.4) : Color.indigo, in: RoundedRectangle(cornerRadius: 14))
            }
            .disabled(webURLString.trimmingCharacters(in: .whitespaces).isEmpty || isProcessing)
        }
        .liquidGlassCard(cornerRadius: 22, padding: 18)
    }

    // MARK: - PDF Section

    private var pdfSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("PDF Dokument importieren", systemImage: "doc.richtext.fill")
                .font(.headline)
                .foregroundStyle(Color.adaptiveLabel)

            Text("Extrahiere den Text aus Vorlesungsfolien, Verträgen oder Berichten.")
                .font(.caption)
                .foregroundStyle(Color.adaptiveSecondaryLabel)

            Button {
                isShowingFilePicker = true
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("PDF auswählen")
                }
                .font(.subheadline.bold())
                .foregroundStyle(Color.indigo)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.indigo.opacity(0.3), lineWidth: 1))
            }
            .disabled(isProcessing)
        }
        .liquidGlassCard(cornerRadius: 22, padding: 18)
    }

    // MARK: - OCR Section

    private var ocrSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Foto & Whiteboard OCR", systemImage: "viewfinder.rectangular")
                .font(.headline)
                .foregroundStyle(Color.adaptiveLabel)

            Text("Nutze Apple Vision Texterkennung für handschriftliche Notizen oder Schilder.")
                .font(.caption)
                .foregroundStyle(Color.adaptiveSecondaryLabel)

            Button {
                isShowingImagePicker = true
            } label: {
                HStack {
                    Image(systemName: "camera.fill")
                    Text("Bild aus Mediathek scannen")
                }
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.indigo, in: RoundedRectangle(cornerRadius: 14))
            }
            .disabled(isProcessing)
        }
        .liquidGlassCard(cornerRadius: 22, padding: 18)
    }

    // MARK: - Actions

    private func extractWebContent() {
        guard let url = URL(string: webURLString.trimmingCharacters(in: .whitespaces)),
              url.scheme == "http" || url.scheme == "https" else {
            errorMessage = "Bitte eine gültige URL eingeben (inklusive https://)."
            return
        }

        isProcessing = true
        statusMessage = "Webseite wird geladen…"
        errorMessage = nil

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let htmlString = String(data: data, encoding: .utf8) else {
                    throw NSError(domain: "Import", code: -1, userInfo: [NSLocalizedDescriptionKey: "Konnte Text nicht decodieren."])
                }

                // Strip HTML tags for clean text
                let plainText = htmlString
                    .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let cleanText = String(plainText.prefix(8000))
                await processExtractedText(cleanText, title: url.host ?? "Web-Artikel", sourceType: .web)
            } catch {
                await MainActor.run {
                    self.errorMessage = "Fehler beim Laden: \(error.localizedDescription)"
                    self.isProcessing = false
                }
            }
        }
    }

    private func handlePDFSelection(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "Zugriff auf die Datei verweigert."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            guard let pdfDoc = PDFDocument(url: url) else {
                errorMessage = "PDF konnte nicht geladen werden."
                return
            }

            var fullText = ""
            for i in 0..<min(pdfDoc.pageCount, 30) {
                if let page = pdfDoc.page(at: i), let pageText = page.string {
                    fullText += pageText + "\n"
                }
            }

            let title = url.deletingPathExtension().lastPathComponent
            Task {
                await processExtractedText(fullText, title: title, sourceType: .pdf)
            }

        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func handleImageOCR(image: UIImage) {
        guard let cgImage = image.cgImage else { return }
        isProcessing = true
        statusMessage = "Vision Texterkennung läuft…"
        errorMessage = nil

        let request = VNRecognizeTextRequest { request, error in
            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                DispatchQueue.main.async {
                    self.errorMessage = "Kein Text im Bild erkannt."
                    self.isProcessing = false
                }
                return
            }

            let recognizedStrings = observations.compactMap { $0.topCandidates(1).first?.string }
            let fullText = recognizedStrings.joined(separator: "\n")

            Task {
                await self.processExtractedText(fullText, title: "Scan \(Date().formatted(date: .abbreviated, time: .shortened))", sourceType: .image)
            }
        }
        request.recognitionLanguages = ["de-DE", "en-US"]
        request.recognitionLevel = .accurate

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            try? handler.perform([request])
        }
    }

    private func processExtractedText(_ text: String, title: String, sourceType: SourceType) async {
        await MainActor.run {
            self.statusMessage = "KI-Zusammenfassung wird erstellt…"
        }

        let summary = await ServiceLocator.shared.llm.summarize(transcript: text)
        let mindmap = (try? await ServiceLocator.shared.highlight.makeMindmap(transcript: text)) ?? Mindmap(root: title, children: [])

        var note = Note(title: title)
        note.sourceType = sourceType
        note.summary = summary
        note.mindmap = mindmap
        note.pipeline.stage = .done
        note.pipeline.progress = 1.0

        await ServiceLocator.shared.storage.save(note)
        await notesVM.load()

        await MainActor.run {
            self.isProcessing = false
            self.dismiss()
        }
    }
}

// MARK: - ImagePicker Helper

struct ImagePicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    var onImagePicked: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker

        init(_ parent: ImagePicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let uiImage = info[.originalImage] as? UIImage {
                parent.image = uiImage
                parent.onImagePicked(uiImage)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

#Preview {
    ImportHubView()
        .environmentObject(NotesViewModel())
}
