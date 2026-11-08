import SwiftUI

struct LargeFilesView: View {
    /// Threshold presets in megabytes; `nil` means a custom value.
    private static let presets: [Int?] = [10, 50, 100, 500, nil]

    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings
    @State private var preset: Int?? = .none
    @State private var customMB = 250

    var body: some View {
        MediaBrowserView(
            title: "Large Files",
            items: library.items.filter { $0.size >= thresholdBytes },
            revision: [AnyHashable(library.revision), AnyHashable(thresholdBytes)],
            configuration: MediaBrowserConfiguration(
                defaultSort: .sizeDescending,
                emptySymbol: "externaldrive",
                emptyTitle: "No Large Files",
                emptyMessage: "Nothing in your scanned media is larger than \(thresholdMB) MB."
            )
        ) {
            HStack(spacing: Spacing.m) {
                ChipPicker(options: Self.presets, selection: selectedPreset) { value in
                    value.map { "> \($0) MB" } ?? "Custom"
                }
                if selectedPreset.wrappedValue == nil {
                    TextField("MB", value: $customMB, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .accessibilityLabel("Custom minimum size in megabytes")
                    Stepper("MB", value: $customMB, in: 1...100_000, step: 25)
                        .labelsHidden()
                    Text("MB").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var selectedPreset: Binding<Int?> {
        Binding(
            get: {
                if let preset { return preset }
                return Self.presets.contains(settings.largeFileThresholdMB) ? settings.largeFileThresholdMB : nil
            },
            set: { preset = .some($0) }
        )
    }

    private var thresholdMB: Int {
        selectedPreset.wrappedValue ?? max(1, customMB)
    }

    private var thresholdBytes: Int64 { Int64(thresholdMB) * 1_000_000 }
}
