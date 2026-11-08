import SwiftUI

struct PhotosLibraryView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        Group {
            switch library.photosAuthorization {
            case .authorized, .limited:
                PhotosLibraryBrowser()
            case .notDetermined, .denied, .restricted:
                PhotosAccessView()
            }
        }
        .onAppear { library.refreshPhotosAuthorization() }
    }
}

private struct PhotosAccessView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        VStack(spacing: Spacing.xl) {
            EmptyStateView(
                symbol: "photo.stack",
                title: "Connect Your Photos Library",
                message: "CleanLocal uses Apple’s PhotoKit to find large videos, screenshots and duplicates in Photos. It never edits the library package directly, and every deletion is confirmed by Photos itself."
            ) {
                PhotosConnectRow()
                    .frame(maxWidth: 520)
                    .card()
            }
        }
        .background(Palette.pageBackground)
    }
}

private struct PhotosLibraryBrowser: View {
    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings
    @Environment(\.photosService) private var photos
    @State private var albums: [PhotoAlbum] = []
    @State private var selectedAlbumID: String?
    @State private var albumItemIDs: Set<MediaItem.ID>?

    var body: some View {
        HSplitView {
            albumList
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 300)
            browser
                .frame(minWidth: 480)
        }
        .task { await loadAlbums() }
        .task(id: selectedAlbumID) { await loadAlbumMembers() }
    }

    private var albumList: some View {
        List(selection: $selectedAlbumID) {
            Section("Library") {
                Label("All Photos & Videos", systemImage: "photo.on.rectangle")
                    .tag(String?.none)
            }
            let smart = albums.filter(\.isSmartAlbum)
            if !smart.isEmpty {
                Section("Smart Albums") {
                    ForEach(smart) { album in albumRow(album, symbol: "gearshape") }
                }
            }
            let user = albums.filter { !$0.isSmartAlbum }
            if !user.isEmpty {
                Section("My Albums") {
                    ForEach(user) { album in albumRow(album, symbol: "rectangle.stack") }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                @Bindable var settings = settings
                Toggle("Include in scans", isOn: $settings.includePhotosLibrary)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                if library.photosAuthorization == .limited {
                    Text("Limited access: only photos you selected are visible.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }

    private func albumRow(_ album: PhotoAlbum, symbol: String) -> some View {
        Label(album.title, systemImage: symbol)
            .badge(album.assetCount)
            .tag(Optional(album.id))
    }

    @ViewBuilder
    private var browser: some View {
        let photosItems = library.photosItems
        if photosItems.isEmpty {
            EmptyStateView(
                symbol: "sparkle.magnifyingglass",
                title: "Photos Library Not Indexed Yet",
                message: settings.includePhotosLibrary
                    ? "Run a scan to index your Photos library. Only metadata is read; originals stay where they are."
                    : "Turn on “Include in scans”, then run a scan."
            ) {
                if settings.includePhotosLibrary {
                    ScanButton(large: true)
                }
            }
            .background(Palette.pageBackground)
        } else {
            MediaBrowserView(
                title: albums.first { $0.id == selectedAlbumID }?.title ?? "Photos Library",
                items: albumItemIDs.map { ids in photosItems.filter { ids.contains($0.id) } } ?? photosItems,
                revision: [AnyHashable(library.revision), AnyHashable(selectedAlbumID), AnyHashable(albumItemIDs?.count)],
                configuration: MediaBrowserConfiguration(
                    defaultSort: .dateNewest,
                    showsSourceFilter: false,
                    emptySymbol: "photo.stack",
                    emptyTitle: "No Items",
                    emptyMessage: "This album has no indexed photos or videos. Rescan if you recently added some."
                )
            ) {
                InfoBanner(
                    style: .info,
                    message: "Deleting here uses Photos’ own confirmation. Items move to Recently Deleted and can be recovered there for up to 30 days."
                )
            }
        }
    }

    private func loadAlbums() async {
        guard let photos else { return }
        albums = await Task.detached(priority: .userInitiated) { photos.fetchAlbums() }.value
    }

    private func loadAlbumMembers() async {
        guard let photos, let albumID = selectedAlbumID else {
            albumItemIDs = nil
            return
        }
        albumItemIDs = await Task.detached(priority: .userInitiated) { photos.itemIDs(inAlbum: albumID) }.value
    }
}
