import Foundation

enum FileSizeFormatter {
    static func humanReadable(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var idx = 0

        while value >= 1024 && idx < units.count - 1 {
            value /= 1024
            idx += 1
        }

        if idx == 0 {
            return "\(Int(value)) \(units[idx])"
        }
        return String(format: "%.1f %@", value, units[idx])
    }
}
