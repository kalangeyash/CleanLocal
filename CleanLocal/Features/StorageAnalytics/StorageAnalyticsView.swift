import Charts
import SwiftUI

struct StorageAnalyticsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AnalysisStore.self) private var analysis
    @Environment(DeletionStore.self) private var deletion
    @Environment(\.storageService) private var storage
    @State private var volumes: [VolumeCapacity] = []
    @State private var highlighted: MediaCategory?

    private struct FolderUsage: Identifiable {
        var id: String { path }
        let path: String
        let bytes: Int64
        let count: Int
    }

    private struct LocationUsage: Identifiable {
        let id: String
        let name: String
        let bytes: Int64
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                PageHeader(title: "Storage", subtitle: "Real figures from your disks and the scanned media index")

                figures

                ForEach(volumes) { volume in
                    CapacityBar(volume: volume, mediaBytes: mediaBytes(on: volume))
                        .card(padding: Spacing.xl)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Spacing.l) {
                        categoryCard
                        locationCard
                    }
                    VStack(spacing: Spacing.l) {
                        categoryCard
                        locationCard
                    }
                }

                largestFolders
                glossary
            }
            .padding(Spacing.xxl)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.pageBackground)
        .task(id: library.revision) {
            let roots = library.locations.map { URL(fileURLWithPath: $0.path) }
            volumes = storage.volumes(for: roots)
        }
    }

    // MARK: Figures

    private var figures: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Spacing.l)], spacing: Spacing.l) {
            StatTile(title: "Scanned Media", value: library.breakdown.totalBytes.formattedBytes,
                     caption: "\(library.breakdown.totalCount.formatted()) items indexed", symbol: "photo.stack.fill", tint: Palette.brandIndigo)
            StatTile(title: "Potentially Reclaimable", value: analysis.duplicatePhase == .notStarted ? "—" : analysis.reclaimableDuplicateBytes.formattedBytes,
                     caption: "Extra copies of exact duplicates", symbol: "leaf.fill", tint: Palette.success)
            StatTile(title: "Moved to Trash", value: deletion.totalReclaimedBytes.formattedBytes,
                     caption: "By CleanLocal, all time", symbol: "trash.fill", tint: Palette.destructive)
        }
    }

    private func mediaBytes(on volume: VolumeCapacity) -> Int64 {
        let isStartup = volume.volumePath == "/" || volume.volumePath == volumes.first?.volumePath
        return library.items.reduce(Int64(0)) { total, item in
            guard let path = item.path else {
                // Photos library assets live on the startup disk by default.
                return isStartup ? total + item.size : total
            }
            if isStartup { return path.hasPrefix("/Volumes/") ? total : total + item.size }
            return path.hasPrefix(volume.volumePath + "/") ? total + item.size : total
        }
    }

    // MARK: Charts

    private var categoryCard: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("By Category").font(.cardTitle)
            if library.breakdown.totalBytes > 0 {
                Chart(library.breakdown.entries) { entry in
                    BarMark(x: .value("Size", Double(entry.bytes)), y: .value("Category", entry.category.title))
                        .foregroundStyle(entry.category.tint.gradient)
                        .cornerRadius(5)
                        .annotation(position: .trailing) {
                            Text(entry.bytes.formattedBytes).font(.caption).foregroundStyle(.secondary)
                        }
                }
                .chartXAxis(.hidden)
                .frame(height: 180)
            } else {
                noData
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Spacing.xl)
    }

    private var locationUsage: [LocationUsage] {
        var usage = library.locations.map { location in
            LocationUsage(id: location.id.uuidString, name: location.displayName,
                          bytes: StorageAnalyticsService.totalSize(of: library.items(in: location.id)))
        }
        let photosBytes = StorageAnalyticsService.totalSize(of: library.photosItems)
        if photosBytes > 0 { usage.append(LocationUsage(id: "photos", name: "Photos Library", bytes: photosBytes)) }
        return usage.sorted { $0.bytes > $1.bytes }
    }

    private var locationCard: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("By Location").font(.cardTitle)
            let usage = locationUsage
            if usage.contains(where: { $0.bytes > 0 }) {
                Chart(usage) { entry in
                    BarMark(x: .value("Size", Double(entry.bytes)), y: .value("Location", entry.name))
                        .foregroundStyle(Palette.brandGradient)
                        .cornerRadius(5)
                        .annotation(position: .trailing) {
                            Text(entry.bytes.formattedBytes).font(.caption).foregroundStyle(.secondary)
                        }
                }
                .chartXAxis(.hidden)
                .frame(height: max(120, CGFloat(usage.count) * 36))
            } else {
                noData
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Spacing.xl)
    }

    private var largestFolders: some View {
        let folders = Dictionary(grouping: library.items.filter { $0.path != nil }) { $0.directoryPath ?? "" }
            .map { FolderUsage(path: $0.key, bytes: StorageAnalyticsService.totalSize(of: $0.value), count: $0.value.count) }
            .sorted { $0.bytes > $1.bytes }
            .prefix(8)
        let maxBytes = Double(folders.first?.bytes ?? 1)
        return VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Largest Media Folders").font(.cardTitle)
            if folders.isEmpty {
                noData
            }
            ForEach(Array(folders)) { folder in
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(Palette.brandIndigo)
                        Text(UserDirectories.abbreviate(path: folder.path))
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        Text("\(folder.count) items").foregroundStyle(.secondary)
                        Text(folder.bytes.formattedBytes).monospacedDigit().frame(minWidth: 72, alignment: .trailing)
                    }
                    .font(.callout)
                    GeometryReader { geometry in
                        Capsule().fill(Palette.brandGradient)
                            .frame(width: max(4, geometry.size.width * Double(folder.bytes) / maxBytes))
                    }
                    .frame(height: 4)
                }
                .contextMenu {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.path)])
                    }
                }
            }
        }
        .card(padding: Spacing.xl)
    }

    private var glossary: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("What these numbers mean").font(.cardTitle)
            glossaryRow("Scanned media", "Total size of every photo and video CleanLocal has indexed.")
            glossaryRow("Selected", "The size of items you’ve selected in a list. Shown in the selection bar.")
            glossaryRow("Potentially reclaimable", "What removing extra copies of exact duplicates would free. Estimates never count the copy you keep.")
            glossaryRow("Moved to Trash", "Only items the system confirmed were moved. Space is freed when you empty the Trash; Photos items free space after Recently Deleted is cleared.")
        }
        .card(padding: Spacing.xl)
    }

    private func glossaryRow(_ term: String, _ definition: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            Text(term).font(.callout.weight(.semibold)).frame(width: 170, alignment: .leading)
            Text(definition).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var noData: some View {
        Text("Scan to see data").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100)
    }
}
