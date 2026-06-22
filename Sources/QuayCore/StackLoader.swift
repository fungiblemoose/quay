import Foundation
import Yams

/// Loads `*.quay.yaml` / `*.yaml` stack files from a directory. Re-read each tick
/// by quayd; a malformed file is logged and skipped, never fatal.
public struct StackLoader: Sendable {
    public let logger: Logger
    public init(logger: Logger = Logger()) { self.logger = logger }

    /// Parse a single YAML document into a StackFile. A fresh decoder per call
    /// keeps this free of shared mutable state (Yams' decoder isn't Sendable).
    public static func parse(_ yaml: String) throws -> StackFile {
        try YAMLDecoder().decode(StackFile.self, from: yaml)
    }

    /// Load every stack file in `dir`. Files that fail to parse are skipped with
    /// a logged warning so one bad edit can't take down the whole supervisor.
    public func load(from dir: URL) -> [StackFile] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            logger.warn("stacks dir not readable: \(dir.path)")
            return []
        }
        let yamlFiles = entries
            .filter { ["yaml", "yml"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var stacks: [StackFile] = []
        var seen: Set<String> = []
        for file in yamlFiles {
            do {
                let text = try String(contentsOf: file, encoding: .utf8)
                let stack = try StackLoader.parse(text)
                guard !stack.stack.isEmpty else {
                    logger.warn("\(file.lastPathComponent): empty `stack` name, skipping")
                    continue
                }
                if seen.contains(stack.stack) {
                    logger.warn("\(file.lastPathComponent): duplicate stack name '\(stack.stack)', skipping")
                    continue
                }
                seen.insert(stack.stack)
                stacks.append(stack)
            } catch {
                logger.warn("\(file.lastPathComponent): parse error: \(error) — skipping")
            }
        }
        return stacks
    }
}
