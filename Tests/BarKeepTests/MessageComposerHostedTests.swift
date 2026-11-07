import SwiftUI
import ViewInspector
import XCTest
@testable import BarKeep

final class MessageComposerHostedTests: XCTestCase {
    @MainActor func testInstalledComposerSearchesEmojiAndSendsThroughMockTransport() async throws {
        let suite = "dev.barkeep.hosted-emoji.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); HTTPStub.handler = nil }
        let uploaded = expectation(description: "PNG uploaded")
        let sent = expectation(description: "Image display POST received")
        HTTPStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            switch request.url?.path {
            case "/api/assets/upload":
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(query?.first(where: { $0.name == "file" })?.value, "message.png")
                let data = HTTPStub.body(request)
                XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
                XCTAssertEqual(bitmap.pixelsWide, 72)
                XCTAssertEqual(bitmap.pixelsHigh, 16)
                uploaded.fulfill()
            case "/api/display/draw":
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: HTTPStub.body(request)) as? [String: Any])
                let elements = try XCTUnwrap(object["elements"] as? [[String: Any]])
                XCTAssertEqual(elements.count, 1)
                XCTAssertEqual(elements.first?["type"] as? String, "image")
                XCTAssertEqual(elements.first?["path"] as? String, "message.png")
                XCTAssertEqual(elements.first?["timeout"] as? Int, 30)
                XCTAssertEqual(object["priority"] as? Int, 95)
                sent.fulfill()
            default: XCTFail("Unexpected request: \(request)")
            }
            return (200, Data())
        }
        let state = AppState(defaults: defaults, startServices: false, session: HTTPStub.session())
        state.presets = []
        var sut = MessageTab()
        let inspected = sut.on(\.didAppear) { view in
            try view.find(ViewType.Button.self, where: { (try? $0.accessibilityLabel().string()) == "Insert emoji" }).tap()
            let search = try view.find(ViewType.TextField.self, where: {
                try $0.labelView().text().string().hasPrefix("Search emoji")
            })
            try search.setInput("no-such-emoji-xyz")
            XCTAssertNotNil(try view.find(text: "No matches"))
            try search.setInput("rocket")
            try view.find(button: "🚀").tap()
            let field = try view.find(ViewType.TextField.self, where: {
                try $0.labelView().text().string().hasPrefix("Type a message")
            })
            XCTAssertEqual(try field.input(), "🚀")
            XCTAssertNotNil(try view.find(text: "Contains emoji/unicode — sent as a rendered image (no scrolling, keep it short)."))
            try view.find(button: "Send").tap()
            XCTAssertEqual(try field.input(), "")
        }
        ViewHosting.host(view: sut.environment(state))
        defer { ViewHosting.expel() }
        await fulfillment(of: [inspected, uploaded, sent], timeout: 5)
    }

    @MainActor func testInstalledComposerEditsAndSavesPreset() async throws {
        let suite = "dev.barkeep.hosted-message.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults, startServices: false, session: HTTPStub.session())
        state.presets = []
        var sut = MessageTab()
        let inspected = sut.on(\.didAppear) { view in
            let field = try view.find(ViewType.TextField.self)
            XCTAssertTrue(try view.find(button: "Send").isDisabled())
            try field.setInput("  Hosted message  ")
            XCTAssertEqual(try field.input(), "  Hosted message  ")
            XCTAssertFalse(try view.find(button: "Send").isDisabled())
            try view.find(ViewType.Picker.self, where: { try $0.labelView().text().string() == "For" }).select(value: 120)
            try view.find(ViewType.Button.self, where: { (try? $0.accessibilityLabel().string()) == "Message color" }).tap()
            try view.find(ViewType.Button.self, where: { (try? $0.accessibilityLabel().string()) == "Red" }).tap()
            try view.find(button: "Save current message as preset").tap()
            XCTAssertEqual(state.presets.count, 1)
            XCTAssertEqual(state.presets.first?.text, "Hosted message")
            XCTAssertEqual(state.presets.first?.colorHex, MessageRenderer.rgbaHex(from: NSColor(Color.red)))
            XCTAssertEqual(try field.input(), "")
        }
        ViewHosting.host(view: sut.environment(state))
        defer { ViewHosting.expel() }
        await fulfillment(of: [inspected], timeout: 5)
    }
}
