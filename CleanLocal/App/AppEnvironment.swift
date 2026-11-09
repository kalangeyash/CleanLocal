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
    let access: AccessStore
    let cleanup: CleanupStore
    let trash: TrashStore
    let storageStore: StorageStore
    let maintenance: MaintenanceStore

    init(
        persistence: PersistenceController = .live(),
        defaults: UserDefaults = .standard,
        policy: ProtectedPathPolicy = .standard
    ) {
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
            settings: settings,
            policy: policy
        )
        analysis = AnalysisStore(
            library: library,
            settings: settings,
            duplicateService: DuplicateDetectionService(photosHasher: photos),
            similarityService: SimilarityDetectionService(photosHasher: photos)
        )
        deletion = DeletionStore(
            service: SafeDeletionService(photosDeleter: photos, policy: policy),
            library: library,
            analysis: analysis,
            persistence: persistence
        )
        access = AccessStore(persistence: persistence)
        trash = TrashStore(access: access, library: library, deletion: deletion)
        cleanup = CleanupStore(access: access, settings: settings, deletion: deletion, trash: trash,
                               engine: SafetyPolicyEngine(homePath: UserDirectories.realHomePath))
        storageStore = StorageStore(access: access, storage: storage)
        maintenance = MaintenanceStore(access: access)
        library.onScanCompleted = { [weak analysis] in analysis?.libraryDidRescan() }
        cleanup.onItemsRemoved = { [weak storageStore] paths in storageStore?.markRemoved(paths) }
    }

    /// Loads persisted state and restores folder access. Safe to call more than once.
    func bootstrap() async {
        if CommandLine.arguments.contains("-CleanLocalAccessReport") {
            // Diagnostics: records what the sandbox allows, inside the app's own container.
            AccessAuditor.writeReport(to: FileManager.default.temporaryDirectory.appendingPathComponent("access-report.json"))
        }
        settings.applyAppearance()
        await access.bootstrap()
        await library.bootstrap()
        await deletion.bootstrap()
        storageStore.refreshAreas()
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
            .environment(environment.access)
            .environment(environment.cleanup)
            .environment(environment.trash)
            .environment(environment.storageStore)
            .environment(environment.maintenance)
            .environment(\.thumbnailService, environment.thumbnails)
            .environment(\.photosService, environment.photos)
            .environment(\.storageService, environment.storage)
            // Brand accent (Blaze Orange) for every control, regardless of the system accent.
            .tint(Palette.accent)
    }
}
