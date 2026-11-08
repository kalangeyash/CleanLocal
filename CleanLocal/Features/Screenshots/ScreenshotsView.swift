import SwiftUI

struct ScreenshotsView: View {
    enum SizeFilter: Int, CaseIterable, Identifiable {
        case any = 0, overOne = 1, overFive = 5, overTen = 10
        var id: Int { rawValue }
        var title: String { self == .any ? "Any Size" : "> \(rawValue) MB" }
        var minimumBytes: Int64 { Int64(rawValue) * 1_000_000 }
    }

    @Environment(LibraryStore.self) private var library
    @State private var sizeFilter: SizeFilter = .any

    var body: some View {
        MediaBrowserView(
            title: "Screenshots",
            items: library.items.filter { $0.isScreenshot && $0.size >= sizeFilter.minimumBytes },
            revision: [AnyHashable(library.revision), AnyHashable(sizeFilter)],
            configuration: MediaBrowserConfiguration(
                defaultSort: .dateNewest,
                showsKindFilter: false,
                groupsByMonth: true,
                emptySymbol: "camera.viewfinder",
                emptyTitle: "No Screenshots",
                emptyMessage: "Screenshots are recognized by macOS screenshot metadata, standard screenshot names and Screenshots folders."
            )
        ) {
            ChipPicker(options: SizeFilter.allCases, selection: $sizeFilter) { $0.title }
        }
    }
}
