import AppKit
import AVFoundation
import EditorInteractionKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct EditorView: View {
    @Binding var document: EditorDocument
    let fileURL: URL?
    @ObservedObject var voice: VoiceCaptureService
    @StateObject private var sessions = CursorSessionStore()
    @StateObject private var engine = EditingEngine()
    @StateObject private var timeline = ConversationTimeline()
    @State private var replaying = false
    @State private var injectedHumanEdit = false
    @State private var replayPlayer: AVAudioPlayer?
    @State private var inspectedChangeID: String?
    @State private var inspectionRequest = UUID()
    @State private var replayTask: Task<Void, Never>?
    @State private var ranges = [DocumentTextRange(location: 0, length: 0)]
    @State private var documentWindow: NSWindow?
    @State private var showDevice = false
    @State private var showExport = false
    @State private var exportDocument: RecordingPackageDocument?
    @State private var exportName = "recording.recordingbundle"
    @State private var errorMessage: String?
    @State private var followLatest = true
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            header
            HSplitView {
                VStack(spacing: 0) {
                    NativeTextEditor(text: document.model.snapshot.text, ranges: ranges, changes: engine.changes, inspectedChangeID: inspectedChangeID, inspectionRequest: inspectionRequest, onInspect: { inspectedChangeID = $0 }, onRendered: { text, at in Task { @MainActor in engine.didRender(text, atNs: at) } }, onComposition: { engine.isComposing = $0 }, onEvent: editorEvent)
                        .id(document.model.snapshot.documentID)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(alignment: .leading, spacing: 10) {
                        recordingFiles
                        if !sessions.events.isEmpty { liveEvents }
                        HStack {
                            Text(currentCursorLabel).accessibilityIdentifier("current-cursor")
                            Spacer()
                            Text("LINE / COLUMN")
                        }.font(EditorTheme.font(11, mono: true))
                    }
                    .foregroundStyle(EditorTheme.navy)
                    .padding(.horizontal, 24).padding(.vertical, 12)
                }
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                .background(EditorTheme.paper)
                conversation.frame(minWidth: 360, idealWidth: 440, maxWidth: 440, maxHeight: .infinity)
            }
        }
        .background(EditorTheme.paper)
        .background(DocumentWindowReference { documentWindow = $0 })
        .preferredColorScheme(.light)
        .font(EditorTheme.font(16))
        .tint(EditorTheme.navy)
        .navigationTitle(fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled")
        .sheet(isPresented: $showDevice) { DeviceSettingsView(voice: voice) }
        .fileExporter(isPresented: $showExport, document: exportDocument, contentType: .recordingPackage, defaultFilename: exportName) { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
        .alert("Could not complete action", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onAppear {
            engine.onText = { text, mappedRanges in
                document.model.updateText(text)
                ranges = mappedRanges.isEmpty ? [.init(location: 0, length: 0)] : mappedRanges
            }
            sessions.onPackageUpdated = { directory in
                if let folder = ProcessInfo.processInfo.environment["EDITOR_EVIDENCE_DIR"] {
                    try? directory.path.write(to: URL(fileURLWithPath: folder).appendingPathComponent("handoff-path.txt"), atomically: true, encoding: .utf8)
                }
            }
            sessions.onTranscriptReady = { recording, output in
                if !voice.isMock { engine.alignLiveTranscript(recording, output: output) }
            }
            engine.onAudioReady = { id, audio, result in sessions.attachAlignedAudio(id, audioURL: audio, resultURL: result) }
            engine.start(document: document.model.snapshot)
            if let recovery = ProcessInfo.processInfo.environment["EDITOR_RECOVER_SESSION"] { engine.recoverFailedEdits(from: recovery) }
            if ProcessInfo.processInfo.environment["EDITOR_AUTO_REPLAY"] == "1" { runAudioReplay() }
        }
        .onChange(of: engine.jobs.map { $0.state }) { _, states in
            if ProcessInfo.processInfo.environment["EDITOR_TEST_HUMAN_EDIT"] == "1", !injectedHumanEdit, states.contains("generating") {
                injectedHumanEdit = true
                let text = document.model.snapshot.text.replacingOccurrences(of: "Tuesday", with: "Thursday")
                editorEvent(text, ranges, "keyboard", UUID(), SessionClock.nowNanoseconds(), true)
            }
            if !states.isEmpty && states.allSatisfy({ ["completed", "answered", "failed", "conflict", "cancelled"].contains($0) }) {
                engine.exportEvidence(documentText: document.model.snapshot.text)
            }
        }
        .onReceive(voice.$latest) { recording in
            guard let recording, sessions.packages.contains(where: { $0.id == recording.id }) else { return }
            sessions.attach(recording, voice: voice)
        }
        .onChange(of: voice.state) { _, state in
            if case .failed(let message) = state, let id = sessions.currentID,
               voice.activeClockOriginNs == sessions.recorder?.originNs {
                if sessions.isRecording { perform { try sessions.stop(atNs: SessionClock.nowNanoseconds(), cancelled: true) } }
                sessions.audioFailed(id, message: message)
            }
        }
        .onReceive(sessions.$packages) { packages in
            for package in packages { timeline.receiveRecording(package.id, generation: timeline.generation) }
            updateConversationTasks()
        }
        .onReceive(sessions.$progressByID) { progress in
            if let latest = sessions.latestProgressID, progress[latest]?.hasFailure == true {
                timeline.receiveRecording(latest, generation: timeline.generation)
            }
            timeline.updated()
        }
        .onChange(of: engine.jobs) { _, _ in updateConversationTasks() }
        .onChange(of: engine.interpretations) { _, _ in updateConversationTasks() }
        .onChange(of: engine.changes) { _, _ in timeline.updated() }
        .onChange(of: inspectedChangeID) { _, _ in timeline.updated() }
        .onChange(of: engine.renderedJobIDs) { _, _ in timeline.updated() }
        .onChange(of: sessions.error) { _, message in errorMessage = message }
        .onDisappear {
            replayTask?.cancel(); replayPlayer?.stop(); engine.close()
            if sessions.isRecording { stopRecording(cancelled: true) }
        }
    }

    private func runAudioReplay() {
        guard let path = engine.replayPath, !replaying, !sessions.isRecording else { return }
        replaying = true; injectedHumanEdit = false
        replayTask = Task { @MainActor in
            defer { replaying = false }
            do {
                let replay = try JSONDecoder().decode(AudioEditingReplay.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                try sessions.reset()
                timeline.reset()
                inspectedChangeID = nil
                try engine.reset(replay.document)
                document.model.updateText(replay.document); ranges = [.init(location: 0, length: 0)]
                replayPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: replay.audio))
                replayPlayer?.prepareToPlay()
                let origin = SessionClock.nowNanoseconds()
                let id = try sessions.begin(document: document.model.snapshot, ranges: ranges, atNs: origin)
                try engine.begin(id)
                replayPlayer?.play()
                for event in replay.gestures {
                    let target = origin + UInt64(event.at_ms * 1_000_000)
                    let now = SessionClock.nowNanoseconds()
                    if target > now { try await Task.sleep(nanoseconds: target - now) }
                    try Task.checkCancellation()
                    editorEvent(document.model.snapshot.text, [.init(location: event.location, length: event.length)], "replay", UUID(), SessionClock.nowNanoseconds(), true)
                }
                let end = origin + UInt64(replay.duration_ms * 1_000_000)
                let now = SessionClock.nowNanoseconds()
                if end > now { try await Task.sleep(nanoseconds: end - now) }
                try sessions.stop(atNs: SessionClock.nowNanoseconds())
                engine.end()
                if let folder = ProcessInfo.processInfo.environment["EDITOR_EVIDENCE_DIR"], let capture = sessions.packages.last?.capture {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(capture).write(to: URL(fileURLWithPath: folder).appendingPathComponent("native-capture.json"))
                }
                engine.processAudio(id: id, url: URL(fileURLWithPath: replay.audio), durationMs: replay.duration_ms)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private var currentCursorLabel: String {
        do { return try EditorCursorSnapshot(document: document.model.snapshot, ranges: ranges).label }
        catch { return "Cursor position unavailable" }
    }

    private var hasActiveEdits: Bool {
        engine.jobs.contains { !["completed", "answered", "failed", "conflict", "cancelled"].contains($0.state) }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Text("dash").font(.system(size: 32, weight: .bold, design: .rounded))
                .accessibilityLabel("Dash")
            Text(voice.isMock ? "ASTRA / MOCK" : "GPT-6 ASTRA")
                .font(EditorTheme.font(9, mono: true)).tracking(1).foregroundStyle(EditorTheme.navy)
                .padding(.trailing, 36)
            Button("Open…", action: openInCurrentWindow)
                .disabled(voice.state.isBusy || sessions.isRecording || hasActiveEdits || replaying)
                .accessibilityIdentifier("open-text-file")
            Button("Save") { NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil) }
            Spacer(minLength: 12)
            Button(voice.isMock ? "Mock audio" : (voice.deviceConnected ? "Microphone ready" : "Microphone settings")) {
                showDevice = true
            }.accessibilityIdentifier("device-settings")
            Button("Restart") { perform {
                guard let window = documentWindow,
                      let nativeDocument = NSDocumentController.shared.document(for: window) else {
                    throw EditorServiceError("Could not identify this document for Restart.")
                }
                try sessions.reset()
                timeline.reset()
                inspectedChangeID = nil
                // Become an untitled document BEFORE clearing text: FileDocument autosaves in place.
                nativeDocument.fileURL = nil
                nativeDocument.fileModificationDate = nil
                nativeDocument.displayName = "Untitled"
                nativeDocument.undoManager?.removeAllActions()
                voice.resetPresentation()
                try engine.reset("")
                document = EditorDocument()
                ranges = [DocumentTextRange(location: 0, length: 0)]
                errorMessage = nil
                exportDocument = nil
                showExport = false
                showLog = false
                followLatest = true
            }}
            .disabled(voice.state.isBusy || sessions.isRecording || hasActiveEdits || replaying)
            .help("Clear this document, conversation, recording log, and audio playback")
            .accessibilityIdentifier("restart")
        }
        .buttonStyle(EditorButtonStyle())
        .padding(.horizontal, 16).frame(height: 56)
    }

    private func openInCurrentWindow() {
        guard let window = documentWindow,
              let nativeDocument = NSDocumentController.shared.document(for: window) else {
            errorMessage = "Could not identify this document for Open."
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            perform {
                // Read before changing the session so a failed open preserves the current document.
                let text = try TextFileCodec.decode(Data(contentsOf: url))
                let modificationDate = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                if let other = NSDocumentController.shared.document(for: url), other !== nativeDocument {
                    throw EditorServiceError("This file is already open in another window. Close that window before opening it here.")
                }
                try sessions.reset()
                timeline.reset()
                inspectedChangeID = nil
                nativeDocument.fileURL = nil
                nativeDocument.undoManager?.removeAllActions()
                voice.resetPresentation()
                try engine.reset(text)
                document = EditorDocument(text: text)
                nativeDocument.fileType = UTType.plainText.identifier
                nativeDocument.fileURL = url
                nativeDocument.fileModificationDate = modificationDate
                nativeDocument.displayName = url.lastPathComponent
                ranges = [DocumentTextRange(location: 0, length: 0)]
                exportDocument = nil
                showExport = false
                errorMessage = nil
                showLog = false
                followLatest = true
            }
        }
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Assistant").font(EditorTheme.font(24, bold: true))
                Text("This document’s conversation").font(EditorTheme.font(11, mono: true)).tracking(0.6)
                    .foregroundStyle(EditorTheme.muted)
            }
            ConversationScrollView(revision: timeline.revision) {
                VStack(alignment: .leading, spacing: 24) {
                    if timeline.bubbles.isEmpty {
                        Text(sessions.isRecording ? "Listening. Move the cursor or select text as you speak." : "Start recording, then select text while speaking.")
                            .font(EditorTheme.font(18)).lineSpacing(5).foregroundStyle(EditorTheme.paper)
                    }
                    ForEach(timeline.bubbles) { bubble in
                        conversationBubble(bubble)
                            .background(ConversationAnchor(id: bubble.id))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.id(timeline.generation)
            if let failure = engine.failure {
                Text("\(engine.isEnabled ? "Editing error" : "Editing paused"): \(failure)").font(EditorTheme.font(13))
                    .foregroundStyle(Color(red: 1, green: 0.65, blue: 0.55)).textSelection(.enabled)
            }
            if let timing = engine.timingSummary {
                Text(timing).font(EditorTheme.font(11, mono: true)).foregroundStyle(EditorTheme.muted)
                    .accessibilityIdentifier("result-latency")
            }
            if engine.replayPath != nil {
                Button("Run audio demo") { runAudioReplay() }.disabled(replaying || sessions.isRecording)
                    .accessibilityIdentifier("run-audio-demo")
            }
            composer
        }
        .padding(24).foregroundStyle(EditorTheme.paper)
        .background(EditorTheme.ink)
        .colorScheme(.dark)
    }

    @ViewBuilder
    private func conversationBubble(_ bubble: ConversationTimeline.Bubble) -> some View {
        let package = sessions.packages.first { $0.id == bubble.recordingID }
        let interpretation = engine.interpretations.first { UUID(uuidString: $0.recordingID) == bubble.recordingID }
        if bubble.role == .user {
            RecordingUserBubble(number: bubble.recordingNumber, package: package,
                progress: sessions.progress(for: bubble.recordingID),
                eventCount: package?.capture.events.count ?? sessions.events.count,
                interpretation: interpretation, engineEnabled: engine.isEnabled, isMock: voice.isMock,
                cancelTranscription: { sessions.cancelTranscription(bubble.recordingID) })
                .id(bubble.id).accessibilityIdentifier("conversation-user-\(bubble.recordingID)")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                RecordingAssistantBubble(number: bubble.recordingNumber,
                    jobs: timeline.orderedJobs(engine.jobs, for: bubble.recordingID),
                    interpretation: interpretation, renderedJobIDs: engine.renderedJobIDs,
                    cancel: { engine.cancel($0) }, changes: engine.changes,
                    inspectedChangeID: inspectedChangeID, showChange: { id in
                        inspectedChangeID = id
                        inspectionRequest = UUID()
                    })
                if let change = engine.changes.first(where: { $0.id == inspectedChangeID }),
                   timeline.orderedJobs(engine.jobs, for: bubble.recordingID).contains(where: { $0.id == change.taskID }) {
                    changeInspector(change)
                }
            }
            .id(bubble.id).accessibilityIdentifier("conversation-assistant-\(bubble.recordingID)")
        }
    }

    private func changeInspector(_ change: EditingEngine.Change) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Applied changes").font(.headline)
                Spacer()
                Button("Close") { inspectedChangeID = nil }
            }
            Text(change.instruction).font(.caption)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(change.hunks) { hunk in
                        VStack(alignment: .leading, spacing: 4) {
                            if !hunk.active { Text("Changed again since this task").font(.caption).foregroundStyle(.secondary) }
                            HStack(alignment: .top, spacing: 16) {
                                VStack(alignment: .leading) {
                                    Text("Before").font(.caption).foregroundStyle(.secondary)
                                    Text(hunk.before.isEmpty ? "(nothing)" : hunk.before).textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                VStack(alignment: .leading) {
                                    Text("After").font(.caption).foregroundStyle(.secondary)
                                    Text(hunk.after.isEmpty ? "(deleted)" : hunk.after).textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }.frame(maxHeight: 180)
        }
        .padding(12)
        .foregroundStyle(EditorTheme.ink)
        .background(EditorTheme.bubble, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("change-inspector")
    }

    private func updateConversationTasks() {
        timeline.receiveTasks(engine.jobs, interpretations: engine.interpretations, generation: timeline.generation)
    }

    private var recordingFiles: some View {
        HStack(spacing: 16) {
            if sessions.packages.count > 1 {
                Menu("Show files") {
                    ForEach(Array(sessions.packages.enumerated()), id: \.element.id) { index, package in
                        Button("Recording \(index + 1) · \(package.capture.events.count) events") {
                            NSWorkspace.shared.activateFileViewerSelecting([package.directory])
                        }
                    }
                }
                Menu("Export package") {
                    ForEach(Array(sessions.packages.enumerated()), id: \.element.id) { index, package in
                        Button("Recording \(index + 1) · \(package.capture.events.count) events") { export(package) }
                    }
                }
            } else if let package = sessions.packages.first {
                Button("Show files") { NSWorkspace.shared.activateFileViewerSelecting([package.directory]) }
                Button("Export package") { export(package) }
            }
        }
        .font(EditorTheme.font(13)).buttonStyle(.borderless).tint(EditorTheme.navy.opacity(0.75))
        .fixedSize()
    }

    private func export(_ package: CursorSessionStore.Package) {
        perform {
            exportDocument = try RecordingPackageDocument(directory: package.directory)
            exportName = package.id.uuidString + ".recordingbundle"
            showExport = true
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill").font(.system(size: 24))
                    .frame(width: 28, height: 36).background(EditorTheme.cyan, in: RoundedRectangle(cornerRadius: 6))
                Button(sessions.isRecording ? "Stop recording" : "Start recording", action: recordingButton)
                    .buttonStyle(EditorButtonStyle(filled: true))
                    .disabled(!voice.deviceConnected || (!sessions.isRecording && voice.state.isBusy))
                    .accessibilityIdentifier("record-voice")
                Spacer(minLength: 0)
                if sessions.isRecording {
                    Button { stopRecording(cancelled: true) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Cancel capture").accessibilityLabel("Cancel capture")
                        .accessibilityIdentifier("cancel-capture")
                } else if voice.latest != nil && !voice.state.isBusy {
                    Button { perform { try voice.play() } } label: { Image(systemName: "play.fill") }
                        .buttonStyle(.borderless).help("Play voice").accessibilityLabel("Play voice")
                }
            }
            Text(voice.state.label).font(EditorTheme.font(11, mono: true)).foregroundStyle(EditorTheme.cyan)
            if let status = voice.enhancementStatus {
                Text(status).font(EditorTheme.font(11, mono: true)).foregroundStyle(EditorTheme.cyan)
            }
            Text(sessions.isRecording ? "Select text or move the cursor while speaking." : "Start recording, then select text while speaking.")
                .font(EditorTheme.font(11, mono: true)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(EditorTheme.composer, in: RoundedRectangle(cornerRadius: 12))
    }

    private var liveEvents: some View {
        DisclosureGroup(isExpanded: $showLog) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TimelineView(.periodic(from: .now, by: 0.05)) { _ in
                        Text("\(sessions.elapsedMs, specifier: "%.0f") ms · \(sessions.events.count) events")
                            .accessibilityIdentifier("recording-clock")
                    }
                    Spacer()
                    Toggle("Follow", isOn: $followLatest).toggleStyle(.checkbox)
                }.font(EditorTheme.font(11, mono: true))
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(sessions.events) { event in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(event.timestampMs, specifier: "%.3f") ms").foregroundStyle(EditorTheme.navy)
                                    Text(event.summary)
                                }
                                .font(EditorTheme.font(11, mono: true)).textSelection(.enabled)
                                .id(event.id).accessibilityIdentifier("cursor-event-\(event.sequence)")
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.onChange(of: sessions.events.count) { _, _ in
                        if followLatest, let id = sessions.events.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }.frame(height: 140)
            }.padding(.top, 8)
        } label: {
            Text(sessions.isRecording ? "Live recording log" : "Recording log · frozen")
                .font(EditorTheme.font(13))
        }.tint(EditorTheme.navy)
    }

    private func editorEvent(_ text: String, _ selections: [DocumentTextRange], _ source: String, _ actionID: UUID?, _ timestamp: UInt64, _ forceAction: Bool) {
        let changed = document.model.snapshot.text != text
        do { try engine.edit(text) } catch { errorMessage = error.localizedDescription; return }
        document.model.updateText(text)
        ranges = selections
        do {
            try engine.observe(selections, atMs: sessions.elapsedMs, source: changed ? "typing" : source, actionID: actionID)
            try sessions.observe(document: document.model.snapshot, ranges: selections, source: source,
                actionID: actionID, atNs: timestamp, forceAction: forceAction)
        } catch {
            errorMessage = error.localizedDescription
            if sessions.isRecording { stopRecording(cancelled: true) }
        }
    }

    private func recordingButton() {
        let clickTime = SessionClock.nowNanoseconds()
        if sessions.isRecording { stopRecording(cancelled: false, atNs: clickTime) }
        else {
            do {
                showLog = false
                let id = try sessions.begin(document: document.model.snapshot, ranges: ranges, atNs: clickTime)
                try engine.begin(id)
                Task { await voice.start(id: id, clockOriginNs: clickTime) }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func stopRecording(cancelled: Bool, atNs stopTime: UInt64 = SessionClock.nowNanoseconds()) {
        do {
            try sessions.stop(atNs: stopTime, cancelled: cancelled)
            if cancelled { engine.cancelCapture() } else { engine.end(atNs: stopTime) }
            Task {
                if cancelled || voice.state == .starting { await voice.cancelCapture() }
                else { await voice.stop() }
            }
        } catch {
            errorMessage = error.localizedDescription
            Task { await voice.cancelCapture() }
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation() }
        catch { errorMessage = error.localizedDescription }
    }
}


struct CaptureStatusRows: View {
    let progress: CursorSessionStore.CaptureProgress
    let eventCount: Int
    var onPaper = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            row(progress.cursor, name: "Cursor capture", success: "Captured \(eventCount) cursor events")
                .accessibilityIdentifier("cursor-capture-status")
            row(progress.audio, name: "Audio recording", success: "Audio saved and validated")
                .accessibilityIdentifier("audio-capture-status")
        }.font(EditorTheme.font(13))
    }

    private func row(_ status: CursorSessionStore.StageStatus, name: String, success: String) -> some View {
        let label: String
        let icon: String
        let color: Color
        switch status {
        case .succeeded:
            label = success; icon = "checkmark"; color = onPaper ? EditorTheme.navy : EditorTheme.cyan
        case .failed(let reason):
            label = "\(name) failed: \(reason)"; icon = "xmark.circle"; color = onPaper ? Color(red: 0.65, green: 0.18, blue: 0.09) : Color(red: 1, green: 0.65, blue: 0.55)
        case .cancelled:
            label = "\(name) cancelled"; icon = "minus.circle"; color = onPaper ? EditorTheme.navy : EditorTheme.muted
        case .pending:
            label = "\(name) pending"; icon = "clock"; color = onPaper ? EditorTheme.navy : EditorTheme.muted
        }
        return Label(label, systemImage: icon).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
}


/// Resolve this editor's document even when a different app or window has keyboard focus.
private struct DocumentWindowReference: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.onWindow = onWindow
        return view
    }
    func updateNSView(_ view: WindowView, context: Context) { view.onWindow = onWindow }
    final class WindowView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onWindow?(self.window)
            }
        }
    }
}
