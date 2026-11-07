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
            let edited = try AppSettingsDocument.replacing(in:initial,at:["label"],value:"Saved")
            try await client.saveAppSettings(id:"app.barkeep.qa",json:edited)
            let saved = try await client.appSettings(id:"app.barkeep.qa")
            XCTAssertTrue(saved.contains("Saved"))
            try await client.resetAppSettings(id:"app.barkeep.qa")
            let reset = try await client.appSettings(id:"app.barkeep.qa")
            XCTAssertTrue(reset.contains("QA OK"))
            // Match the native app handoff: its higher-priority overlay must not hide JS output.
            try await client.clearDisplay()
            try await client.launchApp(id:"app.barkeep.qa")
            // The launch response precedes JS parsing. Ignore the launcher splash frame.
            try await Task.sleep(for:.seconds(2))
            var visible = false
            for _ in 0..<40 {
                let frame = try await client.screenFrame()
                if frame.bgrPixels.contains(where: { $0 != 0 }) { visible = true; break }
                try await Task.sleep(for:.milliseconds(250))
            }
            XCTAssertTrue(visible,"Running app should draw visible pixels within 10 seconds")
            try await client.quitApp()
            // Firmware acknowledges stop before the runner releases its script file.
            // This hardware check models the normal UI pause between Stop and Remove.
            try await Task.sleep(for:.seconds(1))
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
