import SwiftUI
import ViewInspector
import XCTest
@testable import BarKeep

final class DeviceToolsInteractionTests: XCTestCase {
    @MainActor func testReadControlDisplaysResponseAndEnablesExport() async throws {
        let suite="dev.barkeep.api-ui.\(UUID().uuidString)"
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite); HTTPStub.handler=nil }
        HTTPStub.handler={ _ in (200,Data(#"{"result":"fixture"}"#.utf8)) }
        let state=AppState(defaults:defaults,startServices:false,session:HTTPStub.session())
        let model=DeviceToolsModel()
        let view=DeviceToolsView(model:model).environment(state)
        XCTAssertTrue(try view.inspect().find(button:"Save Response…").isDisabled())
        try view.inspect().find(button:"Read from Bar").tap()
        await settle { model.responseData != nil }
        XCTAssertFalse(try view.inspect().find(button:"Save Response…").isDisabled())
        XCTAssertNotNil(try view.inspect().find(text:model.response))
        HTTPStub.handler={ _ in (403,Data()) }
        try view.inspect().find(button:"Read from Bar").tap()
        await settle { model.error != nil }
        XCTAssertNotNil(try view.inspect().find(text:model.error!))
        XCTAssertTrue(try view.inspect().find(button:"Save Response…").isDisabled())
    }

    @MainActor func testWriteControlValidatesThenConfirmsTheEditedParameter() async throws {
        let suite="dev.barkeep.api-write-ui.\(UUID().uuidString)"
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite); HTTPStub.handler=nil }
        let sent=expectation(description:"Confirmed brightness applied")
        HTTPStub.handler={ request in
            XCTAssertEqual(request.httpMethod,"POST")
            XCTAssertEqual(request.url?.path,"/api/display/brightness")
            XCTAssertEqual(request.url?.query,"value=50")
            sent.fulfill()
            return (200,Data())
        }
        let state=AppState(defaults:defaults,startServices:false,session:HTTPStub.session())
        let model=DeviceToolsModel()
        let endpoint=try XCTUnwrap(DeviceEndpoint.all.first { $0.path == "/display/brightness" && $0.method == "POST" })
        model.reset(for:endpoint)
        let view=DeviceToolsView(endpoint:endpoint,model:model).environment(state)
        try view.inspect().find(button:"Apply to Bar…").tap()
        XCTAssertFalse(model.confirm)
        XCTAssertEqual(model.error,"Enter value.")
        try view.inspect().find(ViewType.TextField.self,where:{
            (try? $0.labelView().text().string()) == "Required"
        }).setInput("50")
        try view.inspect().find(button:"Apply to Bar…").tap()
        XCTAssertTrue(model.confirm)
        try view.inspect().find(button:"Apply").tap()
        await fulfillment(of:[sent],timeout:2)
        await settle { model.responseData != nil }
        XCTAssertEqual(model.response,"Completed successfully.")
    }

    @MainActor private func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for:.milliseconds(5))
        }
        XCTFail("Device control did not settle")
    }
}
