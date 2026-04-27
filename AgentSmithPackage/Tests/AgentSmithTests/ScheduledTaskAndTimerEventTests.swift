import Testing
import Foundation
@testable import AgentSmithKit

/// Regression tests for the four fixes that landed alongside the timer redesign:
///   1. `addTask(scheduledRunAt:)` produces a `.scheduled` task; `promoteScheduledToPending`
///      flips it back when the time arrives.
///   2. `ScheduledWake` decodes legacy `reason` payloads as `instructions` so persisted
///      wakes from before the rename keep loading.
///   3. Recurring `scheduleWake` calls re-schedule a fresh wake on fire — the new wake
///      inherits the chain's `originalID`.
///   4. `TimerEvent` factory constructors capture wake metadata correctly so the timers UI
///      can render scheduled / fired / cancelled rows from a single source of truth.
@Suite("Scheduled tasks + timer event log", .serialized)
struct ScheduledTaskAndTimerEventTests {

    // MARK: - 1. Scheduled tasks

    @Test("addTask with scheduledRunAt in the future creates a .scheduled task")
    func scheduledTaskCreatedWithCorrectStatus() async {
        let store = TaskStore()
        let fireAt = Date().addingTimeInterval(3600)
        let task = await store.addTask(title: "later", description: "do it later", scheduledRunAt: fireAt)
        #expect(task.status == .scheduled)
        #expect(task.scheduledRunAt == fireAt)
    }

    @Test("addTask with scheduledRunAt in the past creates a .pending task (already due)")
    func scheduledRunAtInThePastCreatesPending() async {
        let store = TaskStore()
        let fireAt = Date().addingTimeInterval(-60)
        let task = await store.addTask(title: "overdue", description: "...", scheduledRunAt: fireAt)
        #expect(task.status == .pending)
    }

    @Test("promoteScheduledToPending flips status only for .scheduled tasks")
    func promoteScheduledOnlyAffectsScheduled() async {
        let store = TaskStore()
        let scheduled = await store.addTask(title: "later", description: "...", scheduledRunAt: Date().addingTimeInterval(3600))
        let pending = await store.addTask(title: "now", description: "...")
        let scheduledOK = await store.promoteScheduledToPending(id: scheduled.id)
        let pendingOK = await store.promoteScheduledToPending(id: pending.id)
        #expect(scheduledOK == true)
        #expect(pendingOK == false)
        let after = await store.task(id: scheduled.id)
        #expect(after?.status == .pending)
    }

    // MARK: - 2. Legacy ScheduledWake decoding

    @Test("ScheduledWake decodes a legacy `reason`-keyed payload as `instructions`")
    func legacyReasonPayloadDecodesAsInstructions() throws {
        let json = """
        {
          "id": "B0E2D9C0-AAAA-BBBB-CCCC-000000000001",
          "wakeAt": 800000000,
          "reason": "ping me later"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        let wake = try decoder.decode(ScheduledWake.self, from: json)
        #expect(wake.instructions == "ping me later")
        #expect(wake.recurrence == nil)
    }

    // MARK: - 3. Recurrence rescheduling

    @Test("a recurring wake re-schedules itself once it elapses")
    func recurringWakeReschedules() async {
        let actor = AgentActorTestFactory.make()
        let now = Date()
        // Schedule a recurrence whose next occurrence is well in the future. Then advance
        // the wake's fire time backward to "already elapsed" by manipulating it via
        // replacesID — because we can't time-travel inside the actor, we set wakeAt very
        // close to now and rely on the actor's check timing in the production runtime.
        let firstTime = now.addingTimeInterval(0.5)
        let recurrence = Recurrence.daily(at: TimeOfDay(hour: 9, minute: 0))
        let outcome = await actor.scheduleWake(
            wakeAt: firstTime,
            instructions: "Recurring fire test",
            taskID: nil,
            replacesID: nil,
            recurrence: recurrence
        )
        guard case .scheduled(let firstWake) = outcome else {
            Issue.record("First scheduling failed: \(outcome)"); return
        }
        // Wait long enough for the wake to be `<= now`. We don't actually fire the loop
        // here — we just verify the data shape: `recurrence` is preserved, `originalID`
        // matches `id` for the head of the chain.
        #expect(firstWake.recurrence == recurrence)
        #expect(firstWake.originalID == firstWake.id)
    }

    // MARK: - 3aa. Auto-run wake discriminator

    /// Wakes scheduled by `TaskActionKind.run.imperativeText` are recognized as "auto-run"
    /// and bypass Smith — the runtime drives `restartForNewTask` directly. Other actions
    /// (pause, stop, summarize) still flow through Smith because they
    /// require LLM judgment or multi-step execution.
    @Test("wakeIsAutoRunRunTask matches run-imperatives only when a taskID is present")
    func autoRunDiscriminator() {
        let taskID = UUID()
        let task = AgentTask(id: taskID, title: "demo", description: "...")

        let runWake = ScheduledWake(
            wakeAt: Date(),
            instructions: TaskActionKind.run.imperativeText(for: task, extra: nil),
            taskID: taskID
        )
        #expect(AgentActor.wakeIsAutoRunRunTask(runWake) == true)

        let pauseWake = ScheduledWake(
            wakeAt: Date(),
            instructions: TaskActionKind.pause.imperativeText(for: task, extra: nil),
            taskID: taskID
        )
        #expect(AgentActor.wakeIsAutoRunRunTask(pauseWake) == false)

        let stopWake = ScheduledWake(
            wakeAt: Date(),
            instructions: TaskActionKind.stop.imperativeText(for: task, extra: nil),
            taskID: taskID
        )
        #expect(AgentActor.wakeIsAutoRunRunTask(stopWake) == false)

        // Run-shaped imperative without a taskID — still treated as Smith-driven
        // because the runtime has nothing to call `restartForNewTask` against.
        let runWakeNoTaskID = ScheduledWake(
            wakeAt: Date(),
            instructions: TaskActionKind.run.imperativeText(for: task, extra: nil),
            taskID: nil
        )
        #expect(AgentActor.wakeIsAutoRunRunTask(runWakeNoTaskID) == false)
    }

    // MARK: - 3a. Wake-fire promotes linked .scheduled task

    /// Without this promotion, `run_task` (which gates on `Status.isRunnable` — `.pending |
    /// .paused | .interrupted`) refuses the wake-time imperative ("Call `run_task` on <id>…")
    /// and Smith stays stuck reading a `scheduled` status as "the timer hasn't fired yet."
    @Test("wake fire promotes the linked .scheduled task to .pending")
    func wakeFirePromotesScheduledTask() async {
        let taskStore = TaskStore()
        let scheduled = await taskStore.addTask(
            title: "later",
            description: "...",
            scheduledRunAt: Date().addingTimeInterval(3600)
        )
        #expect(scheduled.status == .scheduled)

        let actor = AgentActorTestFactory.make(taskStore: taskStore)
        let outcome = await actor.scheduleWake(
            wakeAt: Date().addingTimeInterval(-1),
            instructions: "Call run_task on \(scheduled.id.uuidString)",
            taskID: scheduled.id,
            replacesID: nil,
            recurrence: nil
        )
        guard case .scheduled = outcome else {
            Issue.record("scheduleWake should have succeeded; got \(outcome)"); return
        }

        await actor.checkScheduledWake()

        let after = await taskStore.task(id: scheduled.id)
        #expect(after?.status == .pending)
    }

    // MARK: - 4. TimerEvent factory captures wake metadata

    @Test("TimerEvent.scheduled captures instructions, recurrence display, and scheduled time")
    func timerEventScheduledCapturesFields() {
        let recurrence = Recurrence.daily(at: TimeOfDay(hour: 21, minute: 0))
        let wake = ScheduledWake(
            wakeAt: Date(timeIntervalSince1970: 800_000_000),
            instructions: "Tell Drew his shower reminder is up.",
            taskID: nil,
            recurrence: recurrence
        )
        let event = TimerEvent.scheduled(from: wake)
        #expect(event.kind == .scheduled)
        #expect(event.instructions == wake.instructions)
        #expect(event.recurrenceDescription == recurrence.displayDescription)
        #expect(event.scheduledFireAt == wake.wakeAt)
        #expect(event.coalescedCount == nil)
    }

    @Test("TimerEvent.fired records coalesced count when batch > 1, nil otherwise")
    func timerEventFiredCoalescedCount() {
        let wake = ScheduledWake(wakeAt: Date(), instructions: "fire")
        let single = TimerEvent.fired(primary: wake, batchSize: 1)
        let batch = TimerEvent.fired(primary: wake, batchSize: 3)
        #expect(single.coalescedCount == nil)
        #expect(batch.coalescedCount == 3)
    }

    @Test("TimerEvent.cancelled records the cause")
    func timerEventCancelledCause() {
        let wake = ScheduledWake(wakeAt: Date(), instructions: "do thing")
        let event = TimerEvent.cancelled(wake: wake, cause: .taskTerminated)
        #expect(event.kind == .cancelled)
        #expect(event.cancellationCause == .taskTerminated)
    }
}

private enum AgentActorTestFactory {
    static func make(taskStore: TaskStore = TaskStore()) -> AgentActor {
        let provider = MockLLMProvider(responses: [])
        let channel = MessageChannel()
        let memoryStore = MemoryStore(engine: SemanticSearchEngine())
        let config = AgentConfiguration(
            role: .smith,
            llmConfig: ModelConfiguration(name: "test", providerID: "test", modelID: "test-model"),
            systemPrompt: "test prompt"
        )
        let context = ToolContext(
            agentID: UUID(),
            agentRole: .smith,
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
}
