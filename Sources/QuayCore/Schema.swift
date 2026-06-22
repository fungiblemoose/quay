import Foundation

// MARK: - Stack file schema
//
// One YAML file == one stack. This is Quay's *native* format, deliberately not
// docker-compose. Decoding is hand-written so that missing keys fall back to
// sensible defaults instead of throwing — a stack author should be able to omit
// `restart`, `protocol`, and the health integers and still get a valid stack.

public struct StackFile: Codable, Sendable, Equatable {
    public var version: Int
    public var stack: String
    public var services: [String: Service]
    public var volumes: [String: VolumeSpec]

    public init(version: Int, stack: String, services: [String: Service], volumes: [String: VolumeSpec] = [:]) {
        self.version = version
        self.stack = stack
        self.services = services
        self.volumes = volumes
    }

    enum CodingKeys: String, CodingKey { case version, stack, services, volumes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.stack = try c.decode(String.self, forKey: .stack)
        self.services = try c.decodeIfPresent([String: Service].self, forKey: .services) ?? [:]
        self.volumes = try c.decodeIfPresent([String: VolumeSpec].self, forKey: .volumes) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(stack, forKey: .stack)
        try c.encode(services, forKey: .services)
        try c.encode(volumes, forKey: .volumes)
    }
}

public struct Service: Codable, Sendable, Equatable {
    public var image: String
    public var env: [String]
    public var volumes: [String]
    public var publish: [PortPublish]
    public var restart: RestartPolicy
    public var health: HealthSpec?

    public init(image: String,
                env: [String] = [],
                volumes: [String] = [],
                publish: [PortPublish] = [],
                restart: RestartPolicy = .always,
                health: HealthSpec? = nil) {
        self.image = image
        self.env = env
        self.volumes = volumes
        self.publish = publish
        self.restart = restart
        self.health = health
    }

    enum CodingKeys: String, CodingKey { case image, env, volumes, publish, restart, health }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.image = try c.decode(String.self, forKey: .image)
        self.env = try c.decodeIfPresent([String].self, forKey: .env) ?? []
        self.volumes = try c.decodeIfPresent([String].self, forKey: .volumes) ?? []
        self.publish = try c.decodeIfPresent([PortPublish].self, forKey: .publish) ?? []
        // Default restart policy is `always` when the key is absent.
        self.restart = try c.decodeIfPresent(RestartPolicy.self, forKey: .restart) ?? .always
        self.health = try c.decodeIfPresent(HealthSpec.self, forKey: .health)
    }
}

public enum RestartPolicy: String, Codable, Sendable, Equatable {
    case always
    case onFailure = "on-failure"
    case never

    /// Decode leniently: unknown / misspelled values fall back to `always` rather
    /// than throwing, since `always` is the safest default for an appliance.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw.lowercased() {
        case "always": self = .always
        case "on-failure", "onfailure", "on_failure": self = .onFailure
        case "never", "no", "none": self = .never
        default: self = .always
        }
    }
}

public enum NetProtocol: String, Codable, Sendable, Equatable {
    case tcp
    case udp // NOTE: out of scope for v1 publish logic; accepted in schema only.
}

public struct PortPublish: Codable, Sendable, Equatable {
    public var host: Int
    public var container: Int
    public var proto: NetProtocol

    public init(host: Int, container: Int, proto: NetProtocol = .tcp) {
        self.host = host
        self.container = container
        self.proto = proto
    }

    enum CodingKeys: String, CodingKey {
        case host, container
        case proto = "protocol"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.host = try c.decode(Int.self, forKey: .host)
        self.container = try c.decode(Int.self, forKey: .container)
        // Default protocol is tcp when omitted.
        self.proto = try c.decodeIfPresent(NetProtocol.self, forKey: .proto) ?? .tcp
    }
}

public enum HealthType: String, Codable, Sendable, Equatable {
    case http
    // `dns` is explicitly out of scope for v1 (see README scope section).
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = HealthType(rawValue: raw.lowercased()) ?? .unknown
    }
}

public struct HealthSpec: Codable, Sendable, Equatable {
    public var type: HealthType
    public var url: String?
    public var intervalSeconds: Int
    public var timeoutSeconds: Int
    public var failuresToUnhealthy: Int
    public var failuresToRestart: Int

    public init(type: HealthType = .http,
                url: String? = nil,
                intervalSeconds: Int = 30,
                timeoutSeconds: Int = 5,
                failuresToUnhealthy: Int = 3,
                failuresToRestart: Int = 6) {
        self.type = type
        self.url = url
        self.intervalSeconds = intervalSeconds
        self.timeoutSeconds = timeoutSeconds
        self.failuresToUnhealthy = failuresToUnhealthy
        self.failuresToRestart = failuresToRestart
    }

    enum CodingKeys: String, CodingKey {
        case type, url
        case intervalSeconds = "interval_seconds"
        case timeoutSeconds = "timeout_seconds"
        case failuresToUnhealthy = "failures_to_unhealthy"
        case failuresToRestart = "failures_to_restart"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try c.decodeIfPresent(HealthType.self, forKey: .type) ?? .http
        self.url = try c.decodeIfPresent(String.self, forKey: .url)
        self.intervalSeconds = try c.decodeIfPresent(Int.self, forKey: .intervalSeconds) ?? 30
        self.timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 5
        self.failuresToUnhealthy = try c.decodeIfPresent(Int.self, forKey: .failuresToUnhealthy) ?? 3
        self.failuresToRestart = try c.decodeIfPresent(Int.self, forKey: .failuresToRestart) ?? 6
    }
}

/// Volume declarations. Today the body is empty (`{}`) but it is modeled as a
/// struct so options (driver, size, …) can be added without a schema break.
public struct VolumeSpec: Codable, Sendable, Equatable {
    public init() {}
    public init(from decoder: Decoder) throws {
        // Accept `{}`, null, or any mapping we don't yet understand.
        self.init()
    }
    public func encode(to encoder: Encoder) throws {
        // Encode as an empty mapping `{}` by creating (but not populating) a
        // keyed container.
        _ = encoder.container(keyedBy: EmptyKey.self)
    }
    private enum EmptyKey: CodingKey {}
}

// MARK: - Derived helpers

public extension StackFile {
    /// The managed container name for a service: `quay-<stack>-<service>`.
    func containerName(forService service: String) -> String {
        ContainerNaming.name(stack: stack, service: service)
    }
}

/// The single source of truth for "is this container mine".
public enum ContainerNaming {
    public static let prefix = "quay-"

    public static func name(stack: String, service: String) -> String {
        "\(prefix)\(stack)-\(service)"
    }

    public static func isManaged(_ containerName: String) -> Bool {
        containerName.hasPrefix(prefix)
    }
}
