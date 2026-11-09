import AppKit
import SwiftUI

/// Read-only system information and helpful links. Nothing here changes your Mac.
struct MaintenanceView: View {
    @Environment(MaintenanceStore.self) private var maintenance
    @Environment(AccessStore.self) private var access
    @Environment(NavigationModel.self) private var navigation

    private let columns = [GridItem(.adaptive(minimum: 340), spacing: Spacing.l, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                PageHeader(title: "Maintenance", subtitle: "Read-only information about this Mac. CleanLocal doesn’t change system settings.") {
                    Button("Refresh") { Task { await maintenance.refresh() } }.buttonStyle(.glass)
                }
                if let snapshot = maintenance.snapshot {
                    LazyVGrid(columns: columns, spacing: Spacing.l) {
                        macCard(snapshot)
                        storageCard(snapshot)
                        if let battery = snapshot.battery { batteryCard(battery) }
                        diskCard(snapshot)
                    }
                    loginItemsCard
                    accessCard
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(Spacing.xxl)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.pageBackground)
        .task { await maintenance.refresh() }
    }

    // MARK: Cards

    private func card<Content: View>(_ title: String, _ symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Label(title, systemImage: symbol).font(.cardTitle)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Spacing.xl)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.callout)
    }

    private func macCard(_ snapshot: SystemSnapshot) -> some View {
        card("This Mac", "laptopcomputer") {
            row("Model", snapshot.modelIdentifier)
            row("Chip", snapshot.chipName)
            row("Architecture", snapshot.architecture)
            row("macOS", snapshot.osVersion)
            row("Memory", Int64(snapshot.physicalMemory).formatted(.byteCount(style: .memory)))
            row("CPU cores", "\(snapshot.processorCount)")
            row("Uptime", Duration.seconds(snapshot.uptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated)))
            row("Thermal state", thermal(snapshot.thermalState))
        }
    }

    private func storageCard(_ snapshot: SystemSnapshot) -> some View {
        card("Storage Overview", "internaldrive") {
            if let volume = snapshot.volume {
                CapacityBar(volume: volume, mediaBytes: 0, compact: true)
                row("Capacity", volume.totalBytes.formattedBytes)
                row("Used", volume.usedBytes.formattedBytes)
                row("Available", volume.availableBytes.formattedBytes)
            }
            if let purgeable = snapshot.purgeableBytes, purgeable > 0 {
                row("Purgeable (estimated)", purgeable.formattedBytes)
            }
            Text("Storage figures are estimates: APFS snapshots, purgeable space and shared containers all affect what macOS reports.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Open Storage Analyzer") { navigation.destination = .storageAnalyzer }.buttonStyle(.link)
        }
    }

    private func batteryCard(_ battery: SystemSnapshot.Battery) -> some View {
        card("Battery", battery.isCharging ? "battery.100.bolt" : "battery.75") {
            if let charge = battery.chargePercent { row("Charge", "\(charge)%\(battery.isCharging ? " (charging)" : "")") }
            if let condition = battery.condition { row("Condition", condition) }
            if let health = battery.healthPercent { row("Maximum capacity", "\(health)%") }
            if let cycles = battery.cycleCount { row("Cycle count", "\(cycles)") }
            Text("Cleaning storage doesn’t change battery health. For battery settings, use System Settings › Battery.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func diskCard(_ snapshot: SystemSnapshot) -> some View {
        card("Startup Disk", "externaldrive") {
            if let disk = snapshot.disk {
                if let name = disk.mediaName { row("Device", name) }
                if let protocolName = disk.protocolName { row("Connection", protocolName) }
                if let isInternal = disk.isInternal { row("Location", isInternal ? "Internal" : "External") }
                if let fileSystem = disk.fileSystem { row("Format", fileSystem) }
            } else {
                Text("Disk details aren’t available.").foregroundStyle(.secondary)
            }
            Text("CleanLocal never repairs disks. To check or repair a disk, run First Aid in Disk Utility.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Open Disk Utility") {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.DiskUtility") {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                }
            }
            .buttonStyle(.glass)
        }
    }

    private var loginItemsCard: some View {
        card("Login & Background Items", "power") {
            Text("Apps that start automatically can slow startup. CleanLocal only lists what it can read; it never disables or removes launch items. Manage them in System Settings.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Login Items Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.primary)
                Spacer()
            }
            if maintenance.launchItems.isEmpty {
                Text(access.hasHomeAccess ? "No launch agents found in the folders CleanLocal can read." : "Grant Home folder access to list your launch agents.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(maintenance.launchItems) { item in
                        HStack(alignment: .top, spacing: Spacing.m) {
                            Image(systemName: item.scope.hasPrefix("System") ? "gearshape.2" : "person.crop.circle")
                                .foregroundStyle(Palette.accent).frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.label).font(.callout).lineLimit(1)
                                Text(item.program.map(UserDirectories.abbreviate(path:)) ?? item.path)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(item.scope).font(.caption).foregroundStyle(.secondary)
                                Text([item.runsAtLoad ? "At login" : nil, item.keepsAlive ? "Kept alive" : nil, item.isDisabled ? "Disabled" : nil]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 5)
                        Divider().opacity(0.5)
                    }
                }
            }
            Text("Startup impact isn’t shown: it can’t be measured reliably without system-level tools.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var accessCard: some View {
        card("Access & Permissions", "lock.shield") {
            Text("What macOS currently lets CleanLocal read. Locations without access are skipped, never worked around.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(access.audit) { check in
                HStack {
                    Image(systemName: check.readable ? "checkmark.circle.fill" : (check.exists ? "lock.circle" : "minus.circle"))
                        .foregroundStyle(check.readable ? Palette.ink : Palette.grey)
                    Text(check.title)
                    Spacer()
                    Text(check.statusTitle).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            HStack {
                if !access.hasHomeAccess { Button("Grant Home Folder…") { access.grantHomeAccess() }.buttonStyle(.primary) }
                if !access.hasTrashAccess { Button("Grant Trash…") { access.grantTrashAccess() }.buttonStyle(.glass) }
            }
        }
    }

    private func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Normal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}
