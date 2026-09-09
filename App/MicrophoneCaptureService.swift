import AVFoundation
import Foundation
import EditorInteractionKit

/// A deliberately small, stop-then-transcribe microphone adapter.
@MainActor
final class MicrophoneCaptureService: VoiceCaptureService {
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var recordingID: UUID?
    private var startedAt: Date?
    private var sampleZeroNs: UInt64?
    private var generation = 0

    override init() {
        super.init()
        deviceConnected = true // Request permission when the user first presses Record.
        deviceDescription = "Default Mac microphone"
    }

    override func connect() async {
        deviceConnected = await AVCaptureDevice.requestAccess(for: .audio)
        deviceDescription = deviceConnected ? "Default Mac microphone · ready" : "Microphone access denied · check System Settings → Privacy & Security"
        if !deviceConnected { state = .failed(deviceDescription) }
    }
    override func disconnect() async {
        await cancelCapture()
        deviceConnected = false
    }
    override func start(id: UUID = UUID(), clockOriginNs: UInt64 = SessionClock.nowNanoseconds()) async {
        guard !state.isBusy else { return }
        generation += 1
        let attempt = generation
        activeClockOriginNs = clockOriginNs
        state = .starting
        await connect()
        guard attempt == generation, state == .starting else { return }
        guard deviceConnected else { return }
        do {
            let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("DashHackathon/Microphone", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let audio = try AVAudioRecorder(url: folder.appendingPathComponent("\(id).wav"), settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
            ])
            audio.isMeteringEnabled = true
            guard audio.prepareToRecord() else { throw EditorServiceError("Could not prepare the microphone.") }
            let start = SessionClock.nowNanoseconds()
            guard audio.record() else { throw EditorServiceError("Could not start microphone recording.") }
            recorder = audio; recordingID = id; startedAt = Date(); sampleZeroNs = start
            activeClockOriginNs = clockOriginNs
            activeTiming = AudioCaptureTiming(originNs: clockOriginNs,
                startAcknowledgedUs: try SessionClock.microseconds(since: clockOriginNs, at: start),
                clockMappingStatus: "microphone_recorder_start_estimate")
            latest = nil; elapsed = 0; receivedPackets = 0; state = .recording
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let recorder = self.recorder, self.state == .recording else { return }
                    recorder.updateMeters()
                    self.elapsed = recorder.currentTime
                    self.level = Double(pow(10, recorder.averagePower(forChannel: 0) / 20))

                }
            }
        } catch { recorder?.stop(); recorder = nil; state = .failed(error.localizedDescription) }
    }
    override func stop() async {
        guard state == .recording, let recorder, let id = recordingID, let startedAt, let origin = activeClockOriginNs else { return }
        state = .stopping; timer?.invalidate(); timer = nil
        do {
            activeTiming?.hostStopRequestedUs = try SessionClock.microseconds(since: origin, at: SessionClock.nowNanoseconds())
            recorder.stop()
            let file = try AVAudioFile(forReading: recorder.url)
            let duration = Double(file.length) / file.fileFormat.sampleRate
            guard duration > 0 else { throw EditorServiceError("The microphone recording is empty.") }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recorder.url.path)
            activeTiming?.hostStopAcknowledgedUs = try SessionClock.microseconds(since: origin, at: SessionClock.nowNanoseconds())
            latest = Recording(id: id, sessionID: 0, startedAt: startedAt, duration: duration, packets: 0,
                sampleRate: Int(file.fileFormat.sampleRate), rmsDBFS: Double(recorder.averagePower(forChannel: 0)),
                firmware: "SYSTEM_MICROPHONE", audioURL: recorder.url, multichannelURL: recorder.url, timing: activeTiming)
            elapsed = duration; state = .completed; self.recorder = nil
        } catch { self.recorder = nil; state = .failed(error.localizedDescription) }
    }
    override func cancelCapture() async {
        generation += 1
        timer?.invalidate(); timer = nil
        recorder?.stop(); recorder = nil
        if state.isBusy { state = .cancelled }
    }
    override func transcribeSession(_ recording: Recording) async throws -> TranscriptionOutput {
        let env = ProcessInfo.processInfo.environment
        guard let base = URL(string: env["DASH_ASR_URL"] ?? "http://127.0.0.1:8001"),
              base.scheme == "https" || (base.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(base.host ?? "")) else {
            throw EditorServiceError("Speech service must use HTTPS or local HTTP.")
        }
        var request = URLRequest(url: base.appendingPathComponent("transcribe"))
        request.httpMethod = "POST"; request.timeoutInterval = 180
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        if let key = env["DASH_ASR_API_KEY"], !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.upload(for: request, from: Data(contentsOf: recording.audioURL))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw EditorServiceError("Speech service failed. Check that server/app.py is running and both Qwen models are loaded.")
        }
        struct Word: Decodable { let text: String; let start: Double; let end: Double }
        struct Transcript: Decodable { let text: String; let words: [Word] }
        let transcript = try JSONDecoder().decode(Transcript.self, from: data)
        guard !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !transcript.words.isEmpty else {
            throw EditorServiceError("No aligned speech returned. Try a short spoken request.")
        }
        // The server returns audio-relative seconds. The engine consumes session-relative milliseconds.
        let offset = Double(recording.timing?.hostStartAcknowledgedUs ?? 0) / 1000
        var previous = 0.0
        let words: [[Any]] = try transcript.words.map { word in
            guard word.start.isFinite, word.end.isFinite, word.start >= previous,
                  word.end >= word.start, word.end <= recording.duration + 0.25 else {
                throw EditorServiceError("Speech service returned invalid word timing.")
            }
            previous = word.start
            return [word.text, word.start * 1000 + offset, word.end * 1000 + offset]
        }
        let alignment: [String: Any] = ["text": transcript.text, "words": words,
            "duration_ms": max(recording.duration * 1000 + offset, (transcript.words.last?.end ?? 0) * 1000 + offset),
            "clock_mapping": "microphone_recorder_start_estimate", "timestampUnit": "milliseconds"]
        let url = recording.audioURL.deletingPathExtension().appendingPathExtension("alignment.json")
        try JSONSerialization.data(withJSONObject: alignment, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return TranscriptionOutput(text: transcript.text, provider: "qwen3_asr_forced_aligner",
            referenceAudioURL: recording.audioURL, alignmentResultURL: url)
    }
}
