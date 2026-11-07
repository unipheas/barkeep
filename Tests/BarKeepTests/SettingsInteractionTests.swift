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
}
