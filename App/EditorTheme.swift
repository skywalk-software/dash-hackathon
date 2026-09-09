import AppKit
import SwiftUI

/// System typography keeps the starter self-contained.
enum EditorTheme {
    static let ink = Color(red: 10 / 255, green: 10 / 255, blue: 10 / 255)
    static let navy = Color(red: 0, green: 51 / 255, blue: 102 / 255)
    static let cyan = Color(red: 125 / 255, green: 249 / 255, blue: 1)
    static let paper = Color(red: 250 / 255, green: 249 / 255, blue: 236 / 255)
    static let bubble = Color(red: 229 / 255, green: 254 / 255, blue: 1)
    static let composer = Color(white: 0.2)
    static let muted = Color(white: 0.81)

    static func nativeFont(_ size: CGFloat, bold: Bool = false, mono: Bool = false) -> NSFont {
        return mono ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size, weight: bold ? .bold : .regular)
    }
    static func font(_ size: CGFloat, bold: Bool = false, mono: Bool = false) -> Font {
        Font(nativeFont(size, bold: bold, mono: mono))
    }
}

struct EditorButtonStyle: ButtonStyle {
    var filled = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(EditorTheme.font(16, bold: true))
            .padding(.horizontal, 16).frame(minHeight: 36)
            .foregroundStyle(filled ? EditorTheme.ink : EditorTheme.navy)
            .background(filled ? EditorTheme.cyan : EditorTheme.paper, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(filled ? Color.clear : EditorTheme.navy, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }
}
