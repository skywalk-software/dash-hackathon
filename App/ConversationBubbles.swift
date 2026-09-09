import EditorInteractionKit
import SwiftUI

struct RecordingUserBubble: View {
    let number: Int
    let package: CursorSessionStore.Package?
    let progress: CursorSessionStore.CaptureProgress
    let eventCount: Int
    let interpretation: EditingEngine.Interpretation?
    let engineEnabled: Bool
    let isMock: Bool
    let cancelTranscription: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("YOU · RECORDING \(number)\(isMock ? " · MOCK" : "")")
                .font(EditorTheme.font(10, mono: true)).tracking(0.8).foregroundStyle(EditorTheme.navy)
            if let transcript = package?.transcript {
                Text(transcript).font(EditorTheme.font(16)).lineSpacing(4).textSelection(.enabled)
            } else if let package, package.status.hasPrefix("Failed:"), !progress.audio.isFailure {
                Label("Transcription failed: " + String(package.status.dropFirst("Failed: ".count)), systemImage: "xmark.circle")
                    .foregroundStyle(Color(red: 0.65, green: 0.18, blue: 0.09))
            } else if progress.audio == .cancelled || package?.status == "Transcription cancelled" {
                Label("Transcription cancelled", systemImage: "minus.circle").foregroundStyle(EditorTheme.navy)
            } else if progress.hasFailure {
                Text("Recording could not be completed.").foregroundStyle(EditorTheme.navy)
            } else {
                Label("Transcribing your audio", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(EditorTheme.navy)
            }
            CaptureStatusRows(progress: progress, eventCount: eventCount, onPaper: true)
            if package?.transcript != nil {
                interpretationProgress.font(EditorTheme.font(13)).foregroundStyle(EditorTheme.navy)
            }
            if package?.status == "Transcription pending" {
                Button("Cancel transcription", action: cancelTranscription)
                    .font(EditorTheme.font(13)).buttonStyle(.plain).foregroundStyle(EditorTheme.navy)
            }
        }
        .font(EditorTheme.font(16))
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(EditorTheme.ink)
        .background(EditorTheme.bubble, in: RoundedRectangle(cornerRadius: 16))
        .padding(.leading, 32)
    }

    @ViewBuilder private var interpretationProgress: some View {
        if let interpretation {
            switch interpretation.status {
            case "interpreted": Label("Cursor events interpreted", systemImage: "checkmark")
            case "interpreting": Label("Interpreting \(eventCount) cursor events", systemImage: "arrow.triangle.2.circlepath")
            case "failed": Label("Cursor interpretation failed: \(interpretation.error ?? "No result was returned")", systemImage: "xmark.circle")
            default: Label("Cursor interpretation status: \(interpretation.status)", systemImage: "exclamationmark.circle")
            }
        } else if engineEnabled {
            Label("Waiting to interpret cursor events", systemImage: "clock")
        } else {
            Label("Cursor interpretation unavailable", systemImage: "minus.circle")
        }
    }
}

struct RecordingAssistantBubble: View {
    let number: Int
    let jobs: [EditingEngine.Job]
    let interpretation: EditingEngine.Interpretation?
    let renderedJobIDs: Set<String>
    let cancel: (String) -> Void
    var changes: [EditingEngine.Change] = []
    var inspectedChangeID: String?
    var showChange: (String) -> Void = { _ in }

    private var completedCount: Int {
        jobs.filter { TaskProgress(job: $0, rendered: renderedJobIDs.contains($0.id)).isComplete }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "waveform").frame(width: 16, height: 16)
                    .frame(width: 24, height: 24).background(EditorTheme.cyan, in: Circle())
                Text("DASH · RECORDING \(number)").font(EditorTheme.font(9, mono: true)).tracking(0.5)
                Spacer(minLength: 4)
                if !jobs.isEmpty {
                    Text("\(completedCount) of \(jobs.count) complete").font(EditorTheme.font(11, mono: true))
                }
            }.foregroundStyle(EditorTheme.cyan)
            ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                ConversationTaskCard(number: index + 1, job: job,
                    rendered: renderedJobIDs.contains(job.id), cancel: { cancel(job.id) },
                    changeID: changes.last(where: { $0.taskID == job.id })?.id,
                    inspectedChangeID: inspectedChangeID, showChange: showChange)
            }
            if let needs = interpretation?.result?.needs_input, !needs.isEmpty {
                ForEach(Array(needs.enumerated()), id: \.offset) { _, need in
                    Label(need.message, systemImage: "questionmark.circle")
                        .font(EditorTheme.font(16)).foregroundStyle(EditorTheme.paper).textSelection(.enabled)
                }
            } else if jobs.isEmpty {
                Text("No tasks identified.").font(EditorTheme.font(16)).foregroundStyle(EditorTheme.paper)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConversationTaskCard: View {
    let number: Int
    let job: EditingEngine.Job
    let rendered: Bool
    let cancel: () -> Void
    var changeID: String?
    var inspectedChangeID: String?
    var showChange: (String) -> Void = { _ in }
    @State private var expanded = false

    private var progress: TaskProgress { TaskProgress(job: job, rendered: rendered) }
    private var referenceText: String { job.references.map(\.quote).joined(separator: "\n\n") }
    private var cancellable: Bool { !["completed", "answered", "failed", "conflict", "cancelled"].contains(job.state) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Task \(number)\(job.operation == "question" ? " · Question" : "")")
                .font(EditorTheme.font(16, bold: true))
                .onTapGesture { if let changeID { showChange(changeID) } }
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(job.references.enumerated()), id: \.offset) { index, reference in
                        VStack(alignment: .leading, spacing: 4) {
                            if job.references.count > 1 {
                                Text("PASSAGE \(index + 1)").font(EditorTheme.font(10, mono: true)).foregroundStyle(EditorTheme.cyan)
                            }
                            Text(reference.quote).font(EditorTheme.font(16)).lineSpacing(4).textSelection(.enabled)
                        }
                    }
                    Text("INSTRUCTION").font(EditorTheme.font(10, mono: true)).foregroundStyle(EditorTheme.cyan)
                    Text(job.displayInstruction).font(EditorTheme.font(16)).lineSpacing(4).textSelection(.enabled)
                }.padding(.top, 10)
            } label: {
                Text("Referenced text").font(EditorTheme.font(13)).foregroundStyle(EditorTheme.cyan)
            }.tint(EditorTheme.cyan)
            if !expanded {
                Text(referenceText.isEmpty ? "No explicit text reference." : referenceText)
                    .font(EditorTheme.font(16)).lineSpacing(4).lineLimit(2)
            }
            HStack(alignment: .top) {
                Label(progress.label, systemImage: icon)
                    .font(EditorTheme.font(13)).foregroundStyle(statusColor)
                Spacer(minLength: 4)
                if let changeID {
                    Button("Show changes") { showChange(changeID) }
                        .font(EditorTheme.font(13)).buttonStyle(.plain)
                        .foregroundStyle(EditorTheme.cyan)
                        .accessibilityIdentifier("show-changes-\(job.id)")
                }
                if cancellable { Button("Cancel", action: cancel).font(EditorTheme.font(13)).buttonStyle(.plain) }
            }
            if progress.kind == .failed, let error = job.error, !error.isEmpty {
                Text(error).font(EditorTheme.font(13)).foregroundStyle(statusColor).textSelection(.enabled)
            }
            if job.state == "answered", let answer = job.answer {
                Text(answer).font(EditorTheme.font(16)).lineSpacing(4).textSelection(.enabled)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(EditorTheme.paper)
        .background(EditorTheme.composer, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(
            changeID != nil && changeID == inspectedChangeID ? EditorTheme.cyan : .clear, lineWidth: 1))
        .accessibilityIdentifier("conversation-task-\(job.id)")
    }

    private var icon: String {
        switch progress.kind {
        case .working: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark"
        case .failed: return "xmark.circle"
        case .cancelled: return "minus.circle"
        }
    }
    private var statusColor: Color {
        progress.kind == .failed ? Color(red: 1, green: 0.65, blue: 0.55) : EditorTheme.cyan
    }
}
