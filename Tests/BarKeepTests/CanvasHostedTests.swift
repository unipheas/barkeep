import XCTest
import SwiftUI
import ViewInspector
@testable import BarKeep

final class CanvasHostedTests: XCTestCase {
    @MainActor func testInstalledCanvasPaintsInterpolatesErasesAndSendsPNG() async throws {
        try await verifyCanvasOutput(clearBeforeSending: false)
    }

    @MainActor func testClearCanvasRemovesPaintedPixels() async throws {
        try await verifyCanvasOutput(clearBeforeSending: true)
    }

    @MainActor func testBusySessionDisablesSendingAndShowsError() async throws {
        let suite = "dev.barkeep.canvas-busy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); HTTPStub.handler = nil }
        HTTPStub.handler = { _ in (200, Data("{}".utf8)) }
        let state = AppState(defaults: defaults, startServices: false, session: HTTPStub.session())
        await state.setOnCall(true).value
        state.lastError = "Fixture display failure"
        let view = CanvasView().environment(state)
        XCTAssertTrue(try view.inspect().find(button: "Send to Bar").isDisabled())
        XCTAssertNotNil(try view.inspect().find(text: "Fixture display failure"))
        XCTAssertNotNil(try view.inspect().find(ViewType.Text.self, where: { try $0.string().hasPrefix("Sending is unavailable") }))
        await state.setOnCall(false).value
    }

    @MainActor private func verifyCanvasOutput(clearBeforeSending: Bool) async throws {
        let suite = "dev.barkeep.canvas-hosted.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); HTTPStub.handler = nil }
        let uploaded = expectation(description: "Canvas PNG uploaded")
        let drawn = expectation(description: "Canvas displayed with selected timeout")
        HTTPStub.handler = { request in
            let body = HTTPStub.body(request)
            if request.url?.path == "/api/assets/upload" && request.httpMethod == "POST" {
                let signature = Data([137,80,78,71,13,10,26,10])
                let range = try XCTUnwrap(body.range(of: signature))
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: body.subdata(in: range.lowerBound..<body.endIndex)))
                XCTAssertEqual(bitmap.pixelsWide, 72)
                XCTAssertEqual(bitmap.pixelsHigh, 16)
                if clearBeforeSending {
                    for x in 0..<72 { for y in 0..<16 {
                        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent, 0)
                    }}
                } else {
                    XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).redComponent, 0.5)
                    XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 1, y: 0)).alphaComponent, 0)
                    XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 2, y: 0)).redComponent, 0.5)
                }
                uploaded.fulfill()
            }
            if request.url?.path == "/api/display/draw" && request.httpMethod == "POST" {
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let elements = try XCTUnwrap(json["elements"] as? [[String: Any]])
                XCTAssertEqual(elements.count, 1)
                XCTAssertEqual(elements.first?["timeout"] as? Int, 120)
                XCTAssertEqual(elements.first?["path"] as? String, "canvas.png")
                drawn.fulfill()
            }
            return (200, Data("{}".utf8))
        }
        let state = AppState(defaults: defaults, startServices: false, session: HTTPStub.session())
        var sut = CanvasView()
        let inspected = sut.on(\.didAppear) { view in
            let gesture = try view.find(ViewType.Canvas.self).gesture(DragGesture.self)
            func sample(_ x: CGFloat, _ y: CGFloat) -> DragGesture.Value {
                .init(time: Date(), location: .init(x: x, y: y), startLocation: .zero, velocity: .zero)
            }
            try gesture.callOnChanged(value: sample(1, 1))
            try gesture.callOnChanged(value: sample(25, 1))
            try gesture.callOnEnded(value: sample(25, 1))
            try view.find(ViewType.Toggle.self).tap()
            try gesture.callOnChanged(value: sample(13, 1))
            try gesture.callOnEnded(value: sample(13, 1))
            try gesture.callOnChanged(value: sample(-1, -1))
            try gesture.callOnChanged(value: sample(10000, 1))
            try gesture.callOnChanged(value: sample(1, 10000))
            if clearBeforeSending { try view.find(button: "Clear Canvas").tap() }
            try view.find(ViewType.Picker.self).select(value: 120)
            var renderedView = try view.actualView()
            renderedView.didAppear = nil
            let renderer = ImageRenderer(content: renderedView.environment(state))
            XCTAssertNotNil(renderer.cgImage, "Painted canvas must render to an image")
            try view.find(button: "Send to Bar").tap()
        }
        ViewHosting.host(view: sut.environment(state))
        defer { ViewHosting.expel() }
        await fulfillment(of: [inspected, uploaded, drawn], timeout: 5)
    }
}
