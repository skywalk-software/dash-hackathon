import Foundation
import Dispatch

public enum SessionClock {
    public static func nowNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    public static func microseconds(since origin: UInt64, at instant: UInt64) throws -> Int64 {
        guard instant >= origin, (instant - origin) / 1_000 <= UInt64(Int64.max) else { throw HandoffError.invalidTimestamp }
        return Int64((instant - origin) / 1_000)
    }
}

public struct AudioPacketTimingAnchor: Codable, Equatable, Sendable {
    public let sequence: UInt32
    public let deviceSampleIndexModulo: UInt16?
    public let decodedSampleCount: Int
    public let receivedSamplesBeforePacket: Int
    public let hostReceivedUs: Int64?
    public let hostConsumedUs: Int64
    public init(sequence: UInt32, deviceSampleIndexModulo: UInt16?, decodedSampleCount: Int,
                receivedSamplesBeforePacket: Int, hostReceivedUs: Int64?, hostConsumedUs: Int64) {
        self.sequence = sequence; self.deviceSampleIndexModulo = deviceSampleIndexModulo
        self.decodedSampleCount = decodedSampleCount; self.receivedSamplesBeforePacket = receivedSamplesBeforePacket
        self.hostReceivedUs = hostReceivedUs; self.hostConsumedUs = hostConsumedUs
    }
}

public struct AudioCaptureTiming: Codable, Equatable, Sendable {
    public let sessionOriginMonotonicNs: String
    public let hostStartAcknowledgedUs: Int64
    public var hostStopRequestedUs: Int64?
    public var hostStopAcknowledgedUs: Int64?
    public var packetAnchors: [AudioPacketTimingAnchor] = []
    public let clockMappingStatus: String
    public init(originNs: UInt64, startAcknowledgedUs: Int64, clockMappingStatus: String) {
        sessionOriginMonotonicNs = String(originNs); hostStartAcknowledgedUs = startAcknowledgedUs
        self.clockMappingStatus = clockMappingStatus
    }
}

public struct EditorTextPosition: Codable, Equatable, Sendable {
    public let line: Int
    public let column: Int
    public let utf16Offset: Int
    public var label: String { "(L\(line), C\(column))" }

    /// Logical, 1-based Unicode-scalar columns. CRLF is one line break; tabs count as one character.
    public init(utf16Offset: Int, in text: String) throws {
        guard utf16Offset >= 0 && utf16Offset <= text.utf16.count else { throw HandoffError.invalidRange }
        let scalars = Array(text.unicodeScalars)
        var offset = 0, row = 1, col = 1, index = 0
        while index < scalars.count && offset < utf16Offset {
            let value = scalars[index].value
            var width = value > 0xFFFF ? 2 : 1
            if value == 13, index + 1 < scalars.count, scalars[index + 1].value == 10 {
                width = 2; index += 1
            }
            guard offset + width <= utf16Offset else { throw HandoffError.invalidRange }
            offset += width
            if value == 10 || value == 13 { row += 1; col = 1 }
            else { col += 1 }
            index += 1
        }
        line = row; column = col; self.utf16Offset = utf16Offset
    }
}

public struct EditorCursorRange: Codable, Equatable, Sendable {
    public let start: EditorTextPosition
    public let end: EditorTextPosition
    public let utf16Range: DocumentTextRange
    public let selectedText: String
    public var isCaret: Bool { utf16Range.length == 0 }
    public var label: String { isCaret ? start.label : "\(start.label) → \(end.label)" }

    public init(_ range: DocumentTextRange, in text: String) throws {
        guard range.location >= 0, range.length >= 0, range.location <= text.utf16.count,
              range.length <= text.utf16.count - range.location else { throw HandoffError.invalidRange }
        start = try EditorTextPosition(utf16Offset: range.location, in: text)
        end = try EditorTextPosition(utf16Offset: range.location + range.length, in: text)
        utf16Range = range
        selectedText = (text as NSString).substring(with: range.nsRange)
    }
}

public struct EditorCursorSnapshot: Codable, Equatable, Sendable {
    public let documentID: UUID
    public let documentRevision: Int
    public let ranges: [EditorCursorRange]
    public init(document: DocumentSnapshot, ranges: [DocumentTextRange]) throws {
        documentID = document.documentID; documentRevision = document.revision
        self.ranges = try ranges.map { try EditorCursorRange($0, in: document.text) }
    }
    public var label: String { ranges.map(\.label).joined(separator: ", ") }
}

public enum CursorEventKind: String, Codable, Sendable {
    case recordingStarted = "recording_started"
    case cursorMoved = "cursor_moved"
    case selectionChanged = "selection_changed"
    case documentEdited = "document_edited"
    case cursorAction = "cursor_action"
    case recordingStopped = "recording_stopped"
    case recordingCancelled = "recording_cancelled"
}

public struct RecordingCursorEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sequence: Int
    public let timestampMs: Double
    public let kind: CursorEventKind
    public let source: String
    public let actionID: UUID?
    public let before: EditorCursorSnapshot
    public let after: EditorCursorSnapshot

    public var summary: String {
        switch kind {
        case .recordingStarted: return "Recording started · \(after.label)"
        case .recordingStopped: return "Recording stopped · \(after.label)"
        case .recordingCancelled: return "Recording cancelled · \(after.label)"
        case .cursorMoved: return "Cursor moved: \(before.label) → \(after.label)"
        case .selectionChanged:
            return after.ranges.contains(where: { !$0.isCaret }) ? "Selected: \(after.label)" : "Selection cleared: \(after.label)"
        case .documentEdited: return "Text edited · cursor: \(before.label) → \(after.label)"
        case .cursorAction: return "Cursor action: \(after.label)"
        }
    }
}

public struct CursorRecordingCapture: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let recordingID: UUID
    public let startedAt: Date
    public let originMonotonicNs: String
    public let clock: String
    public let timestampUnit: String
    public let coordinateBase: Int
    public let columnUnit: String
    public let rangeEndConvention: String
    public var status: String
    public var endTimestampMs: Double?
    public var documents: [DocumentSnapshot]
    public var events: [RecordingCursorEvent]
}

/// Append-only until the Stop click. No inference result can extend this event stream.
public struct CursorEventRecorder {
    public private(set) var capture: CursorRecordingCapture
    public let originNs: UInt64
    private var lastTimestampMs: Double = 0
    private var current: EditorCursorSnapshot
    private let maxEvents: Int
    public var isRecording: Bool { capture.status == "recording" }

    public init(recordingID: UUID = UUID(), document: DocumentSnapshot, ranges: [DocumentTextRange],
                originNs: UInt64, startedAt: Date = Date(), maxEvents: Int = 50_000) throws {
        guard maxEvents >= 2 else { throw HandoffError.eventLimit }
        self.originNs = originNs; self.maxEvents = maxEvents
        current = try EditorCursorSnapshot(document: document, ranges: ranges)
        capture = CursorRecordingCapture(schemaVersion: 1, recordingID: recordingID, startedAt: startedAt,
            originMonotonicNs: String(originNs), clock: "macOS_uptime_monotonic", timestampUnit: "milliseconds",
            coordinateBase: 1, columnUnit: "unicode_scalar_tab_counts_one", rangeEndConvention: "exclusive",
            status: "recording", documents: [document], events: [])
        append(kind: .recordingStarted, source: "record_button", actionID: nil, atMs: 0, after: current)
    }

    private mutating func timestamp(_ now: UInt64) throws -> Double {
        guard isRecording else { throw HandoffError.alreadyStopped }
        guard now >= originNs else { throw HandoffError.invalidTimestamp }
        let value = Double(now - originNs) / 1_000_000
        guard value >= lastTimestampMs else { throw HandoffError.invalidTimestamp }
        lastTimestampMs = value
        return value
    }

    public mutating func observe(document: DocumentSnapshot, ranges: [DocumentTextRange], source: String,
                                 actionID: UUID? = nil, atNs: UInt64, forceAction: Bool = false) throws {
        guard document.documentID == current.documentID else { throw InteractionError.wrongDocument }
        let after = try EditorCursorSnapshot(document: document, ranges: ranges)
        let at = try timestamp(atNs)
        guard forceAction || after != current else { return }
        guard capture.events.count < maxEvents - 1 else { throw HandoffError.eventLimit }
        if let existing = capture.documents.first(where: { $0.revision == document.revision }) {
            guard existing == document else { throw HandoffError.revisionCollision }
        } else { capture.documents.append(document) }
        let kind: CursorEventKind
        if after.documentRevision != current.documentRevision { kind = .documentEdited }
        else if after == current { kind = .cursorAction }
        else if after.ranges.allSatisfy(\.isCaret) && current.ranges.allSatisfy(\.isCaret) { kind = .cursorMoved }
        else { kind = .selectionChanged }
        append(kind: kind, source: source, actionID: actionID, atMs: at, after: after)
    }

    @discardableResult
    public mutating func finish(atNs: UInt64, cancelled: Bool = false) throws -> CursorRecordingCapture {
        let at = try timestamp(atNs)
        append(kind: cancelled ? .recordingCancelled : .recordingStopped, source: "record_button", actionID: nil, atMs: at, after: current)
        capture.endTimestampMs = at; capture.status = cancelled ? "cancelled" : "stopped"
        return capture
    }

    private mutating func append(kind: CursorEventKind, source: String, actionID: UUID?, atMs: Double, after: EditorCursorSnapshot) {
        capture.events.append(RecordingCursorEvent(id: UUID(), sequence: capture.events.count, timestampMs: atMs,
            kind: kind, source: source, actionID: actionID, before: current, after: after))
        current = after
    }
}

public enum HandoffError: Error, LocalizedError {
    case invalidTimestamp, alreadyStopped, invalidRange, revisionCollision, eventLimit, clockMismatch
    public var errorDescription: String? {
        switch self {
        case .invalidTimestamp: return "Cursor timestamps are not in recording-clock order."
        case .alreadyStopped: return "This recording's cursor log is already sealed."
        case .invalidRange: return "The cursor or selection is outside valid text character boundaries."
        case .revisionCollision: return "Different text snapshots have the same document revision."
        case .eventLimit: return "The recording reached its cursor-event limit; no events were silently dropped."
        case .clockMismatch: return "Audio and cursor capture do not share the same recording clock."
        }
    }
}
