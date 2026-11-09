# CleanLocal architecture

CleanLocal uses MVVM with explicit service boundaries. SwiftUI views stay thin; business logic lives in services that can be tested independently, and observable stores sit between the two.

```
 SwiftUI views (Features/, Components/)
        │ read state, call intents
        ▼
 @MainActor @Observable stores (Stores/)
   LibraryStore · AnalysisStore · DeletionStore · SettingsStore · NavigationModel
        │ async calls, value types in and out
        ▼
 Services (Services/) — actors or Sendable structs, no UI knowledge
   MediaScannerService · MediaMetadataService · ThumbnailService
   DuplicateDetectionService · SimilarityDetectionService
   SafeDeletionService · StorageAnalyticsService · PhotosLibraryService · BookmarkManager
        │
        ▼
 Persistence (Persistence/) — JSONFileStore actors in Application Support
```

`AppEnvironment` (`App/AppEnvironment.swift`) is the composition root. It builds every service and store once and injects them into each window with `cleanLocalEnvironment(_:)`. Tests build the same graph with temporary persistence, a private `UserDefaults` suite and a test path policy.

## Cleanup pipeline

```
 CleanupRules (one per category, verified locations only)
        │ CandidateDraft (url, scope, proposed safety, reasons, owner)
        ▼
 CleanupScanner ── CleanupEligibility.measure (same sizing the executor uses)
        │          SafetyPolicyEngine.classify  → Safe / Review / Protected + reasons
        ▼
 CleanupStore (selection: Safe pre-selected, Review never) → CleanupSheet preview
        ▼
 CleanupExecutionService ── SafetyPolicyEngine.validateForRemoval (again, per file)
        │                   FileRemoving (Trash by default; immediate only for opted-in Safe caches)
        ▼
 CleanupReport (per item: removed / skipped / errors / trashed paths) → history, "Free Space Now"
```

- **Scopes.** `.item` removes the entry, `.contents` removes eligible children and keeps the folder, and `.filesOlderThan(days)` removes old files and keeps folders.
- **Ownership.** Folder names are parsed as bundle identifiers (handling `.plist`/`.savedState` suffixes and `group.`/Team-ID prefixes) and checked with LaunchServices (`AppCataloging`, injectable for tests).
- **Space.** `FileSpaceInspector` combines `lstat` (link count, inode, flags) with `getattrlist` (`ATTR_CMNEXT_PRIVATESIZE`, `ATTR_CMNEXT_CLONEID`, `ATTR_CMNEXT_EXT_FLAGS`). `DirectorySizer` and `DiskUsageScanner` never follow symlinks, never cross mount points and count hard links once.
- **Storage.** One `DiskUsageScanner` pass over the Home folder powers the Storage Analyzer, Large Files, Old Files and file duplicates. Files under 1 MB are aggregated per folder to bound memory. `StorageBreakdownService` partitions used space without double counting; whatever the sandbox can't see is reported as an explicitly inferred remainder.
- **Media.** Media deletion (`SafeDeletionService`) applies the same protection rules and validation before trashing, and records trashed paths so "Free Space Now" works for media too.

## Data model

- `MediaItem` is an immutable-by-convention `Sendable` struct. Its ID is the absolute path for files, or `photos:<localIdentifier>` for Photos assets. `MediaSource` records which deletion path applies (filesystem or PhotoKit).
- Hashes (`contentHash`, `perceptualHash`, `differenceHash`) are cached on the item. They're invalidated whenever the size or modification date changes, so rescans and re-analysis only do work for new or changed files.
- `DuplicateGroup` represents both exact (`kind: .exact`) and similar (`kind: .similar`) groups, together with the suggested keeper.

## Concurrency

The app is built in Swift 6 language mode with complete strict-concurrency checking. It builds with zero warnings.

| Component | Isolation | Notes |
| --- | --- | --- |
| Stores | `@MainActor` | The only mutable UI state. Services report progress through `@Sendable` callbacks, and stores hop back to the main actor. A scan ID guards against late progress events. |
| `MediaScannerService` | `actor` | Prevents overlapping scans. Traversal runs synchronously off the main actor; metadata reads use `concurrentMap(maxConcurrency:)` (bounded task group). |
| Hashing / similarity | `Sendable` structs | Bounded parallelism (2–4 hashers, up to 8 metadata readers). Pairwise grouping runs in a detached task. |
| `SafeDeletionService` | `actor` | Serializes removals; validation is `nonisolated` and pure. |
| `ThumbnailService` | `@unchecked Sendable` | Only immutable state plus a thread-safe `NSCache`. Generation is capped by an `AsyncSemaphore`. |
| `JSONFileStore` | `actor` | Serializes atomic writes. |

Cancellation is cooperative throughout: `Task.isCancelled` is checked between directory entries, inside hashing chunk loops and per pairwise row, and `PHAssetResourceManager` data requests are cancelled through `withTaskCancellationHandler`.

## Performance

- **No full decodes for display.** Grid thumbnails come from QuickLook or the ImageIO thumbnail path at about 360 px; previews are downsampled to 3200 px. Hashing decodes at 128 px.
- **Streaming hashes.** SHA-256 reads 1 MiB chunks inside `autoreleasepool`, so multi-gigabyte videos never sit in memory.
- **Cheap stages first.** Duplicate detection only hashes files that share an exact size, and splits candidates by a 64 KB head/tail fingerprint before computing a full hash.
- **Lazy UI.** `LazyVGrid` and `Table` only build visible rows. Thumbnail loads are tied to each cell's `.task(id:)`, so cells that scroll away cancel their work. Browsers re-filter and re-sort only when the query or the library's `revision` changes, not on every render.
- **Two-level thumbnail cache.** An in-memory cache limited to about 192 MB, plus small JPEGs on disk keyed by path, size and modification date.

## Safety layers

1. **The sandbox** limits reachable files to folders the user granted.
2. **`ProtectedPathPolicy`** blocks system locations and packages at scan time, when adding a location, and at deletion time.
3. **`SafeDeletionService.validate`** re-checks containment, symlinks, file type, the scan signature (size and modification date) and locks immediately before each move.
4. **`DuplicateSelectionPolicy`** guarantees that auto-selection always leaves the keeper. `DeletionStore` warns when a manual selection would remove every copy of a group.
5. **UI.** The destructive button is never the default action, so pressing Return can't delete. Every flow ends on a result screen that lists failures.

## Persistence

`PersistenceController` owns four versioned JSON documents in `~/Library/Containers/com.yourdomain.cleanlocal/Data/Library/Application Support/CleanLocal/`:

| File | Contents |
| --- | --- |
| `locations.json` | Scan locations and their security-scoped bookmarks |
| `media-index.json` | The media index, including cached hashes |
| `scan-history.json` | The last 50 scan sessions |
| `deletion-history.json` | The last 5,000 deletion records |

Writes are atomic. A corrupt file, or one with an incompatible schema version, is moved aside rather than deleted, and the app starts with empty state. Preferences are kept in `UserDefaults`.

## Design system

All colors come from the brand palette in `DesignSystem/Theme.swift` (`Palette`). Don't introduce other hex values; derive new tokens from these seven.

Safety colors: Safe = Khaki, Review = Tangerine, Protected = Flame (each with a symbol, so color is never the only signal).

| Token | Hex | Role |
| --- | --- | --- |
| `Palette.black` | `#000000` | Text on brand fills (`onBrand`), light-mode ink, dark-mode page |
| `Palette.grey` | `#80807E` | "Other Media", neutral info, secondary data; dark-mode surfaces are derived from it |
| `Palette.porcelain` | `#FFFFFC` | Light-mode cards, dark-mode ink, glyphs on dark overlays |
| `Palette.khaki` | `#BEB7A4` | Screenshots, "keep" / success states; light-mode page tint, fills and strokes |
| `Palette.tangerine` | `#FF7F11` | Photos, warnings, gradient start |
| `Palette.blaze` | `#FF5F09` | Accent (selection, focus, controls; also the AccentColor asset) |
| `Palette.flame` | `#FF3F00` | Videos, destructive actions, gradient end |

Rules:

- **Contrast.** Text and glyphs on any brand fill use `Palette.onBrand` (Black, 6–11 : 1). White on these oranges is only 2.5–3.5 : 1, which fails WCAG AA for body text. Orange text is reserved for large display type (`accentTextGradient`).
- **Primary vs destructive.** Primary buttons are ink pills (Black in light mode, Porcelain in dark mode). Destructive buttons are Blazing Flame. The two never share a color.
- **Categories:** Photos = Tangerine, Videos = Flame, Screenshots = Khaki, Other = Grey.
- **Surfaces:** in light mode, the page is Porcelain warmed with 16 % Khaki and cards are Porcelain. In dark mode, the page is Black and cards are Black lifted with Grey.
- **Controls:** the root view applies `.tint(Palette.accent)`, so native controls use Blaze Orange whatever the system accent color is.

## Adding a feature screen

1. Create `Features/<Name>/<Name>View.swift`.
2. Add a case to `SidebarDestination` (title, symbol, section) and route it in `DetailRouter`.
3. For a filtered media list, reuse `MediaBrowserView`. Pass the pre-filtered items and a `revision` key, and optionally an accessory view for screen-specific controls. Search, sort, grid/list layout, selection, keyboard navigation, preview and safe deletion then work automatically.
