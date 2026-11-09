import SwiftUI

/// Main window: sidebar navigation plus the selected destination.
struct ContentView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(NavigationModel.self) private var navigation
    @Environment(AccessStore.self) private var access

    var body: some View {
        @Bindable var library = library
        @Bindable var access = access
        NavigationSplitView {
            SidebarView()
        } detail: {
            DetailRouter(destination: navigation.destination ?? .overview)
                .frame(minWidth: 680, minHeight: 520)
        }
        .toolbar(removing: .title)
        .deletionSheetHost(context: .main)
        .cleanupSheetHost()
        .alert(item: $access.presentedError) { error in
            Alert(title: Text(error.title), message: Text(error.message), dismissButton: .default(Text("OK")))
        }
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
            case .smartCleanup: SmartCleanupView()
            case .systemJunk, .applicationCache, .temporaryFiles, .browserCleanup, .developerCleanup, .leftovers:
                CleanupModuleView(destination: destination)
            case .largeFiles: LargeFilesView()
            case .duplicates: DuplicateFinderView()
            case .mediaCleaner: MediaCleanerView()
            case .oldFiles: OldFilesView()
            case .trashManager: TrashManagerView()
            case .storageAnalyzer: StorageAnalyzerView()
            case .maintenance: MaintenanceView()
            case .history: DeletionHistoryView()
            case .settings: SettingsView(embedded: true)
            }
        }
        .navigationTitle(destination.title)
        .id(destination) // fresh state (selection, filters) per destination
        .transition(.opacity)
    }
}
