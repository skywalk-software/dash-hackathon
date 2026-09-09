import SwiftUI

struct DeviceSettingsView: View {
    @ObservedObject var voice: VoiceCaptureService
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            Section("Microphone") {
                Text("Uses your Mac’s default input. Choose another microphone in System Settings → Sound → Input.")
                Text(voice.deviceDescription).foregroundStyle(.secondary)
                Button("Allow microphone access") { Task { await voice.connect() } }
                    .disabled(voice.state.isBusy)
            }
            Section("Powered by GPT-6 Astra") {
                Text("Astra understands your spoken requests, proposes edits, and reconciles them with your latest text. A separate speech service supplies the transcript and word times.")
                Text(ProcessInfo.processInfo.environment["DASH_ASR_URL"] ?? "http://127.0.0.1:8001")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text("Start the speech service and launch with scripts/run.py. Audio goes to your configured service; recordings and full document revisions remain on this Mac until you delete them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Done") { dismiss() }
        }.formStyle(.grouped).frame(width: 580, height: 400)
    }
}
