# CleanLocal and macOS permissions

CleanLocal runs inside the **App Sandbox** with the **Hardened Runtime**. It can only reach what you explicitly grant it, and it never works around macOS privacy protections.

## Entitlements

Defined in [`Config/CleanLocal.entitlements`](../Config/CleanLocal.entitlements):

| Entitlement | Why CleanLocal needs it |
| --- | --- |
| `com.apple.security.app-sandbox` | Confines the app to its own container plus whatever you grant. |
| `com.apple.security.files.user-selected.read-write` | Read folders you pick in an open panel, and move files you confirm to the Trash. |
| `com.apple.security.files.bookmarks.app-scope` | Remember the folders you picked across launches (security-scoped bookmarks). |
| `com.apple.security.personal-information.photos-library` | Use PhotoKit, but only after you approve the system Photos prompt. |

CleanLocal deliberately does **not** request:

- **Network access** (`com.apple.security.network.client`). It can't upload, download or phone home.
- **Full Disk Access.** It never asks for it and never scans the whole disk.
- Downloads, Pictures or Movies folder entitlements. Every folder goes through the same explicit picker, so you always see what you're granting.

## Folder access

### First grant

1. You pick **Pictures**, **Desktop**, **Downloads**, **Movies** or **Other Folder or Drive…** (from onboarding, the dashboard, *Settings › Locations*, or *File › Add Folder…* ⌘O).
2. macOS shows an open panel already pointed at that folder. Clicking **Add to CleanLocal** is what grants access.
3. CleanLocal stores a **security-scoped bookmark**. If the bookmark goes stale (for example, the folder was renamed), it's refreshed automatically.

### Every launch

- Each bookmark is resolved and `startAccessingSecurityScopedResource()` is called once per location. Access is stopped when you remove the location and when the app quits (`LocationAccessManager`, `SecurityScopedAccess`).
- If a folder was deleted or moved, or its drive is unplugged, the location is marked **Unavailable**. Its items stay in the index, but nothing in it can be removed until access is restored. To grant access again, remove the location and add it back.

### What is never scanned

Even inside a folder you've granted, CleanLocal skips:

- symbolic links (never followed, so no loops or escapes);
- packages and bundles (`.app`, `.photoslibrary`, `.fcpbundle`, `.imovielibrary`, `.logicx`, …);
- protected locations: `/System`, `/Library`, `/Applications`, `/usr`, `/bin`, `/sbin`, `/private`, `/var`, `/etc`, `~/Library` and `~/.Trash`;
- hidden files, unless you turn on *Settings › General › Include hidden files*.

CleanLocal refuses to add a protected location as a scan location in the first place.

## Cleanup access (Home folder and Trash)

The cleanup modules, Storage Analyzer, Large Files, Old Files and file duplicates need access the sandbox doesn't give by default. A real-app audit on macOS 27 confirmed that, without a grant, CleanLocal can't read `~/Library/Caches`, `~/Library/Logs`, `~/.npm`, `~/Library/Developer`, `~/Downloads` or the Trash. Only `/Applications` is readable.

| Grant | How | Enables |
| --- | --- | --- |
| **Home folder** | *Choose Home Folder…* opens a panel; you select your home folder | Caches, logs, developer caches, Downloads, leftovers, Storage Analyzer |
| **Trash** | *Choose Trash Folder…* opens a panel showing hidden files; you select `.Trash` | Trash Manager, "Free Space Now" |
| **Developer folders** | *Settings › Access › Add Developer Folders…* | `node_modules`, build outputs and virtualenvs in those folders only |

Grants are stored as security-scoped bookmarks and can be revoked in *Settings › Access*. Even with the Home folder granted, macOS may still:

- show its own prompt before an app reads **Downloads**, or **other apps' data** in `~/Library/Containers` (scanning leftovers of uninstalled sandboxed apps);
- deny **Safari** caches, **Mail** and other privacy-protected stores.

CleanLocal never probes those locations at launch. They're read only during a scan you start. Anything denied is listed as "couldn't be read" and skipped. CleanLocal doesn't request Full Disk Access, administrator rights or a privileged helper, and has no way to bypass these protections.

## Running apps and system information

- CleanLocal reads the list of running apps (`NSWorkspace.runningApplications`) to skip caches of apps that are open. No permission is needed.
- Maintenance reads public, read-only facts: `sysctl` (model, chip), IOKit power sources and the `AppleSmartBattery` registry entry (charge, condition, cycles), DiskArbitration (startup disk description) and LaunchAgents folders it can read. It changes nothing.

## Photos library

- CleanLocal requests **read/write** authorization (`PHPhotoLibrary.requestAuthorization(for: .readWrite)`). Write access is needed only to move items to Recently Deleted when you ask.
- **Limited access** works: CleanLocal sees only the photos you selected.
- If you denied access, turn it on in *System Settings › Privacy & Security › Photos*. CleanLocal links you there directly.
- CleanLocal never opens the `.photoslibrary` package on disk. All reads go through PhotoKit, and network access is disabled for every PhotoKit request.
- Deleting uses `PHPhotoLibrary.performChanges` with `PHAssetChangeRequest.deleteAssets`. Photos shows its own confirmation, and items stay in **Recently Deleted** for up to 30 days. If you cancel in that dialog, nothing is deleted and the cancellation is recorded in the history.

## Trash behavior

- Files are moved with `FileManager.trashItem(at:resultingItemURL:)`. You can put them back from the Trash in Finder until you empty it.
- CleanLocal never empties the Trash and can't restore anything after you do.
- Files on some external or network volumes can't be moved to a Trash. CleanLocal reports this as a failure for that file and doesn't fall back to permanent deletion.

## Resetting permissions during development

```bash
tccutil reset Photos com.kalangeyash.cleanlocal   # forget the Photos decision
```

To forget all folder grants, remove the locations in *Settings › Locations*. To reset everything, delete `~/Library/Containers/com.kalangeyash.cleanlocal`.
