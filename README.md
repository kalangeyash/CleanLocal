# CleanLocal

**Your Mac. Your Storage. Your Control.**

CleanLocal is a native macOS storage cleaner and maintenance app. It shows what is using your disk, finds caches, logs, developer leftovers, duplicates and forgotten media, and removes only what you approve. It's fully sandboxed and works entirely on your Mac. It has no network access, no analytics and no automatic deletion.

> **Guiding rule:** aggressive in *discovering* wasted space, conservative in deciding what's *safe* to remove, transparent about every action.

---

## Modules

| Group | Module | What it does |
| --- | --- | --- |
| Overview | **Overview** | Disk usage with a clickable breakdown of "Other data", cleanup potential, media stats and recommended actions. |
| | **Smart Cleanup** | One scan across every category. Each finding is classified **Safe**, **Review** or **Protected**, with an explanation. Only Safe items are pre-selected. |
| Cleanup | **System Junk** | Old logs, crash and diagnostic reports, saved window state. |
| | **Application Cache** | `~/Library/Caches`, per app. Only contents not changed in 15 minutes are removed; folders are kept and running apps are skipped. |
| | **Temporary Files** | Stale incomplete downloads, app tmp folders, old installers and archives (Review). |
| | **Browser Cleanup** | Cache folders only for Safari, Chrome, Edge, Brave and Firefox. Cookies, sign-ins, history, bookmarks, extensions and tabs are never touched. |
| | **Developer Cleanup** | DerivedData, Archives, Device Support, simulator caches, npm/Yarn/pnpm/Gradle/Maven/CocoaPods/SwiftPM/pip/Go/Homebrew/Playwright caches, plus `node_modules`, build outputs and virtualenvs in the project folders you choose. Docker data is reported only. |
| | **Application Leftovers** | Data left by apps that are no longer installed (checked through LaunchServices). Shared group containers are protected. |
| Files & Media | **Large Files** | Every file type, with 10 MB to 1 GB+ or custom thresholds, by kind; shows logical size, size on disk and what removal actually frees. |
| | **Duplicate Finder** | Photos & videos (SHA-256, plus iCloud "probable" matches), and any file type, with clone awareness. |
| | **Media Cleaner** | Gallery, videos, screenshots, similar photos (pHash/dHash), large and old media, Photos library (PhotoKit). |
| | **Old Files** | Files you haven't changed in years, for review. |
| Storage | **Storage Analyzer** | DaisyDisk-style drill-down with a ring chart, plus a breakdown of used space by area. |
| | **Trash Manager** | See what's in the Trash (including external drives) and empty all or part of it, after confirmation. |
| | **Maintenance** | Read-only Mac, battery, disk, storage and login-item information, plus an access overview. Links to Disk Utility and System Settings. |
| Activity | **Cleanup History** | Every removal with its category, size, status and any errors. |

Quick Look previews (Space or the eye button) are available wherever files are listed.

## Safety model

All removals go through one **`SafetyPolicyEngine`** and one execution service. There is no other code path that deletes files.

1. **Classification at scan time.** Every candidate is Safe, Review or Protected, with reasons based on verified locations, app ownership (LaunchServices), running apps, recent changes and file metadata. Filenames alone never decide.
2. **Hard protection.** System locations, `/Applications`, keychains, cookies, Mail, Messages, iCloud Drive, credentials (`.ssh`, `.aws`, `.p12`, provisioning profiles…), app databases outside cache folders, app bundles, browser profiles, Docker data, the Trash, and top-level home folders. These can't be selected through any screen or service, and there's no override.
3. **Re-validation right before removal.** The file must still exist and be the same file (same inode). It must be inside the granted folder, with no symlink escape and no crossing onto another mount point. It must not be locked, and the owning app must not be running.
4. **Scoped removal.** Folder *contents* are removed (never the folder itself), and logs are removed by age. Nothing is ever deleted with a recursive wipe.
5. **The Trash is the default.** Immediate deletion is opt-in and limited to Safe, rebuildable caches. Partial failures are reported per item, and nothing claims space was freed unless the system confirmed it.

## Accurate space accounting

- **APFS clones and hard links.** CleanLocal reads each file's APFS *private size* and clone ID with `getattrlist(2)`, and its link count. Removing a clone or a hard-linked file frees little or nothing, and CleanLocal shows that ("frees …") instead of the file's nominal size. Duplicate groups made of clones are marked.
- **Logical vs on-disk size.** Both are shown. Disk analysis counts hard-linked files once.
- **"Other data" explained.** The Storage Analyzer splits used space into Photos libraries, Downloads, app data, projects, Xcode, developer caches, app caches, applications, macOS and *System Data & Other*. The last area is what the sandbox can't see (other users, swap, `/opt`, snapshots, purgeable space) and is labelled as inferred.
- **Freeing space now.** After any cleanup you can permanently remove just the items CleanLocal moved to the Trash, or manage the whole Trash in Trash Manager.

## Photos library

- PhotoKit only; the `.photoslibrary` package is never touched directly. Deletion uses `PHPhotoLibrary.performChanges` with Photos' own confirmation, and items go to Recently Deleted.
- **Sizes.** Read from asset metadata when available. Otherwise they're measured with the public `PHAssetResourceManager` API (resources are streamed and counted, never stored). Assets whose size truly can't be determined are labelled "Unknown size", never "0 KB".
- **iCloud-only originals.** CleanLocal matches them as **Probable duplicates** using dimensions, capture time, duration and the appearance of locally cached thumbnails. These are never auto-selected or counted as savings. An opt-in setting lets *Photos* fetch the originals for byte-for-byte verification.

---

## Requirements

- macOS 15.0 or later
- Xcode 16 or later (developed with Xcode 27.2 and the macOS 27.2 SDK)
- No third-party dependencies

## Build, test and install

```bash
Scripts/build.sh            # Debug  → build/DerivedData/Build/Products/Debug/CleanLocal.app
Scripts/build.sh Release    # Release
Scripts/test.sh             # 118 XCTest cases (temporary directories only)
```

You can also open `CleanLocal.xcodeproj` in Xcode, choose the **CleanLocal** scheme and press ⌘R. Key components have `#Preview` canvases with sample data (`CleanLocal/Resources/PreviewSupport.swift`).

**Install:** copy the Release `CleanLocal.app` to `/Applications`. For other Macs, set your team, replace `com.yourdomain.cleanlocal` with your own bundle identifier, then archive, sign with Developer ID and notarize.

**First run:** for media, choose your media folders and/or connect Photos. For cleanup, grant your **Home folder**, and optionally the **Trash**. See [Docs/PERMISSIONS.md](Docs/PERMISSIONS.md).

## Testing

The suite covers the safety engine (every protected class, classification and re-validation), clone and hard-link accounting, every cleanup rule against a generated fake home folder (including installed vs. uninstalled apps, running apps, recent files and unreadable folders), scoped execution, partial failures, refusal of replaced or protected items, Trash emptying limits, disk analysis, the storage breakdown, file and media duplicates (including iCloud probable matches), scanning, persistence, bookmarks and the end-to-end media flow.

Destructive tests run only in temporary directories, and use fake removers that never touch the real Trash.

## Design

The palette is Black `#000000`, Grey `#80807E`, Porcelain `#FFFFFC`, Khaki Beige `#BEB7A4`, Vivid Tangerine `#FF7F11`, Blaze Orange `#FF5F09` and Blazing Flame `#FF3F00`, applied in light and dark mode with WCAG AA text contrast. Safety colors map to the palette: Safe = Khaki, Review = Tangerine, Protected = Flame. See [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md).

## Known limitations

- **Sandbox scope.** CleanLocal sees only what you grant. Locations macOS protects even after a grant are skipped and listed with the reason, never worked around: other apps' containers may prompt, and Safari caches and Mail stay closed. `/opt/homebrew`, other users' files, swap, APFS snapshots and system caches appear only as an inferred total.
- **Package-manager commands aren't run.** A sandboxed app can't run `npm`/`gradle`/`docker` against your home folder. Caches are cleaned only where removing the folder is equivalent to the documented command, and Docker and pnpm stores are left to their own tools.
- **Photos file sizes.** The fast path reads `PHAssetResource`'s undocumented `fileSize` value, only if the object responds to it. The fallback uses public APIs only, but it reads the resource data, which is slower.
- **Login items.** macOS has no public API to list modern (SMAppService) login items, so CleanLocal lists LaunchAgents it can read and links to System Settings. Startup impact isn't estimated.
- **Similar-photo grouping** compares fingerprints pairwise. Libraries above roughly 50,000 photos can take tens of seconds.

## Git workflow

`main` always builds and passes the tests. Work happens on `feature/*` branches merged with `--no-ff`, using [Conventional Commits](https://www.conventionalcommits.org).
