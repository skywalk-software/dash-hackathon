import XCTest
@testable import EditorInteractionKit

final class DocumentInteractionTests: XCTestCase {
    func testUnicodeSelectionAndScopedReplacement() throws {
        var document = TextDocumentState(text: "Hello 👩🏽‍💻, café!")
        let range = (document.snapshot.text as NSString).range(of: "👩🏽‍💻")
        let target = try TextTarget(snapshot: document.snapshot, range: .init(location: range.location, length: range.length))
        let selected = try document.replace(target: target, expectedRevision: 0, with: "世界")
        XCTAssertEqual(document.snapshot.text, "Hello 世界, café!")
        XCTAssertEqual(selected, DocumentTextRange(location: 6, length: 2))
        XCTAssertEqual(document.snapshot.revision, 1)
    }

    func testInvalidUTF16OffsetsFailWithoutMutation() throws {
        let document = TextDocumentState(text: "🙂 hello")
        for range in [DocumentTextRange(location: 1, length: 1), .init(location: -1, length: 1), .init(location: 0, length: Int.max)] {
            XCTAssertThrowsError(try TextTarget(snapshot: document.snapshot, range: range))
        }
        XCTAssertEqual(document.snapshot.text, "🙂 hello")
    }

    func testTargetRebasesAfterDistantTyping() throws {
        var document = TextDocumentState(text: String(repeating: "x", count: 60) + " chosen text " + String(repeating: "z", count: 60))
        let original = (document.snapshot.text as NSString).range(of: "chosen text")
        let target = try TextTarget(snapshot: document.snapshot, range: .init(location: original.location, length: original.length))
        document.updateText("new intro\n" + document.snapshot.text)
        XCTAssertEqual(try target.resolve(in: document.snapshot).location, original.location + 10)
    }

    func testAmbiguousAndChangedTargetsFail() throws {
        var document = TextDocumentState(text: "one selected phrase here")
        let target = try TextTarget(snapshot: document.snapshot, range: .init(location: 4, length: 15))
        document.updateText(document.snapshot.text + "\n" + document.snapshot.text)
        XCTAssertThrowsError(try target.resolve(in: document.snapshot)) { XCTAssertEqual($0 as? InteractionError, .ambiguousTarget) }
        document.updateText("one changed phrase here")
        XCTAssertThrowsError(try target.resolve(in: document.snapshot))
    }

    func testStaleEditsAndCrossDocumentTargetsNeverOverwrite() throws {
        var document = TextDocumentState(text: "Keep this text")
        let target = try TextTarget(snapshot: document.snapshot, range: .init(location: 0, length: 4))
        document.updateText("Keep this human edit")
        XCTAssertThrowsError(try document.replace(target: target, expectedRevision: 0, with: "Delete"))
        XCTAssertEqual(document.snapshot.text, "Keep this human edit")
        var other = TextDocumentState(text: "Keep this text")
        XCTAssertThrowsError(try other.replace(target: target, expectedRevision: 0, with: "Delete"))
        XCTAssertEqual(other.snapshot.text, "Keep this text")
    }

    func testCursorFailsAfterDocumentChanges() throws {
        var document = TextDocumentState(text: "Hello")
        let target = try TextTarget(snapshot: document.snapshot, range: .init(location: 5, length: 0))
        document.updateText("Hello there")
        XCTAssertThrowsError(try target.resolve(in: document.snapshot))
    }

    func testSecondParagraphSurvivesFirstParagraphRewrite() throws {
        var document = TextDocumentState(text: "A long opening paragraph that an agent will shorten.\n\nYour lamp will arrive on Tuesday.\n\nBest, Sam")
        let range = (document.snapshot.text as NSString).range(of: "Your lamp will arrive on Tuesday.")
        let target = try TextTarget(snapshot: document.snapshot, range: .init(location: range.location, length: range.length))
        document.updateText("Sorry about the delay.\n\nYour lamp will arrive on Tuesday.\n\nBest, Sam")
        let resolved = try target.resolve(in: document.snapshot)
        XCTAssertEqual((document.snapshot.text as NSString).substring(with: resolved.nsRange), target.exactText)
        document.updateText("Sorry about the delay.\n\nYour lamp will arrive on Thursday.\n\nBest, Sam")
        XCTAssertThrowsError(try document.replace(target: target, expectedRevision: document.snapshot.revision, with: "Your lamp arrives Tuesday."))
        XCTAssertTrue(document.snapshot.text.contains("Thursday"))
    }

    func testFileRoundTripAndInvalidEncoding() throws {
        let text = "# Notes\r\nCafé 👋\n第二行\n"
        XCTAssertEqual(try TextFileCodec.decode(TextFileCodec.encode(text)), text)
        XCTAssertThrowsError(try TextFileCodec.decode(Data([0xFF, 0xFE, 0x80])))
    }

    func testInteractionContextRoundTripPreservesTargetIdentity() throws {
        let document = TextDocumentState(text: "A spoken request targets this text.")
        let context = try DocumentInteractionContext(document: document.snapshot, selection: .init(location: 25, length: 9))
        let data = try JSONEncoder().encode(context)
        XCTAssertEqual(try JSONDecoder().decode(DocumentInteractionContext.self, from: data), context)
    }
}
