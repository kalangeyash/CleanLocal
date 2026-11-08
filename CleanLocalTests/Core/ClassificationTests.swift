import XCTest
@testable import CleanLocal

final class MediaClassificationTests: XCTestCase {
    func testRecognizesAllRequiredFormatsCaseInsensitively() {
        let expectations: [String: MediaFormat] = [
            "jpg": .jpeg, "JPEG": .jpeg, "png": .png, "HEIC": .heic, "heif": .heic, "gif": .gif,
            "tif": .tiff, "TIFF": .tiff, "bmp": .bmp, "webp": .webp, "dng": .raw, "CR3": .raw, "nef": .raw,
            "mp4": .mp4, "MOV": .mov, "m4v": .m4v, "avi": .avi, "mkv": .mkv, "3gp": .otherVideo, "webm": .otherVideo,
        ]
        for (fileExtension, format) in expectations {
            XCTAssertEqual(MediaFormat.from(fileExtension: fileExtension), format, fileExtension)
        }
    }

    func testIgnoresNonMediaAndAmbiguousExtensions() {
        for fileExtension in ["txt", "pdf", "swift", "ts", "zip", "", "app", "photoslibrary"] {
            XCTAssertNil(MediaFormat.from(fileExtension: fileExtension), fileExtension)
        }
    }

    func testKindsAreConsistent() {
        XCTAssertTrue(MediaFormat.videoFormats.allSatisfy { $0.kind == .video })
        XCTAssertTrue(MediaFormat.imageFormats.allSatisfy { $0.kind == .image })
        XCTAssertEqual(MediaFormat.videoFormats.count + MediaFormat.imageFormats.count, MediaFormat.allCases.count)
    }

    func testClassifierHonorsDisabledFormats() {
        let classifier = MediaTypeClassifier(enabledFormats: [.jpeg, .mov])
        XCTAssertEqual(classifier.format(for: URL(fileURLWithPath: "/a/b.JPG")), .jpeg)
        XCTAssertEqual(classifier.format(for: URL(fileURLWithPath: "/a/b.mov")), .mov)
        XCTAssertNil(classifier.format(for: URL(fileURLWithPath: "/a/b.png")))
        XCTAssertNil(classifier.format(for: URL(fileURLWithPath: "/a/b.mp4")))
    }

    func testCategories() {
        XCTAssertEqual(makeItem(format: .jpeg).category, .photos)
        XCTAssertEqual(makeItem(format: .raw).category, .photos)
        XCTAssertEqual(makeItem(format: .mov).category, .videos)
        XCTAssertEqual(makeItem(format: .gif).category, .other)
        XCTAssertEqual(makeItem(format: .png, isScreenshot: true).category, .screenshots)
    }
}

final class ScreenshotDetectorTests: XCTestCase {
    private let detector = ScreenshotDetector()

    func testDetectsMacOSScreenshotFilenamesInSeveralLanguages() {
        for name in [
            "Screenshot 2024-05-01 at 10.15.22.png", "Screen Shot 2019-01-01 at 9.00.00 AM.png",
            "Bildschirmfoto 2024-01-01 um 12.00.00.png", "Capture d’écran 2024-01-01 à 12.00.00.png",
            "スクリーンショット 2024-01-01 12.00.00.png", "CleanShot 2024-01-01 at 12.00.00@2x.png",
        ] {
            XCTAssertTrue(detector.isScreenshot(filename: name, directoryPath: "/x", format: .png, exifUserComment: nil), name)
        }
    }

    func testDetectsScreenshotMetadata() {
        XCTAssertTrue(detector.isScreenshot(filename: "image.png", directoryPath: "/x", format: .png, exifUserComment: "Screenshot"))
    }

    func testDetectsScreenshotFolders() {
        XCTAssertTrue(detector.isScreenshot(filename: "a.png", directoryPath: "/Users/me/Desktop/Screenshots", format: .png, exifUserComment: nil))
    }

    func testDoesNotFlagOrdinaryImagesOrVideos() {
        XCTAssertFalse(detector.isScreenshot(filename: "IMG_0001.HEIC", directoryPath: "/Users/me/Pictures", format: .heic, exifUserComment: nil))
        XCTAssertFalse(detector.isScreenshot(filename: "receipt-with-text.png", directoryPath: "/Users/me/Documents", format: .png, exifUserComment: "Taken on iPhone"))
        XCTAssertFalse(detector.isScreenshot(filename: "my screenshot ideas.png", directoryPath: "/x", format: .png, exifUserComment: nil))
        XCTAssertFalse(detector.isScreenshot(filename: "Screenshot 2024.mov", directoryPath: "/x", format: .mov, exifUserComment: nil))
        XCTAssertFalse(detector.isScreenshot(filename: "Screenshot.png", directoryPath: "/x", format: nil, exifUserComment: nil))
    }
}

final class ProtectedPathPolicyTests: XCTestCase {
    private let policy = ProtectedPathPolicy.standard

    func testProtectsSystemAndLibraryLocations() {
        for path in ["/", "/System/Library/foo.png", "/Library/Desktop Pictures/a.heic", "/usr/share/x.png",
                     "/private/var/tmp/a.jpg", "/Applications/Photos.app", UserDirectories.realHomePath + "/Library/Caches/a.png"] {
            XCTAssertTrue(policy.isProtected(path: path), path)
        }
    }

    func testProtectsPackagesAnywhere() {
        XCTAssertTrue(policy.isProtected(path: UserDirectories.realHomePath + "/Pictures/Photos Library.photoslibrary/originals/A/1.heic"))
        XCTAssertTrue(policy.isProtected(path: "/Volumes/External/Tools/Foo.app/Contents/Resources/icon.png"))
        XCTAssertTrue(policy.isProtected(path: UserDirectories.realHomePath + "/Movies/My Movie.imovielibrary/clip.mov"))
    }

    func testAllowsUserMediaFolders() {
        for path in [UserDirectories.realHomePath + "/Pictures/Trip/IMG_1.jpg",
                     UserDirectories.realHomePath + "/Downloads/video.mp4",
                     "/Volumes/Backup/Photos/2020/a.png"] {
            XCTAssertFalse(policy.isProtected(path: path), path)
        }
    }

    func testRejectsRelativePathsAndDotDotEscapes() {
        XCTAssertTrue(policy.isProtected(path: "relative/a.png"))
        XCTAssertTrue(policy.isProtected(path: UserDirectories.realHomePath + "/Pictures/../Library/a.png"))
    }
}
