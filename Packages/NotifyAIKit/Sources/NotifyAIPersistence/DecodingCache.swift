//
//  DecodingCache.swift
//  NotifyAIPersistence
//

import Foundation
import NotifyAICore

/// Remembers what a note's JSON attributes decoded to.
///
/// Views read `note.summary` and `note.markers` on every render, the task board and the search
/// index read them for many notes. Decoding JSON each time is wasted work while the data is
/// the same. Comparing the data (a memory comparison) is far cheaper than decoding it, and
/// it stays correct after a rollback or an undo, which a "dirty" flag would miss.
final class DecodingCache {
    private var summary: (data: Data, value: NoteSummary)?
    private var markers: (data: Data, value: [Marker])?

    func summary(for data: Data) -> NoteSummary? {
        if let summary, summary.data == data {
            return summary.value
        }
        guard let decoded = try? JSONDecoder().decode(NoteSummary.self, from: data) else { return nil }
        summary = (data, decoded)
        return decoded
    }

    func markers(for data: Data) -> [Marker] {
        if let markers, markers.data == data {
            return markers.value
        }
        let decoded = (try? JSONDecoder().decode([Marker].self, from: data)) ?? []
        markers = (data, decoded)
        return decoded
    }
}
