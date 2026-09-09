import Combine
import EditorInteractionKit
import Foundation

/// The in-process handoff surface for the shared voice/agent interaction layer.
@MainActor
final class EditorInteractionAdapter: ObservableObject {
    @Published private(set) var snapshot: DocumentSnapshot
    @Published var selection = DocumentTextRange(location: 0, length: 0)
    @Published private(set) var pinnedTarget: TextTarget?
    @Published private(set) var voiceInputs: [VoiceInteractionInput] = []
    @Published private(set) var jobs: [EditJob] = []
    var applyText: ((String) -> Void)?
    private var tasks: [UUID: Task<Void, Never>] = [:]

    struct EditJob: Identifiable {
        let id: UUID
        var target: TrackedTextTarget
        var instruction = ""
        var status = "Transcription pending"
        var isFinished = false
    }

    init(snapshot: DocumentSnapshot) { self.snapshot = snapshot }

    func update(snapshot: DocumentSnapshot, selection: DocumentTextRange) {
        if snapshot.documentID == self.snapshot.documentID, snapshot.text != self.snapshot.text {
            let change = DocumentChange(before: self.snapshot.text, after: snapshot.text)
            for index in jobs.indices where !jobs[index].isFinished { jobs[index].target.follow(change) }
        }
        self.snapshot = snapshot
        self.selection = selection
    }

    func pinSelection() throws { pinnedTarget = try TextTarget(snapshot: snapshot, range: selection) }
    func clearTarget() { pinnedTarget = nil }

    func context() throws -> DocumentInteractionContext {
        let range = try pinnedTarget?.resolve(in: snapshot) ?? selection
        return try DocumentInteractionContext(document: snapshot, selection: range)
    }

    func accept(recording: VoiceCaptureService.Recording, context: DocumentInteractionContext, voice: VoiceCaptureService) {
        guard !jobs.contains(where: { $0.id == recording.id }) else { return }
        voiceInputs.append(VoiceInteractionInput(
            context: context, audioURL: recording.audioURL, capturedAt: recording.startedAt,
            sampleRate: recording.sampleRate, duration: recording.duration
        ))
        var target = TrackedTextTarget(context.target)
        if context.document.text != snapshot.text {
            target.follow(DocumentChange(before: context.document.text, after: snapshot.text))
        }
        jobs.append(EditJob(id: recording.id, target: target))
        pinnedTarget = nil
        tasks[recording.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let instruction = try await voice.transcribe(recording, context: context)
                try Task.checkCancellation()
                guard let index = jobs.firstIndex(where: { $0.id == recording.id }), !jobs[index].isFinished else { return }
                jobs[index].instruction = instruction
                jobs[index].status = voice.isMock ? "Edit pending · mock rehearsal delay" : "Edit pending · ready for interaction layer"
                guard voice.isMock else { return }
                // Deliberately visible delay exercises HACK-2's overlap, not production latency.
                try await Task.sleep(for: .seconds(12))
                try Task.checkCancellation()
                guard let current = jobs.first(where: { $0.id == recording.id }), !current.isFinished else { return }
                let latestText = try current.target.text(in: snapshot)
                let replacement = try MockRewriter.rewrite(text: latestText, instruction: instruction)
                try applyResponse(requestID: recording.id, expectedRevision: snapshot.revision, replacement: replacement)
            } catch is CancellationError {
                cancel(recording.id)
            } catch {
                finish(recording.id, status: "Failed: \(error.localizedDescription)")
            }
            tasks[recording.id] = nil
        }
    }

    func applyResponse(requestID: UUID, expectedRevision: Int, replacement: String) throws {
        guard let index = jobs.firstIndex(where: { $0.id == requestID }) else { throw EditorServiceError("Unknown request ID.") }
        guard !jobs[index].isFinished else { return }
        guard expectedRevision == snapshot.revision else { throw InteractionError.staleRevision }
        _ = try jobs[index].target.text(in: snapshot)
        guard let applyText else { throw EditorServiceError("The document is no longer open.") }
        let updated = (snapshot.text as NSString).replacingCharacters(in: jobs[index].target.range.nsRange, with: replacement)
        jobs[index].status = "Applied once"; jobs[index].isFinished = true
        applyText(updated)
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        finish(id, status: "Cancelled")
    }

    func cancelAll() {
        cancelPending()
        applyText = nil
    }

    func cancelPending() {
        for job in jobs where !job.isFinished { cancel(job.id) }
    }

    private func finish(_ id: UUID, status: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].isFinished else { return }
        jobs[index].status = status; jobs[index].isFinished = true
    }

    func export() throws -> Data {
        struct Payload: Encodable {
            let context: DocumentInteractionContext
            let voiceInputs: [VoiceInteractionInput]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Payload(context: context(), voiceInputs: voiceInputs))
    }
}
