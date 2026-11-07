import XCTest
@testable import BarKeep

/// Opt-in only. Installs a disposable package with a unique ID, then removes it.
final class LiveDeviceTests: XCTestCase {
    func testPhysicalDeviceAppLifecycle() async throws {
        guard let package = ProcessInfo.processInfo.environment["BARKEEP_TEST_PACKAGE"] else {
            throw XCTSkip("Set BARKEEP_TEST_PACKAGE to a built app.barkeep.qa package for the hardware test.")
        }
        let client = BusyBarClient(host: ProcessInfo.processInfo.environment["BARKEEP_TEST_HOST"] ?? "10.0.4.20")
        let before = try await client.apps()
        guard !before.contains(where: { $0.id == "app.barkeep.qa" }) else {
            throw XCTSkip("Refusing to replace an existing app.barkeep.qa installation.")
        }
        let busy = try await client.currentBusyType()
        guard busy == "NOT_STARTED" else { throw XCTSkip("Device is busy; do not interrupt the user's session.") }
        let staged = try await client.stageApp(Data(contentsOf: URL(fileURLWithPath: package)))
        XCTAssertEqual(staged.staged.id,"app.barkeep.qa")
        guard staged.staged.id == "app.barkeep.qa", staged.installed == nil else {
            XCTFail("Only a new disposable QA package is allowed"); return
        }
        try await client.installApp(key:staged.install_key)
        do {
            let installed = try await client.apps()
            XCTAssertTrue(installed.contains { $0.id == "app.barkeep.qa" })
            let initial = try await client.appSettings(id:"app.barkeep.qa")
            XCTAssertTrue(initial.contains("QA OK"))
            try await client.saveAppSettings(id:"app.barkeep.qa",json:#"{"version":1,"values":{"label":"Saved"}}"#)
            let saved = try await client.appSettings(id:"app.barkeep.qa")
            XCTAssertTrue(saved.contains("Saved"))
            try await client.resetAppSettings(id:"app.barkeep.qa")
            let reset = try await client.appSettings(id:"app.barkeep.qa")
            XCTAssertTrue(reset.contains("QA OK"))
            try await client.launchApp(id:"app.barkeep.qa")
            try await Task.sleep(for:.seconds(2))
            let frame = try await client.screenFrame()
            XCTAssertTrue(frame.bgrPixels.contains { $0 != 0 },"Running app should draw visible pixels")
            try await client.quitApp()
            try await client.removeApp(id:"app.barkeep.qa")
        } catch {
            try? await client.quitApp()
            try? await client.removeApp(id:"app.barkeep.qa")
            throw error
        }
        let after = try await client.apps()
        XCTAssertEqual(Set(before.map(\.id)),Set(after.map(\.id)))
    }
}
