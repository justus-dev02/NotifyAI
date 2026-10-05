//
//  NoteDetailModel.swift
//  NotifyAI
//

import Foundation
import NotifyAICore
import NotifyAIPersistence
import NotifyAIServices
import Observation

/// View state of the detail screen: decoded transcript, highlight windows and playback.
///
/// The transcript is decoded once per change (off the main actor) instead of on every
/// render, and the segment under the playhead is found by binary search.
@MainActor
@Observable
final class NoteDetailModel {
    let player: AudioPlayer
    private(set) var segments: [TranscriptSegment] = []
    private(set) var markers: [Marker] = []
    private(set) var highlights = HighlightWindows(markers: [])
    var showsHighlights = true
    var followsPlayback = true

    /// `contentRevision` of the note whose transcript is decoded, `nil` before the first update.
    @ObservationIgnored private var loadedRevision: Int?
    @ObservationIgnored private var loadedAudioURL: URL?

    init(audioSession: AudioSessionController) {
        player = AudioPlayer(session: audioSession)
    }

    /// Synchronises the model with the note. Cheap when nothing changed.
    ///
    /// All values are read from the note before the first `await`: the note may be deleted
    /// while the transcript is decoded, and a deleted model must not be accessed again.
    func update(from note: Note, audioURL: URL?) async {
        let markers = note.markers
        let duration = note.duration
        let revision = note.contentRevision
        let isRecording = note.status == .recording

        self.markers = markers
        highlights = HighlightWindows(markers: markers, duration: duration > 0 ? duration : nil)

        // The audio of a running recording is incomplete; load it once it is finished.
        if !isRecording, let audioURL, audioURL != loadedAudioURL,
           FileManager.default.fileExists(atPath: audioURL.path(percentEncoded: false)) {
            loadedAudioURL = audioURL
            player.load(url: audioURL)
        }

        // Comparing the revision avoids loading the transcript file on every update.
        if revision != loadedRevision {
            loadedRevision = revision
            if let transcriptData = note.transcriptData {
                segments = await Self.decode(transcriptData)
            } else {
                segments = []
            }
        }
    }

    @concurrent
    private static func decode(_ transcriptData: Data) async -> [TranscriptSegment] {
        (try? Transcript.decode(transcriptData)) ?? []
    }

    /// The segment that contains the playback position, if playback has started.
    var currentSegmentID: UUID? {
        guard player.isPlaying || player.currentTime > 0 else { return nil }
        let time = player.currentTime
        var low = 0
        var high = segments.count - 1
        var match: Int?
        // Last segment whose start is not after `time`.
        while low <= high {
            let mid = (low + high) / 2
            if segments[mid].start <= time {
                match = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard let match, time <= segments[match].end + 1 else { return nil }
        return segments[match].id
    }

    func play(from time: TimeInterval) {
        player.seek(to: time)
        if !player.isPlaying {
            player.play()
        }
    }

    /// A new marker at the current playback position.
    func markerAtPlaybackPosition() -> Marker {
        Marker(time: player.currentTime)
    }

    func stop() {
        player.stop()
        loadedAudioURL = nil
    }
}
