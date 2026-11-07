import XCTest
@testable import BarKeep

final class DeviceAppsTests: XCTestCase {
    private var client: BusyBarClient!
    override func setUp() { client = BusyBarClient(host: "bar.test", token: "local-password", session: HTTPStub.session()) }
    override func tearDown() { HTTPStub.handler = nil }

    func testAppAPIContractAndBinaryUpload() async throws {
        var requests: [URLRequest] = []
        HTTPStub.handler = { request in
            requests.append(request)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Token"), "local-password")
            switch request.url!.path {
            case "/api/apps/list": return (200, Data("{\"apps\":[\(appFixture)]}".utf8))
            case "/api/apps/stage":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
                XCTAssertEqual(HTTPStub.body(request), Data([31,139,1,2]))
                XCTAssertEqual(request.timeoutInterval, 120)
                return (200, Data("{\"install_key\":4294967295,\"staged\":\(appFixture),\"installed\":\(appFixture)}".utf8))
            case "/api/apps/settings" where request.httpMethod == "GET":
                return (200, Data(#"{"version":1,"values":{"city":"Chicago","nested":{"enabled":true}}}"#.utf8))
            default: return (200, Data(#"{"result":"OK"}"#.utf8))
            }
        }
        let apps = try await client.apps()
        XCTAssertEqual(apps.first?.name, "Clock")
        let staged = try await client.stageApp(Data([31,139,1,2]))
        XCTAssertEqual(staged.installed?.version, "1.2.3")
        try await client.installApp(key: staged.install_key)
        try await client.launchApp(id: "app.test.clock")
        try await client.quitApp()
        let settings = try await client.appSettings(id: "app.test.clock")
        XCTAssertTrue(settings.contains("Chicago"))
        try await client.saveAppSettings(id: "app.test.clock", json: settings)
        try await client.resetAppSettings(id: "app.test.clock")
        try await client.removeApp(id: "app.test.clock")
        XCTAssertEqual(requests.map { $0.httpMethod! }, ["GET","POST","POST","POST","POST","GET","PUT","DELETE","DELETE"])
        XCTAssertEqual(URLComponents(url: requests[2].url!, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "install_key", value: "4294967295")])
        for index in [3,5,6,7,8] { XCTAssertTrue(requests[index].url!.query!.contains("app_id=app.test.clock")) }
    }

    @MainActor func testAlreadyStoppedAppResumesWidgetsAndPartialRemovalRefreshesList() async throws {
        var stops=0, removals=0, removed=false
        let app=try JSONDecoder().decode(DeviceApp.self,from:Data(appFixture.utf8))
        HTTPStub.handler={ request in
            switch (request.httpMethod!,request.url!.path) {
            case (_,"/api/apps/quit"): return (409,Data(#"{"error":"application is not running"}"#.utf8))
            case ("DELETE","/api/apps"):
                removed=true
                return (508,Data(#"{"error":"Filesystem error"}"#.utf8))
            case (_,"/api/apps/list"):
                return (200,Data("{\"apps\":\(removed ? "[]" : "[" + appFixture + "]")}".utf8))
            case (_,"/api/apps/settings"): return (200,Data(#"{"version":1,"values":{}}"#.utf8))
            default: return (404,Data())
            }
        }
        let model=DeviceAppsModel(client:client,stopAction:{stops += 1},removeAction:{ _ in removals += 1 })
        await model.refresh()
        await model.loadSettings(app)
        XCTAssertNotNil(model.settingsApp)
        await model.stop()
        XCTAssertNil(model.error); XCTAssertEqual(model.message,"App already stopped.")
        XCTAssertEqual(stops,1)
        await model.remove(app)
        XCTAssertTrue(model.apps.isEmpty)
        XCTAssertNil(model.settingsApp)
        XCTAssertEqual(removals,1)
        XCTAssertTrue(model.message?.contains("left files behind") == true)
        XCTAssertTrue(model.error?.contains("508") == true,"A partial removal must retain the firmware error")
    }

    func testInvalidInputNeverReachesDevice() async {
        HTTPStub.handler = { _ in XCTFail("Invalid input reached network"); return (200, Data()) }
        for id in ["", ".hidden", "../test", "app/a", String(repeating: "a", count: 33), "a&b", "🙂"] {
            do { try await client.launchApp(id: id); XCTFail("Accepted \(id)") } catch {}
        }
        for settings in ["{}", "[]", #"{"version":true,"values":{}}"#, #"{"version":1.5,"values":{}}"#, #"{"version":1,"values":[]}"#, "bad json"] {
            do { try await client.saveAppSettings(id: "app.valid", json: settings); XCTFail("Accepted \(settings)") } catch {}
        }
        do { _ = try await client.stageApp(Data()); XCTFail("Accepted empty archive") } catch {}
        do { _ = try await client.api("GET", "//elsewhere/../status"); XCTFail("Accepted bad path") } catch {}
    }

    func testHTTPFailuresAndMalformedResponses() async {
        for code in [403,404,409,500] {
            HTTPStub.handler = { _ in (code, Data("device says no".utf8)) }
            do { _ = try await client.apps(); XCTFail("Accepted HTTP \(code)") }
            catch { XCTAssertEqual((error as? BusyBarError)?.statusCode, code) }
        }
        HTTPStub.handler = { _ in (200, Data("{}".utf8)) }
        do { _ = try await client.apps(); XCTFail("Accepted malformed apps response") } catch {}
        HTTPStub.handler = { _ in throw URLError(.timedOut) }
        do { _ = try await client.apps(); XCTFail("Ignored timeout") } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
    }

    @MainActor func testModelInstallSettingsLaunchAndRemoval() async throws {
        let model = DeviceAppsModel(client: client)
        var installed = false
        HTTPStub.handler = { request in
            switch (request.httpMethod!, request.url!.path) {
            case (_, "/api/apps/list"): return (200, Data("{\"apps\":\(installed ? "[" + appFixture + "]" : "[]")}".utf8))
            case (_, "/api/apps/stage"): return (200, Data("{\"install_key\":123,\"staged\":\(appFixture)}".utf8))
            case (_, "/api/apps/install"): installed = true
            case ("GET", "/api/apps/settings"): return (200, Data(#"{"version":1,"values":{"x":true}}"#.utf8))
            default: break
            }
            return (200, Data(#"{"result":"OK"}"#.utf8))
        }
        await model.refresh(); XCTAssertTrue(model.loaded); XCTAssertTrue(model.apps.isEmpty)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("test.tgz"); try Data([1,2,3]).write(to: url)
        await model.stage(url: url); XCTAssertEqual(model.staged?.install_key, 123)
        await model.install(); XCTAssertNil(model.staged); XCTAssertEqual(model.apps.count, 1)
        let app = try XCTUnwrap(model.apps.first)
        await model.launch(app); XCTAssertEqual(model.message, "Launched Clock.")
        await model.stop(); XCTAssertEqual(model.message, "App stopped.")
        await model.loadSettings(app); XCTAssertEqual(model.settingsApp?.id, app.id)
        await model.saveSettings(); XCTAssertTrue(model.message!.contains("Saved"))
        await model.resetSettings(); XCTAssertEqual(model.message, "Restored default settings.")
        await model.remove(app); XCTAssertTrue(model.apps.isEmpty); XCTAssertNil(model.settingsApp)
        await model.install(); await model.saveSettings(); await model.resetSettings()
        await model.stage(url: dir.appendingPathComponent("bad.zip")); XCTAssertNotNil(model.error)
        await model.stage(url: dir.appendingPathComponent("missing.tgz")); XCTAssertNotNil(model.error)
        await model.stage(url: url); client.host = "new-bar.test"
        await model.install(); XCTAssertNil(model.staged); XCTAssertTrue(model.error!.contains("Device changed"))
        client.host = "bar.test"
        HTTPStub.handler = { _ in (404, Data()) }
        await model.refresh(); XCTAssertTrue(model.error!.contains("1.3.1")); XCTAssertFalse(model.working)
        await model.launch(app)
        XCTAssertTrue(model.error!.contains("404"))
        XCTAssertFalse(model.error!.contains("1.3.1"),"A missing app is not evidence of old firmware")
    }

    func testRequestIsolationAndInvalidTransportResponses() async throws {
        let bad = BusyBarClient(host: "[", session: HTTPStub.session())
        XCTAssertThrowsError(try bad.request("GET", "/status"))
        HTTPStub.handler = { _ in (-1, Data()) }
        do { _ = try await client.status(); XCTFail("Accepted a non-HTTP response") }
        catch { XCTAssertEqual(error.localizedDescription, "No HTTP response") }
        let req = URLRequest(url:URL(string:"http://bar.test/api/status")!)
        let response = HTTPURLResponse(url:req.url!,statusCode:302,httpVersion:nil,headerFields:nil)!
        let session = URLSession(configuration:.ephemeral)
        let task = session.dataTask(with:req)
        var redirected = true
        NoRedirectDelegate().urlSession(session,task:task,willPerformHTTPRedirection:response,newRequest:req) {
            redirected = $0 != nil
        }
        XCTAssertFalse(redirected)
        session.invalidateAndCancel()
        let tokenEndpoint = try XCTUnwrap(DeviceEndpoint.all.first { $0.path == "/access/tokens/{short_id}" })
        XCTAssertThrowsError(try tokenEndpoint.prepare(values:["short_id":"../oops"],json:"",file:nil))
        let nameEndpoint = try XCTUnwrap(DeviceEndpoint.all.first { $0.path == "/name" && $0.method == "POST" })
        let prepared = try nameEndpoint.prepare(values:[:],json:#"{"name":"BarKeep"}"#,file:nil)
        XCTAssertNotNil(prepared.body)
        XCTAssertThrowsError(try nameEndpoint.prepare(values:[:],json:"invalid",file:nil))
    }

    @MainActor func testPackageLimitAndDeviceChangeDuringStage() async throws {
        let model = DeviceAppsModel(client:client)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".tgz")
        try Data([1]).write(to:file)
        defer { try? FileManager.default.removeItem(at:file) }
        let handle = try FileHandle(forWritingTo:file)
        try handle.truncate(atOffset:100*1024*1024+1); try handle.close()
        await model.stage(url:file)
        XCTAssertTrue(model.error!.contains("100 MiB"))
        try Data([1]).write(to:file)
        let started = expectation(description:"Stage in flight")
        HTTPStub.handler = { _ in
            started.fulfill(); Thread.sleep(forTimeInterval:0.05)
            return (200,Data("{\"install_key\":1,\"staged\":\(appFixture)}".utf8))
        }
        let task=Task { await model.stage(url:file) }
        await fulfillment(of:[started],timeout:1)
        await model.refresh()
        client.token="changed"
        await task.value
        XCTAssertNil(model.staged)
        XCTAssertTrue(model.error!.contains("Device changed during upload"))
    }

    func testAppsSortNaturallyAndTransportFallbacks() async throws {
        let two = appFixture.replacingOccurrences(of:"Clock",with:"App 2")
        let ten = appFixture.replacingOccurrences(of:"Clock",with:"App 10")
        HTTPStub.handler = { _ in (200,Data("{\"apps\":[\(ten),\(two)]}".utf8)) }
        let apps = try await client.apps()
        XCTAssertEqual(apps.map(\.name),["App 2","App 10"])
        HTTPStub.handler = { _ in (200,Data("{}".utf8)) }
        let transport = try await client.transport(); XCTAssertEqual(transport,"unknown")
        HTTPStub.handler = { _ in (500,Data([0xFF])) }
        do { _ = try await client.status(); XCTFail("Expected failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("HTTP 500")) }
        let socket = try client.statusSocket(); socket.close()
    }

    func testCatalogCoversFirmwareAndValidatesRequests() throws {
        XCTAssertEqual(DeviceEndpoint.all.count, 81)
        XCTAssertEqual(Set(DeviceEndpoint.all.map(\.id)).count, 81)
        XCTAssertEqual(DeviceEndpoint.apiVersion, "27.14.0")
        let list = try XCTUnwrap(DeviceEndpoint.all.first { $0.path == "/apps/list" })
        XCTAssertTrue(list.isReadOnly)
        XCTAssertEqual(try list.prepare(values: [:], json: "", file: nil).path, "/apps/list")
        let launch = try XCTUnwrap(DeviceEndpoint.all.first { $0.path == "/apps/launch" })
        XCTAssertThrowsError(try launch.prepare(values: [:], json: "", file: nil))
        XCTAssertEqual(try launch.prepare(values: ["app_id":"app.test"], json: "", file: nil).query["app_id"], "app.test")
        let stage = try XCTUnwrap(DeviceEndpoint.all.first { $0.path == "/apps/stage" })
        XCTAssertTrue(stage.isBinary)
        XCTAssertThrowsError(try stage.prepare(values: [:], json: "", file: nil))
        XCTAssertEqual(try stage.prepare(values: [:], json: "", file: Data([3])).body, Data([3]))
        let profile = try XCTUnwrap(DeviceEndpoint.all.first { $0.path == "/busy/profiles/{slot}" && $0.isReadOnly })
        XCTAssertEqual(try profile.prepare(values: ["slot":"busy"], json: "", file: nil).path, "/busy/profiles/busy")
        XCTAssertThrowsError(try profile.prepare(values: ["slot":"../x"], json: "", file: nil))
        for endpoint in DeviceEndpoint.all where endpoint.contentType == "application/json" {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(endpoint.bodyTemplate.utf8)), endpoint.id)
        }
    }
}
