import SwiftUI

extension View {
    /// Presents the deletion confirmation/result sheet for flows started in `context`.
    func deletionSheetHost(context: DeletionContext) -> some View {
        modifier(DeletionSheetHost(context: context))
    }
}

private struct DeletionSheetHost: ViewModifier {
    let context: DeletionContext
    @Environment(DeletionStore.self) private var deletion

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { deletion.session?.context == context },
            set: { if !$0 { deletion.dismiss() } }
        )) {
            DeletionSheet()
        }
    }
}

/// Confirm → progress → result, all in one sheet so the user always sees the outcome.
struct DeletionSheet: View {
    @Environment(DeletionStore.self) private var deletion

    var body: some View {
        Group {
            if let session = deletion.session {
                switch session.phase {
                case .confirming:
                    DeletionConfirmationView(session: session, isDeleting: false)
                case .deleting:
                    DeletionConfirmationView(session: session, isDeleting: true)
                case let .finished(report):
                    DeletionResultView(report: report)
                }
            }
        }
        .frame(width: 540)
        .interactiveDismissDisabled(isDeleting)
    }

    private var isDeleting: Bool {
        if case .deleting = deletion.session?.phase { return true }
        return false
    }
}

private struct DeletionConfirmationView: View {
    let session: DeletionSession
    let isDeleting: Bool
    @Environment(DeletionStore.self) private var deletion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            HStack(alignment: .top, spacing: Spacing.l) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Palette.onBrand)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Palette.destructive))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(title).font(.title3.weight(.semibold))
                    Text("\(session.totalBytes.formattedBytes) in total. You can restore files from the Trash until you empty it.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if session.fullySelectedGroupCount > 0 {
                InfoBanner(
                    style: .warning,
                    title: "Every copy selected",
                    message: "In \(session.fullySelectedGroupCount) duplicate \(session.fullySelectedGroupCount == 1 ? "group" : "groups") you selected all copies. No copy will remain outside the Trash."
                )
            }
            if session.photosItemCount > 0 {
                InfoBanner(
                    style: .info,
                    title: "\(session.photosItemCount) \(session.photosItemCount == 1 ? "item is" : "items are") in your Photos library",
                    message: "Photos will ask you to confirm. Deleted items move to Photos › Recently Deleted and stay there for up to 30 days unless you remove them sooner. If you use iCloud Photos, they’re deleted on all your devices."
                )
            }

            fileList

            HStack {
                if isDeleting {
                    ProgressView().controlSize(.small)
                    Text("Moving items…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { deletion.dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isDeleting)
                // Intentionally not the default action: Return must never delete.
                Button(session.fileItemCount > 0 ? "Move to Trash" : "Delete from Photos") {
                    Task { await deletion.confirm() }
                }
                .buttonStyle(.destructive)
                .disabled(isDeleting)
            }
        }
        .padding(Spacing.xxl)
    }

    private var title: String {
        let count = session.items.count
        let noun = count == 1 ? "item" : "items"
        if session.photosItemCount == count { return "Delete \(count) \(noun) from Photos?" }
        return "Move \(count) \(noun) to the Trash?"
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(session.items) { item in
                    HStack(spacing: Spacing.m) {
                        ThumbnailView(item: item, pixelSize: AppConstants.Thumbnails.listPixelSize)
                            .frame(width: 34, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.filename).lineLimit(1).truncationMode(.middle)
                            Text(item.locationDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer()
                        Text(item.displaySize)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, Spacing.xs)
                    .padding(.horizontal, Spacing.m)
                    Divider().padding(.leading, 58)
                }
            }
        }
        .frame(maxHeight: 240)
        .background(RoundedRectangle(cornerRadius: Radius.medium).fill(Palette.subtleFill))
        .clipShape(RoundedRectangle(cornerRadius: Radius.medium))
    }
}

private struct DeletionResultView: View {
    let report: DeletionReport
    @Environment(DeletionStore.self) private var deletion
    @Environment(TrashStore.self) private var trash
    @Environment(AccessStore.self) private var access
    @State private var freeResult: FreeSpaceResult?
    @State private var isFreeing = false

    private var trashedPaths: [String] { report.successes.compactMap(\.trashedPath) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            HStack(alignment: .top, spacing: Spacing.l) {
                Image(systemName: report.failures.isEmpty ? "checkmark" : "exclamationmark")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Palette.onBrand)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(report.failures.isEmpty ? Palette.success : Palette.warning))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(headline).font(.title3.weight(.semibold))
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let freeResult {
                InfoBanner(style: freeResult.failures.isEmpty ? .success : .warning,
                           title: "Freed \(freeResult.freedBytes.formattedBytes) on disk",
                           message: freeResult.needsTrashAccess
                               ? "macOS didn’t let CleanLocal empty these items. Grant Trash access, or empty the Trash in Finder."
                               : (freeResult.failures.isEmpty ? "The items were permanently removed from the Trash." : freeResult.failures.prefix(2).joined(separator: "\n")))
                if freeResult.needsTrashAccess {
                    Button("Grant Trash Access…") { access.grantTrashAccess() }.buttonStyle(.glass)
                }
            } else if !trashedPaths.isEmpty {
                HStack(spacing: Spacing.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Free the space now?").font(.callout.weight(.semibold))
                        Text("Permanently removes just these items from the Trash. This can’t be undone.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(isFreeing ? "Freeing…" : "Free Space Now") {
                        isFreeing = true
                        Task {
                            freeResult = await trash.deleteTrashedItems(trashedPaths)
                            isFreeing = false
                        }
                    }
                    .buttonStyle(.destructive)
                    .disabled(isFreeing)
                }
                .card(padding: Spacing.m)
            }

            if !report.failures.isEmpty {
                Text("Not removed").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        ForEach(report.failures) { record in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.filename).font(.callout.weight(.medium))
                                Text(record.errorDescription ?? "Unknown error")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(Spacing.m)
                }
                .frame(maxHeight: 200)
                .background(RoundedRectangle(cornerRadius: Radius.medium).fill(Palette.subtleFill))
            }

            HStack {
                Spacer()
                Button("Done") { deletion.dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xxl)
    }

    private var headline: String {
        let moved = report.successes.count
        if moved == 0 { return "Nothing was removed" }
        return "Removed \(moved) \(moved == 1 ? "item" : "items")"
    }

    private var detail: String {
        var parts: [String] = []
        let trashed = report.successes.filter { $0.status == .movedToTrash }
        let photos = report.successes.filter { $0.status == .removedFromPhotos }
        if !trashed.isEmpty {
            let bytes = trashed.reduce(Int64(0)) { $0 + $1.size }
            parts.append("\(bytes.formattedBytes) moved to the Trash. Empty the Trash in Finder to free the space.")
        }
        if !photos.isEmpty {
            parts.append("\(photos.count) Photos \(photos.count == 1 ? "item" : "items") moved to Recently Deleted.")
        }
        if !report.failures.isEmpty {
            parts.append("\(report.failures.count) \(report.failures.count == 1 ? "item was" : "items were") left untouched.")
        }
        return parts.joined(separator: " ")
    }
}
