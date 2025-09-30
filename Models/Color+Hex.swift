import SwiftUI

extension Color {
    init?(hex: String) {
        var sanitized = hex.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if sanitized.hasPrefix("#") {
            sanitized.removeFirst()
        }

        guard sanitized.count == 6 || sanitized.count == 8,
              let value = UInt64(sanitized, radix: 16) else {
            return nil
        }

        let hasAlpha = sanitized.count == 8
        let a = hasAlpha ? Double((value & 0xFF000000) >> 24) / 255.0 : 1.0
        let r = Double((value & 0x00FF0000) >> 16) / 255.0
        let g = Double((value & 0x0000FF00) >> 8) / 255.0
        let b = Double(value & 0x000000FF) / 255.0

        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
