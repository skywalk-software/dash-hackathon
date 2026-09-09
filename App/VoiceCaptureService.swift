import AVFoundation
import Combine
import Foundation
import EditorInteractionKit

@MainActor
class VoiceCaptureService: ObservableObject {
    enum State: Equatable {
        case idle, starting, recording, stopping, completed, cancelled, failed(String)
        var isBusy: Bool { self == .starting || self == .recording || self == .stopping }
        var label: String {
            switch self {
            case .idle: return "Ready to record"
            case .starting: return "Starting capture…"
            case .recording: return "Recording"
            case .stopping: return "Finishing recording…"
            case .completed: return "Voice recording saved"
            case .cancelled: return "Capture cancelled"
            case .failed(let message): return "Recording failed: \(message)"
            }
        }
    }
    struct Recording: Codable, Equatable, Identifiable {
        let id: UUID
        let sessionID: UInt32
        let startedAt: Date
        let duration: Double
        let packets: Int
        let sampleRate: Int
        let rmsDBFS: Double
        let firmware: String
        let audioURL: URL
        let multichannelURL: URL
        var timing: AudioCaptureTiming? = nil
    }
    struct TranscriptionOutput {
        let text: String
        let provider: String
        let referenceAudioURL: URL?
        var alignmentResultURL: URL? = nil
        var remoteArtifactDirectory: String? = nil
    }
    @Published var enhancementStatus: String?
    @Published var state: State = .idle
    @Published var receivedPackets = 0
    @Published var elapsed: Double = 0
    @Published var level: Double = 0
    @Published var latest: Recording?
    @Published var deviceConnected = false
    @Published var deviceDescription = "Not connected"
    var isMock: Bool { false }
    private var player: AVAudioPlayer?
    var activeTiming: AudioCaptureTiming?
    var activeClockOriginNs: UInt64?

    func connect() async { preconditionFailure("A concrete device adapter is required") }
    func disconnect() async { preconditionFailure("A concrete device adapter is required") }
    func start(id: UUID = UUID(), clockOriginNs: UInt64 = SessionClock.nowNanoseconds()) async { preconditionFailure("A concrete capture adapter is required") }
    func stop() async { preconditionFailure("A concrete capture adapter is required") }
    func cancelCapture() async { preconditionFailure("A concrete capture adapter is required") }
    func resetPresentation() {
        precondition(!state.isBusy, "Finish capture before resetting the demo")
        latest = nil; state = .idle; elapsed = 0; receivedPackets = 0; level = 0
        player?.stop(); player = nil
        activeTiming = nil; activeClockOriginNs = nil
    }
    func transcribe(_ recording: Recording, context: DocumentInteractionContext) async throws -> String {
        throw EditorServiceError("An authenticated transcription adapter is not configured.")
    }
    func transcribeSession(_ recording: Recording) async throws -> TranscriptionOutput {
        throw EditorServiceError("A recording-session transcription adapter is not configured.")
    }
    func play() throws {
        guard let latest, !state.isBusy else { throw EditorServiceError("No completed recording is available.") }
        player = try AVAudioPlayer(contentsOf: latest.audioURL)
        guard player?.play() == true else { throw EditorServiceError("Could not play the recording.") }
    }
}

struct EditorServiceError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
final class MockVoiceCaptureService: VoiceCaptureService {
    override var isMock: Bool { true }
    private var startedAt: Date?
    private var requestID: UUID?
    private var mockAudioStartNs: UInt64?
    override init() {
        super.init()
        deviceConnected = true
        deviceDescription = "Mock audio · synthetic tone, no microphone"
    }
    override func connect() async { deviceConnected = true }
    override func disconnect() async { deviceConnected = false }
    override func start(id: UUID = UUID(), clockOriginNs: UInt64 = SessionClock.nowNanoseconds()) async {
        guard !state.isBusy else { return }
        requestID = id; startedAt = Date(); latest = nil
        receivedPackets = 0; elapsed = 0; level = 0
        activeClockOriginNs = clockOriginNs
        let acknowledged = SessionClock.nowNanoseconds()
        mockAudioStartNs = acknowledged
        do {
            activeTiming = AudioCaptureTiming(originNs: clockOriginNs,
                startAcknowledgedUs: try SessionClock.microseconds(since: clockOriginNs, at: acknowledged),
                clockMappingStatus: "synthetic_audio_starts_at_acknowledgment")
        } catch { state = .failed(error.localizedDescription); return }
        state = .recording
    }
    override func stop() async {
        guard state == .recording, let startedAt, let requestID else { return }
        state = .stopping
        do {
            guard let origin = activeClockOriginNs, let audioStart = mockAudioStartNs else {
                throw EditorServiceError("Mock recording timing is missing.")
            }
            let stopped = SessionClock.nowNanoseconds()
            let duration = Double(stopped - audioStart) / 1_000_000_000
            guard duration <= 120 else { throw EditorServiceError("Mock recordings must be at most 120 seconds.") }
            let frameCount = max(1, Int(duration * 16_000))
            activeTiming?.hostStopRequestedUs = try SessionClock.microseconds(since: origin, at: stopped)
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("DashHackathon/MockAudio", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(requestID).wav")
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
            let file = try AVAudioFile(forWriting: url, settings: settings)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frameCount)),
                  let samples = buffer.floatChannelData?[0] else { throw EditorServiceError("Could not allocate mock audio.") }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            for index in 0..<frameCount { samples[index] = 0.03 * sin(Float(index) * 2 * .pi * 220 / 16_000) }
            try file.write(from: buffer)
            activeTiming?.hostStopAcknowledgedUs = try SessionClock.microseconds(since: origin, at: SessionClock.nowNanoseconds())
            latest = Recording(id: requestID, sessionID: 0, startedAt: startedAt, duration: Double(frameCount) / 16_000,
                packets: (frameCount + 319) / 320, sampleRate: 16_000, rmsDBFS: -33.5, firmware: "MOCK",
                audioURL: url, multichannelURL: url, timing: activeTiming)
            receivedPackets = (frameCount + 319) / 320; elapsed = Double(frameCount) / 16_000; state = .completed
        } catch { state = .failed(error.localizedDescription) }
    }
    override func cancelCapture() async {
        guard state.isBusy else { return }
        requestID = nil; startedAt = nil; latest = nil; state = .cancelled
    }
    override func transcribe(_ recording: Recording, context: DocumentInteractionContext) async throws -> String {
        try await Task.sleep(for: .milliseconds(400))
        if context.target.exactText.contains("Your lamp will arrive") { return MockRewriter.resolutionInstruction }
        if context.target.exactText.contains("warehouse") && context.target.exactText.contains("lamp") { return MockRewriter.apologyInstruction }
        throw EditorServiceError("The scripted mock supports the two paragraphs in the customer-apology demo. Select one complete paragraph.")
    }
    override func transcribeSession(_ recording: Recording) async throws -> TranscriptionOutput {
        try await Task.sleep(for: .milliseconds(400))
        return TranscriptionOutput(text: "Make the first selection more concise. Turn the second selection into bullet points.",
            provider: "scripted_mock_not_speech_recognition", referenceAudioURL: nil)
    }
}
