//
//  CaptureStreamConsumer.swift
//  NotifyAIServices
//

import AudioCapture
import Foundation
import NotifyAICore

/// Feeds the streams of a running capture to where they belong: levels to the meter, audio
/// to the live transcript, events to the recording controller. One per recording.
@MainActor
final class CaptureStreamConsumer {
    private var audioTasks: [Task<Void, Never>] = []
    private var eventTask: Task<Void, Never>?

    init(
        _ streams: AudioCaptureStreams,
        meter: RecordingMeter,
        transcript: LiveTranscriptFeed,
        events handleEvent: @escaping @MainActor (CaptureEvent) -> Void
    ) {
        audioTasks = [
            Task { [weak meter] in
                for await level in streams.levels {
                    meter?.record(level)
                }
            },
        ]
        if let chunks = streams.chunks {
            audioTasks.append(Task { [weak transcript] in
                for await chunk in chunks {
                    await transcript?.append(chunk)
                }
            })
        }
        eventTask = Task {
            for await event in streams.events {
                handleEvent(event)
            }
        }
    }

    /// No more events are handled, e.g. because the recording is stopping.
    func stopEvents() {
        eventTask?.cancel()
        eventTask = nil
    }

    /// Waits until all recorded audio reached the meter and the live transcript. The recorder
    /// finishes the streams when it stops, so this returns after the last block.
    func waitForAudio() async {
        for task in audioTasks {
            await task.value
        }
    }

    /// Stops delivering anything at once (the recording is discarded).
    func cancel() {
        stopEvents()
        audioTasks.forEach { $0.cancel() }
    }
}
