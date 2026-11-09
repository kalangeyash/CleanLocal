import SwiftUI

struct TrashManagerView: View {
    @Environment(AccessStore.self) private var access
    @Environment(TrashStore.self) private var trash
    @State private var confirmation: [TrashEntry]?
    @State private var previewURL: URL?
    @State private var sortOrder = [KeyPathComparator(\TrashEntry.size.allocatedSize, order: .reverse)]

    var body: some View {
        @Bindable var trash = trash
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                PageHeader(title: "Trash Manager", subtitle: subtitle) {
                    HStack(spacing: Spacing.s) {
                        Button("Refresh") { Task { await trash.refresh() } }.buttonStyle(.glass).disabled(!access.hasTrashAccess)
                        Button("Empty Trash…") { confirmation = trash.entries }
                            .buttonStyle(.destructive)
                            .disabled(trash.entries.isEmpty || trash.isEmptying)
                    }
                }
                InfoBanner(style: .warning, title: "Emptying the Trash is permanent",
                           message: "Items you remove here can’t be recovered — not by CleanLocal, and not from the Trash. CleanLocal never empties the Trash on its own, and Smart Cleanup never empties it either.")
                if let result = trash.lastResult {
                    InfoBanner(style: result.failures.isEmpty ? .success : .warning,
                               title: "Freed \(result.freedBytes.formattedBytes)",
                               message: result.failures.isEmpty ? "The selected items were permanently removed." : result.failures.prefix(3).joined(separator: "\n"))
                }
            }
            .padding(.horizontal, Spacing.xxl)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.m)
            Divider().opacity(0.6)

            if !access.hasTrashAccess {
                AccessRequiredView(kind: .trash)
            } else if trash.entries.isEmpty {
                EmptyStateView(symbol: "trash", title: trash.isLoading ? "Reading the Trash…" : "The Trash Is Empty",
                               message: trash.issues.first?.reason ?? "Nothing is waiting to be permanently removed.", tint: Palette.accent)
            } else {
                let sorted = trash.entries.sorted(using: sortOrder)
                Table(sorted, selection: $trash.selection, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name) { entry in
                        HStack(spacing: Spacing.s) {
                            FileThumbnailView(url: entry.url, size: 26, showsThumbnail: !entry.isDirectory)
                            Text(entry.name).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .width(min: 200, ideal: 300)
                    TableColumn("Original Location") { entry in
                        Text(entry.originalPath.map { UserDirectories.abbreviate(path: ($0 as NSString).deletingLastPathComponent) } ?? "—")
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            .help(entry.originalPath == nil ? "Known only for items CleanLocal moved to the Trash." : "")
                    }
                    .width(min: 140, ideal: 220)
                    TableColumn("Trashed") { Text($0.dateTrashed?.mediumDisplay ?? "—").foregroundStyle(.secondary) }
                        .width(min: 110, ideal: 140)
                    TableColumn("Items") { Text($0.size.fileCount.formatted()).monospacedDigit().foregroundStyle(.secondary) }
                        .width(min: 50, ideal: 60)
                    TableColumn("Size", value: \.size.allocatedSize) { Text($0.size.allocatedSize.formattedBytes).monospacedDigit() }
                        .width(min: 70, ideal: 90)
                }
                .contextMenu(forSelectionType: TrashEntry.ID.self) { ids in
                    let chosen = trash.entries.filter { ids.contains($0.id) }
                    if let first = chosen.first {
                        Button("Quick Look", systemImage: "eye") { previewURL = first.url }
                        Divider()
                        Button("Delete Permanently…", systemImage: "xmark.bin", role: .destructive) { confirmation = chosen }
                    }
                } primaryAction: { ids in
                    previewURL = trash.entries.first { ids.contains($0.id) }?.url
                }
                .onKeyPress(.space) {
                    guard let first = trash.selectedEntries.first else { return .ignored }
                    previewURL = first.url
                    return .handled
                }
                .quickLook($previewURL, in: sorted.map(\.url))
            }
        }
        .background(Palette.pageBackground)
        .overlay(alignment: .bottom) {
            if !trash.selectedEntries.isEmpty {
                HStack(spacing: Spacing.m) {
                    Text("\(trash.selectedEntries.count) selected · \(trash.selectedEntries.reduce(Int64(0)) { $0 + $1.size.allocatedSize }.formattedBytes)")
                        .font(.headline)
                    Button("Delete Permanently…") { confirmation = trash.selectedEntries }.buttonStyle(.destructive)
                }
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.s)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                .padding(.bottom, Spacing.xl)
            }
        }
        .task(id: access.hasTrashAccess) { await trash.refresh() }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
            presenting: confirmation
        ) { entries in
            Button("Delete Permanently", role: .destructive) {
                Task { await trash.permanentlyDelete(entries) }
            }
        } message: { entries in
            Text("\(entries.count) items (\(entries.reduce(Int64(0)) { $0 + $1.size.allocatedSize }.formattedBytes)) will be permanently deleted. This can’t be undone.")
        }
    }

    private var subtitle: String {
        guard access.hasTrashAccess else { return "See and empty what’s in the Trash" }
        let size = trash.totalSize
        return "\(trash.entries.count) items · \(size.allocatedSize.formattedBytes) on disk"
    }

    private var confirmationTitle: String {
        guard let confirmation else { return "" }
        return confirmation.count == trash.entries.count ? "Empty the Trash?" : "Delete \(confirmation.count) items permanently?"
    }
}
