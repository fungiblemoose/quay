import Foundation

/// Minimal leveled logger that writes to stderr (quayd runs headless under a
/// LaunchAgent, so stderr is the natural sink — launchd captures it to a file).
public struct Logger: Sendable {
    public enum Level: Int, Sendable, Comparable {
        case debug = 0, info, warn, error
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        var label: String {
            switch self {
            case .debug: return "DEBUG"
            case .info:  return "INFO "
            case .warn:  return "WARN "
            case .error: return "ERROR"
            }
        }
    }

    public let minLevel: Level
    public let subsystem: String

    public init(subsystem: String = "quay", minLevel: Level = .info) {
        self.subsystem = subsystem
        self.minLevel = minLevel
    }

    private static func timestamp(_ date: Date) -> String {
        // A fresh formatter per line keeps this free of shared mutable state
        // (ISO8601DateFormatter isn't Sendable). Logging volume is low.
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    public func log(_ level: Level, _ message: @autoclosure () -> String) {
        guard level >= minLevel else { return }
        let line = "\(Self.timestamp(Date())) [\(level.label)] \(subsystem): \(message())\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    public func debug(_ m: @autoclosure () -> String) { log(.debug, m()) }
    public func info(_ m: @autoclosure () -> String)  { log(.info, m()) }
    public func warn(_ m: @autoclosure () -> String)  { log(.warn, m()) }
    public func error(_ m: @autoclosure () -> String) { log(.error, m()) }
}
