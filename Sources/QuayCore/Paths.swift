import Foundation

/// All Quay paths derive from `$HOME`. Nothing is hardcoded so the same binary
/// works for any user and any home location.
public enum QuayPaths {
    /// The user's home directory, taken from the `HOME` environment variable and
    /// falling back to the value Foundation reports.
    public static var home: URL {
        if let h = ProcessInfo.processInfo.environment["HOME"], !h.isEmpty {
            return URL(fileURLWithPath: h, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// `~/.config/quay` — the base for all runtime state.
    public static var configDir: URL {
        home.appendingPathComponent(".config/quay", isDirectory: true)
    }

    /// `~/.config/quay/stacks` — the default place quayd looks for stack files.
    public static var defaultStacksDir: URL {
        configDir.appendingPathComponent("stacks", isDirectory: true)
    }

    /// `~/.config/quay/status.json` — the snapshot QuayBar reads.
    public static var statusFile: URL {
        configDir.appendingPathComponent("status.json", isDirectory: false)
    }

    /// `~/.local/bin` — where install-agent.sh drops the built binaries.
    public static var localBin: URL {
        home.appendingPathComponent(".local/bin", isDirectory: true)
    }

    /// Ensure the config directory exists; safe to call repeatedly.
    public static func ensureConfigDir() throws {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    }
}
