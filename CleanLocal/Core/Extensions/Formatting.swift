import Foundation

extension Int64 {
    /// File-style byte count, e.g. "1.2 GB".
    var formattedBytes: String {
        // The system style renders zero as "Zero KB", which reads oddly in tables and charts.
        self == 0 ? "0 KB" : formatted(.byteCount(style: .file))
    }
}

extension Int {
    var formattedBytes: String { Int64(self).formattedBytes }
}

extension TimeInterval {
    /// "1:05" or "1:02:03".
    var formattedDuration: String {
        let total = Int(rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

extension Date {
    var shortDisplay: String {
        formatted(date: .abbreviated, time: .omitted)
    }

    var mediumDisplay: String {
        formatted(date: .abbreviated, time: .shortened)
    }

    var relativeDisplay: String {
        formatted(.relative(presentation: .named))
    }
}
