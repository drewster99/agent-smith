import Testing
import Foundation
@testable import AgentSmithKit

/// Tests for `ToolExecutionTracker` — the actor-isolated FIFO ring buffer that
/// records whether tool calls succeeded or failed after security approval.
///
/// The tracker is small (20-entry cap) and append-only from the call site's
/// perspective, but two behaviors are load-bearing for SecurityEvaluator's
/// recent-tool-calls annotations:
///   1. Re-recording the same `toolCallID` overwrites the prior status (so
///      the most recent execution wins, not the first).
///   2. Past the 20-entry cap, oldest entries are evicted in FIFO order.
@Suite("ToolExecutionTracker — ring buffer")
struct ToolExecutionTrackerRingBufferTests {

    @Test("recording a never-seen id stores succeeded=true")
    func recordsSuccess() async {
        let tracker = ToolExecutionTracker()
        await tracker.recordExecutionStatus(toolCallID: "call_a", succeeded: true)
        #expect(await tracker.hasSucceeded(toolCallID: "call_a") == true)
        #expect(await tracker.hasFailed(toolCallID: "call_a") == false)
    }

    @Test("recording a never-seen id stores succeeded=false")
    func recordsFailure() async {
        let tracker = ToolExecutionTracker()
        await tracker.recordExecutionStatus(toolCallID: "call_b", succeeded: false)
        #expect(await tracker.hasFailed(toolCallID: "call_b") == true)
        #expect(await tracker.hasSucceeded(toolCallID: "call_b") == false)
    }

    @Test("an unrecorded id returns nil from getExecutionStatus")
    func unrecordedReturnsNil() async {
        let tracker = ToolExecutionTracker()
        #expect(await tracker.getExecutionStatus(toolCallID: "missing") == nil)
        #expect(await tracker.hasSucceeded(toolCallID: "missing") == false)
        #expect(await tracker.hasFailed(toolCallID: "missing") == false)
    }

    @Test("re-recording the same id overwrites the prior status")
    func rewriteWins() async {
        let tracker = ToolExecutionTracker()
        await tracker.recordExecutionStatus(toolCallID: "call_x", succeeded: true)
        await tracker.recordExecutionStatus(toolCallID: "call_x", succeeded: false)
        // Most recent write wins — the same call ID can't simultaneously have
        // succeeded and failed.
        #expect(await tracker.hasFailed(toolCallID: "call_x") == true)
        #expect(await tracker.hasSucceeded(toolCallID: "call_x") == false)
    }

    @Test("past the cap, oldest entries are evicted in FIFO order")
    func capEnforced() async {
        let tracker = ToolExecutionTracker()
        // Write 25 distinct ids. The cap is 20, so the first 5 must have been evicted.
        for i in 0..<25 {
            await tracker.recordExecutionStatus(toolCallID: "id_\(i)", succeeded: true)
        }
        // First 5 evicted: nil.
        for i in 0..<5 {
            #expect(
                await tracker.getExecutionStatus(toolCallID: "id_\(i)") == nil,
                "id_\(i) should have been evicted"
            )
        }
        // Last 20 retained.
        for i in 5..<25 {
            #expect(
                await tracker.getExecutionStatus(toolCallID: "id_\(i)") == true,
                "id_\(i) should still be present"
            )
        }
    }

    @Test("re-recording an existing id keeps it in the ring (does not double-count toward cap)")
    func rewriteDoesNotConsumeCapacity() async {
        let tracker = ToolExecutionTracker()
        // Fill exactly to capacity with 20 distinct ids.
        for i in 0..<20 {
            await tracker.recordExecutionStatus(toolCallID: "id_\(i)", succeeded: true)
        }
        // Re-record an existing id. Cap is 20; this MUST NOT evict id_0.
        await tracker.recordExecutionStatus(toolCallID: "id_5", succeeded: false)
        #expect(await tracker.getExecutionStatus(toolCallID: "id_0") == true)
        #expect(await tracker.getExecutionStatus(toolCallID: "id_5") == false)
        // Now write a 21st distinct id — id_0 (the oldest) must be evicted, but
        // id_1 stays since it's now the oldest distinct entry.
        await tracker.recordExecutionStatus(toolCallID: "id_new", succeeded: true)
        #expect(await tracker.getExecutionStatus(toolCallID: "id_0") == nil)
        #expect(await tracker.getExecutionStatus(toolCallID: "id_1") == true)
        #expect(await tracker.getExecutionStatus(toolCallID: "id_new") == true)
    }
}

/// Tests that AgentActor records execution status in the gap-paths the recent
/// review found uncovered: the unknown-tool branches (lifecycle and sequential
/// approval) and the cancelled-call placeholder loop. The actor itself isn't
/// directly testable in isolation — it expects a fully-wired runtime — but the
/// tracker is the observable side-effect, and we can test it through the
/// shared closures that AgentActor uses to communicate with the runtime.
///
/// Concretely: AgentActor calls `await toolContext.setToolExecutionStatus(id, false)`
/// on each gap path. We can't easily unit-test the AgentActor branches because
/// they require a live LLM provider; the integration sits in
/// `SecurityEvaluatorTests` which exercises the prompt rendering for tracked
/// outcomes. The dedicated tests here exercise the tracker directly so a
/// regression in *its* contract surfaces here, while branch-coverage in
/// AgentActor is covered by the integration tests' fixture-style assertions.
@Suite("ToolExecutionTracker — semantic conveniences")
struct ToolExecutionTrackerSemanticsTests {

    @Test("hasSucceeded and hasFailed never both return true for the same id")
    func mutuallyExclusive() async {
        let tracker = ToolExecutionTracker()
        await tracker.recordExecutionStatus(toolCallID: "call", succeeded: true)
        let succeeded = await tracker.hasSucceeded(toolCallID: "call")
        let failed = await tracker.hasFailed(toolCallID: "call")
        #expect(succeeded != failed)

        await tracker.recordExecutionStatus(toolCallID: "call", succeeded: false)
        let succeeded2 = await tracker.hasSucceeded(toolCallID: "call")
        let failed2 = await tracker.hasFailed(toolCallID: "call")
        #expect(succeeded2 != failed2)
    }

    @Test("hasSucceeded returns false for an unrecorded id (does not throw or crash)")
    func unrecordedHasSucceededIsFalse() async {
        let tracker = ToolExecutionTracker()
        #expect(await tracker.hasSucceeded(toolCallID: "never_seen") == false)
        #expect(await tracker.hasFailed(toolCallID: "never_seen") == false)
    }
}
