import Observation

/// Every destination in the sidebar.
enum SidebarDestination: String, Hashable, CaseIterable, Identifiable {
    case overview
    case smartCleanup
    case systemJunk
    case applicationCache
    case temporaryFiles
    case browserCleanup
    case developerCleanup
    case leftovers
    case largeFiles
    case duplicates
    case mediaCleaner
    case oldFiles
    case trashManager
    case storageAnalyzer
    case maintenance
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .smartCleanup: "Smart Cleanup"
        case .systemJunk: "System Junk"
        case .applicationCache: "Application Cache"
        case .temporaryFiles: "Temporary Files"
        case .browserCleanup: "Browser Cleanup"
        case .developerCleanup: "Developer Cleanup"
        case .leftovers: "Application Leftovers"
        case .largeFiles: "Large Files"
        case .duplicates: "Duplicate Finder"
        case .mediaCleaner: "Media Cleaner"
        case .oldFiles: "Old Files"
        case .trashManager: "Trash Manager"
        case .storageAnalyzer: "Storage Analyzer"
        case .maintenance: "Maintenance"
        case .history: "Cleanup History"
        case .settings: "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: "square.grid.2x2.fill"
        case .smartCleanup: "sparkles"
        case .systemJunk: "gearshape.2.fill"
        case .applicationCache: "shippingbox.fill"
        case .temporaryFiles: "hourglass"
        case .browserCleanup: "globe"
        case .developerCleanup: "hammer.fill"
        case .leftovers: "app.dashed"
        case .largeFiles: "externaldrive.fill"
        case .duplicates: "square.on.square.fill"
        case .mediaCleaner: "photo.on.rectangle.angled"
        case .oldFiles: "clock.arrow.circlepath"
        case .trashManager: "trash.fill"
        case .storageAnalyzer: "chart.pie.fill"
        case .maintenance: "wrench.and.screwdriver.fill"
        case .history: "list.bullet.rectangle.portrait.fill"
        case .settings: "gearshape.fill"
        }
    }

    /// The cleanup group shown by a category module, if any.
    var cleanupGroups: [CleanupGroup]? {
        switch self {
        case .systemJunk: [.systemJunk]
        case .applicationCache: [.applicationCache]
        case .temporaryFiles: [.temporaryFiles, .installers]
        case .browserCleanup: [.browser]
        case .developerCleanup: [.developer]
        case .leftovers: [.leftovers]
        default: nil
        }
    }

    enum Section: String, CaseIterable {
        case overview = "Overview"
        case cleanup = "Cleanup"
        case files = "Files & Media"
        case storage = "Storage"
        case activity = "Activity"
    }

    static func destinations(in section: Section) -> [SidebarDestination] {
        switch section {
        case .overview: [.overview, .smartCleanup]
        case .cleanup: [.systemJunk, .applicationCache, .temporaryFiles, .browserCleanup, .developerCleanup, .leftovers]
        case .files: [.largeFiles, .duplicates, .mediaCleaner, .oldFiles]
        case .storage: [.storageAnalyzer, .trashManager, .maintenance]
        case .activity: [.history]
        }
    }

    /// Order used for ⌘1…⌘9 shortcuts.
    static let shortcutOrder: [SidebarDestination] = [
        .overview, .smartCleanup, .storageAnalyzer, .largeFiles, .duplicates, .mediaCleaner, .developerCleanup, .trashManager, .history,
    ]
}

/// Sub-sections of the Media Cleaner.
enum MediaTab: String, CaseIterable, Identifiable, Hashable {
    case library, videos, screenshots, similar, largeMedia, oldMedia, photosLibrary, recentlyScanned

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: "All Media"
        case .videos: "Videos"
        case .screenshots: "Screenshots"
        case .similar: "Similar Photos"
        case .largeMedia: "Large Media"
        case .oldMedia: "Old Media"
        case .photosLibrary: "Photos Library"
        case .recentlyScanned: "Recent"
        }
    }

    var symbolName: String {
        switch self {
        case .library: "photo.on.rectangle"
        case .videos: "film"
        case .screenshots: "camera.viewfinder"
        case .similar: "rectangle.stack"
        case .largeMedia: "externaldrive"
        case .oldMedia: "clock.arrow.circlepath"
        case .photosLibrary: "photo.stack"
        case .recentlyScanned: "sparkle.magnifyingglass"
        }
    }
}

enum DuplicateTab: String, CaseIterable, Identifiable, Hashable {
    case media, files
    var id: String { rawValue }
    var title: String { self == .media ? "Photos & Videos" : "All Files" }
}

@MainActor
@Observable
final class NavigationModel {
    var destination: SidebarDestination? = .overview
    var mediaTab: MediaTab = .library
    var duplicateTab: DuplicateTab = .media

    func showMedia(_ tab: MediaTab) {
        mediaTab = tab
        destination = .mediaCleaner
    }
}
