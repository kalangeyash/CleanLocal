import SwiftUI

/// Main window: sidebar navigation plus the selected destination.
struct ContentView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        @Bindable var library = library
        NavigationSplitView {
            SidebarView()
        } detail: {
            DetailRouter(destination: navigation.destination ?? .overview)
                .frame(minWidth: 680, minHeight: 520)
        }
        .toolbar(removing: .title)
        .deletionSheetHost(context: .main)
        .alert(item: $library.presentedError) { error in
            Alert(title: Text(error.title), message: Text(error.message), dismissButton: .default(Text("OK")))
        }
    }
}

struct DetailRouter: View {
    let destination: SidebarDestination

    var body: some View {
        Group {
            switch destination {
            case .overview: DashboardView()
            case .allMedia: AllMediaView()
            case .largeFiles: LargeFilesView()
            case .duplicates: DuplicatesView()
            case .similar: SimilarPhotosView()
            case .oldMedia: OldMediaView()
            case .videos: VideosView()
            case .screenshots: ScreenshotsView()
            case .recentlyScanned: RecentlyScannedView()
            case .photosLibrary: PhotosLibraryView()
            case .storage: StorageAnalyticsView()
            case .history: DeletionHistoryView()
            case .settings: SettingsView(embedded: true)
            }
        }
        .navigationTitle(destination.title)
        .id(destination) // fresh state (selection, filters) per destination
        .transition(.opacity)
    }
}
