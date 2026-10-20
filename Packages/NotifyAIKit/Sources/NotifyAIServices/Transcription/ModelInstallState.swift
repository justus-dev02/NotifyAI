//
//  ModelInstallState.swift
//  NotifyAIServices
//

import Foundation

/// Download state of a downloadable model (Whisper, speaker recognition, Parakeet), as shown
/// in the settings.
public enum ModelInstallState: Equatable, Sendable {
    case notInstalled
    case downloading(progress: Double)
    /// Downloaded; the model is being compiled for this device.
    case preparing
    case installed(bytes: Int64)
    case failed(message: String)

    public var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }
}
