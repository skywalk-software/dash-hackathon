import Foundation

public struct DocumentChange: Equatable, Sendable {
    public let replacedRange: DocumentTextRange
    public let insertedUTF16Count: Int

    public init(before: String, after: String) {
        let old = Array(before), new = Array(after)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count - prefix, new.count - prefix), old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        replacedRange = DocumentTextRange(location: String(old.prefix(prefix)).utf16.count,
            length: String(old[prefix..<(old.count - suffix)]).utf16.count)
        insertedUTF16Count = String(new[prefix..<(new.count - suffix)]).utf16.count
    }
}

public extension DocumentTextRange {
    func following(_ change: DocumentChange) -> DocumentTextRange {
        let edit = change.replacedRange
        if location >= edit.location + edit.length {
            return DocumentTextRange(location: location + change.insertedUTF16Count - edit.length, length: length)
        }
        if location + length <= edit.location { return self }
        return DocumentTextRange(location: edit.location + change.insertedUTF16Count, length: 0)
    }
}

public struct TrackedTextTarget: Equatable, Sendable {
    public let id: UUID
    public let documentID: UUID
    public private(set) var range: DocumentTextRange
    public private(set) var invalidated = false

    public init(_ target: TextTarget) { id = target.id; documentID = target.documentID; range = target.range }

    public mutating func follow(_ change: DocumentChange) {
        guard !invalidated else { return }
        let start = range.location, end = start + range.length
        let editStart = change.replacedRange.location
        let editEnd = editStart + change.replacedRange.length
        let delta = change.insertedUTF16Count - change.replacedRange.length
        if change.replacedRange.length == 0 && change.insertedUTF16Count == 0 { return }
        if range.length == 0 { invalidated = true; return }
        if editEnd <= start && editStart < start { range.location += delta }
        else if editStart > end || (editStart == end && change.replacedRange.length > 0) { return }
        else if editStart >= start && editEnd <= end {
            range.length += delta
            if range.length == 0 { invalidated = true }
        } else { invalidated = true }
    }

    public func text(in snapshot: DocumentSnapshot) throws -> String {
        guard snapshot.documentID == documentID else { throw InteractionError.wrongDocument }
        guard !invalidated else { throw InteractionError.staleTarget }
        return String(snapshot.text[try range.validated(in: snapshot.text)])
    }
}

public enum MockRewriter {
    public static let apologyInstruction = "Make this warmer and more direct. Own the mistake without making excuses."
    public static let resolutionInstruction = "Make the resolution easy to scan, keeping the delivery day, refund, tracking, and what to do if it is late."

    public static func rewrite(text: String, instruction: String) throws -> String {
        if instruction == apologyInstruction, text.contains("warehouse"), text.contains("lamp") {
            return "I’m sorry we didn’t ship your lamp when we promised. A processing delay at our warehouse caused the problem, and you should not have had to contact us to find out what happened. We know you were counting on the lamp arriving sooner, and we’re working to put this right."
        }
        if instruction == resolutionInstruction {
            let pattern = #"Your lamp will arrive on (.+?), and we will refund the (\$[0-9]+(?:\.[0-9]{2})?) shipping charge"#
            let regex = try NSRegularExpression(pattern: pattern)
            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
                throw InteractionError.staleTarget
            }
            let source = text as NSString
            let day = source.substring(with: match.range(at: 1)), refund = source.substring(with: match.range(at: 2))
            return "Here’s what happens next:\n• Your lamp will arrive on \(day).\n• We will refund the \(refund) shipping charge to your original payment method; no extra request is needed.\n• We will email your tracking link when the package leaves our warehouse.\n• If it hasn’t arrived by \(day), reply to this email so we can investigate and help."
        }
        throw InteractionError.staleTarget
    }
}
