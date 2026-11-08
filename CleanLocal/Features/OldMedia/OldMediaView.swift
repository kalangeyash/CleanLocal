import SwiftUI

struct OldMediaView: View {
    enum Range: Hashable {
        case olderThan(OldMediaThreshold)
        case custom

        var title: String {
            switch self {
            case let .olderThan(threshold): "> \(threshold.title)"
            case .custom: "Custom Range"
            }
        }
    }

    private static let options: [Range] = OldMediaThreshold.allCases.map(Range.olderThan) + [.custom]

    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings
    @State private var range: Range?
    @State private var customStart = Calendar.current.date(byAdding: .year, value: -3, to: .now) ?? .now
    @State private var customEnd = Calendar.current.date(byAdding: .year, value: -1, to: .now) ?? .now

    var body: some View {
        MediaBrowserView(
            title: "Old Media",
            items: library.items.filter(matches),
            revision: [AnyHashable(library.revision), AnyHashable(selectedRange), AnyHashable(customStart), AnyHashable(customEnd)],
            configuration: MediaBrowserConfiguration(
                defaultSort: .dateOldest,
                emptySymbol: "clock.arrow.circlepath",
                emptyTitle: "No Old Media",
                emptyMessage: "Nothing in your scanned media falls in this date range."
            )
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(spacing: Spacing.m) {
                    ChipPicker(options: Self.options, selection: rangeBinding) { $0.title }
                    if selectedRange == .custom {
                        DatePicker("From", selection: $customStart, in: ...customEnd, displayedComponents: .date)
                            .fixedSize()
                        DatePicker("To", selection: $customEnd, in: customStart..., displayedComponents: .date)
                            .fixedSize()
                    }
                }
                InfoBanner(
                    style: .info,
                    message: "Old doesn’t mean unwanted. These are grouped for review only, by capture date when known, otherwise by file date."
                )
            }
        }
    }

    private var selectedRange: Range {
        range ?? .olderThan(settings.oldMediaThreshold)
    }

    private var rangeBinding: Binding<Range> {
        Binding(get: { selectedRange }, set: { range = $0 })
    }

    private func matches(_ item: MediaItem) -> Bool {
        let date = item.effectiveDate
        switch selectedRange {
        case let .olderThan(threshold):
            return date < threshold.cutoff()
        case .custom:
            let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: customEnd)) ?? customEnd
            return date >= Calendar.current.startOfDay(for: customStart) && date < end
        }
    }
}
