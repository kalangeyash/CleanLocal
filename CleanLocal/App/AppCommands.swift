import SwiftUI

/// Menu bar commands and keyboard shortcuts.
struct AppCommands: Commands {
    let environment: AppEnvironment
    @FocusedValue(\.mediaBrowserActions) private var browserActions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Folder…") {
                environment.library.addLocations(LocationPicker.chooseFolders())
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider()

            Button("Scan Now") { environment.library.startScan() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(environment.library.isScanning)
            Button("Stop Scan") { environment.library.cancelScan() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!environment.library.isScanning)
            Button("Find Duplicates") {
                environment.analysis.analyzeDuplicates()
                environment.navigation.destination = .duplicates
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Select All Media") { browserActions?.selectAll() }
                .disabled(browserActions == nil)
            Button("Deselect All") { browserActions?.deselectAll() }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(browserActions == nil)
            Divider()
            Button("Quick Look") { browserActions?.preview?() }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(browserActions?.preview == nil)
            Button("Reveal in Finder") { browserActions?.revealInFinder?() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(browserActions?.revealInFinder == nil)
            Button("Move to Trash…") { browserActions?.moveToTrash?() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(browserActions?.moveToTrash == nil)
        }

        CommandMenu("Go") {
            ForEach(Array(SidebarDestination.shortcutOrder.enumerated()), id: \.element) { index, destination in
                Button(destination.title) { environment.navigation.destination = destination }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Divider()
            Button(SidebarDestination.photosLibrary.title) { environment.navigation.destination = .photosLibrary }
            Button(SidebarDestination.recentlyScanned.title) { environment.navigation.destination = .recentlyScanned }
            Button(SidebarDestination.history.title) { environment.navigation.destination = .history }
        }
    }
}
