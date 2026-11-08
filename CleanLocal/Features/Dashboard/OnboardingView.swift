import SwiftUI

/// First-run experience shown until at least one source is configured.
struct OnboardingView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xxl) {
                VStack(spacing: Spacing.l) {
                    BrandMark(size: 84)
                    VStack(spacing: Spacing.s) {
                        Text("Welcome to CleanLocal")
                            .font(.heroTitle)
                        Text(AppConstants.tagline)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(Palette.brandGradient)
                        Text("Find large, duplicate and forgotten photos and videos, then decide what goes. Nothing leaves your Mac, and nothing is removed without your say-so.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 520)
                    }
                }
                .padding(.top, Spacing.xxxl)

                HStack(spacing: Spacing.m) {
                    featurePill("lock.shield.fill", "100% on-device", Palette.brandTeal)
                    featurePill("hand.raised.fill", "Nothing deleted automatically", Palette.brandViolet)
                    featurePill("bolt.fill", "Fast, incremental scans", Palette.warning)
                }

                VStack(alignment: .leading, spacing: Spacing.l) {
                    Text("Choose what CleanLocal may scan")
                        .font(.cardTitle)
                    Text("macOS will ask you to confirm each folder. You can change this any time in Settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    LocationQuickPicks()
                    Divider()
                    PhotosConnectRow()
                }
                .frame(maxWidth: 640)
                .card(padding: Spacing.xl)
            }
            .padding(Spacing.xxl)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.pageBackground)
    }

    private func featurePill(_ symbol: String, _ title: String, _ tint: Color) -> some View {
        Label(title, systemImage: symbol)
            .font(.callout.weight(.medium))
            .labelStyle(TintedIconLabelStyle(tint: tint))
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .background(Capsule().fill(Palette.cardBackground))
            .overlay(Capsule().strokeBorder(Palette.cardStroke))
    }
}

private struct TintedIconLabelStyle: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Spacing.xs) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

/// Connect / status row for the Apple Photos library.
struct PhotosConnectRow: View {
    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: "photo.stack.fill")
                .font(.title2)
                .foregroundStyle(Palette.brandGradient)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Photos Library").font(.headline)
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch library.photosAuthorization {
            case .notDetermined:
                Button("Connect…") { Task { await library.requestPhotosAccess() } }
                    .buttonStyle(.primary)
            case .authorized, .limited:
                @Bindable var settings = settings
                Toggle("Include in scans", isOn: $settings.includePhotosLibrary)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("Include the Photos library in scans")
            case .denied, .restricted:
                Button("Open Privacy Settings") { PhotosPrivacy.openSystemSettings() }
                    .buttonStyle(.glass)
            }
        }
    }

    private var statusText: String {
        switch library.photosAuthorization {
        case .notDetermined: "Analyze your Photos library through Apple’s PhotoKit. macOS will ask for permission."
        case .authorized: settings.includePhotosLibrary ? "Connected and included in scans." : "Connected, but not included in scans."
        case .limited: "Connected with limited access to selected photos."
        case .denied: "Access was denied. You can allow it in System Settings › Privacy & Security › Photos."
        case .restricted: "Access to Photos is restricted on this Mac."
        }
    }
}

@MainActor
enum PhotosPrivacy {
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
            NSWorkspace.shared.open(url)
        }
    }
}
