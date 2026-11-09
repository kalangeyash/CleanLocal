import AppKit
import QuickLook
import QuickLookThumbnailing
import SwiftUI

/// The file's Finder icon, upgraded to a real Quick Look thumbnail when one exists
/// (images, videos, PDFs, documents).
struct FileThumbnailView: View {
    let url: URL
    var size: CGFloat = 32
    var showsThumbnail = true

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            guard showsThumbnail else { return }
            let request = QLThumbnailGenerator.Request(
                fileAt: url, size: CGSize(width: size, height: size),
                scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail
            )
            if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                image = representation.nsImage
            }
        }
        .accessibilityHidden(true)
    }
}

/// Opens the system Quick Look panel for a list of files, with arrow-key paging.
struct QuickLookModifier: ViewModifier {
    @Binding var url: URL?
    let urls: [URL]

    func body(content: Content) -> some View {
        content.quickLookPreview($url, in: urls)
    }
}

extension View {
    func quickLook(_ url: Binding<URL?>, in urls: [URL]) -> some View {
        modifier(QuickLookModifier(url: url, urls: urls))
    }
}

/// Safe / Review / Protected label.
struct SafetyPill: View {
    let level: SafetyLevel

    var body: some View {
        Label(level.shortTitle, systemImage: level.symbolName)
            .font(.caption2.weight(.bold))
            .foregroundStyle(Palette.onBrand)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(level.tint))
            .help(level.title)
            .accessibilityLabel(level.title)
    }
}

extension SafetyLevel {
    /// Safe uses the calm palette neutral, review the warm warning tone and protected the
    /// strongest flame — matching how much attention each needs.
    var tint: Color {
        switch self {
        case .safe: Palette.khaki
        case .review: Palette.tangerine
        case .protected: Palette.flame
        }
    }
}
