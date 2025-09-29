//
//  PipelineManager.swift
//  NotifyAI
//
//  Created by Justus on 29.09.25.
//

import Foundation
import BackgroundTasks
import UIKit

actor PipelineManager {
    static let shared = PipelineManager()
    private let storage = ServiceLocator.shared.storage
    private let transcriber = ServiceLocator.shared.transcription
    private let diarizer = ServiceLocator.shared.diarization
    private let llm = ServiceLocator.shared.llm
    private let highlight = ServiceLocator.shared.highlight
    private let search = SemanticSearchService.shared

    func registerBGTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.your.app.pipeline", using: nil) { task in
            Task { await self.runPending(task: task as! BGProcessingTask) }
        }
    }

    func scheduleBG() {
        let req = BGProcessingTaskRequest(identifier: "com.your.app.pipeline")
        req.requiresNetworkConnectivity = false
        req.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(req)
    }

    func enqueue(noteId: UUID, audio: URL) async {
        await run(noteId: noteId, audio: audio, isBackground: false)
        scheduleBG()
    }

    private func update(_ noteId: UUID, stage: PipelineState.Stage, progress: Double, eta: Int?, msg: String?) async {
        await storage.updatePipeline(noteId: noteId) { s in
            s.stage = stage; s.progress = progress; s.etaSeconds = eta; s.message = msg
        }
        await MainActor.run { NotificationCenter.default.post(name: .pipelineUpdated, object: noteId) }
    }

    private func chunks(for audio: URL, targetSec: Double = 300) async -> [URL] {
        // TODO: tatsächlich aufsplitten (AVAssetExportSession). Platzhalter:
        return [audio]
    }

    private func run(noteId: UUID, audio: URL, isBackground: Bool) async {
        do {
            await update(noteId, stage: .chunking, progress: 0.05, eta: nil, msg: "Audio wird in Abschnitte geteilt…")
            let parts = await chunks(for: audio)

            var allSegments: [TranscriptSegment] = []
            var c = 0
            for part in parts {
                c += 1
                let p = Double(c) / Double(parts.count)
                await update(noteId, stage: .transcribing, progress: 0.1 + 0.6*p, eta: estimateETA(parts.count - c, perChunk: 60), msg: "Transkription…")

                let segmentsPart: [TranscriptSegment] = [] // TODO

                allSegments.append(contentsOf: segmentsPart)
            }

            await update(noteId, stage: .diarizing, progress: 0.72, eta: 45, msg: "Sprecher werden erkannt…")
            let diar = try await diarizer.diarize(audio)
            let withSpeakers = mapSpeakers(allSegments, diar: diar)

            await storage.updateSegments(noteId: noteId, segments: withSpeakers)

            await update(noteId, stage: .summarizing, progress: 0.80, eta: 40, msg: "Zusammenfassung wird erstellt…")
            let fullText = withSpeakers.map{$0.text}.joined(separator: " ")
            var base = try await llm.summarize(transcript: fullText)

            // Zitate (Referenzen): nimm die Top-Sätze pro Abschnitt
            base.citations = withSpeakers.prefix(12).map(\.id)

            await update(noteId, stage: .roleSummaries, progress: 0.88, eta: 30, msg: "Rollenbasierte Zusammenfassungen…")
            let roles = ["Sales","Team","Leadership"]
            var roleSummaries: [String: Summary] = [:]
            for r in roles {
                roleSummaries[r] = try await highlight.roleSummary(role: r, transcript: fullText, segments: withSpeakers)
            }

            await update(noteId, stage: .mindmap, progress: 0.92, eta: 20, msg: "Mindmap…")
            let mind = try await highlight.makeMindmap(transcript: fullText)

            await storage.updateSummaries(noteId: noteId, summary: base, roleSummaries: roleSummaries, mindmap: mind)

            await update(noteId, stage: .indexing, progress: 0.96, eta: 10, msg: "Index wird aktualisiert…")
            let notes = await storage.loadAll()
            search.buildIndex(notes: notes)

            await update(noteId, stage: .done, progress: 1.0, eta: 0, msg: "Fertig")
            notifyDone(noteId)
        } catch {
            await update(noteId, stage: .error, progress: 1.0, eta: nil, msg: error.localizedDescription)
        }
    }

    private func runPending(task: BGProcessingTask) async {
        defer { task.setTaskCompleted(success: true) }
        // Lade offene Notes mit stage != .done und verarbeite
        let pending = await storage.pendingNotes()
        for p in pending {
            await run(noteId: p.id, audio: p.audioURL!, isBackground: true)
            if task.isCancelled { break }
        }
    }

    private func notifyDone(_ id: UUID) {
        let content = UNMutableNotificationContent()
        content.title = "Aufbereitung abgeschlossen"
        content.body = "Deine Aufnahme ist jetzt vollständig zusammengefasst."
        let req = UNNotificationRequest(identifier: "done-\(id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    private func estimateETA(_ chunksRemaining: Int, perChunk: Int) -> Int { chunksRemaining * perChunk }

    private func mapSpeakers(_ segments: [TranscriptSegment],
                             diar: [(start: TimeInterval, end: TimeInterval, speakerId: String)]) -> [TranscriptSegment] {
        // Einfaches Intervall-Matching
        segments.map { seg in
            var s = seg
            if let d = diar.first(where: { $0.start <= seg.start && seg.end <= $0.end }) {
                s.speakerId = d.speakerId
            }
            return s
        }
    }
}
