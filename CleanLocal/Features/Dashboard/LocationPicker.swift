import AppKit
import SwiftUI

/// Grants folder access the sandbox-correct way: through an open panel the user confirms.
@MainActor
enum LocationPicker {
    struct Suggestion: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let url: URL?

        static let all: [Suggestion] = [
            Suggestion(id: "pictures", title: "Pictures", symbol: "photo.fill", url: UserDirectories.pictures),
            Suggestion(id: "desktop", title: "Desktop", symbol: "menubar.dock.rectangle", url: UserDirectories.desktop),
            Suggestion(id: "downloads", title: "Downloads", symbol: "arrow.down.circle.fill", url: UserDirectories.downloads),
            Suggestion(id: "movies", title: "Movies", symbol: "film.fill", url: UserDirectories.movies),
            Suggestion(id: "other", title: "Other Folder or Drive…", symbol: "folder.badge.plus", url: nil),
        ]
    }

    /// Shows an open panel (optionally pre-navigated) and returns the confirmed folders.
    static func chooseFolders(startingAt directory: URL? = nil) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = directory == nil
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Add to CleanLocal"
        panel.message = directory.map { "Click “Add to CleanLocal” to let CleanLocal scan your \($0.lastPathComponent) folder. Access stays on this Mac." }
            ?? "Choose folders or external drives for CleanLocal to scan. CleanLocal can only read folders you choose."
        if let directory {
            panel.directoryURL = directory.deletingLastPathComponent()
            panel.nameFieldStringValue = directory.lastPathComponent
            panel.directoryURL = directory
        }
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func add(_ suggestion: Suggestion, to library: LibraryStore) {
        let urls = chooseFolders(startingAt: suggestion.url)
        library.addLocations(urls)
    }
}

/// Buttons for adding common folders.
struct LocationQuickPicks: View {
    @Environment(LibraryStore.self) private var library
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Spacing.m)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: Spacing.m) {
            ForEach(LocationPicker.Suggestion.all) { suggestion in
                let isAdded = suggestion.url.map { url in library.locations.contains { $0.path == url.path } } ?? false
                Button {
                    LocationPicker.add(suggestion, to: library)
                } label: {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: isAdded ? "checkmark.circle.fill" : suggestion.symbol)
                            .foregroundStyle(isAdded ? Palette.ink : Palette.accent)
                            .frame(width: 20)
                        Text(suggestion.title).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.m)
                    .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(Palette.subtleFill))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverLift(scale: 1.02)
                .disabled(isAdded)
                .help(isAdded ? "Already added" : "Choose \(suggestion.title)")
            }
        }
    }
}
