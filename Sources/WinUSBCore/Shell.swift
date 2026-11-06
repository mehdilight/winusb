import Foundation

public struct ShellError: LocalizedError {
    public let command: String
    public let status: Int32
    public let output: String

    public var errorDescription: String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return "`\(command)` failed (exit \(status))" + (trimmed.isEmpty ? "" : ":\n\(trimmed)")
    }
}

public struct ShellResult {
    public let status: Int32
    public let stdout: Data
    public let stderr: String
    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
}

/// Runs external tools (diskutil, hdiutil, wimlib-imagex). Keeps a handle on the
/// running process so a long-running job can be cancelled.
public final class Shell {
    private let lock = NSLock()
    private var current: Process?
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        let p = current
        lock.unlock()
        p?.terminate()
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    @discardableResult
    public func run(_ executable: String, _ args: [String], check: Bool = true,
                    onOutputLine: ((String) -> Void)? = nil) throws -> ShellResult {
        if isCancelled { throw CancellationError() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            if let onOutputLine {
                // Stream line by line (wimlib uses \r for progress lines).
                var buffer = Data()
                let handle = outPipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    outData.append(chunk)
                    buffer.append(chunk)
                    while let idx = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                        let line = String(decoding: buffer[buffer.startIndex..<idx], as: UTF8.self)
                        buffer.removeSubrange(buffer.startIndex...idx)
                        if !line.trimmingCharacters(in: .whitespaces).isEmpty { onOutputLine(line) }
                    }
                }
                if !buffer.isEmpty { onOutputLine(String(decoding: buffer, as: UTF8.self)) }
            } else {
                outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            }
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        lock.lock()
        current = process
        lock.unlock()
        defer { lock.lock(); current = nil; lock.unlock() }

        try process.run()
        process.waitUntilExit()
        group.wait()

        if isCancelled { throw CancellationError() }

        let result = ShellResult(status: process.terminationStatus, stdout: outData,
                                 stderr: String(decoding: errData, as: UTF8.self))
        if check && result.status != 0 {
            let cmd = ([URL(fileURLWithPath: executable).lastPathComponent] + args).joined(separator: " ")
            let combined = result.stderr.isEmpty ? result.stdoutString : result.stderr
            throw ShellError(command: cmd, status: result.status, output: combined)
        }
        return result
    }

    /// Runs a command that prints a property list and decodes it.
    public func plist(_ executable: String, _ args: [String]) throws -> [String: Any] {
        let r = try run(executable, args)
        guard let obj = try PropertyListSerialization.propertyList(from: r.stdout, format: nil) as? [String: Any] else {
            throw ShellError(command: executable, status: 0, output: "Could not parse plist output")
        }
        return obj
    }
}
