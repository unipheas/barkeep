import XCTest
import SwiftUI
import ViewInspector
@testable import BarKeep

final class SettingsInteractionTests: XCTestCase {
    @MainActor func testNativeControlsEditTheCompleteSettingsDocument() throws {
        let schemaJSON = #"{"version":1,"fields":{"enabled":{"type":"boolean","label":"Enabled"},"format":{"type":"enum","label":"Format","options":[{"value":"a","label":"Alpha"},{"value":"b","label":"Beta"}]},"name":{"type":"string","label":"Name"},"secret":{"type":"string","label":"Secret","sensitive":true},"group":{"type":"group","label":"Group","fields":{"nested":{"type":"string","label":"Nested"}}}}}"#
        let schema = try JSONDecoder().decode(AppSettingsSchema.self,from:Data(schemaJSON.utf8))
        var json = #"{"version":1,"values":{"enabled":false,"format":"a","name":"before","secret":"fixture","group":{"nested":"old"},"unknown":42}}"#
        let form = AppSettingsForm(fields:schema.fields,json:Binding(get:{json},set:{json=$0}))
        let view = try form.inspect()
        try view.find(ViewType.Toggle.self).tap()
        try view.find(ViewType.Picker.self).select(value:"b")
        try view.find(ViewType.TextField.self,where: { try $0.labelView().text().string() == "Name" }).setInput("after")
        try view.find(ViewType.TextField.self,where: { try $0.labelView().text().string() == "Nested" }).setInput("new")
        try view.find(ViewType.SecureField.self).setInput("edited fixture")
        XCTAssertEqual(AppSettingsDocument.value(in:json,at:["enabled"]) as? Bool,true)
        XCTAssertEqual(AppSettingsDocument.value(in:json,at:["format"]) as? String,"b")
        XCTAssertEqual(AppSettingsDocument.value(in:json,at:["name"]) as? String,"after")
        XCTAssertEqual(AppSettingsDocument.value(in:json,at:["secret"]) as? String,"edited fixture")
        XCTAssertEqual(AppSettingsDocument.value(in:json,at:["group","nested"]) as? String,"new")
        XCTAssertEqual(AppSettingsDocument.value(in:json,at:["unknown"]) as? Int,42)
        XCTAssertNoThrow(try schema.validate(json))
    }

    @MainActor func testSettingsSheetValidatesThenSavesAndCloses() async throws {
        _ = NSApplication.shared
        let lock=NSLock()
        var document = #"{"version":1,"values":{"name":"before","unknown":42}}"#
        var writes=0
        let schema = #"{"version":1,"fields":{"name":{"type":"string","label":"Name","min_length":1,"max_length":8}}}"#
        HTTPStub.handler={ request in
            if request.url!.path == "/api/storage/read" { return (200,Data(schema.utf8)) }
            if request.httpMethod == "PUT" {
                lock.withLock { document=String(decoding:HTTPStub.body(request),as:UTF8.self); writes += 1 }
            }
            return (200,Data(lock.withLock { document }.utf8))
        }
        defer { HTTPStub.handler=nil }
        let model=DeviceAppsModel(client:BusyBarClient(host:"fixture.test",session:HTTPStub.session()))
        let app=try JSONDecoder().decode(DeviceApp.self,from:Data(appFixture.utf8))
        await model.loadSettings(app)
        let sheet=AppSettingsSheet(model:model)
        let field=try sheet.inspect().find(ViewType.TextField.self)
        try field.setInput("Too long name")
        try sheet.inspect().find(button:"Save").tap()
        await settle { model.error != nil }
        XCTAssertEqual(lock.withLock { writes },0)
        XCTAssertNotNil(try sheet.inspect().find(text:model.error!))
        try field.setInput("after")
        try sheet.inspect().find(button:"Save").tap()
        await settle { model.message?.contains("Saved") == true }
        XCTAssertEqual(lock.withLock { writes },1)
        XCTAssertEqual(AppSettingsDocument.value(in:model.settingsJSON,at:["name"]) as? String,"after")
        XCTAssertEqual(AppSettingsDocument.value(in:model.settingsJSON,at:["unknown"]) as? Int,42)
        XCTAssertNotNil(try sheet.inspect().find(text:model.message!))
        try sheet.inspect().find(button:"Done").tap()
        XCTAssertNil(model.settingsApp)
        XCTAssertEqual(model.settingsJSON,"")
    }

    @MainActor func testSettingsSheetWithoutSchemaEditsCompleteJSON() async throws {
        _ = NSApplication.shared
        let lock=NSLock()
        var document = #"{"version":2,"values":{"custom":"before"}}"#
        HTTPStub.handler={ request in
            if request.url!.path == "/api/storage/read" { return (404,Data()) }
            if request.httpMethod == "PUT" {
                lock.withLock { document=String(decoding:HTTPStub.body(request),as:UTF8.self) }
            }
            return (200,Data(lock.withLock { document }.utf8))
        }
        defer { HTTPStub.handler=nil }
        let model=DeviceAppsModel(client:BusyBarClient(host:"fixture.test",session:HTTPStub.session()))
        let app=try JSONDecoder().decode(DeviceApp.self,from:Data(appFixture.utf8))
        await model.loadSettings(app)
        let sheet=AppSettingsSheet(model:model)
        try sheet.inspect().find(ViewType.TextEditor.self).setInput(#"{"version":2,"values":{"custom":"after"}}"#)
        try sheet.inspect().find(button:"Save").tap()
        await settle { model.message?.contains("Saved") == true }
        XCTAssertEqual(AppSettingsDocument.value(in:model.settingsJSON,at:["custom"]) as? String,"after")
        try sheet.inspect().find(button:"Done").tap()
        XCTAssertNil(model.settingsApp)
    }

    @MainActor private func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for:.milliseconds(5))
        }
        XCTFail("Settings action did not settle")
    }

}
