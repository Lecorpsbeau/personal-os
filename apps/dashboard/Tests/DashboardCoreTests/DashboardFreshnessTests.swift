import Foundation
import Testing
@testable import DashboardCore

@Suite("Dashboard Freshness")
struct DashboardFreshnessTests {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    @Test("Non-finite freshness windows use safe defaults")
    func testNonFinitePolicyValues() {
        let policy = DashboardFreshnessPolicy(
            staleAfter: .infinity,
            liveWindow: .nan
        )
        #expect(policy.staleAfter == 10)
        #expect(policy.liveWindow == 2)
    }

    @Test("Freshness distinguishes live updated and stale data")
    func testDataFreshness() {
        let referenceDate = now
        let policy = DashboardFreshnessPolicy(
            staleAfter: 10,
            liveWindow: 2,
            now: { referenceDate }
        )

        #expect(policy.evaluate(snapshot(age: 1)) == .live)
        #expect(policy.evaluate(snapshot(age: 5)) == .updated(secondsAgo: 5))
        #expect(policy.evaluate(snapshot(age: 20)) == .stale)

        let stalePayload = RuntimeStatusPayload(
            version: 1,
            state: "running",
            updatedAt: now.addingTimeInterval(-20),
            cyclesExecuted: 1,
            lastCycleAt: now.addingTimeInterval(-20),
            lastSuccessfulPersistenceAt: now.addingTimeInterval(-20),
            lastMaintenanceAt: nil,
            fsUsage: nil
        )
        #expect(
            policy.evaluate(
                snapshot(age: 1, runtime: .stale(stalePayload))
            ) == .stale
        )
    }

    @Test("Freshness distinguishes runtime stopped failed and unknown")
    func testRuntimeFreshness() {
        let referenceDate = now
        let policy = DashboardFreshnessPolicy(
            staleAfter: 10,
            liveWindow: 2,
            now: { referenceDate }
        )

        #expect(policy.evaluate(snapshot(age: 1, state: "stopped")) == .runtimeStopped)
        #expect(policy.evaluate(snapshot(age: 1, state: "failed")) == .runtimeFailed)
        #expect(policy.evaluate(snapshot(age: 1, state: "stopping")) == .runtimeStopping)
        #expect(policy.evaluate(snapshot(age: 1, runtime: .unknown(reason: "missing"))) == .runtimeUnknown)
        #expect(policy.evaluate(snapshot(age: nil, state: "running")) == .noData)
    }

    private func snapshot(
        age: TimeInterval?,
        state: String = "running",
        runtime: RuntimeObservation? = nil
    ) -> DashboardSnapshot {
        let timestamp = age.map { now.addingTimeInterval(-$0) }
        let overview = DashboardOverview(
            latestTimestamp: timestamp,
            cpu: MetricSummary(current: timestamp == nil ? nil : 10),
            memory: .noData,
            diskRead: .noData,
            diskWrite: .noData,
            networkIn: .noData,
            networkOut: .noData,
            droppedEvents: nil
        )
        let observation: RuntimeObservation
        if let runtime {
            observation = runtime
        } else {
            let payload = RuntimeStatusPayload(
                version: 1,
                state: state,
                updatedAt: now,
                cyclesExecuted: 1,
                lastCycleAt: timestamp,
                lastSuccessfulPersistenceAt: timestamp,
                lastMaintenanceAt: nil,
                fsUsage: nil
            )
            observation = .current(payload)
        }
        return DashboardSnapshot(
            generatedAt: now,
            range: .oneHour,
            overview: overview,
            history: [],
            rankings: ProcessRankings(),
            events: [],
            runtime: observation,
            fsUsage: nil
        )
    }
}
