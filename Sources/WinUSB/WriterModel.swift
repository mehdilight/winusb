import Foundation
import SwiftUI
import WinUSBCore

@MainActor
final class WriterModel: ObservableObject {
    enum State: Equatable { case idle, inspecting, writing, done, failed(String), cancelled }

    @Published var disks: [USBDisk] = []
    @Published var selectedDiskID: String?
    @Published var iso: ISOInfo?
    @Published var isoError: String?
    @Published var scheme: PartitionScheme = .mbr
    @Published var label = "WINUSB"
    @Published var unattend = UnattendOptions()
    @Published var state: State = .idle
    @Published var progress = WriteProgress(phase: "Ready", fraction: 0)
    @Published var log: [String] = []
    @Published var wimlibPath: String? = WimTool.find()

    private var writer: USBWriter?
    private var refreshTimer: Timer?
    private var refreshing = false

    var selectedDisk: USBDisk? { disks.first { $0.id == selectedDiskID } }
    var isBusy: Bool { state == .writing || state == .inspecting }

    var canStart: Bool {
        guard !isBusy, let iso, selectedDisk != nil else { return false }
        if iso.needsSplit && wimlibPath == nil { return false }
        return iso.otherOversizedFiles.isEmpty
    }

    init() {
        refreshDisks()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isBusy else { return }
                self.refreshDisks()
            }
        }
    }

    func refreshDisks() {
        guard !refreshing else { return }
        refreshing = true
        Task.detached {
            let list = (try? DiskManager.listUSBDisks()) ?? []
            await MainActor.run {
                self.refreshing = false
                if list != self.disks { self.disks = list }
                if self.selectedDiskID == nil || !list.contains(where: { $0.id == self.selectedDiskID }) {
                    self.selectedDiskID = list.first?.id
                }
                self.wimlibPath = WimTool.find()
            }
        }
    }

    func selectISO(_ url: URL) {
        closeISO()
        state = .inspecting
        isoError = nil
        progress = WriteProgress(phase: "Reading \(url.lastPathComponent)…", fraction: 0)
        Task.detached {
            do {
                let info = try ISOImage.open(url)
                await MainActor.run {
                    self.iso = info
                    self.label = info.suggestedLabel
                    self.state = .idle
                    self.progress = WriteProgress(phase: "Ready", fraction: 0)
                }
            } catch {
                await MainActor.run {
                    self.isoError = error.localizedDescription
                    self.state = .idle
                    self.progress = WriteProgress(phase: "Ready", fraction: 0)
                }
            }
        }
    }

    func closeISO() {
        if let iso { ISOImage.close(devEntry: iso.devEntry) }
        iso = nil
    }

    func start() {
        guard let iso, let disk = selectedDisk else { return }
        var opts = WriteOptions()
        opts.label = label
        opts.scheme = scheme
        opts.unattend = unattend

        log = []
        state = .writing
        progress = WriteProgress(phase: "Starting…", fraction: 0)

        let writer = USBWriter(
            onProgress: { p in Task { @MainActor in self.progress = p } },
            log: { line in Task { @MainActor in self.log.append(line) } })
        self.writer = writer

        Task.detached {
            do {
                try writer.write(iso: iso, to: disk, options: opts)
                await MainActor.run { self.state = .done; self.finish() }
            } catch is CancellationError {
                await MainActor.run {
                    self.state = .cancelled
                    self.log.append("Cancelled by user. The drive is incomplete.")
                    self.progress = WriteProgress(phase: "Cancelled", fraction: 0)
                    self.finish()
                }
            } catch {
                await MainActor.run {
                    self.state = .failed(error.localizedDescription)
                    self.log.append("ERROR: \(error.localizedDescription)")
                    self.progress.phase = "Failed"
                    self.finish()
                }
            }
        }
    }

    func cancel() { writer?.cancel() }

    private func finish() {
        writer = nil
        refreshDisks()
    }
}
