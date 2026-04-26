import Testing
import Foundation
@testable import AgentSmithKit

/// Tests the scheduled-wake persistence path that lets reminders survive an app quit.
/// Three guarantees worth pinning down:
///   1. Round-trip: a wake encoded via `JSONEncoder` and decoded back is value-equal.
///   2. `restoreScheduledWakes` replaces the actor's list (not merge), with sort.
///   3. Wakes whose `wakeAt` is already in the past are kept on restore — the production
///      run loop will then fire them on the next iteration, which is the recovery path
///      for "the timer would have fired while the app was quit."
@Suite("Scheduled wake persistence", .serialized)
struct ScheduledWakePersistenceTests {

    @Test("ScheduledWake round-trips through JSON unchanged")
    func roundTripThroughJSON() throws {
        let recurrence = Recurrence.weekly(at: TimeOfDay(hour: 9, minute: 30), on: [.monday, .friday])
        let original = ScheduledWake(
            wakeAt: Date(timeIntervalSince1970: 800_000_000),
            instructions: "Tell Drew to take a break",
            taskID: UUID(uuidString: "00000000-0000-0000-0000-00000000ABCD"),
            recurrence: recurrence
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScheduledWake.self, from: encoded)
        #expect(decoded == original)
    }

    @Test("restoreScheduledWakes replaces the actor's list with a sorted copy")
    func restoreSortsAndReplaces() async {
        let actor = makeActor()
        // Seed two wakes via the public API so we know the actor sees something to replace.
        _ = await actor.scheduleWake(wakeAt: Date().addingTimeInterval(60), instructions: "old-1", taskID: nil, replacesID: nil)
        _ = await actor.scheduleWake(wakeAt: Date().addingTimeInterval(120), instructions: "old-2", taskID: nil, replacesID: nil)

        let now = Date()
        let restored: [ScheduledWake] = [
            ScheduledWake(wakeAt: now.addingTimeInterval(300), instructions: "later"),
            ScheduledWake(wakeAt: now.addingTimeInterval(30),  instructions: "soon")
        ]
        await actor.restoreScheduledWakes(restored)
        let listed = await actor.listScheduledWakes()
        #expect(listed.count == 2)
        #expect(listed.first?.instructions == "soon")
        #expect(listed.last?.instructions == "later")
    }

    @Test("restoreScheduledWakes keeps already-elapsed wakes so the run loop fires them")
    func keepsElapsedWakes() async {
        let actor = makeActor()
        let elapsed = ScheduledWake(
            wakeAt: Date().addingTimeInterval(-3600),
            instructions: "should-fire-on-next-loop"
        )
        await actor.restoreScheduledWakes([elapsed])
        let listed = await actor.listScheduledWakes()
        #expect(listed.count == 1)
        #expect(listed.first?.instructions == "should-fire-on-next-loop")
    }

    private func makeActor() -> AgentActor {
        let provider = MockLLMProvider(responses: [])
        let channel = MessageChannel()
        let taskStore = TaskStore()
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
