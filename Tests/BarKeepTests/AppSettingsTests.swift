import XCTest
import SwiftUI
import AppKit
@testable import BarKeep

final class AppSettingsTests: XCTestCase {
    func testNestedEditsPreserveVersionAndUnknownFields() throws {
        let original = #"{"version":2,"values":{"keep":"unchanged","group":{"flag":false,"number":3}}}"#
        let changed = try AppSettingsDocument.replacing(in:original,at:["group","flag"],value:true)
        XCTAssertEqual(AppSettingsDocument.value(in:changed,at:["group","flag"]) as? Bool,true)
        XCTAssertEqual(AppSettingsDocument.value(in:changed,at:["group","number"]) as? Int,3)
        XCTAssertEqual(AppSettingsDocument.value(in:changed,at:["keep"]) as? String,"unchanged")
        XCTAssertTrue(changed.contains("\"version\" : 2"))
        XCTAssertNil(AppSettingsDocument.value(in:"bad json",at:["x"]))
        XCTAssertThrowsError(try AppSettingsDocument.replacing(in:"{}",at:["x"],value:true))
        XCTAssertThrowsError(try AppSettingsDocument.replacing(in:original,at:[],value:true))
        let created = try AppSettingsDocument.replacing(in:original,at:["new","setting"],value:"hello")
        XCTAssertEqual(AppSettingsDocument.value(in:created,at:["new","setting"]) as? String,"hello")
    }

    @MainActor func testSchemaBackedEditorLoadsEveryFieldKind() async throws {
        let schemaJSON = #"{"version":1,"fields":{"flag":{"type":"boolean","label":"Enabled","description":"Test flag"},"count":{"type":"integer","label":"Count"},"choice":{"type":"enum","label":"Format","options":[{"value":"a","label":"A"}]},"secret":{"type":"string","label":"Secret","sensitive":true},"time":{"type":"time","label":"Time"},"color":{"type":"color","label":"Color"},"location":{"type":"geolocation","label":"Location"},"group":{"type":"group","label":"Group","fields":{"name":{"type":"string","label":"Name"}}}}}"#
        let schema = try JSONDecoder().decode(AppSettingsSchema.self,from:Data(schemaJSON.utf8))
        let client = BusyBarClient(host:"bar.test",session:HTTPStub.session())
        let model = DeviceAppsModel(client:client)
        HTTPStub.handler = { request in
            switch request.url!.path {
            case "/api/apps/list": return (200,Data("{\"apps\":[\(appFixture)]}".utf8))
            case "/api/storage/read": return (200,Data(schemaJSON.utf8))
            default: return (200,Data(##"{"version":1,"values":{"flag":true,"count":3,"choice":"a","secret":"test","time":"12:00","color":"#FFFFFF","location":{"mode":"auto","name":"Auto"},"group":{"name":"QA"}}}"##.utf8))
            }
        }
        defer { HTTPStub.handler = nil }
        await model.refresh()
        await model.loadSettings(try XCTUnwrap(model.apps.first))
        XCTAssertNotNil(model.settingsSchema)
        let hosting = NSHostingView(rootView:AppSettingsForm(fields:schema.fields,json:Binding(get:{model.settingsJSON},set:{model.settingsJSON=$0})))
        hosting.frame = NSRect(x:0,y:0,width:450,height:650)
        let window = NSWindow(contentRect:hosting.frame,styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for:.milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hosting.fittingSize.height,100)
        model.closeSettings(); XCTAssertNil(model.settingsSchema)
    }
}
