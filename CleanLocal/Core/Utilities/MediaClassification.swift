import Foundation

/// Maps files to media formats, honoring the formats enabled in Settings.
struct MediaTypeClassifier: Sendable {
    var enabledFormats: Set<MediaFormat>

    init(enabledFormats: Set<MediaFormat> = Set(MediaFormat.allCases)) {
        self.enabledFormats = enabledFormats
    }

    func format(for url: URL) -> MediaFormat? {
        format(forExtension: url.pathExtension)
    }

    func format(forExtension fileExtension: String) -> MediaFormat? {
        guard let format = MediaFormat.from(fileExtension: fileExtension),
              enabledFormats.contains(format) else { return nil }
        return format
    }
}

/// Identifies screenshots conservatively.
///
/// An image counts as a screenshot only with positive evidence: the metadata macOS
/// writes into screenshots, a well-known screenshot filename pattern, or a folder
/// explicitly named for screenshots. Images that merely contain text are *not*
/// screenshots.
struct ScreenshotDetector: Sendable {
    /// Lowercased filename prefixes used by macOS (in several languages) and popular capture tools.
    static let filenamePrefixes: [String] = [
        "screenshot", "screen shot", "bildschirmfoto", "capture d’écran", "capture d'écran",
        "schermata", "captura de pantalla", "captura de ecrã", "captura de tela", "schermafbeelding",
        "skärmavbild", "skjermbilde", "skærmbillede", "näyttökuva", "zrzut ekranu", "snímek obrazovky",
        "képernyőfotó", "снимок экрана", "знімок екрана", "ekran resmi", "スクリーンショット",
        "屏幕快照", "截屏", "螢幕截圖", "스크린샷", "cleanshot", "shottr",
    ]

    static let screenshotFormats: Set<MediaFormat> = [.png, .jpeg, .heic, .tiff]

    func isScreenshot(
        filename: String,
        directoryPath: String?,
        format: MediaFormat?,
        exifUserComment: String?
    ) -> Bool {
        guard let format, Self.screenshotFormats.contains(format) else { return false }

        if let comment = exifUserComment?.trimmingCharacters(in: .whitespacesAndNewlines),
           comment.caseInsensitiveCompare("Screenshot") == .orderedSame {
            return true
        }

        let name = filename.lowercased()
        if Self.filenamePrefixes.contains(where: { name.hasPrefix($0) }) {
            return true
        }

        if let directoryPath {
            let folder = (directoryPath as NSString).lastPathComponent.lowercased()
            if folder.contains("screenshot") || folder.contains("screen shot") {
                return true
            }
        }
        return false
    }
}
