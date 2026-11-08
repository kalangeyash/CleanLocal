# CleanLocal

**Your Mac. Your Media. Your Control.**

CleanLocal is a native macOS app that finds the photos and videos taking up space on your Mac — large files, exact duplicates, look-alike shots, old media and screenshots — and helps you safely move what you no longer need to the Trash.

Everything happens on your Mac. CleanLocal has no network access, no analytics and no automatic deletion.

---

## Features

| Area | What it does |
| --- | --- |
| **Overview** | Live scan progress, real totals (media count and size, photos, videos, duplicates, large files, potential savings), an interactive storage donut and startup-disk usage. |
| **Scanning** | Scans only folders you choose (Desktop, Downloads, Pictures, Movies, any folder or external drive) and, optionally, your Apple Photos library. Incremental, cancellable and parallel with a fixed concurrency limit. |
| **All Media / Videos / Recently Scanned** | Lazy grid or list browser with search, sort, type and source filters, Finder-style multi-select and keyboard navigation. |
| **Large Files** | > 10 / 50 / 100 / 500 MB or a custom threshold, largest first, with the selected size shown live. |
| **Duplicate Media** | Three-stage detection (size → edge fingerprint → SHA-256). Suggests which copy to keep; never auto-selects the last copy. |
| **Similar Photos** | Perceptual hashing (pHash + dHash) with an adjustable threshold. You review every group; nothing is pre-selected. |
| **Old Media** | Older than 6 months / 1 / 2 / 5 years or a custom date range, for review only. |
| **Screenshots** | Detected from macOS screenshot metadata, standard screenshot names and Screenshots folders; grouped by month. |
| **Photos Library** | PhotoKit integration: albums, thumbnails, metadata, duplicates, large videos, screenshots, and deletion through Photos' own confirmation. |
| **Preview** | Separate window with a downsampled image or video player plus a metadata inspector. |
| **Safe deletion** | Confirmation sheet listing every file, then `FileManager.trashItem` (never permanent deletion), with a per-file result. |
| **Trash & History** | Log of every removal, including failures and their reasons. |
| **Storage** | Disk capacity per volume, media by category and location, largest media folders, and definitions of each figure. |
| **Settings** | Theme, locations, file types, detection thresholds, cache and index management, privacy information. |

### Supported formats

- **Images:** JPEG, HEIC/HEIF, PNG, GIF, TIFF, BMP, WebP, and RAW (DNG, CR2, CR3, NEF, ARW, ORF, RW2, RAF and more, wherever ImageIO can read them).
- **Videos:** MP4, MOV, M4V, AVI, MKV, plus 3GP, MTS/M2TS, MPEG, WMV, WebM, FLV and OGV.

Files AVFoundation or ImageIO can't decode are still indexed with their size and dates.

---

## Requirements

- macOS 15.0 or later (Apple silicon or Intel)
- Xcode 16 or later to build (developed with Xcode 27.2 and the macOS 27.2 SDK)
- No third-party dependencies

## Build and run

### Xcode

1. Open `CleanLocal.xcodeproj`.
2. Select the **CleanLocal** scheme and **My Mac**.
3. Press **⌘R**.

The project signs with **Sign to Run Locally** by default, which works out of the box on your own Mac. To distribute the app, set your team under *Signing & Capabilities*, and change the bundle identifier `com.yourdomain.cleanlocal` to one in your own domain.

### Command line

```bash
Scripts/build.sh            # Debug build → build/DerivedData/Build/Products/Debug/CleanLocal.app
Scripts/build.sh Release    # Release build
Scripts/test.sh             # Run the unit and integration test suite
```

The scripts use the Xcode found at `/Applications/Xcode.app` when `xcode-select` points at the Command Line Tools. Your system setting is not changed.

## Install

1. Build the Release configuration: `Scripts/build.sh Release`.
2. Copy `build/DerivedData/Build/Products/Release/CleanLocal.app` to `/Applications`.
3. Open it. On first launch, choose the folders to scan; macOS asks you to confirm each one.

To share the app with other Macs, archive it in Xcode (*Product › Archive*), sign it with a Developer ID, and notarize it.

---

## Safety model

CleanLocal is built so that it **can't** remove anything you didn't explicitly choose:

1. Nothing is ever deleted automatically. Every removal goes through a confirmation sheet that lists each file, its location and the total size.
2. Files are **moved to the Trash** (`FileManager.trashItem`), never erased. Photos assets go to **Recently Deleted** through PhotoKit, after Photos' own system confirmation.
3. Immediately before moving a file, CleanLocal re-checks it against the live filesystem:
   - it must be inside a folder you authorized;
   - it must not be in a protected location (`/System`, `/Library`, `/Applications`, `~/Library`, and others) or inside a package (`.app`, `.photoslibrary`, `.fcpbundle`, and others);
   - it must be a regular file — symbolic links are refused, as are symlinked parent folders that point outside the authorized folder;
   - its size and modification date must still match the scan; if the file changed, you're asked to rescan;
   - it must not be locked.
4. Duplicate auto-selection always keeps at least one copy per group. If you manually select every copy, the confirmation sheet warns you.
5. Storage is only reported as reclaimed after the system confirms the move succeeded.

## Privacy

- The app is sandboxed and has **no network entitlement**. It cannot upload, sync or download anything, and it does not fetch iCloud originals.
- There is no telemetry, analytics or crash-reporting SDK.
- CleanLocal stores a metadata index, thumbnails, preferences and an activity log inside its own sandbox container. You can clear each of them in *Settings › Data & Cache*.

See [Docs/PERMISSIONS.md](Docs/PERMISSIONS.md) for every permission CleanLocal uses and why.

---

## Project structure

```
CleanLocal/
├── App/            Entry point, composition root (AppEnvironment), menu commands
├── Core/           Models, typed errors, constants, formatting, utilities
│                   (classification, screenshot detection, path policy, hashing)
├── Services/       Scanner, metadata, thumbnails, duplicates, similarity,
│                   safe deletion, storage analytics, PhotoKit, bookmarks
├── Persistence/    Versioned, atomic JSON stores in Application Support
├── Stores/         @MainActor @Observable state: library, analysis, deletion,
│                   settings, navigation
├── DesignSystem/   Palette, spacing, typography, card and button styles
├── Components/     Sidebar, media grid/list/browser, preview window,
│                   deletion sheet, charts, shared views
├── Features/       One folder per screen (Dashboard, LargeFiles, DuplicateFinder, …)
└── Resources/      Asset catalog (app icon, accent color)
CleanLocalTests/    XCTest suite (generated media in temporary directories only)
Config/             Entitlements
Scripts/            build, test and app-icon generation scripts
Docs/               Architecture and permissions documentation
```

See [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md) for design decisions, concurrency and data flow.

## Testing

`Scripts/test.sh` runs 91 XCTest cases inside the sandboxed app host:

- media classification, screenshot detection and protected-path rules
- metadata extraction (dimensions, EXIF dates, orientation) from generated images
- SHA-256 and edge fingerprints, perceptual hashing on resized or recompressed copies
- directory scanning: hidden files, packages, symlink loops, unreadable folders, overlapping roots, incremental rescans, cancellation and progress
- duplicate detection, keeper suggestions and auto-selection invariants; similarity grouping
- safe deletion: protected paths, outside-root files, symlinks, files changed since the scan, missing files, locked files, disconnected volumes, partial failures, error mapping and the Photos path
- security-scoped bookmarks, revoked access and persistence (round trip, corrupt files, schema changes)
- storage calculations, settings persistence, query, selection and pruning logic
- an end-to-end store test: add a folder → scan → find duplicates → delete → reload from disk

Tests only touch temporary directories. Deletion tests use a fake Trash that moves files into a temporary folder, so nothing ever lands in your real Trash.

---

## Known limitations

- **Photos file sizes.** PhotoKit has no public file-size API. CleanLocal reads `PHAssetResource`'s `fileSize` value only when the resource exposes it, and otherwise reports the size as unknown (0 bytes).
- **iCloud-only originals.** With *Optimize Mac Storage* turned on, some originals exist only in iCloud. Because CleanLocal never uses the network, it can't hash or preview those items, so they are skipped during duplicate detection.
- **APFS clones.** Copies made in Finder on APFS can share disk blocks. "Potentially reclaimable" uses logical file sizes, so removing a cloned copy may free less space than shown.
- **Space is freed when you empty the Trash.** Photos items free space once they're cleared from Recently Deleted. With iCloud Photos turned on, Photos deletions sync to all your devices.
- **Similar-photo grouping** compares every pair of photos. Fingerprints are cached, but grouping libraries above roughly 50,000 photos can take tens of seconds.
- **Scanning runs only while CleanLocal is open.** It runs in the background of the open app; there is no login item or daemon.
- **Disconnected drives.** Items on an unplugged drive stay in the index and show as unavailable. Removing them is refused until the drive is reconnected.

## Git workflow

- `main` always builds and passes the tests.
- Work happens on `feature/*` branches merged with `--no-ff`, and commits follow [Conventional Commits](https://www.conventionalcommits.org) (`feat:`, `fix:`, `test:`, `docs:`, `chore:`).
