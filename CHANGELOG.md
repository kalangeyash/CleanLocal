# Changelog

All notable changes to CleanLocal are documented here. This project uses [Semantic Versioning](https://semver.org).

## [1.0.0] — 2026-11-09

The first public release.

### Storage cleanup
- **Smart Cleanup:** a single scan across all categories. Each finding is classified Safe, Review or Protected, with a plain-language explanation; only Safe items are pre-selected.
- **Cleanup modules:** System Junk, Application Cache, Temporary Files, Browser Cleanup (cache folders only), Developer Cleanup (Xcode, npm, pnpm, Yarn, Gradle, Maven, CocoaPods, SwiftPM, pip, Go, Homebrew, Playwright, `node_modules`, build outputs, virtualenvs) and Application Leftovers.
- **Storage Analyzer:** drill-down disk map with a breakdown of "Other data".
- **Large Files** and **Old Files** across every file type.
- **Trash Manager**, plus **Free Space Now** after any cleanup.
- **Maintenance:** read-only Mac, battery, disk and login-item information.

### Media
- Media scanner with an incremental index, gallery, previews, videos, screenshots, large and old media.
- Exact duplicates (SHA-256), similar photos (pHash and dHash) and duplicate files of any type.
- Apple Photos integration through PhotoKit, including **probable duplicates** for iCloud-only originals.

### Safety and accuracy
- One `SafetyPolicyEngine` for every removal: hard protection, classification and re-validation immediately before each operation.
- APFS-aware space accounting: clones and hard links report what deleting them actually frees.
- Moved to the Trash by default; immediate deletion is opt-in and limited to Safe caches.
- Fully sandboxed: no network access, telemetry, Full Disk Access or helper tools.

### Known limitations
- The build is ad-hoc signed and **not notarized**, so you need to approve the first launch in macOS.
- Cleanup features need you to grant your Home folder (and optionally the Trash) once.
