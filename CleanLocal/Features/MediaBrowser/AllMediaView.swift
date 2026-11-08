import SwiftUI

struct AllMediaView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        MediaBrowserView(
            title: "All Media",
            items: library.items,
            revision: library.revision,
            configuration: MediaBrowserConfiguration(
                defaultSort: .dateNewest,
                emptyTitle: "No Media Yet",
                emptyMessage: "Scan your folders or Photos library and every photo and video will appear here."
            )
        )
    }
}
