import Charts
import SwiftUI

/// "What's using my disk?" — the breakdown of used space plus a drill-down explorer.
struct StorageAnalyzerView: View {
    @Environment(AccessStore.self) private var access
    @Environment(StorageStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                PageHeader(title: "Storage Analyzer", subtitle: subtitle) { DiskScanControls() }
                if case let .scanning(progress) = store.phase {
                    DiskScanProgressCard(progress: progress)
                }
                StorageBreakdownCard()
                if !access.hasHomeAccess {
                    AccessRequiredView(kind: .home).frame(minHeight: 300).card()
                } else if store.tree != nil {
                    StorageExplorer()
                } else if !store.isScanning {
                    EmptyStateView(symbol: "chart.pie", title: "Analyze Your Home Folder",
                                   message: "CleanLocal measures every folder (counting clones and hard links correctly) so you can see exactly where your space goes.") {
                        Button("Analyze Now") { store.scan() }.buttonStyle(.primaryLarge)
                    }
                    .frame(minHeight: 280)
                    .card()
                }
                InfoBanner(style: .info, title: "About these numbers",
                           message: "Sizes are space actually used on disk. Cloned files share space, so deleting a clone frees only its private part, shown as “frees”. macOS figures such as purgeable space, APFS snapshots and other users’ files are estimates or invisible to apps, and appear as “System Data & Other”.")
            }
            .padding(Spacing.xxl)
            .padding(.bottom, 80)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.pageBackground)
        .task { store.refreshAreas() }
    }

    private var subtitle: String {
        guard let tree = store.tree else { return "See what’s taking up space on your Mac" }
        return "Home folder analyzed \(tree.scannedAt.relativeDisplay) · \(tree.root.fileCount.formatted()) files"
    }
}

struct DiskScanControls: View {
    @Environment(StorageStore.self) private var store
    @Environment(AccessStore.self) private var access

    var body: some View {
        if store.isScanning {
            Button("Stop") { store.cancelScan() }.buttonStyle(.glass)
        } else {
            Button(store.tree == nil ? "Analyze" : "Re-analyze") { store.scan() }
                .buttonStyle(.primary)
                .disabled(!access.hasHomeAccess)
        }
    }
}

struct DiskScanProgressCard: View {
    let progress: DiskScanProgress

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Text("Measuring your Home folder…").font(.headline)
                Spacer()
                Text("\(progress.itemsVisited.formatted()) items · \(progress.bytesCounted.formattedBytes)")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary).contentTransition(.numericText())
            }
            ProgressView().progressViewStyle(.linear)
            Text(progress.currentPath).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .card(padding: Spacing.xl)
    }
}

/// Stacked bar and list of storage areas, each linking to where it can be cleaned.
struct StorageBreakdownCard: View {
    var compact = false
    @Environment(StorageStore.self) private var store
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.storageService) private var storage

    private static let palette: [Color] = [Palette.tangerine, Palette.blaze, Palette.flame, Palette.khaki, Palette.grey]

    var body: some View {
        let areas = store.areas
        let total = max(areas.reduce(Int64(0)) { $0 + $1.bytes }, 1)
        VStack(alignment: .leading, spacing: Spacing.l) {
            HStack {
                Text("What’s Using Your Disk").font(.cardTitle)
                Spacer()
                if let volume = storage.startupVolume() {
                    Text("\(volume.usedBytes.formattedBytes) used · \(volume.availableBytes.formattedBytes) available")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(Array(areas.enumerated()), id: \.element.id) { index, area in
                        Rectangle()
                            .fill(area.isMeasured ? AnyShapeStyle(color(index).gradient) : AnyShapeStyle(Palette.strongFill))
                            .frame(width: max(2, geometry.size.width * Double(area.bytes) / Double(total) - 2))
                            .help("\(area.title): \(area.bytes.formattedBytes)")
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 14)

            VStack(spacing: 0) {
                ForEach(Array(areas.prefix(compact ? 6 : areas.count).enumerated()), id: \.element.id) { index, area in
                    Button {
                        if let destination = area.destination {
                            if area.id == "photos" { navigation.showMedia(.photosLibrary) } else { navigation.destination = destination }
                        }
                    } label: {
                        HStack(spacing: Spacing.m) {
                            Image(systemName: area.symbolName)
                                .foregroundStyle(Palette.onBrand)
                                .frame(width: 26, height: 26)
                                .background(RoundedRectangle(cornerRadius: 7).fill(area.isMeasured ? AnyShapeStyle(color(index)) : AnyShapeStyle(Palette.strongFill)))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(area.title).font(.callout.weight(.medium))
                                Text(area.detail).font(.caption).foregroundStyle(.secondary).lineLimit(compact ? 1 : 2)
                            }
                            Spacer()
                            Text("\(Int((Double(area.bytes) / Double(total) * 100).rounded()))%")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(area.bytes.formattedBytes).font(.callout.monospacedDigit()).frame(minWidth: 76, alignment: .trailing)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                .opacity(area.destination == nil ? 0 : 1)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(area.destination == nil)
                    Divider().opacity(0.5)
                }
            }
            if store.tree == nil {
                Text("Analyze your Home folder to break down the rest of “Other data”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .card(padding: Spacing.xl)
    }

    private func color(_ index: Int) -> Color { Self.palette[index % Self.palette.count] }
}

/// DaisyDisk-style drill-down: ring chart of the current folder plus a sortable list.
private struct StorageExplorer: View {
    @Environment(StorageStore.self) private var store
    @Environment(CleanupStore.self) private var cleanup
    @State private var previewURL: URL?
    @State private var selectedAngle: Double?
    @State private var hovered: Int?

    var body: some View {
        if let tree = store.tree {
            let currentID = store.currentNodeID ?? tree.rootID
            let children = store.children(of: currentID)
            VStack(alignment: .leading, spacing: Spacing.l) {
                breadcrumb(tree.breadcrumb(to: currentID))
                HStack(alignment: .top, spacing: Spacing.xl) {
                    ring(children: children, total: tree.node(currentID).allocatedSize)
                        .frame(width: 260, height: 260)
                    list(children)
                }
            }
            .card(padding: Spacing.xl)
            .quickLook($previewURL, in: children.filter { $0.kind != .smallFiles }.map { URL(fileURLWithPath: $0.path) })
        }
    }

    private func breadcrumb(_ chain: [DiskNode]) -> some View {
        HStack(spacing: Spacing.xxs) {
            ForEach(chain) { node in
                Button(node.name) { store.currentNodeID = node.id }
                    .buttonStyle(.plain)
                    .font(.callout.weight(node.id == chain.last?.id ? .semibold : .regular))
                    .foregroundStyle(node.id == chain.last?.id ? Palette.ink : Color.secondary)
                if node.id != chain.last?.id {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if let current = chain.last {
                Text("\(current.allocatedSize.formattedBytes) · \(current.fileCount.formatted()) files")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func ring(children: [DiskNode], total: Int64) -> some View {
        let top = Array(children.prefix(12))
        let rest = children.dropFirst(12).reduce(Int64(0)) { $0 + $1.allocatedSize }
        let slices = top.map { ($0.name, Double($0.allocatedSize), $0.id) } + (rest > 0 ? [("Other", Double(rest), -1)] : [])
        let colors: [Color] = [Palette.tangerine, Palette.blaze, Palette.flame, Palette.khaki, Palette.grey]
        return Chart(Array(slices.enumerated()), id: \.offset) { index, slice in
            SectorMark(angle: .value("Size", slice.1), innerRadius: .ratio(0.55), angularInset: 1)
                .cornerRadius(3)
                .foregroundStyle(colors[index % colors.count].opacity(hovered == nil || hovered == slice.2 ? 1 : 0.35))
        }
        .chartLegend(.hidden)
        .chartAngleSelection(value: $selectedAngle)
        .onChange(of: selectedAngle) { _, value in
            guard let value else { hovered = nil; return }
            var running = 0.0
            hovered = slices.first { running += $0.1; return value <= running }?.2
        }
        .chartBackground { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let frame = geometry[anchor]
                    let label = hovered.flatMap { id in children.first { $0.id == id } }
                    VStack(spacing: 2) {
                        Text((label?.allocatedSize ?? total).formattedBytes).font(.system(.title3, design: .rounded, weight: .bold))
                        Text(label?.name ?? "This folder").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(width: 120)
                    .position(x: frame.midX, y: frame.midY)
                }
            }
        }
    }

    private func list(_ children: [DiskNode]) -> some View {
        let maxSize = Double(children.first?.allocatedSize ?? 1)
        return VStack(spacing: 0) {
            ForEach(children.prefix(60)) { node in
                HStack(spacing: Spacing.m) {
                    nodeIcon(node)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: Spacing.xs) {
                            Text(node.name).font(.callout).lineLimit(1).truncationMode(.middle)
                            if node.kind == .inaccessible { Badge(text: "No access", tint: Palette.grey) }
                        }
                        GeometryReader { geometry in
                            Capsule().fill(Palette.brandGradient)
                                .frame(width: max(3, geometry.size.width * Double(node.allocatedSize) / max(maxSize, 1)))
                        }
                        .frame(height: 4)
                    }
                    Spacer(minLength: Spacing.s)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(node.allocatedSize.formattedBytes).font(.callout.monospacedDigit())
                        if node.reclaimableSize < node.allocatedSize * 9 / 10, node.kind != .smallFiles {
                            Text("frees \(node.reclaimableSize.formattedBytes)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minWidth: 84, alignment: .trailing)
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if node.kind == .directory { store.currentNodeID = node.id } }
                .contextMenu { menu(for: node) }
                .onHover { inside in hovered = inside ? node.id : nil }
                Divider().opacity(0.4)
            }
            if children.count > 60 {
                Text("\(children.count - 60) more smaller items").font(.caption).foregroundStyle(.secondary).padding(.top, Spacing.s)
            }
        }
    }

    @ViewBuilder
    private func nodeIcon(_ node: DiskNode) -> some View {
        switch node.kind {
        case .directory:
            Button { store.currentNodeID = node.id } label: {
                Image(systemName: "folder.fill").foregroundStyle(Palette.accent).frame(width: 26)
            }
            .buttonStyle(.plain)
            .help("Open")
        case .smallFiles:
            Image(systemName: "square.grid.3x3.fill").foregroundStyle(Palette.grey).frame(width: 26)
        case .inaccessible:
            Image(systemName: "lock.fill").foregroundStyle(Palette.grey).frame(width: 26)
        case .file, .package:
            FileThumbnailView(url: URL(fileURLWithPath: node.path), size: 26)
        }
    }

    @ViewBuilder
    private func menu(for node: DiskNode) -> some View {
        if node.kind == .directory { Button("Open", systemImage: "folder") { store.currentNodeID = node.id } }
        if node.kind != .smallFiles {
            Button("Quick Look", systemImage: "eye") { previewURL = URL(fileURLWithPath: node.path) }
            Button("Reveal in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)]) }
        }
        if node.isRemovableEntry {
            Divider()
            let candidates = store.candidates(for: [node])
            Button("Move to Trash…", systemImage: "trash", role: .destructive) { cleanup.reviewCleanup(candidates) }
                .disabled(candidates.allSatisfy { !$0.isSelectable })
        }
    }
}
