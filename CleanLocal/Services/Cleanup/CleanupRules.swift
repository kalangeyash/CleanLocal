import Foundation

/// The user's home layout. Tests point this at a temporary folder.
struct HomeLayout: Sendable {
    let home: URL
    /// Developer folders the user chose; the only places searched for node_modules etc.
    var projectRoots: [URL] = []

    func path(_ relative: String) -> URL { home.appendingPathComponent(relative) }
    var caches: URL { path("Library/Caches") }
    var logs: URL { path("Library/Logs") }
    var downloads: URL { path("Downloads") }
    var developer: URL { path("Library/Developer") }
}

/// Age thresholds the user can tune in Settings.
struct CleanupThresholds: Sendable, Equatable {
    var logAgeDays = 30
    var crashReportAgeDays = 30
    var installerAgeDays = 14
    var incompleteDownloadAgeDays = 1
}

struct RuleContext: Sendable {
    let layout: HomeLayout
    let apps: any AppCataloging
    let installedApps: [InstalledApp]
    let running: Set<String>
    let now: Date
    let thresholds: CleanupThresholds
    let ownBundleID: String

    func owner(_ bundleID: String) -> AppOwner { apps.owner(bundleID: bundleID, running: running) }

    func isOlder(_ url: URL, thanDays days: Int) -> Bool {
        guard let info = FileSpaceInspector.inspect(url: url) else { return false }
        return now.timeIntervalSince(info.modificationDate) > Double(days) * 86_400
    }
}

/// A discovered item before sizing and final classification.
struct CandidateDraft: Sendable {
    var url: URL
    var name: String
    var detail: String?
    var scope: CleanupScope
    var safety: SafetyLevel
    var reasons: [String] = []
    var owner: AppOwner?
    /// Overrides the rule's category (project artifacts span several categories).
    var categoryID: String?
}

/// A location exists but macOS denied access to it.
struct RuleAccessError: Error, Sendable {
    let path: String
    let reason: String
}

struct CleanupRule: Sendable {
    let categoryID: String
    let discover: @Sendable (RuleContext) throws -> [CandidateDraft]
}

// MARK: - Rules

enum CleanupRules {
    /// Cache folders owned by more specific rules, so they aren't counted twice.
    static let claimedCacheFolders: Set<String> = [
        "Google", "Microsoft Edge", "BraveSoftware", "Firefox", "com.apple.Safari", "org.swift.swiftpm",
        "CocoaPods", "Homebrew", "pip", "go-build", "Yarn", "ms-playwright", "node-gyp",
    ]

    static let browserBundleIDs: [String: String] = [
        "browser-safari": "com.apple.Safari", "browser-chrome": "com.google.Chrome", "browser-edge": "com.microsoft.edgemac",
        "browser-brave": "com.brave.Browser", "browser-firefox": "org.mozilla.firefox",
    ]

    static func all() -> [CleanupRule] {
        [
            logs, diagnosticReports, savedApplicationState, applicationCaches, appTemporaryFolders,
            incompleteDownloads, installers,
            safari, chromium("browser-chrome", "Google/Chrome"), chromium("browser-edge", "Microsoft Edge"),
            chromium("browser-brave", "BraveSoftware/Brave-Browser"), firefox,
            derivedData, archives, deviceSupport,
            folderContents("simulator-caches", "Library/Developer/CoreSimulator/Caches", name: "CoreSimulator Caches"),
            folderContents("swiftpm-cache", "Library/Caches/org.swift.swiftpm", name: "SwiftPM"),
            folderContents("cocoapods-cache", "Library/Caches/CocoaPods", name: "CocoaPods"),
            folderContents("homebrew-cache", "Library/Caches/Homebrew", name: "Homebrew"),
            folderContents("pip-cache", "Library/Caches/pip", name: "pip"),
            folderContents("go-build-cache", "Library/Caches/go-build", name: "Go"),
            folderContents("yarn-cache", "Library/Caches/Yarn", name: "Yarn"),
            folderContents("playwright-browsers", "Library/Caches/ms-playwright", name: "Playwright"),
            folderContents("node-gyp-cache", "Library/Caches/node-gyp", name: "node-gyp"),
            wholeFolder("npm-cache", ".npm/_cacache", name: "npm cache", safety: .safe),
            wholeFolder("pnpm-store", "Library/pnpm/store", name: "pnpm store", safety: .review),
            wholeFolder("gradle-cache", ".gradle/caches", name: "Gradle caches", safety: .safe),
            wholeFolder("maven-repository", ".m2/repository", name: "Maven repository", safety: .review),
            dockerData, projectArtifacts,
            leftovers("leftover-support", "Library/Application Support", safety: .review),
            leftovers("leftover-containers", "Library/Containers", safety: .review),
            leftovers("leftover-group-containers", "Library/Group Containers", safety: .review),
            leftovers("leftover-preferences", "Library/Preferences", safety: .review, filesOnly: true),
            leftovers("leftover-web-data", "Library/HTTPStorages", safety: .safe),
            leftovers("leftover-web-data", "Library/WebKit", safety: .safe),
        ]
    }

    // MARK: Helpers

    /// Lists a directory. Missing → empty; permission denied → `RuleAccessError`.
    static func list(_ url: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            // `fileExists` can be false for unreadable parents; check the parent explicitly.
            if let parentError = accessError(for: url.deletingLastPathComponent()) { throw parentError }
            return []
        }
        guard isDirectory.boolValue else { return [] }
        do {
            return try FileManager.default.contentsOfDirectory(atPath: url.path)
                .filter { $0 != ".DS_Store" && $0 != ".localized" }
                .map { url.appendingPathComponent($0) }
        } catch {
            throw RuleAccessError(path: url.path, reason: "macOS didn’t allow CleanLocal to read this folder.")
        }
    }

    private static func accessError(for url: URL) -> RuleAccessError? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        if (try? FileManager.default.contentsOfDirectory(atPath: url.path)) == nil {
            return RuleAccessError(path: url.path, reason: "macOS didn’t allow CleanLocal to read this folder.")
        }
        return nil
    }

    static func isDirectory(_ url: URL) -> Bool {
        FileSpaceInspector.inspect(url: url)?.isDirectory ?? false
    }

    private static func exists(_ url: URL) -> Bool {
        FileSpaceInspector.inspect(url: url) != nil
    }

    // MARK: System junk

    static let logs = CleanupRule(categoryID: "user-logs") { context in
        let days = context.thresholds.logAgeDays
        return try list(context.layout.logs).compactMap { url -> CandidateDraft? in
            let name = url.lastPathComponent
            guard name != "DiagnosticReports", !name.hasPrefix(".") else { return nil }
            let owner = BundleIdentifier.extract(from: name).map(context.owner)
            if isDirectory(url) {
                return CandidateDraft(url: url, name: owner?.name ?? name, detail: "Files older than \(days) days",
                                      scope: .filesOlderThan(days: days), safety: .safe, owner: owner)
            }
            guard context.isOlder(url, thanDays: days) else { return nil }
            return CandidateDraft(url: url, name: name, detail: "Older than \(days) days", scope: .item, safety: .safe)
        }
    }

    static let diagnosticReports = CleanupRule(categoryID: "diagnostic-reports") { context in
        let days = context.thresholds.crashReportAgeDays
        let reportExtensions: Set<String> = ["ips", "crash", "spin", "hang", "diag", "panic", "cpu_resource", "wakeups_resource"]
        let root = context.layout.logs.appendingPathComponent("DiagnosticReports")
        var files = try list(root)
        for folder in files where isDirectory(folder) && folder.lastPathComponent == "Retired" {
            files += (try? list(folder)) ?? []
        }
        return files.compactMap { url in
            guard !isDirectory(url), reportExtensions.contains(url.pathExtension.lowercased()),
                  context.isOlder(url, thanDays: days) else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            let app = name.components(separatedBy: "-20").first.flatMap { $0.isEmpty ? nil : $0 } ?? name
            return CandidateDraft(url: url, name: app, detail: url.lastPathComponent, scope: .item, safety: .safe)
        }
    }

    static let savedApplicationState = CleanupRule(categoryID: "saved-app-state") { context in
        try list(context.layout.path("Library/Saved Application State")).compactMap { url in
            guard url.pathExtension == "savedState", let bundleID = BundleIdentifier.extract(from: url.lastPathComponent),
                  bundleID != context.ownBundleID else { return nil }
            let owner = context.owner(bundleID)
            return CandidateDraft(url: url, name: owner.name, detail: bundleID, scope: .item, safety: .review,
                                  reasons: owner.isInstalled ? [] : ["The app is no longer installed."], owner: owner)
        }
    }

    // MARK: Application caches

    static let applicationCaches = CleanupRule(categoryID: "app-caches") { context in
        try list(context.layout.caches).compactMap { url in
            let name = url.lastPathComponent
            guard !claimedCacheFolders.contains(name), !name.hasPrefix("."), name != context.ownBundleID else { return nil }
            guard let bundleID = BundleIdentifier.extract(from: name) else {
                return CandidateDraft(url: url, name: name, scope: isDirectory(url) ? .contents : .item, safety: .review,
                                      reasons: ["The owning app couldn’t be identified from the folder name."])
            }
            let owner = context.owner(bundleID)
            if BundleIdentifier.isApple(bundleID) {
                return CandidateDraft(url: url, name: owner.name, detail: bundleID, scope: isDirectory(url) ? .contents : .item,
                                      safety: .review, reasons: ["Apple service cache. macOS rebuilds most of these, but some services keep state here."],
                                      owner: owner)
            }
            return CandidateDraft(url: url, name: owner.name, detail: bundleID, scope: isDirectory(url) ? .contents : .item,
                                  safety: .safe,
                                  reasons: owner.isInstalled ? [] : ["The app is no longer installed."],
                                  owner: owner)
        }
    }

    static let appTemporaryFolders = CleanupRule(categoryID: "app-temporary") { context in
        var drafts: [CandidateDraft] = []
        for folder in try list(context.layout.caches) where isDirectory(folder) && !claimedCacheFolders.contains(folder.lastPathComponent) {
            for name in ["tmp", "Temp", "temp", "TemporaryItems"] {
                let candidate = folder.appendingPathComponent(name)
                guard isDirectory(candidate) else { continue }
                let owner = BundleIdentifier.extract(from: folder.lastPathComponent).map(context.owner)
                drafts.append(CandidateDraft(url: candidate, name: owner?.name ?? folder.lastPathComponent, detail: name,
                                             scope: .contents, safety: .safe, owner: owner))
            }
        }
        return drafts
    }

    // MARK: Downloads

    static let incompleteDownloads = CleanupRule(categoryID: "incomplete-downloads") { context in
        let extensions: Set<String> = ["crdownload", "download", "part", "partial", "opdownload"]
        let days = context.thresholds.incompleteDownloadAgeDays
        return try list(context.layout.downloads).compactMap { url in
            guard extensions.contains(url.pathExtension.lowercased()), context.isOlder(url, thanDays: days) else { return nil }
            return CandidateDraft(url: url, name: url.deletingPathExtension().lastPathComponent, detail: url.lastPathComponent,
                                  scope: .item, safety: .safe)
        }
    }

    static let installers = CleanupRule(categoryID: "installers") { context in
        let extensions: Set<String> = ["dmg", "pkg", "mpkg", "xip", "iso", "zip", "tgz", "7z", "rar", "gz"]
        let days = context.thresholds.installerAgeDays
        let installedNames = context.installedApps.map { $0.name.lowercased() }
        return try list(context.layout.downloads).compactMap { url in
            let fileExtension = url.pathExtension.lowercased()
            guard extensions.contains(fileExtension), !isDirectory(url) || fileExtension == "pkg",
                  context.isOlder(url, thanDays: days) else { return nil }
            var reasons = ["You may need this installer or archive again."]
            let lower = url.deletingPathExtension().lastPathComponent.lowercased()
            if let match = installedNames.first(where: { $0.count > 2 && lower.contains($0) }) {
                reasons.append("A matching app (“\(match.capitalized)”) appears to be installed already.")
            }
            return CandidateDraft(url: url, name: url.lastPathComponent, detail: "Older than \(days) days",
                                  scope: .item, safety: .review, reasons: reasons)
        }
    }

    // MARK: Browsers

    private static func browserOwner(_ categoryID: String, _ context: RuleContext) -> AppOwner? {
        browserBundleIDs[categoryID].map(context.owner)
    }

    static let safari = CleanupRule(categoryID: "browser-safari") { context in
        let owner = browserOwner("browser-safari", context)
        var drafts: [CandidateDraft] = []
        for relative in ["Library/Caches/com.apple.Safari", "Library/Containers/com.apple.Safari/Data/Library/Caches"] {
            let url = context.layout.path(relative)
            guard exists(url) else { continue }
            _ = try list(url) // surfaces a permission error
            drafts.append(CandidateDraft(url: url, name: "Safari", detail: relative, scope: .contents, safety: .safe, owner: owner))
        }
        return drafts
    }

    static func chromium(_ categoryID: String, _ vendorPath: String) -> CleanupRule {
        CleanupRule(categoryID: categoryID) { context in
            let owner = browserOwner(categoryID, context)
            let root = context.layout.caches.appendingPathComponent(vendorPath)
            var drafts: [CandidateDraft] = []
            for profile in try list(root) where isDirectory(profile) {
                for cacheName in ["Cache", "Code Cache", "GPUCache"] {
                    let cache = profile.appendingPathComponent(cacheName)
                    guard isDirectory(cache) else { continue }
                    drafts.append(CandidateDraft(url: cache, name: "\(owner?.name ?? vendorPath) — \(profile.lastPathComponent)",
                                                 detail: cacheName, scope: .contents, safety: .safe, owner: owner))
                }
            }
            return drafts
        }
    }

    static let firefox = CleanupRule(categoryID: "browser-firefox") { context in
        let owner = browserOwner("browser-firefox", context)
        return try list(context.layout.caches.appendingPathComponent("Firefox/Profiles")).compactMap { profile in
            let cache = profile.appendingPathComponent("cache2")
            guard isDirectory(cache) else { return nil }
            return CandidateDraft(url: cache, name: "Firefox — \(profile.lastPathComponent)", detail: "cache2",
                                  scope: .contents, safety: .safe, owner: owner)
        }
    }

    // MARK: Developer

    static let derivedData = CleanupRule(categoryID: "xcode-derived-data") { context in
        let xcode = context.owner("com.apple.dt.Xcode")
        return try list(context.layout.path("Library/Developer/Xcode/DerivedData")).compactMap { url in
            guard isDirectory(url) else { return nil }
            let name = url.lastPathComponent
            let project = name.contains("-") ? String(name[..<(name.lastIndex(of: "-") ?? name.endIndex)]) : name
            var reasons: [String] = []
            var safety = SafetyLevel.safe
            if xcode.isRunning {
                safety = .review
                reasons.append("Xcode is open; make sure this project isn’t building.")
            }
            return CandidateDraft(url: url, name: project, detail: name, scope: .item, safety: safety, reasons: reasons, owner: xcode)
        }
    }

    static let archives = CleanupRule(categoryID: "xcode-archives") { context in
        var drafts: [CandidateDraft] = []
        for day in try list(context.layout.path("Library/Developer/Xcode/Archives")) where isDirectory(day) {
            for archive in (try? list(day)) ?? [] where archive.pathExtension == "xcarchive" {
                let info = NSDictionary(contentsOf: archive.appendingPathComponent("Info.plist"))
                let name = info?["Name"] as? String ?? archive.deletingPathExtension().lastPathComponent
                let version = (info?["ApplicationProperties"] as? [String: Any])?["CFBundleShortVersionString"] as? String
                drafts.append(CandidateDraft(url: archive, name: name,
                                             detail: [version.map { "Version \($0)" }, day.lastPathComponent].compactMap { $0 }.joined(separator: " · "),
                                             scope: .item, safety: .review))
            }
        }
        return drafts
    }

    static let deviceSupport = CleanupRule(categoryID: "xcode-device-support") { context in
        var drafts: [CandidateDraft] = []
        for platform in ["iOS", "watchOS", "tvOS", "visionOS"] {
            let root = context.layout.path("Library/Developer/Xcode/\(platform) DeviceSupport")
            for version in (try? list(root)) ?? [] where isDirectory(version) {
                drafts.append(CandidateDraft(url: version, name: "\(platform) \(version.lastPathComponent)", detail: platform + " DeviceSupport",
                                             scope: .item, safety: .review))
            }
        }
        return drafts
    }

    static func folderContents(_ categoryID: String, _ relative: String, name: String) -> CleanupRule {
        CleanupRule(categoryID: categoryID) { context in
            let url = context.layout.path(relative)
            guard isDirectory(url) else { return [] }
            _ = try list(url)
            return [CandidateDraft(url: url, name: name, detail: "~/" + relative, scope: .contents, safety: .safe)]
        }
    }

    static func wholeFolder(_ categoryID: String, _ relative: String, name: String, safety: SafetyLevel) -> CleanupRule {
        CleanupRule(categoryID: categoryID) { context in
            let url = context.layout.path(relative)
            guard isDirectory(url) else { return [] }
            _ = try list(url)
            return [CandidateDraft(url: url, name: name, detail: "~/" + relative, scope: .item, safety: safety)]
        }
    }

    static let dockerData = CleanupRule(categoryID: "docker-data") { context in
        let url = context.layout.path("Library/Containers/com.docker.docker")
        guard exists(url) else { return [] }
        return [CandidateDraft(url: url, name: "Docker Desktop", detail: "Manage in Docker Desktop", scope: .item, safety: .protected,
                               reasons: ["Images, containers and volumes may hold irreplaceable data."],
                               owner: context.owner("com.docker.docker"))]
    }

    /// node_modules, build outputs and virtual environments — only inside chosen developer folders.
    static let projectArtifacts = CleanupRule(categoryID: "node-modules") { context in
        ProjectArtifactFinder.find(in: context.layout.projectRoots)
    }

    // MARK: Leftovers

    static func leftovers(_ categoryID: String, _ relative: String, safety: SafetyLevel, filesOnly: Bool = false) -> CleanupRule {
        CleanupRule(categoryID: categoryID) { context in
            let installedPrefixes = Set(context.installedApps.map { vendorPrefix(of: $0.bundleID) })
            return try list(context.layout.path(relative)).compactMap { url in
                if filesOnly && isDirectory(url) { return nil }
                guard let bundleID = BundleIdentifier.extract(from: url.lastPathComponent),
                      !BundleIdentifier.isApple(bundleID), bundleID != context.ownBundleID,
                      !context.apps.isInstalled(bundleID: bundleID) else { return nil }
                var draft = CandidateDraft(url: url, name: BundleIdentifier.prettyName(for: bundleID), detail: bundleID,
                                           scope: .item, safety: safety,
                                           reasons: ["No installed app uses \(bundleID)."],
                                           owner: context.owner(bundleID))
                if categoryID == "leftover-group-containers", installedPrefixes.contains(vendorPrefix(of: bundleID)) {
                    draft.safety = .protected
                    draft.reasons.append("Shared with an installed app from the same developer.")
                }
                return draft
            }
        }
    }

    static func vendorPrefix(of bundleID: String) -> String {
        bundleID.split(separator: ".").prefix(2).joined(separator: ".").lowercased()
    }
}

/// Finds rebuildable project artifacts, never descending into them or into hidden folders.
enum ProjectArtifactFinder {
    static let maxDepth = 7

    static func find(in roots: [URL]) -> [CandidateDraft] {
        var drafts: [CandidateDraft] = []
        var visited = Set<String>()
        for root in roots { visit(root, depth: 0, drafts: &drafts, visited: &visited) }
        return drafts
    }

    private static func visit(_ directory: URL, depth: Int, drafts: inout [CandidateDraft], visited: inout Set<String>) {
        guard depth <= maxDepth, !Task.isCancelled, visited.insert(directory.path).inserted,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let entries = Set(names)
        let projectName = Self.projectName(in: directory, entries: entries)
        var skip: Set<String> = ["node_modules", ".git"]

        func add(_ folder: String, category: String, kind: String) {
            let url = directory.appendingPathComponent(folder)
            guard RuleTypeCheck.isRealDirectory(url) else { return }
            skip.insert(folder)
            drafts.append(CandidateDraft(url: url, name: projectName, detail: "\(kind) · \(UserDirectories.abbreviate(path: directory.path))",
                                         scope: .item, safety: .review, categoryID: category))
        }

        if entries.contains("package.json") { add("node_modules", category: "node-modules", kind: "node_modules") }
        if entries.contains("Cargo.toml") { add("target", category: "build-artifacts", kind: "Rust target") }
        if entries.contains("pubspec.yaml") { add("build", category: "build-artifacts", kind: "Flutter build") }
        if entries.contains("build.gradle") || entries.contains("build.gradle.kts") { add("build", category: "build-artifacts", kind: "Gradle build") }
        if entries.contains("Package.swift") { add(".build", category: "build-artifacts", kind: "SwiftPM .build") }
        for venv in [".venv", "venv", "env"] where entries.contains(venv)
            && FileManager.default.fileExists(atPath: directory.appendingPathComponent(venv).appendingPathComponent("pyvenv.cfg").path) {
            add(venv, category: "python-venvs", kind: "Python venv")
        }

        for name in names where !name.hasPrefix(".") && !skip.contains(name) {
            let child = directory.appendingPathComponent(name)
            guard RuleTypeCheck.isRealDirectory(child), !SafetyPolicyEngine.protectedPackageExtensions.contains(child.pathExtension.lowercased()),
                  !["xcarchive", "photoslibrary", "app"].contains(child.pathExtension.lowercased()) else { continue }
            visit(child, depth: depth + 1, drafts: &drafts, visited: &visited)
        }
    }

    private static func projectName(in directory: URL, entries: Set<String>) -> String {
        if entries.contains("package.json"),
           let data = try? Data(contentsOf: directory.appendingPathComponent("package.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = json["name"] as? String, !name.isEmpty {
            return name
        }
        return directory.lastPathComponent
    }
}

enum RuleTypeCheck {
    /// A directory that is not a symbolic link.
    static func isRealDirectory(_ url: URL) -> Bool {
        guard let info = FileSpaceInspector.inspect(url: url) else { return false }
        return info.isDirectory && !info.isSymbolicLink
    }
}
