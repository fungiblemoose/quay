import Foundation

// MARK: - Status snapshot
//
// The reconciler is the single writer of this file; QuayBar is a read-only
// reader. Written atomically to ~/.config/quay/status.json each tick.

public enum ServiceRunState: String, Codable, Sendable {
    case pending     // desired, not yet created
    case starting    // create/start issued, not confirmed healthy yet
    case running     // running, health not applicable / not yet known
    case healthy     // running + health check passing
    case unhealthy   // running but failing health checks
    case stopped     // present but not running
    case failed      // backoff exhausted; given up
    case orphan      // quay-* container with no matching desired service
}

public enum HealthDot: String, Codable, Sendable {
    case green       // healthy
    case yellow      // starting / degraded / unknown
    case red         // failed / unhealthy
    case gray        // not applicable / no health configured
}

public struct ServiceStatus: Codable, Sendable, Equatable {
    public var service: String
    public var containerName: String
    public var image: String
    public var state: ServiceRunState
    public var health: HealthDot
    public var restartCount: Int
    public var backoffAttempt: Int
    public var nextActionAt: Date?
    public var lastError: String?

    public init(service: String, containerName: String, image: String,
                state: ServiceRunState, health: HealthDot, restartCount: Int,
                backoffAttempt: Int, nextActionAt: Date?, lastError: String?) {
        self.service = service
        self.containerName = containerName
        self.image = image
        self.state = state
        self.health = health
        self.restartCount = restartCount
        self.backoffAttempt = backoffAttempt
        self.nextActionAt = nextActionAt
        self.lastError = lastError
    }
}

public struct StackStatus: Codable, Sendable, Equatable {
    public var stack: String
    public var services: [ServiceStatus]
    public init(stack: String, services: [ServiceStatus]) {
        self.stack = stack
        self.services = services
    }
}

public struct StatusSnapshot: Codable, Sendable, Equatable {
    public var version: Int
    public var generatedAt: Date
    public var daemonHealthy: Bool
    public var containerRuntimeAvailable: Bool
    public var runtimeVersion: String?
    public var stacks: [StackStatus]
    public var orphans: [String]
    public var note: String?

    public init(version: Int = 1, generatedAt: Date = Date(), daemonHealthy: Bool = true,
                containerRuntimeAvailable: Bool = true, runtimeVersion: String? = nil,
                stacks: [StackStatus] = [], orphans: [String] = [], note: String? = nil) {
        self.version = version
        self.generatedAt = generatedAt
        self.daemonHealthy = daemonHealthy
        self.containerRuntimeAvailable = containerRuntimeAvailable
        self.runtimeVersion = runtimeVersion
        self.stacks = stacks
        self.orphans = orphans
        self.note = note
    }

    /// Aggregate glyph for the menu bar: red if anything failed/unhealthy,
    /// yellow if anything is still starting/degraded, green if all healthy.
    public var aggregate: HealthDot {
        let all = stacks.flatMap { $0.services }
        if all.isEmpty { return containerRuntimeAvailable ? .gray : .red }
        if all.contains(where: { $0.state == .failed || $0.state == .unhealthy }) { return .red }
        if all.contains(where: { $0.state == .pending || $0.state == .starting || $0.state == .stopped }) { return .yellow }
        if all.allSatisfy({ $0.state == .healthy || $0.state == .running }) { return .green }
        return .yellow
    }
}

/// Reads/writes the status snapshot. Atomic writes so a reader never sees a
/// half-written file.
public struct StatusStore: Sendable {
    public let url: URL

    public init(url: URL = QuayPaths.statusFile) {
        self.url = url
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func write(_ snapshot: StatusSnapshot) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    public func read() throws -> StatusSnapshot {
        let data = try Data(contentsOf: url)
        return try Self.decoder().decode(StatusSnapshot.self, from: data)
    }

    public static func encode(_ snapshot: StatusSnapshot) throws -> Data {
        try encoder().encode(snapshot)
    }

    public static func decode(_ data: Data) throws -> StatusSnapshot {
        try decoder().decode(StatusSnapshot.self, from: data)
    }
}
