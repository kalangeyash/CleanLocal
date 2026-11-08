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

## Adding a feature screen

1. Create `Features/<Name>/<Name>View.swift`.
2. Add a case to `SidebarDestination` (title, symbol, section) and route it in `DetailRouter`.
3. For a filtered media list, reuse `MediaBrowserView`. Pass the pre-filtered items and a `revision` key, and optionally an accessory view for screen-specific controls. Search, sort, grid/list layout, selection, keyboard navigation, preview and safe deletion then work automatically.
