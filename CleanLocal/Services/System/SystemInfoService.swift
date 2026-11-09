import DiskArbitration
import Foundation
import IOKit
import IOKit.ps

/// Read-only facts about this Mac. Nothing here changes system state.
struct SystemSnapshot: Sendable {
    struct Battery: Sendable {
        let chargePercent: Int?
        let condition: String?
        let cycleCount: Int?
        /// Full-charge capacity relative to design capacity, when the hardware reports both.
        let healthPercent: Int?
        let isCharging: Bool
    }

    struct Disk: Sendable {
        let mediaName: String?
        let protocolName: String?
        let isInternal: Bool?
        let isSolidState: Bool?
        let fileSystem: String?
    }

    let modelIdentifier: String
    let chipName: String
    let architecture: String
    let osVersion: String
    let physicalMemory: UInt64
    let processorCount: Int
    let uptime: TimeInterval
    let thermalState: ProcessInfo.ThermalState
    let battery: Battery?
    let disk: Disk?
    let volume: VolumeCapacity?
    /// Space macOS can free on demand (caches, local snapshots), when reported.
    let purgeableBytes: Int64?
}

enum SystemInfoService {
    static func snapshot() -> SystemSnapshot {
        let volume = StorageAnalyticsService().startupVolume()
        return SystemSnapshot(
            modelIdentifier: sysctlString("hw.model") ?? "Mac",
            chipName: sysctlString("machdep.cpu.brand_string") ?? "Apple silicon",
            architecture: architecture,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            processorCount: ProcessInfo.processInfo.activeProcessorCount,
            uptime: ProcessInfo.processInfo.systemUptime,
            thermalState: ProcessInfo.processInfo.thermalState,
            battery: battery(),
            disk: bootDisk(),
            volume: volume,
            purgeableBytes: purgeableBytes()
        )
    }

    private static var architecture: String {
        #if arch(arm64)
        "Apple silicon (arm64)"
        #else
        "Intel (x86_64)"
        #endif
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    // MARK: Battery (public IOKit power-source and registry properties)

    static func battery() -> SystemSnapshot.Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int
            let max = description[kIOPSMaxCapacityKey] as? Int
            let registry = smartBatteryProperties()
            let design = registry["DesignCapacity"] as? Int
            let fullCharge = (registry["AppleRawMaxCapacity"] as? Int) ?? (registry["NominalChargeCapacity"] as? Int)
            let health = design.flatMap { design in fullCharge.map { Int((Double($0) / Double(design) * 100).rounded()) } }
            return SystemSnapshot.Battery(
                chargePercent: current.flatMap { current in max.map { $0 > 0 ? current * 100 / $0 : current } },
                condition: description[kIOPSBatteryHealthKey] as? String,
                cycleCount: registry["CycleCount"] as? Int,
                healthPercent: health.map { min($0, 100) },
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false
            )
        }
        return nil
    }

    private static func smartBatteryProperties() -> [String: Any] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return [:] }
        return properties?.takeRetainedValue() as? [String: Any] ?? [:]
    }

    // MARK: Disk (DiskArbitration, read-only)

    static func bootDisk() -> SystemSnapshot.Disk? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, URL(fileURLWithPath: "/") as CFURL),
              let description = DADiskCopyDescription(disk) as? [CFString: Any] else { return nil }
        let protocolName = description[kDADiskDescriptionDeviceProtocolKey] as? String
        return SystemSnapshot.Disk(
            mediaName: (description[kDADiskDescriptionDeviceModelKey] as? String)?.trimmingCharacters(in: .whitespaces)
                ?? description[kDADiskDescriptionMediaNameKey] as? String,
            protocolName: protocolName,
            isInternal: description[kDADiskDescriptionDeviceInternalKey] as? Bool,
            isSolidState: protocolName.map { ["Apple Fabric", "PCI-Express", "NVMe"].contains($0) },
            fileSystem: (description[kDADiskDescriptionVolumeKindKey] as? String)?.uppercased()
        )
    }

    private static func purgeableBytes() -> Int64? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: keys),
              let important = values.volumeAvailableCapacityForImportantUsage,
              let plain = values.volumeAvailableCapacity else { return nil }
        return max(0, important - Int64(plain))
    }
}

/// A launchd job definition found in a LaunchAgents/LaunchDaemons folder.
struct LaunchItem: Identifiable, Hashable, Sendable {
    var id: String { path }
    let label: String
    let path: String
    let program: String?
    let runsAtLoad: Bool
    let keepsAlive: Bool
    let scope: String
    let isDisabled: Bool
}

/// Read-only overview of background launch items. CleanLocal never edits or unloads them.
enum LoginItemsService {
    static func launchItems(home: URL) -> (items: [LaunchItem], unreadable: [String]) {
        let folders: [(String, String)] = [
            (home.appendingPathComponent("Library/LaunchAgents").path, "Your account"),
            ("/Library/LaunchAgents", "All users"),
            ("/Library/LaunchDaemons", "System-wide (daemon)"),
        ]
        var items: [LaunchItem] = []
        var unreadable: [String] = []
        for (folder, scope) in folders {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
                if FileManager.default.fileExists(atPath: folder) { unreadable.append(folder) }
                continue
            }
            for name in names where name.hasSuffix(".plist") {
                let path = folder + "/" + name
                guard let plist = NSDictionary(contentsOfFile: path) as? [String: Any] else { continue }
                let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
                let keepAlive: Bool = if let flag = plist["KeepAlive"] as? Bool { flag } else { plist["KeepAlive"] != nil }
                items.append(LaunchItem(
                    label: plist["Label"] as? String ?? String(name.dropLast(6)),
                    path: path, program: program, runsAtLoad: plist["RunAtLoad"] as? Bool ?? false,
                    keepsAlive: keepAlive, scope: scope, isDisabled: plist["Disabled"] as? Bool ?? false
                ))
            }
        }
        return (items.sorted { $0.label < $1.label }, unreadable)
    }
}
