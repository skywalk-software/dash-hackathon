import AppKit
import SwiftUI
import XCTest
import EditorInteractionKit
@testable import DashHackathon

@MainActor
final class ConversationScrollTests: XCTestCase {
    final class Fixture: ObservableObject {
        @Published var firstHeight: CGFloat = 200
        @Published var revision = 0
    }
    struct FixtureView: View {
        @ObservedObject var fixture: Fixture
        var body: some View {
            ConversationScrollView(revision: fixture.revision) {
                VStack(spacing: 20) {
                    ForEach(0..<8) { index in
                        Text("Bubble \(index)").frame(maxWidth: .infinity)
                            .frame(height: index == 0 ? fixture.firstHeight : 160)
                            .background(ConversationAnchor(id: "bubble-\(index)"))
                    }
                }
            }
        }
    }
    private func settle(_ view: NSView) async throws {
        for _ in 0..<8 {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private func findScroll(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.compactMap(findScroll).first
    }

    func testEarlierBubbleGrowthPreservesReadingAnchorAndBottomFollowing() async throws {
        let fixture = Fixture()
        let host = NSHostingView(rootView: FixtureView(fixture: fixture))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await settle(host)
        let scroll = try XCTUnwrap(findScroll(host))
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.frame.height, 1000)
        XCTAssertEqual(scroll.contentView.bounds.maxY, document.frame.height, accuracy: 2)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 420))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(host)
        let before = scroll.contentView.bounds.minY
        fixture.firstHeight += 100; fixture.revision += 1
        try await settle(host)
        XCTAssertEqual(scroll.contentView.bounds.minY, before + 100, accuracy: 2)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.frame.height - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(host)
        fixture.firstHeight += 100; fixture.revision += 1
        try await settle(host)
        XCTAssertEqual(scroll.contentView.bounds.maxY, document.frame.height, accuracy: 2)
    }
    func testConversationBubbleRendering() async throws {
        let id = UUID()
        var recorder = try CursorEventRecorder(recordingID: id,
            document: TextDocumentState(text: "Thank you for getting in touch.\nYour lamp will arrive on Tuesday.").snapshot,
            ranges: [.init(location: 0, length: 30)], originNs: 100)
        let capture = try recorder.finish(atNs: 100_000_100)
        let package = CursorSessionStore.Package(id: id, directory: FileManager.default.temporaryDirectory,
            capture: capture, status: "Ready · transcript aligned",
            transcript: "Make the opening warmer and more direct. Turn the resolution into a checklist.")
        let progress = CursorSessionStore.CaptureProgress(id: id, cursor: .succeeded, audio: .succeeded)
        let interpretation = EditingEngine.Interpretation(recordingID: id.uuidString, status: "interpreted",
            result: .init(needs_input: []), error: nil)
        let jobs = ["Thank you for getting in touch.", "Your lamp will arrive on Tuesday."].enumerated().map { index, quote in
            EditingEngine.Job(id: "job-\(index)", recordingID: id.uuidString,
                state: index == 0 ? "completed" : "reconciling", instruction: "Rewrite reference_1 carefully.",
                operation: "edit", references: [.init(name: "reference_1", paragraph: "document", quote: quote, selection_id: "selection-\(index)")],
                context: [], working_area: nil, outcome: index == 0 ? "committed" : nil, answer: nil, error: nil)
        }
        let content = VStack(alignment: .leading, spacing: 24) {
            RecordingUserBubble(number: 1, package: package, progress: progress,
                eventCount: capture.events.count, interpretation: interpretation,
                engineEnabled: true, isMock: true, cancelTranscription: {})
            RecordingAssistantBubble(number: 1, jobs: jobs, interpretation: interpretation,
                renderedJobIDs: ["job-0"], cancel: { _ in })
        }.padding(24).frame(width: 440).background(EditorTheme.ink).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 440, height: 850)
        try await settle(host)
        XCTAssertLessThan(host.fittingSize.height, 850)
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent("open-editor-bubbles.png")
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: snapshot)
        print("Conversation snapshot: \(snapshot.path)")
    }

}
