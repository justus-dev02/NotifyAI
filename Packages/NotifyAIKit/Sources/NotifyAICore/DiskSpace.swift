//
//  DiskSpace.swift
//  NotifyAICore
//

import Foundation

public enum DiskSpace {
    /// Free space on the volume holding `url` for data the user asked to keep, in bytes.
    /// `nil` if the volume does not report it.
    ///
    /// Declared in the app's privacy manifest (disk space, reasons E174.1 and 85F4.1).
    public static func available(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
