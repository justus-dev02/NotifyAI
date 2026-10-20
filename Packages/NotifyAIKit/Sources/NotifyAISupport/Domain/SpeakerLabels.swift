//
//  SpeakerLabels.swift
//  NotifyAISupport
//

import Foundation

/// The labels speakers have before the user names them, in the language of the app.
///
/// Speaker detection, the audio source split, the search and the summaries all need them, so
/// they live at the bottom of the services rather than in any one of them.
package enum SpeakerLabels {
    /// The user's own voice.
    package static let user = String(localized: "Ich", bundle: .module)
    /// Everybody on the other side of a "Mikrofon + Systemton" recording.
    package static let others = String(localized: "Andere", bundle: .module)

    /// A speaker found by speaker detection ("Sprecher 2").
    package static func detected(_ number: Int) -> String {
        String(localized: "Sprecher \(number)", bundle: .module)
    }
}
