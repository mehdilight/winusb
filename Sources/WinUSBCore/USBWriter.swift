import Foundation

public enum WriterError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}

public struct WriteOptions {
    public var label = "WINUSB"
    public var scheme: PartitionScheme = .mbr
    public var unattend = UnattendOptions()
    /// Size of each install.swm part. Must stay below 4096 MiB.
    public var splitPartMiB = 3800
    public var ejectWhenDone = true
    public init() {}

    /// FAT32 labels: max 11 chars, upper-case, no special characters.
    public static func sanitizeLabel(_ s: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let cleaned = String(s.uppercased().filter { allowed.contains($0) }.prefix(11))
        return cleaned.isEmpty ? "WINUSB" : cleaned
    }
}

public struct WriteProgress {
    public var phase: String
    public var fraction: Double          // 0...1
    public var bytesDone: Int64 = 0
    public var bytesTotal: Int64 = 0
    public var bytesPerSecond: Double = 0

    public init(phase: String, fraction: Double, bytesDone: Int64 = 0, bytesTotal: Int64 = 0, bytesPerSecond: Double = 0) {
        self.phase = phase; self.fraction = fraction
        self.bytesDone = bytesDone; self.bytesTotal = bytesTotal; self.bytesPerSecond = bytesPerSecond
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    var value: Bool { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
}

/// Creates a bootable Windows installer USB:
/// 1. erase the drive as FAT32 (MBR or GPT)
/// 2. copy every file from the ISO
/// 3. split install.wim into <4 GB .swm parts if needed (FAT32 limit)
/// 4. optionally add an autounattend.xml (Windows 11 requirement bypasses etc.)
public final class USBWriter {
    public typealias ProgressHandler = (WriteProgress) -> Void
    public typealias LogHandler = (String) -> Void

    private let shell = Shell()
    private let onProgress: ProgressHandler
    private let log: LogHandler

    private var bytesTotal: Int64 = 0
    private var bytesDone: Int64 = 0
    private var startTime = Date()
    private var lastReport = Date.distantPast

    public init(onProgress: @escaping ProgressHandler, log: @escaping LogHandler) {
        self.onProgress = onProgress
        self.log = log
    }

    public func cancel() { shell.cancel() }

    private func checkCancel() throws { if shell.isCancelled { throw CancellationError() } }

    private func report(_ phase: String, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) > 0.15 else { return }
        lastReport = now
        let elapsed = max(now.timeIntervalSince(startTime), 0.001)
        // Erase = first 2 %, data = next 97 %, finalise = last 1 %.
        let frac = bytesTotal > 0 ? 0.02 + 0.97 * Double(bytesDone) / Double(bytesTotal) : 0
        onProgress(WriteProgress(phase: phase, fraction: min(frac, 0.99), bytesDone: bytesDone,
                                 bytesTotal: bytesTotal, bytesPerSecond: Double(bytesDone) / elapsed))
    }

    /// Blocking. Run on a background thread.
    public func write(iso: ISOInfo, to disk: USBDisk, options: WriteOptions) throws {
        let label = WriteOptions.sanitizeLabel(options.label)
        let wim = WimTool.find()

        // ---- Pre-flight checks -------------------------------------------------
        if !iso.otherOversizedFiles.isEmpty {
            throw WriterError.message("These files are larger than 4 GB and can't be stored on FAT32: \(iso.otherOversizedFiles.joined(separator: ", "))")
        }
        if iso.needsSplit && wim == nil {
            throw WriterError.message("install.wim is \(fmt(iso.installImageSize)) — larger than FAT32's 4 GB limit — and must be split. Install wimlib first:  brew install wimlib")
        }
        if disk.size < iso.totalBytes + 300_000_000 {
            throw WriterError.message("The drive (\(disk.sizeString)) is too small for this ISO (\(fmt(iso.totalBytes))).")
        }

        bytesTotal = iso.totalBytes
        bytesDone = 0
        startTime = Date()

        // ---- 1. Erase ----------------------------------------------------------
        onProgress(WriteProgress(phase: "Unmounting \(disk.identifier)…", fraction: 0))
        log("Unmounting \(disk.deviceNode)")
        try DiskManager.unmount(disk, shell: shell)
        try checkCancel()

        onProgress(WriteProgress(phase: "Formatting as FAT32 (\(options.scheme.rawValue))…", fraction: 0.005))
        log("Erasing \(disk.deviceNode) → FAT32 '\(label)', \(options.scheme.rawValue) partition map")
        try DiskManager.erase(disk, label: label, scheme: options.scheme, shell: shell)
        try checkCancel()

        let dest = try DiskManager.mountPoint(of: disk, label: label, shell: shell)
        log("Volume mounted at \(dest.path)")
        // Keep Spotlight / fseventsd from littering the drive.
        FileManager.default.createFile(atPath: dest.appendingPathComponent(".metadata_never_index").path, contents: nil)
        try? FileManager.default.createDirectory(at: dest.appendingPathComponent(".fseventsd"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dest.appendingPathComponent(".fseventsd/no_log").path, contents: nil)

        // ---- 2. Copy files -----------------------------------------------------
        startTime = Date()
        let src = iso.mountPoint
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let en = fm.enumerator(at: src, includingPropertiesForKeys: keys) else {
            throw WriterError.message("Couldn't read the ISO contents.")
        }
        let skipInstall = iso.needsSplit ? iso.installImage?.standardizedFileURL.path : nil
        let srcPrefix = src.standardizedFileURL.path

        log("Copying \(iso.fileCount) files (\(fmt(iso.totalBytes)))")
        for case let f as URL in en {
            try checkCancel()
            let v = try f.resourceValues(forKeys: Set(keys))
            var rel = String(f.standardizedFileURL.path.dropFirst(srcPrefix.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            let target = dest.appendingPathComponent(rel)
            if v.isDirectory == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else if v.isRegularFile == true {
                if f.standardizedFileURL.path == skipInstall { continue }
                try copyFile(from: f, to: target, phase: "Copying \(rel)")
            }
        }

        // ---- 3. Split install.wim ---------------------------------------------
        if iso.needsSplit, let wim, let install = iso.installImage {
            try splitInstallImage(wim: wim, install: install, destSources: dest.appendingPathComponent("sources"),
                                  partMiB: options.splitPartMiB)
        }

        // ---- 4. autounattend.xml ----------------------------------------------
        if !iso.isWindows11 && (options.unattend.bypassHardwareChecks || options.unattend.bypassOnlineAccount) {
            log("Skipping Windows 11-only options (TPM/Secure Boot bypass, BypassNRO): this is not a Windows 11 image")
        }
        if let xml = Unattend.xml(options.unattend, archs: iso.architectures, isWindows11: iso.isWindows11) {
            log("Writing autounattend.xml (Windows Setup customisations)")
            try xml.write(to: dest.appendingPathComponent("autounattend.xml"), atomically: false, encoding: .utf8)
        }

        // ---- 5. Finalise -------------------------------------------------------
        onProgress(WriteProgress(phase: "Flushing data to the drive…", fraction: 0.99, bytesDone: bytesDone, bytesTotal: bytesTotal))
        try? fm.removeItem(at: dest.appendingPathComponent(".Spotlight-V100"))
        removeAppleDoubleFiles(in: dest)
        sync()
        if options.ejectWhenDone {
            log("Ejecting \(disk.deviceNode)")
            try? DiskManager.eject(disk, shell: shell)
        }
        let secs = Date().timeIntervalSince(startTime)
        log(String(format: "Done in %d:%02d", Int(secs) / 60, Int(secs) % 60))
        onProgress(WriteProgress(phase: "Done", fraction: 1, bytesDone: bytesTotal, bytesTotal: bytesTotal))
    }

    private func splitInstallImage(wim: String, install: URL, destSources: URL, partMiB: Int) throws {
        var source = install
        var tempDir: URL?
        defer { if let tempDir { try? FileManager.default.removeItem(at: tempDir) } }

        if install.pathExtension.lowercased() == "esd" {
            // ESDs use solid compression and can't be split; convert to WIM first.
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("winusb-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            tempDir = tmp
            let out = tmp.appendingPathComponent("install.wim")
            report("Converting install.esd to install.wim (this can take a while)…", force: true)
            log("Converting install.esd → install.wim before splitting")
            try WimTool.exportToWim(wim: wim, source: install, destination: out, shell: shell, log: log)
            source = out
        }

        let base = bytesDone
        let target = destSources.appendingPathComponent("install.swm")
        log("Splitting \(install.lastPathComponent) (\(fmt(installSize(install)))) into \(partMiB) MiB install*.swm parts")

        // wimlib's own progress output is hard to parse reliably; instead watch the parts grow.
        let watcherDone = DispatchSemaphore(value: 0)
        let stopped = Flag()
        DispatchQueue.global().async { [self] in
            while true {
                if stopped.value { break }
                let written = (try? FileManager.default.contentsOfDirectory(at: destSources, includingPropertiesForKeys: [.fileSizeKey]))?
                    .filter { $0.pathExtension.lowercased() == "swm" }
                    .reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } ?? 0
                bytesDone = base + written
                report("Splitting install.wim into FAT32-sized parts…")
                Thread.sleep(forTimeInterval: 0.5)
            }
            watcherDone.signal()
        }
        defer {
            stopped.value = true
            watcherDone.wait()
        }
        try WimTool.split(wim: wim, source: source, destination: target, partSizeMiB: partMiB, shell: shell, log: log)
        let parts = (try? FileManager.default.contentsOfDirectory(atPath: destSources.path).filter { $0.lowercased().hasSuffix(".swm") }) ?? []
        log("Created \(parts.sorted().joined(separator: ", "))")
    }

    /// macOS stores extended attributes on FAT32 as "._name" sidecar files. Windows doesn't need them.
    private func removeAppleDoubleFiles(in root: URL) {
        // FileManager hides "._" files, so walk the tree with fts(3) and unlink them directly.
        var junk: [String] = []
        root.path.withCString { p in
            var paths: [UnsafeMutablePointer<CChar>?] = [strdup(p), nil]
            defer { free(paths[0]) }
            guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return }
            defer { fts_close(fts) }
            while let ent = fts_read(fts) {
                let info = Int32(ent.pointee.fts_info)
                guard info == FTS_F || info == FTS_DEFAULT else { continue }
                let path = String(cString: ent.pointee.fts_path)
                if (path as NSString).lastPathComponent.hasPrefix("._") { junk.append(path) }
            }
        }
        for path in junk { unlink(path) }
        if !junk.isEmpty { log("Removed \(junk.count) macOS metadata (._) files") }
    }

    private func installSize(_ u: URL) -> Int64 {
        Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// Uncached chunked copy so progress reflects what actually reached the USB stick.
    private func copyFile(from src: URL, to dst: URL, phase: String) throws {
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }

        let fd = open(dst.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw WriterError.message("Can't create \(dst.path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)

        let chunk = 8 * 1024 * 1024
        while true {
            try checkCancel()
            guard let data = try input.read(upToCount: chunk), !data.isEmpty else { break }
            try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                var off = 0
                while off < buf.count {
                    let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw WriterError.message("Write failed for \(dst.lastPathComponent): \(String(cString: strerror(errno)))")
                    }
                    off += n
                }
            }
            bytesDone += Int64(data.count)
            report(phase)
        }
    }
}

func fmt(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
