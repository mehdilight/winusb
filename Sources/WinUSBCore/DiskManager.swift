import Foundation

public struct USBDisk: Identifiable, Hashable {
    public var id: String { identifier }
    public let identifier: String      // e.g. "disk4"
    public let name: String            // e.g. "SanDisk Ultra"
    public let size: Int64
    public let bus: String             // e.g. "USB"
    public let isDiskImage: Bool
    public let volumes: [String]       // currently mounted volume names

    public var deviceNode: String { "/dev/\(identifier)" }
    public var sizeString: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .decimal) }
    public var displayName: String {
        "\(name) (\(identifier), \(sizeString)\(isDiskImage ? ", disk image" : ""))"
    }
}

public enum DiskManager {
    static let diskutil = "/usr/sbin/diskutil"

    /// Lists external, non-internal whole disks that are safe to erase.
    /// `includeDiskImages` is for testing with `hdiutil attach` images only.
    public static func listUSBDisks(includeDiskImages: Bool = false) throws -> [USBDisk] {
        let shell = Shell()
        let args = includeDiskImages ? ["list", "-plist", "external"] : ["list", "-plist", "external", "physical"]
        let list = try shell.plist(diskutil, args)
        let all = list["AllDisksAndPartitions"] as? [[String: Any]] ?? []

        var disks: [USBDisk] = []
        for entry in all {
            guard let ident = entry["DeviceIdentifier"] as? String else { continue }
            guard let info = try? shell.plist(diskutil, ["info", "-plist", ident]) else { continue }

            let isInternal = info["Internal"] as? Bool ?? true
            let wholeDisk = info["WholeDisk"] as? Bool ?? false
            let bus = info["BusProtocol"] as? String ?? "?"
            let isImage = bus == "Disk Image"
            let virtual = (info["VirtualOrPhysical"] as? String) == "Virtual"

            // Safety: never internal disks, never partitions, never APFS synthesized containers.
            if isInternal || !wholeDisk || ident == "disk0" { continue }
            if isImage && !includeDiskImages { continue }
            if virtual && !isImage { continue }
            if info["APFSPhysicalStores"] != nil || info["APFSContainerReference"] as? String == ident { continue }

            let name = (info["MediaName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (info["IORegistryEntryName"] as? String) ?? "Unknown Disk"
            let size = (info["TotalSize"] as? NSNumber ?? info["Size"] as? NSNumber)?.int64Value ?? 0

            let parts = entry["Partitions"] as? [[String: Any]] ?? []
            var vols = parts.compactMap { $0["VolumeName"] as? String }.filter { !$0.isEmpty }
            if let v = entry["VolumeName"] as? String, !v.isEmpty { vols.append(v) }

            disks.append(USBDisk(identifier: ident, name: name.trimmingCharacters(in: .whitespaces),
                                 size: size, bus: bus, isDiskImage: isImage, volumes: vols))
        }
        return disks
    }

    public static func unmount(_ disk: USBDisk, shell: Shell) throws {
        try shell.run(diskutil, ["unmountDisk", "force", disk.deviceNode])
    }

    public static func erase(_ disk: USBDisk, label: String, scheme: PartitionScheme, shell: Shell) throws {
        try shell.run(diskutil, ["eraseDisk", "MS-DOS FAT32", label, scheme.diskutilName, disk.deviceNode])
    }

    /// Finds the mount point of the FAT32 data partition created on `disk`.
    public static func mountPoint(of disk: USBDisk, label: String, shell: Shell) throws -> URL {
        for attempt in 0..<20 {
            let list = try shell.plist(diskutil, ["list", "-plist", disk.deviceNode])
            let all = list["AllDisksAndPartitions"] as? [[String: Any]] ?? []
            let parts = all.first?["Partitions"] as? [[String: Any]] ?? []
            for p in parts where (p["VolumeName"] as? String)?.uppercased() == label.uppercased() {
                guard let ident = p["DeviceIdentifier"] as? String else { continue }
                if let mp = p["MountPoint"] as? String, !mp.isEmpty { return URL(fileURLWithPath: mp) }
                if attempt == 3 { _ = try? shell.run(diskutil, ["mount", ident], check: false) }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw WriterError.message("The new FAT32 volume did not mount. Try unplugging and re-inserting the drive.")
    }

    public static func eject(_ disk: USBDisk, shell: Shell) throws {
        try shell.run(diskutil, ["eject", disk.deviceNode])
    }
}

public enum PartitionScheme: String, CaseIterable, Identifiable {
    case mbr = "MBR"
    case gpt = "GPT"
    public var id: String { rawValue }
    var diskutilName: String { rawValue }
    public var description: String {
        switch self {
        case .mbr: return "MBR (UEFI, most compatible)"
        case .gpt: return "GPT (UEFI only)"
        }
    }
}
