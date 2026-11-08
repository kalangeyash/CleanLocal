import AppKit
import SwiftUI

/// Item-level actions shared by grid, list and context menus.
struct MediaItemActions {
    var preview: (MediaItem) -> Void
    var revealInFinder: ([MediaItem]) -> Void
    var moveToTrash: ([MediaItem]) -> Void
}

/// Adaptive, lazily rendered thumbnail grid with keyboard navigation.
///
/// * Click selects, ⌘-click toggles, ⇧-click extends; double-click or Space previews.
/// * Arrow keys move focus; ⇧-arrow extends the selection; ⌘A selects all.
struct MediaGridView: View {
    let sections: [MediaSection]
    @Binding var selection: Set<MediaItem.ID>
    let actions: MediaItemActions

    @State private var focusedID: MediaItem.ID?
    @State private var anchorID: MediaItem.ID?
    @State private var columnCount = 4
    @FocusState private var hasKeyboardFocus: Bool

    private static let minimumCellWidth: CGFloat = 156
    private static let spacing: CGFloat = 14
    private static let padding: CGFloat = 24
    private let columns = [GridItem(.adaptive(minimum: minimumCellWidth, maximum: 240), spacing: spacing, alignment: .top)]

    private var orderedItems: [MediaItem] { sections.flatMap(\.items) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: Self.spacing, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.items) { item in
                                cell(for: item)
                                    .id(item.id)
                            }
                        } header: {
                            if let title = section.title {
                                sectionHeader(title: title, items: section.items)
                            }
                        }
                    }
                }
                .padding(Self.padding)
                .padding(.bottom, 72) // room for the floating selection bar
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                let usable = width - Self.padding * 2 + Self.spacing
                columnCount = max(1, Int(usable / (Self.minimumCellWidth + Self.spacing)))
            }
            .focusable()
            .focused($hasKeyboardFocus)
            .focusEffectDisabled()
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                handleArrow(press, proxy: proxy)
            }
            .onKeyPress(.space) { activateFocused() }
            .onKeyPress(.return) { activateFocused() }
            .onKeyPress(.escape) {
                guard !selection.isEmpty else { return .ignored }
                selection.removeAll()
                return .handled
            }
            .onKeyPress(characters: CharacterSet(charactersIn: "aA"), phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                selection = Set(orderedItems.map(\.id))
                return .handled
            }
        }
    }

    private func cell(for item: MediaItem) -> some View {
        MediaGridCell(
            item: item,
            isSelected: selection.contains(item.id),
            isFocused: hasKeyboardFocus && focusedID == item.id,
            onToggleSelection: { toggle(item) }
        )
        .onTapGesture { click(item) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { actions.preview(item) })
        .contextMenu { contextMenu(for: item) }
    }

    private func sectionHeader(title: String, items: [MediaItem]) -> some View {
        HStack {
            Text(title).font(.headline)
            Text("\(items.count) · \(StorageAnalyticsService.totalSize(of: items).formattedBytes)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button(items.allSatisfy { selection.contains($0.id) } ? "Deselect Month" : "Select Month") {
                let ids = Set(items.map(\.id))
                if ids.isSubset(of: selection) { selection.subtract(ids) } else { selection.formUnion(ids) }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        .padding(.vertical, Spacing.s)
        .padding(.horizontal, Spacing.xs)
        .background(.bar)
    }

    @ViewBuilder
    private func contextMenu(for item: MediaItem) -> some View {
        let targets = selection.contains(item.id) ? orderedItems.filter { selection.contains($0.id) } : [item]
        Button("Quick Look", systemImage: "eye") { actions.preview(item) }
        if !item.isPhotosAsset {
            Button("Reveal in Finder", systemImage: "folder") { actions.revealInFinder(targets) }
        }
        Divider()
        Button(selection.contains(item.id) ? "Deselect" : "Select", systemImage: "checkmark.circle") { toggle(item) }
        Divider()
        Button(targets.count > 1 ? "Move \(targets.count) Items to Trash…" : "Move to Trash…", systemImage: "trash", role: .destructive) {
            actions.moveToTrash(targets)
        }
    }

    // MARK: Interaction

    private func click(_ item: MediaItem) {
        hasKeyboardFocus = true
        focusedID = item.id
        var modifiers: SelectionLogic.Modifiers = []
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        let result = SelectionLogic.click(item.id, orderedIDs: orderedItems.map(\.id), selection: selection, anchor: anchorID, modifiers: modifiers)
        selection = result.selection
        anchorID = result.anchor
    }

    private func toggle(_ item: MediaItem) {
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        anchorID = item.id
        focusedID = item.id
    }

    private func handleArrow(_ press: KeyPress, proxy: ScrollViewProxy) -> KeyPress.Result {
        let items = orderedItems
        let direction: SelectionLogic.Direction = switch press.key {
        case .leftArrow: .left
        case .rightArrow: .right
        case .upArrow: .up
        default: .down
        }
        let current = focusedID.flatMap { id in items.firstIndex { $0.id == id } }
        guard let next = SelectionLogic.move(from: current, count: items.count, columns: columnCount, direction: direction) else {
            return .ignored
        }
        let target = items[next]
        focusedID = target.id
        if press.modifiers.contains(.shift) {
            let result = SelectionLogic.click(target.id, orderedIDs: items.map(\.id), selection: selection,
                                              anchor: anchorID ?? current.map { items[$0].id }, modifiers: .shift)
            selection = result.selection
            anchorID = result.anchor
        }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(target.id) }
        return .handled
    }

    private func activateFocused() -> KeyPress.Result {
        guard let focusedID, let item = orderedItems.first(where: { $0.id == focusedID }) else { return .ignored }
        actions.preview(item)
        return .handled
    }
}

/// Sortable-by-menu table layout with native selection and keyboard behavior.
struct MediaListView: View {
    let items: [MediaItem]
    @Binding var selection: Set<MediaItem.ID>
    let actions: MediaItemActions

    var body: some View {
        Table(items, selection: $selection) {
            TableColumn("Name") { item in
                HStack(spacing: Spacing.s) {
                    ThumbnailView(item: item, pixelSize: AppConstants.Thumbnails.listPixelSize)
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text(item.filename).lineLimit(1).truncationMode(.middle)
                    if item.isPhotosAsset { Badge(text: "Photos", tint: Palette.grey) }
                    if item.isScreenshot { Badge(text: "Screenshot", tint: MediaCategory.screenshots.tint) }
                }
            }
            .width(min: 220, ideal: 320)
            TableColumn("Kind") { Text($0.typeDescription).foregroundStyle(.secondary) }
                .width(min: 50, ideal: 70)
            TableColumn("Size") { Text($0.size.formattedBytes).monospacedDigit() }
                .width(min: 70, ideal: 80)
            TableColumn("Dimensions") { Text($0.dimensionsDescription ?? "—").foregroundStyle(.secondary).monospacedDigit() }
                .width(min: 80, ideal: 100)
            TableColumn("Duration") { Text($0.duration?.formattedDuration ?? "—").foregroundStyle(.secondary).monospacedDigit() }
                .width(min: 55, ideal: 65)
            TableColumn("Date") { Text($0.effectiveDate.shortDisplay).foregroundStyle(.secondary) }
                .width(min: 90, ideal: 110)
            TableColumn("Location") { Text($0.locationDescription).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
                .width(min: 120, ideal: 240)
        }
        .contextMenu(forSelectionType: MediaItem.ID.self) { ids in
            let targets = items.filter { ids.contains($0.id) }
            if let first = targets.first {
                Button("Quick Look", systemImage: "eye") { actions.preview(first) }
                if targets.contains(where: { !$0.isPhotosAsset }) {
                    Button("Reveal in Finder", systemImage: "folder") { actions.revealInFinder(targets) }
                }
                Divider()
                Button(targets.count > 1 ? "Move \(targets.count) Items to Trash…" : "Move to Trash…", systemImage: "trash", role: .destructive) {
                    actions.moveToTrash(targets)
                }
            }
        } primaryAction: { ids in
            if let first = items.first(where: { ids.contains($0.id) }) { actions.preview(first) }
        }
        .onKeyPress(.space) {
            guard let first = items.first(where: { selection.contains($0.id) }) else { return .ignored }
            actions.preview(first)
            return .handled
        }
    }
}

/// Floating bar summarizing the selection with bulk actions.
struct SelectionActionBar: View {
    let count: Int
    let bytes: Int64
    let canReveal: Bool
    let onPreview: (() -> Void)?
    let onReveal: () -> Void
    let onDeselect: () -> Void
    let onMoveToTrash: () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(count) selected")
                    .font(.headline)
                    .contentTransition(.numericText())
                Text("\(bytes.formattedBytes) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .frame(minWidth: 110, alignment: .leading)

            Divider().frame(height: 28)

            Button("Deselect", systemImage: "xmark", action: onDeselect)
                .buttonStyle(.glass)
                .labelStyle(.iconOnly)
                .help("Deselect All (Esc)")
            if let onPreview {
                Button("Quick Look", systemImage: "eye", action: onPreview)
                    .buttonStyle(.glass)
                    .labelStyle(.iconOnly)
                    .help("Quick Look (Space)")
            }
            if canReveal {
                Button("Reveal in Finder", systemImage: "folder", action: onReveal)
                    .buttonStyle(.glass)
                    .labelStyle(.iconOnly)
                    .help("Reveal in Finder")
            }
            Button(action: onMoveToTrash) {
                Label("Move to Trash…", systemImage: "trash")
            }
            .buttonStyle(.destructive)
            .help("Move to Trash… (⌘⌫)")
        }
        .padding(.leading, Spacing.l)
        .padding(.trailing, Spacing.s)
        .padding(.vertical, Spacing.s)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.cardStroke))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(count) items selected, \(bytes.formattedBytes)")
    }
}

/// Actions exposed to the menu bar for whichever media browser has focus.
struct MediaBrowserCommandActions {
    var selectAll: () -> Void
    var deselectAll: () -> Void
    var preview: (() -> Void)?
    var revealInFinder: (() -> Void)?
    var moveToTrash: (() -> Void)?
}

extension FocusedValues {
    @Entry var mediaBrowserActions: MediaBrowserCommandActions?
}

@MainActor
enum FinderActions {
    static func reveal(_ items: [MediaItem]) {
        let urls = items.compactMap(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
