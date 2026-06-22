import Foundation

/// Result of running an external process.
public struct CommandResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public var ok: Bool { exitCode == 0 }
}

public enum CommandError: Error, CustomStringConvertible {
    case launchFailed(String)
    case nonZeroExit(command: String, code: Int32, stderr: String)
    case toolNotFound(String)

    public var description: String {
        switch self {
        case .launchFailed(let m): return "failed to launch: \(m)"
        case .nonZeroExit(let cmd, let code, let err):
            return "`\(cmd)` exited \(code): \(err.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .toolNotFound(let tool): return "command not found: \(tool) (is it installed and on PATH?)"
        }
    }
}

/// Abstraction over "run a CLI and collect output" so the container client can be
/// unit-tested with a fake runner instead of shelling out to a real binary.
public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ args: [String]) async throws -> CommandResult
}

/// Real runner backed by Foundation `Process`. Resolves the executable on `PATH`
/// itself so a clear `toolNotFound` error surfaces instead of an opaque launch
/// failure when `container` isn't installed.
public struct ProcessRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ args: [String]) async throws -> CommandResult {
        let resolved = try Self.resolve(executable)
        return try await withCheckedThrowingContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: resolved)
            proc.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            // Drain pipes on background queues to avoid deadlock on large output.
            let outData = LockedData()
            let errData = LockedData()
            outPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil } else { outData.append(d) }
            }
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil } else { errData.append(d) }
            }

            proc.terminationHandler = { p in
                // Flush any remaining buffered bytes.
                outData.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                errData.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                let result = CommandResult(
                    exitCode: p.terminationStatus,
                    stdout: outData.string,
                    stderr: errData.string
                )
                cont.resume(returning: result)
            }

            do {
                try proc.run()
            } catch {
                cont.resume(throwing: CommandError.launchFailed(error.localizedDescription))
            }
        }
    }

    /// Resolve a bare command name against `PATH`; absolute paths pass through.
    static func resolve(_ executable: String) throws -> String {
        if executable.contains("/") { return executable }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        // apple/container commonly installs to /usr/local/bin; include it defensively.
        let dirs = (path.split(separator: ":").map(String.init)) + ["/usr/local/bin", "/opt/homebrew/bin"]
        let fm = FileManager.default
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent(executable)
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        throw CommandError.toolNotFound(executable)
    }
}

/// Tiny thread-safe byte buffer for pipe draining.
final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
