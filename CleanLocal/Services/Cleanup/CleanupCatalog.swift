import Foundation

/// Every cleanup category CleanLocal knows, with its safety explanation.
enum CleanupCatalog {
    private static func category(
        _ id: String, _ group: CleanupGroup, _ title: String, _ symbol: String,
        summary: String, safety: String, impact: String, level: SafetyLevel,
        immediate: Bool = false, ownerClosed: Bool = false
    ) -> CleanupCategory {
        CleanupCategory(
            id: id, group: group, title: title, symbolName: symbol, summary: summary, safetyNote: safety,
            impact: impact, defaultSafety: level, allowsImmediateDeletion: immediate, requiresOwnerClosed: ownerClosed
        )
    }

    static let all: [CleanupCategory] = [
        // System junk
        category("user-logs", .systemJunk, "Application Logs", "doc.text.fill",
                 summary: "Log files apps write to ~/Library/Logs.",
                 safety: "Only log files older than your age threshold are removed. Recent logs, which help with troubleshooting, are kept, and folders stay in place.",
                 impact: "Older troubleshooting history won’t be available.", level: .safe, immediate: true),
        category("diagnostic-reports", .systemJunk, "Crash & Diagnostic Reports", "exclamationmark.triangle.fill",
                 summary: "Crash, hang and resource reports in ~/Library/Logs/DiagnosticReports.",
                 safety: "Only reports older than your threshold are listed. macOS doesn’t need them once they’ve been reviewed or sent.",
                 impact: "You won’t be able to look at those old crash details.", level: .safe, immediate: true),
        category("saved-app-state", .systemJunk, "Saved Application State", "macwindow.on.rectangle",
                 summary: "Data apps use to reopen your windows after a restart.",
                 safety: "Harmless to remove while the app is closed, but you lose the windows it would have restored.",
                 impact: "The app opens with fresh windows next time.", level: .review, ownerClosed: true),

        // Application cache
        category("app-caches", .applicationCache, "Application Caches", "shippingbox.fill",
                 summary: "Rebuildable data apps keep in ~/Library/Caches.",
                 safety: "Apps recreate caches automatically. CleanLocal removes only contents that haven’t changed in the last 15 minutes, keeps each cache folder, and skips apps that are running. Apple service caches need review.",
                 impact: "Apps may launch or load content a little slower the first time.", level: .safe, immediate: true, ownerClosed: true),

        // Temporary files
        category("incomplete-downloads", .temporaryFiles, "Incomplete Downloads", "arrow.down.circle.dotted",
                 summary: "Downloads that never finished (.crdownload, .download, .part).",
                 safety: "Listed only if unchanged for more than a day, so active downloads are never touched.",
                 impact: "Resume isn’t possible; download the file again if you need it.", level: .safe, immediate: true),
        category("app-temporary", .temporaryFiles, "App Temporary Folders", "hourglass",
                 summary: "tmp/Temp folders inside ~/Library/Caches.",
                 safety: "Temporary by design, and only contents unchanged for 15 minutes are removed. Running apps are skipped.",
                 impact: "None expected.", level: .safe, immediate: true, ownerClosed: true),

        // Installers
        category("installers", .installers, "Old Installers & Archives", "opticaldiscdrive.fill",
                 summary: "Disk images, packages and archives in Downloads.",
                 safety: "Never selected automatically: you may need an installer again, or an archive may hold the only copy of something.",
                 impact: "You’d need to download them again.", level: .review),

        // Browsers
        category("browser-safari", .browser, "Safari Cache", "safari.fill",
                 summary: "Cached web files Safari can download again.",
                 safety: "Only cache files are removed. Cookies, sign-ins, history, bookmarks, extensions and open tabs are never touched. Safari must be closed.",
                 impact: "Websites load a little slower the first time.", level: .safe, immediate: true, ownerClosed: true),
        category("browser-chrome", .browser, "Google Chrome Cache", "globe",
                 summary: "Chrome’s disk cache for each profile.",
                 safety: "Only the Cache folders are cleaned. Profiles, cookies, passwords, history, bookmarks and extensions are never touched. Chrome must be closed.",
                 impact: "Websites load a little slower the first time.", level: .safe, immediate: true, ownerClosed: true),
        category("browser-edge", .browser, "Microsoft Edge Cache", "globe",
                 summary: "Edge’s disk cache for each profile.",
                 safety: "Only the Cache folders are cleaned. Profiles, cookies, passwords, history and extensions are never touched. Edge must be closed.",
                 impact: "Websites load a little slower the first time.", level: .safe, immediate: true, ownerClosed: true),
        category("browser-brave", .browser, "Brave Cache", "globe",
                 summary: "Brave’s disk cache for each profile.",
                 safety: "Only the Cache folders are cleaned. Profiles, cookies, wallets, passwords and history are never touched. Brave must be closed.",
                 impact: "Websites load a little slower the first time.", level: .safe, immediate: true, ownerClosed: true),
        category("browser-firefox", .browser, "Firefox Cache", "globe",
                 summary: "Firefox’s cache2 folder for each profile.",
                 safety: "Only cache2 is cleaned. Profiles, logins, cookies, history and add-ons are never touched. Firefox must be closed.",
                 impact: "Websites load a little slower the first time.", level: .safe, immediate: true, ownerClosed: true),

        // Developer
        category("xcode-derived-data", .developer, "Xcode DerivedData", "hammer.fill",
                 summary: "Build products, indexes and intermediates for each project.",
                 safety: "Xcode rebuilds DerivedData on the next build. Projects built in the last 15 minutes are skipped. Source code, projects and signing assets live elsewhere and are never touched.",
                 impact: "The next build and indexing of each project take longer.", level: .safe, immediate: true),
        category("xcode-archives", .developer, "Xcode Archives", "archivebox.fill",
                 summary: "Archived app builds in ~/Library/Developer/Xcode/Archives.",
                 safety: "Review first: archives contain release builds and debug symbols you may need for crash reports or re-submission.",
                 impact: "You can’t re-export or symbolicate those builds.", level: .review),
        category("xcode-device-support", .developer, "Device Support Files", "iphone",
                 summary: "Debug symbols Xcode copies from each iOS/watchOS/tvOS/visionOS version you’ve connected.",
                 safety: "Re-created automatically the next time a device with that OS version connects. Old versions are usually unneeded.",
                 impact: "The next connection of that device takes a while to prepare.", level: .review),
        category("simulator-caches", .developer, "Simulator Caches", "ipad.and.iphone",
                 summary: "Caches CoreSimulator rebuilds on demand.",
                 safety: "Only ~/Library/Developer/CoreSimulator/Caches is cleaned. Simulator devices, their data and runtimes are never touched.",
                 impact: "Simulators may take longer to boot once.", level: .safe, immediate: true),
        category("swiftpm-cache", .developer, "Swift Package Manager Cache", "swift",
                 summary: "Downloaded package repositories in ~/Library/Caches/org.swift.swiftpm.",
                 safety: "SwiftPM fetches packages again when needed.", impact: "The next package resolution re-downloads dependencies.", level: .safe, immediate: true),
        category("cocoapods-cache", .developer, "CocoaPods Cache", "cube.fill",
                 summary: "Downloaded pods in ~/Library/Caches/CocoaPods.",
                 safety: "Equivalent to `pod cache clean --all`.", impact: "The next pod install downloads again.", level: .safe, immediate: true),
        category("homebrew-cache", .developer, "Homebrew Downloads", "mug.fill",
                 summary: "Downloaded bottles and source archives in ~/Library/Caches/Homebrew.",
                 safety: "Equivalent to the download cleanup in `brew cleanup`. Installed packages are untouched.", impact: "Reinstalling a formula downloads it again.", level: .safe, immediate: true),
        category("pip-cache", .developer, "pip Cache", "terminal.fill",
                 summary: "Downloaded wheels in ~/Library/Caches/pip.",
                 safety: "Equivalent to `pip cache purge`.", impact: "Packages are downloaded again on install.", level: .safe, immediate: true),
        category("go-build-cache", .developer, "Go Build Cache", "terminal.fill",
                 summary: "Compiled package cache in ~/Library/Caches/go-build.",
                 safety: "Equivalent to `go clean -cache`.", impact: "The next Go build is slower.", level: .safe, immediate: true),
        category("yarn-cache", .developer, "Yarn Cache", "terminal.fill",
                 summary: "Package tarballs in ~/Library/Caches/Yarn.",
                 safety: "Equivalent to `yarn cache clean`.", impact: "Packages are downloaded again on install.", level: .safe, immediate: true),
        category("playwright-browsers", .developer, "Playwright Browsers", "theatermasks.fill",
                 summary: "Browser builds Playwright downloads to ~/Library/Caches/ms-playwright.",
                 safety: "Re-downloaded by `npx playwright install` when tests need them.", impact: "The next Playwright run downloads browsers again.", level: .safe, immediate: true),
        category("node-gyp-cache", .developer, "node-gyp Headers", "terminal.fill",
                 summary: "Node.js headers cached for compiling native modules.",
                 safety: "node-gyp downloads them again when it needs to build a native module.", impact: "The next native module build downloads headers.", level: .safe, immediate: true),
        category("npm-cache", .developer, "npm Cache", "terminal.fill",
                 summary: "The content-addressable cache in ~/.npm/_cacache.",
                 safety: "Equivalent to `npm cache clean --force`, which npm documents as safe. Installed node_modules are unaffected.", impact: "Packages are downloaded again on install.", level: .safe, immediate: true),
        category("pnpm-store", .developer, "pnpm Store", "terminal.fill",
                 summary: "pnpm’s global content-addressable store.",
                 safety: "Review first: projects hard-link files from this store, so removing it frees little while those projects exist. Prefer `pnpm store prune`.", impact: "Projects reinstall packages from the network.", level: .review),
        category("gradle-cache", .developer, "Gradle Caches", "terminal.fill",
                 summary: "Dependency and build caches in ~/.gradle/caches.",
                 safety: "Gradle documents this folder as safe to delete; stop running Gradle daemons first. Wrapper distributions and settings are kept.", impact: "The next build downloads dependencies again.", level: .safe, immediate: true),
        category("maven-repository", .developer, "Maven Local Repository", "terminal.fill",
                 summary: "Artifacts in ~/.m2/repository.",
                 safety: "Review first: it can contain artifacts you installed locally with `mvn install` that exist nowhere else.", impact: "Dependencies are downloaded again.", level: .review),
        category("node-modules", .developer, "node_modules Folders", "shippingbox.circle.fill",
                 summary: "Installed JavaScript dependencies in your project folders.",
                 safety: "Review first: reinstall with `npm install` (or yarn/pnpm). Only the node_modules folder is removed — never the project.", impact: "Projects need dependencies reinstalled before they run.", level: .review),
        category("build-artifacts", .developer, "Project Build Outputs", "gearshape.2.fill",
                 summary: "Rebuildable output folders (Rust target, Flutter/Gradle build, SwiftPM .build).",
                 safety: "Review first: detected only next to the matching project file (Cargo.toml, pubspec.yaml, build.gradle, Package.swift).", impact: "The next build starts from scratch.", level: .review),
        category("python-venvs", .developer, "Python Virtual Environments", "terminal.fill",
                 summary: "Folders containing pyvenv.cfg inside your projects.",
                 safety: "Review first: recreate with `python -m venv` and reinstall requirements.", impact: "The environment must be recreated.", level: .review),
        category("docker-data", .developer, "Docker Desktop Data", "shippingbox.and.arrow.backward.fill",
                 summary: "Docker images, containers, volumes and build cache.",
                 safety: "Protected: volumes and containers can hold databases and other irreplaceable data. Manage it in Docker Desktop or with `docker system df` and an explicit `docker system prune`.", impact: "—", level: .protected),

        // Files picked by hand in the Storage Analyzer, Large Files, Old Files or Duplicates
        category("user-file", .userFiles, "Selected Files", "doc.fill",
                 summary: "Files and folders you chose yourself.",
                 safety: "Always reviewed by you. Moved to the Trash, never deleted outright; protected locations can’t be chosen.",
                 impact: "Restore from the Trash if you change your mind.", level: .review),

        // Leftovers
        category("leftover-support", .leftovers, "Application Support (uninstalled apps)", "folder.fill.badge.questionmark",
                 summary: "Data folders named after apps that are no longer installed.",
                 safety: "Review first: may contain documents, databases or downloads you created with that app.", impact: "The data is gone if you reinstall the app.", level: .review),
        category("leftover-containers", .leftovers, "Containers (uninstalled apps)", "square.stack.3d.down.right.fill",
                 summary: "Sandboxed app containers for apps that are no longer installed.",
                 safety: "Review first: containers can hold user-created content.", impact: "The data is gone if you reinstall the app.", level: .review),
        category("leftover-group-containers", .leftovers, "Group Containers (uninstalled apps)", "square.stack.3d.up.fill",
                 summary: "Shared containers for app groups whose apps are no longer installed.",
                 safety: "Review first: shared by every app from that developer. Folders shared with an installed app are protected.", impact: "The data is gone if you reinstall the apps.", level: .review),
        category("leftover-preferences", .leftovers, "Preferences (uninstalled apps)", "slider.horizontal.3",
                 summary: "Settings files for apps that are no longer installed.",
                 safety: "Small, but review first: they restore your settings if you reinstall.", impact: "Settings reset if you reinstall the app.", level: .review),
        category("leftover-web-data", .leftovers, "Web Caches (uninstalled apps)", "network",
                 summary: "HTTPStorages and WebKit caches for apps that are no longer installed.",
                 safety: "Network caches of apps that no longer exist.", impact: "None expected.", level: .safe, immediate: true),
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func category(id: String) -> CleanupCategory? { byID[id] }

    static func categories(in group: CleanupGroup) -> [CleanupCategory] {
        all.filter { $0.group == group }
    }
}
