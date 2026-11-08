import SwiftUI

struct SidebarView: View {
    @Environment(NavigationModel.self) private var navigation
    @Environment(AnalysisStore.self) private var analysis
    @Environment(LibraryStore.self) private var library

    var body: some View {
        @Bindable var navigation = navigation
        List(selection: $navigation.destination) {
            ForEach(SidebarDestination.Section.allCases, id: \.self) { section in
                Section(section.rawValue) {
                    ForEach(SidebarDestination.destinations(in: section)) { destination in
                        Label(destination.title, systemImage: destination.symbolName)
                            .badge(badge(for: destination))
                            .tag(destination)
                    }
                }
            }
            Section {
                Label(SidebarDestination.settings.title, systemImage: SidebarDestination.settings.symbolName)
                    .tag(SidebarDestination.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { BrandHeader() }
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter() }
        .navigationSplitViewColumnWidth(min: 220, ideal: 244, max: 320)
    }

    private func badge(for destination: SidebarDestination) -> Int {
        switch destination {
        case .duplicates: analysis.redundantCopyCount
        case .similar: analysis.similarGroups.count
        default: 0
        }
    }
}

/// App logo, name and tagline.
struct BrandHeader: View {
    var body: some View {
        HStack(spacing: Spacing.m) {
            BrandMark(size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(AppConstants.appName)
                    .font(.system(.headline, design: .rounded, weight: .bold))
                Text("Your Media. Your Control.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, Spacing.s)
        .padding(.bottom, Spacing.m)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(AppConstants.appName), \(AppConstants.tagline)")
    }
}

/// The CleanLocal logo mark: a gradient squircle with a stacked-photos glyph.
struct BrandMark: View {
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(Palette.brandGradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
            }
            .shadow(color: Palette.brandViolet.opacity(0.35), radius: size * 0.18, y: size * 0.08)
            .accessibilityHidden(true)
    }
}

/// Disk summary and the scan control, pinned to the bottom of the sidebar.
struct SidebarFooter: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.storageService) private var storage
    @State private var volume: VolumeCapacity?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if let volume {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack {
                        Text(volume.name).font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(volume.availableBytes.formattedBytes) free")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    CapacityBar(volume: volume, mediaBytes: library.breakdown.totalBytes, compact: true)
                    Text("Media: \(library.breakdown.totalBytes.formattedBytes) in \(library.breakdown.totalCount.formatted()) items")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            ScanButton(fullWidth: true)
        }
        .padding(Spacing.m)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .task(id: library.revision) { volume = storage.startupVolume() }
    }
}

/// Starts a scan, or shows progress with a stop control while scanning.
struct ScanButton: View {
    var fullWidth = false
    var large = false
    @Environment(LibraryStore.self) private var library
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        if let progress = library.scanProgress {
            HStack(spacing: Spacing.s) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 0) {
                    Text(progress.phase.rawValue).font(.caption.weight(.semibold))
                    Text("\(progress.mediaFound.formatted()) found")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
                Button {
                    library.cancelScan()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.glass)
                .help("Stop Scan (⌘.)")
                .accessibilityLabel("Stop scan")
            }
            .frame(maxWidth: fullWidth ? .infinity : nil)
        } else {
            Button {
                if library.hasSources {
                    library.startScan()
                } else {
                    navigation.destination = .overview
                }
            } label: {
                Label(library.hasSources ? "Scan My Mac" : "Choose Folders", systemImage: "sparkle.magnifyingglass")
                    .frame(maxWidth: fullWidth ? .infinity : nil)
            }
            .buttonStyle(PrimaryButtonStyle(size: large ? .large : .regular))
            .help("Scan authorized folders for media (⌘R)")
        }
    }
}
