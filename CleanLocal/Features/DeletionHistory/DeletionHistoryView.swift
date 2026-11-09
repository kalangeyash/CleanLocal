import SwiftUI

struct DeletionHistoryView: View {
    @Environment(DeletionStore.self) private var deletion
    @State private var searchText = ""
    @State private var showsClearConfirmation = false
    @State private var sortOrder = [KeyPathComparator(\DeletionRecord.timestamp, order: .reverse)]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                PageHeader(title: "Cleanup History", subtitle: subtitle) {
                    Button("Clear History…") { showsClearConfirmation = true }
                        .buttonStyle(.glass)
                        .disabled(deletion.history.isEmpty)
                }
                InfoBanner(
                    style: .info,
                    title: "Moving to the Trash isn’t permanent",
                    message: "Files stay in the Finder Trash until you empty it, and can be put back from there. Photos items stay in Photos › Recently Deleted for up to 30 days. Once the Trash is emptied, CleanLocal can’t restore anything. Clearing this history doesn’t affect any files."
                )
            }
            .padding(.horizontal, Spacing.xxl)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.m)

            if deletion.history.isEmpty {
                EmptyStateView(symbol: "clock.arrow.circlepath", title: "No Activity Yet",
                               message: "Every item CleanLocal moves to the Trash is recorded here, including failures.")
            } else {
                Table(records, sortOrder: $sortOrder) {
                    TableColumn("Status") { record in
                        // Color on the icon only: brand tints are too light for small text.
                        Label {
                            Text(record.status.title)
                        } icon: {
                            Image(systemName: symbol(for: record.status)).foregroundStyle(color(for: record.status))
                        }
                    }
                    .width(min: 130, ideal: 170)
                    TableColumn("Name", value: \.filename) { Text($0.filename).lineLimit(1).truncationMode(.middle) }
                        .width(min: 140, ideal: 220)
                    TableColumn("Category") { Text($0.category ?? ($0.wasPhotosAsset ? "Photos" : "Media")).foregroundStyle(.secondary) }
                        .width(min: 90, ideal: 140)
                    TableColumn("Original Location", value: \.originalLocation) { record in
                        Text(UserDirectories.abbreviate(path: (record.originalLocation as NSString).deletingLastPathComponent))
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            .help(record.originalLocation)
                    }
                    .width(min: 140, ideal: 240)
                    TableColumn("Size", value: \.size) { Text($0.size.formattedBytes).monospacedDigit() }
                        .width(min: 70, ideal: 80)
                    TableColumn("Date", value: \.timestamp) { Text($0.timestamp.mediumDisplay).foregroundStyle(.secondary) }
                        .width(min: 120, ideal: 150)
                    TableColumn("Details") { record in
                        Text(record.errorDescription ?? detail(for: record))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .help(record.errorDescription ?? "")
                    }
                    .width(min: 160, ideal: 280)
                }
            }
        }
        .background(Palette.pageBackground)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search history")
        .confirmationDialog("Clear deletion history?", isPresented: $showsClearConfirmation) {
            Button("Clear History", role: .destructive) { deletion.clearHistory() }
        } message: {
            Text("This only removes CleanLocal’s log. Items in the Trash are not affected.")
        }
    }

    private var records: [DeletionRecord] {
        let filtered = searchText.isEmpty ? deletion.history : deletion.history.filter {
            $0.filename.localizedCaseInsensitiveContains(searchText) || $0.originalLocation.localizedCaseInsensitiveContains(searchText)
        }
        return filtered.sorted(using: sortOrder)
    }

    private var subtitle: String {
        let succeeded = deletion.history.filter { $0.status.succeeded }
        let failed = deletion.history.count - succeeded.count
        var text = "\(succeeded.count) removed · \(deletion.totalReclaimedBytes.formattedBytes)"
        if failed > 0 { text += " · \(failed) failed" }
        return text
    }

    private func detail(for record: DeletionRecord) -> String {
        switch record.status {
        case .removedFromPhotos: "Recoverable in Photos › Recently Deleted"
        case .movedToTrash: "Recoverable from the Trash until it’s emptied"
        case .deletedPermanently: record.itemCount.map { "\($0) files permanently removed" } ?? "Permanently removed"
        case .partial: "Some files were in use and left in place"
        case .failed: "Left untouched"
        }
    }

    private func symbol(for status: DeletionRecord.Status) -> String {
        switch status {
        case .movedToTrash: "trash.fill"
        case .removedFromPhotos: "photo.stack"
        case .failed: "exclamationmark.triangle.fill"
        case .deletedPermanently: "xmark.bin.fill"
        case .partial: "circle.lefthalf.filled"
        }
    }

    private func color(for status: DeletionRecord.Status) -> Color {
        switch status {
        case .movedToTrash, .removedFromPhotos, .deletedPermanently: Palette.grey
        case .partial: Palette.tangerine
        case .failed: Palette.flame
        }
    }
}
