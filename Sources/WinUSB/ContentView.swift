import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WinUSBCore

struct ContentView: View {
    @EnvironmentObject var model: WriterModel
    @State private var confirmErase = false
    @State private var showLog = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            driveSection
            customSection
            statusSection
            buttonRow
            if showLog { logView }
        }
        .padding(20)
        .frame(width: 600)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .overlay(dropTargeted ? RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 3).padding(4) : nil)
        .alert("Erase \(model.selectedDisk?.name ?? "drive")?", isPresented: $confirmErase) {
            Button("Erase and Write", role: .destructive) { showLog = true; model.start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("ALL DATA on \(model.selectedDisk?.displayName ?? "the selected drive") will be permanently destroyed.")
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !model.isBusy, let p = providers.first else { return false }
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url, url.pathExtension.lowercased() == "iso" {
                Task { @MainActor in model.selectISO(url) }
            }
        }
        return true
    }

    private var driveSection: some View {
            section("Drive Properties") {
                deviceRow
                isoRow
                if let err = model.isoError { warning(err, color: .red) }
                if let iso = model.iso { isoDetails(iso) }
                LabeledContent("Partition scheme") {
                    Picker("", selection: $model.scheme) {
                        ForEach(PartitionScheme.allCases) { Text($0.description).tag($0) }
                    }
                    .labelsHidden().frame(maxWidth: 260)
                }
                LabeledContent("Volume label") {
                    TextField("", text: $model.label).frame(maxWidth: 160)
                        .onChange(of: model.label) { v in
                            let s = WriteOptions.sanitizeLabel(v)
                            if s != v && !v.isEmpty { model.label = s }
                        }
                }
            }
            .disabled(model.isBusy)
    }

    private var customSection: some View {
            section("Windows Setup Customisation") {
                Toggle("Remove requirement for TPM 2.0, Secure Boot, 4 GB+ RAM and supported CPU",
                       isOn: $model.unattend.bypassHardwareChecks)
                Toggle("Remove requirement for an online Microsoft account", isOn: $model.unattend.bypassOnlineAccount)
                HStack {
                    Toggle("Create a local account named", isOn: Binding(
                        get: { !model.unattend.localAccountName.isEmpty },
                        set: { model.unattend.localAccountName = $0 ? NSUserName() : "" }))
                    TextField("username", text: $model.unattend.localAccountName).frame(maxWidth: 160)
                        .disabled(model.unattend.localAccountName.isEmpty)
                }
                Toggle("Disable data collection (skip privacy questions)", isOn: $model.unattend.disableDataCollection)
            }
            .disabled(model.isBusy)
    }

    private var statusSection: some View {
            section("Status") {
                ProgressView(value: model.progress.fraction)
                HStack {
                    Text(statusText).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(statusColor)
                    Spacer()
                    if model.state == .writing && model.progress.bytesPerSecond > 0 {
                        Text(speedText).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }
    }

    private var buttonRow: some View {
            HStack {
                Button(showLog ? "Hide log" : "Show log") { showLog.toggle() }
                Spacer()
                if model.state == .writing {
                    Button("Cancel", role: .cancel) { model.cancel() }
                } else {
                    Button("Start") { confirmErase = true }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canStart)
                }
            }
            .controlSize(.large)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.fill.badge.plus").font(.system(size: 30)).foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text("WinUSB").font(.title2.bold())
                Text("Create a bootable Windows 10 / 11 USB installer").foregroundStyle(.secondary)
            }
        }
    }

    private var deviceRow: some View {
        LabeledContent("Device") {
            HStack {
                Picker("", selection: $model.selectedDiskID) {
                    if model.disks.isEmpty { Text("No USB drive detected").tag(String?.none) }
                    ForEach(model.disks) { d in
                        Text(d.displayName + (d.volumes.isEmpty ? "" : " — \(d.volumes.joined(separator: ", "))"))
                            .tag(Optional(d.id))
                    }
                }
                .labelsHidden()
                Button { model.refreshDisks() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh drive list")
            }
        }
    }

    private var isoRow: some View {
        LabeledContent("Boot selection") {
            HStack {
                Text(model.iso?.url.lastPathComponent ?? (model.state == .inspecting ? "Reading…" : "Choose or drop a Windows ISO"))
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(model.iso == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if model.state == .inspecting { ProgressView().controlSize(.small) }
                Button("Select…") { pickISO() }
            }
        }
    }

    @ViewBuilder
    private func isoDetails(_ iso: ISOInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(iso.productName) · \(iso.architectures.joined(separator: "/")) · \(fmt(iso.totalBytes)) · \(iso.fileCount) files")
            if !iso.editions.isEmpty {
                Text(iso.editions.prefix(4).joined(separator: ", ") + (iso.editions.count > 4 ? " +\(iso.editions.count - 4) more" : ""))
                    .foregroundStyle(.secondary).lineLimit(2)
            }
            if iso.needsSplit {
                if model.wimlibPath != nil {
                    Text("install image is \(fmt(iso.installImageSize)) — it will be split into <4 GB parts for FAT32.")
                        .foregroundStyle(.secondary)
                } else {
                    warning("install.wim is larger than 4 GB and must be split. Install wimlib:  brew install wimlib", color: .orange)
                }
            }
            if !iso.otherOversizedFiles.isEmpty {
                warning("Files over 4 GB can't be stored on FAT32: \(iso.otherOversizedFiles.joined(separator: ", "))", color: .red)
            }
            if let d = model.selectedDisk, d.size < iso.totalBytes + 300_000_000 {
                warning("The selected drive is too small for this image.", color: .red)
            }
        }
        .font(.callout)
        .padding(.leading, 4)
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { i, line in
                        Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(i)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(height: 140)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: model.log.count) { n in proxy.scrollTo(n - 1) }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        } label: {
            Text(title).font(.headline)
        }
    }

    private func warning(_ text: String, color: Color) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(color).textSelection(.enabled)
    }

    private var statusText: String {
        switch model.state {
        case .done: return "Done — your Windows USB drive is ready and has been ejected."
        case .failed(let e): return "Failed: \(e)"
        case .cancelled: return "Cancelled — the drive is incomplete."
        default: return model.progress.phase
        }
    }

    private var statusColor: Color {
        switch model.state {
        case .done: return .green
        case .failed: return .red
        default: return .primary
        }
    }

    private var speedText: String {
        let p = model.progress
        var s = "\(fmt(p.bytesDone)) / \(fmt(p.bytesTotal)) · \(fmt(Int64(p.bytesPerSecond)))/s"
        if p.bytesPerSecond > 0 && p.bytesTotal > p.bytesDone {
            let eta = Int(Double(p.bytesTotal - p.bytesDone) / p.bytesPerSecond)
            s += String(format: " · %d:%02d left", eta / 60, eta % 60)
        }
        return s
    }

    private func pickISO() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Windows 10 or Windows 11 ISO"
        if panel.runModal() == .OK, let url = panel.url { model.selectISO(url) }
    }

    private func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
}
