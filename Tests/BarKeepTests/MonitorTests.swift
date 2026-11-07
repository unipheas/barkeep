import XCTest
import SQLite3
@testable import BarKeep

final class MonitorTests: XCTestCase {
    func testTeamsNotificationDatabasePrimingDeduplicationAndRecycledIDs() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let path = folder.appendingPathComponent("notifications.db").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path,&db),SQLITE_OK)
        defer { sqlite3_close(db) }
        func sql(_ value: String) { XCTAssertEqual(sqlite3_exec(db,value,nil,nil,nil),SQLITE_OK) }
        sql("CREATE TABLE app (app_id INTEGER, identifier TEXT); CREATE TABLE record (rec_id INTEGER, app_id INTEGER, uuid, data BLOB);")
        sql("INSERT INTO app VALUES (1,'com.microsoft.teams2')")
        let data = try PropertyListSerialization.data(fromPropertyList:["req":["titl":"Test call","subt":"QA","body":"Join now"]],format:.binary,options:0)
        let hex = data.map { String(format:"%02x",$0) }.joined()
        sql("INSERT INTO record VALUES (1,1,'old',X'\(hex)')")
        let watcher = NotificationWatcher(paths:[path])
        final class Notes: @unchecked Sendable { var values: [ForwardedNotification] = [] }
        let notes = Notes()
        watcher.onNotification = { notes.values.append($0) }
        watcher.poll(); XCTAssertEqual(watcher.status,.watching); XCTAssertTrue(notes.values.isEmpty)
        sql("INSERT INTO record VALUES (2,1,X'010203',X'\(hex)')")
        watcher.poll(); watcher.poll(); XCTAssertEqual(notes.values.count,1)
        XCTAssertEqual(notes.values[0].bundleID,"com.microsoft.teams2")
        XCTAssertEqual(notes.values[0].title,"Test call"); XCTAssertEqual(notes.values[0].body,"QA — Join now")
        sql("DELETE FROM record WHERE rec_id=2; INSERT INTO record VALUES (2,1,'new-id',X'\(hex)')")
        watcher.poll(); XCTAssertEqual(notes.values.count,2)
        sql("INSERT INTO record VALUES (3,1,NULL,NULL); INSERT INTO record VALUES (4,1,'bad',X'000001')")
        watcher.poll(); XCTAssertEqual(notes.values.count,2)
        let empty = try PropertyListSerialization.data(fromPropertyList:["req":[:]],format:.binary,options:0).map { String(format:"%02x",$0) }.joined()
        sql("INSERT INTO record VALUES (5,1,'empty',X'\(empty)')")
        watcher.poll(); XCTAssertEqual(notes.values.count,2)
        let stopped = expectation(description:"stopped")
        watcher.onStatusChange = { if $0 == .stopped { stopped.fulfill() } }
        watcher.stop(); wait(for:[stopped],timeout:2)
        let missing = NotificationWatcher(paths:[folder.appendingPathComponent("missing.db").path])
        missing.poll(); XCTAssertEqual(missing.status,.noAccess)
        sql("DROP TABLE record")
        let invalid = NotificationWatcher(paths:[path]); invalid.poll()
        if case .error = invalid.status {} else { XCTFail("Missing table must produce an actionable error") }
        invalid.stop()
    }

    func testNotificationLifecycleAndUnreadableDatabaseFixtures() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let corrupt=folder.appendingPathComponent("corrupt.db")
        try Data("not a database".utf8).write(to:corrupt)
        let empty=folder.appendingPathComponent("empty.db")
        try Data().write(to:empty)
        let missing=folder.appendingPathComponent("usernoted-missing.db")
        let watcher=NotificationWatcher(paths:[corrupt.path,empty.path,missing.path,folder.path])
        let denied=expectation(description:"No accessible notification database")
        let stopped=expectation(description:"Watcher stopped")
        watcher.onStatusChange={ status in
            if status == .noAccess { denied.fulfill() }
            if status == .stopped { stopped.fulfill() }
        }
        watcher.start(); watcher.start()
        wait(for:[denied],timeout:2)
        watcher.stop()
        wait(for:[stopped],timeout:2)
    }

    func testWeatherUsesConfiguredLocationUnitsAndHandlesBadResponses() async throws {
        let suite = "dev.barkeep.weather-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite); HTTPStub.handler = nil }
        defaults.set(41.8,forKey:"weatherLat"); defaults.set(-87.6,forKey:"weatherLon")
        defaults.set("Chicago",forKey:"weatherCity")
        let session = HTTPStub.session()
        let cases: [(Int,String)] = [(0,"☀️"),(1,"🌤"),(2,"⛅️"),(3,"☁️"),(45,"🌫"),(55,"🌦"),(63,"🌧"),(73,"🌨"),(96,"⛈"),(999,"🌡")]
        for (code,emoji) in cases {
            HTTPStub.handler = { request in
                XCTAssertTrue(request.url!.query!.contains("temperature_unit=fahrenheit"))
                return (200,Data("{\"current\":{\"temperature_2m\":68.4,\"weather_code\":\(code)}}".utf8))
            }
            let weather = try XCTUnwrap(awaitValue: await WeatherMonitor.fetch(defaults:defaults,session:session))
            XCTAssertEqual(weather.tempText,"68F"); XCTAssertEqual(weather.city,"Chicago"); XCTAssertEqual(weather.emoji,emoji)
        }
        defaults.set(true,forKey:"weatherCelsius")
        defaults.removeObject(forKey:"weatherLat"); defaults.removeObject(forKey:"weatherLon")
        HTTPStub.handler = { request in
            if request.url!.host == "ipinfo.io" { return (200,Data(#"{"loc":"41.8,-87.6","city":"Chicago"}"#.utf8)) }
            if request.url!.host == "geocoding-api.open-meteo.com" { return (200,Data(#"{"results":[{"latitude":41.8,"longitude":-87.6,"name":"Chicago"}]}"#.utf8)) }
            return (200,Data(#"{"current":{"temperature_2m":20}}"#.utf8))
        }
        let weather = await WeatherMonitor.fetch(defaults:defaults,session:session); XCTAssertEqual(weather?.tempText,"20C")
        let city = await WeatherMonitor.geocode("Chicago",session:session); XCTAssertEqual(city?.city,"Chicago")
        for bad in [#"{"loc":"invalid"}"#,"{}","garbage"] {
            HTTPStub.handler = { _ in (200,Data(bad.utf8)) }
            let failed = await WeatherMonitor.fetch(defaults:defaults,session:session); XCTAssertNil(failed)
            let failedCity = await WeatherMonitor.geocode("unknown",session:session); XCTAssertNil(failedCity)
        }
        HTTPStub.handler = { _ in (500,Data()) }
        let failed = await WeatherMonitor.fetch(defaults:defaults,session:session); XCTAssertNil(failed)
    }

    func testWeatherMissingFieldsAndUnsafeTemperature() async throws {
        let suite="dev.barkeep.weather-fallback.\(UUID().uuidString)"
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite); HTTPStub.handler=nil }
        let session=HTTPStub.session()
        defaults.set(0.0,forKey:"weatherLat"); defaults.set(0.0,forKey:"weatherLon")
        for body in ["{}",#"{"current":{}}"#,#"{"current":{"temperature_2m":1e300}}"#] {
            HTTPStub.handler={ _ in (200,Data(body.utf8)) }
            let value=await WeatherMonitor.fetch(defaults:defaults,session:session)
            XCTAssertNil(value)
        }
        HTTPStub.handler={ _ in (200,Data(#"{"current":{"temperature_2m":20}}"#.utf8)) }
        let custom=await WeatherMonitor.fetch(defaults:defaults,session:session)
        XCTAssertEqual(custom?.city,"custom")
        defaults.removeObject(forKey:"weatherLat"); defaults.removeObject(forKey:"weatherLon")
        HTTPStub.handler={ request in
            if request.url?.host == "ipinfo.io" { return (200,Data(#"{"loc":"0,0"}"#.utf8)) }
            if request.url?.host == "geocoding-api.open-meteo.com" { return (200,Data(#"{"results":[{"latitude":0,"longitude":0}]}"#.utf8)) }
            return (200,Data(#"{"current":{"temperature_2m":20}}"#.utf8))
        }
        let automatic=await WeatherMonitor.fetch(defaults:defaults,session:session)
        XCTAssertEqual(automatic?.city,"?")
        let city=await WeatherMonitor.geocode("Fallback",session:session)
        XCTAssertEqual(city?.city,"Fallback")
        let slack=SlackSync(session:session); slack.token="fixture"
        HTTPStub.handler={ _ in (-1,Data()) }
        let error=await slack.setBusy(true); XCTAssertTrue(error!.contains("HTTP 0"))
    }

    func testEmojiSearchAndIconVariants() throws {
        XCTAssertGreaterThan(EmojiCatalog.all.count,100)
        XCTAssertEqual(EmojiCatalog.search(" "),EmojiCatalog.all)
        let faces = EmojiCatalog.search("grinning face")
        XCTAssertFalse(faces.isEmpty)
        XCTAssertTrue(faces.allSatisfy { $0.name.contains("GRINNING") && $0.name.contains("FACE") })
        XCTAssertTrue(EmojiCatalog.search("not a real emoji name qqq").isEmpty)
        XCTAssertEqual(faces[0].id,faces[0].char)
        for on in [false,true] { for reachable in [false,true] {
            let image = MenuBarIcon.current(onCall:on,reachable:reachable)
            XCTAssertGreaterThan(image.size.width,0)
        }}
    }
}

private func XCTUnwrap<T>(awaitValue: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(awaitValue,file:file,line:line)
}
