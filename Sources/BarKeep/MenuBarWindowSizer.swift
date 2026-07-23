import AppKit
import SwiftUI

struct MenuContentSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct MenuBarWindowSizer: NSViewRepresentable {
    let contentSize: CGSize

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard contentSize.width > 0, contentSize.height > 0 else { return }

        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let targetFrame = Self.frame(
                preservingTopOf: window.frame,
                forContentSize: contentSize,
                in: window
            )
            guard targetFrame.size != context.coordinator.lastAppliedSize else { return }

            context.coordinator.lastAppliedSize = targetFrame.size
            window.setFrame(targetFrame, display: true, animate: false)
        }
    }

    static func frame(
        preservingTopOf currentFrame: NSRect,
        forContentSize contentSize: CGSize,
        in window: NSWindow
    ) -> NSRect {
        let targetSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: contentSize)
        ).size

        return NSRect(
            x: currentFrame.minX,
            y: currentFrame.maxY - targetSize.height,
            width: targetSize.width,
            height: targetSize.height
        )
    }

    final class Coordinator {
        var lastAppliedSize = CGSize.zero
    }
}
