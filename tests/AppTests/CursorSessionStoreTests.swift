import AppKit
import AVFoundation
import XCTest
import EditorInteractionKit
@testable import DashHackathon

@MainActor
final class CursorSessionStoreTests: XCTestCase {
    func testCaptureIsSealedBeforeTranscriptAndNeverChangesAfterwards() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = TextDocumentState(text: "First selection\nSecond selection").snapshot
        let store = CursorSessionStore(root: root)
        let voice = MockVoiceCaptureService()
        let zero = SessionClock.nowNanoseconds()
        let id = try store.begin(document: document, ranges: [.init(location: 0, length: 0)], atNs: zero)
        await voice.start(id: id, clockOriginNs: zero)
        try store.observe(document: document, ranges: [.init(location: 0, length: 5)], source: "mouse", actionID: nil,
                          atNs: SessionClock.nowNanoseconds(), forceAction: false)
        try store.stop(atNs: SessionClock.nowNanoseconds())
        let folder = try XCTUnwrap(store.packages.first?.directory)
        let sealed = try Data(contentsOf: folder.appendingPathComponent("capture.json"))
        let count = store.events.count
        try store.observe(document: document, ranges: [.init(location: 16, length: 6)], source: "keyboard", actionID: nil,
                          atNs: SessionClock.nowNanoseconds(), forceAction: false)
        XCTAssertEqual(store.events.count, count)
        await voice.stop()
        store.attach(try XCTUnwrap(voice.latest), voice: voice)
        for _ in 0..<100 {
            if store.packages.first?.status != "Transcription pending" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.packages.first?.status, "Ready for handoff · alignment not run")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("capture.json")), sealed)
        let transcript = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("transcript.json"))) as? [String: Any]
        XCTAssertEqual(transcript?["recordingID"] as? String, id.uuidString)
        XCTAssertEqual(transcript?["alignmentStatus"] as? String, "not_available_forced_aligner_not_run")
        XCTAssertNil(transcript?["timestamps"])
    }

    func testAlignedAudioCompletesImmutablePackage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CursorSessionStore(root: root)
        let id = try store.begin(document: TextDocumentState(text: "pending pending").snapshot, ranges: [.init(location: 8, length: 7)], atNs: 1000)
        try store.stop(atNs: 1_001_000)
        let folder = try XCTUnwrap(store.packages.first?.directory)
        let capture = try Data(contentsOf: folder.appendingPathComponent("capture.json"))
        let audio = root.appendingPathComponent("input.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24))
        buffer.frameLength = 24
        try AVAudioFile(forWriting: audio, settings: format.settings).write(from: buffer)
        let result = root.appendingPathComponent("result.json")
        try Data(#"{"text":"confirmed","words":[["confirmed",0,1]]}"#.utf8).write(to: result)
        store.attachAlignedAudio(id, audioURL: audio, resultURL: result)
        XCTAssertEqual(store.packages.first?.status, "Ready · transcript aligned")
        XCTAssertEqual(store.packages.first?.transcript, "confirmed")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("capture.json")), capture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("alignment.json").path))
        XCTAssertEqual(store.packages.first?.assets.count, 1)
    }

    func testTranscriptContextRetainsSelectionsAfterClearAndAcrossRecordings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = TextDocumentState(text: "First selection\nSecond selection").snapshot
        let store = CursorSessionStore(root: root)
        let zero = SessionClock.nowNanoseconds()
        _ = try store.begin(document: document, ranges: [.init(location: 0, length: 0)], atNs: zero)
        try store.observe(document: document, ranges: [.init(location: 0, length: 15)], source: "mouse", actionID: nil, atNs: zero + 1_000_000, forceAction: false)
        try store.observe(document: document, ranges: [.init(location: 0, length: 15)], source: "mouse", actionID: nil, atNs: zero + 2_000_000, forceAction: true)
        try store.observe(document: document, ranges: [.init(location: 16, length: 16)], source: "mouse", actionID: nil, atNs: zero + 3_000_000, forceAction: false)
        try store.observe(document: document, ranges: [.init(location: 20, length: 0)], source: "mouse", actionID: nil, atNs: zero + 4_000_000, forceAction: false)
        try store.stop(atNs: zero + 5_000_000)
        let package = try XCTUnwrap(store.packages.first)
        XCTAssertEqual(package.selectedTextEvents.map { $0.after.ranges[0].selectedText }, ["First selection", "Second selection"])
        XCTAssertEqual(package.selectedTextEvents.map(\.timestampMs), [1, 3])
        _ = try store.begin(document: document, ranges: [.init(location: 16, length: 16)], atNs: zero + 6_000_000)
        try store.stop(atNs: zero + 7_000_000)
        XCTAssertEqual(store.packages[0].selectedTextEvents.count, 2)
        XCTAssertEqual(store.packages[1].selectedTextEvents.map { $0.after.ranges[0].selectedText }, ["Second selection"])
    }

    func testCursorFailureRemainsFailedAfterSavingPartialCapture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CursorSessionStore(root: root)
        let doc = TextDocumentState(text: "hello").snapshot
        let zero = SessionClock.nowNanoseconds()
        let id = try store.begin(document: doc, ranges: [.init(location: 0, length: 0)], atNs: zero)
        XCTAssertThrowsError(try store.observe(document: doc, ranges: [.init(location: 99, length: 1)], source: "mouse", actionID: nil, atNs: zero + 1, forceAction: false))
        XCTAssertTrue(store.progress(for: id).cursor.isFailure)
        try store.stop(atNs: zero + 2, cancelled: true)
        XCTAssertTrue(store.progress(for: id).cursor.isFailure)
        XCTAssertEqual(store.progress(for: id).audio, .cancelled)
        let manifest = try Data(contentsOf: store.packages[0].directory.appendingPathComponent("manifest.json"))
        XCTAssertTrue(String(decoding: manifest, as: UTF8.self).contains("captureProgress"))
    }

    func testCursorSaveFailureIsVisibleWithoutPackage() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = CursorSessionStore(root: file)
        let zero = SessionClock.nowNanoseconds()
        let id = try store.begin(document: TextDocumentState(text: "hello").snapshot, ranges: [.init(location: 0, length: 0)], atNs: zero)
        XCTAssertThrowsError(try store.stop(atNs: zero + 1))
        XCTAssertTrue(store.packages.isEmpty)
        XCTAssertTrue(store.latestProgress?.cursor.isFailure == true)
        XCTAssertEqual(store.progress(for: id).audio, .cancelled)
        XCTAssertFalse(store.isRecording)
        XCTAssertEqual(store.elapsedMs, 0.000001)
    }

    func testAudioFailureDoesNotTurnSavedCursorIntoFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CursorSessionStore(root: root)
        let zero = SessionClock.nowNanoseconds()
        let id = try store.begin(document: TextDocumentState(text: "hello").snapshot, ranges: [.init(location: 0, length: 0)], atNs: zero)
        try store.stop(atNs: zero + 1)
        store.audioFailed(id, message: "Audio packets were lost")
        XCTAssertEqual(store.progress(for: id).cursor, .succeeded)
        XCTAssertEqual(store.progress(for: id).audio, .failed("Audio packets were lost"))
    }

    func testInferenceFailureKeepsBothCaptureStagesSuccessful() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CursorSessionStore(root: root)
        let zero = SessionClock.nowNanoseconds()
        let id = try store.begin(document: TextDocumentState(text: "hello").snapshot, ranges: [.init(location: 0, length: 0)], atNs: zero)
        let voice = MockVoiceCaptureService()
        await voice.start(id: id, clockOriginNs: zero)
        try store.stop(atNs: SessionClock.nowNanoseconds())
        await voice.stop()
        // The base adapter rejects transcription, after valid mock audio has been saved.
        store.attach(try XCTUnwrap(voice.latest), voice: VoiceCaptureService())
        for _ in 0..<100 {
            if store.packages[0].status != "Transcription pending" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(store.packages[0].status.hasPrefix("Failed:"))
        XCTAssertEqual(store.progress(for: id).cursor, .succeeded)
        XCTAssertEqual(store.progress(for: id).audio, .succeeded)
    }

    func testRestartClearsSessionAndIgnoresLateTranscriptionFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CursorSessionStore(root: root)
        let zero = SessionClock.nowNanoseconds()
        let id = try store.begin(document: TextDocumentState(text: "hello").snapshot, ranges: [.init(location: 0, length: 5)], atNs: zero)
        let voice = MockVoiceCaptureService()
        await voice.start(id: id, clockOriginNs: zero)
        try store.stop(atNs: SessionClock.nowNanoseconds())
        await voice.stop()
        let pending = DeferredTranscriptionVoice()
        store.attach(try XCTUnwrap(voice.latest), voice: pending)
        for _ in 0..<100 {
            if pending.continuation != nil { break }
            await Task.yield()
        }
        let continuation = try XCTUnwrap(pending.continuation)
        let savedPackage = try XCTUnwrap(store.packages.first?.directory)
        try store.reset()
        voice.resetPresentation()
        continuation.resume(throwing: EditorServiceError("Late network failure"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(store.packages.isEmpty)
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertTrue(store.progressByID.isEmpty)
        XCTAssertNil(store.latestProgress)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.elapsedMs, 0)
        XCTAssertNil(voice.latest)
        XCTAssertNil(voice.activeClockOriginNs)
        XCTAssertEqual(voice.state, .idle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedPackage.appendingPathComponent("capture.json").path))
    }

    func testNativeEditorEmitsMultipleRangesAndSuppressesRenderChanges() {
        var received: [[DocumentTextRange]] = []
        let parent = NativeTextEditor(text: "first second third", ranges: [.init(location: 0, length: 0)]) { _, ranges, _, _, _, _ in
            received.append(ranges)
        }
        let coordinator = NativeTextEditor.Coordinator(parent)
        let view = CursorTrackingTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        view.string = parent.text
        view.delegate = coordinator
        view.selectedRanges = [NSValue(range: NSRange(location: 0, length: 5)), NSValue(range: NSRange(location: 13, length: 5))]
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view))
        XCTAssertEqual(received.last, [.init(location: 0, length: 5), .init(location: 13, length: 5)])
        let before = received.count
        coordinator.isRendering = true
        view.setSelectedRange(NSRange(location: 1, length: 0))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view))
        XCTAssertEqual(received.count, before)
    }
}


@MainActor
private final class DeferredTranscriptionVoice: VoiceCaptureService {
    var continuation: CheckedContinuation<TranscriptionOutput, Error>?
    override func transcribeSession(_ recording: Recording) async throws -> TranscriptionOutput {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
}
