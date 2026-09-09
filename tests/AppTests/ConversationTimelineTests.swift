import XCTest
@testable import DashHackathon

@MainActor
final class ConversationTimelineTests: XCTestCase {
    private func job(_ id: String, recording: UUID, state: String = "generating", outcome: String? = nil,
                     operation: String = "edit") -> EditingEngine.Job {
        EditingEngine.Job(id: id, recordingID: recording.uuidString, state: state,
            instruction: "Rewrite reference_1; preserve reference_2.", operation: operation,
            references: [
                .init(name: "reference_1", paragraph: "document", quote: "First passage", selection_id: "selection-a"),
                .init(name: "reference_2", paragraph: "document", quote: "Second passage", selection_id: "selection-b")
            ], context: ["read-only-document"], working_area: nil, outcome: outcome, answer: nil, error: nil)
    }

    func testLateFirstAssistantAppendsAfterSecondRecordingAndUpdatesStayInPlace() {
        let timeline = ConversationTimeline(), first = UUID(), second = UUID()
        let generation = timeline.generation
        timeline.receiveRecording(first, generation: generation)
        let firstUser = timeline.bubbles[0].id
        timeline.receiveRecording(second, generation: generation)
        timeline.receiveTasks([job("job-1", recording: first)], interpretations: [], generation: generation)
        XCTAssertEqual(timeline.bubbles.map(\.recordingID), [first, second, first])
        XCTAssertEqual(timeline.bubbles.map(\.role), [.user, .user, .assistant])
        let initialIDs = timeline.bubbles.map(\.id)
        timeline.receiveRecording(first, generation: generation)
        timeline.receiveTasks([job("job-1", recording: first, state: "completed", outcome: "committed")], interpretations: [], generation: generation)
        XCTAssertEqual(timeline.bubbles.map(\.id), initialIDs)
        XCTAssertEqual(timeline.bubbles[0].id, firstUser)
    }

    func testOutOfOrderTaskCompletionDoesNotChangeTaskPositions() {
        let timeline = ConversationTimeline(), id = UUID()
        timeline.receiveRecording(id, generation: timeline.generation)
        timeline.receiveTasks([job("first", recording: id), job("second", recording: id)], interpretations: [], generation: timeline.generation)
        let next = [job("second", recording: id, state: "completed", outcome: "committed"), job("first", recording: id)]
        timeline.receiveTasks(next, interpretations: [], generation: timeline.generation)
        XCTAssertEqual(timeline.orderedJobs(next, for: id).map(\.id), ["first", "second"])
        let complete = next.filter { TaskProgress(job: $0, rendered: $0.id == "second").isComplete }
        XCTAssertEqual(complete.map(\.id), ["second"])
        XCTAssertEqual(timeline.bubbles.count, 2)
    }

    func testRestartRejectsOldGenerationAndUnknownRecordingJobs() {
        let timeline = ConversationTimeline(), id = UUID()
        let old = timeline.generation
        timeline.receiveRecording(id, generation: old)
        timeline.reset()
        timeline.receiveRecording(id, generation: old)
        timeline.receiveTasks([job("old", recording: id)], interpretations: [], generation: old)
        timeline.receiveTasks([job("old", recording: id)], interpretations: [], generation: timeline.generation)
        XCTAssertTrue(timeline.bubbles.isEmpty)
    }

    func testAppliedRequiresNativeRenderAndNoopIsNotApplied() {
        let id = UUID()
        let committed = job("a", recording: id, state: "completed", outcome: "committed")
        XCTAssertEqual(TaskProgress(job: committed, rendered: false).label, "Applying to the document")
        XCTAssertFalse(TaskProgress(job: committed, rendered: false).isComplete)
        XCTAssertEqual(TaskProgress(job: committed, rendered: true).label, "Applied")
        let noop = job("b", recording: id, state: "completed", outcome: "noop")
        XCTAssertEqual(TaskProgress(job: noop, rendered: false).label, "No change needed")
        XCTAssertTrue(TaskProgress(job: noop, rendered: false).isComplete)
        XCTAssertEqual(TaskProgress(job: job("c", recording: id, state: "conflict"), rendered: false).kind, .failed)
        XCTAssertEqual(TaskProgress(job: job("d", recording: id, state: "cancelled"), rendered: false).kind, .cancelled)
    }

    func testReferenceMetadataAndDistinctNamesArePreserved() {
        let value = job("a", recording: UUID())
        XCTAssertEqual(value.references.map(\.quote), ["First passage", "Second passage"])
        XCTAssertEqual(value.references.map(\.selection_id), ["selection-a", "selection-b"])
        XCTAssertEqual(value.displayInstruction, "Rewrite passage 1; preserve passage 2.")
        XCTAssertFalse(value.references.map(\.quote).contains(value.context[0]))
    }

    func testClarificationCreatesOneStableAssistantEvenWithoutTasks() {
        let timeline = ConversationTimeline(), id = UUID()
        timeline.receiveRecording(id, generation: timeline.generation)
        let interpretation = EditingEngine.Interpretation(recordingID: id.uuidString, status: "interpreted",
            result: .init(needs_input: [.init(kind: "clarify", message: "Which passage did you mean?")]), error: nil)
        timeline.receiveTasks([], interpretations: [interpretation], generation: timeline.generation)
        let ids = timeline.bubbles.map(\.id)
        timeline.receiveTasks([], interpretations: [interpretation], generation: timeline.generation)
        XCTAssertEqual(timeline.bubbles.count, 2)
        XCTAssertEqual(timeline.bubbles.map(\.id), ids)
    }
}
