import SwiftUI

@main
@MainActor
struct DashHackathonApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: EditorDocument()) { file in
            MicrophoneEditorWindow(document: file.$document, fileURL: file.fileURL)
        }.defaultSize(width: 1280, height: 872)
    }
}

private struct MicrophoneEditorWindow: View {
    @Binding var document: EditorDocument
    let fileURL: URL?
    @StateObject private var voice = MicrophoneCaptureService()
    var body: some View {
        EditorView(document: $document, fileURL: fileURL, voice: voice)
            .frame(minWidth: 1000, minHeight: 740)
    }
}
