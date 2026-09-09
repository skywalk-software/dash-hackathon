import XCTest
@testable import EditorInteractionKit

final class CursorRecordingTests: XCTestCase {
    func testRequestedLineColumnExamplesAndExactStopBoundary() throws {
        let document = TextDocumentState(text: Array(repeating: String(repeating: "x", count: 70), count: 10).joined(separator: "\n")).snapshot
        let origin: UInt64 = 1_000_000_000
        var recorder = try CursorEventRecorder(document: document, ranges: [.init(location: 9, length: 0)], originNs: origin)
        try recorder.observe(document: document, ranges: [.init(location: 9 * 71 + 9, length: 0)], source: "mouse", atNs: origin + 100_000_000)
        let selectionStart = 4 * 71 + 19, selectionEnd = 5 * 71 + 49
        try recorder.observe(document: document, ranges: [.init(location: selectionStart, length: selectionEnd - selectionStart)], source: "mouse", atNs: origin + 500_000_000)
        let capture = try recorder.finish(atNs: origin + 1_000_000_000)
        XCTAssertEqual(capture.events.map(\.timestampMs), [0, 100, 500, 1000])
        XCTAssertEqual(capture.events[1].summary, "Cursor moved: (L1, C10) → (L10, C10)")
        XCTAssertEqual(capture.events[2].summary, "Selected: (L5, C20) → (L6, C50)")
        XCTAssertEqual(capture.endTimestampMs, 1000)
        XCTAssertThrowsError(try recorder.observe(document: document, ranges: [.init(location: 0, length: 0)], source: "keyboard", atNs: origin + 1_100_000_000))
        XCTAssertEqual(recorder.capture, capture)
    }

    func testUnicodeLogicalColumnsTabsAndCRLF() throws {
        let text = "a😀e\u{301}\tZ\r\n中x"
        XCTAssertEqual(try EditorTextPosition(utf16Offset: 3, in: text).column, 3)
        XCTAssertEqual(try EditorTextPosition(utf16Offset: 5, in: text).column, 5)
        XCTAssertEqual(try EditorTextPosition(utf16Offset: 6, in: text).column, 6)
        let nextLine = try EditorTextPosition(utf16Offset: 9, in: text)
        XCTAssertEqual(nextLine.line, 2); XCTAssertEqual(nextLine.column, 1)
        XCTAssertThrowsError(try EditorTextPosition(utf16Offset: 2, in: text))
        XCTAssertThrowsError(try EditorTextPosition(utf16Offset: 8, in: text))
        XCTAssertThrowsError(try EditorTextPosition(utf16Offset: -1, in: text))
    }

    func testMultipleSelectionsAndDocumentRevisionsPreserveText() throws {
        var document = TextDocumentState(text: "first\nsecond\nthird")
        var recorder = try CursorEventRecorder(document: document.snapshot, ranges: [.init(location: 0, length: 0)], originNs: 0)
        try recorder.observe(document: document.snapshot, ranges: [.init(location: 0, length: 5), .init(location: 13, length: 5)], source: "keyboard", atNs: 100_000_000)
        XCTAssertEqual(recorder.capture.events.last?.after.ranges.map(\.selectedText), ["first", "third"])
        document.updateText("first\nSECOND\nthird")
        try recorder.observe(document: document.snapshot, ranges: [.init(location: 12, length: 0)], source: "keyboard", atNs: 200_000_000)
        XCTAssertEqual(recorder.capture.events.last?.kind, .documentEdited)
        XCTAssertEqual(recorder.capture.documents.count, 2)
        XCTAssertEqual(recorder.capture.documents[0].text, "first\nsecond\nthird")
    }

    func testNoOpActionsAndEqualTimestampsKeepSequenceOrder() throws {
        let doc = TextDocumentState(text: "hello").snapshot
        var recorder = try CursorEventRecorder(document: doc, ranges: [.init(location: 0, length: 0)], originNs: 0)
        try recorder.observe(document: doc, ranges: [.init(location: 0, length: 0)], source: "mouse", atNs: 10_000_000)
        XCTAssertEqual(recorder.capture.events.count, 1)
        try recorder.observe(document: doc, ranges: [.init(location: 0, length: 0)], source: "mouse", atNs: 10_000_000, forceAction: true)
        try recorder.observe(document: doc, ranges: [.init(location: 1, length: 0)], source: "keyboard", atNs: 10_000_000)
        XCTAssertEqual(recorder.capture.events.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(recorder.capture.events[1].kind, .cursorAction)
    }

    func testClockMismatchWrongDocumentAndEventOverflowFail() throws {
        let doc = TextDocumentState(text: "hello").snapshot
        var recorder = try CursorEventRecorder(document: doc, ranges: [.init(location: 0, length: 0)], originNs: 100, maxEvents: 3)
        XCTAssertThrowsError(try recorder.observe(document: doc, ranges: [.init(location: 1, length: 0)], source: "mouse", atNs: 99))
        XCTAssertThrowsError(try recorder.observe(document: TextDocumentState(text: "other").snapshot, ranges: [.init(location: 0, length: 0)], source: "mouse", atNs: 200))
        try recorder.observe(document: doc, ranges: [.init(location: 1, length: 0)], source: "keyboard", atNs: 300)
        XCTAssertThrowsError(try recorder.observe(document: doc, ranges: [.init(location: 2, length: 0)], source: "keyboard", atNs: 400))
        XCTAssertEqual(try recorder.finish(atNs: 500, cancelled: true).status, "cancelled")
    }

    func testCaptureJSONRoundTrip() throws {
        let doc = TextDocumentState(text: "Hi 👋\nWorld").snapshot
        var recorder = try CursorEventRecorder(document: doc, ranges: [.init(location: 0, length: 0)], originNs: 123)
        try recorder.observe(document: doc, ranges: [.init(location: 0, length: 5)], source: "mouse", atNs: 1_000_123)
        let captured = try recorder.finish(atNs: 2_000_123)
        let data = try JSONEncoder().encode(captured)
        XCTAssertEqual(try JSONDecoder().decode(CursorRecordingCapture.self, from: data), captured)
    }
}
