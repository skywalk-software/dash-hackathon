import Foundation

public struct DocumentTextRange: Codable, Equatable, Sendable {
    public var location: Int
    public var length: Int
    public init(location: Int, length: Int) { self.location = location; self.length = length }
    public var nsRange: NSRange { NSRange(location: location, length: length) }

    public func validated(in text: String) throws -> Range<String.Index> {
        guard location >= 0, length >= 0, location <= text.utf16.count,
              length <= text.utf16.count - location,
              let range = Range(nsRange, in: text),
              (range.lowerBound == text.endIndex || text.indices.contains(range.lowerBound)),
              (range.upperBound == text.endIndex || text.indices.contains(range.upperBound)) else { throw InteractionError.invalidRange }
        return range
    }
}

public struct DocumentSnapshot: Codable, Equatable, Sendable {
    public let documentID: UUID
    public let revision: Int
    public let text: String
    public init(documentID: UUID, revision: Int, text: String) {
        self.documentID = documentID; self.revision = revision; self.text = text
    }
}

public struct TextTarget: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let documentID: UUID
    public let revision: Int
    public let range: DocumentTextRange
    public let exactText: String
    public let prefix: String
    public let suffix: String

    public init(snapshot: DocumentSnapshot, range: DocumentTextRange) throws {
        let indices = try range.validated(in: snapshot.text)
        id = UUID(); documentID = snapshot.documentID; revision = snapshot.revision
        self.range = range
        exactText = String(snapshot.text[indices])
        prefix = String(snapshot.text[..<indices.lowerBound].suffix(24))
        suffix = String(snapshot.text[indices.upperBound...].prefix(24))
    }

    /// Rebase only an exact, unique text-and-context match. Changed or ambiguous targets fail.
    public func resolve(in snapshot: DocumentSnapshot) throws -> DocumentTextRange {
        guard documentID == snapshot.documentID else { throw InteractionError.wrongDocument }
        if revision == snapshot.revision {
            let indices = try range.validated(in: snapshot.text)
            guard String(snapshot.text[indices]) == exactText else { throw InteractionError.staleTarget }
            return range
        }
        guard !exactText.isEmpty else { throw InteractionError.staleTarget }
        let needle = exactText
        let text = snapshot.text as NSString
        var search = NSRange(location: 0, length: text.length)
        var matches: [NSRange] = []
        while search.length > 0 {
            let match = text.range(of: needle, options: .literal, range: search)
            if match.location == NSNotFound { break }
            matches.append(match)
            let next = match.location + 1
            search = NSRange(location: next, length: text.length - next)
        }
        if matches.count > 1 {
            matches = matches.filter { match in
                guard match.location >= prefix.utf16.count,
                      text.length - NSMaxRange(match) >= suffix.utf16.count else { return false }
                return text.substring(with: NSRange(location: match.location - prefix.utf16.count, length: prefix.utf16.count)) == prefix
                    && text.substring(with: NSRange(location: NSMaxRange(match), length: suffix.utf16.count)) == suffix
            }
        }
        guard matches.count <= 1 else { throw InteractionError.ambiguousTarget }
        guard let match = matches.first else { throw InteractionError.staleTarget }
        let resolved = DocumentTextRange(location: match.location, length: exactText.utf16.count)
        _ = try resolved.validated(in: snapshot.text)
        return resolved
    }
}

public struct DocumentInteractionContext: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let document: DocumentSnapshot
    public let target: TextTarget
    public init(document: DocumentSnapshot, selection: DocumentTextRange) throws {
        schemaVersion = 1; self.document = document
        target = try TextTarget(snapshot: document, range: selection)
    }
}

public struct VoiceInteractionInput: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let context: DocumentInteractionContext
    public let audioURL: URL
    public let capturedAt: Date
    public let sampleRate: Int
    public let duration: Double
    public init(context: DocumentInteractionContext, audioURL: URL, capturedAt: Date, sampleRate: Int, duration: Double) {
        id = UUID(); self.context = context; self.audioURL = audioURL
        self.capturedAt = capturedAt; self.sampleRate = sampleRate; self.duration = duration
    }
}

public struct TextDocumentState: Equatable, Sendable {
    public private(set) var snapshot: DocumentSnapshot
    public init(text: String = "") { snapshot = DocumentSnapshot(documentID: UUID(), revision: 0, text: text) }

    public mutating func updateText(_ text: String) {
        guard text != snapshot.text else { return }
        snapshot = DocumentSnapshot(documentID: snapshot.documentID, revision: snapshot.revision + 1, text: text)
    }

    /// Applies an approved edit only to the exact document revision the caller inspected.
    @discardableResult
    public mutating func replace(target: TextTarget, expectedRevision: Int, with replacement: String) throws -> DocumentTextRange {
        guard expectedRevision == snapshot.revision else { throw InteractionError.staleRevision }
        let range = try target.resolve(in: snapshot)
        let indices = try range.validated(in: snapshot.text)
        var text = snapshot.text
        text.replaceSubrange(indices, with: replacement)
        updateText(text)
        return DocumentTextRange(location: range.location, length: replacement.utf16.count)
    }
}

public enum TextFileCodec {
    public static func decode(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else { throw InteractionError.invalidUTF8 }
        return text
    }
    public static func encode(_ text: String) -> Data { Data(text.utf8) }
}

public enum InteractionError: Error, LocalizedError, Equatable {
    case invalidRange, wrongDocument, staleTarget, ambiguousTarget, staleRevision, invalidUTF8
    public var errorDescription: String? {
        switch self {
        case .invalidRange: return "The text selection is outside the document or splits a Unicode character."
        case .wrongDocument: return "The target belongs to another document."
        case .staleTarget: return "The selected text or its context has changed. Select the target again."
        case .ambiguousTarget: return "More than one text target matches. Select the target again."
        case .staleRevision: return "The document changed while the edit was being prepared. Review it again."
        case .invalidUTF8: return "This file is not valid UTF-8 text. Convert its encoding before opening it."
        }
    }
}
