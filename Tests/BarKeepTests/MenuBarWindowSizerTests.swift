import AppKit
import XCTest
@testable import BarKeep

final class MenuBarWindowSizerTests: XCTestCase {
    func testContentSizePreferenceDoesNotLoseMeasurementToZero() {
        var size = CGSize(width: 340, height: 360)

        MenuContentSizeKey.reduce(value: &size) { .zero }

        XCTAssertEqual(size, CGSize(width: 340, height: 360))
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
