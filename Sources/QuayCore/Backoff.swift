import Foundation

/// Per-container exponential backoff so a crash-looping image can't pin the CPU.
///
/// base 2s, doubling, capped at 5m, ~10 attempts before we give up and let the
/// reconciler mark the service `failed`. Reset on a healthy observation.
public struct Backoff: Sendable, Equatable {
    public let base: TimeInterval
    public let cap: TimeInterval
    public let maxAttempts: Int

    /// Number of consecutive failed (re)start cycles.
    public private(set) var attempts: Int = 0
    /// Wall-clock time before which we should not act again.
    public private(set) var nextAllowed: Date = .distantPast

    public init(base: TimeInterval = 2, cap: TimeInterval = 300, maxAttempts: Int = 10) {
        self.base = base
        self.cap = cap
        self.maxAttempts = maxAttempts
    }

    /// Have we burned through all attempts?
    public var isExhausted: Bool { attempts >= maxAttempts }

    /// May we act at `now`? (Respects the cooldown window.)
    public func mayAct(now: Date = Date()) -> Bool { now >= nextAllowed }

    /// The delay that *would* be applied for the current attempt count.
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        // attempt 0 -> base, 1 -> 2*base, ... capped.
        let raw = base * pow(2.0, Double(max(0, attempt)))
        return min(raw, cap)
    }

    /// Record that we just performed a (re)start attempt; advances the cooldown.
    public mutating func recordAttempt(now: Date = Date()) {
        let d = delay(forAttempt: attempts)
        attempts += 1
        nextAllowed = now.addingTimeInterval(d)
    }

    /// Service is healthy again — clear all backoff state.
    public mutating func reset() {
        attempts = 0
        nextAllowed = .distantPast
    }
}
