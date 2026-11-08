import Foundation

enum MediaSort: String, CaseIterable, Identifiable, Sendable {
    case sizeDescending, sizeAscending, dateNewest, dateOldest, nameAscending, nameDescending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sizeDescending: "Largest First"
        case .sizeAscending: "Smallest First"
        case .dateNewest: "Newest First"
        case .dateOldest: "Oldest First"
        case .nameAscending: "Name A–Z"
        case .nameDescending: "Name Z–A"
        }
    }

    var isDateBased: Bool { self == .dateNewest || self == .dateOldest }

    func sorted(_ items: [MediaItem]) -> [MediaItem] {
        switch self {
        case .sizeDescending: items.sorted { ($0.size, $1.id) > ($1.size, $0.id) }
        case .sizeAscending: items.sorted { ($0.size, $0.id) < ($1.size, $1.id) }
        case .dateNewest: items.sorted { $0.effectiveDate > $1.effectiveDate }
        case .dateOldest: items.sorted { $0.effectiveDate < $1.effectiveDate }
        case .nameAscending: items.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        case .nameDescending: items.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedDescending }
        }
    }
}

enum MediaKindFilter: String, CaseIterable, Identifiable, Sendable {
    case all, photos, videos, screenshots, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .photos: "Photos"
        case .videos: "Videos"
        case .screenshots: "Screenshots"
        case .other: "Other"
        }
    }

    func matches(_ item: MediaItem) -> Bool {
        switch self {
        case .all: true
        case .photos: item.category == .photos
        case .videos: item.kind == .video
        case .screenshots: item.isScreenshot
        case .other: item.category == .other
        }
    }
}

enum MediaSourceFilter: String, CaseIterable, Identifiable, Sendable {
    case all, files, photosLibrary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All Sources"
        case .files: "Folders"
        case .photosLibrary: "Photos Library"
        }
    }

    func matches(_ item: MediaItem) -> Bool {
        switch self {
        case .all: true
        case .files: !item.isPhotosAsset
        case .photosLibrary: item.isPhotosAsset
        }
    }
}

enum BrowserLayout: String, CaseIterable, Identifiable, Sendable {
    case grid, list
    var id: String { rawValue }
}

/// Search, filter and sort state for a media browser.
struct MediaQuery: Hashable, Sendable {
    var searchText = ""
    var sort: MediaSort = .dateNewest
    var kind: MediaKindFilter = .all
    var source: MediaSourceFilter = .all

    func apply(to items: [MediaItem]) -> [MediaItem] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = items.filter { item in
            kind.matches(item) && source.matches(item)
                && (needle.isEmpty || item.filename.localizedCaseInsensitiveContains(needle))
        }
        return sort.sorted(filtered)
    }
}

/// A titled run of items, e.g. one month of screenshots.
struct MediaSection: Identifiable {
    let id: String
    let title: String?
    let items: [MediaItem]

    /// Groups already-sorted items into consecutive month sections, preserving order.
    static func byMonth(_ items: [MediaItem], calendar: Calendar = .current) -> [MediaSection] {
        var sections: [MediaSection] = []
        var currentKey: DateComponents?
        var bucket: [MediaItem] = []

        func flush() {
            guard let key = currentKey, let first = bucket.first else { return }
            let title = first.effectiveDate.formatted(.dateTime.month(.wide).year())
            sections.append(MediaSection(id: "\(key.year ?? 0)-\(key.month ?? 0)", title: title, items: bucket))
        }

        for item in items {
            let key = calendar.dateComponents([.year, .month], from: item.effectiveDate)
            if key != currentKey {
                flush()
                currentKey = key
                bucket = []
            }
            bucket.append(item)
        }
        flush()
        return sections
    }
}

/// Finder-style click selection: plain click selects one, ⌘ toggles, ⇧ extends a range.
enum SelectionLogic {
    struct Modifiers: OptionSet {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1 << 0)
        static let shift = Modifiers(rawValue: 1 << 1)
    }

    static func click(
        _ id: MediaItem.ID,
        orderedIDs: [MediaItem.ID],
        selection: Set<MediaItem.ID>,
        anchor: MediaItem.ID?,
        modifiers: Modifiers
    ) -> (selection: Set<MediaItem.ID>, anchor: MediaItem.ID?) {
        if modifiers.contains(.shift), let anchor,
           let start = orderedIDs.firstIndex(of: anchor), let end = orderedIDs.firstIndex(of: id) {
            let range = Set(orderedIDs[min(start, end)...max(start, end)])
            return (modifiers.contains(.command) ? selection.union(range) : range, anchor)
        }
        if modifiers.contains(.command) {
            var updated = selection
            if updated.contains(id) { updated.remove(id) } else { updated.insert(id) }
            return (updated, id)
        }
        return ([id], id)
    }

    /// Index reached by moving with the arrow keys in a grid of `columns` columns.
    static func move(from index: Int?, count: Int, columns: Int, direction: Direction) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return 0 }
        let columns = max(1, columns)
        let target = switch direction {
        case .left: index - 1
        case .right: index + 1
        case .up: index - columns
        case .down: index + columns
        }
        return min(max(target, 0), count - 1)
    }

    enum Direction { case left, right, up, down }
}
