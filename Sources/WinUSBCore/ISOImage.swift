import Foundation

public let fat32MaxFileSize: Int64 = 4 * 1024 * 1024 * 1024 - 1

public struct ISOInfo {
    public let url: URL
    public let mountPoint: URL
    public let devEntry: String
    public let totalBytes: Int64
    public let fileCount: Int
    /// sources/install.wim or sources/install.esd
    public let installImage: URL?
    public let installImageSize: Int64
    public let architectures: [String]   // "x64", "arm64", "x86"
    public let editions: [String]        // from WIM XML, if wimlib is available
    /// Files larger than 4 GB other than the install image (cannot be put on FAT32).
    public let otherOversizedFiles: [String]

    public var needsSplit: Bool { installImageSize > fat32MaxFileSize }
    public var isWindows11: Bool { editions.contains { $0.localizedCaseInsensitiveContains("Windows 11") } }
    public var productName: String {
        if isWindows11 { return "Windows 11" }
        if editions.contains(where: { $0.localizedCaseInsensitiveContains("Windows 10") }) { return "Windows 10" }
        return "Windows"
    }
    public var suggestedLabel: String {
        isWindows11 ? "WIN11" : (productName == "Windows 10" ? "WIN10" : "WINUSB")
    }
}

public enum ISOImage {
    static let hdiutil = "/usr/bin/hdiutil"

    /// Mounts the ISO read-only (hidden from Finder) and inspects it.
    public static func open(_ url: URL, shell: Shell = Shell()) throws -> ISOInfo {
        let plist = try shell.plist(hdiutil, ["attach", "-nobrowse", "-readonly", "-noverify",
                                              "-noautofsck", "-plist", url.path])
        let entities = plist["system-entities"] as? [[String: Any]] ?? []
        guard let devEntry = entities.compactMap({ $0["dev-entry"] as? String }).sorted().first else {
            throw WriterError.message("hdiutil could not attach the image.")
        }
        guard let mp = entities.compactMap({ $0["mount-point"] as? String }).first else {
            _ = try? shell.run(hdiutil, ["detach", devEntry, "-force"], check: false)
            throw WriterError.message("The image attached but has no readable filesystem. Is this a Windows ISO?")
        }
        let mount = URL(fileURLWithPath: mp)
        do {
            return try inspect(url: url, mount: mount, devEntry: devEntry)
        } catch {
            close(devEntry: devEntry)
            throw error
        }
    }

    public static func close(devEntry: String) {
        _ = try? Shell().run(hdiutil, ["detach", devEntry, "-force"], check: false)
    }

    static func inspect(url: URL, mount: URL, devEntry: String) throws -> ISOInfo {
        let fm = FileManager.default
        func exists(_ rel: String) -> Bool { fm.fileExists(atPath: mount.appendingPathComponent(rel).path) }

        // Case-insensitive lookup of sources/install.(wim|esd)
        let sources = try? fm.contentsOfDirectory(atPath: mount.appendingPathComponent("sources").path)
        guard let sources else {
            throw WriterError.message("This doesn't look like a Windows installation ISO (no 'sources' folder).")
        }
        let installName = sources.first { $0.lowercased() == "install.wim" }
            ?? sources.first { $0.lowercased() == "install.esd" }
            ?? sources.first { $0.lowercased() == "install.swm" }
        let installURL = installName.map { mount.appendingPathComponent("sources").appendingPathComponent($0) }

        var arches: [String] = []
        if exists("efi/boot/bootx64.efi") || exists("EFI/BOOT/BOOTX64.EFI") { arches.append("x64") }
        if exists("efi/boot/bootaa64.efi") || exists("EFI/BOOT/BOOTAA64.EFI") { arches.append("arm64") }
        if exists("efi/boot/bootia32.efi") || exists("EFI/BOOT/BOOTIA32.EFI") { arches.append("x86") }
        if arches.isEmpty && !exists("bootmgr") {
            throw WriterError.message("No UEFI boot loader found in the ISO (efi/boot/*.efi).")
        }

        var total: Int64 = 0, count = 0, installSize: Int64 = 0
        var oversized: [String] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        if let en = fm.enumerator(at: mount, includingPropertiesForKeys: keys) {
            for case let f as URL in en {
                let v = try f.resourceValues(forKeys: Set(keys))
                guard v.isRegularFile == true else { continue }
                let size = Int64(v.fileSize ?? 0)
                total += size; count += 1
                if f.standardizedFileURL.path == installURL?.standardizedFileURL.path {
                    installSize = size
                } else if size > fat32MaxFileSize {
                    oversized.append(f.path.replacingOccurrences(of: mount.path + "/", with: ""))
                }
            }
        }

        var editions: [String] = []
        if let installURL, let wim = WimTool.find() {
            editions = (try? WimTool.imageNames(wim: wim, image: installURL)) ?? []
        }

        return ISOInfo(url: url, mountPoint: mount, devEntry: devEntry, totalBytes: total, fileCount: count,
                       installImage: installURL, installImageSize: installSize, architectures: arches,
                       editions: editions, otherOversizedFiles: oversized)
    }
}
