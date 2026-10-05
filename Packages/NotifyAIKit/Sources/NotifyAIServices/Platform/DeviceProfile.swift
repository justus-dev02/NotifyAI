//
//  DeviceProfile.swift
//  NotifyAIServices
//

import Foundation
#if os(iOS)
import UIKit
#endif

/// The kind of device the app runs on, for defaults that depend on its power.
///
/// Settings and model choices ask for the profile instead of checking the platform
/// themselves, so the distinction lives in one place.
enum DeviceProfile: Sendable {
    case phone
    case pad
    case mac

    @MainActor
    static var current: Self {
        #if os(macOS)
        .mac
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
        #endif
    }

    /// Compile-time variant for values that are needed outside the main actor. The iPad
    /// counts as a phone here; use `current` where the difference matters.
    static var build: Self {
        #if os(macOS)
        .mac
        #else
        .phone
        #endif
    }
}
