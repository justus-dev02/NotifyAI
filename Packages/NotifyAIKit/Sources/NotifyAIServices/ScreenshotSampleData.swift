//
//  ScreenshotSampleData.swift
//  NotifyAIServices
//

#if DEBUG
import Foundation
import NotifyAICore
import NotifyAIPersistence
import NotifyAISupport

/// English notes for the App Store screenshots (`-screenshot-sample-data`, see
/// `NotifyAIUITests/ScreenshotTests.swift`). Only in debug builds; the released app never
/// contains them.
@MainActor
extension SampleData {
    /// Inserts a library of finished English notes: meetings, an interview, a lecture with
    /// chapters, a 1:1 and an imported document, with transcripts, speakers and tasks.
    public static func insertScreenshotNotes(into services: ServiceContainer, now: Date = .now) throws {
        for note in try screenshotNotes(now: now) {
            try services.store.insert(note)
        }
    }

    private static func screenshotNotes(now: Date) throws -> [Note] {
        let hour: TimeInterval = 3_600
        let day: TimeInterval = 86_400
        return [
            try roadmapMeeting(createdAt: now.addingTimeInterval(-2 * hour)),
            try customerInterview(createdAt: now.addingTimeInterval(-day - 3 * hour)),
            try lecture(createdAt: now.addingTimeInterval(-2 * day)),
            try oneOnOne(createdAt: now.addingTimeInterval(-3 * day)),
            try salesCall(createdAt: now.addingTimeInterval(-4 * day)),
            projectBrief(createdAt: now.addingTimeInterval(-6 * day)),
        ]
    }

    // MARK: Notes

    private static func roadmapMeeting(createdAt: Date) throws -> Note {
        let note = Note(title: "Q4 Product Roadmap", isTitleUserDefined: true, createdAt: createdAt, kind: .recording, status: .ready,
                        focus: .meeting, language: .englishUS, participants: ["Sarah", "David", "Priya"])
        let segments = transcript([
            ("Sarah", "Okay, let's get started. The goal today is to lock the Q4 roadmap before the planning review on Friday."),
            ("David", "From the engineering side, offline sync is the biggest item. We estimate about six weeks with two people."),
            ("Priya", "Customers keep asking for it. It came up in eight of the last ten interviews, so I'd put it first."),
            ("Sarah", "Agreed. Offline sync goes first. What does that mean for the new onboarding?"),
            ("David", "If we start sync now, onboarding moves to November. The design is ready, so that's not a risk."),
            ("Priya", "I can test the onboarding prototype with five customers next week, so we have feedback before we build it."),
            ("Sarah", "Great. And the pricing page? Marketing wants the new plans live before Black Friday."),
            ("David", "That's mostly content. Two days of work if the copy is final by October 31."),
            ("Sarah", "I'll get the copy from marketing. Priya, can you update the roadmap document today?"),
            ("Priya", "Sure. One open question is whether we still support the old Android version in Q4."),
            ("David", "Usage is under three percent. I'd drop it, but we should check with support first."),
            ("Sarah", "Let's decide that next week. So to sum up: sync first, onboarding in November, pricing before Black Friday."),
        ])
        try setTranscript(segments, on: note)
        note.duration = 42 * 60 + 18
        note.isFavorite = true
        note.markers = [Marker(time: segments[3].start + 2, createdAt: createdAt), Marker(time: segments[11].start + 3, createdAt: createdAt)]
        note.speakers = speakers(in: segments)
        note.setLabels(["Product", "Planning"])
        note.summary = roadmapSummary(segments: segments, createdAt: createdAt)
        return note
    }

    private static func roadmapSummary(segments: [TranscriptSegment], createdAt: Date) -> NoteSummary {
        NoteSummary(
            overview: "The team agreed on the Q4 roadmap: offline sync ships first, the new onboarding follows in November and the pricing page goes live before Black Friday.",
            keyPoints: [
                "Offline sync is the most requested feature – mentioned in 8 of the last 10 customer interviews.",
                "Engineering estimates six weeks with two people for offline sync.",
                "The onboarding design is finished, so moving it to November carries little risk.",
                "The pricing page is mostly content work and takes about two days.",
            ],
            decisions: [
                "Offline sync is the top priority for Q4.",
                "The new onboarding moves to November.",
            ],
            actionItems: [
                ActionItem(task: "Update the roadmap document", owner: "Priya", due: "today"),
                ActionItem(task: "Test the onboarding prototype with five customers", owner: "Priya", due: "next week"),
                ActionItem(task: "Get the final pricing copy from marketing", owner: "Sarah", due: "Friday"),
                ActionItem(task: "Check Android usage with support", owner: "David", due: "next week"),
            ],
            openQuestions: ["Do we keep supporting the old Android version in Q4?"],
            topics: [
                SummaryTopic(title: "Offline sync", points: ["Six weeks, two engineers", "Top customer request"]),
                SummaryTopic(title: "Pricing page", points: ["Live before Black Friday", "Copy due October 31"]),
            ],
            source: .appleIntelligence,
            createdAt: createdAt,
            keywords: ["Roadmap", "Offline sync", "Pricing"],
            sourceTimes: [
                "Offline sync is the most requested feature – mentioned in 8 of the last 10 customer interviews.": segments[2].start,
                "Engineering estimates six weeks with two people for offline sync.": segments[1].start,
                "The onboarding design is finished, so moving it to November carries little risk.": segments[4].start,
                "The pricing page is mostly content work and takes about two days.": segments[7].start,
                "Offline sync is the top priority for Q4.": segments[3].start,
                "The new onboarding moves to November.": segments[4].start,
                "Update the roadmap document": segments[8].start,
                "Test the onboarding prototype with five customers": segments[5].start,
                "Get the final pricing copy from marketing": segments[8].start,
                "Check Android usage with support": segments[10].start,
                "Do we keep supporting the old Android version in Q4?": segments[9].start,
            ]
        )
    }

    private static func customerInterview(createdAt: Date) throws -> Note {
        let note = Note(title: "Customer Interview – Northwind", isTitleUserDefined: true, createdAt: createdAt, kind: .recording, status: .ready,
                        focus: .interview, language: .englishUS, participants: ["Emma", "Me"])
        let segments = transcript([
            ("Me", "Thanks for taking the time, Emma. How does your team take notes in meetings today?"),
            ("Emma", "Honestly, someone types along in a shared document, and half of the decisions get lost anyway."),
            ("Me", "What happens after the meeting?"),
            ("Emma", "Someone writes a summary, usually a day later. By then nobody remembers who promised what."),
            ("Me", "If you had a summary with tasks right after the call, what would you do with it?"),
            ("Emma", "Send it to Notion, definitely. And I'd want every task to link back to where it was said."),
            ("Me", "How important is it that recordings stay on the device?"),
            ("Emma", "Very. Our legal team won't approve anything that uploads customer calls to a cloud service."),
        ])
        try setTranscript(segments, on: note)
        note.duration = 28 * 60 + 5
        note.speakers = speakers(in: segments)
        note.setLabels(["Research"])
        note.summary = NoteSummary(
            overview: "Emma’s team loses decisions because notes are typed by hand and summarized a day later. On-device processing is a must for their legal team.",
            keyPoints: [
                "Notes are typed into a shared document during the meeting.",
                "Summaries arrive a day later, and task owners are often unclear.",
                "Tasks should link back to the moment they were agreed.",
                "Recordings must not be uploaded to a cloud service.",
            ],
            actionItems: [
                ActionItem(task: "Share the Notion export with Emma", owner: "Me", due: "tomorrow"),
                ActionItem(task: "Send the privacy overview to Northwind legal", owner: "Me", due: "Friday"),
            ],
            openQuestions: ["Which Notion workspace layout does Northwind use?"],
            source: .appleIntelligence,
            createdAt: createdAt,
            keywords: ["Interview", "Notion", "Privacy"]
        )
        return note
    }

    private static func lecture(createdAt: Date) throws -> Note {
        let note = Note(title: "Machine Learning – Lecture 5", isTitleUserDefined: true, createdAt: createdAt, kind: .recording, status: .ready,
                        focus: .lecture, language: .englishUS, participants: ["Prof. Miller"])
        let segments = transcript([
            ("Prof. Miller", "Today we look at gradient descent and why the learning rate matters so much."),
            ("Prof. Miller", "If the learning rate is too large, the loss jumps around and never settles."),
            ("Prof. Miller", "If it is too small, training takes forever. In practice we use a schedule that decreases it over time."),
            ("Prof. Miller", "The second topic is overfitting. A model that memorizes the training data fails on new data."),
            ("Prof. Miller", "Regularization and early stopping are the two tools you will use most often."),
            ("Prof. Miller", "For the exam, make sure you can explain the bias-variance trade-off with an example."),
        ], wordsPerSecond: 2.2)
        try setTranscript(segments, on: note)
        note.duration = 74 * 60 + 40
        note.speakers = speakers(in: segments)
        note.setLabels(["University"])
        note.summary = NoteSummary(
            overview: "Gradient descent, learning-rate schedules and overfitting, with regularization and early stopping as the main remedies.",
            keyPoints: [
                "A learning rate that is too large makes the loss diverge; one that is too small slows training down.",
                "Learning-rate schedules decrease the rate over time.",
                "Overfitting means memorizing the training data instead of generalizing.",
                "Regularization and early stopping are the most common remedies.",
            ],
            actionItems: [ActionItem(task: "Prepare an example of the bias-variance trade-off", owner: "Me", due: "end of the week")],
            topics: [
                SummaryTopic(title: "Exam", points: ["Explain the bias-variance trade-off with an example"]),
            ],
            source: .appleIntelligence,
            createdAt: createdAt,
            keywords: ["Gradient descent", "Overfitting"],
            chapters: [
                SummaryChapter(start: 0, end: 1_520, title: "Gradient descent", overview: "How the learning rate affects training."),
                SummaryChapter(start: 1_520, end: 3_100, title: "Overfitting", overview: "Why models fail on new data."),
                SummaryChapter(start: 3_100, end: 4_480, title: "Exam preparation", overview: "The bias-variance trade-off."),
            ]
        )
        return note
    }

    private static func oneOnOne(createdAt: Date) throws -> Note {
        let note = Note(title: "1:1 with Alex", isTitleUserDefined: true, createdAt: createdAt, kind: .recording, status: .ready,
                        focus: .oneOnOne, language: .englishUS, participants: ["Alex", "Me"])
        let segments = transcript([
            ("Me", "How are you feeling about the release?"),
            ("Alex", "Good overall. The testing week was intense, but we caught the important bugs."),
            ("Me", "What would you like to focus on next quarter?"),
            ("Alex", "I'd like to lead the offline sync project. I worked on the storage layer last year."),
        ])
        try setTranscript(segments, on: note)
        note.duration = 31 * 60
        note.speakers = speakers(in: segments)
        note.setLabels(["Team"])
        note.summary = NoteSummary(
            overview: "Alex is happy with the release and wants to lead the offline sync project next quarter.",
            keyPoints: ["The testing week caught the important bugs.", "Alex has experience with the storage layer."],
            actionItems: [ActionItem(task: "Propose Alex as lead for offline sync", owner: "Me", due: "Monday")],
            source: .appleIntelligence,
            createdAt: createdAt,
            keywords: ["Career", "Offline sync"]
        )
        return note
    }

    private static func salesCall(createdAt: Date) throws -> Note {
        let note = Note(title: "Sales Call – Acme Corp", isTitleUserDefined: true, createdAt: createdAt, kind: .recording, status: .ready,
                        focus: .sales, language: .englishUS, participants: ["Tom", "Lisa"])
        let segments = transcript([
            ("Tom", "We need a solution for about 40 people, and it has to work on Mac and iPhone."),
            ("Lisa", "Both are supported, and everything runs on the device, so there is no data processing agreement needed."),
            ("Tom", "Budget-wise we'd need a decision before the end of the month."),
        ])
        try setTranscript(segments, on: note)
        note.duration = 24 * 60 + 12
        note.speakers = speakers(in: segments)
        note.setLabels(["Sales"])
        note.summary = NoteSummary(
            overview: "Acme needs a solution for 40 people on Mac and iPhone and wants to decide by the end of the month.",
            keyPoints: ["40 seats, Mac and iPhone.", "On-device processing removes the need for a data processing agreement."],
            actionItems: [ActionItem(task: "Send the offer for 40 seats", owner: "Lisa", due: "tomorrow")],
            openQuestions: ["Who signs off the budget at Acme?"],
            source: .appleIntelligence,
            createdAt: createdAt,
            keywords: ["Acme", "Offer"]
        )
        return note
    }

    private static func projectBrief(createdAt: Date) -> Note {
        let note = Note(title: "Website Relaunch Brief", isTitleUserDefined: true, createdAt: createdAt, kind: .document, status: .ready,
                        language: .englishUS,
                        bodyText: "The new website launches in spring. Goals: faster pages, a clearer pricing page and a blog for product updates.")
        note.setLabels(["Marketing"])
        note.summary = NoteSummary(
            overview: "The website relaunch in spring focuses on speed, a clearer pricing page and a product blog.",
            keyPoints: ["Launch in spring.", "Faster pages and a clearer pricing page.", "A blog for product updates."],
            source: .appleIntelligence,
            createdAt: createdAt,
            keywords: ["Website", "Relaunch"]
        )
        return note
    }

    // MARK: Helpers

    /// Segments with word timings, one after another with a short pause, at a natural pace.
    private static func transcript(_ lines: [(speaker: String, text: String)], wordsPerSecond: Double = 2.6) -> [TranscriptSegment] {
        var time: TimeInterval = 4
        return lines.map { line in
            var words: [TranscriptWord] = []
            var wordStart = time
            for (index, word) in line.text.split(separator: " ").enumerated() {
                let length = 1 / wordsPerSecond
                words.append(TranscriptWord(text: (index == 0 ? "" : " ") + word, start: wordStart, end: wordStart + length * 0.9))
                wordStart += length
            }
            let segment = TranscriptSegment(start: time, end: wordStart, text: line.text, speaker: line.speaker, words: words)
            time = wordStart + 1.5
            return segment
        }
    }

    private static func setTranscript(_ segments: [TranscriptSegment], on note: Note) throws {
        note.setTranscript(encoded: try Transcript.encode(segments), plainText: Transcript.plainText(of: segments), engine: .whisper)
    }

    /// The speakers in order of first appearance, named by the user.
    private static func speakers(in segments: [TranscriptSegment]) -> [NoteSpeaker] {
        var order: [String] = []
        var durations: [String: TimeInterval] = [:]
        for segment in segments {
            guard let speaker = segment.speaker else { continue }
            if durations[speaker] == nil { order.append(speaker) }
            durations[speaker, default: 0] += segment.end - segment.start
        }
        return order.map { NoteSpeaker(label: $0, origin: .named, speechDuration: durations[$0] ?? 0) }
    }
}
#endif
