import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // URLSession lives here on Linux.
#endif

public enum HealthResult: Sendable, Equatable {
    case healthy
    case unhealthy(String)
    /// No health configured, or a type we don't evaluate — treated as healthy by
    /// the reconciler so services without a health block aren't churned.
    case notApplicable
}

/// Abstraction so the reconciler can be tested without real network I/O.
public protocol HealthChecking: Sendable {
    func check(_ spec: HealthSpec?) async -> HealthResult
}

/// HTTP health check: GET the URL, 2xx/3xx == healthy, anything else or a
/// transport error == unhealthy. Missing/unknown type == notApplicable.
public struct HTTPHealthChecker: HealthChecking {
    public let session: URLSession

    public init(session: URLSession? = nil) {
        if let s = session {
            self.session = s
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: cfg)
        }
    }

    public func check(_ spec: HealthSpec?) async -> HealthResult {
        guard let spec else { return .notApplicable }
        switch spec.type {
        case .http:
            guard let urlString = spec.url, let url = URL(string: urlString) else {
                return .unhealthy("no/invalid health url")
            }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = TimeInterval(spec.timeoutSeconds)
            do {
                let (_, response) = try await session.data(for: req)
                guard let http = response as? HTTPURLResponse else {
                    return .unhealthy("non-HTTP response")
                }
                if (200...399).contains(http.statusCode) {
                    return .healthy
                }
                return .unhealthy("HTTP \(http.statusCode)")
            } catch {
                return .unhealthy("\(error.localizedDescription)")
            }
        case .unknown:
            // dns and other types are out of scope for v1 — don't churn.
            return .notApplicable
        }
    }
}
