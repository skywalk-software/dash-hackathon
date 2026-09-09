import EditorInteractionKit
import SwiftUI
import UniformTypeIdentifiers

struct EditorDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var model: TextDocumentState

    init(text: String = "") { model = TextDocumentState(text: text) }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        model = TextDocumentState(text: try TextFileCodec.decode(data))
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: TextFileCodec.encode(model.snapshot.text))
    }
}

struct InteractionJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

extension UTType {
    static let recordingPackage = UTType(exportedAs: "org.dashhackathon.recording-package", conformingTo: .package)
}

struct RecordingPackageDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.recordingPackage] }
    let files: [String: Data]
    init(directory: URL) throws { files = try Self.read(FileWrapper(url: directory, options: .immediate)) }
    init(configuration: ReadConfiguration) throws { files = try Self.read(configuration.file) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(directoryWithFileWrappers: files.mapValues { FileWrapper(regularFileWithContents: $0) })
    }
    private static func read(_ directory: FileWrapper) throws -> [String: Data] {
        guard let wrappers = directory.fileWrappers else { throw CocoaError(.fileReadCorruptFile) }
        var files: [String: Data] = [:]
        for (name, wrapper) in wrappers {
            guard wrapper.isRegularFile, let contents = wrapper.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
            files[name] = contents
        }
        return files
    }
}
