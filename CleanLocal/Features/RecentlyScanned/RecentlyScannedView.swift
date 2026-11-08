import SwiftUI

struct RecentlyScannedView: View {
    enum Window: String, CaseIterable, Identifiable {
        case latestScan, week, month
        var id: String { rawValue }
        var title: String {
            switch self {
            case .latestScan: "Latest Scan"
            case .week: "Last 7 Days"
            case .month: "Last 30 Days"
            }
        }
    }

    @Environment(LibraryStore.self) private var library
    @State private var window: Window = .latestScan

    var body: some View {
        MediaBrowserView(
            title: "Recently Scanned",
            items: library.items.filter { $0.discoveredAt >= cutoff },
            revision: [AnyHashable(library.revision), AnyHashable(window)],
            configuration: MediaBrowserConfiguration(
                defaultSort: .dateNewest,
                emptySymbol: "sparkle.magnifyingglass",
                emptyTitle: "Nothing New",
                emptyMessage: "Media that CleanLocal discovers for the first time shows up here."
            )
        ) {
            ChipPicker(options: Window.allCases, selection: $window) { $0.title }
        }
    }

    private var cutoff: Date {
        switch window {
        case .latestScan:
            // Items first indexed during the most recent completed scan.
            library.scanSessions.first { !$0.wasCancelled }?.startedAt ?? .distantPast
        case .week:
            Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
        case .month:
            Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
        }
    }
}
