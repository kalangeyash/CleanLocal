import SwiftUI

/// Lazily loads a downsampled thumbnail. Shows a category-tinted placeholder meanwhile.
///
/// Loading is tied to the view's lifetime with `.task(id:)`, so scrolled-away cells cancel
/// their work automatically.
struct ThumbnailView: View {
    let item: MediaItem
    var pixelSize: CGFloat = AppConstants.Thumbnails.gridPixelSize
    var contentMode: ContentMode = .fill

    @Environment(\.thumbnailService) private var service
    @State private var image: RenderedImage?

    var body: some View {
        ZStack {
            Rectangle().fill(item.category.tint.opacity(0.12))
            if let image {
                Image(decorative: image.cgImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                Image(systemName: item.category.symbolName)
                    .font(.system(size: pixelSize > 150 ? 26 : 12, weight: .medium))
                    .foregroundStyle(item.category.tint.opacity(0.65))
            }
        }
        .task(id: "\(item.id)|\(item.size)|\(Int(pixelSize))") {
            if let cached = service?.cachedThumbnail(for: item, pixelSize: pixelSize) {
                image = cached
                return
            }
            let loaded = await service?.thumbnail(for: item, pixelSize: pixelSize)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
        .accessibilityHidden(true)
    }
}
