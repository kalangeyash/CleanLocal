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
tccutil reset Photos com.yourdomain.cleanlocal   # forget the Photos decision
```

To forget all folder grants, remove the locations in *Settings › Locations*. To reset everything, delete `~/Library/Containers/com.yourdomain.cleanlocal`.
