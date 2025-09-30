import Foundation

enum SampleDataFactory {
    static func makeSampleNotes() -> [Note] {
        var meeting = Note(title: "Sales Sync – Horizon GmbH")
        meeting.createdAt = Date().addingTimeInterval(-3600)
        meeting.location = "München"
        meeting.duration = 45 * 60
        meeting.participants = [
            Participant(name: "Lea", role: "AE", colorHex: "#A66CF4"),
            Participant(name: "Tim", role: "PM", colorHex: "#65D6FF"),
            Participant(name: "Sven", role: "CTO", colorHex: "#FF8AAE")
        ]
        meeting.highlights = ["Pilot auf 12 Wochen verlängern", "Security Review abgeschlossen"]
        meeting.decisions = ["Custom SLA akzeptiert"]
        meeting.risks = ["Budget-Freigabe noch offen"]
        meeting.sourceType = .meeting
        meeting.summary = Summary(
            highlights: meeting.highlights,
            decisions: meeting.decisions,
            actionItems: [
                ActionItem(owner: "Lea", task: "Follow-up Angebot senden", due: Calendar.current.date(byAdding: .day, value: 2, to: Date()), status: .inProgress),
                ActionItem(owner: "Tim", task: "Security Whitepaper bereitstellen", status: .open)
            ],
            risks: meeting.risks,
            markdown: "Kompakte Executive Summary des Calls."
        )
        meeting.roleSummaries = [
            "Sales": Summary(markdown: "Fokus auf Upsell und Verlängerung."),
            "Leadership": Summary(markdown: "Budget-Entscheidung beobachten.")
        ]
        meeting.pipeline = PipelineState(stage: .summarizing, progress: 0.6, etaSeconds: 120, message: nil)
        meeting.segments = [
            TranscriptSegment(start: 0, end: 45, speakerId: meeting.participants[0].id.uuidString, text: "Willkommen, Agenda heute: Status Pilot."),
            TranscriptSegment(start: 60, end: 120, speakerId: meeting.participants[1].id.uuidString, text: "Feature Requests sind priorisiert."),
            TranscriptSegment(start: 150, end: 240, speakerId: meeting.participants[2].id.uuidString, text: "Wir brauchen Deployment am 24.09.")
        ]
        meeting.mindmap = Mindmap(root: "Sales Sync", children: [
            MindmapNode(label: "Pilot", children: [MindmapNode(label: "Verlängerung", children: nil)]),
            MindmapNode(label: "Risiken", children: [MindmapNode(label: "Budget", children: nil)])
        ])

        var web = Note(title: "Artikel – Apple Intelligence Review")
        web.createdAt = Date().addingTimeInterval(-7200)
        web.sourceType = .web
        web.highlights = ["On-Device AI", "Privacy Fokus", "Integration in iOS 18"]
        web.summary = Summary(highlights: web.highlights, markdown: "Kernerkenntnisse des Artikels mit Fokus auf Unternehmensnutzen.")
        web.pipeline = PipelineState(stage: .done, progress: 1.0, etaSeconds: nil, message: nil)

        var pdf = Note(title: "Produkt-Whitepaper.pdf")
        pdf.sourceType = .pdf
        pdf.highlights = ["Kapitelmarken gesetzt", "OCR abgeschlossen"]
        pdf.pipeline = PipelineState(stage: .indexing, progress: 0.9, etaSeconds: 60, message: nil)

        var audio = Note(title: "Podcast Recap")
        audio.sourceType = .audio
        audio.highlights = ["Episode 123", "KI Use-Cases"]
        audio.pipeline = PipelineState(stage: .diarizing, progress: 0.3, etaSeconds: 180, message: nil)

        return [meeting, web, pdf, audio]
    }
}
