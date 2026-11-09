import Foundation
import OSLog

/// Centralized product constants.
enum AppConstants {
    static let appName = "CleanLocal"
    static let tagline = "Your Mac. Your Storage. Your Control."
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.yourdomain.cleanlocal"

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    enum Scanning {
        /// Concurrent metadata readers. Bounded so tens of thousands of files never spawn
        /// tens of thousands of tasks.
        static let metadataConcurrency = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
        static let hashingConcurrency = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    enum Thumbnails {
        static let gridPixelSize: CGFloat = 360
        static let listPixelSize: CGFloat = 96
        static let previewPixelSize: CGFloat = 3200
        static let maxConcurrentGenerations = 6
        static let memoryCacheCostLimit = 192 * 1024 * 1024
    }

    enum Defaults {
        static let largeFileThresholdMB = 100
        static let similarityThreshold = 0.90
    }

    enum StorageKeys {
        static let appearance = "settings.appearance"
        static let enabledFormats = "settings.enabledFormats"
        static let includeHiddenFiles = "settings.includeHiddenFiles"
        static let includePhotosLibrary = "settings.includePhotosLibrary"
        static let similarityThreshold = "settings.similarityThreshold"
        static let largeFileThresholdMB = "settings.largeFileThresholdMB"
        static let oldMediaThreshold = "settings.oldMediaThreshold"
        static let analyzeDuplicatesAfterScan = "settings.analyzeDuplicatesAfterScan"
        static let deleteCachesImmediately = "settings.deleteCachesImmediately"
        static let logAgeDays = "settings.logAgeDays"
        static let crashReportAgeDays = "settings.crashReportAgeDays"
        static let installerAgeDays = "settings.installerAgeDays"
        static let allowICloudVerification = "settings.allowICloudVerification"
    }
}

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.yourdomain.cleanlocal"
    static let scanning = Logger(subsystem: subsystem, category: "scanning")
    static let deletion = Logger(subsystem: subsystem, category: "deletion")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let photos = Logger(subsystem: subsystem, category: "photos")
    static let access = Logger(subsystem: subsystem, category: "access")
}
