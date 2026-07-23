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
            context.coordinator.update(window: window, contentSize: contentSize)
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.detach()
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

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var desiredContentSize = CGSize.zero
        private var anchorTopY: CGFloat?
        private var observers: [NSObjectProtocol] = []
        private var correctionScheduled = false

        func update(window: NSWindow, contentSize: CGSize) {
            if self.window !== window {
                attach(to: window)
            }
            desiredContentSize = contentSize
            applyDesiredFrame()
        }

        func detach() {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
            window = nil
            anchorTopY = nil
        }

        private func attach(to window: NSWindow) {
            detach()
            self.window = window
            anchorTopY = window.frame.maxY

            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleCorrection()
                }
            })

            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let window else { return }
                    self.anchorTopY = window.frame.maxY
                    self.scheduleCorrection()
                }
            })
        }

        private func scheduleCorrection() {
            guard !correctionScheduled else { return }
            correctionScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.correctionScheduled = false
                self.applyDesiredFrame()
            }
        }

        private func applyDesiredFrame() {
            guard let window, desiredContentSize != .zero else { return }
            let topY = anchorTopY ?? window.frame.maxY
            var anchoredFrame = window.frame
            anchoredFrame.origin.y = topY - anchoredFrame.height
            let targetFrame = MenuBarWindowSizer.frame(
                preservingTopOf: anchoredFrame,
                forContentSize: desiredContentSize,
                in: window
            )

            guard !Self.approximatelyEqual(window.frame, targetFrame) else { return }
            window.setFrame(targetFrame, display: true, animate: false)
        }

        private static func approximatelyEqual(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
            abs(lhs.minX - rhs.minX) < 0.5
                && abs(lhs.minY - rhs.minY) < 0.5
                && abs(lhs.width - rhs.width) < 0.5
                && abs(lhs.height - rhs.height) < 0.5
        }
    }
}
