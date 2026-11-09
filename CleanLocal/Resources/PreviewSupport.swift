#if DEBUG
import SwiftUI

/// Sample data for Xcode previews. Debug builds only; never used by the shipping app.
@MainActor
enum PreviewData {
    static let environment: AppEnvironment = {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("CleanLocalPreviews", isDirectory: true)
        let defaults = UserDefaults(suiteName: "CleanLocalPreviews") ?? .standard
        return AppEnvironment(persistence: PersistenceController(baseURL: base), defaults: defaults)
    }()

    static func candidate(
        _ name: String, category: String, bytes: Int64, files: Int, safety: SafetyLevel,
        detail: String? = nil, reasons: [String] = [], owner: AppOwner? = nil
    ) -> CleanupCandidate {
        let url = URL(fileURLWithPath: "/Users/preview/Library/Caches/\(name)")
        return CleanupCandidate(
            id: url.path, url: url, categoryID: category, displayName: name, detail: detail, scope: .contents,
            safety: safety, reasons: reasons, owner: owner, isDirectory: true,
            size: DirectorySize(logicalSize: bytes, allocatedSize: bytes, reclaimableSize: bytes, fileCount: files,
                                directoryCount: 1, newestModification: .now.addingTimeInterval(-86_400 * 3)),
            identity: FileIdentity(device: 1, inode: UInt64(abs(name.hashValue))), rootPath: "/Users/preview"
        )
    }

    static let caches: [CleanupCandidate] = [
        candidate("Google Chrome", category: "app-caches", bytes: 1_710_000_000, files: 4_210, safety: .safe, detail: "com.google.Chrome"),
        candidate("Brave Browser", category: "app-caches", bytes: 560_000_000, files: 1_022, safety: .safe, detail: "com.brave.Browser"),
        candidate("Slack", category: "app-caches", bytes: 312_000_000, files: 880, safety: .protected, detail: "com.tinyspeck.slackmacgap",
                  reasons: ["Slack is running. Quit it to clean this safely."]),
        candidate("OldEditor", category: "app-caches", bytes: 95_000_000, files: 120, safety: .safe, detail: "com.gone.OldEditor",
                  reasons: ["The app is no longer installed."],
                  owner: AppOwner(bundleID: "com.gone.OldEditor", name: "OldEditor", isInstalled: false, isRunning: false)),
        candidate("Spotlight", category: "app-caches", bytes: 41_000_000, files: 60, safety: .review, detail: "com.apple.Spotlight",
                  reasons: ["Apple service cache. macOS rebuilds most of these, but some services keep state here."]),
    ]

    static let deviceSupport: [CleanupCandidate] = [
        candidate("iOS 27.0 (24A437)", category: "xcode-device-support", bytes: 6_600_000_000, files: 9_801, safety: .review, detail: "iOS DeviceSupport"),
    ]
}

#Preview("Category — App Caches") {
    @Previewable @State var selection: Set<CleanupCandidate.ID> = Set(PreviewData.caches.filter { $0.safety == .safe }.map(\.id))
    @Previewable @State var previewURL: URL?
    CategorySection(category: CleanupCatalog.category(id: "app-caches")!, candidates: PreviewData.caches,
                    selection: $selection, previewURL: $previewURL)
        .padding()
        .frame(width: 820)
        .background(Palette.pageBackground)
}

#Preview("Candidate Rows") {
    @Previewable @State var selection: Set<CleanupCandidate.ID> = []
    VStack(spacing: 0) {
        ForEach(PreviewData.caches + PreviewData.deviceSupport) { candidate in
            CandidateRow(candidate: candidate, selection: $selection) {}
            Divider()
        }
    }
    .card(padding: 0)
    .padding()
    .frame(width: 820)
}

#Preview("Safety Pills & Selection Bar") {
    VStack(spacing: 24) {
        HStack { ForEach(SafetyLevel.allCases, id: \.self) { SafetyPill(level: $0) } }
        CleanupSelectionBar(count: 12, bytes: 2_840_000_000) {}
        SelectionActionBar(count: 3, bytes: 4_500_000, canReveal: true, onPreview: {}, onReveal: {}, onDeselect: {}, onMoveToTrash: {})
    }
    .padding(40)
    .background(Palette.pageBackground)
}

#Preview("Stat Tiles") {
    HStack(spacing: 16) {
        StatTile(title: "Total Media", value: "18,402", caption: "3 folders + Photos", symbol: "photo.on.rectangle.angled", tint: Palette.tangerine) {}
        StatTile(title: "Media Storage", value: "70.91 GB", caption: "Scanned media size", symbol: "internaldrive.fill", tint: Palette.blaze) {}
        StatTile(title: "Potential Savings", value: "4.2 GB", caption: "Extra duplicate copies", symbol: "leaf.fill", tint: Palette.success) {}
    }
    .padding(24)
    .frame(width: 760)
    .background(Palette.pageBackground)
}

#Preview("Access Required") {
    AccessRequiredView(kind: .home)
        .cleanLocalEnvironment(PreviewData.environment)
        .frame(width: 760, height: 520)
}

#Preview("Onboarding") {
    OnboardingView()
        .cleanLocalEnvironment(PreviewData.environment)
        .frame(width: 1000, height: 820)
}

#Preview("Maintenance") {
    MaintenanceView()
        .cleanLocalEnvironment(PreviewData.environment)
        .frame(width: 1100, height: 900)
}

#Preview("Whole App") {
    ContentView()
        .cleanLocalEnvironment(PreviewData.environment)
        .frame(width: 1240, height: 820)
}
#endif
