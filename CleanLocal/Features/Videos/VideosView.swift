import SwiftUI

struct VideosView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        MediaBrowserView(
            title: "Videos",
            items: library.items.filter { $0.kind == .video },
            revision: library.revision,
            configuration: MediaBrowserConfiguration(
                defaultSort: .sizeDescending,
                showsKindFilter: false,
                emptySymbol: "film.stack",
                emptyTitle: "No Videos Found",
                emptyMessage: "Videos from your scanned folders and Photos library appear here, largest first."
            )
        )
    }
}
