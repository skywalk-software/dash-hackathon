import AppKit
import SwiftUI

/// Preserve the visible bubble and its pixel offset when an earlier bubble grows.
struct ConversationScrollView<Content: View>: View {
    let revision: Int
    let content: Content
    @State private var hasUpdates = false
    @State private var jump = 0

    init(revision: Int, @ViewBuilder content: () -> Content) {
        self.revision = revision
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            NativeConversationScroll(content: AnyView(content), revision: revision, jump: jump,
                onUpdates: { hasUpdates = $0 })
            if hasUpdates {
                Button("New or updated activity ↓") { jump += 1 }
                    .font(EditorTheme.font(13, bold: true)).buttonStyle(.plain)
                    .foregroundStyle(EditorTheme.ink).padding(.horizontal, 14).padding(.vertical, 9)
                    .background(EditorTheme.cyan, in: Capsule()).padding(.bottom, 8)
                    .accessibilityIdentifier("conversation-new-activity")
            }
        }
    }
}

private final class ConversationAnchorRegistry {
    private struct WeakView { weak var view: NSView? }
    private var views: [String: WeakView] = [:]
    func register(_ view: NSView, id: String) { views[id] = WeakView(view: view) }
    @MainActor func frames(in document: NSView) -> [(String, NSRect)] {
        views.compactMap { id, reference in
            guard let view = reference.view, view.isDescendant(of: document) else { return nil }
            return (id, document.convert(view.bounds, from: view))
        }.sorted { $0.1.minY < $1.1.minY }
    }
}

private struct ConversationAnchorKey: EnvironmentKey {
    static let defaultValue = ConversationAnchorRegistry()
}
private extension EnvironmentValues {
    var conversationAnchors: ConversationAnchorRegistry {
        get { self[ConversationAnchorKey.self] }
        set { self[ConversationAnchorKey.self] = newValue }
    }
}

struct ConversationAnchor: NSViewRepresentable {
    let id: String
    @Environment(\.conversationAnchors) private var registry
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        registry.register(view, id: id)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { registry.register(view, id: id) }
}

private struct NativeConversationScroll: NSViewRepresentable {
    let content: AnyView
    let revision: Int
    let jump: Int
    let onUpdates: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = LayoutScrollView(frame: NSRect(x: 0, y: 0, width: 392, height: 600))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.setAccessibilityLabel("Conversation history")
        scroll.setAccessibilityIdentifier("conversation-history")
        context.coordinator.attach(scroll)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(content: content, revision: revision, jump: jump, onUpdates: onUpdates)
    }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) { coordinator.detach() }

    @MainActor final class Coordinator {
        private let registry = ConversationAnchorRegistry()
        private weak var scroll: NSScrollView?
        private var host: ConversationHostingView?
        private var content = AnyView(EmptyView())
        private var observer: NSObjectProtocol?
        private var onUpdates: ((Bool) -> Void)?
        private var followsBottom = true
        private var anchor: (id: String, offset: CGFloat)?
        private var lastY: CGFloat = 0
        private var lastWidth: CGFloat = 0
        private var lastRevision = -1
        private var lastJump = 0
        private var measuring = false
        private var scheduled = false
        private var suppressBounds = false
        private var reportedUpdates = false

        func attach(_ scroll: LayoutScrollView) {
            self.scroll = scroll
            let host = ConversationHostingView(rootView: AnyView(EmptyView()))
            self.host = host
            host.isFlipped = true
            scroll.documentView = host
            host.onSizeChange = { [weak self] in self?.scheduleLayout() }
            scroll.onLayout = { [weak self] in self?.scheduleLayout() }
            scroll.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.boundsChanged() }
                }
        }
        func detach() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            host?.onSizeChange = nil
            scroll = nil
        }
        func update(content: AnyView, revision: Int, jump: Int, onUpdates: @escaping (Bool) -> Void) {
            self.onUpdates = onUpdates
            if lastRevision >= 0, lastRevision != revision, !followsBottom { reportUpdates(true) }
            lastRevision = revision
            if jump != lastJump { followsBottom = true; reportUpdates(false); lastJump = jump }
            self.content = content
            installRoot()
            scheduleLayout()
        }
        private func installRoot() {
            guard let scroll, let host else { return }
            let width = max(1, scroll.contentView.bounds.width)
            lastWidth = width
            host.rootView = AnyView(content.environment(\.conversationAnchors, registry)
                .frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true))
        }
        private func scheduleLayout() {
            guard !measuring, !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.layout()
            }
        }
        private func layout() {
            guard let scroll, let host else { return }
            measuring = true; suppressBounds = true
            defer { measuring = false; suppressBounds = false }
            let width = max(1, scroll.contentView.bounds.width)
            if abs(width - lastWidth) > 0.5 { installRoot() }
            host.setFrameSize(NSSize(width: width, height: host.frame.height))
            host.layoutSubtreeIfNeeded()
            let height = max(0, host.fittingSize.height)
            host.setFrameSize(NSSize(width: width, height: height))
            host.layoutSubtreeIfNeeded()
            let maximum = max(0, height - scroll.contentView.bounds.height)
            var position = scroll.contentView.bounds.minY
            if followsBottom { position = maximum }
            else if let anchor, let frame = registry.frames(in: host).first(where: { $0.0 == anchor.id })?.1 {
                position = frame.minY + anchor.offset
            }
            position = min(maximum, max(0, position))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: position))
            scroll.reflectScrolledClipView(scroll.contentView)
            lastY = position
            rememberAnchor()
        }
        private func boundsChanged() {
            guard let scroll, let host, !suppressBounds else { return }
            let y = scroll.contentView.bounds.minY
            guard abs(y - lastY) > 0.5 else { return }
            lastY = y
            followsBottom = host.frame.height - scroll.contentView.bounds.maxY < 24
            rememberAnchor()
            if followsBottom { reportUpdates(false) }
        }
        private func rememberAnchor() {
            guard let scroll, let host else { return }
            let y = scroll.contentView.bounds.minY
            if let first = registry.frames(in: host).first(where: { $0.1.maxY > y + 1 }) {
                anchor = (first.0, y - first.1.minY)
            }
        }
        private func reportUpdates(_ value: Bool) {
            guard value != reportedUpdates else { return }
            reportedUpdates = value
            DispatchQueue.main.async { [weak self] in self?.onUpdates?(value) }
        }
    }

    final class LayoutScrollView: NSScrollView {
        var onLayout: (() -> Void)?
        override func tile() { super.tile(); onLayout?() }
    }
    final class ConversationHostingView: NSHostingView<AnyView> {
        var onSizeChange: (() -> Void)?
        override func invalidateIntrinsicContentSize() { super.invalidateIntrinsicContentSize(); onSizeChange?() }
        override func layout() { super.layout(); onSizeChange?() }
    }
}
