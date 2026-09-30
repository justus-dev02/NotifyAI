//
//  TimeFormatting.swift
//  NotifyAICore
//

import Foundation

public enum TimeFormatting {
    /// "03:07" or "1:02:03" for positions in a recording.
    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    /// "12 Min." / "1 Std. 5 Min." for durations in lists.
    public static func duration(_ seconds: TimeInterval) -> String {
        let value = max(seconds, 1)
        let units: Set<Duration.UnitsFormatStyle.Unit> = value >= 3600 ? [.hours, .minutes] : value >= 60 ? [.minutes] : [.seconds]
        return Duration.seconds(value).formatted(.units(allowed: units, width: .abbreviated))
    }

    public static func byteCount(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}
