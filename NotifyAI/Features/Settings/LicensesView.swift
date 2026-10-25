//
//  LicensesView.swift
//  NotifyAI
//

import SwiftUI

/// Software and models NotifyAI contains or downloads, with the notices their licenses ask for.
///
/// The license texts are bundled from `NotifyAI/Licenses` (`License-<name>.txt`), copied
/// verbatim from the packages' checkouts; `THIRD_PARTY_NOTICES.md` lists the same entries.
/// Models are not part of the app: it downloads them from Hugging Face only when asked to in
/// the settings, so they are named with their attribution (CC BY 4.0 requires it).
struct Acknowledgement: Identifiable {
    enum Kind {
        case library
        case model
    }

    let name: String
    let kind: Kind
    /// SPDX-like name of the license, e.g. "MIT" or "CC BY 4.0".
    let license: String
    let copyright: String
    let source: String
    /// Bundled license text (`License-<file>.txt`), for licenses that ask for their text to be shipped.
    var licenseFile: String?
    /// Where the license is published, for licenses that ask for a link (Creative Commons).
    var licenseLink: String?
    /// What the entry is, where it is used and what was changed.
    var note: String?

    var id: String { name }

    /// The text of `licenseFile`, or `nil` if the entry has none.
    var licenseText: String? {
        guard let licenseFile, let url = Bundle.main.url(forResource: "License-\(licenseFile)", withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// NotifyAI itself.
    static let app = Self(
        name: "NotifyAI",
        kind: .library,
        license: "MIT",
        copyright: "Copyright (c) 2026 Justus Schmiernow",
        source: "https://github.com/justus-dev02/NotifyAI",
        licenseFile: "NotifyAI"
    )

    static var all: [Self] {
        var entries = [
            Self(
                name: "WhisperKit",
                kind: .library,
                license: "MIT",
                copyright: "Copyright (c) 2024 argmax, inc.",
                source: "https://github.com/argmaxinc/WhisperKit",
                licenseFile: "WhisperKit"
            ),
            Self(
                name: "FluidAudio",
                kind: .library,
                license: "Apache-2.0",
                copyright: "Copyright Fluid Inference",
                source: "https://github.com/FluidInference/FluidAudio",
                licenseFile: "Apache-2.0"
            ),
            Self(
                name: "VBx",
                kind: .library,
                license: "Apache-2.0",
                copyright: "Copyright 2021-2024 BUT Speech@FIT",
                source: "https://github.com/BUTSpeechFIT/VBx",
                licenseFile: "Apache-2.0",
                note: String(localized: "Teil von FluidAudio (Sprechererkennung).")
            ),
            Self(
                name: "fastcluster",
                kind: .library,
                license: "BSD-2-Clause",
                copyright: "© 2011 Daniel Müllner, © Google Inc.",
                source: "https://danifold.net/fastcluster.html",
                licenseFile: "fastcluster",
                note: String(localized: "Teil von FluidAudio (Sprechererkennung).")
            ),
            Self(
                name: "swift-transformers",
                kind: .library,
                license: "Apache-2.0",
                copyright: "Copyright 2022 Hugging Face SAS.",
                source: "https://github.com/huggingface/swift-transformers",
                licenseFile: "Apache-2.0"
            ),
            Self(
                name: "Jinja",
                kind: .library,
                license: "MIT",
                copyright: "Copyright (c) 2024 John Mai",
                source: "https://github.com/johnmai-dev/Jinja",
                licenseFile: "Jinja"
            ),
            Self(
                name: "Swift Collections",
                kind: .library,
                license: "Apache-2.0 with Runtime Library Exception",
                copyright: "Copyright Apple Inc. and the Swift project authors",
                source: "https://github.com/apple/swift-collections",
                licenseFile: "swift-collections"
            ),
        ]
        #if os(macOS)
        entries.append(Self(
            name: "Sparkle",
            kind: .library,
            license: "MIT",
            copyright: "Copyright (c) 2006-2013 Andy Matuschak and others",
            source: "https://github.com/sparkle-project/Sparkle",
            licenseFile: "Sparkle",
            note: String(localized: "Updates der Mac-App. Enthält Code unter weiteren freien Lizenzen, siehe Lizenztext.")
        ))
        #endif
        entries += [
            Self(
                name: "Whisper",
                kind: .model,
                license: "MIT",
                copyright: "Copyright (c) 2022 OpenAI; Core ML: argmax, inc.",
                source: "https://huggingface.co/argmaxinc/whisperkit-coreml",
                licenseLink: "https://github.com/openai/whisper/blob/main/LICENSE",
                note: String(localized: "Spracherkennung. Core-ML-Fassung der Whisper-Modelle von OpenAI.")
            ),
            Self(
                name: "Parakeet Ultra",
                kind: .model,
                license: "CC BY 4.0",
                copyright: "NVIDIA (parakeet-tdt-0.6b-v3), Moondream (Parakeet Ultra), Fluid Inference (Core ML)",
                source: "https://huggingface.co/FluidInference/parakeet-ultra-coreml",
                licenseLink: "https://creativecommons.org/licenses/by/4.0/",
                note: String(localized: "Spracherkennung. Geändert: Moondream hat NVIDIAs parakeet-tdt-0.6b-v3 nachtrainiert, Fluid Inference hat das Modell in Core ML umgewandelt und den Encoder auf 8 Bit quantisiert.")
            ),
            Self(
                name: "Speaker Diarization Community-1",
                kind: .model,
                license: "CC BY 4.0",
                copyright: "pyannote, WeSpeaker, BUT Speech@FIT (PLDA), Fluid Inference (Core ML)",
                source: "https://huggingface.co/FluidInference/speaker-diarization-coreml",
                licenseLink: "https://creativecommons.org/licenses/by/4.0/",
                note: String(localized: "Sprechererkennung. Geändert: Fluid Inference hat die Modelle von pyannote/speaker-diarization-community-1 in Core ML umgewandelt.")
            ),
        ]
        return entries
    }
}

/// Settings → General → Licenses: the app's own license and everything it builds on.
struct LicensesView: View {
    var body: some View {
        Form {
            Section {
                NavigationLink {
                    AcknowledgementView(entry: .app)
                } label: {
                    AcknowledgementRow(entry: .app)
                }
            } footer: {
                Text("NotifyAI ist Open Source unter der MIT-Lizenz.")
            }

            Section("Bibliotheken") {
                entries(of: .library)
            }

            Section {
                entries(of: .model)
            } header: {
                Text("Modelle")
            } footer: {
                Text("Die Modelle sind nicht in der App enthalten. NotifyAI lädt sie erst, wenn du sie in den Einstellungen herunterlädst, direkt von Hugging Face.")
            }
        }
        .formStyle(.grouped)
        .settingsPage("Lizenzen")
    }

    private func entries(of kind: Acknowledgement.Kind) -> some View {
        ForEach(Acknowledgement.all.filter { $0.kind == kind }) { entry in
            NavigationLink {
                AcknowledgementView(entry: entry)
            } label: {
                AcknowledgementRow(entry: entry)
            }
        }
    }
}

private struct AcknowledgementRow: View {
    let entry: Acknowledgement

    var body: some View {
        LabeledContent {
            Text(verbatim: entry.license)
        } label: {
            Text(verbatim: entry.name)
        }
    }
}

/// One entry: copyright, links, what was changed and the full license text.
private struct AcknowledgementView: View {
    let entry: Acknowledgement

    var body: some View {
        Form {
            Section {
                LabeledContent("Lizenz") { Text(verbatim: entry.license) }
                Text(verbatim: entry.copyright)
                    .textSelection(.enabled)
                if let note = entry.note {
                    Text(note)
                        .foregroundStyle(.secondary)
                }
                if let url = URL(string: entry.source) {
                    Link("Quelle öffnen", destination: url)
                }
                if let link = entry.licenseLink, let url = URL(string: link) {
                    Link("Lizenz öffnen", destination: url)
                }
            }
            if let text = entry.licenseText {
                Section("Lizenztext") {
                    Text(verbatim: text)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .settingsPage(verbatim: entry.name)
    }
}
