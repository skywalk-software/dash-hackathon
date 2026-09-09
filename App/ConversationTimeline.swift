import Foundation
import Combine

/// Display order is assigned at first appearance, never reconstructed from mutable status or clocks.
@MainActor
final class ConversationTimeline: ObservableObject {
    enum Role: String { case user, assistant }
    struct Bubble: Identifiable, Equatable {
        let generation: UUID
        let recordingID: UUID
        let recordingNumber: Int
        let role: Role
        var id: String { "\(generation.uuidString):\(recordingID.uuidString):\(role.rawValue)" }
    }
    @Published private(set) var bubbles: [Bubble] = []
    @Published private(set) var revision = 0
    private(set) var generation = UUID()
    private var recordings: [UUID] = []
    private var taskOrder: [UUID: [String]] = [:]

    func reset() {
        generation = UUID()
        bubbles = []; recordings = []; taskOrder = [:]
        revision += 1
    }

    func receiveRecording(_ id: UUID, generation source: UUID) {
        guard source == generation else { return }
        if !recordings.contains(id) {
            recordings.append(id)
            append(id, role: .user)
        }
        revision += 1
    }

    func receiveTasks(_ jobs: [EditingEngine.Job], interpretations: [EditingEngine.Interpretation], generation source: UUID) {
        guard source == generation else { return }
        for job in jobs {
            guard let raw = job.recordingID, let id = UUID(uuidString: raw), recordings.contains(id) else { continue }
            if !(taskOrder[id] ?? []).contains(job.id) { taskOrder[id, default: []].append(job.id) }
            append(id, role: .assistant)
        }
        for interpretation in interpretations where interpretation.status == "interpreted" {
            guard let id = UUID(uuidString: interpretation.recordingID), recordings.contains(id) else { continue }
            append(id, role: .assistant)
        }
        revision += 1
    }

    func updated() { revision += 1 }

    func orderedJobs(_ jobs: [EditingEngine.Job], for id: UUID) -> [EditingEngine.Job] {
        let matching = jobs.filter { UUID(uuidString: $0.recordingID ?? "") == id }
        return (taskOrder[id] ?? []).compactMap { jobID in matching.first { $0.id == jobID } }
    }

    private func append(_ id: UUID, role: Role) {
        guard !bubbles.contains(where: { $0.recordingID == id && $0.role == role }),
              let index = recordings.firstIndex(of: id) else { return }
        bubbles.append(Bubble(generation: generation, recordingID: id, recordingNumber: index + 1, role: role))
    }
}

struct TaskProgress: Equatable {
    enum Kind: Equatable { case working, succeeded, failed, cancelled }
    let label: String
    let kind: Kind
    var isComplete: Bool { kind == .succeeded }

    @MainActor
    init(job: EditingEngine.Job, rendered: Bool) {
        switch job.state {
        case "queued": self.init("Waiting to start", .working)
        case "generating": self.init(job.operation == "question" ? "Preparing an answer" : "Rewriting", .working)
        case "queued_reconciliation": self.init("Waiting to combine changes", .working)
        case "reconciling": self.init("Combining your latest edits", .working)
        case "retry": self.init("Refreshing after your latest edits", .working)
        case "completed":
            if job.outcome == "noop" { self.init("No change needed", .succeeded) }
            else if rendered { self.init("Applied", .succeeded) }
            else { self.init("Applying to the document", .working) }
        case "answered": self.init("Answer ready", .succeeded)
        case "failed": self.init("Failed", .failed)
        case "conflict": self.init("Needs clarification", .failed)
        case "cancelled": self.init("Cancelled", .cancelled)
        default: self.init("Unrecognized task state: \(job.state)", .failed)
        }
    }

    private init(_ label: String, _ kind: Kind) { self.label = label; self.kind = kind }
}
