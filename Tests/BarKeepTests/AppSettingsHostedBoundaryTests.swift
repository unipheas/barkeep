import SwiftUI
import XCTest
import ViewInspector
@testable import BarKeep

final class AppSettingsHostedBoundaryTests: XCTestCase {
    @MainActor func testInstalledFormDisplaysAndClearsEditErrorAndEditsDefaults() async throws {
        let schema = try JSONDecoder().decode(AppSettingsSchema.self, from: Data(#"{"version":1,"fields":{"name":{"type":"string","label":"Name"},"enabled":{"type":"boolean","label":"Enabled"},"count":{"type":"integer","label":"Count"},"choice":{"type":"enum","label":"Choice"}}}"#.utf8))
        var json = "{}"
        var sut = AppSettingsForm(fields: schema.fields, json: Binding(get: { json }, set: { json = $0 }))
        let inspected = sut.on(\.didAppear) { view in
            let name = try view.find(ViewType.TextField.self, where: { try $0.labelView().text().string() == "Name" })
            try name.setInput("invalid document edit")
            let error = "Load the complete settings document before editing."
            XCTAssertNotNil(try view.find(text: error))
            XCTAssertEqual(json, "{}")
            json = #"{"version":1,"values":{}}"#
            XCTAssertFalse(try view.find(ViewType.Toggle.self).isOn())
            try view.find(ViewType.Toggle.self).tap()
            XCTAssertEqual(AppSettingsDocument.value(in: json, at: ["enabled"]) as? Bool, true)
            let count = try view.find(ViewType.TextField.self, where: { try $0.labelView().text().string() == "Count" })
            XCTAssertEqual(try count.input(), "0")
            try count.setInput("7")
            XCTAssertEqual(AppSettingsDocument.value(in: json, at: ["count"]) as? Int, 7)
            try name.setInput("repaired")
            XCTAssertEqual(AppSettingsDocument.value(in: json, at: ["name"]) as? String, "repaired")
            XCTAssertThrowsError(try view.find(text: error))
            XCTAssertNotNil(try view.find(ViewType.Picker.self))
        }
        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }
        await fulfillment(of: [inspected], timeout: 5)
    }

    @MainActor func testInstalledAdvancedJSONEditorSavesCompleteDocument() async throws {
        let saved = expectation(description: "Complete settings document saved")
        let document = #"{"version":1,"values":{"name":"edited","unknown":42}}"#
        HTTPStub.handler = { request in
            if request.url?.path == "/api/storage/read" {
                return (200, Data(#"{"version":1,"fields":{"name":{"type":"string","label":"Name"}}}"#.utf8))
            }
            if request.httpMethod == "PUT" {
                XCTAssertEqual(request.url?.path, "/api/apps/settings")
                let body = String(decoding: HTTPStub.body(request), as: UTF8.self)
                XCTAssertEqual(AppSettingsDocument.value(in: body, at: ["name"]) as? String, "edited")
                XCTAssertEqual(AppSettingsDocument.value(in: body, at: ["unknown"]) as? Int, 42)
                saved.fulfill()
            }
            return (200, Data(document.utf8))
        }
        defer { HTTPStub.handler = nil }
        let model = DeviceAppsModel(client: BusyBarClient(host: "fixture.test", session: HTTPStub.session()))
        await model.loadSettings(try JSONDecoder().decode(DeviceApp.self, from: Data(appFixture.utf8)))
        var sut = AppSettingsSheet(model: model)
        let inspected = sut.on(\.didAppear) { view in
            let advanced = try view.find(ViewType.DisclosureGroup.self)
            XCTAssertFalse(try advanced.isExpanded(), "A fresh settings sheet starts with Advanced JSON collapsed")
            try advanced.expand()
            XCTAssertTrue(try advanced.isExpanded())
            try view.find(ViewType.TextEditor.self).setInput(document)
            try view.find(button: "Save").tap()
        }
        ViewHosting.host(view: sut)
        defer { ViewHosting.expel(); model.closeSettings() }
        await fulfillment(of: [inspected, saved], timeout: 5)
        for _ in 0..<200 where model.working { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(model.error)
        XCTAssertEqual(AppSettingsDocument.value(in: model.settingsJSON, at: ["unknown"]) as? Int, 42)
    }

    @MainActor func testInstalledResetConfirmationCancelsThenRestoresDefaults() async throws {
        let lock = NSLock()
        var resets = 0
        HTTPStub.handler = { request in
            if request.url?.path == "/api/storage/read" { return (404, Data()) }
            if request.httpMethod == "DELETE" {
                XCTAssertEqual(request.url?.path, "/api/apps/settings")
                XCTAssertTrue(request.url!.query!.contains("app_id=app.test.clock"))
                lock.withLock { resets += 1 }
                return (200, Data())
            }
            return (200, Data(#"{"version":1,"values":{"name":"default"}}"#.utf8))
        }
        defer { HTTPStub.handler = nil }
        let model = DeviceAppsModel(client: BusyBarClient(host: "fixture.test", session: HTTPStub.session()))
        await model.loadSettings(try JSONDecoder().decode(DeviceApp.self, from: Data(appFixture.utf8)))
        var sut = AppSettingsSheet(model: model)
        let inspected = sut.on(\.didAppear) { view in
            XCTAssertThrowsError(try view.find(text: "This replaces all settings with the app's defaults."))
            try view.find(button: "Reset Defaults…").tap()
            XCTAssertNotNil(try view.find(text: "This replaces all settings with the app's defaults."))
            try view.find(button: "Cancel").tap()
            XCTAssertEqual(lock.withLock { resets }, 0)
            try view.find(button: "Reset Defaults…").tap()
            try view.find(button: "Reset").tap()
        }
        ViewHosting.host(view: sut)
        defer { ViewHosting.expel(); model.closeSettings() }
        await fulfillment(of: [inspected], timeout: 5)
        for _ in 0..<200 where model.message != "Restored default settings." { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(lock.withLock { resets }, 1)
        XCTAssertEqual(model.message, "Restored default settings.")
        XCTAssertEqual(AppSettingsDocument.value(in: model.settingsJSON, at: ["name"]) as? String, "default")
    }
}
