import SwiftUI

/// One cleanup candidate: checkbox, icon, name, safety, size and the reasons behind it.
struct CandidateRow: View {
    let candidate: CleanupCandidate
    @Binding var selection: Set<CleanupCandidate.ID>
    let onPreview: () -> Void
    @State private var isHovering = false

    private var isSelected: Bool { selection.contains(candidate.id) }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Toggle("Select \(candidate.displayName)", isOn: Binding(
                get: { isSelected },
                set: { on in if on { selection.insert(candidate.id) } else { selection.remove(candidate.id) } }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!candidate.isSelectable)
            .padding(.top, 2)

            FileThumbnailView(url: candidate.url, size: 30, showsThumbnail: !candidate.isDirectory)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Spacing.xs) {
                    Text(candidate.displayName).font(.callout.weight(.medium)).lineLimit(1)
                    SafetyPill(level: candidate.safety)
                    if let owner = candidate.owner, !owner.isInstalled, !BundleIdentifier.isApple(owner.bundleID) {
                        Badge(text: "Not installed", tint: Palette.grey)
                    }
                }
                Text(candidate.detail ?? UserDirectories.abbreviate(path: candidate.url.path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !visibleReasons.isEmpty {
                    Text(visibleReasons.joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Spacing.m)
            VStack(alignment: .trailing, spacing: 2) {
                Text(candidate.size.logicalSize.formattedBytes).font(.callout.monospacedDigit())
                Text("\(candidate.size.fileCount.formatted()) files")
                    .font(.caption).foregroundStyle(.secondary)
                if candidate.size.reclaimableSize < candidate.size.allocatedSize * 9 / 10 {
                    Text("frees \(candidate.size.reclaimableSize.formattedBytes)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .help("Shared (cloned or hard-linked) data is only freed when every copy is gone.")
                }
            }
            HStack(spacing: Spacing.xxs) {
                Button("Quick Look", systemImage: "eye", action: onPreview)
                Button("Reveal in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([candidate.url]) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .opacity(isHovering ? 1 : 0.35)
        }
        .padding(.vertical, Spacing.s)
        .padding(.horizontal, Spacing.m)
        .background(isSelected ? Palette.accent.opacity(0.07) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var visibleReasons: [String] { candidate.reasons.filter { !$0.isEmpty } }
}

/// Expandable card for one cleanup category.
struct CategorySection: View {
    let category: CleanupCategory
    let candidates: [CleanupCandidate]
    @Binding var selection: Set<CleanupCandidate.ID>
    @Binding var previewURL: URL?
    @State private var isExpanded = false
    @State private var showsDetails = false

    private var selectable: [CleanupCandidate] { candidates.filter(\.isSelectable) }
    private var selectedCount: Int { selectable.filter { selection.contains($0.id) }.count }
    private var totalBytes: Int64 { candidates.reduce(0) { $0 + $1.size.logicalSize } }
    private var level: SafetyLevel { candidates.map(\.safety).min() ?? category.defaultSafety }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider()
                if showsDetails { explanation }
                LazyVStack(spacing: 0) {
                    ForEach(candidates) { candidate in
                        CandidateRow(candidate: candidate, selection: $selection) { previewURL = candidate.url }
                        Divider().padding(.leading, 84).opacity(0.6)
                    }
                }
            }
        }
        .card(padding: 0)
        .animation(.cleanLocalSpring, value: isExpanded)
    }

    private var header: some View {
        HStack(spacing: Spacing.m) {
            Toggle("Select all \(category.title)", isOn: Binding(
                get: { !selectable.isEmpty && selectedCount == selectable.count },
                set: { on in
                    let ids = Set(selectable.map(\.id))
                    if on { selection.formUnion(ids) } else { selection.subtract(ids) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(selectable.isEmpty)

            Image(systemName: category.symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.onBrand)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(level.tint.gradient))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.xs) {
                    Text(category.title).font(.headline)
                    SafetyPill(level: level)
                }
                Text(category.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(totalBytes.formattedBytes).font(.system(.title3, design: .rounded, weight: .semibold).monospacedDigit())
                Text(selectable.isEmpty ? "\(candidates.count) items" : "\(selectedCount) of \(selectable.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                withAnimation(.cleanLocalSpring) { showsDetails.toggle(); isExpanded = true }
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("Why is this \(level.shortTitle.lowercased())?")
            .accessibilityLabel("Explain \(category.title)")
            Button {
                withAnimation(.cleanLocalSpring) { isExpanded.toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
        }
        .padding(Spacing.m)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.cleanLocalSpring) { isExpanded.toggle() } }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label { Text(category.safetyNote) } icon: { Image(systemName: "checkmark.shield").foregroundStyle(Palette.ink) }
            Label { Text("After cleaning: " + category.impact) } icon: { Image(systemName: "arrow.uturn.backward").foregroundStyle(Palette.ink) }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.subtleFill)
    }
}

/// Floating summary with the "Review & Clean" action.
struct CleanupSelectionBar: View {
    let count: Int
    let bytes: Int64
    let onReview: () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(count) selected").font(.headline).contentTransition(.numericText())
                Text("\(bytes.formattedBytes) to clean").font(.caption).foregroundStyle(.secondary).contentTransition(.numericText())
            }
            Button(action: onReview) {
                Label("Review & Clean…", systemImage: "sparkles")
            }
            .buttonStyle(.primary)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.leading, Spacing.l)
        .padding(.trailing, Spacing.s)
        .padding(.vertical, Spacing.s)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.cardStroke))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
}

/// Explains why access is needed and offers the grant.
struct AccessRequiredView: View {
    enum Kind { case home, trash }
    let kind: Kind
    @Environment(AccessStore.self) private var access

    var body: some View {
        EmptyStateView(
            symbol: kind == .home ? "lock.open.fill" : "trash.fill",
            title: kind == .home ? "Give CleanLocal Access to Your Home Folder" : "Give CleanLocal Access to the Trash",
            message: kind == .home
                ? "macOS keeps every app out of your files by default. To find caches, logs and developer files, select your Home folder in the next window. Access stays on this Mac, you can revoke it in Settings, and nothing is removed without your confirmation."
                : "macOS protects the Trash with an extra privacy rule. Select the hidden “.Trash” folder in the next window so CleanLocal can show and empty it when you ask."
        ) {
            Button(kind == .home ? "Choose Home Folder…" : "Choose Trash Folder…") {
                if kind == .home { access.grantHomeAccess() } else { access.grantTrashAccess() }
            }
            .buttonStyle(.primaryLarge)
        }
    }
}
