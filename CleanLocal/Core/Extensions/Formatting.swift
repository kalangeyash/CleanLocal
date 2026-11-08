import Foundation

extension Int64 {
    /// File-style byte count, e.g. "1.2 GB".
    var formattedBytes: String {
        guard self == 0 else { return formatted(.byteCount(style: .file)) }
        // The default style spells zero out ("Zero kB"); keep it numeric and localized.
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: 0)
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
