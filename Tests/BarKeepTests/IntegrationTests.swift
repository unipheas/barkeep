import AppKit
import XCTest
@testable import BarKeep

final class IntegrationTests: XCTestCase {
    override func tearDown() { HTTPStub.handler = nil }

    func testSlackTransactionsStayOrderedAndPinCredentials() async {
        let slack = SlackSync(session:HTTPStub.session())
        slack.token = "first-fixture-token"
        let started = expectation(description:"First profile update pending")
        let release = DispatchSemaphore(value:0)
        let lock = NSLock()
        var requests: [URLRequest] = []
        HTTPStub.handler = { request in
            let index = lock.withLock { requests.append(request); return requests.count }
            if index == 1 { started.fulfill(); _ = release.wait(timeout:.now()+5) }
            return (200,Data(#"{"ok":true}"#.utf8))
        }
        defer { release.signal(); HTTPStub.handler = nil }
        let busy = Task { await slack.setBusy(true) }
        await fulfillment(of:[started],timeout:2)
        slack.token = "second-fixture-token"
        let clear = Task { await slack.setBusy(false) }
        release.signal()
        let busyError = await busy.value, clearError = await clear.value
        XCTAssertNil(busyError); XCTAssertNil(clearError)
        XCTAssertEqual(requests.map { $0.url!.lastPathComponent },["users.profile.set","dnd.setSnooze","users.profile.set","dnd.endSnooze"])
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField:"Authorization") },["Bearer first-fixture-token","Bearer first-fixture-token","Bearer second-fixture-token","Bearer second-fixture-token"])
    }

    func testSlackBusyAndClearUseExpectedScopesAndPayloads() async throws {
        let slack = SlackSync(session: HTTPStub.session())
        let empty = await slack.setBusy(true); XCTAssertNil(empty)
        slack.token = "test-token"
        var methods: [String] = []
        HTTPStub.handler = { request in
            methods.append(request.url!.lastPathComponent)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.httpMethod, "POST")
            let json = try JSONSerialization.jsonObject(with: HTTPStub.body(request)) as! [String:Any]
            if request.url!.lastPathComponent == "dnd.setSnooze" { XCTAssertEqual(json["num_minutes"] as? Int, 120) }
            if request.url!.lastPathComponent == "dnd.endSnooze" { return (200, Data(#"{"ok":false,"error":"snooze_not_active"}"#.utf8)) }
            return (200, Data(#"{"ok":true}"#.utf8))
        }
        let on = await slack.setBusy(true); XCTAssertNil(on)
        let off = await slack.setBusy(false); XCTAssertNil(off)
        XCTAssertEqual(methods, ["users.profile.set","dnd.setSnooze","users.profile.set","dnd.endSnooze"])
        HTTPStub.handler = { _ in (200, Data(#"{"ok":false,"error":"invalid_auth"}"#.utf8)) }
        let rejected = await slack.setBusy(true); XCTAssertTrue(rejected!.contains("invalid_auth"))
        HTTPStub.handler = { _ in (429, Data()) }
        let limited = await slack.setBusy(true); XCTAssertTrue(limited!.contains("429"))
        HTTPStub.handler = { _ in (200, Data(#"{}"#.utf8)) }
        let unknown = await slack.setBusy(true); XCTAssertTrue(unknown!.contains("unknown error"))
    }

    func testMessageAndEmojiRenderingPreserveDeviceDimensions() throws {
        XCTAssertTrue(MessageRenderer.isPlainASCII("Hello! 123"))
        XCTAssertFalse(MessageRenderer.isPlainASCII("Teams: résumé 👋"))
        XCTAssertFalse(MessageRenderer.isPlainASCII("a\nb"))
        let color = try XCTUnwrap(MessageRenderer.nsColor(fromRGBAHex: " #12AB34FF "))
        XCTAssertEqual(MessageRenderer.rgbaHex(from: color), "#12AB34FF")
        XCTAssertNil(MessageRenderer.nsColor(fromRGBAHex: "#nothex!"))
        for text in ["Hello", "Teams call 👋", String(repeating: "Long message ", count: 10)] {
            let png = try XCTUnwrap(MessageRenderer.renderToPNG(text, colorHex: "invalid"))
            let image = try XCTUnwrap(NSBitmapImageRep(data: png))
            XCTAssertEqual(image.pixelsWide,72); XCTAssertEqual(image.pixelsHigh,16)
        }
        let emoji = try XCTUnwrap(MessageRenderer.renderEmojiIcon("👾"))
        XCTAssertEqual(NSBitmapImageRep(data: emoji)?.pixelsWide,16)
        XCTAssertNil(MessageRenderer.renderGridToPNG([]))
        XCTAssertNil(MessageRenderer.renderGridToPNG([[nil], []]))
        let grid = try XCTUnwrap(MessageRenderer.renderGridToPNG([["#FF0000FF",nil],[nil,"bad"]]))
        let image = try XCTUnwrap(NSBitmapImageRep(data: grid))
        XCTAssertEqual(image.pixelsWide,2); XCTAssertEqual(image.pixelsHigh,2)
        XCTAssertEqual(image.colorAt(x:0,y:0)?.redComponent,1)
    }

    func testExistingClientControlsMatchFirmware() async throws {
        let client = BusyBarClient(host: "bar.test", session: HTTPStub.session())
        var seen: [URLRequest] = []
        HTTPStub.handler = { request in
            seen.append(request)
            let result: String
            switch request.url!.path {
            case "/api/status": result = #"{"power":{"state":"charging","battery_charge":100},"firmware":{"version":"1.3.1"}}"#
            case "/api/busy/snapshot": result = #"{"snapshot":{"type":"NOT_STARTED"}}"#
            case "/api/storage/list": result = #"{"list":[{"type":"dir","name":"on_air"},{"type":"file","name":"ignore"}]}"#
            case "/api/display/brightness": result = #"{"value":"auto"}"#
            case "/api/audio/volume": result = #"{"volume":80}"#
            case "/api/name": result = #"{"name":"Test Bar"}"#
            case "/api/transport": result = #"{"type":"usb"}"#
            case "/api/wifi/status": result = #"{"state":"connected"}"#
            case "/api/update/status": result = #"{"check":{"available_version":"1.3.1","event":"stop","status":"available"}}"#
            case "/api/screen":
                let back = request.url!.query == "display=1"
                return (200, Data(Data(repeating: back ? 0xF3 : 0, count: back ? 160*80/2 : 72*16*3).base64EncodedString().utf8))
            default: result = #"{"result":"OK"}"#
            }
            return (200,Data(result.utf8))
        }
        let status = try await client.status(); XCTAssertEqual(status.firmware.version,"1.3.1")
        let busy = try await client.currentBusyType(); XCTAssertEqual(busy,"NOT_STARTED")
        let themes = try await client.listThemes(); XCTAssertEqual(themes,["busy","on_air"])
        try await client.setBusy(true,theme:"coding",triggerSmartHome:false)
        try await client.setBusy(false,theme:"busy",triggerSmartHome:false)
        try await client.startSimpleSession(minutes:5,theme:"busy",triggerSmartHome:false)
        try await client.startIntervalSession(workMinutes:25,restMinutes:5,cycles:4,theme:"busy",triggerSmartHome:false)
        try await client.drawText("hello",font:.normal,colorHex:"#FFFFFFFF",timeout:5,priority:95,ledColor:"#FF0000FF")
        try await client.drawImage(named:"test.png",timeout:5,priority:95)
        try await client.drawCountdown(to:Date(timeIntervalSince1970:123456),colorHex:"#FFFFFFFF",timeout:5,priority:95)
        try await client.drawPingBadge(text:"23ms",colorHex:"#FFFFFFFF")
        try await client.drawWeatherBadge(iconUploaded:true,tempText:"68F")
        try await client.drawWeatherBadge(iconUploaded:false,tempText:"20C")
        try await client.expireElements([.text(id:"ping"),.image(id:"wx",path:"wx.png")])
        try await client.clearDisplay()
        let front = try await client.screenFrame(); XCTAssertEqual(front.width,72)
        let back = try await client.screenFrame(display:1); XCTAssertEqual(back.width,160)
        XCTAssertEqual(back.bgrPixels.count,160*80*3)
        XCTAssertEqual(Array(back.bgrPixels.prefix(6)),[51,51,51,255,255,255])
        do { _ = try await client.screenFrame(display:2); XCTFail("Invalid display accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Display must")) }
        let brightness = try await client.brightness(); XCTAssertEqual(brightness,"auto")
        try await client.setBrightness("50")
        let volume = try await client.volume(); XCTAssertEqual(volume,80)
        try await client.setVolume(50)
        let name = try await client.deviceName(); XCTAssertEqual(name,"Test Bar")
        try await client.setDeviceName("New Bar")
        let transport = try await client.transport(); XCTAssertEqual(transport,"usb")
        let wifi = try await client.wifiState(); XCTAssertEqual(wifi,"connected")
        try await client.playSound(stockPath:"shared/calendar_event_starts.snd")
        try await client.startUpdateCheck()
        let update = try await client.updateStatus(); XCTAssertEqual(update.check.status,"available")
        try await client.uploadAsset(filename:"test.png",data:Data([1,2]))
        let snapshots = try seen.filter { $0.httpMethod == "PUT" }.map {
            try JSONSerialization.jsonObject(with: HTTPStub.body($0)) as! [String:Any]
        }
        XCTAssertEqual(snapshots.count,4)
        XCTAssertEqual((snapshots[2]["snapshot"] as? [String:Any])?["time_left_ms"] as? Int,300000)
        HTTPStub.handler = { _ in (200,Data("not base64!".utf8)) }
        do { _ = try await client.screenFrame(); XCTFail("Accepted invalid frame") } catch { XCTAssertTrue(error.localizedDescription.contains("base64")) }
        HTTPStub.handler = { _ in (200,Data("AA==".utf8)) }
        do { _ = try await client.screenFrame(); XCTFail("Accepted short frame") } catch { XCTAssertTrue(error.localizedDescription.contains("small")) }
    }
}
