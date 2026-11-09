import AVKit
import SwiftUI

enum MediaPreviewScene {
    static let id = "media-preview"
}

/// Root of a preview window, opened with `openWindow(id:value:)` for a media item ID.
struct MediaPreviewWindow: View {
    let itemID: MediaItem.ID?
    @Environment(LibraryStore.self) private var library

    var body: some View {
        Group {
            if let itemID, let item = library.itemsByID[itemID] {
                MediaPreviewView(item: item)
            } else {
                EmptyStateView(
                    symbol: "checkmark.circle",
                    title: "Item No Longer in Library",
                    message: "It was moved to the Trash or removed from its folder. Close this window to continue.",
                    tint: Palette.accent
                )
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        // Hosted here (not on the content) so the result sheet survives the item's removal.
        .deletionSheetHost(context: .preview(itemID ?? ""))
    }
}

struct MediaPreviewView: View {
    let item: MediaItem

    @Environment(\.thumbnailService) private var thumbnails
    @Environment(\.photosService) private var photos
    @Environment(DeletionStore.self) private var deletion
    @State private var image: RenderedImage?
    @State private var player: AVPlayer?
    @State private var loadFailed = false

    var body: some View {
        HStack(spacing: 0) {
            canvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            MediaInspector(
                item: item,
                onReveal: { FinderActions.reveal([item]) },
                onMoveToTrash: { deletion.requestDeletion(of: [item], context: .preview(item.id)) }
            )
            .frame(width: 300)
        }
        .navigationTitle(item.filename)
        .navigationSubtitle(item.displaySize)
        .task(id: item.id) { await load() }
        .onDisappear { player?.pause() }
    }

    @ViewBuilder
    private var canvas: some View {
        ZStack {
            Palette.canvas
            if item.kind == .video {
                if let player {
                    VideoPlayer(player: player)
                } else if loadFailed {
                    unavailable
                } else {
                    ProgressView().controlSize(.large)
                }
            } else if let image {
                Image(decorative: image.cgImage, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
                    .padding(Spacing.xxl)
                    .transition(.opacity)
                    .accessibilityLabel("Preview of \(item.filename)")
            } else if loadFailed {
                unavailable
            } else {
                ThumbnailView(item: item, contentMode: .fit)
                    .padding(Spacing.xxl)
                    .overlay { ProgressView() }
            }
        }
    }

    private var unavailable: some View {
        EmptyStateView(
            symbol: "eye.slash",
            title: "Preview Unavailable",
            message: item.isPhotosAsset
                ? "The original may be stored only in iCloud. CleanLocal doesn’t download media."
                : "macOS can’t render this format. You can still reveal it in Finder.",
            tint: .secondary
        )
    }

    private func load() async {
        loadFailed = false
        image = nil
        player?.pause()
        player = nil

        if item.kind == .video {
            if item.isPhotosAsset, let identifier = item.photosLocalIdentifier {
                player = await photos?.player(forLocalIdentifier: identifier)
            } else if let url = item.url, FileManager.default.isReadableFile(atPath: url.path) {
                player = AVPlayer(url: url)
            }
            loadFailed = player == nil
        } else {
            let loaded = await thumbnails?.previewImage(for: item)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
            loadFailed = loaded == nil
        }
    }
}

/// Metadata panel beside the preview.
struct MediaInspector: View {
    let item: MediaItem
    let onReveal: () -> Void
    let onMoveToTrash: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(item.filename)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Spacing.xs) {
                        Badge(text: item.category.title, symbol: item.category.symbolName, tint: item.category.tint)
                        if item.isPhotosAsset { Badge(text: "Photos Library", tint: Palette.grey) }
                    }
                }

                section("Information") {
                    row("Kind", item.format?.displayName ?? item.kind.title)
                    row("Size", item.hasKnownSize ? "\(item.displaySize) (\(item.size.formatted()) bytes)" : "Unknown (original is in iCloud)")
                    if let reclaimable = item.reclaimableSize, item.isSharedOnDisk {
                        row("Frees if deleted", "\(reclaimable.formattedBytes) — shares space with a clone")
                    }
                    if let dimensions = item.dimensionsDescription { row("Dimensions", dimensions) }
                    if let duration = item.duration { row("Duration", duration.formattedDuration) }
                    if let captured = item.captureDate { row("Captured", captured.mediumDisplay) }
                    if let created = item.creationDate { row("Created", created.mediumDisplay) }
                    if let modified = item.modificationDate { row("Modified", modified.mediumDisplay) }
                }

                section("Location") {
                    Text(item.path.map(UserDirectories.abbreviate(path:)) ?? "Photos Library")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let hash = item.contentHash {
                    section("Fingerprint") {
                        Text("SHA-256 \(hash.prefix(16))…")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .help(hash)
                    }
                }

                VStack(spacing: Spacing.s) {
                    if !item.isPhotosAsset {
                        Button(action: onReveal) {
                            Label("Reveal in Finder", systemImage: "folder").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }
                    Button(action: onMoveToTrash) {
                        Label(item.isPhotosAsset ? "Delete from Photos…" : "Move to Trash…", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.destructive)
                }
            }
            .padding(Spacing.xl)
        }
        .background(Palette.pageBackground)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: Spacing.m)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.callout)
    }
}
