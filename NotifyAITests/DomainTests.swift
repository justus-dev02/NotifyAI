//
//  DomainTests.swift
//  NotifyAITests
//

import Foundation
@testable import NotifyAI
import NotifyAICore
import Testing

@Suite("Markers and highlighting")
struct MarkerTests {
    @Test("A marker highlights five seconds before and after")
    func highlightWindow() {
        let marker = Marker(time: 30)
        #expect(marker.highlightRange() == 25...35)
    }

    @Test("The window is clamped to the start and end of the recording")
    func clamping() {
        #expect(Marker(time: 2).highlightRange() == 0...7)
        #expect(Marker(time: 58).highlightRange(duration: 60) == 53...60)
    }

    @Test("Overlapping windows are merged")
    func merging() {
        let windows = HighlightWindows(markers: [Marker(time: 10), Marker(time: 16), Marker(time: 40)])
        #expect(windows.ranges == [5...21, 35...45])
    }

    @Test("Words are highlighted by their midpoint")
    func wordHighlighting() {
        let windows = HighlightWindows(markers: [Marker(time: 20)])
        #expect(windows.contains(TranscriptWord(text: " inside", start: 24.6, end: 24.9)))
        // Starts inside the window but its midpoint is outside.
        #expect(!windows.contains(TranscriptWord(text: " outside", start: 24.8, end: 25.6)))
        #expect(!windows.contains(TranscriptWord(text: " before", start: 13, end: 14.9)))
    }

    @Test("Binary search agrees with a linear scan", arguments: 0..<20)
    func intersectsMatchesLinearScan(seed: Int) {
        var generator = SeededGenerator(seed: UInt64(seed))
        let markers = (0..<8).map { _ in Marker(time: Double.random(in: 0...600, using: &generator)) }
        let windows = HighlightWindows(markers: markers)

        for _ in 0..<200 {
            let start = Double.random(in: 0...620, using: &generator)
            let range = start...(start + Double.random(in: 0...3, using: &generator))
            let expected = markers.contains { $0.highlightRange().overlaps(range) }
            #expect(windows.intersects(range) == expected)
        }
    }
}

@Suite("Transcript helpers")
struct TranscriptTests {
    private let segments = [
        TranscriptSegment(start: 5, end: 8, text: "Zweiter Satz.", speaker: "Sprecher 2"),
        TranscriptSegment(start: 0, end: 4, text: "Erster Satz.", speaker: "Sprecher 1"),
        TranscriptSegment(start: 9, end: 10, text: "   "),
        TranscriptSegment(start: 11, end: 13, text: "Noch einer.", speaker: "Sprecher 2"),
    ]

    @Test("Normalizing sorts by time and drops empty segments")
    func normalized() {
        let result = Transcript.normalized(segments)
        #expect(result.map(\.text) == ["Erster Satz.", "Zweiter Satz.", "Noch einer."])
    }

    @Test("Plain text starts a labelled line on every speaker change")
    func plainText() {
        let text = Transcript.plainText(of: Transcript.normalized(segments))
        #expect(text == "Sprecher 1: Erster Satz.\nSprecher 2: Zweiter Satz. Noch einer.")
    }

    @Test("Text in a range uses word timing when available")
    func textInRange() {
        let segment = TranscriptSegment(
            start: 0,
            end: 6,
            text: "Das ist sehr wichtig heute",
            words: [
                TranscriptWord(text: "Das", start: 0, end: 0.5),
                TranscriptWord(text: " ist", start: 0.6, end: 1),
                TranscriptWord(text: " sehr", start: 2, end: 2.5),
                TranscriptWord(text: " wichtig", start: 2.6, end: 3.2),
                TranscriptWord(text: " heute", start: 5, end: 6),
            ]
        )
        #expect(Transcript.text(in: 1.8...3.5, of: [segment]) == "sehr wichtig")
    }

    @Test("Encoding round-trips")
    func roundTrip() throws {
        let data = try Transcript.encode(segments)
        #expect(try Transcript.decode(data) == segments)
    }
}

@Suite("Formatting")
struct TimeFormattingTests {
    @Test("Timestamps", arguments: [(0.0, "00:00"), (65.4, "01:05"), (3_725, "1:02:05"), (-3, "00:00")])
    func timestamps(seconds: Double, expected: String) {
        #expect(TimeFormatting.timestamp(seconds) == expected)
    }
}
