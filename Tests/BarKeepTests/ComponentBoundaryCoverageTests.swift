import SwiftUI
import ViewInspector
import XCTest
@testable import BarKeep

final class ComponentBoundaryCoverageTests: XCTestCase {
    @MainActor func testEveryDeviceControlRendersItsApplicableInput() throws {
        let suite = "dev.barkeep.component.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults, startServices: false, session: HTTPStub.session())
        for endpoint in DeviceEndpoint.all {
            let model = DeviceToolsModel()
            model.reset(for: endpoint)
            let view = DeviceToolsView(endpoint: endpoint, model: model).environment(state)
            if endpoint.path == "/status/ws" {
                XCTAssertNotNil(try view.inspect().find(text: "Live Device Status"))
                continue
            }
            XCTAssertNotNil(try view.inspect().find(button: endpoint.isReadOnly ? "Read from Bar" : "Apply to Bar…"))
            if endpoint.contentType == "application/json" {
                let editor = try view.inspect().find(ViewType.TextEditor.self)
                try editor.setInput("{\"fixture\":true}")
                XCTAssertEqual(model.json, "{\"fixture\":true}")
            } else if endpoint.isBinary {
                XCTAssertNotNil(try view.inspect().find(text: "No file selected"))
                model.upload = URL(fileURLWithPath: "/tmp/fixture.bin")
                XCTAssertNotNil(try view.inspect().find(text: "fixture.bin"))
            }
            for parameter in endpoint.parameters where !parameter.choices.isEmpty {
                let picker = try view.inspect().find(ViewType.Picker.self, where: {
                    try $0.labelView().text().string() == parameter.name
                })
                try picker.select(value: parameter.choices[0])
                XCTAssertEqual(model.values[parameter.name], parameter.choices[0])
            }
        }
    }

    @MainActor func testSettingsFallbackDescriptionsAndInvalidDocumentEdit() throws {
        let schema = try JSONDecoder().decode(AppSettingsSchema.self, from: Data(#"{"version":1,"fields":{"future":{"type":"future","label":"Future","description":"Preserve this value"},"name":{"type":"string","label":"Name"},"emptyGroup":{"type":"group","label":"Empty group"}}}"#.utf8))
        var json = "not JSON"
        let form = AppSettingsForm(fields: schema.fields, json: Binding(get: { json }, set: { json = $0 }))
        XCTAssertNotNil(try form.inspect().find(text: "Future: use Advanced JSON below to edit this setting."))
        XCTAssertNotNil(try form.inspect().find(text: "Preserve this value"))
        let field = try form.inspect().find(ViewType.TextField.self)
        XCTAssertEqual(try field.input(), "")
        try field.setInput("replacement")
        XCTAssertEqual(json, "not JSON", "An invalid complete document must not be silently replaced")
    }
}
