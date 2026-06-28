import XCTest
@testable import QuayCore

final class ReconcilerTests: XCTestCase {

    private func makeReconciler(client: MockContainerClient, health: MockHealthChecker,
                                maxAttempts: Int = 10) -> Reconciler {
        Reconciler(client: client, health: health,
                   status: TestFixtures.tempStatusStore(),
                   logger: TestFixtures.silentLogger(),
                   backoffBase: 2, backoffCap: 300, backoffMaxAttempts: maxAttempts)
    }

    func testCreatesWhenMissing() async {
        let client = MockContainerClient()
        client.listResult = [] // nothing exists
        let r = makeReconciler(client: client, health: MockHealthChecker(.healthy))

        let snap = await r.tick(stacks: [TestFixtures.stack()], now: Date())

        XCTAssertEqual(client.runs.count, 1)
        let spec = client.runs[0]
        XCTAssertEqual(spec.name, TestFixtures.containerName)
        XCTAssertEqual(spec.image, "img:latest")
        XCTAssertEqual(spec.env, ["A=B"])
        XCTAssertEqual(spec.publish.first?.host, 3000)
        XCTAssertTrue(client.volumes.contains("data"), "declared volume ensured")
        XCTAssertEqual(snap.stacks.first?.services.first?.state, .starting)
    }

    func testStartsStoppedWhenAlways() async {
        let client = MockContainerClient()
        client.listResult = [ContainerSummary(name: TestFixtures.containerName, state: .stopped, exitCode: 0)]
        let r = makeReconciler(client: client, health: MockHealthChecker(.healthy))

        await r.tick(stacks: [TestFixtures.stack(restart: .always)], now: Date())

        XCTAssertEqual(client.starts, [TestFixtures.containerName])
        XCTAssertTrue(client.runs.isEmpty)
    }

    func testNeverDoesNotStartStopped() async {
        let client = MockContainerClient()
        client.listResult = [ContainerSummary(name: TestFixtures.containerName, state: .stopped, exitCode: 1)]
        let r = makeReconciler(client: client, health: MockHealthChecker(.healthy))

        let snap = await r.tick(stacks: [TestFixtures.stack(restart: .never)], now: Date())

        XCTAssertTrue(client.starts.isEmpty)
        XCTAssertEqual(snap.stacks.first?.services.first?.state, .stopped)
    }

    func testOnFailureStartsOnNonzeroExitOnly() async {
        // exit 0 -> clean stop, leave it.
        let cleanClient = MockContainerClient()
        cleanClient.listResult = [ContainerSummary(name: TestFixtures.containerName, state: .stopped, exitCode: 0)]
        let r1 = makeReconciler(client: cleanClient, health: MockHealthChecker(.healthy))
        await r1.tick(stacks: [TestFixtures.stack(restart: .onFailure)], now: Date())
        XCTAssertTrue(cleanClient.starts.isEmpty, "clean exit should not restart")

        // exit 1 -> failure, restart.
        let failClient = MockContainerClient()
        failClient.listResult = [ContainerSummary(name: TestFixtures.containerName, state: .stopped, exitCode: 1)]
        let r2 = makeReconciler(client: failClient, health: MockHealthChecker(.healthy))
        await r2.tick(stacks: [TestFixtures.stack(restart: .onFailure)], now: Date())
        XCTAssertEqual(failClient.starts, [TestFixtures.containerName])
    }

    func testHealthyRunningMarksHealthy() async {
        let client = MockContainerClient()
        client.listResult = [ContainerSummary(name: TestFixtures.containerName, state: .running)]
        let r = makeReconciler(client: client, health: MockHealthChecker(.healthy))

        let snap = await r.tick(stacks: [TestFixtures.stack()], now: Date())

        XCTAssertTrue(client.runs.isEmpty)
        XCTAssertTrue(client.starts.isEmpty)
        XCTAssertEqual(snap.stacks.first?.services.first?.state, .healthy)
        XCTAssertEqual(snap.stacks.first?.services.first?.health, .green)
    }

    func testUnknownHealthTreatedHealthy() async {
        let client = MockContainerClient()
        client.listResult = [ContainerSummary(name: TestFixtures.containerName, state: .running)]
        let r = makeReconciler(client: client, health: MockHealthChecker(.notApplicable))

        let snap = await r.tick(stacks: [TestFixtures.stack()], now: Date())

        XCTAssertEqual(snap.stacks.first?.services.first?.state, .running)
        XCTAssertTrue(client.stops.isEmpty, "must not churn services without health")
    }

    func testRestartsAfterConsecutiveHealthFailures() async {
        let client = MockContainerClient()
        client.listResult = [ContainerSummary(name: TestFixtures.containerName, state: .running)]
        let r = makeReconciler(client: client, health: MockHealthChecker(.unhealthy("HTTP 500")))
        let stack = TestFixtures.stack(failuresToRestart: 2, failuresToUnhealthy: 1)

        var now = Date()
        // First failure: below restart threshold, no restart yet.
        await r.tick(stacks: [stack], now: now)
        XCTAssertTrue(client.stops.isEmpty)
        // Second failure: hits threshold -> stop+start.
        now = now.addingTimeInterval(1000)
        await r.tick(stacks: [stack], now: now)
        XCTAssertEqual(client.stops, [TestFixtures.containerName])
        XCTAssertEqual(client.starts, [TestFixtures.containerName])
        let count = await r.restartCount(for: TestFixtures.containerName)
        XCTAssertEqual(count, 1)
    }

    func testHealthCheckThrottledToInterval() async {
        // interval_seconds = 30; reconcile ticks come faster. The probe should
        // only fire once per interval, not once per tick.
        let client = MockContainerClient()
        client.listResult = [ContainerSummary(name: TestFixtures.containerName, state: .running)]
        let health = MockHealthChecker(.healthy)
        let r = makeReconciler(client: client, health: health)
        let stack = TestFixtures.stack() // intervalSeconds: 30

        let t0 = Date(timeIntervalSince1970: 0)
        await r.tick(stacks: [stack], now: t0)                       // probes (first time)
        await r.tick(stacks: [stack], now: t0.addingTimeInterval(5)) // within interval -> skip
        await r.tick(stacks: [stack], now: t0.addingTimeInterval(20))// within interval -> skip
        XCTAssertEqual(health.checkCount, 1, "must not re-probe inside the interval")

        await r.tick(stacks: [stack], now: t0.addingTimeInterval(31))// interval elapsed -> probe
        XCTAssertEqual(health.checkCount, 2, "probes again once the interval elapses")
    }

    func testInitialStartIsNotARestart() async {
        let client = MockContainerClient()
        client.listResult = [] // missing on first sight
        let r = makeReconciler(client: client, health: MockHealthChecker(.healthy))

        await r.tick(stacks: [TestFixtures.stack()], now: Date(timeIntervalSince1970: 0))

        let count = await r.restartCount(for: TestFixtures.containerName)
        XCTAssertEqual(count, 0, "the very first bring-up is not a restart")
    }

    func testResurrectionAfterRunningCountsAsRestart() async {
        let client = MockContainerClient()
        let r = makeReconciler(client: client, health: MockHealthChecker(.healthy))
        let stack = TestFixtures.stack()

        // Tick 1: container is up and healthy — quayd records it as having run.
        client.listResult = [ContainerSummary(name: TestFixtures.containerName, state: .running)]
        await r.tick(stacks: [stack], now: Date(timeIntervalSince1970: 0))
        var count = await r.restartCount(for: TestFixtures.containerName)
        XCTAssertEqual(count, 0, "a healthy running container is not a restart")

        // Tick 2: the container has vanished — quayd recreates it. THAT is a restart
        // (the bug this fixes: resurrections used to not be counted).
        client.listResult = []
        await r.tick(stacks: [stack], now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(client.runs.count, 1, "quayd recreated the missing container")
        count = await r.restartCount(for: TestFixtures.containerName)
        XCTAssertEqual(count, 1, "resurrecting a container that had been up counts as a restart")
    }

    func testOrphanLoggedNotRemoved() async {
        let client = MockContainerClient()
        client.listResult = [
            ContainerSummary(name: "quay-old-orphan", state: .running),
            ContainerSummary(name: TestFixtures.containerName, state: .running),
        ]
        let r = makeReconciler(client: client, health: MockHealthChecker(.healthy))

        let snap = await r.tick(stacks: [TestFixtures.stack()], now: Date())

        XCTAssertEqual(snap.orphans, ["quay-old-orphan"])
        XCTAssertTrue(client.stops.isEmpty, "orphans are never stopped or removed")
    }

    func testBackoffExhaustionMarksFailed() async {
        let client = MockContainerClient()
        client.listResult = []      // always missing
        client.runShouldThrow = true // every create fails
        let r = makeReconciler(client: client, health: MockHealthChecker(.healthy), maxAttempts: 3)
        let stack = TestFixtures.stack()

        var now = Date(timeIntervalSince1970: 0)
        var lastState: ServiceRunState?
        for _ in 0..<6 {
            let snap = await r.tick(stacks: [stack], now: now)
            lastState = snap.stacks.first?.services.first?.state
            now = now.addingTimeInterval(1000) // jump past cooldown each time
        }
        XCTAssertEqual(lastState, .failed)
        XCTAssertEqual(client.runs.count, 3, "stops trying after maxAttempts")
    }

    func testRuntimeUnavailableProducesClearStatus() async {
        let client = MockContainerClient()
        client.available = false
        let r = makeReconciler(client: client, health: MockHealthChecker(.healthy))

        let snap = await r.tick(stacks: [TestFixtures.stack()], now: Date())

        XCTAssertFalse(snap.containerRuntimeAvailable)
        XCTAssertEqual(snap.aggregate, .red)
        XCTAssertTrue(client.runs.isEmpty, "no actions taken without a runtime")
        XCTAssertNotNil(snap.note)
    }

    func testBackoffCooldownDelaysSecondAttempt() async {
        let client = MockContainerClient()
        client.listResult = []
        client.runShouldThrow = true
        let r = makeReconciler(client: client, health: MockHealthChecker(.healthy))
        let stack = TestFixtures.stack()

        let now = Date(timeIntervalSince1970: 0)
        await r.tick(stacks: [stack], now: now)
        XCTAssertEqual(client.runs.count, 1)
        // Immediately again — still in cooldown, no new attempt.
        await r.tick(stacks: [stack], now: now.addingTimeInterval(1))
        XCTAssertEqual(client.runs.count, 1, "cooldown blocks immediate retry")
        // After the 2s window, a new attempt fires.
        await r.tick(stacks: [stack], now: now.addingTimeInterval(3))
        XCTAssertEqual(client.runs.count, 2)
    }
}
