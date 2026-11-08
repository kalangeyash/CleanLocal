import SwiftUI

/// Options for a ``MediaBrowserView`` screen.
struct MediaBrowserConfiguration {
    var defaultSort: MediaSort = .dateNewest
    var showsKindFilter = true
    var showsSourceFilter = true
    var groupsByMonth = false
    var emptySymbol = "photo.on.rectangle.angled"
    var emptyTitle = "No Media"
    var emptyMessage = "Nothing matches the current filters."
}

/// The reusable gallery used by All Media, Large Files, Videos, Screenshots, Old Media and more.
///
/// Callers pass a pre-filtered list plus a cheap `revision` key; filtering and sorting are
/// recomputed only when the query or revision changes, never on every render.
struct MediaBrowserView<Accessory: View>: View {
    let title: String
    let items: [MediaItem]
    let revision: AnyHashable
    var configuration = MediaBrowserConfiguration()
    @ViewBuilder var accessory: () -> Accessory

    @Environment(DeletionStore.self) private var deletion
    @Environment(\.openWindow) private var openWindow
    @AppStorage("browser.layout") private var layout: BrowserLayout = .grid
    @State private var query: MediaQuery
    @State private var visible: [MediaItem] = []
    @State private var sections: [MediaSection] = []
    @State private var selection = Set<MediaItem.ID>()

    init(
        title: String,
        items: [MediaItem],
        revision: AnyHashable,
        configuration: MediaBrowserConfiguration = MediaBrowserConfiguration(),
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.items = items
        self.revision = revision
        self.configuration = configuration
        self.accessory = accessory
        _query = State(initialValue: MediaQuery(sort: configuration.defaultSort))
    }

    private struct RecomputeKey: Hashable {
        let query: MediaQuery
        let revision: AnyHashable
        let count: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            content
        }
        .background(Palette.pageBackground)
        .overlay(alignment: .bottom) {
            if !selectedItems.isEmpty {
                SelectionActionBar(
                    count: selectedItems.count,
                    bytes: StorageAnalyticsService.totalSize(of: selectedItems),
                    canReveal: selectedItems.contains { !$0.isPhotosAsset },
                    onPreview: { selectedItems.first.map(preview) },
                    onReveal: { FinderActions.reveal(selectedItems) },
                    onDeselect: { selection.removeAll() },
                    onMoveToTrash: { deletion.requestDeletion(of: selectedItems) }
                )
                .padding(.bottom, Spacing.xl)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.cleanLocalSpring, value: selection.isEmpty)
        .searchable(text: $query.searchText, placement: .toolbar, prompt: "Search filenames")
        .toolbar { toolbarContent }
        .onChange(of: RecomputeKey(query: query, revision: revision, count: items.count), initial: true) {
            recompute()
        }
        .focusedSceneValue(\.mediaBrowserActions, commandActions)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            PageHeader(title: title, subtitle: summary) {
                HStack(spacing: Spacing.s) {
                    Button(allVisibleSelected ? "Deselect All" : "Select All") {
                        if allVisibleSelected { selection.removeAll() } else { selection = Set(visible.map(\.id)) }
                    }
                    .buttonStyle(.glass)
                    .disabled(visible.isEmpty)
                }
            }
            accessory()
            if configuration.showsKindFilter || configuration.showsSourceFilter {
                HStack(spacing: Spacing.m) {
                    if configuration.showsKindFilter {
                        ChipPicker(options: MediaKindFilter.allCases, selection: $query.kind) { $0.title }
                    }
                    Spacer()
                    if configuration.showsSourceFilter {
                        Picker("Source", selection: $query.source) {
                            ForEach(MediaSourceFilter.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.top, Spacing.xl)
        .padding(.bottom, Spacing.m)
    }

    private var summary: String {
        let total = StorageAnalyticsService.totalSize(of: visible)
        return "\(visible.count.formatted()) \(visible.count == 1 ? "item" : "items") · \(total.formattedBytes)"
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if visible.isEmpty {
            EmptyStateView(
                symbol: query.searchText.isEmpty ? configuration.emptySymbol : "magnifyingglass",
                title: query.searchText.isEmpty ? configuration.emptyTitle : "No Results",
                message: query.searchText.isEmpty ? configuration.emptyMessage : "No filenames match “\(query.searchText)”."
            )
        } else if layout == .grid {
            MediaGridView(sections: sections, selection: $selection, actions: itemActions)
        } else {
            MediaListView(items: visible, selection: $selection, actions: itemActions)
                .padding(.bottom, selection.isEmpty ? 0 : 64)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                Picker("Sort By", selection: $query.sort) {
                    ForEach(MediaSort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort")

            Picker("Layout", selection: $layout) {
                Label("Grid", systemImage: "square.grid.2x2").tag(BrowserLayout.grid)
                Label("List", systemImage: "list.bullet").tag(BrowserLayout.list)
            }
            .pickerStyle(.segmented)
            .help("Switch between grid and list")
        }
    }

    // MARK: Logic

    private var selectedItems: [MediaItem] {
        visible.filter { selection.contains($0.id) }
    }

    private var allVisibleSelected: Bool {
        !visible.isEmpty && selection.count >= visible.count && visible.allSatisfy { selection.contains($0.id) }
    }

    private func recompute() {
        visible = query.apply(to: items)
        sections = configuration.groupsByMonth && query.sort.isDateBased
            ? MediaSection.byMonth(visible)
            : [MediaSection(id: "all", title: nil, items: visible)]
        // Never keep hidden items selected: actions apply only to what the user can see.
        let visibleIDs = Set(visible.map(\.id))
        if !selection.isSubset(of: visibleIDs) { selection.formIntersection(visibleIDs) }
    }

    private func preview(_ item: MediaItem) {
        openWindow(id: MediaPreviewScene.id, value: item.id)
    }

    private var itemActions: MediaItemActions {
        MediaItemActions(
            preview: preview,
            revealInFinder: { FinderActions.reveal($0) },
            moveToTrash: { deletion.requestDeletion(of: $0) }
        )
    }

    private var commandActions: MediaBrowserCommandActions {
        let selected = selectedItems
        return MediaBrowserCommandActions(
            selectAll: { selection = Set(visible.map(\.id)) },
            deselectAll: { selection.removeAll() },
            preview: selected.first.map { item in { preview(item) } },
            revealInFinder: selected.contains { !$0.isPhotosAsset } ? { FinderActions.reveal(selected) } : nil,
            moveToTrash: selected.isEmpty ? nil : { deletion.requestDeletion(of: selected) }
        )
    }
}
