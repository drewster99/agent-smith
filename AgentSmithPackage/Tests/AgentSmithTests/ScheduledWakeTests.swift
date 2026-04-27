import Testing
import Foundation
@testable import AgentSmithKit

/// Tests for `AgentActor`'s scheduled-wake surface — the primitive used by Smith's
/// `schedule_wake` / `cancel_wake` / `list_scheduled_wakes` tools and the cross-actor
/// `cancelWakesForTask` cleanup hook.
///
/// These tests construct an actor without starting its run loop so the wake state
/// machine can be exercised in isolation. Behavioral guarantees covered:
///   - Multiple wakes can coexist at any time gap (no minimum spacing).
///   - `replacesID` removes the named wake before scheduling, atomically.
///   - `cancelWake(id:)` returns true only when something was actually removed.
///   - `cancelWakesForTask(_:)` returns the cancelled wakes' IDs and only
///     touches wakes belonging to that task.
///   - `listScheduledWakes()` returns the wakes sorted ascending by `wakeAt`.
///   - Empty / whitespace `reason` is rejected via `.error(...)`, not `.scheduled`.
@Suite("AgentActor scheduled wakes", .serialized)
struct ScheduledWakeTests {

    // MARK: - Helpers

    /// Builds a fresh `AgentActor` with stub dependencies. The actor is constructed
    /// but never started, so the run-loop side-effects don't fire — the scheduled-wake
    /// surface is fully exercisable from public methods alone.
    private static func makeActor(role: AgentRole = .smith) -> AgentActor {
        let provider = MockLLMProvider(responses: [])
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let memoryStore = MemoryStore(engine: SemanticSearchEngine())
        let config = AgentConfiguration(
            role: role,
            llmConfig: ModelConfiguration(
                name: "test", providerID: "test", modelID: "test-model"
            ),
            systemPrompt: "test prompt"
        )
        let context = ToolContext(
            agentID: UUID(),
            agentRole: role,
            channel: channel,
            taskStore: taskStore,
            spawnBrown: { nil },
            terminateAgent: { _, _ in false },
            abort: { _, _ in },
            agentRoleForID: { _ in nil },
            memoryStore: memoryStore,
            setToolExecutionStatus: { _, _ in },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )
        return AgentActor(
            configuration: config,
            provider: provider,
            tools: [],
            toolContext: context
        )
    }

    /// Returns a wake from a `ScheduleWakeOutcome.scheduled(...)` outcome, failing
    /// the test if the outcome is anything else.
    private static func scheduledOrFail(_ outcome: ScheduleWakeOutcome, comment: Comment) -> ScheduledWake? {
        switch outcome {
        case .scheduled(let wake):
            return wake
        case .error(let message):
            Issue.record("\(comment) — got error: \(message)")
            return nil
        }
    }

    // MARK: - Basic scheduling

    @Test("schedule_wake returns .scheduled with the requested time and reason")
    func basicSchedule() async {
        let actor = Self.makeActor()
        let when = Date().addingTimeInterval(60)
        let outcome = await actor.scheduleWake(
            wakeAt: when, instructions: "ping me", taskID: nil, replacesID: nil
        )
        guard let wake = Self.scheduledOrFail(outcome, comment: "first scheduling should succeed") else { return }
        #expect(wake.instructions == "ping me")
        #expect(wake.wakeAt == when)
        #expect(wake.taskID == nil)
    }

    @Test("schedule_wake rejects empty reason")
    func emptyReasonRejected() async {
        let actor = Self.makeActor()
        let outcome = await actor.scheduleWake(
            wakeAt: Date().addingTimeInterval(60), instructions: "", taskID: nil, replacesID: nil
        )
        switch outcome {
        case .scheduled:
            Issue.record("empty reason should have been rejected")
        case .error(let message):
            #expect(message.contains("instructions"))
        }
    }

    @Test("schedule_wake rejects whitespace-only reason")
    func whitespaceReasonRejected() async {
        let actor = Self.makeActor()
        let outcome = await actor.scheduleWake(
            wakeAt: Date().addingTimeInterval(60), instructions: "   \n\t  ", taskID: nil, replacesID: nil
        )
        switch outcome {
        case .scheduled:
            Issue.record("whitespace-only reason should have been rejected")
        case .error:
            break
        }
    }

    // MARK: - Coexistence (no spacing minimum)

    @Test("multiple wakes within seconds of each other coexist (no 60s minimum)")
    func wakesCanShareNearTimes() async {
        let actor = Self.makeActor()
        let baseTime = Date().addingTimeInterval(60)

        let outcome1 = await actor.scheduleWake(
            wakeAt: baseTime, instructions: "first", taskID: nil, replacesID: nil
        )
        let outcome2 = await actor.scheduleWake(
            wakeAt: baseTime.addingTimeInterval(5), instructions: "second", taskID: nil, replacesID: nil
        )
        let outcome3 = await actor.scheduleWake(
            wakeAt: baseTime.addingTimeInterval(30), instructions: "third", taskID: nil, replacesID: nil
        )
        _ = Self.scheduledOrFail(outcome1, comment: "wake 1")
        _ = Self.scheduledOrFail(outcome2, comment: "wake 2 (5s later)")
        _ = Self.scheduledOrFail(outcome3, comment: "wake 3 (30s later)")

        let listed = await actor.listScheduledWakes()
        #expect(listed.count == 3)
        // listScheduledWakes returns in ascending wakeAt order.
        #expect(listed[0].instructions == "first")
        #expect(listed[1].instructions == "second")
        #expect(listed[2].instructions == "third")
    }

    @Test("wakes scheduled at the exact same time both stick")
    func wakesAtSameTimeCoexist() async {
        let actor = Self.makeActor()
        let when = Date().addingTimeInterval(120)

        let r1 = await actor.scheduleWake(wakeAt: when, instructions: "a", taskID: nil, replacesID: nil)
        let r2 = await actor.scheduleWake(wakeAt: when, instructions: "b", taskID: nil, replacesID: nil)
        _ = Self.scheduledOrFail(r1, comment: "wake at time")
        _ = Self.scheduledOrFail(r2, comment: "second wake at same time")

        let listed = await actor.listScheduledWakes()
        #expect(listed.count == 2)
    }

    // MARK: - replacesID semantics

    @Test("replacesID removes the named wake before scheduling the new one")
    func replacesRemovesPriorWake() async {
        let actor = Self.makeActor()
        let firstOutcome = await actor.scheduleWake(
            wakeAt: Date().addingTimeInterval(60), instructions: "old reason", taskID: nil, replacesID: nil
        )
        guard let firstWake = Self.scheduledOrFail(firstOutcome, comment: "initial") else { return }

        let secondOutcome = await actor.scheduleWake(
            wakeAt: Date().addingTimeInterval(120), instructions: "new reason", taskID: nil, replacesID: firstWake.id
        )
        _ = Self.scheduledOrFail(secondOutcome, comment: "replacement")

        let listed = await actor.listScheduledWakes()
        #expect(listed.count == 1)
        #expect(listed.first?.instructions == "new reason")
        #expect(listed.contains { $0.id == firstWake.id } == false)
    }

    @Test("replacesID with an unknown id is a no-op (still schedules the new wake)")
    func replacesUnknownIdIsNoop() async {
        let actor = Self.makeActor()
        let outcome = await actor.scheduleWake(
            wakeAt: Date().addingTimeInterval(60),
            instructions: "fresh",
            taskID: nil,
            replacesID: UUID()
        )
        _ = Self.scheduledOrFail(outcome, comment: "replacement of unknown id")
        let listed = await actor.listScheduledWakes()
        #expect(listed.count == 1)
    }

    // MARK: - Cancellation

    @Test("cancelWake by id returns true exactly once for an existing wake")
    func cancelWakeReturnsTrueOnce() async {
        let actor = Self.makeActor()
        let outcome = await actor.scheduleWake(
            wakeAt: Date().addingTimeInterval(60), instructions: "x", taskID: nil, replacesID: nil
        )
        guard let wake = Self.scheduledOrFail(outcome, comment: "set up") else { return }

        let firstCancel = await actor.cancelWake(id: wake.id)
        #expect(firstCancel == true)
        let secondCancel = await actor.cancelWake(id: wake.id)
        #expect(secondCancel == false)
    }

    @Test("cancelWake by unknown id returns false and leaves other wakes intact")
    func cancelUnknownIdReturnsFalse() async {
        let actor = Self.makeActor()
        let kept = await actor.scheduleWake(
            wakeAt: Date().addingTimeInterval(60), instructions: "kept", taskID: nil, replacesID: nil
        )
        _ = Self.scheduledOrFail(kept, comment: "kept wake")

        let result = await actor.cancelWake(id: UUID())
        #expect(result == false)
        let listed = await actor.listScheduledWakes()
        #expect(listed.count == 1)
    }

    @Test("cancelWakesForTask returns only the cancelled IDs and leaves others")
    func cancelWakesForTaskScopedCorrectly() async {
        let actor = Self.makeActor()
        let taskA = UUID()
        let taskB = UUID()

        let a1 = await actor.scheduleWake(
            wakeAt: Date().addingTimeInterval(30), instructions: "a-1", taskID: taskA, replacesID: nil
        )
        let a2 = await actor.scheduleWake(
            wakeAt: Date().addingTimeInterval(60), instructions: "a-2", taskID: taskA, replacesID: nil
        )
        let b1 = await actor.scheduleWake(
            wakeAt: Date().addingTimeInterval(45), instructions: "b-1", taskID: taskB, replacesID: nil
        )
        let untagged = await actor.scheduleWake(
            wakeAt: Date().addingTimeInterval(90), instructions: "u", taskID: nil, replacesID: nil
        )
        guard let aw1 = Self.scheduledOrFail(a1, comment: "a-1"),
              let aw2 = Self.scheduledOrFail(a2, comment: "a-2"),
              let _ = Self.scheduledOrFail(b1, comment: "b-1"),
              let _ = Self.scheduledOrFail(untagged, comment: "untagged") else { return }

        let cancelledIDs = await actor.cancelWakesForTask(taskA)
        #expect(Set(cancelledIDs) == Set([aw1.id, aw2.id]))

        let listed = await actor.listScheduledWakes()
        let listedIDs = Set(listed.map { $0.id })
        #expect(listedIDs.contains(aw1.id) == false)
        #expect(listedIDs.contains(aw2.id) == false)
        #expect(listed.count == 2)
        #expect(listed.contains { $0.instructions == "b-1" })
        #expect(listed.contains { $0.instructions == "u" })
    }

    @Test("cancelWakesForTask on a task with no wakes returns empty")
    func cancelWakesForTaskEmpty() async {
        let actor = Self.makeActor()
        let cancelled = await actor.cancelWakesForTask(UUID())
        #expect(cancelled.isEmpty)
    }

    @Test("cancelWakesForTask preserves wakes flagged survivesTaskTermination")
    func cancelWakesForTaskPreservesSurvivors() async {
        let actor = Self.makeActor()
        let taskID = UUID()

        let cancellable = await actor.scheduleWake(
            wakeAt: Date().addingTimeInterval(30),
            instructions: "pause",
            taskID: taskID,
            replacesID: nil,
            survivesTaskTermination: false
        )
        let surviving1 = await actor.scheduleWake(
            wakeAt: Date().addingTimeInterval(60),
            instructions: "run-again-1",
            taskID: taskID,
            replacesID: nil,
            survivesTaskTermination: true
        )
        let surviving2 = await actor.scheduleWake(
            wakeAt: Date().addingTimeInterval(90),
            instructions: "run-again-2",
            taskID: taskID,
            replacesID: nil,
            survivesTaskTermination: true
        )
        guard let cw = Self.scheduledOrFail(cancellable, comment: "cancellable"),
              let sw1 = Self.scheduledOrFail(surviving1, comment: "surviving-1"),
              let sw2 = Self.scheduledOrFail(surviving2, comment: "surviving-2") else { return }

        let cancelledIDs = await actor.cancelWakesForTask(taskID)
        #expect(cancelledIDs == [cw.id])

        let listed = await actor.listScheduledWakes()
        let listedIDs = Set(listed.map { $0.id })
        #expect(listedIDs == Set([sw1.id, sw2.id]))
    }

    // MARK: - Listing order

    @Test("listScheduledWakes returns wakes sorted ascending by wakeAt regardless of insertion order")
    func listingIsSortedAscending() async {
        let actor = Self.makeActor()

        // Schedule out-of-order: 60s, 10s, 120s, 30s.
        let r1 = await actor.scheduleWake(wakeAt: Date().addingTimeInterval(60),  instructions: "60",  taskID: nil, replacesID: nil)
        let r2 = await actor.scheduleWake(wakeAt: Date().addingTimeInterval(10),  instructions: "10",  taskID: nil, replacesID: nil)
        let r3 = await actor.scheduleWake(wakeAt: Date().addingTimeInterval(120), instructions: "120", taskID: nil, replacesID: nil)
        let r4 = await actor.scheduleWake(wakeAt: Date().addingTimeInterval(30),  instructions: "30",  taskID: nil, replacesID: nil)
        _ = (r1, r2, r3, r4)

        let listed = await actor.listScheduledWakes()
        let reasons = listed.map { $0.instructions }
        #expect(reasons == ["10", "30", "60", "120"])
    }
}
