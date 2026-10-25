//
//  DecodingCache.swift
//  NotifyAIPersistence
//

import Foundation
import NotifyAICore
import OSLog

/// Remembers what a note's JSON attributes decoded to.
///
/// Views read `note.summary` and `note.markers` on every render, the task board and the search
/// index read them for many notes. Decoding JSON each time is wasted work while the data is
/// the same. Comparing the data (a memory comparison) is far cheaper than decoding it, and
/// it stays correct after a rollback or an undo, which a "dirty" flag would miss.
///
/// Data that cannot be decoded is logged once per value, not on every read, and reads as
/// absent; the stored data stays untouched.
final class DecodingCache {
    private var summary: (data: Data, value: NoteSummary?)?
    private var markers: (data: Data, value: [Marker])?
    private var speakers: (data: Data, value: [NoteSpeaker])?
    private var sourceActivity: (data: Data, value: SourceActivity?)?

    func summary(for data: Data) -> NoteSummary? {
        if let summary, summary.data == data {
            return summary.value
        }
        let decoded = Self.decode(NoteSummary.self, from: data, attribute: "summary")
        summary = (data, decoded)
        return decoded
    }

    func markers(for data: Data) -> [Marker] {
        if let markers, markers.data == data {
            return markers.value
        }
        let decoded = Self.decode([Marker].self, from: data, attribute: "markers") ?? []
        markers = (data, decoded)
        return decoded
    }

    func speakers(for data: Data) -> [NoteSpeaker] {
        if let speakers, speakers.data == data {
            return speakers.value
        }
        let decoded = Self.decode([NoteSpeaker].self, from: data, attribute: "speakers") ?? []
        speakers = (data, decoded)
        return decoded
    }

    func sourceActivity(for data: Data) -> SourceActivity? {
        if let sourceActivity, sourceActivity.data == data {
            return sourceActivity.value
        }
        let decoded = Self.decode(SourceActivity.self, from: data, attribute: "sourceActivity")
        sourceActivity = (data, decoded)
        return decoded
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data, attribute: String) -> T? {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            Logger.persistence.error("Decoding the note's \(attribute, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
