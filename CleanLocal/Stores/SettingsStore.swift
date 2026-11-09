import AppKit
import Observation

enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum OldMediaThreshold: String, CaseIterable, Identifiable, Sendable {
    case sixMonths, oneYear, twoYears, fiveYears

    var id: String { rawValue }
    var title: String {
        switch self {
        case .sixMonths: "6 months"
        case .oneYear: "1 year"
        case .twoYears: "2 years"
        case .fiveYears: "5 years"
        }
    }

    func cutoff(from now: Date = .now) -> Date {
        let calendar = Calendar.current
        let date: Date? = switch self {
        case .sixMonths: calendar.date(byAdding: .month, value: -6, to: now)
        case .oneYear: calendar.date(byAdding: .year, value: -1, to: now)
        case .twoYears: calendar.date(byAdding: .year, value: -2, to: now)
        case .fiveYears: calendar.date(byAdding: .year, value: -5, to: now)
        }
        return date ?? now
    }
}

/// User preferences, persisted locally in `UserDefaults`.
@MainActor
@Observable
final class SettingsStore {
    @ObservationIgnored private let defaults: UserDefaults
    private typealias Keys = AppConstants.StorageKeys

    var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            applyAppearance()
        }
    }

    var enabledFormats: Set<MediaFormat> {
        didSet { defaults.set(enabledFormats.map(\.rawValue).sorted(), forKey: Keys.enabledFormats) }
    }

    var includeHiddenFiles: Bool {
        didSet { defaults.set(includeHiddenFiles, forKey: Keys.includeHiddenFiles) }
    }

    var includePhotosLibrary: Bool {
        didSet { defaults.set(includePhotosLibrary, forKey: Keys.includePhotosLibrary) }
    }

    /// Minimum visual similarity (0.80–0.98) for two photos to be grouped.
    var similarityThreshold: Double {
        didSet { defaults.set(similarityThreshold, forKey: Keys.similarityThreshold) }
    }

    var largeFileThresholdMB: Int {
        didSet { defaults.set(largeFileThresholdMB, forKey: Keys.largeFileThresholdMB) }
    }

    var oldMediaThreshold: OldMediaThreshold {
        didSet { defaults.set(oldMediaThreshold.rawValue, forKey: Keys.oldMediaThreshold) }
    }

    var analyzeDuplicatesAfterScan: Bool {
        didSet { defaults.set(analyzeDuplicatesAfterScan, forKey: Keys.analyzeDuplicatesAfterScan) }
    }

    /// Delete verified, rebuildable caches immediately instead of moving them to the Trash.
    /// Off by default: the Trash is always the default.
    var deleteCachesImmediately: Bool {
        didSet { defaults.set(deleteCachesImmediately, forKey: Keys.deleteCachesImmediately) }
    }

    var logAgeDays: Int {
        didSet { defaults.set(logAgeDays, forKey: Keys.logAgeDays) }
    }

    var crashReportAgeDays: Int {
        didSet { defaults.set(crashReportAgeDays, forKey: Keys.crashReportAgeDays) }
    }

    var installerAgeDays: Int {
        didSet { defaults.set(installerAgeDays, forKey: Keys.installerAgeDays) }
    }

    /// Let Photos fetch iCloud-only originals so duplicates can be verified byte-for-byte.
    var allowICloudVerification: Bool {
        didSet { defaults.set(allowICloudVerification, forKey: Keys.allowICloudVerification) }
    }

    var cleanupThresholds: CleanupThresholds {
        CleanupThresholds(logAgeDays: logAgeDays, crashReportAgeDays: crashReportAgeDays,
                          installerAgeDays: installerAgeDays, incompleteDownloadAgeDays: 1)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = AppAppearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        if let stored = defaults.stringArray(forKey: Keys.enabledFormats) {
            enabledFormats = Set(stored.compactMap(MediaFormat.init(rawValue:)))
        } else {
            enabledFormats = Set(MediaFormat.allCases)
        }
        includeHiddenFiles = defaults.bool(forKey: Keys.includeHiddenFiles)
        includePhotosLibrary = defaults.object(forKey: Keys.includePhotosLibrary) as? Bool ?? true
        let threshold = defaults.double(forKey: Keys.similarityThreshold)
        similarityThreshold = threshold == 0 ? AppConstants.Defaults.similarityThreshold : threshold
        let largeThreshold = defaults.integer(forKey: Keys.largeFileThresholdMB)
        largeFileThresholdMB = largeThreshold == 0 ? AppConstants.Defaults.largeFileThresholdMB : largeThreshold
        oldMediaThreshold = OldMediaThreshold(rawValue: defaults.string(forKey: Keys.oldMediaThreshold) ?? "") ?? .oneYear
        analyzeDuplicatesAfterScan = defaults.object(forKey: Keys.analyzeDuplicatesAfterScan) as? Bool ?? true
        deleteCachesImmediately = defaults.bool(forKey: Keys.deleteCachesImmediately)
        logAgeDays = (defaults.object(forKey: Keys.logAgeDays) as? Int) ?? 30
        crashReportAgeDays = (defaults.object(forKey: Keys.crashReportAgeDays) as? Int) ?? 30
        installerAgeDays = (defaults.object(forKey: Keys.installerAgeDays) as? Int) ?? 14
        allowICloudVerification = defaults.bool(forKey: Keys.allowICloudVerification)
    }

    var largeFileThresholdBytes: Int64 { Int64(largeFileThresholdMB) * 1_000_000 }

    var scanConfiguration: ScanConfiguration {
        ScanConfiguration(
            classifier: MediaTypeClassifier(enabledFormats: enabledFormats),
            includeHiddenFiles: includeHiddenFiles,
            policy: .standard,
            metadataConcurrency: AppConstants.Scanning.metadataConcurrency
        )
    }

    func applyAppearance() {
        let appearanceName: NSAppearance.Name? = switch appearance {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
        NSApp?.appearance = appearanceName.flatMap(NSAppearance.init(named:))
    }

    func resetToDefaults() {
        appearance = .system
        enabledFormats = Set(MediaFormat.allCases)
        includeHiddenFiles = false
        includePhotosLibrary = true
        similarityThreshold = AppConstants.Defaults.similarityThreshold
        largeFileThresholdMB = AppConstants.Defaults.largeFileThresholdMB
        oldMediaThreshold = .oneYear
        analyzeDuplicatesAfterScan = true
        deleteCachesImmediately = false
        logAgeDays = 30
        crashReportAgeDays = 30
        installerAgeDays = 14
        allowICloudVerification = false
    }
}
