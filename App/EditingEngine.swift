import AppKit
import Combine
import EditorInteractionKit
import Foundation
import Darwin

/// The native view and the helper exchange mutations synchronously. Inference never
/// runs inside this exchange: the helper only commits completed candidates on poll.
@MainActor
final class EditingEngine: ObservableObject {
    struct Reference: Codable, Equatable {
        let name: String?
        let paragraph: String
        let quote: String
        let selection_id: String?
    }
    struct Job: Decodable, Identifiable, Equatable {
        let id: String
        let recordingID: String?
        let state: String
        let instruction: String
        let operation: String
        let references: [Reference]
        let context: [String]
        let working_area: Reference?
        let outcome: String?
        let answer: String?
        let error: String?

        var displayInstruction: String {
            var text = instruction
            for (index, reference) in references.enumerated().sorted(by: { ($0.element.name?.count ?? 0) > ($1.element.name?.count ?? 0) }) {
                guard let name = reference.name, !name.isEmpty else { continue }
                text = text.replacingOccurrences(of: "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b",
                    with: "passage \(index + 1)", options: .regularExpression)
            }
            return text
        }
    }
    struct Change: Decodable, Identifiable, Equatable {
        struct Hunk: Decodable, Identifiable, Equatable {
            let id: String
            let before: String
            let after: String
            let location: Int
            let length: Int
            let active: Bool
        }
        let id: String
        let taskID: String?
        let instruction: String
        let committedAt: Double
        let beforeText: String
        let afterText: String
        let hunks: [Hunk]
    }
    @Published private(set) var changes: [Change] = []
    struct Interpretation: Decodable, Identifiable, Equatable {
        struct Need: Decodable, Equatable { let kind: String; let message: String }
        struct Result: Decodable, Equatable { let needs_input: [Need] }
        let recordingID: String
        let status: String
        let result: Result?
        let error: String?
        var id: String { recordingID }
    }
    @Published private(set) var interpretations: [Interpretation] = []
    @Published private(set) var renderedJobIDs = Set<String>()
    @Published private(set) var jobs: [Job] = []
    @Published private(set) var timingSummary: String?
    private var activeRecording: String?
    private var stoppedAt: [String: UInt64] = [:]
    private var appliedTimes: [String: [Double]] = [:]
    private var pendingRender: (text: String, jobs: [Job])?
    @Published private(set) var status = "Editing engine disabled"
    @Published private(set) var failure: String?
    var onAudioReady: ((UUID, URL, URL) -> Void)?
    private var deliveredAudio = Set<String>()
    var isComposing = false
    var onText: ((String, [DocumentTextRange]) -> Void)?
    private var evidenceDirectory: URL?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var timer: Timer?
    private var documentID = ""
    private var acknowledgedText = ""
    private var seenPackages = Set<String>()
    var isEnabled: Bool { process?.isRunning == true }
    var replayPath: String? { ProcessInfo.processInfo.environment["EDITOR_REPLAY_FILE"] }

    func start(document: DocumentSnapshot) {
        guard process == nil else { return }
        do {
            let environment = ProcessInfo.processInfo.environment
            guard let root = environment["EDITOR_ENGINE_PATH"], let node = environment["EDITOR_NODE"] else { return }
            if let path = environment["EDITOR_EVIDENCE_DIR"] {
                guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw EditorServiceError("The configured evidence output directory is empty.")
                }
                evidenceDirectory = URL(fileURLWithPath: path)
            } else {
                evidenceDirectory = nil
            }
            let p = Process(), to = Pipe(), from = Pipe()
            p.environment = environment
            p.currentDirectoryURL = URL(fileURLWithPath: root)
            p.executableURL = URL(fileURLWithPath: node)
            p.arguments = [URL(fileURLWithPath: root).appendingPathComponent("worker.mjs").path]
            p.standardInput = to; p.standardOutput = from; p.standardError = FileHandle.standardError
            try p.run(); process = p; input = to.fileHandleForWriting; output = from.fileHandleForReading
            documentID = document.documentID.uuidString; acknowledgedText = document.text
            _ = try request(["op": "init", "text": document.text], timeout: 15)
            status = "Ready · Automerge"
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
        } catch { fail(error) }
    }

    func reset(_ text: String) throws {
        guard isEnabled else { return }
        _ = try request(["op": "init", "text": text])
        seenPackages.removeAll(); deliveredAudio.removeAll(); stoppedAt.removeAll(); appliedTimes.removeAll(); renderedJobIDs.removeAll(); pendingRender = nil; timingSummary = nil
    }
    func edit(_ text: String) throws {
        guard isEnabled, text != acknowledgedText else { return }
        _ = try request(["op": "edit", "before": acknowledgedText, "text": text])
    }
    func begin(_ id: UUID) throws { guard isEnabled else { return }; activeRecording = id.uuidString; timingSummary = nil; _ = try request(["op": "begin", "recordingID": id.uuidString]) }
    func observe(_ ranges: [DocumentTextRange], atMs: Double, source: String, actionID: UUID?) throws {
        guard isEnabled else { return }
        _ = try request(["op": "observe", "ranges": ranges.map { ["location": $0.location, "length": $0.length] },
                         "at_ms": atMs, "source": source, "actionID": actionID?.uuidString ?? UUID().uuidString])
    }
    func end(atNs: UInt64 = SessionClock.nowNanoseconds()) {
        if let id = activeRecording { stoppedAt[id] = atNs }
        perform { _ = try request(["op": "end", "stopUptimeNs": String(atNs)]) }
    }
    func didRender(_ text: String, atNs: UInt64) {
        guard let pending = pendingRender, pending.text == text else { return }
        pendingRender = nil
        for job in pending.jobs where !renderedJobIDs.contains(job.id) {
            guard let id = job.recordingID, let stop = stoppedAt[id], atNs >= stop else { continue }
            renderedJobIDs.insert(job.id)
            let milliseconds = Double(atNs - stop) / 1_000_000
            appliedTimes[id, default: []].append(milliseconds)
            let times = appliedTimes[id]!
            timingSummary = String(format: "After Stop: first edit %.2f s · latest edit %.2f s", times.min()! / 1000, times.max()! / 1000)
            if let directory = ProcessInfo.processInfo.environment["EDITOR_EVIDENCE_DIR"] {
                let event: [String: Any] = ["event": "native_text_applied", "recordingID": id, "jobID": job.id,
                    "stop_to_apply_ms": milliseconds, "stop_uptime_ns": String(stop), "applied_uptime_ns": String(atNs)]
                let url = URL(fileURLWithPath: directory).appendingPathComponent("latency-events.jsonl")
                do {
                    var data = try JSONSerialization.data(withJSONObject: event, options: .sortedKeys); data.append(10)
                    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
                    let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
                    try file.seekToEnd(); try file.write(contentsOf: data)
                } catch { failure = "Could not save timing evidence: \(error.localizedDescription)" }
            }
        }
    }
    func cancelCapture() { perform { _ = try request(["op": "cancelCapture"]) } }
    func cancel(_ id: String) { perform { _ = try request(["op": "cancel", "jobID": id]) } }
    func processAudio(id: UUID, url: URL, durationMs: Double) {
        guard isEnabled, !seenPackages.contains(id.uuidString) else { return }
        seenPackages.insert(id.uuidString)
        perform { _ = try request(["op": "audio", "recordingID": id.uuidString, "audioPath": url.path, "duration_ms": durationMs]) }
    }
    func alignLiveTranscript(_ recording: VoiceCaptureService.Recording, output: VoiceCaptureService.TranscriptionOutput) {
        if let alignmentURL = output.alignmentResultURL {
            guard isEnabled, !seenPackages.contains(recording.id.uuidString) else { return }
            perform {
                guard let result = try JSONSerialization.jsonObject(with: Data(contentsOf: alignmentURL)) as? [String: Any],
                      let words = result["words"], let duration = result["duration_ms"] else { throw EditorServiceError("Speech alignment is incomplete.") }
                seenPackages.insert(recording.id.uuidString)
                _ = try request(["op": "process", "recordingID": recording.id.uuidString, "transcript": output.text, "words": words, "duration_ms": duration])
            }
            return
        }
        guard isEnabled, !seenPackages.contains(recording.id.uuidString), let audio = output.referenceAudioURL else { return }
        seenPackages.insert(recording.id.uuidString)
        let directory = recording.audioURL.deletingLastPathComponent()
        perform { _ = try request(["op": "audio", "recordingID": recording.id.uuidString, "audioPath": audio.path,
            "transcriptionResult": directory.appendingPathComponent("inference-result.json").path,
            "recordingMetadata": directory.appendingPathComponent("recording.json").path,
            "duration_ms": recording.duration * 1000]) }
    }
    private static var consumedRecoveries = Set<String>()
    func recoverFailedEdits(from directory: String) {
        guard Self.consumedRecoveries.insert(directory).inserted else { return }
        perform {
            var payload: [String: Any] = ["op": "recover", "directory": directory]
            if let plan = ProcessInfo.processInfo.environment["EDITOR_RECOVERY_PLAN"] { payload["planFile"] = plan }
            _ = try request(payload)
        }
    }
    /// Evidence export is an opt-in diagnostic feature, not part of normal editing.
    func exportEvidence(documentText: String) {
        guard let directory = evidenceDirectory else { return }
        perform {
            _ = try request(["op": "export"])
            try documentText.write(to: directory.appendingPathComponent("app-document.txt"),
                                   atomically: true, encoding: .utf8)
        }
    }
    func close() {
        timer?.invalidate(); timer = nil
        try? input?.close(); process?.terminate(); process = nil
        onText = nil; onAudioReady = nil
    }
    private func poll() { guard isEnabled, !isComposing else { return }; perform { _ = try request(["op": "poll"]) } }
    private func fail(_ error: Error) { failure = error.localizedDescription; status = "Editing paused"; timer?.invalidate(); process?.terminate() }
    private func perform(_ body: () throws -> Void) { do { try body() } catch { fail(error) } }
    @discardableResult private func request(_ payload: [String: Any], timeout: TimeInterval = 3) throws -> [String: Any] {
        guard let input, let output, process?.isRunning == true else { throw EditorServiceError("Editing engine is unavailable.") }
        var message = payload; message["documentID"] = documentID
        var data = try JSONSerialization.data(withJSONObject: message); data.append(10)
        try input.write(contentsOf: data)
        var reply = Data(); let deadline = Date().addingTimeInterval(timeout)
        while true {
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let remaining = max(0, deadline.timeIntervalSinceNow)
            guard remaining > 0, Darwin.poll(&descriptor, 1, Int32(remaining * 1000)) > 0 else { throw EditorServiceError("Editing engine stopped responding; document changes were paused.") }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(output.fileDescriptor, &buffer, buffer.count)
            guard count > 0 else { throw EditorServiceError("Editing engine exited.") }
            reply.append(contentsOf: buffer.prefix(count))
            if reply.last == 10 { reply.removeLast(); break }
            guard reply.count < 16_000_000 else { throw EditorServiceError("Editing engine response is too large.") }
        }
        guard let result = try JSONSerialization.jsonObject(with: reply) as? [String: Any], result["ok"] as? Bool == true else {
            let result = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
            throw EditorServiceError(result?["error"] as? String ?? "Invalid engine response")
        }
        if let text = result["text"] as? String, text != acknowledgedText {
            acknowledgedText = text
            // Human mutations already appear in NSTextView. Only polls may render
            // model commits, after the guarded transaction has acknowledged them.
            if payload["op"] as? String == "poll" {
                let mapped = (result["ranges"] as? [[String: Int]] ?? []).map { DocumentTextRange(location: $0["location"] ?? 0, length: $0["length"] ?? 0) }
                if let rawJobs = result["jobs"], let data = try? JSONSerialization.data(withJSONObject: rawJobs),
                   let currentJobs = try? JSONDecoder().decode([Job].self, from: data) {
                    pendingRender = (text, currentJobs.filter { $0.state == "completed" && !renderedJobIDs.contains($0.id) })
                }
                onText?(text, mapped)
            }
        }
        if let results = result["audioResults"] as? [[String: String]] {
            for audio in results {
                if let id = audio["recordingID"], let uuid = UUID(uuidString: id), !deliveredAudio.contains(id),
                   let audioPath = audio["audioPath"], let resultPath = audio["resultPath"] {
                    deliveredAudio.insert(id)
                    onAudioReady?(uuid, URL(fileURLWithPath: audioPath), URL(fileURLWithPath: resultPath))
                }
            }
        }
        if let raw = result["changes"] { changes = try JSONDecoder().decode([Change].self, from: JSONSerialization.data(withJSONObject: raw)) }
        if let raw = result["jobs"] { jobs = try JSONDecoder().decode([Job].self, from: JSONSerialization.data(withJSONObject: raw)) }
        if let error = result["error"] as? String { failure = error }
        if let phase = result["phase"] as? String { status = phase }
        if let raw = result["interpretations"] {
            interpretations = try JSONDecoder().decode([Interpretation].self, from: JSONSerialization.data(withJSONObject: raw))
        }
        if let records = result["interpretations"] as? [[String: Any]],
           let latest = records.last, let r = latest["result"] as? [String: Any],
           let needs = r["needs_input"] as? [[String: Any]], !needs.isEmpty {
            status = needs.compactMap { $0["message"] as? String }.joined(separator: " · ")
        }
        return result
    }
}
