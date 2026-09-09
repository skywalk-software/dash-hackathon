import AVFoundation
import Combine
import CryptoKit
import EditorInteractionKit
import Foundation

@MainActor
final class CursorSessionStore: ObservableObject {
    enum StageStatus: Codable, Equatable {
        case pending, succeeded, cancelled
        case failed(String)

        var isFailure: Bool { if case .failed = self { return true }; return false }
    }
    struct CaptureProgress: Codable, Identifiable {
        let id: UUID
        var cursor: StageStatus = .pending
        var audio: StageStatus = .pending
        var hasFailure: Bool { cursor.isFailure || audio.isFailure }
    }
    @Published private(set) var progressByID: [UUID: CaptureProgress] = [:]
    @Published private(set) var latestProgressID: UUID?
    var latestProgress: CaptureProgress? { latestProgressID.flatMap { progressByID[$0] } }

    func progress(for id: UUID) -> CaptureProgress {
        guard let progress = progressByID[id] else { preconditionFailure("Missing capture progress for recording") }
        return progress
    }

    struct Package: Identifiable {
        let id: UUID
        let directory: URL
        let capture: CursorRecordingCapture
        var status: String
        var transcript: String?
        var assets: [AudioAsset] = []

        /// Frozen selections from this capture, excluding unchanged snapshots at Stop or cursor actions.
        var selectedTextEvents: [RecordingCursorEvent] {
            capture.events.filter { event in
                event.after.ranges.contains { !$0.isCaret } &&
                    (event.kind == .recordingStarted || event.after.ranges != event.before.ranges)
            }
        }
    }
    struct AudioAsset: Codable {
        let id: String
        let file: String
        let sha256: String
        let sampleRate: Double
        let sampleCount: Int64
        let channels: UInt32
    }
    @Published private(set) var recorder: CursorEventRecorder?
    @Published private(set) var packages: [Package] = []
    @Published private(set) var error: String?
    var onTranscriptReady: ((VoiceCaptureService.Recording, VoiceCaptureService.TranscriptionOutput) -> Void)?
    var onPackageUpdated: ((URL) -> Void)?
    private var generation = UUID()
    private var transcriptionTasks: [UUID: Task<Void, Never>] = [:]
    private let rootOverride: URL?
    private var abortedAtMs: [UUID: Double] = [:]
    var isRecording: Bool {
        guard let recorder else { return false }
        return recorder.isRecording && abortedAtMs[recorder.capture.recordingID] == nil
    }
    var currentID: UUID? { recorder?.capture.recordingID }
    var events: [RecordingCursorEvent] { recorder?.capture.events ?? [] }
    var elapsedMs: Double {
        guard let recorder else { return 0 }
        if let aborted = abortedAtMs[recorder.capture.recordingID] { return aborted }
        if let ended = recorder.capture.endTimestampMs { return ended }
        return Double(SessionClock.nowNanoseconds() - recorder.originNs) / 1_000_000
    }

    init(root: URL? = nil) { rootOverride = root }

    /// Resets this document session; completed packages remain on disk.
    func reset() throws {
        precondition(!isRecording, "Finish capture before restarting")
        generation = UUID()
        for task in transcriptionTasks.values { task.cancel() }
        for index in packages.indices where packages[index].status == "Transcription pending" {
            packages[index].status = "Transcription cancelled"
            try saveManifest(packages[index].id)
        }
        transcriptionTasks.removeAll()
        recorder = nil
        packages.removeAll()
        progressByID.removeAll()
        latestProgressID = nil
        abortedAtMs.removeAll()
        error = nil
    }

    func begin(document: DocumentSnapshot, ranges: [DocumentTextRange], atNs: UInt64) throws -> UUID {
        guard !isRecording else { throw EditorServiceError("A cursor recording is already active.") }
        error = nil
        let id = UUID()
        latestProgressID = id
        progressByID[id] = CaptureProgress(id: id)
        do {
            recorder = try CursorEventRecorder(recordingID: id, document: document, ranges: ranges, originNs: atNs)
        } catch {
            progressByID[id]?.cursor = .failed(error.localizedDescription)
            progressByID[id]?.audio = .cancelled
            throw error
        }
        return id
    }

    func observe(document: DocumentSnapshot, ranges: [DocumentTextRange], source: String, actionID: UUID?, atNs: UInt64, forceAction: Bool) throws {
        guard isRecording, var next = recorder else { return }
        do {
            try next.observe(document: document, ranges: ranges, source: source, actionID: actionID, atNs: atNs, forceAction: forceAction)
        } catch {
            progressByID[next.capture.recordingID]?.cursor = .failed(error.localizedDescription)
            throw error
        }
        recorder = next
    }

    @discardableResult
    func stop(atNs: UInt64, cancelled: Bool = false) throws -> UUID {
        guard var next = recorder else { throw EditorServiceError("No cursor recording is active.") }
        let id = next.capture.recordingID
        let cancelled = cancelled || progress(for: id).cursor.isFailure
        do {
            let capture = try next.finish(atNs: atNs, cancelled: cancelled)
            recorder = next
            let root: URL
            if let rootOverride { root = rootOverride }
            else {
                root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    .appendingPathComponent("DashHackathon/RecordingHandoffs", isDirectory: true)
            }
            let folder = root.appendingPathComponent(capture.recordingID.uuidString + ".recordingbundle", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try write(capture, to: folder.appendingPathComponent("capture.json"))
            if !progress(for: id).cursor.isFailure { progressByID[id]?.cursor = .succeeded }
            if cancelled { progressByID[id]?.audio = .cancelled }
            packages.append(Package(id: capture.recordingID, directory: folder, capture: capture,
                status: cancelled ? "Capture cancelled" : "Audio finalizing"))
            try saveManifest(capture.recordingID)
            return capture.recordingID
        } catch {
            abortedAtMs[id] = atNs >= next.originNs ? Double(atNs - next.originNs) / 1_000_000 : 0
            progressByID[id]?.cursor = .failed(error.localizedDescription)
            progressByID[id]?.audio = .cancelled
            throw error
        }
    }

    func attach(_ recording: VoiceCaptureService.Recording, voice: VoiceCaptureService) {
        guard let index = packages.firstIndex(where: { $0.id == recording.id }), packages[index].status == "Audio finalizing" else { return }
        do {
            guard let timing = recording.timing, timing.sessionOriginMonotonicNs == packages[index].capture.originMonotonicNs else { throw HandoffError.clockMismatch }
            try write(timing, to: packages[index].directory.appendingPathComponent("audio-timing.json"))
            packages[index].assets = [
                try copyAudio(recording.multichannelURL, id: "source", name: "source.wav", into: packages[index].directory),
                try copyAudio(recording.audioURL, id: "voice", name: "voice.wav", into: packages[index].directory)
            ]
            progressByID[recording.id]?.audio = .succeeded
            packages[index].status = "Transcription pending"
            try saveManifest(recording.id)
        } catch { audioFailed(recording.id, message: error.localizedDescription); return }
        let generation = self.generation
        transcriptionTasks[recording.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await voice.transcribeSession(recording)
                guard generation == self.generation else { return }
                try Task.checkCancellation()
                guard let index = packages.firstIndex(where: { $0.id == recording.id }), packages[index].status == "Transcription pending" else { return }
                var reference: AudioAsset?
                if let url = output.referenceAudioURL {
                    let asset = try copyAudio(url, id: "transcript_input", name: "asr-input.wav", into: packages[index].directory)
                    reference = asset
                    packages[index].assets.append(asset)
                }
                struct Transcript: Encodable {
                    let recordingID: UUID
                    let status: String
                    let provider: String
                    let text: String
                    let audioAssetID: String?
                    let audioSHA256: String?
                    let alignmentStatus: String
                    let alignmentFile: String?
                }
                try write(Transcript(recordingID: recording.id, status: "complete", provider: output.provider, text: output.text,
                    audioAssetID: reference?.id, audioSHA256: reference?.sha256,
                    alignmentStatus: output.alignmentResultURL == nil ? "not_available_forced_aligner_not_run" : "complete",
                    alignmentFile: output.alignmentResultURL == nil ? nil : "alignment.json"), to: packages[index].directory.appendingPathComponent("transcript.json"))
                packages[index].transcript = output.text
                if let alignment = output.alignmentResultURL {
                    try Data(contentsOf: alignment).write(to: packages[index].directory.appendingPathComponent("alignment.json"), options: .atomic)
                }
                if let remote = output.remoteArtifactDirectory {
                    let metadata = ["host": "configured-speech-service", "directory": remote, "asr_input": "asr-input.wav", "note": "Remote artifact reference."]
                    try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: packages[index].directory.appendingPathComponent("remote-artifacts.json"), options: .atomic)
                }
                packages[index].status = output.alignmentResultURL == nil ? "Ready for handoff · alignment not run" : "Ready · transcript aligned"
                try saveManifest(recording.id)
                onTranscriptReady?(recording, output)
            } catch is CancellationError {
                if generation == self.generation { cancelTranscription(recording.id) }
            } catch {
                if generation == self.generation { fail(recording.id, error) }
            }
            transcriptionTasks[recording.id] = nil
        }
    }

    /// Attach actual ASR/aligner output for file-audio emulation without changing
    /// the sealed capture log. The sample clock is the emulated recording clock.
    func attachAlignedAudio(_ id: UUID, audioURL: URL, resultURL: URL) {
        guard let index = packages.firstIndex(where: { $0.id == id }), packages[index].capture.status == "stopped" else { return }
        do {
            let data = try Data(contentsOf: resultURL)
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = result["text"] as? String, !text.isEmpty,
                  let words = result["words"] as? [[Any]], !words.isEmpty else { throw EditorServiceError("Alignment output is incomplete.") }
            let folder = packages[index].directory
            let asset = try copyAudio(audioURL, id: "aligned_input", name: "aligned-input.wav", into: folder)
            packages[index].assets.append(asset)
            try data.write(to: folder.appendingPathComponent("alignment.json"), options: .atomic)
            let transcript: [String: Any] = ["recordingID": id.uuidString, "status": "complete", "provider": "Qwen3-ASR",
                "text": text, "audioAssetID": asset.id, "audioSHA256": asset.sha256,
                "alignmentStatus": "complete", "alignmentFile": "alignment.json", "timestampUnit": "milliseconds"]
            try JSONSerialization.data(withJSONObject: transcript, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("transcript.json"), options: .atomic)
            let timing: [String: Any] = ["sessionOriginMonotonicNs": packages[index].capture.originMonotonicNs,
                "clockMappingStatus": "emulated_file_audio", "sampleZeroMs": 0]
            if !FileManager.default.fileExists(atPath: folder.appendingPathComponent("audio-timing.json").path) {
                try JSONSerialization.data(withJSONObject: timing, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("audio-timing.json"), options: .atomic)
            }
            packages[index].transcript = text
            progressByID[id]?.audio = .succeeded
            packages[index].status = "Ready · transcript aligned"
            try saveManifest(id)
        } catch { fail(id, error) }
    }

    func audioFailed(_ id: UUID, message: String) {
        progressByID[id]?.audio = .failed(message)
        fail(id, EditorServiceError(message))
    }

    func cancelTranscription(_ id: UUID) {
        transcriptionTasks[id]?.cancel()
        guard let index = packages.firstIndex(where: { $0.id == id }), packages[index].status == "Transcription pending" else { return }
        packages[index].status = "Transcription cancelled"
        do { try saveManifest(id) } catch { self.error = error.localizedDescription }
    }

    private func fail(_ id: UUID, _ failure: Error) {
        guard let index = packages.firstIndex(where: { $0.id == id }) else { error = failure.localizedDescription; return }
        packages[index].status = "Failed: \(failure.localizedDescription)"
        do { try saveManifest(id) } catch { self.error = "Could not save handoff status: \(error.localizedDescription)" }
    }

    private func copyAudio(_ source: URL, id: String, name: String, into folder: URL) throws -> AudioAsset {
        let data = try Data(contentsOf: source)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let destination = folder.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw EditorServiceError("An audio asset with this name already exists.") }
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        let audio = try AVAudioFile(forReading: destination)
        return AudioAsset(id: id, file: name, sha256: hash, sampleRate: audio.fileFormat.sampleRate,
            sampleCount: audio.length, channels: audio.fileFormat.channelCount)
    }

    private func saveManifest(_ id: UUID) throws {
        guard let package = packages.first(where: { $0.id == id }) else { return }
        struct Manifest: Encodable {
            let schemaVersion = 1
            let recordingID: UUID
            let status: String
            let captureProgress: CaptureProgress
            let captureFile = "capture.json"
            let audioTimingFile: String?
            let transcriptFile: String?
            let audioAssets: [AudioAsset]
            let alignmentFile: String?
            let remoteArtifactsFile: String?
        }
        try write(Manifest(recordingID: id, status: package.status, captureProgress: progress(for: id),
            audioTimingFile: package.assets.isEmpty ? nil : "audio-timing.json",
            transcriptFile: package.transcript == nil ? nil : "transcript.json", audioAssets: package.assets,
            alignmentFile: FileManager.default.fileExists(atPath: package.directory.appendingPathComponent("alignment.json").path) ? "alignment.json" : nil,
            remoteArtifactsFile: FileManager.default.fileExists(atPath: package.directory.appendingPathComponent("remote-artifacts.json").path) ? "remote-artifacts.json" : nil),
            to: package.directory.appendingPathComponent("manifest.json"))
        onPackageUpdated?(package.directory)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
