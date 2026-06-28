import Foundation

/// The core. An actor, and the **single writer** of container state. Every
/// create/start/stop/restart flows through here, serialized by the actor, so two
/// ticks can never race on the same container.
public actor Reconciler {
    private let client: ContainerClient
    private let health: HealthChecking
    private let status: StatusStore
    private let logger: Logger

    private let backoffBase: TimeInterval
    private let backoffCap: TimeInterval
    private let backoffMaxAttempts: Int

    /// Per-service runtime state, keyed by container name (`quay-<stack>-<svc>`).
    private var state: [String: ServiceRuntimeState] = [:]

    public init(client: ContainerClient,
                health: HealthChecking,
                status: StatusStore = StatusStore(),
                logger: Logger = Logger(),
                backoffBase: TimeInterval = 2,
                backoffCap: TimeInterval = 300,
                backoffMaxAttempts: Int = 10) {
        self.client = client
        self.health = health
        self.status = status
        self.logger = logger
        self.backoffBase = backoffBase
        self.backoffCap = backoffCap
        self.backoffMaxAttempts = backoffMaxAttempts
    }

    struct ServiceRuntimeState {
        var backoff: Backoff
        var consecutiveHealthFailures: Int = 0
        var restartCount: Int = 0
        var runState: ServiceRunState = .pending
        var healthDot: HealthDot = .gray
        var lastError: String?
        /// When we last ran a health probe. Used to honor the service's
        /// `interval_seconds` instead of probing on every (faster) reconcile tick.
        /// Reset to nil on (re)start so health re-evaluates promptly.
        var lastHealthCheckAt: Date?
        /// True once quayd has seen this service up at least once. Used so the
        /// FIRST bring-up isn't counted as a restart, but every later resurrection
        /// (container found stopped/missing after having been up) is.
        var hasEverStarted: Bool = false
    }

    private func ensureState(_ name: String) -> ServiceRuntimeState {
        if let s = state[name] { return s }
        let s = ServiceRuntimeState(backoff: Backoff(base: backoffBase, cap: backoffCap, maxAttempts: backoffMaxAttempts))
        state[name] = s
        return s
    }

    /// Run one reconcile pass. Returns the snapshot it published (also written to
    /// disk) so callers/tests can inspect the outcome.
    @discardableResult
    public func tick(stacks: [StackFile], now: Date = Date()) async -> StatusSnapshot {
        let probe = await client.probe()
        guard probe.available else {
            let snap = StatusSnapshot(
                generatedAt: now,
                daemonHealthy: true,
                containerRuntimeAvailable: false,
                runtimeVersion: probe.version,
                stacks: [],
                orphans: [],
                note: "container runtime unavailable: \(probe.detail ?? "unknown"). Quay needs Apple's `container` CLI (macOS 26+)."
            )
            try? status.write(snap)
            logger.error("container runtime unavailable — skipping reconcile. \(probe.detail ?? "")")
            return snap
        }

        // Snapshot of what actually exists right now.
        let actual: [ContainerSummary]
        do {
            actual = try await client.listManaged()
        } catch {
            logger.error("failed to list containers: \(error)")
            let snap = StatusSnapshot(generatedAt: now, daemonHealthy: false,
                                      containerRuntimeAvailable: true, runtimeVersion: probe.version,
                                      note: "list failed: \(error)")
            try? status.write(snap)
            return snap
        }
        var byName: [String: ContainerSummary] = [:]
        for c in actual { byName[c.name] = c }

        var desiredNames: Set<String> = []
        var stackStatuses: [StackStatus] = []

        for stack in stacks {
            // Ensure declared volumes exist before any service in the stack runs.
            for vol in stack.volumes.keys.sorted() {
                try? await client.ensureVolume(name: vol)
            }

            var serviceStatuses: [ServiceStatus] = []
            for serviceName in stack.services.keys.sorted() {
                let service = stack.services[serviceName]!
                let containerName = ContainerNaming.name(stack: stack.stack, service: serviceName)
                desiredNames.insert(containerName)
                let summary = byName[containerName]
                let st = await reconcileService(stack: stack, name: serviceName,
                                                service: service, containerName: containerName,
                                                summary: summary, now: now)
                serviceStatuses.append(st)
            }
            stackStatuses.append(StackStatus(stack: stack.stack, services: serviceStatuses))
        }

        // Orphans: ours by name, but not desired. LOG ONLY — never auto-remove.
        let orphans = actual.map(\.name).filter { !desiredNames.contains($0) }
        for o in orphans {
            logger.warn("orphan container (no matching stack service): \(o) — leaving it alone")
        }
        // Drop runtime state for things no longer desired (keep it tidy).
        for key in state.keys where !desiredNames.contains(key) {
            state.removeValue(forKey: key)
        }

        let snap = StatusSnapshot(
            generatedAt: now,
            daemonHealthy: true,
            containerRuntimeAvailable: true,
            runtimeVersion: probe.version,
            stacks: stackStatuses,
            orphans: orphans,
            note: nil
        )
        do { try status.write(snap) }
        catch { logger.error("failed to write status.json: \(error)") }
        return snap
    }

    // MARK: - per-service state machine

    private func reconcileService(stack: StackFile, name: String, service: Service,
                                  containerName: String, summary: ContainerSummary?,
                                  now: Date) async -> ServiceStatus {
        var s = ensureState(containerName)
        let spec = ContainerSpec(name: containerName, image: service.image,
                                 env: service.env, volumes: service.volumes, publish: service.publish,
                                 memory: service.memory, cpus: service.cpus)

        switch summary?.state {
        case .none:
            // Not present -> create + start (subject to backoff).
            await actStart(create: true, spec: spec, service: service, state: &s, now: now)

        case .stopped, .unknown:
            // Present but not running. Start if policy allows.
            if shouldStartStopped(policy: service.restart, exitCode: summary?.exitCode) {
                await actStart(create: false, spec: spec, service: service, state: &s, now: now)
            } else {
                s.runState = .stopped
                s.healthDot = .gray
                s.lastError = nil
            }

        case .running:
            await evaluateRunning(service: service, containerName: containerName, state: &s, now: now)
        }

        state[containerName] = s
        let nextAt: Date? = s.backoff.nextAllowed > now ? s.backoff.nextAllowed : nil
        return ServiceStatus(
            service: name,
            containerName: containerName,
            image: service.image,
            state: s.runState,
            health: s.healthDot,
            restartCount: s.restartCount,
            backoffAttempt: s.backoff.attempts,
            nextActionAt: nextAt,
            lastError: s.lastError
        )
    }

    /// Whether a stopped container should be (re)started given its restart policy.
    ///
    /// NOTE: Apple's `container` 1.0.0 does not report an exit code in `ls` *or*
    /// `inspect` — only a coarse running/stopped state. So `exitCode` is always
    /// nil in practice today, and `.onFailure` conservatively treats any stop as
    /// a failure (restart). The exit-code branch is kept so the policy becomes
    /// precise automatically if/when the CLI starts surfacing exit codes.
    private func shouldStartStopped(policy: RestartPolicy, exitCode: Int?) -> Bool {
        switch policy {
        case .always: return true
        case .never: return false
        case .onFailure:
            // on-failure-by-exit-code: nonzero (or unknown) exit means failure.
            guard let code = exitCode else { return true }
            return code != 0
        }
    }

    /// Issue a create-or-start, honoring backoff. Mutates `state`.
    private func actStart(create: Bool, spec: ContainerSpec, service: Service,
                          state s: inout ServiceRuntimeState, now: Date) async {
        if s.backoff.isExhausted {
            s.runState = .failed
            s.healthDot = .red
            return
        }
        guard s.backoff.mayAct(now: now) else {
            // In cooldown — waiting before the next attempt.
            s.runState = s.backoff.attempts > 0 ? .starting : .pending
            s.healthDot = .yellow
            return
        }
        s.backoff.recordAttempt(now: now)
        do {
            if create {
                // Volumes are ensured once per stack in tick(); nothing to do here.
                try await client.run(spec)
            } else {
                try await client.start(name: spec.name)
            }
            s.runState = .starting
            s.healthDot = .yellow
            s.lastError = nil
            s.lastHealthCheckAt = nil // re-probe health promptly after a (re)start
            // The first successful bring-up is the initial start; any later one is
            // a resurrection of a service that had been up — count it as a restart.
            if s.hasEverStarted { s.restartCount += 1 }
            s.hasEverStarted = true
            logger.info("\(create ? "created+started" : "started") \(spec.name) (attempt \(s.backoff.attempts))")
        } catch {
            s.lastError = "\(error)"
            s.runState = s.backoff.isExhausted ? .failed : .starting
            s.healthDot = s.backoff.isExhausted ? .red : .yellow
            logger.error("\(create ? "run" : "start") \(spec.name) failed (attempt \(s.backoff.attempts)): \(error)")
        }
    }

    /// Health-evaluate a running container and restart it if it's been failing.
    private func evaluateRunning(service: Service, containerName: String,
                                 state s: inout ServiceRuntimeState, now: Date) async {
        // We're here only because the container is running, so we've now observed
        // it up — a later disappearance counts as a restart even if quayd never
        // issued the original start (e.g. it adopted an already-running container).
        s.hasEverStarted = true

        // Throttle probes to the service's configured interval. Reconcile ticks
        // are typically faster (default 15s) than a health interval (default 30s);
        // without this we'd probe every tick and reach `failures_to_restart`
        // twice as fast as configured. Skipping keeps the last evaluated state.
        if let h = service.health, let last = s.lastHealthCheckAt,
           now.timeIntervalSince(last) < TimeInterval(h.intervalSeconds) {
            return
        }
        s.lastHealthCheckAt = now

        let result = await health.check(service.health)
        switch result {
        case .notApplicable:
            // No/unknown health -> consider it good; don't churn.
            s.backoff.reset()
            s.consecutiveHealthFailures = 0
            s.runState = .running
            s.healthDot = .gray
            s.lastError = nil

        case .healthy:
            s.backoff.reset()
            s.consecutiveHealthFailures = 0
            s.runState = .healthy
            s.healthDot = .green
            s.lastError = nil

        case .unhealthy(let reason):
            s.consecutiveHealthFailures += 1
            s.lastError = "health: \(reason)"
            let h = service.health
            let toRestart = h?.failuresToRestart ?? Int.max
            let toUnhealthy = h?.failuresToUnhealthy ?? Int.max

            if s.consecutiveHealthFailures >= toRestart && restartAllowed(service.restart) {
                await restart(containerName: containerName, service: service, state: &s, now: now)
            } else if s.consecutiveHealthFailures >= toUnhealthy {
                s.runState = .unhealthy
                s.healthDot = .red
            } else {
                // Degraded but under threshold; still running.
                s.runState = .running
                s.healthDot = .yellow
            }
        }
    }

    private func restartAllowed(_ policy: RestartPolicy) -> Bool {
        // A failing health check is a failure; `never` opts out, others restart.
        policy != .never
    }

    /// Stop-then-start a running-but-unhealthy container, honoring backoff.
    private func restart(containerName: String, service: Service,
                         state s: inout ServiceRuntimeState, now: Date) async {
        if s.backoff.isExhausted {
            s.runState = .failed
            s.healthDot = .red
            logger.error("\(containerName) exhausted restart attempts — marking failed")
            return
        }
        guard s.backoff.mayAct(now: now) else {
            s.runState = .unhealthy
            s.healthDot = .red
            return
        }
        s.backoff.recordAttempt(now: now)
        s.consecutiveHealthFailures = 0
        do {
            try await client.stop(name: containerName)
            try await client.start(name: containerName)
            // Count only once the restart actually succeeded, so a failed restart
            // doesn't pre-count and then get double-counted by the resurrection
            // path on a later tick.
            s.restartCount += 1
            s.runState = .starting
            s.healthDot = .yellow
            s.lastHealthCheckAt = nil // re-probe health promptly after a restart
            logger.warn("restarted \(containerName) (restart #\(s.restartCount), attempt \(s.backoff.attempts))")
        } catch {
            s.lastError = "restart: \(error)"
            s.runState = s.backoff.isExhausted ? .failed : .unhealthy
            s.healthDot = .red
            logger.error("restart \(containerName) failed: \(error)")
        }
    }

    // MARK: - test introspection

    /// Expose per-service backoff attempt count for tests.
    public func attemptCount(for containerName: String) -> Int {
        state[containerName]?.backoff.attempts ?? 0
    }
    public func restartCount(for containerName: String) -> Int {
        state[containerName]?.restartCount ?? 0
    }
}
