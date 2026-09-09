import Darwin
import EditorInteractionKit
import Foundation
import XCTest
@testable import DashHackathon

@MainActor
final class EditingDiagnosticsTests: XCTestCase {
    private func withEngine(evidenceEnabled: Bool, _ body: (EditingEngine) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A local protocol fixture: any export request fails, making accidental exports observable.
        let worker = """
        while IFS= read -r message; do
            case "$message" in
                *'"export"'*) echo '{"ok":false,"error":"Diagnostic export failed"}' ;;
                *'"edit"'*) echo '{"ok":true,"text":"Editing still works","jobs":[],"interpretations":[],"error":null}' ;;
                *) echo '{"ok":true,"text":"Before","jobs":[],"interpretations":[],"error":null}' ;;
            esac
        done
        """
        try worker.write(to: folder.appendingPathComponent("worker.mjs"), atomically: true, encoding: .utf8)
        let names = ["EDITOR_ENGINE_PATH", "EDITOR_NODE", "EDITOR_EVIDENCE_DIR"]
        let previous = ProcessInfo.processInfo.environment
        defer {
            for name in names {
                if let value = previous[name] { setenv(name, value, 1) } else { unsetenv(name) }
            }
        }
        setenv("EDITOR_ENGINE_PATH", folder.path, 1)
        setenv("EDITOR_NODE", "/bin/sh", 1)
        if evidenceEnabled { setenv("EDITOR_EVIDENCE_DIR", folder.appendingPathComponent("evidence").path, 1) }
        else { unsetenv("EDITOR_EVIDENCE_DIR") }
        let engine = EditingEngine()
        defer { engine.close() }
        engine.start(document: TextDocumentState(text: "Before").snapshot)
        XCTAssertTrue(engine.isEnabled)
        XCTAssertNil(engine.failure)
        try body(engine)
    }

    func testUnconfiguredEvidenceExportDoesNotPauseEditing() throws {
        try withEngine(evidenceEnabled: false) { engine in
            engine.exportEvidence(documentText: "A completed edit")
            engine.exportEvidence(documentText: "Another completed edit")
            XCTAssertNil(engine.failure)
            XCTAssertTrue(engine.isEnabled)
            try engine.edit("Editing still works")
            XCTAssertNil(engine.failure)
        }
    }

    func testExplicitlyConfiguredExportFailureRemainsVisible() throws {
        try withEngine(evidenceEnabled: true) { engine in
            engine.exportEvidence(documentText: "A completed edit")
            XCTAssertEqual(engine.failure, "Diagnostic export failed")
            XCTAssertEqual(engine.status, "Editing paused")
        }
    }
}
