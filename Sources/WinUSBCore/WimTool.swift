import Foundation

/// Wrapper around `wimlib-imagex`, used to split install.wim files larger than
/// FAT32's 4 GB limit into install.swm, install2.swm, ... (Windows Setup reads these natively).
public enum WimTool {
    /// Looks for a bundled copy inside the .app first, then Homebrew / MacPorts locations.
    public static func find() -> String? {
        var candidates: [String] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("wimlib/wimlib-imagex").path)
        }
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exe.appendingPathComponent("wimlib-imagex").path)
        }
        candidates += ["/opt/homebrew/bin/wimlib-imagex", "/usr/local/bin/wimlib-imagex", "/opt/local/bin/wimlib-imagex"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func imageNames(wim: String, image: URL) throws -> [String] {
        let r = try Shell().run(wim, ["info", image.path])
        var names: [String] = []
        for line in r.stdoutString.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "Name" {
                names.append(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return names
    }

    /// Splits `source` into `destination` (e.g. .../sources/install.swm) parts of `partSizeMiB`.
    public static func split(wim: String, source: URL, destination: URL, partSizeMiB: Int, shell: Shell,
                             log: @escaping (String) -> Void) throws {
        try shell.run(wim, ["split", source.path, destination.path, String(partSizeMiB)], onOutputLine: { line in
            // Only forward non-percentage lines to keep the log readable.
            if !line.contains("%") { log(line.trimmingCharacters(in: .whitespaces)) }
        })
    }

    /// Converts a solid-compressed ESD into a regular WIM (ESDs can't be split directly).
    public static func exportToWim(wim: String, source: URL, destination: URL, shell: Shell,
                                   log: @escaping (String) -> Void) throws {
        try shell.run(wim, ["export", source.path, "all", destination.path, "--compress=LZX"], onOutputLine: { line in
            if !line.contains("%") { log(line.trimmingCharacters(in: .whitespaces)) }
        })
    }
}
