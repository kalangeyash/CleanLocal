import SwiftUI

/// Composition root: builds every service and store once and wires them together.
@MainActor
final class AppEnvironment {
    let settings: SettingsStore
    let library: LibraryStore
    let analysis: AnalysisStore
    let deletion: DeletionStore
    let navigation: NavigationModel
    let thumbnails: ThumbnailService
    let photos: PhotosLibraryService
    let storage: StorageAnalyticsService
    let persistence: PersistenceController

    init(persistence: PersistenceController = .live(), defaults: UserDefaults = .standard) {
        self.persistence = persistence
        let photos = PhotosLibraryService()
        self.photos = photos
        storage = StorageAnalyticsService()
        settings = SettingsStore(defaults: defaults)
        thumbnails = ThumbnailService(diskCacheDirectory: ThumbnailService.defaultDiskCacheDirectory(), photosProvider: photos)
        navigation = NavigationModel()

        library = LibraryStore(
            persistence: persistence,
            scanner: MediaScannerService(),
            bookmarks: BookmarkManager(),
            photos: photos,
            settings: settings
        )
        analysis = AnalysisStore(
            library: library,
            settings: settings,
            duplicateService: DuplicateDetectionService(photosHasher: photos),
            similarityService: SimilarityDetectionService(photosHasher: photos)
        )
        deletion = DeletionStore(
            service: SafeDeletionService(photosDeleter: photos),
            library: library,
            analysis: analysis,
            persistence: persistence
        )
        library.onScanCompleted = { [weak analysis] in analysis?.libraryDidRescan() }
    }

    /// Loads persisted state and restores folder access. Safe to call more than once.
    func bootstrap() async {
        settings.applyAppearance()
        await library.bootstrap()
        await deletion.bootstrap()
        if !library.items.isEmpty, settings.analyzeDuplicatesAfterScan, analysis.duplicatePhase == .notStarted {
            analysis.analyzeDuplicates()
        }
    }
}

extension EnvironmentValues {
    @Entry var thumbnailService: ThumbnailService?
    @Entry var photosService: PhotosLibraryService?
    @Entry var storageService: StorageAnalyticsService = StorageAnalyticsService()
}

extension View {
    /// Injects every store and service a CleanLocal window needs.
    func cleanLocalEnvironment(_ environment: AppEnvironment) -> some View {
        self
            .environment(environment.settings)
            .environment(environment.library)
            .environment(environment.analysis)
            .environment(environment.deletion)
            .environment(environment.navigation)
            .environment(\.thumbnailService, environment.thumbnails)
            .environment(\.photosService, environment.photos)
            .environment(\.storageService, environment.storage)
    }
}
