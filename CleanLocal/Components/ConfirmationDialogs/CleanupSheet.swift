import SwiftUI

extension View {
    /// Presents the cleanup preview → progress → report sheet.
    func cleanupSheetHost() -> some View {
        modifier(CleanupSheetHost())
    }
}

private struct CleanupSheetHost: ViewModifier {
    @Environment(CleanupStore.self) private var cleanup

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { cleanup.session != nil },
            set: { if !$0 { cleanup.dismissSession() } }
        )) {
            CleanupSheet()
        }
    }
}

struct CleanupSheet: View {
    @Environment(CleanupStore.self) private var cleanup

    var body: some View {
        Group {
            if let session = cleanup.session {
                switch session.phase {
                case .confirming:
                    CleanupPreview(session: session)
                case let .cleaning(done, total):
                    VStack(spacing: Spacing.l) {
                        ProgressView(value: Double(done), total: Double(max(total, 1)))
                        Text("Cleaning \(min(done + 1, total)) of \(total)…").foregroundStyle(.secondary)
                    }
                    .padding(Spacing.xxxl)
                case let .finished(report):
                    CleanupReportView(report: report, freeSpace: session.freeSpaceResult)
                }
            }
        }
        .frame(width: 620)
        .interactiveDismissDisabled(isCleaning)
    }

    private var isCleaning: Bool {
        if case .cleaning = cleanup.session?.phase { return true }
        return false
    }
}

/// The detailed preview: per category, what, how much, how safe, and how it's removed.
private struct CleanupPreview: View {
    let session: CleanupSession
    @Environment(CleanupStore.self) private var cleanup

    private struct Line: Identifiable {
        let id: String
        let category: CleanupCategory
        let items: Int
        let files: Int
        let directories: Int
        let bytes: Int64
        let level: SafetyLevel
        let method: CleanupMethod
    }

    private var lines: [Line] {
        Dictionary(grouping: session.requests) { $0.candidate.categoryID }.compactMap { id, requests in
            guard let category = CleanupCatalog.category(id: id) else { return nil }
            return Line(
                id: id, category: category, items: requests.count,
                files: requests.reduce(0) { $0 + $1.candidate.size.fileCount },
                directories: requests.reduce(0) { $0 + $1.candidate.size.directoryCount },
                bytes: requests.reduce(0) { $0 + $1.candidate.size.logicalSize },
                level: requests.map(\.candidate.safety).max() ?? .safe,
                method: requests.contains { $0.method == .moveToTrash } ? .moveToTrash : .deletePermanently
            )
        }
        .sorted { $0.bytes > $1.bytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            HStack(alignment: .top, spacing: Spacing.l) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Palette.onBrand)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Palette.brandGradient))
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Clean \(session.totalBytes.formattedBytes)?").font(.title3.weight(.semibold))
                    Text("\(session.fileCount.formatted()) files in \(session.requests.count) items. Each item is checked again right before it’s removed.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(lines) { line in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: Spacing.s) {
                                Image(systemName: line.category.symbolName).frame(width: 18).foregroundStyle(Palette.accent)
                                Text(line.category.title).font(.callout.weight(.semibold))
                                SafetyPill(level: line.level)
                                Spacer()
                                Text(line.bytes.formattedBytes).font(.callout.monospacedDigit())
                            }
                            Text("\(line.items) items · \(line.files.formatted()) files\(line.directories > 0 ? " · \(line.directories.formatted()) folders" : "") · \(line.method.title)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Impact: " + line.category.impact).font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, Spacing.s)
                        .padding(.horizontal, Spacing.m)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 280)
            .background(RoundedRectangle(cornerRadius: Radius.medium).fill(Palette.subtleFill))

            if session.reviewCount > 0 {
                InfoBanner(style: .warning, title: "\(session.reviewCount) items need your judgment",
                           message: "They’re marked Review because they may contain data or state you want to keep. Deselect anything you’re unsure about.")
            }
            InfoBanner(style: .info, message: session.requests.allSatisfy { $0.method == .moveToTrash }
                ? "Everything moves to the Trash, so you can put it back. Space is freed when the Trash is emptied — you can do that right after cleaning."
                : "Verified caches are deleted immediately (you turned this on in Settings). Everything else moves to the Trash.")

            HStack {
                Spacer()
                Button("Cancel") { cleanup.dismissSession() }
                    .keyboardShortcut(.cancelAction)
                // Not the default action: Return must never start a cleanup.
                Button("Clean \(session.totalBytes.formattedBytes)") { Task { await cleanup.confirm() } }
                    .buttonStyle(.destructive)
            }
        }
        .padding(Spacing.xxl)
    }
}

/// What actually happened, with "Free space now" for items that went to the Trash.
private struct CleanupReportView: View {
    let report: CleanupReport
    let freeSpace: FreeSpaceResult?
    @Environment(CleanupStore.self) private var cleanup
    @Environment(AccessStore.self) private var access
    @State private var isFreeing = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            HStack(alignment: .top, spacing: Spacing.l) {
                Image(systemName: report.failures.isEmpty ? "checkmark" : "exclamationmark")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Palette.onBrand)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(report.failures.isEmpty ? Palette.success : Palette.warning))
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(report.removedFiles == 0 ? "Nothing was cleaned" : "Cleaned \(report.removedFiles.formatted()) files")
                        .font(.title3.weight(.semibold))
                    Text(summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            if let freeSpace {
                InfoBanner(style: freeSpace.failures.isEmpty ? .success : .warning,
                           title: "Freed \(freeSpace.freedBytes.formattedBytes) on disk",
                           message: freeSpace.needsTrashAccess
                               ? "macOS didn’t let CleanLocal empty these items. Grant Trash access, or empty the Trash in Finder."
                               : (freeSpace.failures.isEmpty ? "The items were permanently removed from the Trash."
                                  : "\(freeSpace.failures.count) items couldn’t be removed from the Trash."))
                if freeSpace.needsTrashAccess {
                    Button("Grant Trash Access…") { access.grantTrashAccess() }.buttonStyle(.glass)
                }
            } else if report.movedToTrashBytes > 0 {
                HStack(spacing: Spacing.m) {
                    Image(systemName: "trash").foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(report.movedToTrashBytes.formattedBytes) is in the Trash").font(.callout.weight(.semibold))
                        Text("It still uses disk space until the Trash is emptied. Emptying is permanent.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(isFreeing ? "Freeing…" : "Free Space Now") {
                        isFreeing = true
                        Task { await cleanup.freeSpaceNow(); isFreeing = false }
                    }
                    .buttonStyle(.destructive)
                    .disabled(isFreeing)
                }
                .card(padding: Spacing.m)
            }

            if !report.failures.isEmpty {
                Text("Skipped or incomplete").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        ForEach(report.failures) { result in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(result.candidate.displayName) — \(result.status.title)").font(.callout.weight(.medium))
                                Text(result.errors.first ?? "\(result.skippedFiles) files were in use or changed and were left in place.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(Spacing.m)
                }
                .frame(maxHeight: 180)
                .background(RoundedRectangle(cornerRadius: Radius.medium).fill(Palette.subtleFill))
            }

            HStack {
                Spacer()
                Button("Done") { cleanup.dismissSession() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xxl)
    }

    private var summary: String {
        var parts: [String] = []
        if report.movedToTrashBytes > 0 { parts.append("\(report.movedToTrashBytes.formattedBytes) moved to the Trash.") }
        if report.freedBytes > 0 { parts.append("\(report.freedBytes.formattedBytes) freed immediately.") }
        if !report.failures.isEmpty { parts.append("\(report.failures.count) items were skipped or only partly cleaned.") }
        return parts.isEmpty ? "No files were changed." : parts.joined(separator: " ")
    }
}
