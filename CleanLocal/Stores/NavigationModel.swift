import Observation

/// Every destination in the sidebar.
enum SidebarDestination: String, Hashable, CaseIterable, Identifiable {
    case overview
    case allMedia
    case largeFiles
    case duplicates
    case similar
    case oldMedia
    case videos
    case screenshots
    case recentlyScanned
    case photosLibrary
    case storage
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .allMedia: "All Media"
        case .largeFiles: "Large Files"
        case .duplicates: "Duplicate Media"
        case .similar: "Similar Photos"
        case .oldMedia: "Old Media"
        case .videos: "Videos"
        case .screenshots: "Screenshots"
        case .recentlyScanned: "Recently Scanned"
        case .photosLibrary: "Photos Library"
        case .storage: "Storage"
        case .history: "Trash & History"
        case .settings: "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: "square.grid.2x2.fill"
        case .allMedia: "photo.on.rectangle.angled"
        case .largeFiles: "externaldrive.fill"
        case .duplicates: "square.on.square.fill"
        case .similar: "rectangle.stack.fill"
        case .oldMedia: "clock.arrow.circlepath"
        case .videos: "film.stack.fill"
        case .screenshots: "camera.viewfinder"
        case .recentlyScanned: "sparkle.magnifyingglass"
        case .photosLibrary: "photo.stack.fill"
        case .storage: "chart.pie.fill"
        case .history: "trash.fill"
        case .settings: "gearshape.fill"
        }
    }

    enum Section: String, CaseIterable {
        case library = "Library"
        case cleanup = "Clean Up"
        case sources = "Sources & Insights"
        case activity = "Activity"
    }

    static func destinations(in section: Section) -> [SidebarDestination] {
        switch section {
        case .library: [.overview, .allMedia, .videos, .screenshots, .recentlyScanned]
        case .cleanup: [.duplicates, .similar, .largeFiles, .oldMedia]
        case .sources: [.photosLibrary, .storage]
        case .activity: [.history]
        }
    }

    /// Order used for ⌘1…⌘9 shortcuts.
    static let shortcutOrder: [SidebarDestination] = [
        .overview, .allMedia, .largeFiles, .duplicates, .similar, .oldMedia, .videos, .screenshots, .storage,
    ]
}

@MainActor
@Observable
final class NavigationModel {
    var destination: SidebarDestination? = .overview
}
