import AppKit
import XCTest
@testable import BarKeep

final class MenuBarWindowSizerTests: XCTestCase {
    func testContentSizePreferenceDoesNotLoseMeasurementToZero() {
        var size = CGSize(width: 340, height: 360)

        MenuContentSizeKey.reduce(value: &size) { .zero }

        XCTAssertEqual(size, CGSize(width: 340, height: 360))
    }

    @MainActor func testResizeNotificationsPreserveAnchorAndDetachStopsCorrections() async {
        let window=NSWindow(contentRect:NSRect(x:100,y:200,width:340,height:600),
                            styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        let coordinator=MenuBarWindowSizer.Coordinator()
        defer { coordinator.detach(); window.close() }
        coordinator.update(window:window,contentSize:CGSize(width:400,height:420))
        XCTAssertEqual(window.frame.maxY,800)
        window.setFrame(NSRect(x:100,y:200,width:280,height:300),display:false)
        NotificationCenter.default.post(name:NSWindow.didResizeNotification,object:window)
        NotificationCenter.default.post(name:NSWindow.didResizeNotification,object:window)
        await drainMainQueue()
        XCTAssertEqual(window.frame.size,CGSize(width:400,height:420))
        XCTAssertEqual(window.frame.maxY,800)
        window.setFrame(NSRect(x:200,y:200,width:280,height:300),display:false)
        NotificationCenter.default.post(name:NSWindow.didBecomeKeyNotification,object:window)
        await drainMainQueue()
        XCTAssertEqual(window.frame.minX,200)
        XCTAssertEqual(window.frame.maxY,500,"A newly opened popover establishes a fresh anchor")
        coordinator.detach()
        let detached=NSRect(x:50,y:60,width:200,height:250)
        window.setFrame(detached,display:false)
        NotificationCenter.default.post(name:NSWindow.didResizeNotification,object:window)
        await drainMainQueue()
        XCTAssertEqual(window.frame,detached)
    }

    @MainActor func testChangingWindowsRemovesObserversFromPreviousWindow() async {
        let first=NSWindow(contentRect:NSRect(x:100,y:200,width:300,height:400),
                           styleMask:.borderless,backing:.buffered,defer:false)
        let second=NSWindow(contentRect:NSRect(x:200,y:300,width:300,height:400),
                            styleMask:.borderless,backing:.buffered,defer:false)
        first.isReleasedWhenClosed=false; second.isReleasedWhenClosed=false
        let coordinator=MenuBarWindowSizer.Coordinator()
        defer { coordinator.detach(); first.close(); second.close() }
        coordinator.update(window:first,contentSize:CGSize(width:400,height:420))
        coordinator.update(window:second,contentSize:CGSize(width:400,height:500))
        let frame=second.frame
        NotificationCenter.default.post(name:NSWindow.didBecomeKeyNotification,object:first)
        await drainMainQueue()
        XCTAssertEqual(second.frame,frame)
    }

    @MainActor private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testResizePreservesTopEdge() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 600),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let currentFrame = NSRect(x: 100, y: 200, width: 340, height: 600)

        let resized = MenuBarWindowSizer.frame(
            preservingTopOf: currentFrame,
            forContentSize: CGSize(width: 340, height: 360),
            in: window
        )

        XCTAssertEqual(resized.maxY, currentFrame.maxY)
        XCTAssertEqual(resized.minX, currentFrame.minX)
        XCTAssertEqual(resized.size, CGSize(width: 340, height: 360))
    }

    func testResizeUsesRequestedContentHeight() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 360),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let currentFrame = NSRect(x: 100, y: 440, width: 340, height: 360)

        let resized = MenuBarWindowSizer.frame(
            preservingTopOf: currentFrame,
            forContentSize: CGSize(width: 340, height: 600),
            in: window
        )

        XCTAssertEqual(resized.maxY, currentFrame.maxY)
        XCTAssertEqual(resized.minY, 200)
        XCTAssertEqual(resized.height, 600)
    }

    func testCorrectionCanRestoreAnEarlierMenuBarAnchor() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 360),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let systemMovedFrame = NSRect(x: 100, y: 200, width: 340, height: 360)
        let originalTopY: CGFloat = 800
        var anchoredFrame = systemMovedFrame
        anchoredFrame.origin.y = originalTopY - anchoredFrame.height

        let corrected = MenuBarWindowSizer.frame(
            preservingTopOf: anchoredFrame,
            forContentSize: CGSize(width: 340, height: 360),
            in: window
        )

        XCTAssertEqual(corrected.maxY, originalTopY)
        XCTAssertEqual(corrected.minY, 440)
    }
}
