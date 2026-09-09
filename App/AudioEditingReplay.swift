import Foundation
import EditorInteractionKit

struct AudioEditingReplay: Decodable {
    struct Gesture: Decodable { let at_ms: Double; let location: Int; let length: Int }
    let document: String
    let audio: String
    let duration_ms: Double
    let gestures: [Gesture]
}
