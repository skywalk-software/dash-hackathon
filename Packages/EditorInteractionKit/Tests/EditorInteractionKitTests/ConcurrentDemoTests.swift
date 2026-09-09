import XCTest
@testable import EditorInteractionKit

final class ConcurrentDemoTests: XCTestCase {
    func testTwoTargetsTrackHumanCorrectionAndEarlierRewrite() throws {
        let first = "Thank you for asking about your lamp. A processing delay at our warehouse caused the mistake."
        let second = "Your lamp will arrive on Tuesday, and we will refund the $15 shipping charge to your original payment method."
        var doc = TextDocumentState(text: "Subject: Lamp\n\nHi Maya,\n\n\(first)\n\n\(second)\n\nBest, Sam")
        func target(_ text: String) throws -> TrackedTextTarget {
            let range = (doc.snapshot.text as NSString).range(of: text)
            return TrackedTextTarget(try TextTarget(snapshot: doc.snapshot, range: .init(location: range.location, length: range.length)))
        }
        var one = try target(first), two = try target(second)
        func update(_ text: String) {
            let change = DocumentChange(before: doc.snapshot.text, after: text)
            one.follow(change); two.follow(change); doc.updateText(text)
        }
        update(doc.snapshot.text.replacingOccurrences(of: "Tuesday", with: "Thursday"))
        let firstResult = try MockRewriter.rewrite(text: one.text(in: doc.snapshot), instruction: MockRewriter.apologyInstruction)
        update((doc.snapshot.text as NSString).replacingCharacters(in: one.range.nsRange, with: firstResult))
        XCTAssertTrue(try two.text(in: doc.snapshot).contains("Thursday"))
        let secondResult = try MockRewriter.rewrite(text: two.text(in: doc.snapshot), instruction: MockRewriter.resolutionInstruction)
        update((doc.snapshot.text as NSString).replacingCharacters(in: two.range.nsRange, with: secondResult))
        XCTAssertFalse(doc.snapshot.text.contains("Tuesday"))
        XCTAssertTrue(doc.snapshot.text.contains("Thursday"))
        XCTAssertTrue(doc.snapshot.text.contains("$15"))
        XCTAssertTrue(doc.snapshot.text.hasPrefix("Subject: Lamp\n\nHi Maya,"))
        XCTAssertTrue(doc.snapshot.text.hasSuffix("Best, Sam"))
    }

    func testBoundaryCrossingInvalidatesTarget() throws {
        let snapshot = TextDocumentState(text: "before selected after").snapshot
        var target = TrackedTextTarget(try TextTarget(snapshot: snapshot, range: .init(location: 7, length: 8)))
        target.follow(DocumentChange(before: snapshot.text, after: "beforeXYZ after"))
        XCTAssertTrue(target.invalidated)
    }

    func testEarlierRewriteKeepsCaretInHumanEditedParagraph() {
        let before = "Long first paragraph.\n\nDelivery Thursday"
        let after = "Short.\n\nDelivery Thursday"
        let caret = DocumentTextRange(location: before.utf16.count, length: 0)
        let updated = caret.following(DocumentChange(before: before, after: after))
        XCTAssertEqual(updated, DocumentTextRange(location: after.utf16.count, length: 0))
    }
}
