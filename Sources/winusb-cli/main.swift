import Foundation
import WinUSBCore

func usage() -> Never {
    print("""
    winusb-cli — create a bootable Windows 10/11 USB installer on macOS

    USAGE
      winusb-cli list
      winusb-cli info  <windows.iso>
      winusb-cli write <windows.iso> <diskN> [options]

    OPTIONS (write)
      --label NAME          FAT32 volume label (default: WIN11 / WIN10)
      --gpt                 GPT partition map (default: MBR)
      --bypass-checks       Windows 11: skip TPM / Secure Boot / RAM / CPU checks
      --bypass-online       Windows 11: allow setup without a Microsoft account
      --local-user NAME     create a local administrator account NAME
      --no-telemetry        answer "no" to all privacy questions
      --no-eject            leave the drive mounted when done
      --yes                 don't ask for confirmation
    """)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
let allowImages = args.contains("--allow-disk-images")   // testing only
args.removeAll { $0 == "--allow-disk-images" }
var splitMiB = 3800
if let i = args.firstIndex(of: "--split-mib"), i + 1 < args.count { splitMiB = Int(args[i + 1]) ?? 3800; args.removeSubrange(i...i+1) }

guard let cmd = args.first else { usage() }

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("error: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

func printInfo(_ iso: ISOInfo) {
    print("Image:        \(iso.url.lastPathComponent)")
    print("Product:      \(iso.productName)")
    print("Architecture: \(iso.architectures.joined(separator: ", "))")
    print("Files:        \(iso.fileCount), \(ByteCountFormatter.string(fromByteCount: iso.totalBytes, countStyle: .file))")
    if let inst = iso.installImage {
        print("Install img:  \(inst.lastPathComponent), \(ByteCountFormatter.string(fromByteCount: iso.installImageSize, countStyle: .file))\(iso.needsSplit ? "  → will be split (FAT32 4 GB limit)" : "")")
    }
    if !iso.editions.isEmpty { print("Editions:     " + iso.editions.joined(separator: "\n              ")) }
    if iso.needsSplit && WimTool.find() == nil { print("WARNING: wimlib not found — run: brew install wimlib") }
}

switch cmd {
case "list":
    do {
        let disks = try DiskManager.listUSBDisks(includeDiskImages: allowImages)
        if disks.isEmpty { print("No external USB drives found.") }
        for d in disks {
            print("\(d.identifier)\t\(d.sizeString)\t\(d.name)\t\(d.bus)\t\(d.volumes.joined(separator: ", "))")
        }
    } catch { fail(error.localizedDescription) }

case "info":
    guard args.count >= 2 else { usage() }
    do {
        let iso = try ISOImage.open(URL(fileURLWithPath: args[1]))
        defer { ISOImage.close(devEntry: iso.devEntry) }
        printInfo(iso)
    } catch { fail(error.localizedDescription) }

case "write":
    guard args.count >= 3 else { usage() }
    let isoPath = args[1]
    let diskId = args[2].replacingOccurrences(of: "/dev/", with: "")
    var opts = WriteOptions()
    opts.splitPartMiB = splitMiB
    var i = 3, yes = false, label: String?
    while i < args.count {
        switch args[i] {
        case "--label": i += 1; label = i < args.count ? args[i] : nil
        case "--gpt": opts.scheme = .gpt
        case "--bypass-checks": opts.unattend.bypassHardwareChecks = true
        case "--bypass-online": opts.unattend.bypassOnlineAccount = true
        case "--local-user": i += 1; opts.unattend.localAccountName = i < args.count ? args[i] : ""
        case "--no-telemetry": opts.unattend.disableDataCollection = true
        case "--no-eject": opts.ejectWhenDone = false
        case "--yes", "-y": yes = true
        default: fail("unknown option \(args[i])")
        }
        i += 1
    }

    let disks: [USBDisk]
    do { disks = try DiskManager.listUSBDisks(includeDiskImages: allowImages) } catch { fail(error.localizedDescription) }
    guard let disk = disks.first(where: { $0.identifier == diskId }) else {
        fail("\(diskId) is not an external USB drive. Run `winusb-cli list` to see available drives.")
    }

    let iso: ISOInfo
    do { iso = try ISOImage.open(URL(fileURLWithPath: isoPath)) } catch { fail(error.localizedDescription) }
    defer { ISOImage.close(devEntry: iso.devEntry) }
    printInfo(iso)
    opts.label = label ?? iso.suggestedLabel

    if !yes {
        print("\nALL DATA on \(disk.displayName) will be erased. Type 'yes' to continue: ", terminator: "")
        guard readLine()?.lowercased() == "yes" else { print("Aborted."); exit(1) }
    }

    let writer = USBWriter(onProgress: { p in
        let pct = Int(p.fraction * 100)
        let speed = p.bytesPerSecond > 0 ? " " + ByteCountFormatter.string(fromByteCount: Int64(p.bytesPerSecond), countStyle: .file) + "/s" : ""
        let phase = p.phase.count > 50 ? String(p.phase.prefix(47)) + "…" : p.phase
        print("\r\u{1B}[K[\(pct)%]\(speed) \(phase)", terminator: "")
        fflush(stdout)
    }, log: { print("\r\u{1B}[K• \($0)") })

    signal(SIGINT, SIG_IGN)
    let sigSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    sigSrc.setEventHandler { print("\nCancelling…"); writer.cancel() }
    sigSrc.resume()

    do {
        try writer.write(iso: iso, to: disk, options: opts)
        print("\n✅ USB drive is ready.")
    } catch is CancellationError {
        print("\nCancelled. The drive is incomplete — re-run to finish.")
        exit(130)
    } catch {
        print("")
        fail(error.localizedDescription)
    }

default:
    usage()
}
