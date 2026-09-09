import XCTest
import EditorInteractionKit
@testable import DashHackathon

@MainActor
final class RequestLifecycleTests: XCTestCase {
    private final class TranscriptService: VoiceCaptureService {
        override func transcribe(_ recording: Recording, context: DocumentInteractionContext) async throws -> String {
            "Make it concise."
        }
    }

    private func recording(id: UUID = UUID()) -> VoiceCaptureService.Recording {
        .init(id: id, sessionID: 0, startedAt: Date(), duration: 1, packets: 50, sampleRate: 16000,
              rmsDBFS: -30, firmware: "TEST", audioURL: URL(fileURLWithPath: "/test.wav"), multichannelURL: URL(fileURLWithPath: "/test.wav"))
    }

    func testDuplicateDeliveryAppliesOnlyOnce() throws {
        var document = TextDocumentState(text: "Before. Target paragraph. After.")
        let adapter = EditorInteractionAdapter(snapshot: document.snapshot)
        let context = try DocumentInteractionContext(document: document.snapshot, selection: .init(location: 8, length: 17))
        let capture = recording()
        var applications = 0
        adapter.applyText = { text in
            applications += 1
            document.updateText(text)
            adapter.update(snapshot: document.snapshot, selection: .init(location: 0, length: 0))
        }
        adapter.accept(recording: capture, context: context, voice: TranscriptService())
        adapter.accept(recording: capture, context: context, voice: TranscriptService())
        XCTAssertEqual(adapter.jobs.count, 1)
        try adapter.applyResponse(requestID: capture.id, expectedRevision: 0, replacement: "Updated.")
        try adapter.applyResponse(requestID: capture.id, expectedRevision: 0, replacement: "Duplicate.")
        XCTAssertEqual(applications, 1)
        XCTAssertEqual(document.snapshot.text, "Before. Updated. After.")
        adapter.cancelAll()
    }

    func testCancelledAndLateResultDoesNotEditDocument() throws {
        let document = TextDocumentState(text: "Human text")
        let adapter = EditorInteractionAdapter(snapshot: document.snapshot)
        let context = try DocumentInteractionContext(document: document.snapshot, selection: .init(location: 0, length: 10))
        let capture = recording()
        var applications = 0
        adapter.applyText = { _ in applications += 1 }
        adapter.accept(recording: capture, context: context, voice: TranscriptService())
        adapter.cancel(capture.id)
        try adapter.applyResponse(requestID: capture.id, expectedRevision: 0, replacement: "Stale text")
        XCTAssertEqual(applications, 0)
        XCTAssertEqual(adapter.jobs.first?.status, "Cancelled")
        adapter.cancelAll()
    }

    func testStaleRevisionPreservesHumanEdit() throws {
        var document = TextDocumentState(text: "Delivery Tuesday")
        let adapter = EditorInteractionAdapter(snapshot: document.snapshot)
        let context = try DocumentInteractionContext(document: document.snapshot, selection: .init(location: 0, length: 16))
        let capture = recording()
        var applications = 0
        adapter.applyText = { _ in applications += 1 }
        adapter.accept(recording: capture, context: context, voice: TranscriptService())
        document.updateText("Delivery Thursday")
        adapter.update(snapshot: document.snapshot, selection: .init(location: 0, length: 0))
        XCTAssertThrowsError(try adapter.applyResponse(requestID: capture.id, expectedRevision: 0, replacement: "Delivery Tuesday"))
        XCTAssertEqual(applications, 0)
        XCTAssertEqual(adapter.snapshot.text, "Delivery Thursday")
        adapter.cancelAll()
    }

    func testResetCancelsPendingWorkAndCapture() async throws {
        let document = TextDocumentState(text: "Target")
        let adapter = EditorInteractionAdapter(snapshot: document.snapshot)
        let context = try DocumentInteractionContext(document: document.snapshot, selection: .init(location: 0, length: 6))
        let capture = recording()
        adapter.accept(recording: capture, context: context, voice: TranscriptService())
        adapter.cancelPending()
        XCTAssertTrue(adapter.jobs.allSatisfy(\.isFinished))
        let voice = MockVoiceCaptureService()
        await voice.start()
        await voice.cancelCapture()
        XCTAssertEqual(voice.state, .cancelled)
        XCTAssertNil(voice.latest)
        voice.resetPresentation()
        XCTAssertEqual(voice.state, .idle)
        XCTAssertNil(voice.latest)
        adapter.cancelAll()
    }
}
